import Foundation
import Darwin

/// Settings > Folder Log. Lines go straight to a file, from any thread, so the log
/// still shows the last step if the app freezes or crashes.
enum FolderLog {
    static let url = AppPaths.support.appendingPathComponent("folder-log.txt")
    private static let queue = DispatchQueue(label: "LoopPlayer.folderLog")
    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d HH:mm:ss"
        return f
    }()

    static func append(_ line: String) {
        let text = "\(stamp.string(from: Date()))  \(line)"
        queue.sync {
            var lines = read()
            lines.append(text)
            if lines.count > 150 { lines.removeFirst(lines.count - 150) }
            try? (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        }
    }

    static func read() -> [String] {
        guard let s = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return s.split(separator: "\n").map(String.init)
    }

    static func clear() {
        queue.sync { _ = try? FileManager.default.removeItem(at: url) }
    }
}

/// Writes a line to the Folder Log when the app crashes, and when the screen stops
/// responding for a few seconds, so the cause can be read on the phone afterwards.
enum Watchdog {
    private static var logPath: UnsafeMutablePointer<CChar>?
    private static var crashMessage: UnsafeMutablePointer<CChar>?
    private static var started = false

    static func start() {
        guard !started else { return }
        started = true
        logPath = strdup(FolderLog.url.path)
        crashMessage = strdup("CRASH: the app closed because of an error. The step above is where it happened.\n")
        NSSetUncaughtExceptionHandler { e in
            FolderLog.append("CRASH: \(e.name.rawValue) \(e.reason ?? "")")
        }
        for sig in [SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGTRAP, SIGFPE] {
            signal(sig) { s in
                // Only plain C calls here: nothing that allocates memory.
                if let p = Watchdog.logPath, let m = Watchdog.crashMessage {
                    let fd = open(p, O_WRONLY | O_APPEND | O_CREAT, 0o644)
                    if fd >= 0 {
                        _ = write(fd, m, strlen(m))
                        close(fd)
                    }
                }
                signal(s, SIG_DFL)
                raise(s)
            }
        }
        let thread = Thread {
            var stuckFor = 0
            while true {
                let answered = DispatchSemaphore(value: 0)
                DispatchQueue.main.async { answered.signal() }
                if answered.wait(timeout: .now() + 3) == .timedOut {
                    stuckFor += 3
                    if stuckFor == 3 || stuckFor % 15 == 0 {
                        FolderLog.append("The app is not responding (\(stuckFor) s). The step above is where it stopped.")
                    }
                    answered.wait()
                    FolderLog.append("The app is responding again.")
                    stuckFor = 0
                }
                Thread.sleep(forTimeInterval: 1)
            }
        }
        thread.name = "LoopPlayer.watchdog"
        thread.qualityOfService = .utility
        thread.start()
    }
}

/// Folders on the phone, read directly. This only works when the app runs without a
/// sandbox (installed with TrollStore from the .tipa); otherwise `places` is empty and
/// the app uses the system folder picker.
enum DeviceFolders {
    struct Place: Identifiable, Hashable {
        let id: String
        let name: String
        let icon: String
        let url: URL
    }

    /// /var/mobile on a phone (the app's home is /var/mobile/Containers/Data/Application/<id>).
    static var mobileRoot: URL {
        var u = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        for _ in 0..<4 { u.deleteLastPathComponent() }
        return u
    }

    static let places: [Place] = {
        let fm = FileManager.default
        var out: [Place] = []
        let icloud = mobileRoot.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        if (try? fm.contentsOfDirectory(atPath: icloud.path)) != nil {
            out.append(Place(id: "icloud", name: "iCloud Drive", icon: "icloud.fill", url: icloud))
        }
        if let local = onMyIPhone() {
            out.append(Place(id: "local", name: "On My iPhone", icon: "iphone", url: local))
        }
        return out
    }()

    static var available: Bool { !places.isEmpty }

    private static func onMyIPhone() -> URL? {
        let fm = FileManager.default
        let groups = mobileRoot.appendingPathComponent("Containers/Shared/AppGroup", isDirectory: true)
        guard let ids = try? fm.contentsOfDirectory(atPath: groups.path) else { return nil }
        var fallback: URL?
        for g in ids {
            let dir = groups.appendingPathComponent(g, isDirectory: true)
            let storage = dir.appendingPathComponent("File Provider Storage", isDirectory: true)
            guard (try? fm.contentsOfDirectory(atPath: storage.path)) != nil else { continue }
            let meta = dir.appendingPathComponent(".com.apple.mobile_container_manager.metadata.plist")
            if let dict = NSDictionary(contentsOf: meta),
               (dict["MCMMetadataIdentifier"] as? String) == "group.com.apple.FileProvider.LocalStorage" {
                return storage
            }
            if fallback == nil { fallback = storage }
        }
        return fallback
    }

    struct Listing {
        var folders: [URL] = []
        var media = 0
    }

    /// Subfolders and the number of songs/videos directly inside `url`.
    static func list(_ url: URL) -> Listing {
        var out = Listing()
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: url.path) else { return out }
        for name in names {
            var real = name
            if name.hasPrefix(".") {
                guard name.hasSuffix(".icloud"), name.count > 8 else { continue }
                real = String(name.dropFirst().dropLast(7))
            }
            let child = url.appendingPathComponent(name)
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: child.path, isDirectory: &isDir), isDir.boolValue, real == name {
                out.folders.append(url.appendingPathComponent(name, isDirectory: true))
            } else if MediaTypes.isMedia((real as NSString).pathExtension.lowercased()) {
                out.media += 1
            }
        }
        out.folders.sort { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        return out
    }
}
