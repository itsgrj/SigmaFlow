import AppKit
import SwiftUI

/// "Learn from your fixes in Dia too?", above the Dock, the first time you dictate into a
/// browser that doesn't have SigmaFlow's extension (docs/mockups/browser-extension.html, 02).
///
/// Once per browser, ever: it is the only moment SigmaFlow can know about, since without the
/// extension it can't see a fix in a browser at all. Add to Dia does what Settings,
/// Connections does; Not now, or the line along its foot running out, and it never asks about
/// that browser again. Settings, Connections stays the place to find it later (01). Only while
/// learning is on: learning is what it offers.
@MainActor
final class BrowserAsk {
    static let shared = BrowserAsk()

    private var panel: BrowserAskPanel?
    private var pendingShow: Task<Void, Never>?

    private init() {}

    func dictationLanded(in app: NSRunningApplication?, controller: DictationController) {
        let settings = Settings.shared
        let bridge = BrowserBridge.shared
        guard settings.firstOpenDone, settings.learnFromCorrections, panel == nil, pendingShow == nil,
              let browser = KnownBrowser.with(bundleID: app?.bundleIdentifier),
              !bridge.isConnected(browser), bridge.isAdded(browser),
              !settings.browsersAsked.contains(browser.id)
        else { return }
        pendingShow = Task { @MainActor [weak self, weak controller] in
            try? await Task.sleep(for: .seconds(DS.Motion.browserAskDelay))
            guard let self else { return }
            self.pendingShow = nil
            // Another dictation already under way: the overlay has the spot. Ask next time.
            guard !Task.isCancelled, let controller, controller.state == .idle else { return }
            self.show(browser)
        }
    }

    private func show(_ browser: KnownBrowser) {
        Settings.shared.browsersAsked.append(browser.id)
        let model = BrowserAskModel(browser: browser)
        model.onAdd = { [weak self] in
            BrowserBridge.shared.add(browser)
            self?.close()
        }
        model.onDismiss = { [weak self] in self?.close() }
        let panel = BrowserAskPanel(model: model)
        self.panel = panel
        panel.present()
    }

    private func close() {
        panel?.dismiss()
        panel = nil
    }
}

@MainActor
@Observable
final class BrowserAskModel {
    let browser: KnownBrowser
    var onAdd: () -> Void = {}
    var onDismiss: () -> Void = {}

    /// The answer window already spent; nil `runningSince` while the pointer holds the card.
    private var spent: TimeInterval = 0
    private var runningSince: Date? = Date()

    init(browser: KnownBrowser) { self.browser = browser }

    var isHeld: Bool { runningSince == nil }

    func hold() {
        guard let since = runningSince else { return }
        spent += Date().timeIntervalSince(since)
        runningSince = nil
    }

    func release() {
        guard runningSince == nil else { return }
        runningSince = Date()
    }

    /// What the line draws: 1 when the card arrives, 0 when it goes.
    func remaining(at date: Date) -> Double {
        let elapsed = spent + (runningSince.map { date.timeIntervalSince($0) } ?? 0)
        return max(0, 1 - elapsed / DS.Motion.browserAskWindow)
    }
}

/// The call card's panel: the overlay's glass, above the Dock, clicks but never key focus,
/// so the browser keeps the keyboard.
@MainActor
final class BrowserAskPanel: NSPanel {
    private let model: BrowserAskModel
    private var countdown: Task<Void, Never>?

    init(model: BrowserAskModel) {
        self.model = model
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
        ignoresMouseEvents = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        appearance = NSAppearance(named: .darkAqua)
        let hosting = HoverHostingView(rootView: BrowserAskView(model: model))
        hosting.onHoverChange = { [weak model] inside in
            if inside { model?.hold() } else { model?.release() }
        }
        GlassCard.install(hosting, in: self)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    private func place() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let visible = screen.visibleFrame
        setFrameOrigin(NSPoint(x: visible.midX - frame.width / 2, y: visible.minY + DS.Material.hudBottomInset))
        invalidateShadow()
    }

    func present() {
        layoutIfNeeded()
        place()
        alphaValue = 0
        orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = DS.Motion.fadeIn
            animator().alphaValue = 1
        }
        if frame.contains(NSEvent.mouseLocation) { model.hold() }
        countdown = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if self.model.remaining(at: Date()) <= 0 {
                    self.model.onDismiss()
                    return
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    func dismiss() {
        countdown?.cancel()
        countdown = nil
        NSAnimationContext.runAnimationGroup { context in
            context.duration = DS.Motion.fadeOut
            animator().alphaValue = 0
        } completionHandler: { [weak self] in
            Task { @MainActor in self?.orderOut(nil) }
        }
    }
}

struct BrowserAskView: View {
    @Bindable var model: BrowserAskModel

    var body: some View {
        HStack(alignment: .top, spacing: DS.Space.roomy - DS.Space.hair) {
            AppIconTile(size: DS.Material.callPromptIcon)
            VStack(alignment: .leading, spacing: DS.Space.snug) {
                VStack(alignment: .leading, spacing: DS.Space.captionGap) {
                    Text("Learn from your fixes in \(model.browser.name) too?")
                        .font(DS.Font.transcript)
                        .foregroundStyle(DS.Color.ink)
                    Caption("Add SigmaFlow to \(model.browser.name) and it learns from what you fix on websites, the way it does in Mail.")
                }
                HStack(spacing: DS.Space.snug) {
                    AppButton(title: "Add to \(model.browser.name)", kind: .inverted, icon: "add") { model.onAdd() }
                    AppButton(title: "Not now", kind: .tertiary) { model.onDismiss() }
                }
            }
        }
        .padding(.horizontal, DS.Space.hudPadX)
        .padding(.vertical, DS.Space.hudPadY)
        .frame(width: DS.Material.hudWidth, alignment: .leading)
        .overlay(alignment: .bottomLeading) { answerLine }
        .environment(\.colorScheme, .dark)
    }

    private var answerLine: some View {
        TimelineView(.animation(minimumInterval: nil, paused: model.isHeld)) { context in
            GeometryReader { proxy in
                Rectangle()
                    .fill(DS.Color.dim)
                    .frame(width: proxy.size.width * model.remaining(at: context.date))
            }
            .frame(height: DS.Border.bar)
        }
    }
}
