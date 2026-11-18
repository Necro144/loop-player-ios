import XCTest

/// The Suno tab (1.3.0), with real taps: the tab bar button opens suno.com inside Loop Player,
/// and a public song plays there after tapping Suno's own Play button.
final class SunoTabUITests: XCTestCase {
    private var dir: URL!
    private var step = 0

    override func setUp() {
        continueAfterFailure = true
        dir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SUNO_OUT_DIR"] ?? NSTemporaryDirectory())
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    private func shot(_ app: XCUIApplication, _ name: String) {
        step += 1
        let s = XCUIScreen.main.screenshot()
        let a = XCTAttachment(screenshot: s)
        a.name = name
        a.lifetime = .keepAlways
        add(a)
        let base = String(format: "tab%02d-%@", step, name)
        try? s.pngRepresentation.write(to: dir.appendingPathComponent(base + ".png"))
        try? app.debugDescription.write(to: dir.appendingPathComponent(base + ".txt"), atomically: true, encoding: .utf8)
    }

    private func lines(_ f: URL) -> [String] {
        ((try? String(contentsOf: f, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }

    func testSunoTabOpensSuno() {
        let out = dir.appendingPathComponent("suno-tab-open.txt")
        try? FileManager.default.removeItem(at: out)
        let app = XCUIApplication()
        app.launchEnvironment = ["TEST_TAB": "0", "TEST_SUNO_TAB_OUT": out.path]
        app.launch()
        let button = app.buttons["tab-Suno"]
        XCTAssertTrue(button.waitForExistence(timeout: 60), "no Suno tab button")
        shot(app, "home-six-tabs")
        button.tap()
        var opened = false
        for _ in 0..<60 {
            sleep(1)
            if lines(out).contains(where: { $0.hasPrefix("page suno.com") }) { opened = true; break }
        }
        sleep(6)
        shot(app, "suno-tab")
        XCTAssertTrue(opened, "Suno's page didn't load in the tab: \(lines(out).joined(separator: " | "))")
        // Suno's page shows real content (links or buttons), not a blank page.
        let content = app.webViews.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS[c] 'Suno' OR label CONTAINS[c] 'Sign in' OR label CONTAINS[c] 'Create'")).firstMatch
        XCTAssertTrue(content.waitForExistence(timeout: 20), "Suno's page looks blank")
        app.buttons["tab-Home"].tap()
        sleep(1)
        app.buttons["tab-Suno"].tap()
        sleep(2)
        shot(app, "suno-tab-again")
        app.terminate()
    }

    func testPublicSongPlaysInSunoTab() {
        let out = dir.appendingPathComponent("suno-tab-play.txt")
        try? FileManager.default.removeItem(at: out)
        let app = XCUIApplication()
        app.launchEnvironment = ["TEST_TAB": "4", "TEST_SUNO_TAB_OUT": out.path,
                                 "TEST_SUNO_TAB_URL": "https://suno.com/song/538ab4ae-3ace-4abf-95f9-be0bed53b65d"]
        app.launch()
        let play = app.webViews.descendants(matching: .any)
            .matching(NSPredicate(format: "label ==[c] 'Play' OR label ==[c] 'Play song' OR label BEGINSWITH[c] 'Play '")).firstMatch
        guard play.waitForExistence(timeout: 60) else {
            shot(app, "song-no-play-button")
            XCTFail("no Play button on the song page: \(lines(out).joined(separator: " | "))")
            return
        }
        sleep(3)
        shot(app, "song-page")
        play.tap()
        var playing = false
        for _ in 0..<30 {
            sleep(1)
            // "media state: playing 4.2" with a time above 2 s means the song really plays.
            if lines(out).contains(where: { l in
                guard l.hasPrefix("media state:") else { return false }
                return l.components(separatedBy: CharacterSet(charactersIn: " ,")).enumerated().contains { i, w in
                    w == "playing" && i + 1 < l.components(separatedBy: CharacterSet(charactersIn: " ,")).count
                        && (Double(l.components(separatedBy: CharacterSet(charactersIn: " ,"))[i + 1]) ?? 0) > 2
                }
            }) { playing = true; break }
        }
        shot(app, "song-playing")
        try? lines(out).joined(separator: "\n").write(to: dir.appendingPathComponent("result-suno-tab-play.txt"), atomically: true, encoding: .utf8)
        XCTAssertTrue(playing, "the song didn't play: \(lines(out).suffix(15).joined(separator: " | "))")
        app.terminate()
    }
}
