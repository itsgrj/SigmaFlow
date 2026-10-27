import AppKit
import ImageIO
import SwiftUI

/// A camera photo or a screenshot, small, that opens larger beside it while the pointer is
/// on it (docs/mockups/live-notes.html, 3B: one size for both, never cut off).
struct PhotoThumb: View {
    let url: URL
    /// Seconds into the recording, for the caption under the larger view.
    let time: Double
    let side: PhotoPeek.Side
    var isScreenshot = false
    /// A transcript's pictures can be deleted: a faint bin in the larger view's corner.
    var onDelete: (() -> Void)? = nil
    @Environment(\.isSnapshotting) private var isSnapshotting

    var body: some View {
        Group {
            if let image = ThumbCache.image(url) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                DS.Color.controlFill
            }
        }
        .frame(
            width: isScreenshot ? DS.Material.screenThumbWidth : DS.Material.photoThumbWidth,
            height: isScreenshot ? DS.Material.screenThumbHeight : DS.Material.photoThumbHeight)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.chip))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.chip).strokeBorder(DS.Color.border, lineWidth: DS.Border.hairline))
        // Not in a snapshot run: the offscreen renderer paints an AppKit view as its
        // "unsupported" stand-in.
        .background {
            if !isSnapshotting {
                PointerArea(onHover: { inside, view in
                    if inside, let image = ThumbCache.image(url) {
                        PhotoPeek.shared.show(
                            image, caption: isScreenshot ? "Screenshot" : "Photo", time: time, from: view, side: side,
                            onDelete: onDelete)
                    } else {
                        PhotoPeek.shared.hideSoon()
                    }
                })
            }
        }
    }
}

/// Photos read once and kept while the app runs; a notes card redraws several times a second.
@MainActor
enum ThumbCache {
    private static let cache = NSCache<NSURL, NSImage>()
    private static let smallCache = NSCache<NSURL, NSImage>()

    /// A small copy for the list's stacks, read straight at that size: nine full photos a
    /// row down a long list would hold a lot of memory for pictures 30 points wide.
    static func small(_ url: URL) -> NSImage? {
        if let image = smallCache.object(forKey: url as NSURL) { return image }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let thumb = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: DS.Material.stackThumbPixels,
              ] as CFDictionary) else { return nil }
        let image = NSImage(cgImage: thumb, size: .zero)
        smallCache.setObject(image, forKey: url as NSURL)
        return image
    }

    static func image(_ url: URL) -> NSImage? {
        if let image = cache.object(forKey: url as NSURL) { return image }
        guard let image = NSImage(contentsOf: url) else { return nil }
        cache.setObject(image, forKey: url as NSURL)
        return image
    }
}

/// The larger view: a small floating window beside the picture, so nothing clips it.
@MainActor
final class PhotoPeek {
    static let shared = PhotoPeek()

    enum Side {
        /// To the left of the window the picture is in (the notes card in the corner).
        case leftOfWindow
        /// To the right of the picture itself (a transcript row).
        case rightOfPicture
    }

    private var panel: NSPanel?
    /// The picture the view is open for. Only its going away closes the view: a row scrolled
    /// off takes its view with it, but nothing else that leaves does.
    private weak var source: NSView?
    /// The view has a bin to reach, so it waits for the pointer to travel onto it.
    private var isReachable = false
    private var hiding: Task<Void, Never>?

    private init() {}

    func show(
        _ image: NSImage, caption: String, time: Double, from view: NSView, side: Side,
        onDelete: (() -> Void)? = nil
    ) {
        guard let window = view.window, let screen = window.screen ?? NSScreen.main else { return }
        hiding?.cancel()
        let picture = window.convertToScreen(view.convert(view.bounds, to: nil))
        let content = PeekView(
            image: image, caption: caption, time: MeetingNaming.clock(time),
            onDelete: onDelete.map { delete in { PhotoPeek.shared.hide(); delete() } })
        let panel = self.panel ?? Self.makePanel()
        self.panel = panel
        // One view, given new content each time. A new one in its place threw the old away,
        // and the old one's pointer tracker, leaving, closed the view just opened (20 Oct 2026:
        // every peek after the first on a transcript flashed and went).
        let hosting: NSHostingView<PeekView>
        if let shown = panel.contentView as? NSHostingView<PeekView> {
            shown.rootView = content
            hosting = shown
        } else {
            hosting = NSHostingView(rootView: content)
            panel.contentView = hosting
        }
        let size = hosting.fittingSize

        let gap = DS.Material.peekGap
        var x = side == .leftOfWindow ? window.frame.minX - gap - size.width : picture.maxX + gap
        if x < screen.visibleFrame.minX { x = window.frame.maxX + gap }
        var y = picture.midY - size.height / 2
        y = min(max(y, screen.visibleFrame.minY + gap), screen.visibleFrame.maxY - size.height - gap)

        source = view
        isReachable = onDelete != nil
        // Only a view with a bin takes the pointer; the notes card's lets clicks through.
        panel.ignoresMouseEvents = !isReachable
        panel.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
        panel.orderFrontRegardless()
    }

    func hide() {
        hiding?.cancel()
        hiding = nil
        panel?.orderOut(nil)
    }

    /// A picture's tracker is going away (its row scrolled off, the transcript closed): the
    /// view goes too, if it was that picture's.
    fileprivate func hide(ifShownFrom view: NSView) {
        if source === view { hide() }
    }

    /// The pointer left the picture: a view with a bin waits a moment, in case the pointer
    /// is on its way onto it; any other goes at once.
    func hideSoon() {
        guard isReachable else { return hide() }
        hiding?.cancel()
        hiding = Task { @MainActor in
            try? await Task.sleep(for: .seconds(DS.Motion.peekLinger))
            guard !Task.isCancelled else { return }
            hide()
        }
    }

    /// The pointer is on the view itself.
    fileprivate func hold() {
        hiding?.cancel()
        hiding = nil
    }

    private static func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        // Above the notes card, which sits at the status bar's level.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.appearance = NSAppearance(named: .darkAqua)
        return panel
    }

    private struct PeekView: View {
        let image: NSImage
        let caption: String
        let time: String
        let onDelete: (() -> Void)?

        var body: some View {
            VStack(spacing: DS.Space.snug) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: DS.Material.peekWidth, height: DS.Material.peekHeight)
                    .clipShape(RoundedRectangle(cornerRadius: DS.Radius.chip))
                    // Faint, in the corner (Gokul, 16 Oct 2026, round 2, 5).
                    .overlay(alignment: .bottomTrailing) {
                        if let onDelete {
                            PeekDelete(action: onDelete).padding(DS.Material.peekDeleteInset)
                        }
                    }
                HStack {
                    Text(caption)
                    Spacer()
                    Text(time)
                }
                .font(DS.Font.monoSmall)
                .foregroundStyle(DS.Color.dim)
            }
            .padding(DS.Space.snug)
            .background(DS.Color.counterBackdrop, in: RoundedRectangle(cornerRadius: DS.Radius.card))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.card).strokeBorder(DS.Color.borderStrong, lineWidth: DS.Border.hairline))
            .background {
                if onDelete != nil {
                    PointerArea(onHover: { inside, _ in
                        if inside { PhotoPeek.shared.hold() } else { PhotoPeek.shared.hideSoon() }
                    })
                }
            }
            .environment(\.colorScheme, .dark)
        }
    }

    private struct PeekDelete: View {
        let action: () -> Void
        @State private var isHovering = false

        var body: some View {
            Button(action: action) {
                CarbonIcon(name: "trash-can", size: DS.Control.iconSizeTiny)
                    .foregroundStyle(DS.Color.ink)
                    .frame(width: DS.Material.peekDeleteSize, height: DS.Material.peekDeleteSize)
                    .background(
                        isHovering ? DS.Color.peekDeleteFillHover : DS.Color.peekDeleteFill,
                        in: RoundedRectangle(cornerRadius: DS.Radius.chip))
                    .opacity(isHovering ? 1 : DS.Material.peekDeleteRest)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { isHovering = $0 }
        }
    }
}

/// Where a deleted picture was, for as long as Undo is offered: a dashed outline of the
/// same size, and Undo in it.
struct PictureUndo: View {
    let isScreenshot: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text("Undo")
                .font(isScreenshot ? DS.Font.caption : DS.Font.monoSmall)
                .underline()
                .foregroundStyle(DS.Color.inkSecondary)
                .frame(
                    width: isScreenshot ? DS.Material.screenThumbWidth : DS.Material.photoThumbWidth,
                    height: isScreenshot ? DS.Material.screenThumbHeight : DS.Material.photoThumbHeight)
                .overlay(
                    RoundedRectangle(cornerRadius: DS.Radius.chip)
                        .strokeBorder(DS.Color.borderStrong, style: StrokeStyle(lineWidth: DS.Border.hairline, dash: [DS.Space.tight, DS.Space.tight])))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .handCursor()
    }
}

/// Watches the pointer over the view it sits behind, whether or not SigmaFlow is the app in
/// front: sets a cursor, reports coming and going, or both. Clicks go straight through.
struct PointerArea: NSViewRepresentable {
    var cursor: NSCursor? = nil
    var onHover: (@MainActor (Bool, NSView) -> Void)? = nil

    func makeNSView(context: Context) -> PointerView {
        let view = PointerView()
        view.cursor = cursor
        view.onHover = onHover
        return view
    }

    func updateNSView(_ view: PointerView, context: Context) {
        view.cursor = cursor
        view.onHover = onHover
    }

    final class PointerView: NSView {
        var cursor: NSCursor?
        var onHover: (@MainActor (Bool, NSView) -> Void)?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(
                rect: .zero,
                options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                owner: self))
        }

        override func mouseEntered(with event: NSEvent) {
            cursor?.set()
            onHover?(true, self)
        }

        override func mouseMoved(with event: NSEvent) { cursor?.set() }

        override func mouseExited(with event: NSEvent) {
            onHover?(false, self)
            // Not while a button is held: a drag that slips off the bar keeps its cursor.
            guard cursor != nil, NSEvent.pressedMouseButtons == 0 else { return }
            NSCursor.arrow.set()
        }

        override func removeFromSuperview() {
            // A row scrolled away while the pointer was on it: its larger view goes too.
            PhotoPeek.shared.hide(ifShownFrom: self)
            super.removeFromSuperview()
        }
    }
}

/// A click on the view it sits behind, wherever in it, words included (a transcript line:
/// click to play from it, docs/mockups/conversation-playback.html, 5B). A drag is not a click,
/// so words can still be selected for copying.
///
/// SwiftUI's tap gestures never hear a click on selectable text: the text tracks the press
/// itself and swallows the release (tested 20 Oct 2026). So one watcher on the app's own
/// events serves every area, the press is noted on the way down, and the release is looked
/// for either as it comes or, when the text has already swallowed it, right after.
struct ClickArea: NSViewRepresentable {
    /// Off while something covers the view (a question, a picture opened large).
    var isActive = true
    let onClick: @MainActor () -> Void

    func makeNSView(context: Context) -> ClickView {
        let view = ClickView()
        view.isActive = isActive
        view.onClick = onClick
        return view
    }

    func updateNSView(_ view: ClickView, context: Context) {
        view.isActive = isActive
        view.onClick = onClick
    }

    final class ClickView: NSView {
        var isActive = true
        var onClick: (@MainActor () -> Void)?

        private static let shown = NSHashTable<ClickView>.weakObjects()
        private static var monitor: Any?
        private static var press: (point: NSPoint, window: Int)?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil { Self.shown.add(self) } else { Self.shown.remove(self) }
            Self.watch()
        }

        private static func watch() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { event in
                MainActor.assumeIsolated {
                    if event.type == .leftMouseDown {
                        // A double click selects a word; only single clicks play.
                        press = event.clickCount <= 1 ? (event.locationInWindow, event.windowNumber) : nil
                        if press != nil { lookForSwallowedRelease() }
                    } else {
                        finish(event)
                    }
                }
                return event
            }
        }

        /// Once the button is up: a release this watcher saw has already been dealt with
        /// (`press` is gone); otherwise the text kept it, and it is read from the app.
        private static func lookForSwallowedRelease() {
            // Default mode only: never inside the text's own tracking of the press.
            RunLoop.main.perform(inModes: [.default]) {
                MainActor.assumeIsolated {
                    guard let press else { return }
                    if NSEvent.pressedMouseButtons & 1 != 0 {
                        DispatchQueue.main.asyncAfter(deadline: .now() + DS.Motion.clickRecheck) { lookForSwallowedRelease() }
                        return
                    }
                    if let release = NSApp.currentEvent, release.type == .leftMouseUp {
                        finish(release)
                    } else if let window = NSApp.window(withWindowNumber: press.window) {
                        finish(at: window.mouseLocationOutsideOfEventStream, window: press.window)
                    }
                }
            }
        }

        private static func finish(_ release: NSEvent) {
            finish(at: release.locationInWindow, window: release.windowNumber)
        }

        private static func finish(at releasePoint: NSPoint, window releaseWindow: Int) {
            guard let press, press.window == releaseWindow else { return }
            self.press = nil
            let moved = hypot(press.point.x - releasePoint.x, press.point.y - releasePoint.y)
            guard moved < DS.Material.clickSlop else { return }
            for view in shown.allObjects where view.isActive && view.window?.windowNumber == releaseWindow {
                let point = view.convert(press.point, from: nil)
                // Bounds and what is on screen of them: a line scrolled under the card's edge
                // is not clickable there.
                if view.bounds.contains(point), view.visibleRect.contains(point) {
                    view.onClick?()
                    return
                }
            }
        }
    }
}
