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

    static let rates: [Float] = [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0]

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

    var current: Track? { queue.indices.contains(index) ? queue[index] : nil }
    var upNext: [Track] { index + 1 < queue.count ? Array(queue[(index + 1)...]) : [] }

    private init() {
        avPlayer.actionAtItemEnd = .none
        avPlayer.allowsExternalPlayback = true
        configureSession()
        observePlayer()
        observeSystem()
        setupRemoteCommands()
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
        let i = list.firstIndex(of: track) ?? 0
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
        if let cur = current, let o = original.firstIndex(of: cur) {
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
        original.removeAll { removed.contains($0.id) && $0 != current }
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
        activateSession()
        avPlayer.defaultRate = rate
        avPlayer.playImmediately(atRate: rate)
        if let t = current, countedPlay != t.id {
            countedPlay = t.id
            UserStore.shared.markPlayed(t.id)
        }
    }

    func pause() {
        avPlayer.pause()
        saveState(force: true)
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
        avPlayer.pause()
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
                index = queue.firstIndex(of: cur) ?? 0
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
        rate = r
        avPlayer.defaultRate = r
        if isPlaying { avPlayer.rate = r }
        updateNowPlaying()
        saveState(force: true)
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
            item.audioTimePitchAlgorithm = .spectral
            self.watch(item, token: token)
            self.avPlayer.replaceCurrentItem(with: item)
            if seconds > 0.5 {
                _ = await self.avPlayer.seek(to: CMTime(seconds: seconds, preferredTimescale: 600),
                                             toleranceBefore: .zero, toleranceAfter: .zero)
            }
            guard token == self.loadToken else { return }
            if autoplay { self.resume() }
            if track.isPlaceholder { Library.shared.refresh(track.id) }
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

    private func itemStatusChanged(_ status: AVPlayerItem.Status, duration: CMTime, token: Int) {
        guard token == loadToken, let t = current else { return }
        switch status {
        case .readyToPlay:
            failures = 0
            let d = CMTimeGetSeconds(duration)
            if d.isFinite && d > 0 { clock.duration = d }
            updateNowPlaying()
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
            avPlayer.pause()
        }
    }

    private func itemEnded() {
        if sleepAtTrackEnd {
            sleepAtTrackEnd = false
            avPlayer.pause()
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
                avPlayer.pause()
                seek(to: 0)
            }
        }
    }

    private func prefetchNext() {
        guard index + 1 < queue.count, let url = Library.shared.url(for: queue[index + 1]) else { return }
        FileAccess.prefetch(url)
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
                Task { @MainActor in self?.pause() }
            }
        }
        nc.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.configureSession() }
        }
        nc.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.inBackground = true
                self.setSurfacesAttached(false)
                self.saveState(force: true)
            }
        }
        nc.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
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
            resumeAfterInterruption = isPlaying
            isPlaying = false
            saveState(force: true)
        case .ended:
            if resumeAfterInterruption && options.contains(.shouldResume) { resume() }
            resumeAfterInterruption = false
        @unknown default:
            break
        }
    }

    private func configureSession() {
        let s = AVAudioSession.sharedInstance()
        try? s.setCategory(.playback, mode: .default, options: [])
    }

    private func activateSession() {
        try? AVAudioSession.sharedInstance().setActive(true)
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
            MPNowPlayingInfoPropertyMediaType: NSNumber(value: (t.isVideo ? MPNowPlayingInfoMediaType.video : .audio).rawValue),
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
        if isDataless(url.path) { return false }
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
        DispatchQueue.global(qos: .utility).async {
            if !isCurrent(url) { try? FileManager.default.startDownloadingUbiquitousItem(at: url) }
        }
    }
}
