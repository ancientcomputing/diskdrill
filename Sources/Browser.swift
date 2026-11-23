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
    private static let listingQueue = DispatchQueue(label: "folderdrill.listing", qos: .userInteractive)

    /// The folder shown. Empty before the sandboxed app has been given a folder (`needsFolder`).
    var current: String { stack.last ?? "" }
    var needsFolder: Bool { stack.isEmpty }
    var isScanning: Bool { !inFlight.isEmpty }
    var currentListing: Level? { listings[current] }

    /// `stack`: the root folder, then the folders drilled into. Empty shows the folder setup screen.
    init(stack: [String]) {
        self.stack = stack
        for p in stack { open(p) }
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
        UserDefaults.standard.set(path, forKey: "lastRoot")
        stack = [path]
        selection = []
        rescan()
    }

    func rescan() {
        guard !needsFolder else { return }
        cancelAll()
        Scanner.resetClaims()
        listings = [:]
        roots = [:]
        Scanner.progress.withLock { $0 = 0 }
        scannedItems = 0
        open(current)
    }

    func chooseFolder(startingAt start: String? = nil) {
        if let path = Grants.pickFolder(startingAt: start ?? (needsFolder ? Sandbox.home : current)) {
            reset(to: path)
        }
    }

    /// The home folder; in the sandbox, asks for it first if it hasn't been granted.
    func goHome() {
        if Grants.hasAccess(Sandbox.home) {
            reset(to: Sandbox.home)
        } else {
            chooseFolder(startingAt: Sandbox.home)
        }
    }

    func path(of name: String) -> String { joinPath(current, name) }

    // MARK: - Move to Trash

    /// Items awaiting confirmation (names in the current folder). Non-empty shows the dialog.
    var trashCandidates: [String] = []
    /// Messages for items that could not be trashed. Non-empty shows an alert.
    var trashErrors: [String] = []

    func requestTrash(_ names: Set<String>) {
        let trashable = Set(rows.filter { $0.kind != .mount }.map(\.name))
        trashCandidates = names.filter { trashable.contains($0) }.sorted()
    }

    /// Known size of the pending items, and whether any are still being measured.
    var trashCandidatesSize: (bytes: Int64, partial: Bool) {
        let wanted = Set(trashCandidates)
        let picked = rows.filter { wanted.contains($0.name) }
        return (picked.reduce(0) { $0 + ($1.size ?? 0) }, picked.contains { $0.size == nil })
    }

    func confirmTrash() {
        let names = trashCandidates
        trashCandidates = []
        let base = current
        guard var lvl = listings[base] else { return }

        var removed: [LevelEntry] = []
        var errors: [String] = []
        for n in names {
            do {
                try FileManager.default.trashItem(at: URL(fileURLWithPath: joinPath(base, n)), resultingItemURL: nil)
                if let e = lvl.entries.first(where: { $0.name == n }) { removed.append(e) }
            } catch {
                errors.append("\(n): \(error.localizedDescription)")
            }
        }
        trashErrors = errors
        guard !removed.isEmpty else { return }

        // Forget everything at or under the trashed folders.
        for e in removed where e.kind == .dir {
            let p = joinPath(base, e.name)
            let pre = p + "/"
            let under = { (k: String) in k == p || k.hasPrefix(pre) }
            for (k, job) in inFlight where under(k) {
                job.token.cancel()
                Scanner.markCancelled(job.id)
                inFlight[k] = nil
            }
            roots = roots.filter { !under($0.key) }
            listings = listings.filter { !under($0.key) }
        }

        // Update this folder's listing.
        let gone = Set(removed.map(\.name))
        let removedFiles = removed.filter { $0.kind == .file || $0.kind == .symlink }
        let removedFileBytes = removedFiles.reduce(Int64(0)) { $0 + $1.size }
        lvl.entries.removeAll { gone.contains($0.name) }
        lvl.subdirs.removeAll { gone.contains($0) }
        lvl.fileBytes = max(0, lvl.fileBytes - removedFileBytes)
        lvl.fileCount -= removedFiles.count
        listings[base] = lvl

        // Subtract from this folder's cached totals and every cached ancestor.
        patch(base) { node in
            let dropped = node.children.filter { gone.contains($0.name) }
            return DirInfo(
                name: node.name,
                size: max(0, node.size - removedFileBytes - dropped.reduce(0) { $0 + $1.size }),
                fileCount: max(0, node.fileCount - removedFiles.count - dropped.reduce(0) { $0 + $1.fileCount }),
                unreadable: node.unreadable - dropped.reduce(0) { $0 + $1.unreadable },
                children: node.children.filter { !gone.contains($0.name) })
        }

        selection.subtract(gone)
        trySynthesizeUpward(from: base)
        updatePolling()
    }

    /// Applies `f` to the cached DirInfo for `path` in every cached tree that contains it,
    /// rebuilding the ancestors on the way with corrected totals.
    private func patch(_ path: String, _ f: (DirInfo) -> DirInfo) {
        for key in Array(roots.keys) {
            guard let root = roots[key] else { continue }
            if key == path {
                roots[key] = f(root)
            } else {
                let prefix = key == "/" ? "/" : key + "/"
                guard path.hasPrefix(prefix) else { continue }
                let rel = path.dropFirst(prefix.count).split(separator: "/").map(String.init)
                roots[key] = rebuild(root, rel[...], f)
            }
        }
    }

    private func rebuild(_ node: DirInfo, _ comps: ArraySlice<String>, _ f: (DirInfo) -> DirInfo) -> DirInfo {
        guard let first = comps.first else { return f(node) }
        guard let i = node.children.firstIndex(where: { $0.name == first }) else { return node }
        let old = node.children[i]
        let new = rebuild(old, comps.dropFirst(), f)
        var kids = node.children
        kids[i] = new
        return DirInfo(name: node.name,
                       size: node.size - old.size + new.size,
                       fileCount: node.fileCount - old.fileCount + new.fileCount,
                       unreadable: node.unreadable - old.unreadable + new.unreadable,
                       children: kids)
    }

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
