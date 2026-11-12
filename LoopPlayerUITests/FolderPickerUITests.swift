import XCTest

/// Does what the owner does on the phone: tap "Choose a Folder", open the
/// "Suno Songs" folder in the Files picker, tap Open, then play. Also checks
/// that the folder is still there after the app is closed and opened again.
final class FolderPickerUITests: XCTestCase {
    private var shotsDir: URL?
    private var step = 0

    override func setUp() {
        continueAfterFailure = false
        if let d = ProcessInfo.processInfo.environment["SHOTS_DIR"], !d.isEmpty {
            shotsDir = URL(fileURLWithPath: d)
            try? FileManager.default.createDirectory(at: shotsDir!, withIntermediateDirectories: true)
        }
    }

    private func shot(_ app: XCUIApplication, _ name: String) {
        step += 1
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        guard let dir = shotsDir else { return }
        let base = String(format: "%02d-%@", step, name)
        try? screenshot.pngRepresentation.write(to: dir.appendingPathComponent(base + ".png"))
        try? app.debugDescription.write(to: dir.appendingPathComponent(base + ".txt"), atomically: true, encoding: .utf8)
    }

    /// Opens a folder or location in the Files picker by name.
    private func open(_ app: XCUIApplication, _ name: String) {
        let match = NSPredicate(format: "label BEGINSWITH %@", name)
        func find() -> XCUIElement? {
            let cell = app.cells.matching(match).firstMatch
            if cell.waitForExistence(timeout: 6) { return cell }
            let text = app.staticTexts.matching(match).allElementsBoundByIndex.first { $0.isHittable && $0.frame.minY > 150 }
            return text
        }
        if let el = find() {
            el.tap()
            sleep(2)
            return
        }
        // Not on this screen: go back to the top of Browse and look again.
        let browse = app.tabBars.buttons["Browse"]
        if browse.exists {
            browse.tap(); sleep(1)
            if browse.exists { browse.tap(); sleep(1) }
        }
        if let el = find() {
            el.tap()
            sleep(2)
            return
        }
        shot(app, "missing-" + name.replacingOccurrences(of: " ", with: "-"))
        XCTFail("Could not find \(name) in the folder picker")
    }

    private func anything(_ app: XCUIApplication, _ text: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    /// "Suno Songs" inside the app's own folder (On My iPhone > Loop Player).
    func testPickFolderInsideApp() throws {
        try pickFolderThenPlay(path: ["On My iPhone", "Loop Player", "Suno Songs"], tag: "inside")
    }

    /// "Suno Songs" directly in On My iPhone: outside the app, served by the system's file
    /// provider and needing security-scoped access, the same way an iCloud Drive folder is.
    func testPickFolderOutsideApp() throws {
        guard ProcessInfo.processInfo.environment["OUTSIDE_READY"] == "1" else {
            throw XCTSkip("No Suno Songs folder was placed in On My iPhone")
        }
        try pickFolderThenPlay(path: ["On My iPhone", "Suno Songs"], tag: "outside")
    }

    /// No picker at all: "Use the Loop Player folder" (On My iPhone > Loop Player).
    func testUseAppFolder() throws {
        let env = ProcessInfo.processInfo.environment
        let app = XCUIApplication()
        app.launchEnvironment["TEST_RESET"] = "1"
        if let seed = env["SEED_DIR"] { app.launchEnvironment["TEST_SEED_DIR"] = seed }
        app.launch()
        let use = app.buttons["useAppFolder"]
        XCTAssertTrue(use.waitForExistence(timeout: 90), "Use the Loop Player folder is not shown")
        use.tap()
        XCTAssertTrue(app.buttons["Shuffle All"].waitForExistence(timeout: 30), "The Loop Player folder was not added")
        XCTAssertTrue(anything(app, "Night Drive").waitForExistence(timeout: 40), "Songs are not listed")
        app.buttons["Shuffle All"].tap()
        let pp = app.buttons["miniPlayPause"]
        XCTAssertTrue(pp.waitForExistence(timeout: 20))
        expectation(for: NSPredicate(format: "label == 'Pause'"), evaluatedWith: pp)
        waitForExpectations(timeout: 25)
        shot(app, "appfolder-playing")
        app.terminate()
        let again = XCUIApplication()
        again.launch()
        XCTAssertTrue(again.buttons["Shuffle All"].waitForExistence(timeout: 60), "Forgotten after relaunch")
        again.terminate()
    }

    /// TrollStore way: the built-in browser, On My iPhone > Suno Songs.
    func testBrowsePhoneOnMyIPhone() throws {
        guard ProcessInfo.processInfo.environment["OUTSIDE_READY"] == "1" else {
            throw XCTSkip("No Suno Songs folder was placed in On My iPhone")
        }
        try browseThenPlay(place: "On My iPhone", folder: "Suno Songs", tag: "browse-local", bigLibrary: false)
    }

    /// TrollStore way: the built-in browser, iCloud Drive > Suno Songs. That folder holds
    /// about 300 files, a file that is only in iCloud (not downloaded) and a broken file.
    func testBrowsePhoneICloud() throws {
        guard ProcessInfo.processInfo.environment["ICLOUD_READY"] == "1" else {
            throw XCTSkip("No iCloud Drive test folder")
        }
        try browseThenPlay(place: "iCloud Drive", folder: "Suno Songs", tag: "browse-icloud", bigLibrary: true)
    }

    private func browseThenPlay(place: String, folder: String, tag: String, bigLibrary: Bool) throws {
        let app = XCUIApplication()
        app.launchEnvironment["TEST_RESET"] = "1"
        app.launch()

        let browse = app.buttons["browsePhone"]
        XCTAssertTrue(browse.waitForExistence(timeout: 90), "Browse iPhone Folders is not shown")
        shot(app, tag + "-welcome")
        browse.tap()

        let placeButton = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", place)).firstMatch
        XCTAssertTrue(placeButton.waitForExistence(timeout: 20), "\(place) is not listed in the browser")
        shot(app, tag + "-places")
        placeButton.tap()

        let folderButton = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", folder)).firstMatch
        XCTAssertTrue(folderButton.waitForExistence(timeout: 20), "\(folder) is not listed in \(place)")
        folderButton.tap()

        let use = app.buttons["useThisFolder"]
        XCTAssertTrue(use.waitForExistence(timeout: 20))
        sleep(1)
        shot(app, tag + "-folder")
        use.tap()

        let shuffle = app.buttons["Shuffle All"]
        XCTAssertTrue(shuffle.waitForExistence(timeout: 30), "Use This Folder did not add the folder")
        sleep(3)
        shot(app, tag + "-added")
        // A big library is listed at once by file name; tags (like "Night Drive") follow as they are read.
        let listed = anything(app, bigLibrary ? "Clip Video" : "Night Drive").waitForExistence(timeout: bigLibrary ? 240 : 60)
        shot(app, tag + "-tags")
        XCTAssertTrue(listed, "Songs from the folder are not listed")

        // The app must stay usable while it scans: play straight away.
        shuffle.tap()
        let playPause = app.buttons["miniPlayPause"]
        XCTAssertTrue(playPause.waitForExistence(timeout: 20), "Mini player did not appear")
        expectation(for: NSPredicate(format: "label == 'Pause'"), evaluatedWith: playPause)
        waitForExpectations(timeout: 25)
        shot(app, tag + "-playing")

        if bigLibrary {
            // Wait for the scan to finish, then show the log.
            let scanning = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Scanning' OR label BEGINSWITH 'Looking for'")).firstMatch
            expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: scanning)
            waitForExpectations(timeout: 300)
            shot(app, tag + "-scanned")
        }
        app.tabBars.buttons["Settings"].tap()
        let logLink = app.buttons["Folder Log"]
        for _ in 0..<4 where !logLink.isHittable { app.swipeUp() }
        if logLink.isHittable {
            logLink.tap()
            sleep(2)
            shot(app, tag + "-folder-log")
        }

        app.terminate()
        let again = XCUIApplication()
        again.launch()
        let home = again.tabBars.buttons["Home"]
        if home.waitForExistence(timeout: 60) { home.tap() }
        XCTAssertTrue(again.buttons["Shuffle All"].waitForExistence(timeout: 60), "The folder was forgotten after relaunch")
        XCTAssertTrue(anything(again, bigLibrary ? "Clip Video" : "Night Drive").waitForExistence(timeout: 40), "Songs missing after relaunch")
        again.buttons["Shuffle All"].tap()
        let pp = again.buttons["miniPlayPause"]
        XCTAssertTrue(pp.waitForExistence(timeout: 20))
        expectation(for: NSPredicate(format: "label == 'Pause'"), evaluatedWith: pp)
        waitForExpectations(timeout: 25)
        shot(again, tag + "-relaunched-playing")
        again.terminate()
    }

    private func pickFolderThenPlay(path: [String], tag: String) throws {
        let env = ProcessInfo.processInfo.environment
        let app = XCUIApplication()
        app.launchEnvironment["TEST_RESET"] = "1"
        if let seed = env["SEED_DIR"] { app.launchEnvironment["TEST_SEED_DIR"] = seed }
        app.launch()

        let choose = app.buttons["Choose a Folder"]
        XCTAssertTrue(choose.waitForExistence(timeout: 90), "Welcome screen did not appear")
        shot(app, tag + "-welcome")
        choose.tap()

        let openButton = app.buttons["Open"]
        XCTAssertTrue(openButton.waitForExistence(timeout: 30), "The folder picker did not appear")
        sleep(2)
        shot(app, tag + "-picker")

        for name in path { open(app, name) }
        shot(app, tag + "-inside-folder")

        XCTAssertTrue(app.buttons["Open"].waitForExistence(timeout: 10))
        app.buttons["Open"].tap()

        let shuffle = app.buttons["Shuffle All"]
        let took = shuffle.waitForExistence(timeout: 30)
        sleep(3)
        shot(app, tag + "-after-open")
        XCTAssertTrue(took, "Tapping Open did not add the folder")
        XCTAssertTrue(anything(app, "Night Drive").waitForExistence(timeout: 40), "Songs from the folder are not listed")

        shuffle.tap()
        let playPause = app.buttons["miniPlayPause"]
        XCTAssertTrue(playPause.waitForExistence(timeout: 20), "Mini player did not appear")
        expectation(for: NSPredicate(format: "label == 'Pause'"), evaluatedWith: playPause)
        waitForExpectations(timeout: 25)
        sleep(2)
        shot(app, tag + "-playing")

        // Close and reopen: the folder must be remembered and still readable.
        app.terminate()
        let again = XCUIApplication()
        again.launch()
        XCTAssertTrue(again.buttons["Shuffle All"].waitForExistence(timeout: 60), "The folder was forgotten after relaunch")
        XCTAssertTrue(anything(again, "Night Drive").waitForExistence(timeout: 40), "Songs missing after relaunch")
        again.buttons["Shuffle All"].tap()
        let pp = again.buttons["miniPlayPause"]
        XCTAssertTrue(pp.waitForExistence(timeout: 20))
        expectation(for: NSPredicate(format: "label == 'Pause'"), evaluatedWith: pp)
        waitForExpectations(timeout: 25)
        shot(again, tag + "-relaunched-playing")
        again.terminate()
    }
}
