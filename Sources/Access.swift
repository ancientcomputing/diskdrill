import AppKit
import Darwin

/// App Sandbox support. In the Mac App Store build Folder Drill can only read folders the user picked
/// in an open panel. It keeps that access across launches with security-scoped bookmarks. Outside
/// the sandbox (the GitHub build) every folder counts as granted.
enum Sandbox {
    static let isActive = ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil

    /// The user's home folder. `NSHomeDirectory()` is the app's container when sandboxed.
    /// In demo mode, the demo home (see Demo.swift).
    static let home: String = {
        if let demo = Demo.home { return demo }
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir { return String(cString: dir) }
        return NSHomeDirectory()
    }()
}

@MainActor
enum Grants {
    private static let key = "grantedFolders"
    /// Folders we hold access to, resolved from bookmarks.
    private static var granted: [String: Data] = [:]

    /// Resolves the saved bookmarks and starts access to each. Call once at launch.
    static func restore() {
        guard Sandbox.isActive, !Demo.isActive else { return }
        let saved = UserDefaults.standard.array(forKey: key) as? [Data] ?? []
        for data in saved {
            var stale = false
            guard let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope,
                                     relativeTo: nil, bookmarkDataIsStale: &stale),
                  url.startAccessingSecurityScopedResource() else { continue }
            let fresh = stale ? (try? url.bookmarkData(options: .withSecurityScope,
                                                      includingResourceValuesForKeys: nil, relativeTo: nil)) : nil
            granted[url.standardizedFileURL.path] = fresh ?? data
        }
        save()
    }

    /// Whether Folder Drill may read `path`: it's a granted folder or inside one.
    static func hasAccess(_ path: String) -> Bool {
        guard Sandbox.isActive else { return true }
        return granted.keys.contains { g in path == g || path.hasPrefix(g == "/" ? "/" : g + "/") }
    }

    /// Remembers a folder the user just picked in an open panel.
    static func grant(_ url: URL) {
        guard Sandbox.isActive, !hasAccess(url.path) else { return }
        guard let data = try? url.bookmarkData(options: .withSecurityScope,
                                               includingResourceValuesForKeys: nil, relativeTo: nil) else { return }
        granted[url.standardizedFileURL.path] = data
        save()
    }

    private static func save() {
        guard !Demo.isActive else { return }
        UserDefaults.standard.set(Array(granted.values), forKey: key)
    }

    /// Asks for a folder to measure, starting at `start`. Returns its path, now readable.
    static func pickFolder(startingAt start: String) -> String? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = false
        panel.showsHiddenFiles = true
        panel.prompt = "Measure"
        panel.message = "Choose a folder for Folder Drill to measure. It reads the folders inside it, and changes nothing unless you move an item to the Trash."
        panel.directoryURL = URL(fileURLWithPath: start)
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        grant(url)
        return url.standardizedFileURL.path
    }
}

extension String {
    /// `/Users/me/x` as `~/x`, using the real home folder.
    var tildePath: String {
        let home = Sandbox.home
        if self == home { return "~" }
        return hasPrefix(home + "/") ? "~" + dropFirst(home.count) : self
    }
}
