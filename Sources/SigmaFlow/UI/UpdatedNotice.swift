import AppKit
import SwiftUI

/// The word after an update (docs/mockups/app-updates.html, 10):
///
///     UPDATED   SigmaFlow 1.1.0   What's new
///
/// Shown once, the first time a newer version opens, where the correction notice shows: just
/// above the Dock. It holds for `DS.Motion.updatedHold`, longer while the pointer is on it, and
/// What's new opens the release on GitHub. Never on a first install, which has no version
/// before it.
@MainActor
enum UpdatedNotice {
    private static let lastOpenedKey = "lastOpenedVersion"
    private static var panel: UpdatedNoticePanel?

    static func showIfJustUpdated() {
        guard let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              !CommandLine.arguments.contains("--snapshot-dir")
        else { return }
        let defaults = UserDefaults.standard
        let previous = defaults.string(forKey: lastOpenedKey)
        defaults.set(current, forKey: lastOpenedKey)
        guard let previous, current.compare(previous, options: .numeric) == .orderedDescending else { return }

        let notice = UpdatedNoticePanel(version: current) { panel?.dismiss(); panel = nil }
        panel = notice
        notice.present()
    }

    /// The release's own page, whose notes are the GitHub release's.
    static func releasePage(_ version: String) -> URL? {
        URL(string: "https://github.com/itsgrj/SigmaFlow/releases/tag/v\(version)")
    }
}

@MainActor
final class UpdatedNoticePanel: NSPanel {
    private let onDone: () -> Void
    private var isHovered = false
    private var holding: Task<Void, Never>?

    init(version: String, onDone: @escaping () -> Void) {
        self.onDone = onDone
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: DS.Material.hudWidth, height: DS.Material.toolbarHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        appearance = NSAppearance(named: .darkAqua)

        let hosting = HoverHostingView(rootView: UpdatedNoticeView(version: version) {
            if let page = UpdatedNotice.releasePage(version) { NSWorkspace.shared.open(page) }
            onDone()
        })
        hosting.onHoverChange = { [weak self] inside in self?.isHovered = inside }
        GlassCard.install(hosting, in: self)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func present() {
        layoutIfNeeded()
        if let screen = NSScreen.main ?? NSScreen.screens.first {
            let visible = screen.visibleFrame
            setFrameOrigin(NSPoint(x: visible.midX - frame.width / 2, y: visible.minY + DS.Material.hudBottomInset))
        }
        alphaValue = 0
        orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = DS.Motion.fadeIn
            animator().alphaValue = 1
        }
        isHovered = frame.contains(NSEvent.mouseLocation)
        holding = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(DS.Motion.updatedHold))
            // A pointer resting on it is someone reading it.
            while let self, self.isHovered, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(DS.Motion.statusHold))
            }
            guard !Task.isCancelled else { return }
            self?.onDone()
        }
    }

    func dismiss() {
        holding?.cancel()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = DS.Motion.fadeOut
            animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated { self?.orderOut(nil) }
        }
    }
}

struct UpdatedNoticeView: View {
    let version: String
    let onWhatsNew: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: DS.Space.roomy) {
            Eyebrow("Updated")
            Text("SigmaFlow \(version)")
                .font(DS.Font.transcript)
                .foregroundStyle(DS.Color.ink)
                .lineLimit(1)
            AppButton(title: "What’s new", kind: .secondary, action: onWhatsNew)
        }
        .padding(.horizontal, DS.Space.hudPadX)
        .padding(.vertical, DS.Space.hudPadY)
        .fixedSize()
        .environment(\.colorScheme, .dark)
    }
}
