import AppKit
import SwiftUI

@main
struct FolderDrillApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    @State private var model = Browser(stack: Self.startStack)

    /// Where the window opens:
    /// - demo mode: the shot's folders (Demo.swift)
    /// - `-start <folder>` (e.g. `open FolderDrill.app --args -start /Volumes/X`). A bare path
    ///   argument would make AppKit treat the launch as "open a document" and skip the window.
    /// - the folder chosen last time, else the home folder.
    /// In the sandbox only granted folders count; with none, the window shows the folder setup screen.
    private static var startStack: [String] {
        Grants.restore()
        if Demo.isActive { return Demo.stack }
        let candidates = [UserDefaults.standard.string(forKey: "start"),
                          UserDefaults.standard.string(forKey: "lastRoot"),
                          Sandbox.home]
        for case let arg? in candidates {
            let path = ((arg as NSString).expandingTildeInPath as NSString).standardizingPath
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue,
               Grants.hasAccess(path) {
                return [path]
            }
        }
        return []
    }

    var body: some Scene {
        Window("Folder Drill", id: "main") {
            ContentView(model: model)
                .frame(minWidth: 760, minHeight: 480)
                .onAppear { Demo.start(model) }
        }
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Folder Drill") { Links.showAbout() }
            }
            CommandGroup(replacing: .help) {
                Button("Folder Drill Support") { Links.open(Links.support) }
                Button("Email Support…") { Links.open(Links.email) }
                Button("Report an Issue on GitHub…") { Links.open(Links.issues) }
                Divider()
                Button("Privacy Policy") { Links.open(Links.privacy) }
                Button("Folder Drill on GitHub") { Links.open(Links.source) }
            }
            CommandMenu("Go") {
                Button("Back") { model.back() }
                    .keyboardShortcut("[", modifiers: .command)
                    .disabled(model.stack.count < 2)
                Button("Home") { model.goHome() }
                    .keyboardShortcut("h", modifiers: [.command, .shift])
                Button("Choose Folder…") { model.chooseFolder() }
                    .keyboardShortcut("o", modifiers: .command)
                Divider()
                Button("Move to Trash") { model.requestTrash(model.selection) }
                    .keyboardShortcut(.delete, modifiers: .command)
                    .disabled(model.selection.isEmpty)
                Divider()
                Button("Rescan") { model.rescan() }
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(model.needsFolder)
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

private func fmt(_ bytes: Int64) -> String {
    bytes.formatted(.byteCount(style: .file))
}

struct ContentView: View {
    @Bindable var model: Browser

    var body: some View {
        if model.needsFolder {
            SetupView(model: model)
        } else {
            browser
        }
    }

    private var browser: some View {
        let rows = model.rows
        let total = model.currentTotal
        let denominator = max(total?.size ?? model.partialTotal, 1)

        return VStack(spacing: 0) {
            header(total: total)
            Divider()
            if let lvl = model.currentListing, !lvl.ok {
                ContentUnavailableView("Can't read this folder",
                                       systemImage: "lock.fill",
                                       description: Text("Permission denied. Grant Folder Drill Full Disk Access and rescan."))
            } else if model.currentListing == nil {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                table(rows: rows, denominator: denominator)
            }
            Divider()
            footer(total: total)
        }
        .navigationTitle((model.current as NSString).lastPathComponent)
        .confirmationDialog(trashTitle,
                            isPresented: Binding(get: { !model.trashCandidates.isEmpty },
                                                 set: { if !$0 { model.trashCandidates = [] } })) {
            Button("Move to Trash", role: .destructive) { model.confirmTrash() }
            Button("Cancel", role: .cancel) { model.trashCandidates = [] }
        } message: {
            let (bytes, partial) = model.trashCandidatesSize
            Text("This frees \(partial ? "at least " : "")\(fmt(bytes)). You can get items back from the Trash until it's emptied.")
        }
        .alert("Some items couldn't be moved to the Trash",
               isPresented: Binding(get: { !model.trashErrors.isEmpty },
                                    set: { if !$0 { model.trashErrors = [] } })) {
            Button("OK") { model.trashErrors = [] }
        } message: {
            Text(model.trashErrors.joined(separator: "\n"))
        }
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button { model.back() } label: { Image(systemName: "chevron.left") }
                    .help("Back (⌘[)")
                    .disabled(model.stack.count < 2)
            }
            ToolbarItemGroup {
                Button { model.chooseFolder() } label: { Image(systemName: "folder.badge.gearshape") }
                    .help("Choose a different starting folder (⌘O)")
                Button { reveal(model.current) } label: { Image(systemName: "magnifyingglass") }
                    .help("Reveal current folder in Finder")
                Button { model.rescan() } label: { Image(systemName: "arrow.clockwise") }
                    .help("Rescan (⌘R)")
            }
        }
    }

    // MARK: Header (breadcrumb + total)

    private func header(total: DirInfo?) -> some View {
        HStack(alignment: .firstTextBaseline) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(Array(model.stack.enumerated()), id: \.offset) { i, p in
                        if i > 0 { Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary) }
                        Button(crumbName(p, first: i == 0)) { model.pop(to: i) }
                            .buttonStyle(.plain)
                            .focusable(false)
                            .fontWeight(i == model.stack.count - 1 ? .semibold : .regular)
                            .foregroundStyle(i == model.stack.count - 1 ? .primary : .secondary)
                    }
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 0) {
                if let total {
                    Text(fmt(total.size)).font(.title2.monospacedDigit()).bold()
                    Text("\(total.fileCount.formatted()) files").font(.caption).foregroundStyle(.secondary)
                } else {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("≥ " + fmt(model.partialTotal)).font(.title2.monospacedDigit()).bold()
                    }
                    Text("calculating…").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var trashTitle: String {
        let c = model.trashCandidates
        return c.count == 1 ? "Move “\(c[0])” to the Trash?" : "Move \(c.count) items to the Trash?"
    }

    private func crumbName(_ p: String, first: Bool) -> String {
        if first {
            return p == Sandbox.home ? "Home" : p.tildePath
        }
        return (p as NSString).lastPathComponent
    }

    // MARK: Table

    private func table(rows: [Row], denominator: Int64) -> some View {
        Table(rows, selection: $model.selection, sortOrder: $model.sortOrder) {
            TableColumn("Name", value: \.name) { row in
                HStack(spacing: 6) {
                    Image(systemName: icon(row))
                        .foregroundStyle(row.kind == .dir ? Color.accentColor : .secondary)
                        .frame(width: 16)
                    Text(row.name)
                        .foregroundStyle(row.hidden ? .secondary : .primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if row.unreadable > 0 {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .help("\(row.unreadable) folder(s) inside could not be read")
                    }
                }
            }
            .width(min: 200, ideal: 320)

            TableColumn("Size", value: \.sortSize) { row in
                if let s = row.size {
                    Text(row.kind == .mount ? "—" : fmt(s)).monospacedDigit()
                        .frame(maxWidth: .infinity, alignment: .trailing)
                } else {
                    ProgressView().controlSize(.mini).frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            .width(min: 80, ideal: 100, max: 140)

            TableColumn("Share", value: \.sortSize) { row in
                if let s = row.size {
                    let f = Double(s) / Double(denominator)
                    HStack(spacing: 6) {
                        GeometryReader { g in
                            ZStack(alignment: .leading) {
                                Capsule().fill(.quaternary)
                                Capsule().fill(Color.accentColor.gradient)
                                    .frame(width: max(2, g.size.width * min(f, 1)))
                            }
                        }
                        .frame(height: 8)
                        Text(f.formatted(.percent.precision(.fractionLength(1))))
                            .monospacedDigit().font(.caption).foregroundStyle(.secondary)
                            .frame(width: 48, alignment: .trailing)
                    }
                }
            }
            .width(min: 120, ideal: 200)

            TableColumn("Files", value: \.sortItems) { row in
                Text(row.items.map { $0.formatted() } ?? "")
                    .monospacedDigit().foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 60, ideal: 80, max: 120)
        }
        .contextMenu(forSelectionType: String.self) { names in
            if names.count == 1, let n = names.first {
                if rows.first(where: { $0.name == n })?.isDrillable == true {
                    Button("Open") { model.drill(into: n) }
                }
                Button("Reveal in Finder") { reveal(model.path(of: n)) }
                Button("Copy Path") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(model.path(of: n), forType: .string)
                }
            } else if !names.isEmpty {
                Button("Reveal in Finder") { revealMany(names.map(model.path(of:))) }
            }
            if names.contains(where: { n in rows.first { $0.name == n }?.kind != .mount }) {
                Divider()
                Button("Move to Trash", role: .destructive) { model.requestTrash(names) }
            }
        } primaryAction: { names in
            if names.count == 1, let n = names.first { model.drill(into: n) }
        }
    }

    private func icon(_ row: Row) -> String {
        switch row.kind {
        case .dir: "folder.fill"
        case .file: "doc"
        case .symlink: "arrowshape.turn.up.right"
        case .mount: "externaldrive"
        }
    }

    // MARK: Footer

    private func footer(total: DirInfo?) -> some View {
        HStack {
            if model.isScanning {
                ProgressView().controlSize(.small)
                Text("Scanning… \(model.scannedItems.formatted()) items")
                    .monospacedDigit()
            } else {
                Image(systemName: "checkmark.circle").foregroundStyle(.green)
                Text("Scanned \(model.scannedItems.formatted()) items")
                    .monospacedDigit()
            }
            Spacer()
            if let total, total.unreadable > 0 {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text("\(total.unreadable) folders unreadable")
                Button("Grant Full Disk Access…") {
                    Links.open(Links.fullDiskAccess)
                }
            }
            Text("Double-click a folder to drill in · ⌘[ to go back")
                .foregroundStyle(.tertiary)
        }
        .font(.callout)
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }

    private func reveal(_ path: String) { revealMany([path]) }
    private func revealMany(_ paths: [String]) {
        NSWorkspace.shared.activateFileViewerSelecting(paths.map { URL(fileURLWithPath: $0) })
    }
}

/// First run of the sandboxed (Mac App Store) build: Folder Drill can only measure folders the user
/// chooses, so it asks for one.
struct SetupView: View {
    let model: Browser

    var body: some View {
        VStack(spacing: 18) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable().frame(width: 96, height: 96)
            Text("Where did your storage go?")
                .font(.title).bold()
            Text("Choose a folder and Folder Drill measures everything in it, hidden folders included, biggest first. Double-click a folder to drill into it.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 440)
            VStack(spacing: 10) {
                Button { model.chooseFolder(startingAt: Sandbox.home) } label: {
                    Text("Choose Your Home Folder…").frame(minWidth: 220)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                Button("Choose Another Folder or Drive…") { model.chooseFolder(startingAt: "/Volumes") }
                    .buttonStyle(.link)
            }
            Text("Folder Drill only reads the folder you choose, and remembers it for next time. It changes nothing unless you move an item to the Trash. Pick a different folder at any time with ⌘O.")
                .font(.footnote)
                .multilineTextAlignment(.center)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: 440)
            HStack(spacing: 14) {
                Link("Privacy Policy", destination: Links.privacy)
                Link("Support", destination: Links.support)
            }
            .font(.footnote)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("Folder Drill")
    }
}
