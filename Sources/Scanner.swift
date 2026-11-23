import Darwin
import Foundation
import os

/// Immutable result of scanning one directory tree (directories only; files are summed).
final class DirInfo: @unchecked Sendable {
    let name: String
    let size: Int64          // allocated bytes on disk, recursive
    let fileCount: Int       // non-directory items, recursive
    let unreadable: Int      // directories that could not be opened, recursive
    let children: [DirInfo]

    init(name: String, size: Int64, fileCount: Int, unreadable: Int, children: [DirInfo]) {
        self.name = name
        self.size = size
        self.fileCount = fileCount
        self.unreadable = unreadable
        self.children = children
    }

    func child(named n: String) -> DirInfo? { children.first { $0.name == n } }
}

/// Thread-safe cancellation flag for a scan job.
final class CancelToken: @unchecked Sendable {
    private let flag = OSAllocatedUnfairLock(initialState: false)
    var isCancelled: Bool { flag.withLock { $0 } }
    func cancel() { flag.withLock { $0 = true } }
}

enum EntryKind: Sendable { case dir, file, symlink, mount }

struct LevelEntry: Sendable {
    let name: String
    let kind: EntryKind
    let size: Int64      // for files / symlinks only
    let hidden: Bool
}

/// One level (shallow listing) of a directory.
struct Level: Sendable {
    var ok = true
    var fileBytes: Int64 = 0
    var fileCount = 0
    var subdirs: [String] = []        // same-device subdirectories
    var entries: [LevelEntry] = []
}

func joinPath(_ parent: String, _ name: String) -> String {
    parent == "/" ? "/" + name : parent + "/" + name
}

enum Scanner {
    /// Total items visited by all scans (for the status line).
    static let progress = OSAllocatedUnfairLock(initialState: 0)

    /// Hard-link dedup: each (device, inode) with nlink > 1 is counted once,
    /// by whichever job saw it first. Jobs that get cancelled release their claims.
    private struct InodeKey: Hashable { let dev: dev_t; let ino: ino_t }
    private struct Claims { var owner: [InodeKey: UUID] = [:]; var cancelled: Set<UUID> = [] }
    private static let claims = OSAllocatedUnfairLock(initialState: Claims())

    private static func claim(_ st: stat, job: UUID) -> Bool {
        let key = InodeKey(dev: st.st_dev, ino: st.st_ino)
        return claims.withLock { c in
            if let o = c.owner[key], o == job || !c.cancelled.contains(o) { return false }
            c.owner[key] = job
            return true
        }
    }

    static func markCancelled(_ job: UUID) { claims.withLock { _ = $0.cancelled.insert(job) } }
    static func resetClaims() { claims.withLock { $0 = Claims() } }

    /// Reads one directory level using POSIX calls (fast, includes hidden items,
    /// never follows symlinks, never crosses onto other volumes).
    static func readLevel(_ path: String, dev knownDev: dev_t? = nil, keepEntries: Bool, job: UUID) -> Level {
        var lvl = Level()
        var dev: dev_t
        if let knownDev {
            dev = knownDev
        } else {
            var st = stat()
            guard lstat(path, &st) == 0 else { lvl.ok = false; return lvl }
            dev = st.st_dev
        }
        guard let dir = opendir(path) else { lvl.ok = false; return lvl }
        defer { closedir(dir) }
        let fd = dirfd(dir)

        while let ent = readdir(dir) {
            var st = stat()
            let (name, rc): (String, Int32) = withUnsafePointer(to: &ent.pointee.d_name) { p in
                p.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { c in
                    let n = String(cString: c)
                    if n == "." || n == ".." { return (n, -1) }
                    return (n, fstatat(fd, c, &st, AT_SYMLINK_NOFOLLOW))
                }
            }
            if rc != 0 { continue }
            let type = st.st_mode & S_IFMT
            let hidden = name.hasPrefix(".") || (st.st_flags & UInt32(UF_HIDDEN)) != 0
            if type == S_IFDIR {
                let sameDev = st.st_dev == dev
                if sameDev { lvl.subdirs.append(name) }
                if keepEntries {
                    lvl.entries.append(LevelEntry(name: name, kind: sameDev ? .dir : .mount, size: 0, hidden: hidden))
                }
            } else {
                let sz = Int64(st.st_blocks) * 512
                if st.st_nlink <= 1 || claim(st, job: job) { lvl.fileBytes += sz }
                lvl.fileCount += 1
                if keepEntries {
                    lvl.entries.append(LevelEntry(name: name, kind: type == S_IFLNK ? .symlink : .file,
                                                  size: sz, hidden: hidden))
                }
            }
        }
        let visited = lvl.fileCount + lvl.subdirs.count
        progress.withLock { $0 += visited }
        return lvl
    }

    /// Scans a whole tree synchronously on the calling (GCD) thread.
    /// The top couple of levels fan out with concurrentPerform.
    static func scan(path: String, job: UUID, token: CancelToken) -> DirInfo {
        let name = (path as NSString).lastPathComponent
        var st = stat()
        guard lstat(path, &st) == 0 else {
            return DirInfo(name: name, size: 0, fileCount: 0, unreadable: 1, children: [])
        }
        return scan(path: path, name: name, dev: st.st_dev, depth: 0, job: job, token: token)
    }

    private static func scan(path: String, name: String, dev: dev_t, depth: Int,
                             job: UUID, token: CancelToken) -> DirInfo {
        if token.isCancelled { return empty(name) }
        let lvl = readLevel(path, dev: dev, keepEntries: false, job: job)
        guard lvl.ok else { return DirInfo(name: name, size: 0, fileCount: 0, unreadable: 1, children: []) }

        let subs = lvl.subdirs
        var kids = [DirInfo?](repeating: nil, count: subs.count)
        if depth < 2 && subs.count > 1 {
            let lock = NSLock()
            DispatchQueue.concurrentPerform(iterations: subs.count) { i in
                let k = scan(path: joinPath(path, subs[i]), name: subs[i], dev: dev,
                             depth: depth + 1, job: job, token: token)
                lock.lock(); kids[i] = k; lock.unlock()
            }
        } else {
            for (i, d) in subs.enumerated() {
                kids[i] = scan(path: joinPath(path, d), name: d, dev: dev,
                               depth: depth + 1, job: job, token: token)
            }
        }
        return combine(name, lvl, kids.compactMap { $0 })
    }

    static func combine(_ name: String, _ lvl: Level, _ kids: [DirInfo]) -> DirInfo {
        var size = lvl.fileBytes, count = lvl.fileCount, unread = 0
        for k in kids {
            size += k.size
            count += k.fileCount
            unread += k.unreadable
        }
        return DirInfo(name: name, size: size, fileCount: count, unreadable: unread, children: kids)
    }

    private static func empty(_ name: String) -> DirInfo {
        DirInfo(name: name, size: 0, fileCount: 0, unreadable: 0, children: [])
    }
}
