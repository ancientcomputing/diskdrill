import AppKit

/// Demo mode for App Store screenshots: `FOLDERDRILL_DEMO=<folder>` treats that folder (made by
/// packaging/screenshots/make_demo_home.py) as the home folder, uses a fixed window size and saves
/// nothing to the user's settings. `FOLDERDRILL_DEMO_SHOT` picks what the window shows;
/// packaging/screenshots/capture.sh sets both.
enum Demo {
    enum Shot: String {
        case home       // the home folder
        case library    // ~/Library
        case downloads  // ~/Downloads
        case trash      // ~/Library/Developer/Xcode, Move to Trash confirmation for DerivedData
        case setup      // first-run folder setup (sandboxed build)
    }

    static let home: String? = ProcessInfo.processInfo.environment["FOLDERDRILL_DEMO"]
        .map { (($0 as NSString).standardizingPath) }
    static var isActive: Bool { home != nil }
    static let shot = Shot(rawValue: ProcessInfo.processInfo.environment["FOLDERDRILL_DEMO_SHOT"] ?? "") ?? .home

    /// Window size in points; capture.sh centres the window on a 1440 x 900 background.
    static let windowSize = NSSize(width: 1180, height: 720)

    static var stack: [String] {
        let h = home!
        switch shot {
        case .home: return [h]
        case .library: return [h, h + "/Library"]
        case .downloads: return [h, h + "/Downloads"]
        case .trash: return [h, h + "/Library", h + "/Library/Developer", h + "/Library/Developer/Xcode"]
        case .setup: return []
        }
    }

    /// Sizes the window, then sets the selection (and the trash confirmation) once the scan is done.
    @MainActor static func start(_ model: Browser) {
        guard isActive else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            if let w = NSApp.windows.first(where: { $0.isVisible && $0.styleMask.contains(.titled) }) {
                w.setContentSize(windowSize)
                w.center()
            }
            NSApp.activate()
        }
        func whenScanned() {
            guard !model.isScanning, model.currentTotal != nil else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { whenScanned() }
                return
            }
            switch shot {
            case .home: model.selection = ["Library"]
            case .library: model.selection = ["Developer"]
            case .downloads: model.selection = []
            case .trash:
                model.selection = ["DerivedData"]
                model.requestTrash(["DerivedData"])
            case .setup: break
            }
        }
        if shot != .setup { whenScanned() }
    }
}
