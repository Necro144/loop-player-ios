import SwiftUI
import WebKit
import Security

// Sign in to Suno with Suno's own sign-in page (suno.com, run by Clerk) inside a web view.
// Loop Player never sees or keeps the password: the login is typed into Suno's page, and the
// session stays in the app's web data, like in Safari. For API calls the app asks Suno's page
// for a short-lived token, the same way suno.com itself does, so the session renews itself.
//
// 1.2.3: suno.com dropped the Clerk script (window.Clerk) in November 2026 and now talks to its
// sign-in service at auth.suno.com directly: GET /v1/client lists the signed-in sessions and
// POST /v1/client/sessions/<id>/tokens gives the token. 1.2.2 still waited for window.Clerk,
// so it never saw a finished sign-in. `sessionJS` below does what the website does.
//
// 1.2.3: the session is also kept in the Keychain (SunoSessionVault). WebKit alone lost it:
// when the app was closed before WebKit wrote its cookies, on TrollStore installs (no sandbox),
// and after Settings > Clear Cache. On every start the saved cookies are put back into WebKit
// before Suno's page loads, so the app stays signed in until you tap Sign Out.

@MainActor
final class SunoAuth: ObservableObject {
    static let shared = SunoAuth()
    /// Name shown in Settings; nil when signed out.
    @Published private(set) var user: String? = UserDefaults.standard.string(forKey: "sunoUser")
    var signedIn: Bool { user != nil }

    static let safariUA = "Mozilla/5.0 (iPhone; CPU iPhone OS 16_4 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.4 Mobile/15E148 Safari/604.1"

    private var web: WKWebView?
    private var loadedAt: Date?
    private var cached: (String, Date)?

    private var restored = false
    private var savedAt: Date?

    private init() {
        NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in await SunoAuth.shared.saveSession() }
        }
    }

    func setUser(_ name: String?) {
        user = name
        UserDefaults.standard.set(name, forKey: "sunoUser")
        cached = nil
        loadedAt = nil
        if let name {
            FolderLog.append("Suno: signed in as \(name)")
            // Clerk sets its cookies just before this; give WebKit a moment, then keep them.
            Task {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                await self.saveSession(force: true)
            }
        }
    }

    nonisolated private static func isSunoCookie(_ c: HTTPCookie) -> Bool {
        let d = c.domain.lowercased()
        return d.contains("suno") || d.contains("clerk")
    }

    /// Keeps Suno's sign-in cookies in the Keychain (at most once a minute unless forced).
    func saveSession(force: Bool = false) async {
        guard signedIn else { return }
        if !force, let t = savedAt, Date().timeIntervalSince(t) < 60 { return }
        let all = await WKWebsiteDataStore.default().httpCookieStore.allCookies()
        let suno = all.filter(SunoAuth.isSunoCookie)
        // Clerk's "__client" / "__session" cookies prove a session; don't overwrite a good
        // save with an empty or half one.
        guard suno.contains(where: { $0.name.hasPrefix("__client") || $0.name.hasPrefix("__session") }) else {
            if force { FolderLog.append("Suno: no sign-in cookies found to keep (\(suno.count) Suno cookies)") }
            return
        }
        if SunoSessionVault.save(suno) {
            savedAt = Date()
            if force { FolderLog.append("Suno: sign-in kept on this phone (\(suno.count) cookies)") }
        } else {
            FolderLog.append("Suno: couldn't keep the sign-in on this phone")
        }
    }

    /// Puts the kept cookies back into WebKit. Runs once per start (and again with force when
    /// Suno's page says the session is gone). Newer cookies already in WebKit are kept.
    func restoreSession(force: Bool = false) async {
        guard signedIn, force || !restored else { return }
        restored = true
        let saved = SunoSessionVault.load()
        guard !saved.isEmpty else {
            FolderLog.append("Suno: no kept sign-in to restore")
            return
        }
        let store = WKWebsiteDataStore.default().httpCookieStore
        let current = await store.allCookies()
        var put = 0
        for c in saved {
            if let exp = c.expiresDate, exp < Date() { continue }
            let same = current.first { $0.name == c.name && $0.domain == c.domain && $0.path == c.path }
            if !force, let same, (same.expiresDate ?? .distantFuture) >= (c.expiresDate ?? .distantPast) { continue }
            await store.setCookie(c)
            put += 1
        }
        if put > 0 {
            cached = nil
            loadedAt = nil
        }
        FolderLog.append(put == 0 ? "Suno: sign-in already in place (\(saved.count) kept cookies)" : "Suno: restored the kept sign-in (\(put) of \(saved.count) cookies)")
    }

    /// A fresh token for Suno's API, or nil when not signed in.
    func token() async -> String? {
        guard signedIn else { return nil }
        if let c = cached, Date().timeIntervalSince(c.1) < 40 { return c.0 }
        await restoreSession()
        let w = web ?? makeWeb()
        if loadedAt == nil || Date().timeIntervalSince(loadedAt!) > 1800 {
            w.load(URLRequest(url: URL(string: "https://suno.com/")!))
            loadedAt = Date()
        }
        var retried = false
        var lastErr = ""
        for _ in 0..<60 {
            if let r = try? await w.callAsyncJavaScript(SunoAuth.sessionJS, arguments: ["mode": "token"], in: nil, contentWorld: .page) as? String {
                if r.hasPrefix("err:") { lastErr = r }
                if r == "none" {
                    if !retried {
                        // Often only WebKit lost the cookies (or the page loaded before they were
                        // back): put the kept ones back and load Suno's page again before giving up.
                        retried = true
                        FolderLog.append("Suno: page shows no sign-in; restoring the kept one and trying again")
                        await restoreSession(force: true)
                        w.load(URLRequest(url: URL(string: "https://suno.com/")!))
                        loadedAt = Date()
                        try? await Task.sleep(nanoseconds: 1_000_000_000)
                        continue
                    }
                    FolderLog.append("Suno: Suno ended the sign-in; sign in again in Settings")
                    setUser(nil)
                    SunoSessionVault.clear()
                    return nil
                }
                if r.hasPrefix("jwt:") {
                    let t = String(r.dropFirst(4))
                    cached = (t, Date())
                    await saveSession()
                    return t
                }
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        if !lastErr.isEmpty { FolderLog.append("Suno: token from the page failed (\(lastErr.prefix(120)))") }
        // Ask auth.suno.com from the app itself, with the cookies Suno's page set.
        if let t = await nativeToken() {
            cached = (t, Date())
            return t
        }
        // Last resort: Suno's session cookie (it may be a few seconds old).
        let cookies = await WKWebsiteDataStore.default().httpCookieStore.allCookies()
        if let c = cookies.first(where: { $0.name == "__session" && $0.domain.contains("suno") }) {
            cached = (c.value, Date())
            return c.value
        }
        FolderLog.append("Suno: couldn't get a sign-in token from suno.com")
        return nil
    }

    /// Runs on a suno.com page (callAsyncJavaScript, argument `mode`): "who" answers
    /// "user:<name>" or "none"; "token" answers "jwt:<token>" or "none". "wait" while the page
    /// isn't on suno.com yet, "err:..." when auth.suno.com couldn't be asked.
    static let sessionJS = """
    if (!/(^|\\.)suno\\.com$/.test(location.hostname)) return 'wait';
    let cl;
    try {
      const r = await fetch('https://auth.suno.com/v1/client', {credentials: 'include'});
      if (!r.ok) return 'err:client ' + r.status;
      cl = (await r.json()).response || {};
    } catch (e) {
      if (window.Clerk && window.Clerk.loaded) {
        if (!window.Clerk.session) return 'none';
        if (mode === 'who') { const u = window.Clerk.user || {}; return 'user:' + (u.username || u.fullName || 'your account'); }
        return 'jwt:' + await window.Clerk.session.getToken();
      }
      return 'err:client ' + e;
    }
    const list = cl.sessions || [];
    const sid = cl.last_active_session_id || (list[0] && list[0].id);
    if (!sid) return 'none';
    if (mode === 'who') {
      const s = list.find(x => x.id === sid) || list[0] || {};
      const u = s.user || {};
      const mails = u.email_addresses || [];
      const em = mails.find(e => e.id === u.primary_email_address_id) || mails[0];
      return 'user:' + (u.username || [u.first_name, u.last_name].filter(Boolean).join(' ') || (em && em.email_address) || 'your account');
    }
    try {
      const t = await fetch('https://auth.suno.com/v1/client/sessions/' + encodeURIComponent(sid) + '/tokens', {method: 'POST', credentials: 'include'});
      if (!t.ok) return 'err:tokens ' + t.status;
      const j = await t.json();
      return j.jwt ? 'jwt:' + j.jwt : 'err:no jwt';
    } catch (e) { return 'err:tokens ' + e; }
    """

    /// The same two calls as `sessionJS`, made by the app with the cookies WebKit keeps for
    /// auth.suno.com (used when the hidden page doesn't answer).
    private func nativeToken() async -> String? {
        let all = await WKWebsiteDataStore.default().httpCookieStore.allCookies()
        let auth = all.filter { c in
            let d = c.domain.hasPrefix(".") ? String(c.domain.dropFirst()) : c.domain
            return d == "auth.suno.com" || d == "suno.com"
        }
        guard !auth.isEmpty else { return nil }
        let cookie = auth.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
        func req(_ path: String, post: Bool) -> URLRequest {
            var r = URLRequest(url: URL(string: "https://auth.suno.com" + path)!)
            r.httpMethod = post ? "POST" : "GET"
            r.setValue(cookie, forHTTPHeaderField: "Cookie")
            r.setValue("https://suno.com", forHTTPHeaderField: "Origin")
            r.setValue("https://suno.com/", forHTTPHeaderField: "Referer")
            r.setValue(SunoAuth.safariUA, forHTTPHeaderField: "User-Agent")
            r.httpShouldHandleCookies = false
            return r
        }
        do {
            let (d, _) = try await URLSession.shared.data(for: req("/v1/client", post: false))
            let cl = ((try JSONSerialization.jsonObject(with: d)) as? [String: Any])?["response"] as? [String: Any] ?? [:]
            let sessions = cl["sessions"] as? [[String: Any]] ?? []
            guard let sid = (cl["last_active_session_id"] as? String) ?? (sessions.first?["id"] as? String) else {
                FolderLog.append("Suno: auth.suno.com shows no sign-in (\(auth.count) cookies sent)")
                return nil
            }
            let path = "/v1/client/sessions/\(sid.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? sid)/tokens"
            let (td, _) = try await URLSession.shared.data(for: req(path, post: true))
            if let jwt = ((try JSONSerialization.jsonObject(with: td)) as? [String: Any])?["jwt"] as? String, jwt.count > 20 {
                return jwt
            }
            FolderLog.append("Suno: auth.suno.com gave no token")
        } catch {
            FolderLog.append("Suno: auth.suno.com didn't answer (\(error.localizedDescription))")
        }
        return nil
    }

    /// Cookies Suno set, for streaming files that check them.
    func cookies(for url: URL) async -> [HTTPCookie] {
        guard signedIn, let host = url.host else { return [] }
        let all = await WKWebsiteDataStore.default().httpCookieStore.allCookies()
        return all.filter { c in
            let d = c.domain.hasPrefix(".") ? String(c.domain.dropFirst()) : c.domain
            return host == d || host.hasSuffix("." + d)
        }
    }

    func signOut() async {
        if let w = web {
            _ = try? await w.callAsyncJavaScript("try { await fetch('https://auth.suno.com/v1/client', {method: 'DELETE', credentials: 'include'}); } catch (e) {} if (window.Clerk && window.Clerk.signOut) { await window.Clerk.signOut(); } return 1;",
                                                 arguments: [:], in: nil, contentWorld: .page)
        }
        let store = WKWebsiteDataStore.default()
        let records = await store.dataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes())
        let suno = records.filter { $0.displayName.lowercased().contains("suno") || $0.displayName.lowercased().contains("clerk") }
        await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), for: suno)
        web?.removeFromSuperview()
        web = nil
        SunoSessionVault.clear()
        setUser(nil)
        FolderLog.append("Suno: signed out")
    }

    private func makeWeb() -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.mediaTypesRequiringUserActionForPlayback = .all
        let w = WKWebView(frame: CGRect(x: 0, y: 0, width: 4, height: 4), configuration: config)
        w.customUserAgent = SunoAuth.safariUA
        w.alpha = 0.01
        w.isUserInteractionEnabled = false
        // Kept in the window (invisible) so its page keeps running.
        if let win = UIApplication.shared.connectedScenes.compactMap({ ($0 as? UIWindowScene)?.windows.first }).first {
            win.addSubview(w)
        }
        web = w
        return w
    }
}

// MARK: - Kept sign-in

/// Suno's sign-in cookies, kept in the Keychain (this phone only, readable after the first
/// unlock so background playback works). If the Keychain refuses (it can on some TrollStore
/// installs), a protected file in the app's own data is used instead. Never the password:
/// Loop Player never sees it.
enum SunoSessionVault {
    private static let service = "com.necro144.loopplayer.suno"
    private static let account = "session"
    private static var file: URL { AppPaths.support.appendingPathComponent("suno-session.plist") }

    static func save(_ cookies: [HTTPCookie]) -> Bool {
        let list: [[String: Any]] = cookies.compactMap { c in
            guard let props = c.properties else { return nil }
            var d: [String: Any] = [:]
            for (k, v) in props {
                switch v {
                case let x as String: d[k.rawValue] = x
                case let x as Date: d[k.rawValue] = x
                case let x as NSNumber: d[k.rawValue] = x
                case let x as URL: d[k.rawValue] = x.absoluteString
                default: d[k.rawValue] = "\(v)"
                }
            }
            return d
        }
        guard let data = try? PropertyListSerialization.data(fromPropertyList: list, format: .binary, options: 0) else { return false }
        if keychainWrite(data) {
            try? FileManager.default.removeItem(at: file)
            return true
        }
        do {
            try data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            return true
        } catch {
            return false
        }
    }

    static func load() -> [HTTPCookie] {
        guard let data = keychainRead() ?? (try? Data(contentsOf: file)),
              let list = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [[String: Any]]
        else { return [] }
        return list.compactMap { d in
            var props: [HTTPCookiePropertyKey: Any] = [:]
            for (k, v) in d { props[HTTPCookiePropertyKey(k)] = v }
            return HTTPCookie(properties: props)
        }
    }

    static func clear() {
        SecItemDelete(baseQuery as CFDictionary)
        try? FileManager.default.removeItem(at: file)
    }

    private static var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    private static func keychainWrite(_ data: Data) -> Bool {
        let attrs: [String: Any] = [kSecValueData as String: data,
                                    kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemUpdate(baseQuery as CFDictionary, attrs as CFDictionary)
        if status == errSecSuccess { return true }
        if status == errSecItemNotFound {
            var add = baseQuery
            add.merge(attrs) { $1 }
            return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
        }
        return false
    }

    private static func keychainRead() -> Data? {
        var q = baseQuery
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess else { return nil }
        return out as? Data
    }
}

// MARK: - Sign-in screen

/// What happened on the sign-in screen (pages opened, pop-up windows, errors). Shown in the
/// Folder Log, and written to a file in the automatic tap test.
enum SunoSignInLog {
    static var lines: [String] = []
    static func add(_ s: String) {
        lines.append(s)
        FolderLog.append("Suno sign-in: \(s)")
        if let out = ProcessInfo.processInfo.environment["TEST_SUNO_SIGNIN_OUT"] {
            try? lines.joined(separator: "\n").write(toFile: out, atomically: true, encoding: .utf8)
        }
    }
}

struct SunoSignInView: View {
    @EnvironmentObject var auth: SunoAuth
    @Environment(\.dismiss) private var dismiss
    @State private var done: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Text(done.map { "Signed in as \($0)" } ?? "Sign in on Suno's own page below. Loop Player never sees your password.")
                    .font(.footnote)
                    .foregroundColor(done == nil ? Theme.dim : .green)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                SunoSignInWeb { name in
                    guard done == nil else { return }
                    done = name
                    auth.setUser(name)
                    Task {
                        try? await Task.sleep(nanoseconds: 600_000_000)
                        dismiss()
                    }
                }
            }
            .background(Theme.bg)
            .navigationTitle("Sign in to Suno")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
            }
        }
        .preferredColorScheme(.dark)
        // Swiping down must not fight with scrolling and tapping on Suno's page.
        .interactiveDismissDisabled()
    }
}

/// Suno's sign-in page. "Continue with Google / Apple / Discord / Facebook / Microsoft" open a
/// second (pop-up) window; 1.2.1 refused those windows, so tapping the buttons did nothing.
/// Pop-ups now open on top of the page, inside the app, with a bar to go back.
struct SunoSignInWeb: UIViewRepresentable {
    let onSignedIn: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onSignedIn: onSignedIn) }

    func makeUIView(context: Context) -> UIView {
        let box = UIView()
        box.backgroundColor = .black
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        config.userContentController.add(context.coordinator, name: "signinlog")
        config.userContentController.addUserScript(WKUserScript(source: Coordinator.logScript, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        let w = WKWebView(frame: box.bounds, configuration: config)
        w.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        // Google and Apple sign-in refuse in-app browsers that don't say they're Safari.
        w.customUserAgent = SunoAuth.safariUA
        w.uiDelegate = context.coordinator
        w.navigationDelegate = context.coordinator
        w.allowsBackForwardNavigationGestures = true
        box.addSubview(w)
        context.coordinator.box = box
        context.coordinator.main = w
        SunoSignInLog.add("open https://suno.com/sign-in")
        w.load(URLRequest(url: URL(string: "https://suno.com/sign-in")!))
        context.coordinator.start()
        return box
    }

    func updateUIView(_ uiView: UIView, context: Context) {}

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        coordinator.timer?.invalidate()
        coordinator.main?.configuration.userContentController.removeScriptMessageHandler(forName: "signinlog")
    }

    final class Coordinator: NSObject, WKUIDelegate, WKNavigationDelegate, WKScriptMessageHandler {
        let onSignedIn: (String) -> Void
        var timer: Timer?
        weak var box: UIView?
        weak var main: WKWebView?
        /// Open pop-up windows (newest last), each with its bar.
        var popups: [(UIView, WKWebView)] = []
        private var checking = false
        private var finished = false
        private var lastCheck = ""

        init(onSignedIn: @escaping (String) -> Void) { self.onSignedIn = onSignedIn }

        static let logScript = """
        (function(){
          function post(m){ try { window.webkit.messageHandlers.signinlog.postMessage(String(m).slice(0,300)); } catch(e){} }
          window.addEventListener('error', function(e){ post('js error: ' + e.message); });
          window.addEventListener('unhandledrejection', function(e){ post('js promise error: ' + (e.reason && (e.reason.message || e.reason))); });
          var oe = console.error; console.error = function(){ post('console: ' + Array.prototype.join.call(arguments, ' ')); oe.apply(console, arguments); };
        })();
        """

        func start() {
            timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in self?.check() }
        }

        func check() {
            guard !checking, !finished, let main else { return }
            checking = true
            main.callAsyncJavaScript(SunoAuth.sessionJS, arguments: ["mode": "who"], in: nil, in: .page) { [weak self] result in
                guard let self else { return }
                self.checking = false
                guard case .success(let v) = result, let r = v as? String else { return }
                if r.hasPrefix("err:"), r != self.lastCheck { SunoSignInLog.add("check: \(r.prefix(120))") }
                self.lastCheck = r
                guard r.hasPrefix("user:"), !self.finished else { return }
                self.finished = true
                self.timer?.invalidate()
                SunoSignInLog.add("signed in")
                self.closeAllPopups()
                self.onSignedIn(String(r.dropFirst(5)))
            }
        }

        func userContentController(_ uc: WKUserContentController, didReceive message: WKScriptMessage) {
            if let s = message.body as? String { SunoSignInLog.add(s) }
        }

        // MARK: Pop-up windows (Google, Apple, Discord, Facebook, Microsoft)

        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            let target = navigationAction.request.url?.absoluteString ?? ""
            SunoSignInLog.add("popup " + (target.isEmpty ? "(blank)" : target))
            guard let box else { return nil }
            let holder = UIView(frame: box.bounds)
            holder.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            holder.backgroundColor = .black
            let bar = UIView(frame: CGRect(x: 0, y: 0, width: box.bounds.width, height: 44))
            bar.autoresizingMask = [.flexibleWidth]
            bar.backgroundColor = UIColor(white: 0.12, alpha: 1)
            let back = UIButton(type: .system)
            back.setTitle("‹ Back to Suno", for: .normal)
            back.titleLabel?.font = .systemFont(ofSize: 16, weight: .semibold)
            back.tintColor = UIColor(red: 1.0, green: 0.27, blue: 0.47, alpha: 1)
            back.frame = CGRect(x: 8, y: 0, width: 160, height: 44)
            back.contentHorizontalAlignment = .left
            back.accessibilityIdentifier = "suno-popup-back"
            back.addTarget(self, action: #selector(closeTopPopup), for: .touchUpInside)
            bar.addSubview(back)
            // The pop-up must use the configuration WebKit gives, so it stays linked to Suno's page.
            let pop = WKWebView(frame: CGRect(x: 0, y: 44, width: box.bounds.width, height: box.bounds.height - 44), configuration: configuration)
            pop.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            pop.customUserAgent = SunoAuth.safariUA
            pop.uiDelegate = self
            pop.navigationDelegate = self
            holder.addSubview(pop)
            holder.addSubview(bar)
            box.addSubview(holder)
            popups.append((holder, pop))
            return pop
        }

        func webViewDidClose(_ webView: WKWebView) {
            SunoSignInLog.add("popup closed by the page")
            if let i = popups.firstIndex(where: { $0.1 === webView }) {
                popups[i].0.removeFromSuperview()
                popups.remove(at: i)
            }
            check()
        }

        @objc func closeTopPopup() {
            guard let last = popups.popLast() else { return }
            SunoSignInLog.add("popup closed with Back")
            last.1.stopLoading()
            last.0.removeFromSuperview()
            check()
        }

        private func closeAllPopups() {
            for p in popups { p.0.removeFromSuperview() }
            popups.removeAll()
        }

        // MARK: Pages

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            // Already signed in: don't go on into Google/Apple/Discord again while the screen closes.
            if finished, navigationAction.targetFrame?.isMainFrame != false {
                decisionHandler(.cancel)
                return
            }
            if navigationAction.targetFrame?.isMainFrame != false, let u = navigationAction.request.url {
                let isPopup = webView !== main
                SunoSignInLog.add((isPopup ? "popup page " : "page ") + (u.host ?? u.absoluteString) + u.path)
            }
            decisionHandler(.allow)
        }

        // Suno sends you to suno.com/create (or another page) once signing in is done: ask at once.
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            if webView === main, let u = webView.url, (u.host ?? "").hasSuffix("suno.com"), !u.path.hasPrefix("/sign-in") {
                check()
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            SunoSignInLog.add("page failed: \(error.localizedDescription)")
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            SunoSignInLog.add("page didn't open: \(error.localizedDescription)")
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            SunoSignInLog.add("page crashed; reloading")
            webView.reload()
        }

        // Pages may ask with alert()/confirm(): show them instead of ignoring (which can stall a page).
        func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                     initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
            present(message, ok: { completionHandler() }, cancel: nil)
        }

        func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                     initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
            present(message, ok: { completionHandler(true) }, cancel: { completionHandler(false) })
        }

        private func present(_ message: String, ok: @escaping () -> Void, cancel: (() -> Void)?) {
            SunoSignInLog.add("page message: \(message)")
            guard let vc = box?.window?.rootViewController?.topMost else { ok(); return }
            let a = UIAlertController(title: nil, message: message, preferredStyle: .alert)
            a.addAction(UIAlertAction(title: "OK", style: .default) { _ in ok() })
            if let cancel { a.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in cancel() }) }
            vc.present(a, animated: true)
        }
    }
}

private extension UIViewController {
    var topMost: UIViewController { presentedViewController?.topMost ?? self }
}
