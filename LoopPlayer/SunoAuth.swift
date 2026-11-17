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
    }
}

struct SunoSignInWeb: UIViewRepresentable {
    let onSignedIn: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onSignedIn: onSignedIn) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        let w = WKWebView(frame: .zero, configuration: config)
        // Google and Apple sign-in refuse in-app browsers that don't say they're Safari.
        w.customUserAgent = SunoAuth.safariUA
        w.uiDelegate = context.coordinator
        w.navigationDelegate = context.coordinator
        w.load(URLRequest(url: URL(string: "https://suno.com/sign-in")!))
        context.coordinator.start(w)
        return w
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) { coordinator.timer?.invalidate() }

    final class Coordinator: NSObject, WKUIDelegate, WKNavigationDelegate {
        let onSignedIn: (String) -> Void
        var timer: Timer?
        weak var web: WKWebView?
        init(onSignedIn: @escaping (String) -> Void) { self.onSignedIn = onSignedIn }

        func start(_ w: WKWebView) {
            web = w
            timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in self?.check() }
        }

        private func check() {
            let js = "(window.Clerk && window.Clerk.user) ? (window.Clerk.user.username || window.Clerk.user.fullName || (window.Clerk.user.primaryEmailAddress && window.Clerk.user.primaryEmailAddress.emailAddress) || 'your account') : ''"
            web?.evaluateJavaScript(js) { [weak self] r, _ in
                guard let self, let name = r as? String, !name.isEmpty else { return }
                self.timer?.invalidate()
                self.onSignedIn(name)
            }
        }

        // Sign-in with Google/Apple may try to open a new window: open it here instead.
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if navigationAction.targetFrame == nil { webView.load(navigationAction.request) }
            return nil
        }
    }
}
