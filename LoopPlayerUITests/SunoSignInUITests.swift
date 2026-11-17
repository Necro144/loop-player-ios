import XCTest

/// Does what the owner does: opens "Sign in to Suno" and taps "Continue with Google",
/// "Continue with Apple" and "Continue with Discord" with real taps. Each tap must open that
/// service's sign-in page (in a pop-up window or the same page). 1.2.1 failed this: the
/// buttons did nothing.
final class SunoSignInUITests: XCTestCase {
    private var dir: URL!
    private var step = 0

    override func setUp() {
        continueAfterFailure = true
        let d = ProcessInfo.processInfo.environment["SUNO_OUT_DIR"] ?? NSTemporaryDirectory()
        dir = URL(fileURLWithPath: d)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    private func shot(_ app: XCUIApplication, _ name: String) {
        step += 1
        let s = XCUIScreen.main.screenshot()
        let a = XCTAttachment(screenshot: s)
        a.name = name
        a.lifetime = .keepAlways
        add(a)
        let base = String(format: "%02d-%@", step, name)
        try? s.pngRepresentation.write(to: dir.appendingPathComponent(base + ".png"))
        try? app.debugDescription.write(to: dir.appendingPathComponent(base + ".txt"), atomically: true, encoding: .utf8)
    }

    private func log(_ file: URL) -> [String] {
        ((try? String(contentsOf: file, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }

    private func tapAndCheck(_ button: String, host: String) {
        let tag = button.replacingOccurrences(of: "Continue with ", with: "").lowercased()
        let out = dir.appendingPathComponent("signin-\(tag).txt")
        try? FileManager.default.removeItem(at: out)
        let app = XCUIApplication()
        app.launchEnvironment = ["TEST_SUNO_SIGNIN": "1", "TEST_SUNO_SIGNIN_OUT": out.path]
        app.launch()

        let el = app.webViews.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS[c] %@", button)).firstMatch
        guard el.waitForExistence(timeout: 60) else {
            shot(app, "\(tag)-no-button")
            XCTFail("\(button): the button never showed on Suno's page")
            app.terminate()
            return
        }
        sleep(3)
        shot(app, "\(tag)-before-tap")
        let before = log(out).count
        el.tap()   // a real tap, like a finger
        var opened = false
        for _ in 0..<20 {
            sleep(1)
            let after = log(out).dropFirst(before)
            if after.contains(where: { $0.lowercased().contains(host) }) { opened = true; break }
        }
        sleep(3)
        shot(app, "\(tag)-after-tap")
        let after = Array(log(out).dropFirst(before))
        try? (["button=\(button)", "opened=\(opened)"] + after).joined(separator: "\n")
            .write(to: dir.appendingPathComponent("result-\(tag).txt"), atomically: true, encoding: .utf8)
        XCTAssertTrue(opened, "\(button): tapping did not open \(host). After the tap: \(after.joined(separator: " | "))")

        // The pop-up's "Back to Suno" bar must bring Suno's page back.
        let back = app.buttons["suno-popup-back"]
        if back.exists {
            back.tap()
            sleep(2)
            shot(app, "\(tag)-back")
            XCTAssertTrue(el.waitForExistence(timeout: 10) && el.isHittable, "\(button): Suno's page didn't come back after Back")
        }
        app.terminate()
    }

    func testContinueWithGoogle() { tapAndCheck("Continue with Google", host: "google.com") }
    func testContinueWithApple() { tapAndCheck("Continue with Apple", host: "apple.com") }
    func testContinueWithDiscord() { tapAndCheck("Continue with Discord", host: "discord.com") }
}
