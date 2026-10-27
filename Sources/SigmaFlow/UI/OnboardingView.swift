import AppKit
import SwiftUI

/// The setup window of the first open (docs/mockups/onboarding.html, round 6). The words
/// follow docs/copy-voice.md; onboarding is the one place a step carries a line or two
/// under its title (Gokul, 19 Oct 2026). Its logic lives in `FirstOpen`.
struct OnboardingView: View {
    let controller: DictationController
    @State private var flow = FirstOpen.shared
    @State private var settings = Settings.shared
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.isSnapshotting) private var isSnapshotting

    var body: some View {
        VStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, DS.Space.section)
                .padding(.top, DS.Space.panel)
            foot
        }
        .frame(width: DS.Material.welcomeWidth, height: DS.Material.welcomeHeight)
        .background(BackgroundImage())
        .foregroundStyle(DS.Color.ink)
        .background(WelcomeWindowHook())
        .onAppear {
            guard !isSnapshotting else { return }
            flow.windowAppeared(controller: controller)
        }
        .onChange(of: controller.lastLanding) { _, landing in
            if let landing { flow.landed(landing) }
        }
        .onDisappear {
            // Closed before Open SigmaFlow: the app takes over, and the setup comes back at
            // the next launch.
            guard !isSnapshotting, !flow.isFinished else { return }
            flow.closedEarly()
            openWindow(id: "main")
        }
    }

    @ViewBuilder
    private var content: some View {
        switch flow.step {
        case .welcome: welcome
        case .permissions: permissions
        case .talk: talk
        case .handsFree: handsFree
        case .folder: folder
        }
    }

    // MARK: - Steps

    private var welcome: some View {
        VStack(spacing: 0) {
            AppIconTile(size: DS.Material.welcomeIcon)
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text("Sigma").font(DS.Font.welcomeWordmark)
                Text("flow").font(DS.Font.welcomeWordmarkAccent)
            }
            .padding(.top, DS.Space.wide)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("SigmaFlow")
            StepLine("You talk faster than you type. Hold one key, speak naturally, and SigmaFlow writes it into any app.")
            HStack(spacing: DS.Space.snug) {
                ForEach(["Runs on your Mac", "Words as you speak", "Works in every app"], id: \.self) { Badge(text: $0) }
            }
            .padding(.top, DS.Space.wide)
        }
    }

    private var permissions: some View {
        StepFrame(title: "Two quick permissions",
                  line: "SigmaFlow listens only while you hold the key, and writes wherever your cursor is.") {
            Card {
                PermissionRow(icon: "microphone", title: "Microphone", caption: "So SigmaFlow can hear you.",
                              isGranted: flow.hasMicrophone,
                              button: flow.microphoneRefused ? "Open Settings" : "Allow",
                              action: flow.askMicrophone)
                CardDivider()
                PermissionRow(icon: "text--align--left", title: "Accessibility", caption: "So it can write in any app.",
                              isGranted: flow.hasAccessibility,
                              button: flow.accessibilityAsked ? "Open Settings" : "Allow",
                              action: flow.askAccessibility)
            }
            .frame(width: DS.Material.welcomeRowsWidth)
        }
    }

    private var talk: some View {
        StepFrame(title: "Hold \(keyName) and talk",
                  key: keyName,
                  line: flow.talked
                    ? "Now it works in Mail, Slack, Notes, anywhere you type."
                    : "Speak naturally. SigmaFlow writes it for you.") {
            VStack(spacing: DS.Space.base) {
                KeyboardDrawing(target: keyIndex, lit: isHolding)
                SpeechField(flow: flow)
                DoneMark(isDone: flow.talked)
            }
        }
    }

    private var handsFree: some View {
        let listeningLocked = controller.isLatched && controller.state.isActive
        let title: String
        let line: String
        if listeningLocked {
            title = "Tap once to stop"
            line = "Keep talking. Tap once to finish, or press Esc to throw it away."
        } else if flow.talkedHandsFree {
            title = "Hands free"
            line = "Hands free, whenever you need it."
        } else {
            title = "Tap \(keyName) twice"
            line = "For longer thoughts. Talk with your hands free, and tap once when you’re done."
        }
        return StepFrame(title: title, key: listeningLocked || flow.talkedHandsFree ? nil : keyName, line: line) {
            VStack(spacing: DS.Space.base) {
                KeyboardDrawing(target: keyIndex, lit: isHolding)
                TapDots(controller: controller)
                SpeechField(flow: flow)
                DoneMark(isDone: flow.talkedHandsFree)
            }
        }
    }

    private var folder: some View {
        StepFrame(title: "Your recordings stay yours",
                  line: "Every dictation, meeting and conversation is saved to one folder on this Mac. Open it, move it, back it up. It’s yours.") {
            VStack(spacing: DS.Space.base) {
                Card {
                    FolderRow(isOn: flow.isHomeFolder, title: "In your home folder", caption: "~/SigmaFlow",
                              action: flow.useHomeFolder) {
                        TagChip(text: "Recommended")
                    }
                    CardDivider()
                    FolderRow(isOn: !flow.isHomeFolder, title: "Somewhere else",
                              caption: flow.isHomeFolder ? "Choose a folder" : flow.folderPath,
                              isPath: !flow.isHomeFolder,
                              action: flow.chooseFolder) {
                        AppButton(title: "Choose", kind: .tertiary, action: flow.chooseFolder)
                    }
                }
                .frame(width: DS.Material.welcomeRowsWidth)
                if !flow.isHomeFolder && flow.folderSyncs {
                    HStack(alignment: .top, spacing: DS.Space.snug) {
                        CarbonIcon(name: "warning", size: DS.Control.iconSizeSmall)
                        Text("This folder syncs to iCloud, so recordings saved here will leave this Mac.")
                            .font(DS.Font.caption)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .foregroundStyle(DS.Color.inkSecondary)
                    .frame(width: DS.Material.welcomeRowsWidth, alignment: .leading)
                }
            }
        }
    }

    // MARK: - Foot

    private var foot: some View {
        HStack(spacing: DS.Space.snug) {
            HStack(spacing: DS.Space.fieldLabelGap) {
                ForEach(FirstOpen.Step.allCases, id: \.self) { step in
                    Circle()
                        .fill(step == flow.step ? DS.Color.ink : DS.Color.stepDotOff)
                        .frame(width: DS.Material.welcomeStepDot, height: DS.Material.welcomeStepDot)
                }
            }
            Spacer()
            if flow.step != .welcome {
                AppButton(title: "Back", kind: .tertiary) { flow.back() }
            }
            AppButton(title: primaryTitle, kind: .inverted, isEnabled: flow.canContinue) { primary() }
        }
        .padding(.horizontal, DS.Space.wide)
        .frame(height: DS.Material.welcomeFootHeight)
        .background(DS.Color.footer)
        .overlay(alignment: .top) { CardDivider() }
    }

    private var primaryTitle: String {
        switch flow.step {
        case .welcome: "Start"
        case .folder: "Open SigmaFlow"
        default: "Continue"
        }
    }

    private func primary() {
        guard flow.step == .folder else {
            flow.next()
            return
        }
        flow.finish()
        openWindow(id: "main")
        dismissWindow(id: "welcome")
    }

    // MARK: - The key

    private var keyName: String { settings.pushToTalkKey.displayName }

    /// Which key of the drawn bottom row is the push-to-talk key, if it is drawn at all.
    private var keyIndex: Int? {
        switch settings.pushToTalkKey {
        case .rightCommand: 5
        case .rightOption: 6
        case .custom: nil
        }
    }

    /// The key is down and the mic is open: not the locked recording, which no key holds.
    private var isHolding: Bool {
        (controller.state == .starting || controller.state == .listening) && !controller.isLatched
    }
}

// MARK: - Parts

/// A step: its title (with the key drawn in it when there is one), a line under it, and
/// what the step is for.
private struct StepFrame<Content: View>: View {
    let title: String
    var key: String? = nil
    let line: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            titleView
            StepLine(line)
            content.padding(.top, DS.Space.roomy)
        }
    }

    @ViewBuilder
    private var titleView: some View {
        // "Hold Right ⌘ and talk": the key is drawn as a key, between the words around it.
        if let key, let range = title.range(of: key) {
            HStack(spacing: DS.Space.base) {
                Text(title[..<range.lowerBound].trimmingCharacters(in: .whitespaces))
                TitleKey(name: key)
                Text(title[range.upperBound...].trimmingCharacters(in: .whitespaces))
            }
            .font(DS.Font.welcomeTitle)
        } else {
            Text(title).font(DS.Font.welcomeTitle)
        }
    }
}

private struct StepLine: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(DS.Font.body)
            .foregroundStyle(DS.Color.inkSecondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: DS.Material.welcomeLineMeasure)
            .padding(.top, DS.Space.base)
    }
}

/// A key drawn inside a title.
private struct TitleKey: View {
    let name: String

    var body: some View {
        Text(name)
            .font(DS.Font.welcomeKey)
            .padding(.horizontal, DS.Space.navInset)
            .padding(.vertical, DS.Space.hair)
            .background(DS.Color.controlFill, in: RoundedRectangle(cornerRadius: DS.Radius.control))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.control)
                .strokeBorder(DS.Color.borderStrong, lineWidth: DS.Border.hairline))
    }
}

private struct Badge: View {
    let text: String

    var body: some View {
        Text(text)
            .font(DS.Font.caption)
            .foregroundStyle(DS.Color.inkSecondary)
            .padding(.horizontal, DS.Space.navInset)
            .padding(.vertical, DS.Space.tight)
            .background(DS.Color.controlFill, in: RoundedRectangle(cornerRadius: DS.Radius.chip))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.chip)
                .strokeBorder(DS.Color.border, lineWidth: DS.Border.hairline))
    }
}

private struct Allowed: View {
    let text: String

    var body: some View {
        HStack(spacing: DS.Space.fieldLabelGap) {
            CarbonIcon(name: "checkmark", size: DS.Control.iconSizeSmall)
            Text(text).font(DS.Font.caption)
        }
        .foregroundStyle(DS.Color.inkSecondary)
    }
}

private struct PermissionRow: View {
    let icon: String
    let title: String
    let caption: String
    let isGranted: Bool
    let button: String
    let action: () -> Void

    var body: some View {
        HStack(spacing: DS.Space.base) {
            CarbonIcon(name: icon, size: DS.Control.iconSize)
                .foregroundStyle(DS.Color.inkSecondary)
            VStack(alignment: .leading, spacing: DS.Space.captionGap) {
                Text(title).font(DS.Font.body)
                Text(caption).font(DS.Font.caption).foregroundStyle(DS.Color.dim)
            }
            Spacer(minLength: DS.Space.base)
            if isGranted {
                Allowed(text: "Allowed")
            } else {
                AppButton(title: button, kind: .secondary, action: action)
            }
        }
        .padding(.horizontal, DS.Space.rowPadX)
        .padding(.vertical, DS.Space.rowPadY)
    }
}

private struct FolderRow<Trailing: View>: View {
    let isOn: Bool
    let title: String
    let caption: String
    var isPath = true
    let action: () -> Void
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: DS.Space.base) {
            RadioMark(isOn: isOn)
            VStack(alignment: .leading, spacing: DS.Space.captionGap) {
                Text(title).font(DS.Font.body)
                Text(caption).font(isPath ? DS.Font.mono : DS.Font.caption).foregroundStyle(DS.Color.dim)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: DS.Space.base)
            trailing
        }
        .padding(.horizontal, DS.Space.rowPadX)
        .padding(.vertical, DS.Space.rowPadY)
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
    }
}

/// The keyboard on the talking steps: four rows of blank keys and a bottom row with the
/// push-to-talk key outlined, filled while it is held.
private struct KeyboardDrawing: View {
    let target: Int?
    let lit: Bool

    private static let labels = ["fn", "⌃", "⌥", "⌘", "", "⌘", "⌥", ""]
    private var inner: CGFloat { DS.Material.welcomeContentWidth - DS.Space.navInset * 2 }

    var body: some View {
        VStack(spacing: DS.Material.keyGap) {
            ForEach(DS.Material.keyRows.indices, id: \.self) { row in
                HStack(spacing: DS.Material.keyGap) {
                    ForEach(0..<DS.Material.keyRows[row], id: \.self) { _ in
                        key(label: "", isTarget: false).frame(maxWidth: .infinity)
                    }
                }
            }
            HStack(spacing: DS.Material.keyGap) {
                ForEach(DS.Material.keyBottomRow.indices, id: \.self) { index in
                    key(label: Self.labels[index], isTarget: index == target)
                        .frame(width: width(of: index))
                }
            }
        }
        .padding(DS.Space.navInset)
        .frame(width: DS.Material.welcomeContentWidth)
        .background(DS.Color.keyboardFill, in: RoundedRectangle(cornerRadius: DS.Radius.keyboard))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.keyboard)
            .strokeBorder(DS.Color.border, lineWidth: DS.Border.hairline))
        .accessibilityHidden(true)
    }

    private func width(of index: Int) -> CGFloat {
        let ratios = DS.Material.keyBottomRow
        let gaps = DS.Material.keyGap * CGFloat(ratios.count - 1)
        return (inner - gaps) * ratios[index] / ratios.reduce(0, +)
    }

    private func key(label: String, isTarget: Bool) -> some View {
        let isLit = isTarget && lit
        return RoundedRectangle(cornerRadius: DS.Radius.chip)
            .fill(isLit ? DS.Color.ink : DS.Color.keyFill)
            .overlay {
                if isTarget {
                    RoundedRectangle(cornerRadius: DS.Radius.chip)
                        .strokeBorder(DS.Color.ink, lineWidth: DS.Border.hairline)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                Text(label)
                    .font(DS.Font.keyLabel)
                    .foregroundStyle(isLit ? DS.Color.inkOnInverted : isTarget ? DS.Color.ink : DS.Color.dim)
                    .padding(.trailing, DS.Space.tight)
                    .padding(.bottom, DS.Space.hair)
            }
            .frame(height: DS.Material.keyHeight)
    }
}

/// Two dots for the double tap: the first lights on a quick tap, both once it locks.
private struct TapDots: View {
    let controller: DictationController

    var body: some View {
        TimelineView(.periodic(from: .now, by: DS.Motion.tapDotTick)) { context in
            let locked = controller.isLatched && controller.state.isActive
            let firstTap = controller.lastTapEndedAt.map { context.date.timeIntervalSince($0) < DS.Motion.doubleTapWindow } ?? false
            HStack(spacing: DS.Space.snug) {
                dot(isOn: locked || firstTap)
                dot(isOn: locked)
            }
        }
        .accessibilityHidden(true)
    }

    private func dot(isOn: Bool) -> some View {
        Circle()
            .strokeBorder(isOn ? DS.Color.ink : DS.Color.borderStrong, lineWidth: DS.Border.hairline)
            .background(Circle().fill(isOn ? DS.Color.ink : .clear))
            .frame(width: DS.Material.welcomeTapDot, height: DS.Material.welcomeTapDot)
    }
}

/// Where the talking steps' words land, or a thin line while Parakeet is still arriving.
private struct SpeechField: View {
    let flow: FirstOpen

    var body: some View {
        ZStack(alignment: .topLeading) {
            if !flow.isModelReady && flow.lines.isEmpty {
                waiting
            } else {
                VStack(alignment: .leading, spacing: DS.Space.fieldLabelGap) {
                    ForEach(Array(flow.lines.enumerated().suffix(2)), id: \.offset) { item in
                        Text(item.element)
                            .font(DS.Font.transcript)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                            .transition(.opacity)
                    }
                }
                .animation(.easeOut(duration: DS.Motion.wordFlow), value: flow.lines.count)
            }
        }
        .padding(.horizontal, DS.Space.roomy)
        .padding(.vertical, DS.Space.base)
        .frame(width: DS.Material.welcomeContentWidth, height: DS.Material.welcomeFieldHeight, alignment: .topLeading)
        .background(DS.Color.glass, in: RoundedRectangle(cornerRadius: DS.Radius.card))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.card)
            .strokeBorder(DS.Color.borderStrong, lineWidth: DS.Border.hairline))
    }

    private var waiting: some View {
        HStack(spacing: DS.Space.base) {
            ZStack(alignment: .leading) {
                Rectangle().fill(DS.Color.gaugeOff)
                Rectangle().fill(DS.Color.ink)
                    .frame(width: DS.Material.progressWidth * 2 * CGFloat(max(0, min(1, flow.downloadFraction))))
            }
            .frame(width: DS.Material.progressWidth * 2, height: DS.Material.progressHeight)
            if flow.isModelFailed {
                AppButton(title: "Try again", kind: .secondary) { flow.retryDownload() }
            }
        }
        .frame(maxHeight: .infinity, alignment: .center)
    }
}

/// "Done" under the field once the step's dictation has landed; the room kept either way so
/// nothing jumps.
private struct DoneMark: View {
    let isDone: Bool

    var body: some View {
        ZStack {
            if isDone { Allowed(text: "Done") }
        }
        .frame(height: DS.Control.heightCompact)
    }
}

/// Finds the setup window once it exists: places it above the overlay's corner of the
/// screen, so the overlay never covers its buttons, and hands it to `FirstOpen`, which
/// brings it back to the front after Accessibility is switched on in System Settings.
private struct WelcomeWindowHook: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { HookView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class HookView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, FirstOpen.shared.window !== window else { return }
            FirstOpen.shared.window = window
            window.isMovableByWindowBackground = true
            window.standardWindowButton(.zoomButton)?.isEnabled = false
            DispatchQueue.main.async { [weak window] in
                guard let window else { return }
                Self.place(window)
            }
        }

        private static func place(_ window: NSWindow) {
            guard let screen = window.screen ?? NSScreen.main ?? NSScreen.screens.first else { return }
            let visible = screen.visibleFrame
            let size = window.frame.size
            let clearOfOverlay = visible.minY + DS.Material.hudBottomInset + DS.Material.welcomeHUDRoom
            let centred = visible.midY - size.height / 2
            let y = min(max(clearOfOverlay, centred), visible.maxY - size.height)
            window.setFrameOrigin(NSPoint(x: visible.midX - size.width / 2, y: y))
        }
    }
}
