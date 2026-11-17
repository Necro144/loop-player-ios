import SwiftUI
import WebKit

// Sign in to Suno with Suno's own sign-in page (suno.com, run by Clerk) inside a web view.
// Loop Player never sees or keeps the password: the login is typed into Suno's page, and the
// session stays in the app's web data, like in Safari. For API calls the app asks Suno's page
// for a short-lived token (window.Clerk.session.getToken(), what suno.com itself does), so the
// session renews itself the same way the website's does.

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

    func setUser(_ name: String?) {
        user = name
        UserDefaults.standard.set(name, forKey: "sunoUser")
        cached = nil
        loadedAt = nil
        if let name { FolderLog.append("Suno: signed in as \(name)") }
    }

    /// A fresh token for Suno's API, or nil when not signed in.
    func token() async -> String? {
        guard signedIn else { return nil }
        if let c = cached, Date().timeIntervalSince(c.1) < 40 { return c.0 }
        let w = web ?? makeWeb()
        if loadedAt == nil || Date().timeIntervalSince(loadedAt!) > 1800 {
            w.load(URLRequest(url: URL(string: "https://suno.com/")!))
            loadedAt = Date()
        }
        let js = """
        if (!window.Clerk || !window.Clerk.loaded) return 'wait';
        if (!window.Clerk.session) return 'none';
        return await window.Clerk.session.getToken();
        """
        for _ in 0..<40 {
            if let r = try? await w.callAsyncJavaScript(js, arguments: [:], in: nil, contentWorld: .page) as? String {
                if r == "none" {
                    FolderLog.append("Suno: the sign-in has ended; sign in again in Settings")
                    setUser(nil)
                    return nil
                }
                if r != "wait" && r.count > 20 {
                    cached = (r, Date())
                    return r
                }
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        // Suno's page didn't answer: use its session cookie (it may be a few seconds old).
        let cookies = await WKWebsiteDataStore.default().httpCookieStore.allCookies()
        if let c = cookies.first(where: { $0.name == "__session" && $0.domain.contains("suno") }) {
            cached = (c.value, Date())
            return c.value
        }
        FolderLog.append("Suno: couldn't get a sign-in token from suno.com")
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
            _ = try? await w.callAsyncJavaScript("if (window.Clerk && window.Clerk.signOut) { await window.Clerk.signOut(); } return 1;",
                                                 arguments: [:], in: nil, contentWorld: .page)
        }
        let store = WKWebsiteDataStore.default()
        let records = await store.dataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes())
        let suno = records.filter { $0.displayName.lowercased().contains("suno") || $0.displayName.lowercased().contains("clerk") }
        await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), for: suno)
        web?.removeFromSuperview()
        web = nil
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
                        try? await Task.sleep(nanoseconds: 1_200_000_000)
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

        private func check() {
            let js = "(window.Clerk && window.Clerk.user) ? (window.Clerk.user.username || window.Clerk.user.fullName || (window.Clerk.user.primaryEmailAddress && window.Clerk.user.primaryEmailAddress.emailAddress) || 'your account') : ''"
            main?.evaluateJavaScript(js) { [weak self] r, _ in
                guard let self, let name = r as? String, !name.isEmpty else { return }
                self.timer?.invalidate()
                SunoSignInLog.add("signed in")
                self.closeAllPopups()
                self.onSignedIn(name)
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
            if navigationAction.targetFrame?.isMainFrame != false, let u = navigationAction.request.url {
                let isPopup = webView !== main
                SunoSignInLog.add((isPopup ? "popup page " : "page ") + (u.host ?? u.absoluteString) + u.path)
            }
            decisionHandler(.allow)
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
