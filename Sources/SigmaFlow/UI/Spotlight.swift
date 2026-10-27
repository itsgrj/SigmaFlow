import AppKit

/// Autowrite's spotlight (docs/mockups/write-a-reply.html round 3, 4-11): while it listens
/// and writes, everything on screen but the window the words will go into is dimmed, so the
/// mode can't be mistaken for a dictation. One borderless, click-through window per screen,
/// above apps and below the overlay. It is SigmaFlow's own, so the screen Autowrite reads
/// never has it in. It fades in and out; nothing blinks.
@MainActor
final class Spotlight {
    private var windows: [NSWindow] = []

    /// Dims around the front app's front window. Nothing happens when there is no such
    /// window (the desktop, SigmaFlow itself): dimming the whole screen would say nothing.
    func show() {
        guard windows.isEmpty, let hole = Self.frontWindowFrame() else { return }
        for screen in NSScreen.screens {
            let window = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.ignoresMouseEvents = true
            window.isReleasedWhenClosed = false
            window.level = .floating
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            let view = SpotlightView(frame: NSRect(origin: .zero, size: screen.frame.size))
            view.hole = hole.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY)
            window.contentView = view
            window.alphaValue = 0
            window.orderFrontRegardless()
            windows.append(window)
        }
        let arriving = windows
        NSAnimationContext.runAnimationGroup { context in
            context.duration = DS.Motion.fadeIn
            for window in arriving { window.animator().alphaValue = 1 }
        }
    }

    func hide() {
        guard !windows.isEmpty else { return }
        let leaving = windows
        windows = []
        NSAnimationContext.runAnimationGroup { context in
            context.duration = DS.Motion.fadeOut
            for window in leaving { window.animator().alphaValue = 0 }
        } completionHandler: {
            // AppKit always calls this on the main thread.
            MainActor.assumeIsolated { for window in leaving { window.orderOut(nil) } }
        }
    }

    /// The front app's frontmost ordinary window, in screen coordinates (origin bottom left).
    /// Window bounds need no Screen Recording; only window titles do.
    private static func frontWindowFrame() -> NSRect? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]]
        else { return nil }
        // Front to back: the first ordinary window of the front app is the one in use.
        for info in list {
            guard info[kCGWindowOwnerPID as String] as? pid_t == app.processIdentifier,
                  info[kCGWindowLayer as String] as? Int == 0,
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds),
                  rect.width > 0, rect.height > 0
            else { continue }
            // Window bounds count down from the top of the main screen; AppKit counts up.
            let top = NSScreen.screens.first?.frame.maxY ?? 0
            return NSRect(x: rect.minX, y: top - rect.maxY, width: rect.width, height: rect.height)
        }
        return nil
    }
}

private final class SpotlightView: NSView {
    var hole: NSRect = .zero

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(rect: bounds)
        path.append(NSBezierPath(roundedRect: hole, xRadius: DS.Material.spotlightCorner, yRadius: DS.Material.spotlightCorner))
        path.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(DS.Material.spotlightDim).setFill()
        path.fill()
    }
}
