import AppKit
import Foundation
import Observation

struct Row: Identifiable {
    let name: String
    let kind: EntryKind
    let hidden: Bool
    let size: Int64?      // nil = still calculating
    let items: Int?
    let unreadable: Int

    var id: String { name }
    var isDrillable: Bool { kind == .dir }
    var sortSize: Int64 { size ?? .max }   // still-calculating folders float to the top
    var sortItems: Int { items ?? (kind == .dir ? -1 : 0) }
}

@MainActor
@Observable
final class Browser {
    private(set) var stack: [String]
    var selection: Set<String> = []
    var sortOrder: [KeyPathComparator<Row>] = [KeyPathComparator(\Row.sortSize, order: .reverse)]
    private(set) var scannedItems = 0
    private(set) var startTime = Date()

    private var listings: [String: Level] = [:]
    private var roots: [String: DirInfo] = [:]          // completed scan results, keyed by absolute path
    private var inFlight: [String: (id: UUID, token: CancelToken)] = [:]
    private var poller: Timer?
    private static let listingQueue = DispatchQueue(label: "diskdrill.listing", qos: .userInteractive)

    var current: String { stack.last! }
    var isScanning: Bool { !inFlight.isEmpty }
    var currentListing: Level? { listings[current] }

    init(start: String = NSHomeDirectory()) {
        stack = [start]
        open(start)
    }

    // MARK: - Navigation

    func drill(into name: String) {
        guard let row = rows.first(where: { $0.name == name }), row.isDrillable else { return }
        let path = joinPath(current, name)
        stack.append(path)
        selection = []
        open(path)
    }

    func back() {
        guard stack.count > 1 else { return }
        let left = (current as NSString).lastPathComponent
        stack.removeLast()
        selection = [left]
        open(current)
    }

    func pop(to index: Int) {
        guard index < stack.count - 1 else { return }
        stack.removeSubrange((index + 1)...)
        selection = []
        open(current)
    }

    func reset(to path: String) {
        stack = [path]
        selection = []
        rescan()
    }

    func rescan() {
        cancelAll()
        Scanner.resetClaims()
        listings = [:]
        roots = [:]
        Scanner.progress.withLock { $0 = 0 }
        scannedItems = 0
        open(current)
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.showsHiddenFiles = true
        panel.directoryURL = URL(fileURLWithPath: current)
        if panel.runModal() == .OK, let url = panel.url {
            reset(to: url.path)
        }
    }

    func path(of name: String) -> String { joinPath(current, name) }

    // MARK: - Data for the UI

    var rows: [Row] {
        guard let lvl = listings[current] else { return [] }
        let base = current
        return lvl.entries.map { e in
            switch e.kind {
            case .dir:
                let info = lookup(joinPath(base, e.name))
                return Row(name: e.name, kind: .dir, hidden: e.hidden, size: info?.size,
                           items: info?.fileCount, unreadable: info?.unreadable ?? 0)
            case .mount:
                return Row(name: e.name, kind: .mount, hidden: e.hidden, size: 0, items: nil, unreadable: 0)
            case .file, .symlink:
                return Row(name: e.name, kind: e.kind, hidden: e.hidden, size: e.size, items: nil, unreadable: 0)
            }
        }
        .sorted(using: sortOrder)
    }

    /// Total of the current folder if fully known.
    var currentTotal: DirInfo? { lookup(current) }

    /// Sum of whatever is known so far (for the "at least" display while scanning).
    var partialTotal: Int64 {
        guard let lvl = listings[current] else { return 0 }
        return lvl.subdirs.reduce(lvl.fileBytes) { $0 + (lookup(joinPath(current, $1))?.size ?? 0) }
    }

    // MARK: - Scanning

    private func open(_ path: String) {
        if listings[path] != nil {
            startScans(for: path)
            return
        }
        // Own queue so a listing never waits behind running scan jobs.
        Self.listingQueue.async { [weak self] in
            let lvl = Scanner.readLevel(path, keepEntries: true, job: UUID())
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.listings[path] = lvl
                    self.startScans(for: path)
                }
            }
        }
    }

    private func startScans(for path: String) {
        guard let lvl = listings[path], lookup(path) == nil else { return }

        // If this exact folder is being scanned as one big job, split it into
        // per-subfolder jobs so results show up progressively.
        if let job = inFlight[path] {
            job.token.cancel()
            Scanner.markCancelled(job.id)
            inFlight[path] = nil
        }

        for d in lvl.subdirs {
            let child = joinPath(path, d)
            if lookup(child) != nil || hasInFlight(atOrUnder: child) { continue }
            let id = UUID()
            let token = CancelToken()
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let info = Scanner.scan(path: child, job: id, token: token)
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.finished(child, id: id, info: info) }
                }
            }
            inFlight[child] = (id, token)
        }
        trySynthesizeUpward(from: path)
        updatePolling()
    }

    private func finished(_ path: String, id: UUID, info: DirInfo) {
        guard inFlight[path]?.id == id else { return }   // cancelled or superseded
        inFlight[path] = nil
        roots[path] = info
        trySynthesizeUpward(from: (path as NSString).deletingLastPathComponent)
        updatePolling()
    }

    /// When every subfolder of a listed folder is known, build its DirInfo too,
    /// and keep going up the tree.
    private func trySynthesizeUpward(from start: String) {
        var p = start
        while roots[p] == nil, let lvl = listings[p] {
            var kids: [DirInfo] = []
            for d in lvl.subdirs {
                guard let k = lookup(joinPath(p, d)) else { return }
                kids.append(k)
            }
            roots[p] = Scanner.combine((p as NSString).lastPathComponent, lvl, kids)
            let parent = (p as NSString).deletingLastPathComponent
            if parent == p { return }
            p = parent
        }
    }

    private func hasInFlight(atOrUnder path: String) -> Bool {
        let prefix = path + "/"
        return inFlight.keys.contains { $0 == path || $0.hasPrefix(prefix) }
    }

    private func lookup(_ path: String) -> DirInfo? {
        if let r = roots[path] { return r }
        var comps: [String] = []
        var p = path
        while true {
            let parent = (p as NSString).deletingLastPathComponent
            if parent == p || parent.isEmpty { return nil }
            comps.append((p as NSString).lastPathComponent)
            p = parent
            if let r = roots[p] {
                var node = r
                for c in comps.reversed() {
                    guard let n = node.child(named: c) else { return nil }
                    node = n
                }
                return node
            }
        }
    }

    private func cancelAll() {
        for (_, job) in inFlight { job.token.cancel(); Scanner.markCancelled(job.id) }
        inFlight = [:]
        updatePolling()
    }

    private func updatePolling() {
        if isScanning {
            if poller == nil {
                startTime = Date()
                poller = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.scannedItems = Scanner.progress.withLock { $0 } }
                }
            }
        } else {
            poller?.invalidate()
            poller = nil
            scannedItems = Scanner.progress.withLock { $0 }
        }
    }
}
