import AppKit

/// Web pages the app links to from the Help menu, the About panel and the setup screen.
/// App Review requires the privacy policy to be reachable from inside the app.
enum Links {
    static let privacy = URL(string: "https://thisbrain.ai/opensource/privacy.html#folderdrill")!
    static let support = URL(string: "https://thisbrain.ai/opensource/support.html#folderdrill")!
    static let source = URL(string: "https://github.com/ancientcomputing/folderdrill")!
    static let issues = URL(string: "https://github.com/ancientcomputing/folderdrill/issues")!
    static let license = URL(string: "https://www.apache.org/licenses/LICENSE-2.0")!
    static let company = URL(string: "https://thisbrain.ai")!
    static let email = URL(string: "mailto:neuron@thisbrain.ai?subject=Folder%20Drill")!
    static let fullDiskAccess = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!

    static func open(_ url: URL) { NSWorkspace.shared.open(url) }

    /// The standard About panel, with credits that say what the app is and where to go next.
    /// Copyright comes from NSHumanReadableCopyright.
    @MainActor static func showAbout() {
        let centered = NSMutableParagraphStyle()
        centered.alignment = .center
        centered.paragraphSpacing = 6
        let base: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.labelColor, .paragraphStyle: centered,
        ]
        let credits = NSMutableAttributedString()
        func text(_ s: String) { credits.append(NSAttributedString(string: s, attributes: base)) }
        func link(_ s: String, _ url: URL) {
            var a = base
            a[.link] = url
            credits.append(NSAttributedString(string: s, attributes: a))
        }

        text("Shows where your storage went, folder by folder, hidden folders included.\n")
        text("Free and open source under the ")
        link("Apache License 2.0", license)
        text(". ")
        link("Source code on GitHub", source)
        text(".\n")
        link("Support", support)
        text("  ·  ")
        link("Privacy Policy", privacy)
        text("  ·  ")
        link("thisbrain.ai", company)

        NSApp.activate()
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
    }
}
