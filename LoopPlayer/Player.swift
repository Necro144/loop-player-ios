import AVFoundation
import SwiftUI
import MediaPlayer
import UIKit

/// Fast-changing playback time, kept apart from Player so only the scrubbers redraw several times a second.
@MainActor
final class PlaybackClock: ObservableObject {
    @Published var time: Double = 0
    @Published var duration: Double = 0
    @Published var buffering = false
}

/// The view that shows video. Player detaches it in the background so audio keeps going.
final class PlayerLayerView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

@MainActor
final class Player: ObservableObject {
    static let shared = Player()

    let avPlayer = AVPlayer()
    let clock = PlaybackClock()

    @Published private(set) var queue: [Track] = []
    @Published private(set) var index = 0
    @Published private(set) var isPlaying = false
    @Published private(set) var isPreparing = false
    @Published private(set) var repeatMode: RepeatMode = .off
    @Published private(set) var shuffle = false
    @Published private(set) var rate: Float = 1.0
    @Published private(set) var sleepEnd: Date?
    @Published private(set) var sleepAtTrackEnd = false
    @Published var showFullPlayer = false
    @Published var toast: String?
    /// true: speed changes keep the pitch (time-stretch). false: pitch follows speed, like a tape.
    @Published private(set) var keepPitch: Bool = UserDefaults.standard.object(forKey: "keepPitch") as? Bool ?? true
    /// Play together with other apps' sound (the lock screen controls then go away).
    @Published private(set) var mixWithOthers: Bool = UserDefaults.standard.bool(forKey: "mixWithOthers")
    /// A-B loop points in seconds, for the current song only.
    @Published private(set) var loopA: Double?
    @Published private(set) var loopB: Double?

    static let rates: [Float] = [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0]
    static let rateRange: ClosedRange<Float> = 0.5...2.0

    /// Queue order before shuffle was turned on.
    private var original: [Track] = []
    private var loadToken = 0
    private var itemObservers: [NSKeyValueObservation] = []
    private var endObserver: NSObjectProtocol?
    private var timeObserver: Any?
    private var statusObserver: NSKeyValueObservation?
    private var surfaces = NSHashTable<PlayerLayerView>.weakObjects()
    private var inBackground = false
    private var resumeAfterInterruption = false
    private var sleepTimer: Timer?
    private var failures = 0
    private var lastSave = Date.distantPast
    private var countedPlay: String?
    /// Set when the pause came from the user (or the app on purpose: sleep timer, unplugged headphones,
    /// end of the queue). A pause without it, while in the background, is iOS pausing a video: resumed.
    private var userPaused = true
    private var interrupted = false
    private var lastAutoResume = Date.distantPast
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var loopObserver: Any?
    /// For the simulator test: how often the player stopped while the app was in the background.
    private(set) var bgPauses = 0
    var isInBackground: Bool { inBackground }

    var current: Track? { queue.indices.contains(index) ? queue[index] : nil }
    var upNext: [Track] { index + 1 < queue.count ? Array(queue[(index + 1)...]) : [] }

    private init() {
        // 1.1.2: "Play along with other apps" makes iOS hide the lock screen and Control Center
        // controls. Turn it off once for everyone; it can be turned on again in Settings.
        if !UserDefaults.standard.bool(forKey: "mixMigrated112") {
            UserDefaults.standard.set(true, forKey: "mixMigrated112")
            UserDefaults.standard.set(false, forKey: "mixWithOthers")
            mixWithOthers = false
        }
        avPlayer.actionAtItemEnd = .none
        avPlayer.allowsExternalPlayback = true
        // Video files keep playing (as sound) when the app is in the background.
        avPlayer.audiovisualBackgroundPlaybackPolicy = .continuesIfPossible
        configureSession()
        observePlayer()
        observeSystem()
        setupRemoteCommands()
        UIApplication.shared.beginReceivingRemoteControlEvents()
        restore()
    }

    // MARK: Starting playback

    /// Plays `list`, starting at `startAt`. `shuffled: true` starts shuffle mode with a random first song.
    func play(_ list: [Track], startAt: Int = 0, shuffled: Bool = false) {
        guard !list.isEmpty else { return }
        let start = min(max(startAt, 0), list.count - 1)
        original = list
        if shuffled { shuffle = true }
        if shuffle {
            if shuffled {
                queue = list.shuffled()
            } else {
                var rest = list
                let first = rest.remove(at: start)
                queue = [first] + rest.shuffled()
            }
            index = 0
        } else {
            queue = list
            index = start
        }
        load(index, autoplay: true)
    }

    func play(_ track: Track, in list: [Track]) {
        let i = list.firstIndex(where: { $0.id == track.id }) ?? 0
        play(list, startAt: i)
    }

    func jump(to queueIndex: Int) {
        guard queue.indices.contains(queueIndex) else { return }
        load(queueIndex, autoplay: true)
    }

    func playNext(_ tracks: [Track]) {
        guard !tracks.isEmpty else { return }
        if queue.isEmpty { play(tracks); return }
        queue.insert(contentsOf: tracks, at: index + 1)
        if let cur = current, let o = original.firstIndex(where: { $0.id == cur.id }) {
            original.insert(contentsOf: tracks, at: o + 1)
        } else {
            original.append(contentsOf: tracks)
        }
        toast = tracks.count == 1 ? "Playing next" : "\(tracks.count) songs play next"
        saveState(force: true)
    }

    func addToQueue(_ tracks: [Track]) {
        guard !tracks.isEmpty else { return }
        if queue.isEmpty { play(tracks); return }
        queue.append(contentsOf: tracks)
        original.append(contentsOf: tracks)
        toast = tracks.count == 1 ? "Added to queue" : "Added \(tracks.count) songs to queue"
        saveState(force: true)
    }

    /// Offsets are positions inside `upNext`.
    func moveUpNext(from: IndexSet, to: Int) {
        let base = index + 1
        var next = upNext
        next.move(fromOffsets: from, toOffset: to)
        queue.replaceSubrange(base..<queue.count, with: next)
        if !shuffle { original = queue }
        saveState(force: true)
    }

    func removeUpNext(at offsets: IndexSet) {
        let base = index + 1
        for o in offsets.sorted(by: >) where base + o < queue.count {
            let t = queue.remove(at: base + o)
            if let j = original.lastIndex(of: t) { original.remove(at: j) }
        }
        saveState(force: true)
    }

    func clearUpNext() {
        guard index + 1 < queue.count else { return }
        let removed = Set(queue[(index + 1)...].map(\.id))
        queue.removeSubrange((index + 1)...)
        original.removeAll { removed.contains($0.id) && $0.id != current?.id }
        saveState(force: true)
    }

    // MARK: Transport

    func togglePlay() { isPlaying ? pause() : resume() }

    func resume() {
        guard current != nil else {
            let all = Library.shared.tracks
            if !all.isEmpty { play(all, shuffled: shuffle) }
            return
        }
        if avPlayer.currentItem == nil {
            load(index, autoplay: true, at: clock.time)
            return
        }
        userPaused = false
        interrupted = false
        activateSession()
        avPlayer.defaultRate = rate
        avPlayer.playImmediately(atRate: rate)
        endBackgroundTask()
        // Publish the lock screen / Control Center info again now that the sound is live.
        updateNowPlaying()
        if let t = current, countedPlay != t.id {
            countedPlay = t.id
            UserStore.shared.markPlayed(t.id)
        }
    }

    func pause() {
        halt()
        saveState(force: true)
    }

    /// Pauses on purpose (never auto-resumed).
    private func halt() {
        userPaused = true
        avPlayer.pause()
        endBackgroundTask()
    }

    func next() {
        guard !queue.isEmpty else { return }
        if index + 1 < queue.count {
            load(index + 1, autoplay: true)
        } else {
            if shuffle && repeatMode == .all { reshuffleForNextRound() }
            load(0, autoplay: true)
        }
    }

    func previous() {
        guard !queue.isEmpty else { return }
        if clock.time > 3 || (index == 0 && repeatMode != .all) {
            seek(to: 0)
            return
        }
        load(index > 0 ? index - 1 : queue.count - 1, autoplay: true)
    }

    func seek(to seconds: Double) {
        let s = max(0, min(seconds, clock.duration > 0 ? clock.duration - 0.25 : seconds))
        clock.time = s
        avPlayer.seek(to: CMTime(seconds: s, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in self?.updateNowPlayingTime() }
        }
    }

    func skip(by seconds: Double) { seek(to: clock.time + seconds) }

    func stop() {
        halt()
        clearLoop()
        avPlayer.replaceCurrentItem(with: nil)
        queue = []
        original = []
        index = 0
        clock.time = 0
        clock.duration = 0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        saveState(force: true)
    }

    // MARK: Modes

    func cycleRepeat() {
        setRepeat(repeatMode.next)
    }

    func setRepeat(_ mode: RepeatMode) {
        repeatMode = mode
        switch mode {
        case .one: toast = "Looping this song"
        case .all: toast = "Repeating the queue"
        case .off: toast = "Repeat off"
        }
        updateRemoteState()
        saveState(force: true)
    }

    func toggleShuffle() { setShuffle(!shuffle) }

    func setShuffle(_ on: Bool) {
        guard on != shuffle else { return }
        shuffle = on
        if let cur = current {
            if on {
                original = queue
                var rest = queue
                rest.remove(at: index)
                queue = [cur] + rest.shuffled()
                index = 0
            } else {
                queue = original.isEmpty ? queue : original
                index = queue.firstIndex(where: { $0.id == cur.id }) ?? 0
            }
        }
        toast = on ? "Shuffle on" : "Shuffle off"
        updateRemoteState()
        saveState(force: true)
    }

    private func reshuffleForNextRound() {
        queue = queue.shuffled()
    }

    func setRate(_ r: Float) {
        let r = min(max((r * 100).rounded() / 100, Player.rateRange.lowerBound), Player.rateRange.upperBound)
        rate = r
        avPlayer.defaultRate = r
        if isPlaying { avPlayer.rate = r }
        updateNowPlaying()
        saveState(force: true)
    }

    var pitchAlgorithm: AVAudioTimePitchAlgorithm { keepPitch ? .spectral : .varispeed }

    func setKeepPitch(_ on: Bool) {
        keepPitch = on
        UserDefaults.standard.set(on, forKey: "keepPitch")
        if let item = avPlayer.currentItem {
            item.audioTimePitchAlgorithm = pitchAlgorithm
            // Re-apply the rate so the new mode is heard at once.
            if isPlaying { avPlayer.rate = rate }
        }
        toast = on ? "Speed keeps the pitch" : "Pitch follows speed (like a tape)"
    }

    func setMixWithOthers(_ on: Bool) {
        mixWithOthers = on
        UserDefaults.standard.set(on, forKey: "mixWithOthers")
        configureSession()
        if isPlaying { activateSession() }
        if !on { updateNowPlaying() }
    }

    // MARK: A-B loop

    /// First tap marks A, second marks B (the part between them repeats), third clears.
    func abTap() {
        if loopA == nil {
            loopA = clock.time
            toast = "A set at \(formatTime(clock.time)). Tap again at the end of the part."
        } else if loopB == nil, let a = loopA {
            let b = clock.time
            guard b > a + 0.5 else {
                toast = "B must be after A"
                return
            }
            loopB = b
            installLoopObserver()
            toast = "Looping \(formatTime(a)) – \(formatTime(b))"
            seek(to: a)
        } else {
            clearLoop()
            toast = "A-B loop off"
        }
    }

    func clearLoop() {
        loopA = nil
        loopB = nil
        if let loopObserver { avPlayer.removeTimeObserver(loopObserver) }
        loopObserver = nil
    }

    private func installLoopObserver() {
        if let loopObserver { avPlayer.removeTimeObserver(loopObserver) }
        loopObserver = nil
        guard let b = loopB else { return }
        loopObserver = avPlayer.addBoundaryTimeObserver(forTimes: [NSValue(time: CMTime(seconds: b, preferredTimescale: 600))], queue: .main) { [weak self] in
            Task { @MainActor in self?.loopBack() }
        }
    }

    private func loopBack() {
        guard let a = loopA, loopB != nil else { return }
        seek(to: a)
    }

    // MARK: Sleep timer

    func setSleep(minutes: Int) {
        sleepAtTrackEnd = false
        sleepEnd = Date().addingTimeInterval(TimeInterval(minutes * 60))
        startSleepTimer()
        toast = "Sleep timer: \(minutes) min"
    }

    func setSleepAtTrackEnd() {
        sleepEnd = nil
        sleepAtTrackEnd = true
        sleepTimer?.invalidate()
        toast = "Stops after this song"
    }

    func cancelSleep() {
        sleepEnd = nil
        sleepAtTrackEnd = false
        sleepTimer?.invalidate()
        sleepTimer = nil
        avPlayer.volume = 1
    }

    private func startSleepTimer() {
        sleepTimer?.invalidate()
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sleepTick() }
        }
        RunLoop.main.add(t, forMode: .common)
        sleepTimer = t
    }

    private func sleepTick() {
        guard let end = sleepEnd else { sleepTimer?.invalidate(); return }
        let left = end.timeIntervalSinceNow
        if left <= 0 {
            pause()
            cancelSleep()
            return
        }
        avPlayer.volume = left < 15 ? Float(max(0.05, left / 15)) : 1
    }

    // MARK: Loading

    private func load(_ i: Int, autoplay: Bool, at seconds: Double = 0) {
        guard queue.indices.contains(i) else { return }
        index = i
        let track = queue[i]
        loadToken += 1
        let token = loadToken
        countedPlay = nil
        clearLoop()
        // Keeps the app running in the background while the next file is opened (or downloaded from
        // iCloud). Without it iOS can suspend the silent app here, and the music stops.
        if autoplay { beginBackgroundTask() }
        clock.time = seconds
        clock.duration = track.duration
        clock.buffering = false
        updateNowPlaying()
        saveState(force: true)

        guard let url = Library.shared.url(for: track) else {
            toast = "The folder for \(track.title) is not available"
            return
        }
        isPreparing = true
        avPlayer.pause()
        Task {
            let ok = await FileAccess.ensureLocal(url)
            guard token == self.loadToken else { return }
            self.isPreparing = false
            guard ok else {
                self.failed(track, "Couldn't open \(track.fileName)")
                return
            }
            let item = AVPlayerItem(url: url)
            item.audioTimePitchAlgorithm = self.pitchAlgorithm
            if track.isVideo && !track.hasArtwork { self.captureFrame(item, id: track.id, token: token) }
            self.watch(item, token: token)
            self.avPlayer.replaceCurrentItem(with: item)
            if seconds > 0.5 {
                _ = await self.avPlayer.seek(to: CMTime(seconds: seconds, preferredTimescale: 600),
                                             toleranceBefore: .zero, toleranceAfter: .zero)
            }
            guard token == self.loadToken else { return }
            if autoplay { self.resume() } else { self.endBackgroundTask() }
            // The file is on the phone now: read its tags and grab a video frame if that never worked.
            if track.isPlaceholder || track.duration <= 0 || (track.isVideo && !track.hasArtwork) {
                Library.shared.refresh(track.id)
            }
            self.prefetchNext()
        }
    }

    private func watch(_ item: AVPlayerItem, token: Int) {
        itemObservers.forEach { $0.invalidate() }
        itemObservers = []
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        itemObservers.append(item.observe(\.status, options: [.new]) { [weak self] item, _ in
            let status = item.status
            let duration = item.duration
            Task { @MainActor in self?.itemStatusChanged(status, duration: duration, token: token) }
        })
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, token == self.loadToken else { return }
                self.itemEnded()
            }
        }
    }

    /// Picture for a video taken from the frames the player itself shows: works even when reading
    /// the file a second time (the usual way) fails on the phone.
    private func captureFrame(_ item: AVPlayerItem, id: String, token: Int) {
        let out = AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        item.add(out)
        Task {
            var best: (Data, Double)?
            for attempt in 0..<12 {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                guard token == self.loadToken else { return }
                if Library.shared.track(id)?.hasArtwork == true { return }
                let t = item.currentTime()
                guard t.seconds > 1.5, let buf = out.copyPixelBuffer(forItemTime: t, itemTimeForDisplay: nil) else { continue }
                guard let shot = Thumbnail.fromPixelBuffer(buf) else { continue }
                if best == nil || shot.1 > best!.1 { best = shot }
                // Skip black or very dark frames (fade-ins) for a few tries.
                if shot.1 > 0.12 || attempt >= 8 { break }
            }
            guard token == self.loadToken, let best else {
                FolderLog.append("No frame could be taken from the playing video \(id)")
                return
            }
            Library.shared.setThumbnail(id, jpg: best.0, how: "from the playing video")
        }
    }

    private func itemStatusChanged(_ status: AVPlayerItem.Status, duration: CMTime, token: Int) {
        guard token == loadToken, let t = current else { return }
        switch status {
        case .readyToPlay:
            failures = 0
            let d = CMTimeGetSeconds(duration)
            if d.isFinite && d > 0 {
                clock.duration = d
                // The scan could not read the length: the player could, so the list gets it too.
                if t.duration <= 0 { Library.shared.setDuration(t.id, d) }
            }
            updateNowPlaying()
            if t.isVideo && !t.hasArtwork, let asset = avPlayer.currentItem?.asset {
                // Picture from the file the player just opened (works whatever the scan ran into).
                Library.shared.makeThumbnail(t.id, from: asset, duration: clock.duration)
            }
        case .failed:
            failed(t, "Can't play \(t.fileName)")
        default:
            break
        }
    }

    private func failed(_ t: Track, _ text: String) {
        toast = text
        failures += 1
        // Skip broken files, but never loop forever when nothing in the queue plays.
        if failures < queue.count && queue.count > 1 {
            let token = loadToken
            Task {
                try? await Task.sleep(nanoseconds: 700_000_000)
                guard token == self.loadToken else { return }
                self.next()
            }
        } else {
            halt()
        }
    }

    private func itemEnded() {
        if sleepAtTrackEnd {
            sleepAtTrackEnd = false
            halt()
            seek(to: 0)
            return
        }
        switch repeatMode {
        case .one:
            if let t = current { UserStore.shared.markPlayed(t.id) }
            avPlayer.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.avPlayer.playImmediately(atRate: self.rate)
                    self.updateNowPlayingTime()
                }
            }
        case .all:
            next()
        case .off:
            if index + 1 < queue.count {
                next()
            } else {
                halt()
                seek(to: 0)
            }
        }
    }

    /// Downloads the next song from iCloud while this one plays, so the switch needs no wait.
    private func prefetchNext() {
        let nextIndex = index + 1 < queue.count ? index + 1 : (repeatMode == .all ? 0 : -1)
        guard queue.indices.contains(nextIndex), let url = Library.shared.url(for: queue[nextIndex]) else { return }
        FileAccess.prefetch(url)
    }

    // MARK: Background

    private func beginBackgroundTask() {
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "LoopPlayer.load") { [weak self] in
            Task { @MainActor in self?.endBackgroundTask() }
        }
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    /// The player stopped although nobody asked it to (iOS pausing a video in the background):
    /// start it again, at most once every few seconds so it can never fight the system.
    private func unexpectedPause() {
        guard !userPaused, !interrupted, !isPreparing, avPlayer.currentItem != nil,
              Date().timeIntervalSince(lastAutoResume) > 3 else { return }
        lastAutoResume = Date()
        FolderLog.append("Playback stopped by iOS in the background; started again")
        setSurfacesAttached(!inBackground)
        resume()
    }

    // MARK: Video surfaces

    func attach(_ view: PlayerLayerView) {
        surfaces.add(view)
        view.playerLayer.player = inBackground ? nil : avPlayer
    }

    private func setSurfacesAttached(_ on: Bool) {
        for v in surfaces.allObjects { v.playerLayer.player = on ? avPlayer : nil }
    }

    // MARK: Observers

    private func observePlayer() {
        timeObserver = avPlayer.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self] time in
            let s = CMTimeGetSeconds(time)
            Task { @MainActor in
                guard let self, s.isFinite, !self.isPreparing else { return }
                self.clock.time = s
                // Backup for the A-B boundary observer (e.g. after seeking past B).
                if let a = self.loopA, let b = self.loopB, s > b + 0.3 { self.seek(to: a) }
                self.saveState(force: false)
            }
        }
        statusObserver = avPlayer.observe(\.timeControlStatus, options: [.new]) { [weak self] p, _ in
            let st = p.timeControlStatus
            Task { @MainActor in
                guard let self else { return }
                let playing = st != .paused
                self.clock.buffering = st == .waitingToPlayAtSpecifiedRate
                if playing != self.isPlaying {
                    self.isPlaying = playing
                    self.updateNowPlayingTime()
                }
                if !playing && self.inBackground { self.bgPauses += 1 }
                if !playing && self.inBackground && !self.userPaused {
                    // Give the end-of-song handler the first word, then check again.
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    guard self.avPlayer.timeControlStatus == .paused, self.inBackground,
                          let item = self.avPlayer.currentItem,
                          CMTimeGetSeconds(item.currentTime()) < self.clock.duration - 1 else { return }
                    self.unexpectedPause()
                }
            }
        }
        NotificationCenter.default.addObserver(forName: .trackUpdated, object: nil, queue: .main) { [weak self] note in
            guard let id = note.object as? String else { return }
            Task { @MainActor in self?.trackUpdated(id) }
        }
    }

    private func trackUpdated(_ id: String) {
        guard let fresh = Library.shared.track(id) else { return }
        for i in queue.indices where queue[i].id == id { queue[i] = fresh }
        for i in original.indices where original[i].id == id { original[i] = fresh }
        if current?.id == id { updateNowPlaying() }
    }

    private func observeSystem() {
        let nc = NotificationCenter.default
        nc.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            guard let info = note.userInfo,
                  let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            let optRaw = info[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            Task { @MainActor in self?.interruption(type, AVAudioSession.InterruptionOptions(rawValue: optRaw)) }
        }
        nc.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  let reason = AVAudioSession.RouteChangeReason(rawValue: raw) else { return }
            if reason == .oldDeviceUnavailable {
                // Headphones unplugged / Bluetooth gone: pause like the Music app.
                Task { @MainActor in
                    FolderLog.append("Headphones or Bluetooth disconnected: paused")
                    self?.pause()
                }
            }
        }
        nc.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
            // The audio system restarted: everything has to be set up again.
            Task { @MainActor in
                guard let self else { return }
                FolderLog.append("iOS audio services were reset; reloading the song")
                let wasPlaying = !self.userPaused
                self.configureSession()
                self.avPlayer.replaceCurrentItem(with: nil)
                self.load(self.index, autoplay: wasPlaying, at: self.clock.time)
            }
        }
        // The picture must be taken off the player right inside this notification, before it
        // returns: iOS pauses a player that still shows video once the app is in the background.
        // (1.1.0 did this a moment later and also switched the video track off, which made the
        // song stop and start again when going to the home screen.)
        nc.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.inBackground = true
                self.setSurfacesAttached(false)
                // Keeps the sound session ours, so the lock screen and Control Center show the song.
                if self.isPlaying { self.activateSession() }
                self.saveState(force: true)
                self.updateNowPlaying()
            }
        }
        nc.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.inBackground = false
                self.setSurfacesAttached(true)
            }
        }
        nc.addObserver(forName: UIApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.saveState(force: true) }
        }
    }

    private func interruption(_ type: AVAudioSession.InterruptionType, _ options: AVAudioSession.InterruptionOptions) {
        switch type {
        case .began:
            // A call, an alarm, Siri, or another app that started its own sound.
            resumeAfterInterruption = isPlaying || !userPaused
            interrupted = true
            isPlaying = false
            FolderLog.append("Sound interrupted by iOS (call, alarm or another app)")
            saveState(force: true)
        case .ended:
            interrupted = false
            if resumeAfterInterruption && options.contains(.shouldResume) {
                FolderLog.append("Interruption over: playing again")
                resume()
            } else if resumeAfterInterruption {
                // The other app did not hand the sound back: stay paused, like the Music app.
                userPaused = true
            }
            resumeAfterInterruption = false
        @unknown default:
            break
        }
    }

    /// What iOS needs to show the song on the lock screen, for Settings > Lock screen check.
    func lockScreenReport() -> [String] {
        let s = AVAudioSession.sharedInstance()
        let info = MPNowPlayingInfoCenter.default().nowPlayingInfo
        var lines: [String] = []
        lines.append("Sound mode: \(s.category == .playback ? "playback (good)" : s.category.rawValue)")
        lines.append(s.categoryOptions.contains(.mixWithOthers) ? "Play along with other apps: ON (iOS hides the lock screen controls)" : "Play along with other apps: off (good)")
        lines.append("Another app is playing sound: \(s.isOtherAudioPlaying ? "yes" : "no")")
        lines.append("Playing now: \(isPlaying ? "yes" : "no")")
        lines.append("Song sent to the lock screen: \((info?[MPMediaItemPropertyTitle] as? String) ?? "none")")
        lines.append("Picture sent: \(info?[MPMediaItemPropertyArtwork] != nil ? "yes" : "no")")
        lines.append("Background audio allowed: \(((Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String]) ?? []).contains("audio") ? "yes" : "NO")")
        return lines
    }

    private func configureSession() {
        let s = AVAudioSession.sharedInstance()
        do {
            try s.setCategory(.playback, mode: .default, options: mixWithOthers ? [.mixWithOthers] : [])
        } catch {
            FolderLog.append("Could not set up the sound: \(error.localizedDescription)")
        }
    }

    private func activateSession() {
        do {
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            FolderLog.append("Could not start the sound: \(error.localizedDescription)")
        }
    }

    // MARK: Lock screen and Control Center

    private func setupRemoteCommands() {
        let c = MPRemoteCommandCenter.shared()
        c.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.resume() }
            return .success
        }
        c.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.pause() }
            return .success
        }
        c.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.togglePlay() }
            return .success
        }
        c.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.next() }
            return .success
        }
        c.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.previous() }
            return .success
        }
        c.changePlaybackPositionCommand.addTarget { [weak self] e in
            guard let e = e as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let t = e.positionTime
            Task { @MainActor in self?.seek(to: t) }
            return .success
        }
        c.changeRepeatModeCommand.addTarget { [weak self] e in
            guard let e = e as? MPChangeRepeatModeCommandEvent else { return .commandFailed }
            let mode: RepeatMode
            switch e.repeatType {
            case .one: mode = .one
            case .all: mode = .all
            default: mode = .off
            }
            Task { @MainActor in self?.setRepeat(mode) }
            return .success
        }
        c.changeShuffleModeCommand.addTarget { [weak self] e in
            guard let e = e as? MPChangeShuffleModeCommandEvent else { return .commandFailed }
            let on = e.shuffleType != .off
            Task { @MainActor in self?.setShuffle(on) }
            return .success
        }
        c.changePlaybackRateCommand.supportedPlaybackRates = Player.rates.map { NSNumber(value: $0) }
        c.changePlaybackRateCommand.addTarget { [weak self] e in
            guard let e = e as? MPChangePlaybackRateCommandEvent else { return .commandFailed }
            let r = e.playbackRate
            Task { @MainActor in self?.setRate(r) }
            return .success
        }
        // Fine speeds (e.g. 0.85x) set in the app also show on the lock screen.
        c.changePlaybackRateCommand.supportedPlaybackRates = [0.5, 0.75, 0.8, 0.85, 0.9, 0.95, 1.0, 1.05, 1.1, 1.25, 1.5, 1.75, 2.0].map { NSNumber(value: $0) }
        c.skipForwardCommand.isEnabled = false
        c.skipBackwardCommand.isEnabled = false
        updateRemoteState()
    }

    private func updateRemoteState() {
        let c = MPRemoteCommandCenter.shared()
        switch repeatMode {
        case .off: c.changeRepeatModeCommand.currentRepeatType = .off
        case .all: c.changeRepeatModeCommand.currentRepeatType = .all
        case .one: c.changeRepeatModeCommand.currentRepeatType = .one
        }
        c.changeShuffleModeCommand.currentShuffleType = shuffle ? .items : .off
    }

    private func updateNowPlaying() {
        guard let t = current else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: t.title,
            MPMediaItemPropertyArtist: t.displayArtist,
            MPMediaItemPropertyAlbumTitle: t.album,
            MPMediaItemPropertyPlaybackDuration: clock.duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: clock.time,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? Double(rate) : 0.0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: Double(rate),
            // Always "audio": the app plays these as songs, and Control Center shows audio apps reliably.
            MPNowPlayingInfoPropertyMediaType: NSNumber(value: MPNowPlayingInfoMediaType.audio.rawValue),
            MPNowPlayingInfoPropertyPlaybackQueueIndex: index,
            MPNowPlayingInfoPropertyPlaybackQueueCount: queue.count,
        ]
        if let img = ArtworkCache.shared.cached(t.id) {
            info[MPMediaItemPropertyArtwork] = NowPlayingArt.make(img)
            MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        } else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = info
            if t.hasArtwork {
                let id = t.id
                Task {
                    if await ArtworkCache.shared.image(for: t) != nil, self.current?.id == id { self.updateNowPlaying() }
                }
            }
        }
    }

    private func updateNowPlayingTime() {
        guard var info = MPNowPlayingInfoCenter.default().nowPlayingInfo else { updateNowPlaying(); return }
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = clock.time
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? Double(rate) : 0.0
        info[MPMediaItemPropertyPlaybackDuration] = clock.duration
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    // MARK: Resume where you left off

    private struct SavedState: Codable {
        var queue: [String]
        var original: [String]
        var index: Int
        var time: Double
        var repeatMode: RepeatMode
        var shuffle: Bool
        var rate: Float
    }

    private func saveState(force: Bool) {
        if !force && Date().timeIntervalSince(lastSave) < 5 { return }
        lastSave = Date()
        let s = SavedState(queue: queue.map(\.id), original: original.map(\.id), index: index, time: clock.time,
                           repeatMode: repeatMode, shuffle: shuffle, rate: rate)
        if let data = try? JSONEncoder().encode(s) {
            UserDefaults.standard.set(data, forKey: "playerState")
        }
    }

    private func restore() {
        guard let data = UserDefaults.standard.data(forKey: "playerState"),
              let s = try? JSONDecoder().decode(SavedState.self, from: data) else { return }
        repeatMode = s.repeatMode
        shuffle = s.shuffle
        rate = s.rate
        avPlayer.defaultRate = s.rate
        let lib = Library.shared
        let savedCurrent = s.queue.indices.contains(s.index) ? s.queue[s.index] : nil
        queue = lib.lookup(s.queue)
        original = lib.lookup(s.original)
        guard !queue.isEmpty else { return }
        if let id = savedCurrent, let i = queue.firstIndex(where: { $0.id == id }) {
            index = i
            if let t = current {
                clock.time = s.time
                clock.duration = t.duration
                updateNowPlaying()
            }
        } else {
            index = 0
            clock.time = 0
        }
        // The file itself is opened the first time play is pressed.
    }

}

enum NowPlayingArt {
    /// Built outside the main actor: the system calls the closure on a background thread.
    static func make(_ img: UIImage) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: img.size) { _ in img }
    }
}

/// Makes sure a file is on the phone before it is played (downloads it from iCloud Drive if needed).
enum FileAccess {
    static func ensureLocal(_ url: URL) async -> Bool {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: ensureLocalSync(url))
            }
        }
    }

    private static func isCurrent(_ url: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        guard let v = try? url.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]),
              v.isUbiquitousItem == true, let status = v.ubiquitousItemDownloadingStatus else { return true }
        return status == .current || status == .downloaded
    }

    private static func ensureLocalSync(_ url: URL) -> Bool {
        if isCurrent(url) { return true }
        FolderLog.append("Downloading \(url.lastPathComponent) from iCloud")
        try? FileManager.default.startDownloadingUbiquitousItem(at: url)
        var err: NSError?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &err) { _ in }
        if isCurrent(url) { return true }
        // Reading the first byte makes iOS fetch a file that is only listed.
        if let h = try? FileHandle(forReadingFrom: url) {
            _ = try? h.read(upToCount: 1)
            try? h.close()
        }
        if isCurrent(url) { return true }
        // Some providers finish the download a little after the coordinated read returns.
        for _ in 0..<240 {
            Thread.sleep(forTimeInterval: 0.5)
            if isCurrent(url) { return true }
        }
        return FileManager.default.fileExists(atPath: url.path)
    }

    static func prefetch(_ url: URL) {
        // Fully downloaded ahead of time, so the next song starts without a silent wait
        // (iOS may suspend an app that is silent in the background).
        DispatchQueue.global(qos: .utility).async {
            if !isCurrent(url) { _ = ensureLocalSync(url) }
        }
    }
}
