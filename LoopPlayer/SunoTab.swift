import SwiftUI
import WebKit
import Combine
import AVFoundation

// The Suno tab (1.3.0): suno.com itself, like the Suno Legacy app, inside Loop Player.
// It shares the web data with Loop Player's Suno sign-in (WKWebsiteDataStore.default()), so
// signing in here or in Settings > Suno signs in both. Built from Suno Legacy's web tab without
// its Telegram sync.

@MainActor
final class SunoWebModel: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler, WKDownloadDelegate {
    static let shared = SunoWebModel()

    let webView: WKWebView
    @Published var failed = false
    @Published var progress: Double = 0
    @Published var loading = false
    @Published var popup: WKWebView?
    @Published var note: String?
    private var bag = Set<AnyCancellable>()
    private var downloadFiles: [ObjectIdentifier: URL] = [:]
    private var started = false
    private var signingIn = false
    /// True while Suno's page is playing, so Loop Player's own player and the page don't play at once.
    private var pagePlaying = false

    private static func log(_ s: String) {
        FolderLog.append("Suno tab: \(s)")
        test(s)
    }

    // Automatic test only (TEST_SUNO_TAB_OUT): what the tab did, and how far the page's song played.
    private static var testLines: [String] = []
    private static func test(_ s: String) {
        guard let out = ProcessInfo.processInfo.environment["TEST_SUNO_TAB_OUT"] else { return }
        testLines.append(s)
        try? testLines.joined(separator: "\n").write(toFile: out, atomically: true, encoding: .utf8)
    }
    private var testTimer: Timer?

    /// Tells the app when the page starts or stops playing (any audio or video element).
    private static let mediaScript = """
    (function(){
      function post(m){ try { window.webkit.messageHandlers.sunoMedia.postMessage(m); } catch(e){} }
      document.addEventListener('play', function(){ post('play'); }, true);
      document.addEventListener('pause', function(){ post('pause'); }, true);
      document.addEventListener('ended', function(){ post('pause'); }, true);
    })();
    """

    override init() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.allowsInlineMediaPlayback = true
        config.allowsPictureInPictureMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        // The Opus decoder (MIT licence, see THIRD_PARTY.md): Suno's songs are Opus in MP4,
        // which iOS 16 can't play by itself.
        if let url = Bundle.main.url(forResource: "opus-decoder.min", withExtension: "js"),
           let library = try? String(contentsOf: url) {
            config.userContentController.addUserScript(WKUserScript(source: library, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
        config.userContentController.addUserScript(WKUserScript(source: SunoWebShim.script, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        config.userContentController.addUserScript(WKUserScript(source: SunoWebModel.mediaScript, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        webView = WKWebView(frame: .zero, configuration: config)
        super.init()
        config.userContentController.add(self, name: "jsError")
        config.userContentController.add(self, name: "saveFile")
        config.userContentController.add(self, name: "sunoMedia")
        style(webView)
        webView.allowsBackForwardNavigationGestures = true
        webView.scrollView.indicatorStyle = .white
        let refresh = UIRefreshControl()
        refresh.tintColor = .white
        refresh.addTarget(self, action: #selector(pulled), for: .valueChanged)
        webView.scrollView.refreshControl = refresh
        webView.publisher(for: \.estimatedProgress)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.progress = $0 }
            .store(in: &bag)
        // Loop Player starts playing: pause Suno's page.
        Player.shared.$isPlaying
            .removeDuplicates()
            .sink { [weak self] playing in
                guard let self, playing, self.pagePlaying else { return }
                self.pausePage()
            }
            .store(in: &bag)
    }

    /// Loads Suno the first time the tab is opened (after the kept sign-in is back in WebKit).
    func startIfNeeded() {
        guard !started else { return }
        started = true
        SunoWebModel.test("tab opened")
        if ProcessInfo.processInfo.environment["TEST_SUNO_TAB_OUT"] != nil {
            testTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    let js = "var m=[].slice.call(document.querySelectorAll('audio,video')); m.map(function(x){return (x.paused?'paused ':'playing ')+x.currentTime.toFixed(1)}).join(',') || 'no media'"
                    self?.webView.evaluateJavaScript(js) { r, _ in SunoWebModel.test("media state: \(r as? String ?? "?")") }
                }
            }
        }
        // Suno's songs keep playing with the silent switch on and in the background.
        if !Player.shared.isPlaying {
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try? AVAudioSession.sharedInstance().setActive(true)
        }
        Task {
            await SunoAuth.shared.restoreSession()
            home()
        }
    }

    private var autoplayClip: String?

    /// Opens a song in the Suno tab and starts it (used when Loop Player's own player can't play it).
    func playSong(_ clip: String) {
        started = true
        failed = false
        popup = nil
        autoplayClip = clip
        SunoWebModel.log("playing \(clip) here")
        UserDefaults.standard.set(4, forKey: "tab")
        webView.load(URLRequest(url: URL(string: "https://suno.com/song/\(clip)")!))
    }

    /// Taps the song page's own Play button (tries for a few seconds while the page builds).
    private func autoplay() {
        let js = """
        var b = document.querySelector('button[aria-label="Play"], button[aria-label="Play song"]');
        if (b) { b.click(); return 'clicked'; }
        return 'none';
        """
        Task {
            for _ in 0..<12 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if pagePlaying { break }
                if let r = try? await webView.callAsyncJavaScript(js, arguments: [:], in: nil, contentWorld: .page) as? String, r == "clicked" {
                    SunoWebModel.log("pressed Play on the song page")
                    break
                }
            }
        }
    }

    func home() {
        failed = false
        let test = ProcessInfo.processInfo.environment["TEST_SUNO_TAB_URL"].flatMap { URL(string: $0) }
        webView.load(URLRequest(url: test ?? URL(string: "https://suno.com")!))
    }

    func reload() {
        failed = false
        if webView.url == nil { home() } else { webView.reload() }
    }

    @objc private func pulled() { reload() }

    /// Opens the Suno link that was copied.
    func openCopiedLink() {
        let text = UIPasteboard.general.url?.absoluteString ?? UIPasteboard.general.string ?? ""
        guard let link = SunoWebModel.sunoLink(in: text) else {
            say("No Suno link copied. Copy a song or playlist link first.")
            return
        }
        started = true
        failed = false
        popup = nil
        say("Opening the copied Suno link")
        webView.load(URLRequest(url: link))
    }

    static func sunoLink(in text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var found: [URL] = []
        if let d = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
            found = d.matches(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)).compactMap { $0.url }
        }
        if found.isEmpty, let plain = URL(string: trimmed) { found = [plain] }
        return found.first { u in
            guard let h = u.host?.lowercased(), ["http", "https"].contains(u.scheme?.lowercased() ?? "") else { return false }
            return h == "suno.com" || h.hasSuffix(".suno.com") || h == "suno.ai" || h.hasSuffix(".suno.ai")
        }
    }

    private func say(_ text: String) {
        note = text
        Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if note == text { note = nil }
        }
    }

    private func pausePage() {
        webView.evaluateJavaScript("document.querySelectorAll('audio,video').forEach(function(m){ try { m.pause(); } catch(e){} }); 1", completionHandler: nil)
        pagePlaying = false
    }

    private func style(_ view: WKWebView) {
        view.customUserAgent = SunoWebShim.userAgent
        view.navigationDelegate = self
        view.uiDelegate = self
        view.overrideUserInterfaceStyle = .dark
        view.isOpaque = false
        view.backgroundColor = .black
        view.scrollView.backgroundColor = .black
        view.underPageBackgroundColor = .black
    }

    nonisolated func userContentController(_ uc: WKUserContentController, didReceive message: WKScriptMessage) {
        let name = message.name
        let body = message.body
        Task { @MainActor in self.handle(name, body) }
    }

    private func handle(_ name: String, _ body: Any) {
        switch name {
        case "sunoMedia":
            SunoWebModel.test("media \(body)")
            let playing = (body as? String) == "play"
            pagePlaying = playing
            // Suno's page starts playing: pause Loop Player's own player.
            if playing, Player.shared.isPlaying { Player.shared.pause() }
        case "saveFile":
            if let d = body as? [String: Any] { receiveFile(d) }
        default:
            // Only problems go to the Folder Log (the page reports a lot).
            if let s = body as? String, s.contains("rejected") || s.contains("threw") || s.hasPrefix("promise:") {
                SunoWebModel.log(String(s.prefix(200)))
            }
        }
    }

    // MARK: Sign-in shared with Settings > Suno

    private func isSignInPage(_ url: URL?) -> Bool {
        guard let h = url?.host?.lowercased() else { return false }
        return h == "auth.suno.com" || h.hasSuffix("clerk.suno.com") || h.hasSuffix("accounts.google.com")
            || h.hasSuffix("appleid.apple.com") || h.hasSuffix("discord.com") || h.hasSuffix("facebook.com")
            || h.hasSuffix("login.microsoftonline.com") || h.hasSuffix("login.live.com")
    }

    private func isSunoPage(_ url: URL?) -> Bool {
        guard let h = url?.host?.lowercased() else { return false }
        return h == "suno.com" || h == "www.suno.com"
    }

    /// Asks auth.suno.com (same as Settings > Suno) who is signed in, and keeps Loop Player's
    /// sign-in in step with the page.
    private func syncSignIn() {
        webView.callAsyncJavaScript(SunoAuth.sessionJS, arguments: ["mode": "who"], in: nil, in: .page) { result in
            guard case .success(let v) = result, let r = v as? String else { return }
            Task { @MainActor in
                let auth = SunoAuth.shared
                if r.hasPrefix("user:") {
                    let name = String(r.dropFirst(5))
                    if auth.user != name {
                        SunoWebModel.log("signed in as \(name)")
                        auth.setUser(name)
                    } else {
                        await auth.saveSession()
                    }
                } else if r == "none", auth.signedIn {
                    SunoWebModel.log("Suno's page shows no sign-in")
                }
            }
        }
    }

    /// Back on Suno after signing in (as in Suno Legacy): keep the sign-in at once, and if the
    /// page still shows "Log in" (it loaded before the sign-in cookies were in place), reload once.
    private func cameBackFromSignIn() {
        SunoWebModel.log("back on Suno after signing in")
        Task {
            await SunoAuth.shared.saveSession(force: true)
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            let check = "[].slice.call(document.querySelectorAll('button,a')).some(function(e){var t=(e.innerText||'').trim().toLowerCase();return t==='log in'||t==='sign in'||t==='sign up'})"
            if let r = try? await webView.evaluateJavaScript(check) as? Bool, r {
                SunoWebModel.log("page still says Log in; reloading once")
                webView.reload()
            }
        }
    }

    // MARK: Pages

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        if webView === self.webView { loading = true }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard webView === self.webView else { return }
        loading = false
        failed = false
        webView.scrollView.refreshControl?.endRefreshing()
        SunoWebModel.test("page \(webView.url?.host ?? "?")\(webView.url?.path ?? "")")
        if let clip = autoplayClip, webView.url?.path.contains(clip) == true {
            autoplayClip = nil
            autoplay()
        }
        if isSunoPage(webView.url) {
            if signingIn { signingIn = false; cameBackFromSignIn() }
            syncSignIn()
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if navigationAction.shouldPerformDownload { decisionHandler(.download); return }
        if navigationAction.targetFrame?.isMainFrame ?? false, let url = navigationAction.request.url {
            if isSignInPage(url) { signingIn = true }
            // A sign-in window that comes back to Suno is done: show that page here and close it.
            if let window = popup, webView === window, isSunoPage(url) {
                decisionHandler(.cancel)
                window.stopLoading()
                popup = nil
                Task {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    self.signingIn = true   // the page that loads now finishes the sign-in
                    self.webView.load(URLRequest(url: url))
                }
                return
            }
        }
        if let url = navigationAction.request.url, let scheme = url.scheme?.lowercased(),
           !["http", "https", "about", "blob", "data", "file"].contains(scheme) {
            UIApplication.shared.open(url)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        if let http = navigationResponse.response as? HTTPURLResponse,
           (http.value(forHTTPHeaderField: "Content-Disposition") ?? "").lowercased().hasPrefix("attachment") {
            decisionHandler(.download)
            return
        }
        let kind = navigationResponse.response.mimeType?.lowercased() ?? ""
        if navigationResponse.isForMainFrame && (kind.hasPrefix("audio/") || kind == "application/zip") {
            decisionHandler(.download)
            return
        }
        decisionHandler(navigationResponse.canShowMIMEType ? .allow : .download)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        if (error as NSError).code == NSURLErrorCancelled { return }
        SunoWebModel.log("page failed: \(error.localizedDescription)")
        if webView === self.webView { loading = false; failed = true; webView.scrollView.refreshControl?.endRefreshing() }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        let e = error as NSError
        if e.code == NSURLErrorCancelled || (e.domain == "WebKitErrorDomain" && e.code == 102) { return }
        SunoWebModel.log("page didn't open: \(error.localizedDescription)")
        if webView === self.webView { loading = false; failed = true; webView.scrollView.refreshControl?.endRefreshing() }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        SunoWebModel.log("page stopped; reloading")
        if webView === self.webView { reload() }
    }

    // MARK: Windows opened by the page (sign-in pop-ups)

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.navigationType == .linkActivated,
           let url = navigationAction.request.url, ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
            webView.load(navigationAction.request)
            return nil
        }
        let window = WKWebView(frame: .zero, configuration: configuration)
        style(window)
        popup = window
        return window
    }

    func webViewDidClose(_ webView: WKWebView) {
        if webView === popup { closePopup() }
    }

    func closePopup() {
        guard let window = popup else { return }
        window.stopLoading()
        popup = nil
        Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            self.reload()
        }
    }

    // MARK: JavaScript dialogs

    private func present(_ a: UIAlertController, otherwise: () -> Void) {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        var top = scene?.windows.first(where: { $0.isKeyWindow })?.rootViewController ?? scene?.windows.first?.rootViewController
        while let next = top?.presentedViewController { top = next }
        if let top { top.present(a, animated: true) } else { otherwise() }
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let a = UIAlertController(title: frame.request.url?.host, message: message, preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler() })
        present(a, otherwise: completionHandler)
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let a = UIAlertController(title: frame.request.url?.host, message: message, preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in completionHandler(false) })
        a.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler(true) })
        present(a, otherwise: { completionHandler(false) })
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
        let a = UIAlertController(title: frame.request.url?.host, message: prompt, preferredStyle: .alert)
        a.addTextField { $0.text = defaultText }
        a.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in completionHandler(nil) })
        a.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler(a.textFields?.first?.text) })
        present(a, otherwise: { completionHandler(nil) })
    }

    // Microphone for Suno's recorder: only suno.com, and iOS still asks.
    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        decisionHandler(origin.host.hasSuffix("suno.com") ? .prompt : .deny)
    }

    // MARK: Downloads and files the page builds, handed to the share sheet

    private var incoming: [String: (url: URL, handle: FileHandle)] = [:]

    private func receiveFile(_ body: [String: Any]) {
        guard let id = body["id"] as? String, let index = body["index"] as? Int, let total = body["total"] as? Int,
              let text = body["data"] as? String, let bytes = Data(base64Encoded: text) else { return }
        if index == 0 {
            var name = (body["name"] as? String ?? "download").replacingOccurrences(of: "/", with: "-")
            if name.isEmpty { name = "download" }
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = folder.appendingPathComponent(name)
            FileManager.default.createFile(atPath: file.path, contents: nil)
            guard let h = try? FileHandle(forWritingTo: file) else { return }
            incoming[id] = (file, h)
        }
        guard let entry = incoming[id] else { return }
        entry.handle.write(bytes)
        if index == total - 1 {
            try? entry.handle.close()
            incoming[id] = nil
            share(entry.url)
        }
    }

    private func share(_ file: URL) {
        let sheet = UIActivityViewController(activityItems: [file], applicationActivities: nil)
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        var top = scene?.windows.first(where: { $0.isKeyWindow })?.rootViewController
        while let next = top?.presentedViewController { top = next }
        guard let top else { return }
        sheet.popoverPresentationController?.sourceView = top.view
        sheet.popoverPresentationController?.sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.maxY - 40, width: 1, height: 1)
        top.present(sheet, animated: true)
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = self
    }

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                  suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent(suggestedFilename)
        downloadFiles[ObjectIdentifier(download)] = file
        completionHandler(file)
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let file = downloadFiles.removeValue(forKey: ObjectIdentifier(download)) else { return }
        share(file)
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        downloadFiles.removeValue(forKey: ObjectIdentifier(download))
        SunoWebModel.log("download failed: \(error.localizedDescription)")
    }
}

private struct SunoWebContainer: UIViewRepresentable {
    let webView: WKWebView
    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

private struct SunoPopupSheet: View {
    let webView: WKWebView
    let close: () -> Void

    var body: some View {
        NavigationStack {
            SunoWebContainer(webView: webView)
                .background(Theme.bg.ignoresSafeArea())
                .navigationTitle(webView.url?.host ?? "Sign in")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { close() } } }
        }
        .preferredColorScheme(.dark)
    }
}

/// Rounded on the left only, flat against the screen edge (iOS 16 has no UnevenRoundedRectangle).
private struct UnevenRoundedCorners: Shape {
    func path(in r: CGRect) -> Path {
        Path(UIBezierPath(roundedRect: r, byRoundingCorners: [.topLeft, .bottomLeft],
                          cornerRadii: CGSize(width: 12, height: 12)).cgPath)
    }
}

struct SunoTabView: View {
    @ObservedObject private var model = SunoWebModel.shared
    let active: Bool

    var body: some View {
        ZStack(alignment: .top) {
            Theme.bg.ignoresSafeArea()
            SunoWebContainer(webView: model.webView)
                .accessibilityIdentifier("suno-tab-web")
            if model.loading && model.progress < 1 {
                GeometryReader { g in
                    Rectangle().fill(Theme.accent).frame(width: g.size.width * model.progress, height: 2)
                }
                .frame(height: 2)
            }
            if model.failed {
                VStack(spacing: 14) {
                    Image(systemName: "wifi.exclamationmark").font(.system(size: 40)).foregroundColor(Theme.dim)
                    Text("Can't reach Suno").font(.headline)
                    Text("Check your connection and try again.").font(.subheadline).foregroundColor(Theme.dim)
                    Button("Try again") { model.reload() }
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.accent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.bg)
            }
            if let note = model.note {
                VStack {
                    Spacer()
                    Text(note)
                        .font(.footnote)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(Theme.surface2, in: Capsule())
                        .padding(.bottom, 90)
                }
                .allowsHitTesting(false)
            }
            // A small handle on the right edge, halfway down: Suno's own page has buttons in every
            // corner (its menu, Log in, and its bottom bar with its own ··· button).
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    Menu {
                        Button { model.openCopiedLink() } label: { Label("Open Copied Suno Link", systemImage: "link") }
                        Button { model.home() } label: { Label("Suno Home", systemImage: "house") }
                        Button { model.reload() } label: { Label("Reload", systemImage: "arrow.clockwise") }
                    } label: {
                        Image(systemName: "link")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(.white)
                            .frame(width: 30, height: 44)
                            .background(Theme.surface2.opacity(0.85),
                                        in: UnevenRoundedCorners())
                    }
                    .accessibilityLabel("Suno tab options")
                }
                Spacer()
            }
        }
        .background(Theme.bg.ignoresSafeArea())
        .onChange(of: active) { if $0 { model.startIfNeeded() } }
        .onAppear { if active { model.startIfNeeded() } }
        .sheet(isPresented: Binding(get: { model.popup != nil }, set: { if !$0 { model.closePopup() } })) {
            if let p = model.popup { SunoPopupSheet(webView: p) { model.closePopup() } }
        }
    }
}
