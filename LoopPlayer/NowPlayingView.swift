import SwiftUI

struct NowPlayingView: View {
    @EnvironmentObject var player: Player
    @EnvironmentObject var store: UserStore
    @Environment(\.dismiss) private var dismiss
    @State private var showQueue = false
    @State private var videoFullScreen = false
    @State private var pickIDs: TrackIDs?
    @State private var info: Track?
    @State private var seekFlash: String?
    @State private var showSpeed = false

    var body: some View {
        GeometryReader { geo in
            let t = player.current
            let artSide = min(geo.size.width - 48, geo.size.height * 0.42)
            ZStack {
                Backdrop(track: t)
                VStack(spacing: 0) {
                    topBar(t)
                    Spacer(minLength: 8)
                    media(t, side: artSide, width: geo.size.width - 32)
                    Spacer(minLength: 12)
                    titleRow(t)
                        .padding(.horizontal, 24)
                    Scrubber(player: player, loopA: player.loopA, loopB: player.loopB)
                        .padding(.horizontal, 24)
                        .padding(.top, 14)
                    controls
                        .padding(.horizontal, 20)
                        .padding(.top, 6)
                    bottomBar(t)
                        .padding(.horizontal, 26)
                        .padding(.top, 14)
                        .padding(.bottom, max(geo.safeAreaInsets.bottom, 12))
                }
            }
        }
        .preferredColorScheme(.dark)
        .presentationDragIndicator(.visible)
        .sheet(isPresented: $showQueue) { QueueView() }
        .sheet(isPresented: $showSpeed) { SpeedSheet() }
        .sheet(item: $pickIDs) { box in PlaylistPickerView(ids: box.ids) }
        .sheet(item: $info) { t in TrackInfoView(track: t) }
        .fullScreenCover(isPresented: $videoFullScreen) { FullScreenVideoView() }
        .overlay(alignment: .top) { ToastOverlay() }
        .onChange(of: player.current == nil) { gone in if gone { dismiss() } }
    }

    private func topBar(_ t: Track?) -> some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "chevron.down").font(.title3.weight(.semibold)).frame(width: 44, height: 44)
            }
            Spacer()
            VStack(spacing: 2) {
                Text("PLAYING").font(.caption2.weight(.bold)).foregroundColor(Theme.dim)
                Text("\(player.index + 1) of \(player.queue.count)").font(.caption.weight(.semibold))
            }
            Spacer()
            Menu {
                if let t {
                    Button { pickIDs = TrackIDs(ids: [t.id]) } label: { Label("Add to Playlist…", systemImage: "music.note.list") }
                    Button { store.toggleFavorite(t.id) } label: {
                        store.isFavorite(t.id) ? Label("Remove from Favorites", systemImage: "heart.slash") : Label("Add to Favorites", systemImage: "heart")
                    }
                    Button { info = t } label: { Label("File Info", systemImage: "info.circle") }
                    if t.isVideo {
                        Button { videoFullScreen = true } label: { Label("Full Screen Video", systemImage: "arrow.up.left.and.arrow.down.right") }
                    }
                }
                Button(role: .destructive) { player.stop(); dismiss() } label: { Label("Stop and Clear Queue", systemImage: "stop.fill") }
            } label: {
                Image(systemName: "ellipsis").font(.title3.weight(.semibold)).frame(width: 44, height: 44)
            }
        }
        .foregroundColor(.white)
        .padding(.horizontal, 12)
        .padding(.top, 10)
    }

    @ViewBuilder
    private func media(_ t: Track?, side: CGFloat, width: CGFloat) -> some View {
        ZStack {
            if t?.isVideo == true {
                VideoSurface()
                    .frame(width: width, height: width * 9 / 16)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            } else {
                ArtworkView(track: t, size: side, corner: 14)
                    .shadow(color: .black.opacity(0.7), radius: 24, y: 12)
                    .scaleEffect(player.isPlaying ? 1 : 0.88)
                    .animation(.spring(response: 0.45, dampingFraction: 0.75), value: player.isPlaying)
            }
            // Double tap left / right side to jump 10 seconds, like YouTube.
            HStack(spacing: 0) {
                Color.clear.contentShape(Rectangle()).onTapGesture(count: 2) { jump(-10) }
                Color.clear.contentShape(Rectangle()).onTapGesture(count: 2) { jump(10) }
            }
            if let seekFlash {
                Text(seekFlash)
                    .font(.headline)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.black.opacity(0.6), in: Capsule())
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }
            BufferingIndicator(preparing: player.isPreparing)
            if t?.isVideo == true {
                Button { videoFullScreen = true } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.subheadline.weight(.bold))
                        .foregroundColor(.white)
                        .padding(9)
                        .background(.black.opacity(0.55), in: Circle())
                }
                .padding(10)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            }
        }
        .frame(width: t?.isVideo == true ? width : side, height: t?.isVideo == true ? width * 9 / 16 : side)
        .gesture(DragGesture(minimumDistance: 30).onEnded { v in
            if abs(v.translation.width) > abs(v.translation.height) {
                if v.translation.width < -50 { player.next() } else if v.translation.width > 50 { player.previous() }
            }
        })
    }

    private func jump(_ s: Double) {
        player.skip(by: s)
        withAnimation { seekFlash = s > 0 ? "+\(Int(s)) s" : "\(Int(s)) s" }
        let mark = seekFlash
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
            if seekFlash == mark { withAnimation { seekFlash = nil } }
        }
    }

    private func titleRow(_ t: Track?) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(t?.title ?? "Not Playing")
                    .font(.title2.weight(.bold))
                    .lineLimit(1)
                Text(t?.displayArtist ?? "")
                    .font(.title3)
                    .foregroundColor(Theme.dim)
                    .lineLimit(1)
            }
            Spacer()
            if let t {
                Button { store.toggleFavorite(t.id) } label: {
                    Image(systemName: store.isFavorite(t.id) ? "heart.fill" : "heart")
                        .font(.title2)
                        .foregroundColor(store.isFavorite(t.id) ? Theme.accent : .white)
                        .frame(width: 44, height: 44)
                }
            }
        }
    }

    private var controls: some View {
        HStack {
            Button { player.toggleShuffle() } label: {
                Image(systemName: "shuffle")
                    .font(.title3.weight(.semibold))
                    .foregroundColor(player.shuffle ? Theme.accent : .white.opacity(0.75))
                    .frame(width: 48, height: 48)
            }
            Spacer()
            Button { player.previous() } label: {
                Image(systemName: "backward.fill").font(.system(size: 30)).frame(width: 60, height: 60)
            }
            Spacer()
            Button { player.togglePlay() } label: {
                ZStack {
                    Circle().fill(.white).frame(width: 74, height: 74)
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 32, weight: .bold))
                        .foregroundColor(.black)
                        .offset(x: player.isPlaying ? 0 : 2)
                }
            }
            Spacer()
            Button { player.next() } label: {
                Image(systemName: "forward.fill").font(.system(size: 30)).frame(width: 60, height: 60)
            }
            Spacer()
            Button { player.cycleRepeat() } label: {
                Image(systemName: player.repeatMode.symbol)
                    .font(.title3.weight(.semibold))
                    .foregroundColor(player.repeatMode == .off ? .white.opacity(0.75) : Theme.accent)
                    .frame(width: 48, height: 48)
                    .overlay(alignment: .bottom) {
                        if player.repeatMode != .off {
                            Circle().fill(Theme.accent).frame(width: 4, height: 4).offset(y: -4)
                        }
                    }
            }
        }
        .foregroundColor(.white)
        .buttonStyle(.plain)
    }

    private func bottomBar(_ t: Track?) -> some View {
        HStack {
            Button { showSpeed = true } label: {
                Text(player.rate == 1 ? "1×" : String(format: "%g×", player.rate))
                    .font(.subheadline.weight(.bold))
                    .foregroundColor(player.rate == 1 ? .white.opacity(0.8) : Theme.accent)
                    .frame(minWidth: 44, minHeight: 36)
            }
            Spacer()
            ABLoopButton()
            Spacer()
            SleepMenu()
            Spacer()
            AirPlayButton(video: t?.isVideo == true)
                .frame(width: 36, height: 36)
            Spacer()
            Button { showQueue = true } label: {
                Image(systemName: "list.bullet")
                    .font(.title3.weight(.semibold))
                    .frame(width: 44, height: 36)
            }
            .foregroundColor(.white.opacity(0.85))
        }
    }
}

struct BufferingIndicator: View {
    let preparing: Bool
    @EnvironmentObject var clock: PlaybackClock

    var body: some View {
        if preparing || clock.buffering {
            ProgressView().scaleEffect(1.4).tint(.white).allowsHitTesting(false)
        }
    }
}

struct SleepMenu: View {
    @EnvironmentObject var player: Player

    var body: some View {
        Menu {
            if player.sleepEnd != nil || player.sleepAtTrackEnd {
                Button(role: .destructive) { player.cancelSleep() } label: { Label("Turn Off Timer", systemImage: "xmark") }
            }
            Button { player.setSleepAtTrackEnd() } label: { Label("End of This Song", systemImage: "music.note") }
            ForEach([5, 10, 15, 30, 45, 60, 90, 120], id: \.self) { m in
                Button("\(m) minutes") { player.setSleep(minutes: m) }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "moon.zzz.fill")
                if let end = player.sleepEnd {
                    SleepCountdown(end: end)
                } else if player.sleepAtTrackEnd {
                    Text("End").font(.caption.weight(.bold))
                }
            }
            .font(.title3)
            .foregroundColor(player.sleepEnd != nil || player.sleepAtTrackEnd ? Theme.accent : .white.opacity(0.85))
            .frame(minWidth: 44, minHeight: 36)
        }
    }
}

struct SleepCountdown: View {
    let end: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            Text(formatTime(max(0, end.timeIntervalSince(ctx.date))))
                .font(.caption.monospacedDigit().weight(.bold))
        }
    }
}

/// A-B loop: tap at the start of a part, tap at its end, and that part repeats. Tap again to stop.
struct ABLoopButton: View {
    @EnvironmentObject var player: Player

    var body: some View {
        Button { player.abTap() } label: {
            HStack(spacing: 1) {
                Text("A").foregroundColor(player.loopA != nil ? Theme.accent : .white.opacity(0.85))
                Text("-").foregroundColor(.white.opacity(0.6))
                Text("B").foregroundColor(player.loopB != nil ? Theme.accent : .white.opacity(0.85))
            }
            .font(.subheadline.weight(.heavy))
            .padding(.horizontal, 8)
            .frame(minWidth: 44, minHeight: 32)
            .background(player.loopB != nil ? Theme.accent.opacity(0.22) : .clear, in: Capsule())
        }
        .accessibilityLabel(player.loopA == nil ? "Set loop start A" : (player.loopB == nil ? "Set loop end B" : "Turn off A-B loop"))
    }
}

/// Fine speed control, and whether the pitch moves with the speed.
struct SpeedSheet: View {
    @EnvironmentObject var player: Player
    @Environment(\.dismiss) private var dismiss
    @State private var value: Float = 1

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(spacing: 10) {
                        Text(String(format: "%.2f×", value))
                            .font(.system(size: 40, weight: .bold).monospacedDigit())
                            .foregroundColor(value == 1 ? .white : Theme.accent)
                        HStack(spacing: 12) {
                            stepButton("minus", -0.05)
                            Slider(value: $value, in: Player.rateRange, step: 0.05, onEditingChanged: { editing in
                                if !editing { player.setRate(value) }
                            })
                            .tint(Theme.accent)
                            stepButton("plus", 0.05)
                        }
                        HStack(spacing: 8) {
                            ForEach(Player.rates, id: \.self) { r in
                                Button {
                                    value = r
                                    player.setRate(r)
                                } label: {
                                    Text(String(format: "%g", r))
                                        .font(.caption.weight(.bold))
                                        .frame(maxWidth: .infinity, minHeight: 30)
                                        .background(abs(value - r) < 0.001 ? Theme.accent.opacity(0.3) : Theme.surface2,
                                                    in: RoundedRectangle(cornerRadius: 8))
                                        .foregroundColor(.white)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .padding(.vertical, 6)
                    .listRowBackground(Theme.surface)
                } header: {
                    Text("Speed")
                }

                Section {
                    Picker("Pitch", selection: Binding(get: { player.keepPitch }, set: { player.setKeepPitch($0) })) {
                        Text("Keep pitch").tag(true)
                        Text("Change pitch").tag(false)
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Theme.surface)
                } header: {
                    Text("Pitch")
                } footer: {
                    Text(player.keepPitch
                         ? "Keep pitch: slower or faster, but the voice and notes stay the same (time-stretch)."
                         : "Change pitch: like a tape or a slowed video. Slower sounds deeper, faster sounds higher.")
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Theme.bg)
            .navigationTitle("Playback Speed")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Reset") { value = 1; player.setRate(1) }
                }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
        .preferredColorScheme(.dark)
        .onAppear { value = player.rate }
    }

    private func stepButton(_ icon: String, _ delta: Float) -> some View {
        Button {
            value = min(max(((value + delta) * 100).rounded() / 100, Player.rateRange.lowerBound), Player.rateRange.upperBound)
            player.setRate(value)
        } label: {
            Image(systemName: icon)
                .font(.headline)
                .frame(width: 36, height: 36)
                .background(Theme.surface2, in: Circle())
                .foregroundColor(.white)
        }
        .buttonStyle(.plain)
    }
}

/// Seek bar. It watches only the clock, so the rest of the screen does not redraw while a song plays.
struct Scrubber: View {
    let player: Player
    var loopA: Double? = nil
    var loopB: Double? = nil
    @EnvironmentObject var clock: PlaybackClock
    @State private var dragValue: Double?

    var body: some View {
        let duration = max(clock.duration, 0.01)
        let value = dragValue ?? clock.time
        let fraction = min(1, max(0, value / duration))
        VStack(spacing: 6) {
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.18)).frame(height: dragValue == nil ? 5 : 9)
                    if let a = loopA {
                        let fa = min(1, max(0, a / duration))
                        let fb = loopB.map { min(1, max(0, $0 / duration)) } ?? fa
                        Rectangle().fill(Theme.accent.opacity(0.45))
                            .frame(width: max(3, g.size.width * (fb - fa)), height: 13)
                            .offset(x: g.size.width * fa)
                    }
                    Capsule().fill(dragValue == nil ? Color.white : Theme.accent)
                        .frame(width: max(5, g.size.width * fraction), height: dragValue == nil ? 5 : 9)
                    Circle().fill(.white)
                        .frame(width: dragValue == nil ? 12 : 20, height: dragValue == nil ? 12 : 20)
                        .offset(x: g.size.width * fraction - (dragValue == nil ? 6 : 10))
                        .shadow(radius: 3)
                }
                .frame(height: 24)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        let f = min(1, max(0, v.location.x / max(g.size.width, 1)))
                        dragValue = f * duration
                    }
                    .onEnded { _ in
                        if let d = dragValue { player.seek(to: d) }
                        dragValue = nil
                    })
                .animation(.easeOut(duration: 0.15), value: dragValue == nil)
            }
            .frame(height: 24)
            HStack {
                Text(formatTime(value))
                Spacer()
                Text("-" + formatTime(max(0, clock.duration - value)))
            }
            .font(.caption.monospacedDigit())
            .foregroundColor(Theme.dim)
        }
    }
}

struct Backdrop: View {
    let track: Track?
    @State private var image: UIImage?

    var body: some View {
        // The image sits in an overlay so its fill size can never widen the screen.
        Color.black
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .blur(radius: 60)
                        .opacity(0.55)
                }
            }
            .overlay {
                LinearGradient(colors: [.black.opacity(0.15), .black.opacity(0.65), .black], startPoint: .top, endPoint: .bottom)
            }
            .clipped()
            .ignoresSafeArea()
        .task(id: (track?.id ?? "") + (track?.hasArtwork == true ? "1" : "0")) {
            guard let track else { image = nil; return }
            let img = await ArtworkCache.shared.image(for: track)
            withAnimation(.easeInOut(duration: 0.4)) { image = img }
        }
    }
}

// MARK: - Queue

struct QueueView: View {
    @EnvironmentObject var player: Player
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if let t = player.current {
                    Section {
                        HStack(spacing: 12) {
                            ArtworkView(track: t, size: 50, corner: 6)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(t.title).font(.headline).foregroundColor(Theme.accent).lineLimit(1)
                                Text(t.displayArtist).font(.subheadline).foregroundColor(Theme.dim).lineLimit(1)
                            }
                            Spacer()
                            PlayingBars(animating: player.isPlaying)
                        }
                        .listRowBackground(Theme.surface)
                    } header: {
                        Text("Now Playing")
                    }
                }
                Section {
                    HStack(spacing: 10) {
                        modeButton("shuffle", on: player.shuffle) { player.toggleShuffle() }
                        modeButton(player.repeatMode.symbol, on: player.repeatMode != .off) { player.cycleRepeat() }
                    }
                    .listRowBackground(Theme.bg)
                    .listRowSeparator(.hidden)
                    let next = player.upNext
                    if next.isEmpty {
                        Text(player.repeatMode == .all ? "The queue starts again from the top." : "Nothing up next.")
                            .foregroundColor(Theme.dim)
                            .listRowBackground(Theme.bg)
                    }
                    ForEach(Array(next.enumerated()), id: \.offset) { i, t in
                        HStack(spacing: 12) {
                            ArtworkView(track: t, size: 42, corner: 5)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(t.title).lineLimit(1)
                                Text(t.displayArtist).font(.caption).foregroundColor(Theme.dim).lineLimit(1)
                            }
                            Spacer()
                            Text(formatTime(t.duration)).font(.caption.monospacedDigit()).foregroundColor(Theme.dim)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { player.jump(to: player.index + 1 + i) }
                        .listRowBackground(Theme.bg)
                    }
                    .onMove { player.moveUpNext(from: $0, to: $1) }
                    .onDelete { player.removeUpNext(at: $0) }
                } header: {
                    HStack {
                        Text("Up Next")
                        Spacer()
                        if !player.upNext.isEmpty {
                            Button("Clear") { player.clearUpNext() }.font(.caption.weight(.semibold))
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Theme.bg)
            .navigationTitle("Queue")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) { EditButton() }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
        .preferredColorScheme(.dark)
    }

    private func modeButton(_ icon: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.headline)
                .frame(maxWidth: .infinity, minHeight: 40)
                .background(on ? Theme.accent.opacity(0.25) : Theme.surface2, in: RoundedRectangle(cornerRadius: 10))
                .foregroundColor(on ? Theme.accent : .white)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Full screen video

struct FullScreenVideoView: View {
    @EnvironmentObject var player: Player
    @Environment(\.dismiss) private var dismiss
    @State private var controls = true
    @State private var fill = false
    @State private var hideTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VideoSurface(fill: fill)
                .ignoresSafeArea()
            HStack(spacing: 0) {
                Color.clear.contentShape(Rectangle())
                    .onTapGesture(count: 2) { player.skip(by: -10) }
                    .onTapGesture { toggleControls() }
                Color.clear.contentShape(Rectangle())
                    .onTapGesture(count: 2) { player.skip(by: 10) }
                    .onTapGesture { toggleControls() }
            }
            if controls {
                VStack {
                    HStack {
                        Button { dismiss() } label: {
                            Image(systemName: "xmark").font(.title3.weight(.semibold)).frame(width: 44, height: 44)
                        }
                        Text(player.current?.title ?? "").font(.headline).lineLimit(1)
                        Spacer()
                        Button { fill.toggle() } label: {
                            Image(systemName: fill ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                                .font(.title3).frame(width: 44, height: 44)
                        }
                        AirPlayButton(video: true).frame(width: 36, height: 36)
                    }
                    Spacer()
                    HStack(spacing: 46) {
                        Button { player.previous() } label: { Image(systemName: "backward.fill").font(.title) }
                        Button { player.togglePlay() } label: {
                            Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 44))
                        }
                        Button { player.next() } label: { Image(systemName: "forward.fill").font(.title) }
                        Button { player.cycleRepeat() } label: {
                            Image(systemName: player.repeatMode.symbol).font(.title2)
                                .foregroundColor(player.repeatMode == .off ? .white : Theme.accent)
                        }
                    }
                    Spacer()
                    Scrubber(player: player)
                }
                .padding()
                .foregroundColor(.white)
                .background(
                    LinearGradient(colors: [.black.opacity(0.7), .clear, .black.opacity(0.7)], startPoint: .top, endPoint: .bottom)
                        .ignoresSafeArea()
                        .allowsHitTesting(false)
                )
                .transition(.opacity)
            }
        }
        .statusBarHidden(!controls)
        .onAppear { scheduleHide() }
        .onChange(of: player.current?.isVideo ?? false) { isVideo in if !isVideo { dismiss() } }
    }

    private func toggleControls() {
        withAnimation { controls.toggle() }
        if controls { scheduleHide() }
    }

    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if !Task.isCancelled && player.isPlaying { withAnimation { controls = false } }
        }
    }
}
