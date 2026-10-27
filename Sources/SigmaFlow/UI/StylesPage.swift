import AppKit
import SwiftUI

/// Styles, to Figma windows 23, 23B and 23C. Two tabs.
///
/// Default styles: three tiles, one always selected, that differ only in capitals and
/// punctuation and shape every dictation with no key. Custom styles: shortcut rewrites
/// of selected text, each a tile with Edit and Delete; the rewrite engine and its key
/// live at the top of this tab and nowhere else. Edit opens the editor under the grid.
struct StylesPage: View {
    @Bindable var controller: DictationController

    @State private var store = StyleStore.shared
    @State private var settings = Settings.shared
    @State private var draft: WritingStyle?
    @State private var isNew = false
    @State private var isChoosingEngine = false

    enum Tab: String { case defaults, custom }

    private var tab: Binding<Tab> {
        Binding(
            get: { Tab(rawValue: settings.openTabs["styles"] ?? "") ?? .defaults },
            set: { settings.openTabs["styles"] = $0.rawValue }
        )
    }

    var body: some View {
        PageScroll {
            PageHeader(
                "Styles",
                subtitle: "A default style shapes every dictation you type. Custom styles rewrite selected text in a voice you define, each with its own shortcut."
            ) {
                if tab.wrappedValue == .custom {
                    AppButton(title: "New style", kind: .secondary, icon: "add", isEnabled: store.nextFreeShortcut != nil) {
                        startNew()
                    }
                }
            }
            TabStrip(tabs: [(.defaults, "Default styles"), (.custom, "Custom styles")], selection: tab)
        } content: {
            switch tab.wrappedValue {
            case .defaults: defaultsTab
            case .custom: customTab
            }
        }
        .onExitCommand { if draft != nil { draft = nil } }
    }

    // MARK: - Default styles

    private var defaultsTab: some View {
        VStack(alignment: .leading, spacing: DS.Space.sectionGap) {
            HStack(alignment: .top, spacing: DS.Space.tileGap) {
                ForEach(DefaultStyle.allCases, id: \.self) { style in
                    DefaultStyleTile(style: style, isSelected: settings.defaultStyle == style) {
                        settings.defaultStyle = style
                    }
                }
            }
            .frame(height: DS.Material.tileHeightDefault)
            Text("The default style shapes every dictation, in every app. It needs no account and no key.")
                .font(DS.Font.caption)
                .foregroundStyle(DS.Color.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: DS.Space.measureTiles, alignment: .leading)
        }
    }

    // MARK: - Custom styles

    /// The engine card opens as a chooser when there is nothing to summarise yet: no
    /// styles, or a cloud engine with no key. Otherwise one row says what runs rewrites.
    private var showsEngineChooser: Bool {
        isChoosingEngine || store.styles.isEmpty || !engineHasKey(settings.styleEngine)
    }

    private var customTab: some View {
        VStack(alignment: .leading, spacing: DS.Space.sectionGap) {
            Card {
                if showsEngineChooser {
                    EngineChooser(settings: settings) { isChoosingEngine = false }
                } else {
                    engineSummary
                }
            }

            if store.styles.isEmpty {
                Card {
                    EmptyCardBody(
                        "No custom styles yet",
                        detail: "Pick an engine above and add its key. Then press New style to start blank, or add three starters you can edit or delete: Clean, Boss mode and Friendly."
                    ) {
                        AppButton(title: "Add the three starters", kind: .secondary) {
                            withAnimation(DS.Motion.panel) { store.addStarters() }
                        }
                    }
                }
            } else {
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: DS.Space.tileGap, alignment: .top), count: DS.Material.tileColumns),
                    alignment: .leading,
                    spacing: DS.Space.tileGap
                ) {
                    ForEach(store.styles) { style in
                        CustomStyleTile(
                            style: style,
                            isEditing: draft?.id == style.id && !isNew,
                            onEdit: { edit(style) },
                            onDelete: { delete(style) }
                        )
                    }
                }
            }

            if let draft {
                StyleEditorCard(
                    draft: draft,
                    isNew: isNew,
                    taken: Set(store.styles.filter { $0.id != draft.id }.map(\.shortcut)),
                    onSave: { saved in
                        store.save(saved)
                        self.draft = nil
                    },
                    onCancel: { self.draft = nil }
                )
                .id(draft.id)
            }
        }
    }

    private var engineSummary: some View {
        CardRow(
            "Rewrites run on \(engineName(settings.styleEngine))",
            caption: engineSummaryCaption,
            isLast: true
        ) {
            HStack(spacing: DS.Space.tight) {
                AppButton(title: "Change engine") { isChoosingEngine = true }
                if settings.styleEngine != .apple {
                    AppButton(title: "Change key") { isChoosingEngine = true }
                }
            }
        }
    }

    private var engineSummaryCaption: String {
        switch settings.styleEngine {
        case .apple: "On this Mac, free, no key."
        case .claude: "Your Anthropic key is saved in the Mac's Keychain."
        case .openRouter: "Your OpenRouter key is saved in the Mac's Keychain."
        }
    }

    private func engineName(_ engine: StyleEngineChoice) -> String {
        switch engine {
        case .apple: "Apple Intelligence"
        case .claude: "Claude"
        case .openRouter: "OpenRouter"
        }
    }

    private func engineHasKey(_ engine: StyleEngineChoice) -> Bool {
        switch engine {
        case .apple: true
        case .claude: Keychain.hasAnthropicKey
        case .openRouter: Keychain.hasOpenRouterKey
        }
    }

    // MARK: Editing

    private func startNew() {
        guard let free = store.nextFreeShortcut else { return }
        isNew = true
        draft = WritingStyle(name: "", shortcut: free, summary: "", prompt: "", rules: [.neverInvent])
    }

    private func edit(_ style: WritingStyle) {
        isNew = false
        draft = style
    }

    private func delete(_ style: WritingStyle) {
        if draft?.id == style.id { draft = nil }
        withAnimation(DS.Motion.panel) { store.delete(style) }
    }
}

// MARK: - Default tile

/// One of the three: name, what differs, the same sentence in that style, SELECTED when
/// it is the one in use. Clicking anywhere on it selects it.
private struct DefaultStyleTile: View {
    let style: DefaultStyle
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: DS.Space.base) {
                Text(style.displayName)
                    .font(DS.Font.tileTitle)
                    .foregroundStyle(DS.Color.ink)
                Text(style.caption)
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.inkSecondary)
                Text("“\(style.example)”")
                    .font(DS.Font.body)
                    .foregroundStyle(DS.Color.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, DS.Space.examplePadX)
                    .padding(.vertical, DS.Space.examplePadY)
                    .background(DS.Color.controlFill, in: RoundedRectangle(cornerRadius: DS.Radius.card))
                if isSelected {
                    HStack(spacing: DS.Space.fieldLabelGap) {
                        CarbonIcon(name: "checkmark", size: DS.Control.iconSizeTiny)
                            .foregroundStyle(DS.Color.ink)
                        Eyebrow("Selected", color: DS.Color.ink)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(DS.Space.tilePad)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(isSelected ? DS.Color.tileSelectedFill : DS.Color.glass, in: RoundedRectangle(cornerRadius: DS.Radius.card))
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.card).strokeBorder(
                    isSelected ? DS.Color.ink : DS.Color.border,
                    lineWidth: isSelected ? DS.Material.tileSelectedStroke : DS.Border.hairline
                )
            )
            .contentShape(RoundedRectangle(cornerRadius: DS.Radius.card))
        }
        .buttonStyle(.plain)
        .handCursor()
    }
}

// MARK: - Custom tile

/// A custom style: name with its key, the first line of its instructions, Edit and
/// Delete. The one being edited carries the selected fill and edge.
private struct CustomStyleTile: View {
    let style: WritingStyle
    let isEditing: Bool
    let onEdit: () -> Void
    let onDelete: () -> Void

    private var firstLine: String {
        let line = style.prompt.split(whereSeparator: \.isNewline).first.map(String.init) ?? style.prompt
        return line.isEmpty ? style.summary : line
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.base) {
            VStack(alignment: .leading, spacing: DS.Space.navInset) {
                HStack(spacing: DS.Space.navInset) {
                    Text(style.name)
                        .font(DS.Font.tileTitle)
                        .foregroundStyle(DS.Color.ink)
                    KeyChip(text: "⌥\(style.shortcut)")
                }
                Text(firstLine)
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.inkSecondary)
                    .lineLimit(DS.Material.tileLineLimit)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Spacer(minLength: 0)
            RowActions(onEdit: onEdit, onDelete: onDelete)
        }
        .padding(DS.Space.tilePad)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .frame(height: DS.Material.tileHeightCustom, alignment: .top)
        .clipped()
        .background(isEditing ? DS.Color.tileSelectedFill : DS.Color.glass, in: RoundedRectangle(cornerRadius: DS.Radius.card))
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.card).strokeBorder(
                isEditing ? DS.Color.ink : DS.Color.border,
                lineWidth: isEditing ? DS.Material.tileSelectedStroke : DS.Border.hairline
            )
        )
    }
}

// MARK: - Engine chooser

/// Three rows, pick one. A cloud engine opens a key field under its name; Save key
/// stores it in the Keychain and closes the chooser. Apple Intelligence needs nothing.
private struct EngineChooser: View {
    let settings: Settings
    let onDone: () -> Void

    @State private var anthropicKey = Keychain.anthropicKey ?? ""
    @State private var openRouterKey = Keychain.openRouterKey ?? ""

    var body: some View {
        engineRow(
            .apple, name: "Apple Intelligence",
            blurb: "On this Mac, free, no key. Needs an M-series Mac with Apple Intelligence turned on. Best for short texts."
        )
        CardDivider()
        engineRow(
            .claude, name: "Claude",
            blurb: "Anthropic's model with your own API key. The best rewrites; you pay Anthropic per use.",
            key: $anthropicKey, prompt: "Paste your Anthropic API key"
        ) { Keychain.anthropicKey = $0 }
        CardDivider()
        engineRow(
            .openRouter, name: "OpenRouter, free models",
            blurb: "Your own OpenRouter key, free models only. Quality varies by model.",
            key: $openRouterKey, prompt: "Paste your OpenRouter API key"
        ) { Keychain.openRouterKey = $0 }
    }

    @ViewBuilder
    private func engineRow(
        _ engine: StyleEngineChoice, name: String, blurb: String,
        key: Binding<String>? = nil, prompt: String = "", store: @escaping (String) -> Void = { _ in }
    ) -> some View {
        let isOn = settings.styleEngine == engine
        VStack(alignment: .leading, spacing: DS.Space.base) {
            Button {
                settings.styleEngine = engine
                if engine == .apple { onDone() }
            } label: {
                HStack(alignment: .top, spacing: DS.Space.rowPadX - DS.Space.hair) {
                    RadioMark(isOn: isOn)
                        .padding(.top, DS.Space.hair)
                    VStack(alignment: .leading, spacing: DS.Space.tight) {
                        Text(name)
                            .font(DS.Font.body)
                            .foregroundStyle(DS.Color.ink)
                        Text(blurb)
                            .font(DS.Font.caption)
                            .foregroundStyle(DS.Color.inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: DS.Space.measureCaption, alignment: .leading)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .handCursor()

            if isOn, let key {
                HStack(spacing: DS.Space.base) {
                    SecureFormField(prompt: prompt, text: key)
                        .frame(width: DS.Material.searchWidth)
                    AppButton(title: "Save key", kind: .secondary, isEnabled: !key.wrappedValue.trimmingCharacters(in: .whitespaces).isEmpty) {
                        store(key.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines))
                        onDone()
                    }
                }
                .padding(.leading, DS.Space.radioIndent)
            }
        }
        .padding(.horizontal, DS.Space.rowPadX)
        .padding(.vertical, DS.Space.rowPadY + DS.Space.hair)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isOn ? DS.Color.editorFill : Color.clear)
    }
}

// MARK: - Editor

/// Name, shortcut and instructions. Nothing else: the two guard rules are always on and
/// not shown. Opens under the tiles, outlined tile above it.
private struct StyleEditorCard: View {
    @State var draft: WritingStyle
    let isNew: Bool
    let taken: Set<String>
    let onSave: (WritingStyle) -> Void
    let onCancel: () -> Void

    private var shortcutOptions: [(String, String)] {
        ["1", "2", "3", "4", "5"]
            .filter { !taken.contains($0) || $0 == draft.shortcut }
            .map { ($0, "⌥ \($0)") }
    }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: DS.Space.roomy) {
                Eyebrow(isNew ? "New style" : "Editing \(draft.name)")
                HStack(alignment: .top, spacing: DS.Space.roomy) {
                    LabeledField(label: "Name") {
                        FormField(prompt: "Boss mode", text: $draft.name)
                    }
                    .frame(width: DS.Material.editorFieldWidth)
                    LabeledField(label: "Shortcut") {
                        PopupButton(selection: $draft.shortcut, options: shortcutOptions, width: DS.Control.popupWidthShortcut)
                    }
                    .frame(width: DS.Control.popupWidthShortcut)
                    Spacer(minLength: 0)
                }
                LabeledField(label: "Instructions") {
                    VStack(alignment: .leading, spacing: DS.Space.fieldLabelGap) {
                        Text("Brief SigmaFlow the way you would brief a person. When you press ⌥\(draft.shortcut) on selected text, it rewrites that text by these instructions and pastes the result back. The first line is what the tile shows.")
                            .font(DS.Font.caption)
                            .foregroundStyle(DS.Color.inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: DS.Space.measureWide, alignment: .leading)
                        GrowingTextArea(
                            prompt: "Rewrite as short, direct messages. Lead with the ask.",
                            text: $draft.prompt,
                            minHeight: DS.Material.instructionsHeight,
                            maxHeight: DS.Material.instructionsHeight * 2
                        )
                    }
                }
                HStack(spacing: DS.Space.tight) {
                    AppButton(title: "Save style", kind: .secondary, isEnabled: canSave) {
                        var cleaned = draft
                        cleaned.name = cleaned.name.trimmingCharacters(in: .whitespacesAndNewlines)
                        cleaned.prompt = cleaned.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
                        onSave(cleaned)
                    }
                    AppButton(title: "Cancel", action: onCancel)
                }
            }
            .padding(DS.Space.editorPad)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var canSave: Bool {
        !draft.name.trimmingCharacters(in: .whitespaces).isEmpty
            && !draft.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
