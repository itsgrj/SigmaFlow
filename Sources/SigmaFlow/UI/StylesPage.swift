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
                if settings.styleEngine == .claude || settings.styleEngine == .openRouter {
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
        case .local:
            switch localServer {
            case .some(let server) where server.kind != .other:
                "In \(server.name), on this Mac. Your text never leaves it."
            case .some(let server):
                "On this Mac, at \(server.place). Your text never leaves it."
            case nil:
                "On this Mac. Your text never leaves it."
            }
        }
    }

    /// The saved model's server, read from `settings` so the row follows a new pick.
    private var localServer: LocalServer? {
        guard let kind = LocalServer.Kind(rawValue: settings.localModelServer),
              let address = LocalModels.normalised(settings.localModelAddress) else { return nil }
        return LocalServer(kind: kind, address: address)
    }

    private func engineName(_ engine: StyleEngineChoice) -> String {
        switch engine {
        case .apple: "Apple Intelligence"
        case .claude: "Claude"
        case .openRouter: "OpenRouter"
        case .local: settings.localModelName.isEmpty ? "your own model" : settings.localModelName
        }
    }

    private func engineHasKey(_ engine: StyleEngineChoice) -> Bool {
        switch engine {
        case .apple: true
        case .claude: Keychain.hasAnthropicKey
        case .openRouter: Keychain.hasOpenRouterKey
        case .local: !settings.localModelName.isEmpty
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

/// Four rows in two groups (docs/mockups/local-model.html, 1B): on this Mac, Apple
/// Intelligence and the person's own model; with your key, Claude and OpenRouter. A cloud
/// engine opens a key field under its name; Save key stores it in the Keychain and closes
/// the chooser. The own model opens `LocalModelPicker`. Apple Intelligence needs nothing.
private struct EngineChooser: View {
    let settings: Settings
    let onDone: () -> Void

    @State private var anthropicKey = Keychain.anthropicKey ?? ""
    @State private var openRouterKey = Keychain.openRouterKey ?? ""

    var body: some View {
        group("On this Mac")
        engineRow(
            .apple, name: "Apple Intelligence",
            blurb: "On this Mac, free, no key. Needs an M-series Mac with Apple Intelligence turned on. Best for short texts."
        )
        CardDivider()
        engineRow(
            .local, name: "Your own model",
            blurb: "Ollama or LM Studio, with a model you choose. Free, no key."
        )
        CardDivider()
        group("With your key")
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

    private func group(_ title: String) -> some View {
        Eyebrow(title)
            .padding(.horizontal, DS.Space.rowPadX)
            .padding(.top, DS.Space.rowPadY)
            .frame(maxWidth: .infinity, alignment: .leading)
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

            if isOn, engine == .local {
                LocalModelPicker(settings: settings, onDone: onDone)
                    .padding(.leading, DS.Space.radioIndent)
            }
        }
        .padding(.horizontal, DS.Space.rowPadX)
        .padding(.vertical, DS.Space.rowPadY + DS.Space.hair)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isOn ? DS.Color.editorFill : Color.clear)
    }
}

// MARK: - Your own model

/// The open Your own model row (docs/mockups/local-model.html, 2A and 3B): every model
/// SigmaFlow finds on this Mac in one popup, under its server's name, and Use this model;
/// under it, faint, where it was found and Change, for any other address. When nothing
/// answers, Open Ollama (or LM Studio) if it is on this Mac, otherwise Look again.
private struct LocalModelPicker: View {
    let settings: Settings
    let onDone: () -> Void

    private enum Phase: Equatable {
        case looking
        case found([LocalModel])
        /// It answers, with no models in it.
        case empty(LocalServer)
        /// Installed and closed.
        case closed(LocalServer)
        case opening(LocalServer)
        case nothing
    }

    @Environment(\.isSnapshotting) private var isSnapshotting
    @State private var phase: Phase = .looking
    @State private var chosen: LocalModel?
    @State private var isChangingAddress = false
    @State private var address = ""
    @State private var addressMissed = false

    /// A snapshot can't wait for a server, so it draws one model found in Ollama.
    private static let snapshotModel = LocalModel(name: "gemma4:e4b", server: LocalModels.ollama)

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.base) {
            if isChangingAddress {
                addressLine
            } else if isSnapshotting {
                phaseLine(.found([Self.snapshotModel]), chosen: Self.snapshotModel)
            } else {
                phaseLine(phase, chosen: chosen)
            }
        }
        .task { await look() }
    }

    @ViewBuilder
    private func phaseLine(_ shown: Phase, chosen model: LocalModel?) -> some View {
        switch shown {
        case .looking:
            Caption("Looking on this Mac")
        case .found(let models):
            HStack(spacing: DS.Space.base) {
                LocalModelPopup(models: models, selection: $chosen, shown: model)
                AppButton(title: "Use this model", kind: .secondary, isEnabled: model != nil) {
                    guard let model else { return }
                    settings.useLocalModel(model)
                    onDone()
                }
            }
            if let server = model?.server { whereLine(found(server)) }
        case .empty(let server):
            HStack(spacing: DS.Space.base) {
                Caption("\(server.kind == .other ? "The server at \(server.place)" : server.name) has no models yet. Add one there, then look again.")
                AppButton(title: "Look again", kind: .secondary) { Task { await look() } }
            }
        case .closed(let server):
            HStack(spacing: DS.Space.base) {
                Caption("\(server.name) is on this Mac but not open.")
                AppButton(title: "Open \(server.name)", kind: .primary) {
                    Task {
                        phase = .opening(server)
                        _ = await LocalModels.open(server)
                        await look()
                    }
                }
            }
            whereLine(nil)
        case .opening(let server):
            Caption("Opening \(server.name)")
        case .nothing:
            HStack(spacing: DS.Space.base) {
                Caption("Open Ollama or LM Studio, then look again.")
                AppButton(title: "Look again", kind: .secondary) { Task { await look() } }
            }
            whereLine(nil)
        }
    }

    private var addressLine: some View {
        VStack(alignment: .leading, spacing: DS.Space.base) {
            HStack(spacing: DS.Space.base) {
                FormField(prompt: LocalModels.ollama.address.absoluteString, text: $address, onSubmit: lookThere)
                    .frame(width: DS.Control.localAddressWidth)
                AppButton(title: "Look there", kind: .secondary, isEnabled: LocalModels.normalised(address) != nil) {
                    lookThere()
                }
                AppButton(title: "Cancel") {
                    isChangingAddress = false
                    addressMissed = false
                }
            }
            Text(addressMissed ? "Nothing answered at that address." : "Any server that works like Ollama or LM Studio")
                .font(DS.Font.mono)
                .foregroundStyle(DS.Color.dim)
        }
    }

    private func found(_ server: LocalServer) -> String {
        server.kind == .other ? "Found at \(server.place)" : "Found in \(server.name) at \(server.place)"
    }

    /// Where the model came from, faint, and Change; with nothing found, Another address.
    private func whereLine(_ text: String?) -> some View {
        HStack(spacing: DS.Space.base) {
            if let text {
                Text(text)
                    .font(DS.Font.mono)
                    .foregroundStyle(DS.Color.dim)
            }
            Button(text == nil ? "Another address" : "Change") {
                address = chosen?.server.kind == .other ? chosen?.server.address.absoluteString ?? "" : ""
                addressMissed = false
                isChangingAddress = true
            }
            .buttonStyle(.plain)
            .font(DS.Font.mono)
            .foregroundStyle(DS.Color.inkSecondary)
            .underline(true, color: DS.Color.borderStrong)
            .handCursor()
        }
    }

    /// Ollama and LM Studio at their usual addresses, and the saved one if it is elsewhere.
    private func look() async {
        phase = .looking
        var servers = [LocalModels.ollama, LocalModels.lmStudio]
        if let kind = LocalServer.Kind(rawValue: settings.localModelServer),
           let saved = LocalModels.normalised(settings.localModelAddress),
           !servers.contains(where: { $0.address == saved }) {
            servers.insert(LocalServer(kind: kind, address: saved), at: 0)
        }
        let answers = await withTaskGroup(of: (Int, [LocalModel]?).self) { group in
            for (index, server) in servers.enumerated() {
                group.addTask { (index, await LocalModels.models(on: server)) }
            }
            var answers = [[LocalModel]?](repeating: nil, count: servers.count)
            for await (index, models) in group { answers[index] = models }
            return answers
        }
        let models = answers.compactMap { $0 }.flatMap { $0 }
        if !models.isEmpty {
            show(models)
        } else if let index = answers.firstIndex(where: { $0 != nil }) {
            phase = .empty(servers[index])
        } else if let installed = [LocalModels.ollama, LocalModels.lmStudio]
            .first(where: { LocalModels.appURL(for: $0.kind) != nil }) {
            phase = .closed(installed)
        } else {
            phase = .nothing
        }
    }

    private func lookThere() {
        let typed = address
        Task {
            guard let answer = await LocalModels.identify(typed) else {
                addressMissed = true
                return
            }
            isChangingAddress = false
            addressMissed = false
            if answer.models.isEmpty {
                phase = .empty(answer.server)
            } else {
                show(answer.models)
            }
        }
    }

    /// The models in the popup, set to the saved one when it is there, else the first.
    private func show(_ models: [LocalModel]) {
        phase = .found(models)
        chosen = models.first {
            $0.name == settings.localModelName && $0.server.address.absoluteString == settings.localModelAddress
        } ?? models.first
    }
}

/// The models found, each server's under its name, in `PopupButton`'s face.
private struct LocalModelPopup: View {
    let models: [LocalModel]
    @Binding var selection: LocalModel?
    /// What the face says; the selection, except in a snapshot.
    let shown: LocalModel?

    private var servers: [LocalServer] {
        models.reduce(into: []) { list, model in
            if !list.contains(model.server) { list.append(model.server) }
        }
    }

    var body: some View {
        Menu {
            ForEach(servers, id: \.self) { server in
                Section(server.kind == .other ? server.place : server.name) {
                    Picker("", selection: $selection) {
                        ForEach(models.filter { $0.server == server }, id: \.self) { model in
                            Text(model.name).tag(Optional(model))
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
            }
        } label: {
            PopupLabel(text: shown?.name ?? "", width: DS.Control.popupWidthModel)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .handCursor()
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
