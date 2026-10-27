import AppKit
import SwiftUI

/// The floating glass slab that appears while you hold the key.
///
/// The single most important property here is that this panel **never becomes key**.
/// If it did, the user's text field would lose focus and `TextInjector` would have
/// nothing to insert into. Hence `.nonactivatingPanel` plus `canBecomeKey == false`.
@MainActor
final class HUDPanel: NSPanel {
    init(controller: DictationController) {
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
        isMovableByWindowBackground = false
        ignoresMouseEvents = true

        isOpaque = false
        backgroundColor = .clear
        // The window server draws the shadow, following the card's rounded shape.
        hasShadow = true
        appearance = NSAppearance(named: .darkAqua)

        var view = HUDView(controller: controller)
        // SwiftUI measures the card and reports its height; the window follows (`fit`). The
        // hop to the next turn of the run loop keeps the resize out of SwiftUI's own update.
        view.onHeightChange = { [weak self] height in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.fit(height: height) }
            }
        }
        let hosting = NSHostingView(rootView: view)
        // The hosting view is a tall canvas with the card drawn at its top, pinned to the top
        // of the glass and running past the window's bottom edge, where the window clips it.
        // The window's height alone decides how much of the card shows, so it can glide while
        // the words above stay exactly where they are. No Auto Layout: the first version of
        // the glide let constraints place the card, they went stale after a resize, and the
        // words were drawn outside the window.
        GlassCard.install(hosting, in: self, canvasHeight: DS.Material.hudCanvasHeight)
    }

    /// The height the window is at, or gliding to.
    private var cardHeight: CGFloat = 0
    /// When the panel last began to fade in. A glide only runs once the fade is done; until
    /// then the window snaps, so the card never grows while it is still arriving.
    private var presentedAt = Date.distantPast

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Sizes the window to the card, parked just above the Dock and horizontally centered.
    /// The bottom edge never moves, so growth goes upward.
    ///
    /// Growing while the panel is settled on screen glides ("Make room"); the first word of
    /// the new line waits in `WordFlowText` until the room is there. Shrinking, and anything
    /// while hidden or fading in, is immediate: a shrink happens when a new session clears
    /// the last one's words, and a glide there would read as the card collapsing.
    private func fit(height: CGFloat, animated: Bool = true) {
        guard height > 0, height != cardHeight else { return }
        let grows = height > cardHeight
        cardHeight = height
        let target = parkedFrame(height: height)
        let settled = isVisible && Date().timeIntervalSince(presentedAt) > DS.Motion.fadeIn
        guard animated, grows, settled else {
            setFrame(target, display: true)
            invalidateShadow()
            return
        }
        let curve = DS.Motion.hudGrowCurve
        NSAnimationContext.runAnimationGroup { context in
            context.duration = DS.Motion.hudGrow
            context.timingFunction = CAMediaTimingFunction(controlPoints: curve.0, curve.1, curve.2, curve.3)
            animator().setFrame(target, display: true)
        } completionHandler: { [weak self] in
            // AppKit always calls this on the main thread.
            MainActor.assumeIsolated { self?.invalidateShadow() }
        }
    }

    /// `NSScreen.main` is the screen with the *key window* — and an accessory app with a
    /// non-activating panel never has one, so it can be nil. Falling back to `screens.first`
    /// keeps the HUD on-screen instead of stranding it at the origin.
    private func parkedFrame(height: CGFloat) -> NSRect {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else {
            Log.app.error("no screen available to position HUD")
            return NSRect(origin: frame.origin, size: NSSize(width: frame.width, height: height))
        }
        let visible = screen.visibleFrame
        return NSRect(
            x: visible.midX - frame.width / 2,
            y: visible.minY + DS.Material.hudBottomInset,
            width: frame.width,
            height: height
        )
    }

    func present() {
        // Every active state change (starting → listening → finishing) calls this. Without
        // the early exit the panel would reset to alpha 0 and re-fade on each one, which
        // reads as a flicker mid-utterance.
        guard !isVisible || alphaValue < 1 else { return }

        presentedAt = Date()
        if cardHeight > 0 {
            setFrame(parkedFrame(height: cardHeight), display: true)
        }
        alphaValue = 0
        orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = DS.Motion.fadeIn
            animator().alphaValue = 1
        }
    }

    func dismiss() {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = DS.Motion.fadeOut
            animator().alphaValue = 0
        } completionHandler: { [weak self] in
            // AppKit always calls this on the main thread.
            MainActor.assumeIsolated { self?.orderOut(nil) }
        }
    }
}

/// The whole card surface: the desktop blurred behind the window, the tint and 1 px edge
/// over it, cut to the card's radius. Shared by the dictation HUD and the correction notice,
/// whose SwiftUI views draw only their contents.
///
/// It is the panel's content view, not a SwiftUI background, and that is the whole point.
/// A behind-window blur is drawn by the window server from the effect view's frame; no
/// clip shape, layer mask or corner radius on anything above it in the SwiftUI tree can
/// round it, which is why the blur showed as light squares at the card's corners when the
/// glass was nested inside the hosting view. As the content view it owns the window, and
/// `maskImage` (the one shaping AppKit honours for this blur) rounds the blur, the window
/// shadow and the hit shape together. The hosting view is pinned inside it at required
/// priorities, so its ideal size drives the window through Auto Layout: a growing
/// transcript enlarges the window and an emptied one shrinks it back.
@MainActor
enum GlassCard {
    /// With a `canvasHeight`, the hosting view is placed by frame instead: that tall, pinned to
    /// the top of the glass, running past the window's bottom edge. The caller then sets the
    /// window height itself (the HUD, to glide it) and the SwiftUI content draws at the top
    /// of the canvas. Without one, the hosting view's ideal size drives the window.
    static func install<Content: View>(
        _ hosting: NSHostingView<Content>,
        in panel: NSPanel,
        radius: CGFloat = DS.Radius.hud,
        canvasHeight: CGFloat? = nil,
        fills: Bool = false
    ) {
        let glass = NSVisualEffectView()
        glass.material = .hudWindow
        glass.blendingMode = .behindWindow
        glass.state = .active
        glass.appearance = NSAppearance(named: .darkAqua)
        glass.maskImage = cornerMask(radius: radius)
        panel.contentView = glass

        // The card's tint and 1 px edge belong to the window too, not to the SwiftUI tree.
        // SwiftUI animates its height when a word wraps onto a new line while the window
        // jumps to the final size at once; with the tint drawn in SwiftUI, the bare glass
        // showed above and below it for the length of the animation, a second card around
        // the first. Drawn here, the tint is always exactly the window.
        let tint = NSView()
        tint.wantsLayer = true
        tint.layer?.backgroundColor = NSColor(DS.Color.hudGlass).cgColor
        tint.layer?.borderColor = NSColor(DS.Color.borderStrong).cgColor
        tint.layer?.borderWidth = DS.Border.hairline
        tint.layer?.cornerRadius = radius
        tint.layer?.cornerCurve = .circular  // the same curve as the mask below
        tint.layer?.masksToBounds = true
        tint.frame = glass.bounds
        tint.autoresizingMask = [.width, .height]
        glass.addSubview(tint)

        // Fills: the window's size is the user's (live notes), and the content takes all of it.
        if fills {
            hosting.sizingOptions = []
            hosting.frame = glass.bounds
            hosting.autoresizingMask = [.width, .height]
            glass.addSubview(hosting)
            return
        }

        if let canvasHeight {
            hosting.sizingOptions = []
            hosting.frame = NSRect(
                x: 0, y: glass.bounds.height - canvasHeight,
                width: glass.bounds.width, height: canvasHeight
            )
            // Non-flipped: a flexible bottom margin keeps the top edge fixed as the window
            // resizes, mid-glide included.
            hosting.autoresizingMask = [.width, .minYMargin]
            glass.addSubview(hosting)
            return
        }

        hosting.sizingOptions = [.intrinsicContentSize]
        hosting.translatesAutoresizingMaskIntoConstraints = false
        for axis in [NSLayoutConstraint.Orientation.horizontal, .vertical] {
            hosting.setContentHuggingPriority(.required, for: axis)
            hosting.setContentCompressionResistancePriority(.required, for: axis)
        }
        glass.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: glass.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: glass.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: glass.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: glass.bottomAnchor),
        ])
    }

    /// A stretchable rounded-rectangle mask: the corners stay at `radius`, the middle
    /// stretches to whatever size the card grows to.
    private static func cornerMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}
