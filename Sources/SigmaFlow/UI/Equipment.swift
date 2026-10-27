import AppKit
import SwiftUI

// The control vocabulary for SigmaFlow 1.0: the parts on Paper board 10, and nothing else.
// Every value here comes from `DS`. If a component needs a number that isn't a token, the
// token is missing: add it there rather than inlining it.
//
// Geist foundation, native frame. Surfaces are glass over the painting; controls are 32
// high with a 6 px radius; cards are 8; dividers stop at the card edge; emphasis reads
// through ink, never weight, because Geist Pixel has one weight.

// MARK: - Background

/// The app's ground: the Death of Socrates in colour, scaled to fill, under a dark scrim so
/// the glass surfaces read. Falls back to the chassis colour if the asset is missing.
struct BackgroundImage: View {
    /// Also drawn, softened, behind the overlay tiles on Settings.
    static let image: NSImage? = {
        guard let url = Bundle.main.url(forResource: "background-colour", withExtension: "jpg") else { return nil }
        return NSImage(contentsOf: url)
    }()

    var body: some View {
        GeometryReader { geo in
            if let image = Self.image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: geo.size.width, height: geo.size.height)
                    .clipped()
                    .overlay(DS.Color.paintingScrim)
            } else {
                DS.Color.chassis
            }
        }
        .ignoresSafeArea()
    }
}

/// Native vibrancy for the sidebar and the toolbar: whatever is behind blurs through,
/// pinned dark. `DS.Color.rail` is the tint laid over it.
struct RailGlass: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .sidebar

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
        view.appearance = NSAppearance(named: .darkAqua)
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

// MARK: - Page

/// A page with tabs: the header and the tab strip stay put, and only what is under the
/// strip scrolls, clipped at its rule. No page scrolls as a whole (Gokul, 16 Oct 2026, the
/// rule Meetings set). Page inset is 24 top, 28 sides and foot; sections stack with
/// `sectionGap` between them.
struct PageScroll<Header: View, Content: View>: View {
    @ViewBuilder var header: Header
    @ViewBuilder var content: Content
    @Environment(\.isSnapshotting) private var isSnapshotting

    init(@ViewBuilder header: () -> Header, @ViewBuilder content: () -> Content) {
        self.header = header()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: DS.Space.sectionGap) {
                header
            }
            .padding(.top, DS.Space.pageTop)
            .padding(.horizontal, DS.Space.pageSide)
            .frame(maxWidth: .infinity, alignment: .topLeading)

            // The offscreen renderer used for window snapshots cannot draw a scroll view's
            // content, so in that mode the page is laid out flat.
            if isSnapshotting {
                page.frame(maxHeight: .infinity, alignment: .top)
            } else {
                ScrollView { page }.scrollEdgeFade()
            }
        }
    }

    private var page: some View {
        VStack(alignment: .leading, spacing: DS.Space.sectionGap) {
            content
        }
        // The gap sits inside the scroll, so content scrolls up to the tab strip's rule.
        .padding(.top, DS.Space.sectionGap)
        .padding(.horizontal, DS.Space.pageSide)
        .padding(.bottom, DS.Space.pageBottom)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

/// A list page, laid out like Meetings: the header, the search and the card's head stay
/// put, and only the rows scroll, inside their card (`CardScroll`). A short list ends where
/// its rows end.
struct ListPage<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        // No Spacer at the foot: in a spaced stack it would add a section gap to the margin.
        VStack(alignment: .leading, spacing: DS.Space.sectionGap) {
            content
        }
        .padding(.top, DS.Space.pageTop)
        .padding(.horizontal, DS.Space.pageSide)
        .padding(.bottom, DS.Space.pageBottom)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// The rows of a list card, scrolling inside it: as tall as the rows, never taller than the
/// room left, so the card's editor above and its footer below stay where they are.
struct CardScroll<Content: View>: View {
    @ViewBuilder var content: Content
    @State private var height: CGFloat = 0
    @Environment(\.isSnapshotting) private var isSnapshotting

    var body: some View {
        if isSnapshotting {
            // The offscreen renderer cannot draw a scroll view's content.
            VStack(spacing: 0) { content }
        } else {
            ScrollView {
                VStack(spacing: 0) { content }
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
            }
            .scrollEdgeFade()
            .frame(maxHeight: height > 0 ? height : nil)
        }
    }
}

/// A scroll view's content fades out over `scrollFade` at an edge with more beyond it, and
/// shows plainly at an edge where it ends, so a list never looks cut off. A fade of the
/// content itself, not a painted gradient: nothing is laid over the painting.
private struct ScrollEdgeFade: ViewModifier {
    private struct Edges: Equatable {
        var top = false
        var bottom = false
    }

    @State private var edges = Edges()

    func body(content: Content) -> some View {
        content
            .onScrollGeometryChange(for: Edges.self) { geo in
                Edges(
                    top: geo.visibleRect.minY > 1,
                    bottom: geo.visibleRect.maxY < geo.contentSize.height - 1)
            } action: { _, new in
                withAnimation(DS.Motion.panel) { edges = new }
            }
            .mask {
                // Only the mask's opacity counts; black is fully shown, clear is gone.
                VStack(spacing: 0) {
                    LinearGradient(colors: [.black.opacity(edges.top ? 0 : 1), .black], startPoint: .top, endPoint: .bottom)
                        .frame(height: DS.Material.scrollFade)
                    Color.black
                    LinearGradient(colors: [.black, .black.opacity(edges.bottom ? 0 : 1)], startPoint: .top, endPoint: .bottom)
                        .frame(height: DS.Material.scrollFade)
                }
            }
    }
}

extension View {
    func scrollEdgeFade() -> some View { modifier(ScrollEdgeFade()) }
}

/// True only while `WindowSnapshots` draws the window offscreen (a developer aid).
private struct SnapshotModeKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var isSnapshotting: Bool {
        get { self[SnapshotModeKey.self] }
        set { self[SnapshotModeKey.self] = newValue }
    }
}

/// The title row of every page: the title at the left, one live instrument or nothing at
/// the right. It sits at the top of the page content and scrolls with it; no bar, no line.
/// (Gokul, 10 Oct 2026: the pinned bar read as a second window chrome.)
struct Toolbar<Instrument: View>: View {
    let title: String
    @ViewBuilder var instrument: Instrument

    init(_ title: String, @ViewBuilder instrument: () -> Instrument = { EmptyView() }) {
        self.title = title
        self.instrument = instrument()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(DS.Font.title)
                .foregroundStyle(DS.Color.ink)
            Spacer(minLength: DS.Space.wide)
            instrument
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, DS.Space.snug)
    }
}

// MARK: - Labels

/// A section label: Geist Pixel, 12, uppercase, secondary ink. Uppercasing happens here so a
/// label can never be half-styled.
struct Eyebrow: View {
    let text: String
    var color: Color = DS.Color.inkSecondary

    init(_ text: String, color: Color = DS.Color.inkSecondary) {
        self.text = text
        self.color = color
    }

    var body: some View {
        Text(text.uppercased())
            .font(DS.Font.eyebrow)
            .tracking(DS.Font.eyebrowTracking)
            .foregroundStyle(color)
    }
}

/// The earlier name for `Eyebrow`, kept so pages not yet rebuilt compile.
struct Silkscreen: View {
    let text: String
    var large = false
    var color: Color = DS.Color.inkSecondary

    var body: some View { Eyebrow(text, color: color) }
}

/// One caption line under a row's label. Never two.
struct Caption: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(DS.Font.caption)
            .foregroundStyle(DS.Color.inkSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: DS.Space.measure, alignment: .leading)
    }
}

/// An inline keyboard chip: `Right ⌥`.
struct KeyChip: View {
    let text: String

    var body: some View {
        Text(text)
            .font(DS.Font.mono)
            .foregroundStyle(DS.Color.ink)
            .padding(.horizontal, DS.Space.snug)
            .padding(.vertical, DS.Space.hair)
            .background(DS.Color.controlFill, in: RoundedRectangle(cornerRadius: DS.Radius.chip))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.chip).strokeBorder(DS.Color.border, lineWidth: DS.Border.hairline))
    }
}

/// A monospaced-digit readout: timers, counts.
struct Readout: View {
    let text: String
    var large = false

    var body: some View {
        Text(text)
            .font(large ? DS.Font.counterLarge : DS.Font.data)
            .foregroundStyle(DS.Color.ink)
    }
}

/// The app's own icon, as a rounded tile with a thin edge (Gokul, 16 Oct 2026,
/// docs/mockups/notes-home.html 05 A): on black its black square would otherwise vanish.
/// Beside the wordmark, on the card that asks to record a call, and on the first open.
///
/// Drawn from AppIcon.icns itself, rounded the way the Dock rounds it (Gokul, 27 Oct 2026).
/// `applicationIconImage` is macOS 26's rendering: the square icon shrunk inside its own
/// rounded plate, so a tile around it showed a small sigma inside two edges.
struct AppIconTile: View {
    var size: CGFloat = DS.Material.logoSize

    private static let artwork: NSImage = Bundle.main.image(forResource: "AppIcon")
        ?? NSApplication.shared.applicationIconImage

    var body: some View {
        let radius = size * DS.Radius.appIconCorner
        Image(nsImage: Self.artwork)
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(DS.Color.borderStrong, lineWidth: DS.Border.hairline))
            .accessibilityHidden(true)
    }
}

/// The wordmark: one word, "Sigma" in the Square shape and "flow" in the Circle shape.
/// The product is written SigmaFlow in prose; this is a drawing of the name.
struct Wordmark: View {
    var body: some View {
        HStack(spacing: DS.Space.wordmarkLogoGap) {
            AppIconTile()
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text("Sigma").font(DS.Font.wordmark)
                Text("flow").font(DS.Font.wordmarkAccent)
            }
        }
        .foregroundStyle(DS.Color.ink)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("SigmaFlow")
    }
}

// MARK: - Buttons

/// The one button. Three tiers, one height, one font, so any two of them line up when
/// they share a row.
///
/// - `secondary`: control fill with a border. The everyday button.
/// - `inverted`: light fill, dark label. At most one per page, for the action the page
///   exists for (Export, Start recording). Many pages have none.
/// - `tertiary`: no fill, secondary ink, fill on hover. Actions inside a row.
///
/// The earlier tiers map onto these: `primary` is inverted, `ghost` and `link` are tertiary.
/// `isDestructive` is accepted and ignored: danger reads through placement, never through
/// weight or colour.
struct AppButton: View {
    enum Kind { case inverted, secondary, tertiary
        static let primary = Kind.inverted
        static let ghost = Kind.tertiary
        static let link = Kind.tertiary
    }

    let title: String
    var kind: Kind = .tertiary
    var icon: String? = nil
    var trailingIcon: String? = nil
    var isDestructive = false
    var isEnabled = true
    /// Pins the width so a column of buttons lines up across rows (the Models page's Use).
    var fixedWidth: CGFloat? = nil
    /// The icon faint, the button still live: a switch that is off (live notes' camera).
    var iconDimmed = false
    /// Smaller all round, for a row with many buttons (the live notes card).
    var compact = false
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: compact ? DS.Control.iconGapCompact : DS.Control.iconGap) {
                if let icon {
                    CarbonIcon(name: icon, size: compact ? DS.Control.iconSizeSmall : DS.Control.iconSize)
                        .opacity(iconDimmed ? DS.Border.disabledOpacity : 1)
                }
                // An icon-only button passes an empty title; no text, no stray gap.
                if !title.isEmpty { Text(title).font(compact ? DS.Font.caption : DS.Font.body) }
                if let trailingIcon { CarbonIcon(name: trailingIcon, size: compact ? DS.Control.iconSizeSmall : DS.Control.iconSize) }
            }
            .foregroundStyle(labelColor)
            .padding(.horizontal, compact ? DS.Control.padXCompact : kind == .tertiary ? DS.Control.padXQuiet : DS.Control.padX)
            .frame(width: fixedWidth, height: compact ? DS.Control.heightCompact : DS.Control.height)
            .background(fillColor, in: RoundedRectangle(cornerRadius: DS.Radius.control))
            .overlay {
                if kind == .secondary {
                    RoundedRectangle(cornerRadius: DS.Radius.control)
                        .strokeBorder(isHovering ? DS.Color.borderStrong : DS.Color.border, lineWidth: DS.Border.hairline)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: DS.Radius.control))
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : DS.Border.disabledOpacity)
        .onHover { isHovering = $0 }
        .handCursor()
    }

    private var labelColor: Color {
        switch kind {
        case .inverted: DS.Color.inkOnInverted
        case .secondary: DS.Color.ink
        case .tertiary: isHovering ? DS.Color.ink : DS.Color.inkSecondary
        }
    }

    private var fillColor: Color {
        switch kind {
        case .inverted: isHovering ? DS.Color.gray900 : DS.Color.gray1000
        case .secondary: isHovering ? DS.Color.hoverFill : DS.Color.controlFill
        case .tertiary: isHovering ? DS.Color.hoverFill : .clear
        }
    }
}

// MARK: - Cards and rows

/// A section's surface: glass, a 1 px border, radius 8. Rows inside are divided by
/// `CardDivider`s that stop at the card's edge. An optional footer bar carries a hint at the
/// left and at most two buttons at the right.
struct Card<Content: View, Footer: View>: View {
    @ViewBuilder var content: Content
    @ViewBuilder var footer: Footer

    init(@ViewBuilder content: () -> Content, @ViewBuilder footer: () -> Footer = { EmptyView() }) {
        self.content = content()
        self.footer = footer()
    }

    var body: some View {
        VStack(spacing: 0) {
            content
            footer
        }
        .background(DS.Color.glass, in: RoundedRectangle(cornerRadius: DS.Radius.card))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.card).strokeBorder(DS.Color.border, lineWidth: DS.Border.hairline))
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card))
    }
}

/// The footer bar of a card. With something at its leading edge (a list's `PathBar`), the
/// hint moves over beside the buttons.
struct CardFooter<Leading: View, Actions: View>: View {
    let hint: String
    @ViewBuilder var leading: Leading
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack {
            if Leading.self == EmptyView.self {
                hintText
                Spacer()
            } else {
                leading
                Spacer()
                hintText
            }
            HStack(spacing: DS.Space.snug) { actions }
        }
        .padding(.horizontal, DS.Space.rowPadX)
        .padding(.vertical, DS.Space.rowPadY)
        .background(DS.Color.footer)
        .overlay(alignment: .top) { CardDivider() }
    }

    private var hintText: some View {
        Text(hint)
            .font(DS.Font.caption)
            .foregroundStyle(DS.Color.inkSecondary)
    }
}

extension CardFooter where Leading == EmptyView {
    init(hint: String, @ViewBuilder actions: () -> Actions) {
        self.init(hint: hint, leading: { EmptyView() }, actions: actions)
    }
}

/// A 1 px line between rows, inside the card.
struct CardDivider: View {
    var body: some View {
        Rectangle().fill(DS.Color.border).frame(height: DS.Border.hairline)
    }
}

/// One row in a card: label, optional caption under it, optional data in secondary ink,
/// and the control in a fixed lane at the right edge. 52 high without a caption; grows to
/// fit one caption line with one. `isLast` drops the divider under it.
struct CardRow<Control: View>: View {
    let label: String
    var caption: String? = nil
    var data: String? = nil
    var isLast = false
    @ViewBuilder var control: Control

    init(_ label: String, caption: String? = nil, data: String? = nil, isLast: Bool = false,
         @ViewBuilder control: () -> Control = { EmptyView() }) {
        self.label = label
        self.caption = caption
        self.data = data
        self.isLast = isLast
        self.control = control()
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: DS.Space.roomy) {
                VStack(alignment: .leading, spacing: DS.Space.captionGap) {
                    Text(label)
                        .font(DS.Font.body)
                        .foregroundStyle(DS.Color.ink)
                    if let caption { Caption(caption) }
                }
                .padding(.vertical, DS.Space.rowPadY)
                Spacer(minLength: 0)
                if let data {
                    Text(data)
                        .font(DS.Font.data)
                        .foregroundStyle(DS.Color.inkSecondary)
                        .textSelection(.enabled)
                }
                control
                    .frame(minWidth: DS.Control.laneMinWidth, alignment: .trailing)
            }
            .padding(.horizontal, DS.Space.rowPadX)
            .frame(minHeight: DS.Material.cardRowHeight)
            if !isLast { CardDivider() }
        }
    }
}

/// A row whose control is a native switch.
struct ToggleRow: View {
    let label: String
    var caption: String? = nil
    @Binding var isOn: Bool
    var isEnabled = true
    var isLast = false

    var body: some View {
        CardRow(label, caption: caption, isLast: isLast) {
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .tint(DS.Color.blue700)
                .disabled(!isEnabled)
        }
        .opacity(isEnabled ? 1 : DS.Border.disabledOpacity)
    }
}

/// A row whose control is a native popup. Picks one of N.
struct PopupRow<Selection: Hashable, Options: View>: View {
    let label: String
    var caption: String? = nil
    @Binding var selection: Selection
    var isLast = false
    @ViewBuilder var options: Options

    init(_ label: String, caption: String? = nil, selection: Binding<Selection>, isLast: Bool = false,
         @ViewBuilder options: () -> Options) {
        self.label = label
        self.caption = caption
        self._selection = selection
        self.isLast = isLast
        self.options = options()
    }

    var body: some View {
        CardRow(label, caption: caption, isLast: isLast) {
            Picker("", selection: $selection) { options }
                .labelsHidden()
                .pickerStyle(.menu)
                .font(DS.Font.body)
                .frame(width: DS.Control.popupWidth, alignment: .trailing)
        }
    }
}

/// A row that holds arbitrary content full width, for a field with a button beside it.
struct CardContentRow<Content: View>: View {
    var isLast = false
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            content
                .padding(.horizontal, DS.Space.rowPadX)
                .padding(.vertical, DS.Space.rowPadY)
                .frame(maxWidth: .infinity, alignment: .leading)
            if !isLast { CardDivider() }
        }
    }
}

/// Earlier list-row chrome, kept so pages not yet rebuilt compile. Now a card row's
/// geometry without the card: hover fill, divider that stops at the edge.
struct ListRow<Content: View>: View {
    var verticalPadding: CGFloat = DS.Space.rowPadY
    var isActive = false
    @ViewBuilder var content: Content

    @State private var isHovering = false

    var body: some View {
        VStack(spacing: 0) {
            content
                .padding(.vertical, verticalPadding)
                .padding(.horizontal, DS.Space.rowPadX)
            CardDivider()
        }
        .background(isHovering || isActive ? DS.Color.hoverFill : Color.clear)
        .onHover { isHovering = $0 }
    }
}

/// Earlier name for `CardDivider`.
struct ListRule: View {
    var color: Color = DS.Color.border

    var body: some View {
        Rectangle().fill(color).frame(maxWidth: .infinity).frame(height: DS.Border.hairline)
    }
}

extension View {
    /// Earlier full-bleed hairline trick. Dividers now stop at the card edge, so this does
    /// nothing; it stays until the last caller is rebuilt.
    func listBleed() -> some View { self }
}

// MARK: - Fields

/// A single-line input: control fill, border, radius 6, 32 high. The same chrome wherever
/// a page asks for one line of text.
struct FormField: View {
    let prompt: String
    @Binding var text: String
    var onSubmit: () -> Void = {}

    var body: some View {
        TextField(prompt, text: $text)
            .textFieldStyle(.plain)
            .font(DS.Font.body)
            .foregroundStyle(DS.Color.ink)
            .padding(.horizontal, DS.Control.fieldPadX)
            .frame(height: DS.Control.fieldHeight)
            .background(DS.Color.controlFill, in: RoundedRectangle(cornerRadius: DS.Radius.control))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.control).strokeBorder(DS.Color.border, lineWidth: DS.Border.hairline))
            .onSubmit(onSubmit)
    }
}

/// A multi-line input with the same chrome, never shorter than `fieldMinHeight`.
struct TextArea: View {
    let prompt: String
    @Binding var text: String
    var minHeight: CGFloat = DS.Control.fieldMinHeight
    var maxHeight: CGFloat? = nil

    var body: some View {
        TextEditor(text: $text)
            .font(DS.Font.body)
            .foregroundStyle(DS.Color.ink)
            .scrollContentBackground(.hidden)
            .padding(.horizontal, DS.Control.fieldPadX - DS.Space.tight)
            .padding(.vertical, DS.Control.fieldPadY)
            .frame(minHeight: minHeight, maxHeight: maxHeight)
            .background(DS.Color.controlFill, in: RoundedRectangle(cornerRadius: DS.Radius.control))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.control).strokeBorder(DS.Color.border, lineWidth: DS.Border.hairline))
            .overlay(alignment: .topLeading) {
                if text.isEmpty {
                    Text(prompt)
                        .font(DS.Font.body)
                        .foregroundStyle(DS.Color.placeholder)
                        .padding(.horizontal, DS.Control.fieldPadX)
                        .padding(.vertical, DS.Control.fieldPadY)
                        .allowsHitTesting(false)
                }
            }
    }
}

/// A secure single-line input with the field chrome, for API keys.
struct SecureFormField: View {
    let prompt: String
    @Binding var text: String

    var body: some View {
        SecureField(prompt, text: $text)
            .textFieldStyle(.plain)
            .font(DS.Font.body)
            .foregroundStyle(DS.Color.ink)
            .padding(.horizontal, DS.Control.fieldPadX)
            .frame(height: DS.Control.fieldHeight)
            .background(DS.Color.controlFill, in: RoundedRectangle(cornerRadius: DS.Radius.control))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.control).strokeBorder(DS.Color.border, lineWidth: DS.Border.hairline))
    }
}

// MARK: - Status

/// The result of an action, where the action was: a checkmark and a few words in caption
/// ink. Replaces toasts and outcome boxes. The caller shows it for `DS.Motion.statusHold`.
struct StatusLine: View {
    let text: String
    var icon: String = "checkmark"

    var body: some View {
        HStack(spacing: DS.Space.snug) {
            CarbonIcon(name: icon, size: DS.Control.iconSize - DS.Space.hair)
                .foregroundStyle(DS.Color.meterGreen)
            Text(text)
                .font(DS.Font.caption)
                .foregroundStyle(DS.Color.inkSecondary)
        }
        .frame(height: DS.Control.height)
    }
}

/// What a Copy button turns into for a moment after it fires. Same footprint as the
/// button it replaces, so the row doesn't shift.
struct CopiedLabel: View {
    var body: some View { StatusLine(text: "Copied").padding(.horizontal, DS.Control.padX) }
}

/// Naming something in place: one field, Save, Cancel, and a line saying what the name
/// will do. Opens under the thing it names. Return saves, Esc cancels.
struct InlineNameEditor: View {
    let prompt: String
    @Binding var text: String
    let onSave: () -> Void
    let onCancel: () -> Void

    @FocusState private var isFocused: Bool

    private var canSave: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.snug) {
            HStack(spacing: DS.Space.snug) {
                FormField(prompt: "Name", text: $text) { if canSave { onSave() } }
                    .frame(width: DS.Control.popupWidth + DS.Space.section)
                    .focused($isFocused)
                AppButton(title: "Save", kind: .secondary, isEnabled: canSave, action: onSave)
                AppButton(title: "Cancel", action: onCancel)
            }
            Caption(prompt)
        }
        .padding(DS.Space.rowPadX)
        .background(DS.Color.controlFill, in: RoundedRectangle(cornerRadius: DS.Radius.card))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.card).strokeBorder(DS.Color.borderStrong, lineWidth: DS.Border.hairline))
        .onExitCommand(perform: onCancel)
        .onAppear { isFocused = true }
    }
}

/// A passing message, kept for the Meetings page until it is rebuilt or flagged off. Drawn
/// as a small glass card so it matches the rest.
struct Toast: Identifiable, Equatable {
    let id = UUID()
    let icon: String
    let message: String

    static func note(_ message: String) -> Toast { Toast(icon: "checkmark", message: message) }
    static func error(_ message: String) -> Toast { Toast(icon: "warning", message: message) }
}

struct ToastView: View {
    let toast: Toast

    var body: some View {
        HStack(alignment: .top, spacing: DS.Space.snug) {
            CarbonIcon(name: toast.icon, size: DS.Control.iconSize - DS.Space.hair)
                .foregroundStyle(DS.Color.inkSecondary)
                .padding(.top, DS.Space.hair)
            Text(toast.message)
                .font(DS.Font.caption)
                .foregroundStyle(DS.Color.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, DS.Space.roomy)
        .padding(.vertical, DS.Space.base)
        .frame(maxWidth: DS.Space.measure, alignment: .leading)
        .background(DS.Color.glass, in: RoundedRectangle(cornerRadius: DS.Radius.card))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.card).strokeBorder(DS.Color.border, lineWidth: DS.Border.hairline))
    }
}

// MARK: - Cursor

extension View {
    /// The pointing-hand cursor over anything clickable.
    func handCursor() -> some View {
        onHover { inside in
            if inside {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
    }
}

// MARK: - Instrumentation

/// The level meter: a row of round dots that fill left to right in the one colour the app
/// allows. Damped so it rises and drains smoothly instead of flickering with the signal.
///
/// The damping state lives in a plain reference type, deliberately *not* `@State`: it
/// advances once per drawn frame inside the `Canvas` closure, and SwiftUI state mutated
/// during drawing is undefined behavior.
struct VUMeter: View {
    /// Current input level, 0...1.
    let level: Float
    var isActive: Bool
    /// How many dots. The live notes card, with more buttons in its row, has fewer.
    var segments = DS.Material.meterSegments

    @State private var movement = Damper()

    private final class Damper {
        var position: Double = 0
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { _ in
            Canvas { context, size in
                draw(in: &context, size: size)
            }
        }
    }

    private func draw(in context: inout GraphicsContext, size: CGSize) {
        advance()

        let count = segments
        let gap = DS.Material.meterSegmentGap
        let dot = DS.Material.meterDotSize
        let y = (size.height - dot) / 2
        let lit = Int((movement.position * Double(count)).rounded())

        for index in 0..<count {
            let x = CGFloat(index) * (dot + gap)
            let rect = CGRect(x: x, y: y, width: dot, height: dot)
            let color: Color = index < lit ? DS.Color.meterGreen : DS.Color.meterOff
            context.fill(Path(ellipseIn: rect), with: .color(color))
        }
    }

    private func advance() {
        let target = isActive ? Double(min(max(level, 0), 1)) : 0
        let rising = target > movement.position
        let time = rising ? DS.Motion.needleAttack : DS.Motion.needleRelease
        let step = 1.0 / 30.0 / time
        let delta = target - movement.position
        movement.position += min(max(delta, -step), step)
        movement.position = min(max(movement.position, 0), 1)
    }
}

extension VUMeter {
    /// The meter's natural width: every dot and gap, no trailing gap.
    static var naturalWidth: CGFloat { naturalWidth(segments: DS.Material.meterSegments) }

    static func naturalWidth(segments: Int) -> CGFloat {
        CGFloat(segments) * (DS.Material.meterDotSize + DS.Material.meterSegmentGap) - DS.Material.meterSegmentGap
    }
}


// MARK: - 1.0 page furniture

/// The head of every page: the title, one subtitle wrapped at about 65 characters, and
/// at most one instrument at the right (New style on the Styles page; nothing elsewhere).
struct PageHeader<Instrument: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var instrument: Instrument

    init(_ title: String, subtitle: String, @ViewBuilder instrument: () -> Instrument = { EmptyView() }) {
        self.title = title
        self.subtitle = subtitle
        self.instrument = instrument()
    }

    var body: some View {
        HStack(alignment: .center, spacing: DS.Space.wide) {
            VStack(alignment: .leading, spacing: DS.Space.headerGap) {
                Text(title)
                    .font(DS.Font.title)
                    .foregroundStyle(DS.Color.ink)
                Text(subtitle)
                    .font(DS.Font.body)
                    .foregroundStyle(DS.Color.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: DS.Space.subtitleMeasure, alignment: .leading)
            }
            Spacer(minLength: 0)
            instrument
        }
        .frame(maxWidth: .infinity)
    }
}

/// A strip of tabs under the header: labels with a 2 px underline under the open one and
/// a rule beneath. A tab strip, not a content switcher (Gokul, 10 Oct 2026).
struct TabStrip<Tab: Hashable>: View {
    let tabs: [(Tab, String)]
    @Binding var selection: Tab

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: DS.Space.tabGap) {
                ForEach(tabs, id: \.0) { tab, label in
                    let isOpen = tab == selection
                    Button {
                        withAnimation(DS.Motion.panel) { selection = tab }
                    } label: {
                        VStack(alignment: .leading, spacing: DS.Space.tabLabelGap) {
                            Text(label)
                                .font(DS.Font.body)
                                .foregroundStyle(isOpen ? DS.Color.ink : DS.Color.inkSecondary)
                            Rectangle()
                                .fill(isOpen ? DS.Color.ink : Color.clear)
                                .frame(height: DS.Material.tabUnderline)
                        }
                        // The underline is as wide as the label, never wider.
                        .fixedSize()
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .handCursor()
                }
            }
            CardDivider()
        }
    }
}

/// The search box at the head of a list page: a magnifier, then the field, 360 wide.
struct SearchBox: View {
    @Binding var text: String
    let placeholder: String

    var body: some View {
        HStack(spacing: DS.Space.snug) {
            CarbonIcon(name: "search", size: DS.Control.iconSizeSmall)
                .foregroundStyle(DS.Color.dim)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(DS.Font.body)
                .foregroundStyle(DS.Color.ink)
            if !text.isEmpty {
                Button { text = "" } label: {
                    CarbonIcon(name: "close", size: DS.Control.iconSizeTiny)
                        .foregroundStyle(DS.Color.inkSecondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, DS.Control.fieldPadX)
        .frame(width: DS.Material.searchWidth, height: DS.Control.fieldHeight)
        .background(DS.Color.controlFill, in: RoundedRectangle(cornerRadius: DS.Radius.control))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.control).strokeBorder(DS.Color.border, lineWidth: DS.Border.hairline))
    }
}

/// Search at the left, the count at the right. Sits between the header and the list card.
/// A page whose card holds an editor passes `addTitle`: the button beside the search opens
/// it, so the editor stays closed until it is asked for (docs/mockups/ui-audit.html, 04).
struct ListToolbar: View {
    @Binding var query: String
    let placeholder: String
    let count: String
    var addTitle: String? = nil
    var onAdd: () -> Void = {}

    var body: some View {
        HStack(spacing: DS.Space.tight) {
            SearchBox(text: $query, placeholder: placeholder)
            if let addTitle {
                AppButton(title: addTitle, kind: .secondary, icon: "add", action: onAdd)
            }
            Spacer(minLength: DS.Space.wide)
            Text(count)
                .font(DS.Font.data)
                .foregroundStyle(DS.Color.inkSecondary)
        }
    }
}

/// A short uppercase label above the rows of one day inside a list card.
struct DayLabel: View {
    let text: String

    var body: some View {
        Eyebrow(text)
            .padding(.horizontal, DS.Space.rowPadX)
            .padding(.top, DS.Space.dayLabelTop)
            .padding(.bottom, DS.Space.dayLabelBottom)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The editor at the head of a list card: a shade lighter than the rows, 16 inset, the
/// fields above and the buttons below.
struct EditorRow<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.editorGap) {
            content
        }
        .padding(DS.Space.editorPad)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.Color.editorFill)
    }
}

/// An eyebrow over a field: "When I say this" over its box.
struct LabeledField<Field: View>: View {
    let label: String
    @ViewBuilder var field: Field

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.fieldLabelGap) {
            Eyebrow(label)
            field
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// An uppercase word in a thin frame: ACTIVE on the Models page.
struct TagChip: View {
    let text: String

    var body: some View {
        Eyebrow(text)
            .padding(.horizontal, DS.Space.fieldLabelGap)
            .padding(.vertical, DS.Space.hair)
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.chip).strokeBorder(DS.Color.border, lineWidth: DS.Border.hairline))
    }
}

/// A radio mark for a pick-one list: a ring, and a dot when chosen.
struct RadioMark: View {
    let isOn: Bool

    var body: some View {
        ZStack {
            Circle()
                .strokeBorder(isOn ? DS.Color.ink : DS.Color.radioOff, lineWidth: DS.Material.radioStroke)
            if isOn {
                Circle()
                    .fill(DS.Color.ink)
                    .frame(width: DS.Material.radioDot, height: DS.Material.radioDot)
            }
        }
        .frame(width: DS.Material.radioSize, height: DS.Material.radioSize)
    }
}

/// Five blocks with a label: Accuracy and Speed on a model row.
struct GaugeLine: View {
    let label: String
    let value: Int

    var body: some View {
        HStack(spacing: DS.Space.navInset) {
            Text(label.uppercased())
                .font(DS.Font.micro)
                .tracking(DS.Font.microTracking)
                .foregroundStyle(DS.Color.dim)
                .frame(width: DS.Material.gaugeLabelWidth, alignment: .leading)
            HStack(spacing: DS.Material.gaugeBlockGap) {
                ForEach(0..<DS.Material.gaugeBlocks, id: \.self) { index in
                    Rectangle()
                        .fill(index < value ? DS.Color.ink : DS.Color.gaugeOff)
                        .frame(width: DS.Material.gaugeBlockWidth, height: DS.Material.gaugeBlockHeight)
                }
            }
        }
    }
}

/// A thin progress line with the percentage beside it.
struct ProgressLine: View {
    let fraction: Double

    var body: some View {
        HStack(spacing: DS.Space.navInset) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: DS.Material.progressHeight / 2)
                    .fill(DS.Color.gaugeOff)
                RoundedRectangle(cornerRadius: DS.Material.progressHeight / 2)
                    .fill(DS.Color.ink)
                    .frame(width: DS.Material.progressWidth * CGFloat(max(0, min(1, fraction))))
            }
            .frame(width: DS.Material.progressWidth, height: DS.Material.progressHeight)
            Text("\(Int((max(0, min(1, fraction)) * 100).rounded()))%")
                .font(DS.Font.data)
                .foregroundStyle(DS.Color.ink)
        }
    }
}

/// The two small chevrons at the right end of a popup.
struct PopupChevrons: View {
    var body: some View {
        Path { path in
            path.move(to: CGPoint(x: 5, y: 6.5))
            path.addLine(to: CGPoint(x: 8, y: 3.5))
            path.addLine(to: CGPoint(x: 11, y: 6.5))
            path.move(to: CGPoint(x: 5, y: 9.5))
            path.addLine(to: CGPoint(x: 8, y: 12.5))
            path.addLine(to: CGPoint(x: 11, y: 9.5))
        }
        .stroke(DS.Color.dim, style: StrokeStyle(lineWidth: DS.Material.radioStroke, lineCap: .round, lineJoin: .round))
        .frame(width: DS.Control.iconSize, height: DS.Control.iconSize)
    }
}

/// The popup: the current choice in a control-fill button with chevrons, a menu of the
/// options under it with a check against the chosen one. Drawn by the app, not AppKit, so
/// it reads like the rest of the page.
struct PopupButton<Selection: Hashable>: View {
    @Binding var selection: Selection
    let options: [(Selection, String)]
    var width: CGFloat = DS.Control.popupWidth

    private var currentLabel: String {
        options.first { $0.0 == selection }?.1 ?? ""
    }

    var body: some View {
        Menu {
            Picker("", selection: $selection) {
                ForEach(options, id: \.0) { value, label in
                    Text(label).tag(value)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            HStack(spacing: DS.Space.snug) {
                Text(currentLabel)
                    .font(DS.Font.body)
                    .foregroundStyle(DS.Color.ink)
                    .lineLimit(1)
                Spacer(minLength: 0)
                PopupChevrons()
            }
            .padding(.leading, DS.Control.padX)
            .padding(.trailing, DS.Control.padXQuiet)
            .frame(width: width, height: DS.Control.height)
            .background(DS.Color.controlFill, in: RoundedRectangle(cornerRadius: DS.Radius.control))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.control).strokeBorder(DS.Color.border, lineWidth: DS.Border.hairline))
            .contentShape(RoundedRectangle(cornerRadius: DS.Radius.control))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .handCursor()
    }
}

/// A multi-line box that starts at `minHeight`, grows with its text to `maxHeight`, then
/// keeps that height and scrolls inside. An optional counter sits bottom right.
///
/// `TextEditor` fills whatever frame it is given, so the text is measured with a hidden
/// `Text` of the same font and inset laid behind it; that measurement sets the height.
struct GrowingTextArea: View {
    let prompt: String
    @Binding var text: String
    var minHeight: CGFloat = DS.Material.snippetBoxMin
    var maxHeight: CGFloat = DS.Material.snippetBoxMax
    var counter: String? = nil

    @State private var measured: CGFloat = 0

    private var height: CGFloat { min(max(measured, minHeight), maxHeight) }

    var body: some View {
        TextEditor(text: $text)
            .font(DS.Font.body)
            .foregroundStyle(DS.Color.ink)
            .scrollContentBackground(.hidden)
            .padding(.horizontal, DS.Control.fieldPadX - DS.Space.tight)
            .padding(.vertical, DS.Control.fieldPadY)
            .frame(height: height)
            .frame(maxWidth: .infinity)
            .background(alignment: .top) {
                // The measuring copy: same font, same inset, never seen. A trailing space
                // keeps a fresh line counted before anything is typed on it.
                Text(text.isEmpty ? " " : text + " ")
                    .font(DS.Font.body)
                    .padding(.horizontal, DS.Control.fieldPadX)
                    .padding(.vertical, DS.Control.fieldPadY)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .hidden()
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { measured = $0 }
            }
            .overlay(alignment: .topLeading) {
                if text.isEmpty {
                    Text(prompt)
                        .font(DS.Font.body)
                        .foregroundStyle(DS.Color.placeholder)
                        .padding(.horizontal, DS.Control.fieldPadX)
                        .padding(.vertical, DS.Control.fieldPadY)
                        .allowsHitTesting(false)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if let counter {
                    Text(counter)
                        .font(DS.Font.monoSmall)
                        .foregroundStyle(DS.Color.dim)
                        .padding(.horizontal, DS.Space.fieldLabelGap)
                        .padding(.vertical, DS.Space.hair)
                        .background(DS.Color.counterBackdrop, in: RoundedRectangle(cornerRadius: DS.Radius.chip - DS.Border.hairline))
                        .padding(.trailing, DS.Control.fieldPadX)
                        .padding(.bottom, DS.Control.fieldPadY)
                        .allowsHitTesting(false)
                }
            }
            .background(DS.Color.controlFill, in: RoundedRectangle(cornerRadius: DS.Radius.control))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.control).strokeBorder(DS.Color.border, lineWidth: DS.Border.hairline))
    }
}

/// Edit and Delete at the end of a row, 4 apart, both quiet.
struct RowActions: View {
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: DS.Space.tight) {
            AppButton(title: "Edit", icon: "edit", action: onEdit)
            AppButton(title: "Delete", icon: "trash-can", action: onDelete)
        }
    }
}

/// A Copy button that flips to "Copied" with a check for `DS.Motion.statusHold`, then
/// back. No toast, ever.
struct CopyButton: View {
    let text: String
    var title: String = "Copy"
    var kind: AppButton.Kind = .tertiary

    @State private var didCopy = false

    var body: some View {
        AppButton(title: didCopy ? "Copied" : title, kind: kind, icon: didCopy ? "checkmark" : "copy") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            didCopy = true
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(DS.Motion.statusHold))
                didCopy = false
            }
        }
    }
}

/// The way in to deleting: faint text with a small bin, at the very end of a list or a
/// transcript, never on a row (Gokul, 16 Oct 2026: "the user has to search for the delete").
/// Every press of it goes on to `DeleteQuestionView`.
struct FaintDelete<Leading: View>: View {
    let title: String
    @ViewBuilder var leading: Leading
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack {
            leading
            Spacer(minLength: 0)
            Button(action: action) {
                HStack(spacing: DS.Space.tight + DS.Space.hair) {
                    CarbonIcon(name: "trash-can", size: DS.Control.iconSizeTiny)
                    Text(title).font(DS.Font.micro)
                }
                .foregroundStyle(isHovering ? DS.Color.inkSecondary : DS.Color.dim)
                .opacity(isHovering ? 1 : DS.Material.faintDeleteOpacity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { isHovering = $0 }
            .handCursor()
        }
        .padding(.horizontal, DS.Space.rowPadX)
        .padding(.vertical, DS.Space.roomy)
        .overlay(alignment: .top) { CardDivider() }
    }
}

extension FaintDelete where Leading == EmptyView {
    init(title: String, action: @escaping () -> Void) {
        self.init(title: title, leading: { EmptyView() }, action: action)
    }
}

/// Where a list's files are, as Home › SigmaFlow › Meetings, at the left of its footer
/// (27 Oct 2026, docs/mockups/meetings-folder-path.html, picks 1B 2C 3C 4B). Each part is a
/// button that shows that folder selected in the one around it, so the last part opens the
/// SigmaFlow folder with Meetings selected; Home opens Home. As faint as `FaintDelete`.
struct PathBar: View {
    let folder: URL

    private var parts: [(name: String, url: URL)] {
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
        let target = folder.standardizedFileURL
        var url: URL
        var names: [String]
        var result: [(name: String, url: URL)] = []
        if target.path.hasPrefix(home.path + "/") {
            url = home
            names = Array(target.pathComponents.dropFirst(home.pathComponents.count))
            result.append((name: "Home", url: home))
        } else {
            url = URL(fileURLWithPath: "/", isDirectory: true)
            names = Array(target.pathComponents.dropFirst())
        }
        for name in names {
            url = url.appendingPathComponent(name, isDirectory: true)
            result.append((name: name, url: url))
        }
        return result
    }

    var body: some View {
        let parts = parts
        HStack(spacing: DS.Space.hair) {
            ForEach(Array(parts.enumerated()), id: \.offset) { index, part in
                if index > 0 {
                    Text("›").font(DS.Font.monoSmall).foregroundStyle(DS.Color.dim)
                }
                PathPart(name: part.name) {
                    if index == 0 && part.name == "Home" {
                        NSWorkspace.shared.open(part.url)
                    } else {
                        NSWorkspace.shared.activateFileViewerSelecting([part.url])
                    }
                }
            }
        }
        .opacity(DS.Material.faintDeleteOpacity)
    }
}

private struct PathPart: View {
    let name: String
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: DS.Space.tight + DS.Space.hair) {
                CarbonIcon(name: "folder", size: DS.Control.iconSizeTiny)
                Text(name).font(DS.Font.monoSmall).lineLimit(1).truncationMode(.middle)
            }
            .foregroundStyle(isHovering ? DS.Color.ink : DS.Color.dim)
            .padding(.horizontal, DS.Space.tight)
            .padding(.vertical, DS.Space.hair)
            .background(isHovering ? DS.Color.selectedFill : .clear, in: RoundedRectangle(cornerRadius: DS.Radius.control))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Open in Finder")
        .onHover { isHovering = $0 }
        .handCursor()
    }
}

/// A tick box, white with a dark check when on.
struct TickBox: View {
    let isOn: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: DS.Radius.chip)
            .fill(isOn ? DS.Color.ink : DS.Color.tickFill)
            .overlay {
                if isOn {
                    CarbonIcon(name: "checkmark", size: DS.Material.tickMark)
                        .foregroundStyle(DS.Color.inkOnInverted)
                } else {
                    RoundedRectangle(cornerRadius: DS.Radius.chip)
                        .strokeBorder(DS.Color.tickEdge, lineWidth: DS.Border.hairline)
                }
            }
            .frame(width: DS.Material.tickSize, height: DS.Material.tickSize)
    }
}
