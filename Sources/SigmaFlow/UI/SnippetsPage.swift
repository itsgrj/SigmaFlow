import AppKit
import SwiftUI

/// Snippets, to Figma window 22: say a short phrase, get a saved block of text. Search
/// and Add snippet above the card, one row per snippet with Edit and Delete, no footer.
///
/// The editor sits at the head of the card only while it is in use, exactly as on the
/// Dictionary page (docs/mockups/ui-audit.html, 04). Both boxes start at four lines and grow
/// with the text to about six, then scroll. The right box counts towards a 2,000 character
/// limit, enough for a long signature.
struct SnippetsPage: View {
    @Bindable var controller: DictationController

    @State private var store = SnippetStore.shared
    @State private var query = ""
    @State private var trigger = ""
    @State private var text = ""
    /// Set while an existing snippet is loaded into the editor.
    @State private var editingID: UUID?
    /// Set by Add snippet; the editor also shows while a snippet is being edited.
    @State private var isAdding = false
    @FocusState private var focusedField: Field?

    private enum Field { case trigger, text }

    private var isEditorOpen: Bool { isAdding || editingID != nil }

    /// The phrase or the saved text containing the search, as the Dictionary matches.
    private var shown: [Snippet] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return store.snippets }
        return store.snippets.filter {
            $0.trigger.localizedStandardContains(trimmed) || $0.text.localizedStandardContains(trimmed)
        }
    }

    var body: some View {
        ListPage {
            PageHeader(
                "Snippets",
                subtitle: "Say a short phrase, get a saved block of text. Good for addresses, links and sign-offs you type every day."
            )
            ListToolbar(query: $query, placeholder: "Search snippets", count: countLabel, addTitle: "Add snippet", onAdd: startAdding)
            Card {
                if isEditorOpen {
                    editor
                    CardDivider()
                }
                if store.snippets.isEmpty {
                    EmptyCardBody(
                        "No snippets yet",
                        detail: "Your email address is a good first one. Say its phrase while you dictate and the full text lands in its place."
                    )
                } else if shown.isEmpty {
                    EmptyCardBody("Nothing matches that search", detail: "Try fewer letters, or a word from the saved text.")
                } else {
                    CardScroll {
                        ForEach(Array(shown.enumerated()), id: \.element.id) { index, snippet in
                            SnippetRow(snippet: snippet, onEdit: { edit(snippet) }, onDelete: { delete(snippet) })
                            if index < shown.count - 1 { CardDivider() }
                        }
                    }
                }
            }
        }
        .onExitCommand { if isEditorOpen { clear() } }
    }

    private var countLabel: String {
        let count = store.snippets.count
        return "\(count.formatted()) snippet\(count == 1 ? "" : "s")"
    }

    // MARK: Editor

    private var editor: some View {
        EditorRow {
            HStack(alignment: .top, spacing: DS.Space.roomy) {
                LabeledField(label: "When I say this") {
                    GrowingTextArea(prompt: "A short phrase, two words or more. Like “my work email”.", text: $trigger)
                        .focused($focusedField, equals: .trigger)
                }
                LabeledField(label: "SigmaFlow should type") {
                    GrowingTextArea(prompt: "The text to insert, as many lines as you need.", text: $text, counter: counter)
                        .focused($focusedField, equals: .text)
                }
            }
            HStack(spacing: DS.Space.tight) {
                AppButton(
                    title: editingID == nil ? "Add" : "Save",
                    kind: .secondary,
                    isEnabled: isValid,
                    action: save
                )
                AppButton(title: "Cancel", action: clear)
            }
        }
        .onChange(of: text) { _, new in
            if new.count > DS.Material.snippetLimit { text = String(new.prefix(DS.Material.snippetLimit)) }
        }
        .onChange(of: trigger) { _, new in
            // A phrase is one line; Return in the left box moves nothing.
            if new.contains(where: \.isNewline) { trigger = new.replacingOccurrences(of: "\n", with: " ") }
        }
    }

    private var counter: String {
        "\(text.count.formatted()) / \(DS.Material.snippetLimit.formatted())"
    }

    private var isValid: Bool {
        !SnippetStore.normalize(trigger).isEmpty
            && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func save() {
        guard isValid else { return }
        store.save(Snippet(id: editingID ?? UUID(), trigger: trigger, text: text))
        clear()
    }

    /// Opens the editor empty, with the cursor in the phrase box. A snippet half-edited
    /// stays loaded: pressing Add snippet then only moves the cursor back.
    private func startAdding() {
        isAdding = true
        focus(.trigger)
    }

    private func edit(_ snippet: Snippet) {
        editingID = snippet.id
        trigger = snippet.trigger
        text = snippet.text
        focus(.text)
    }

    /// The box is drawn in the same update that opens the editor; focus it on the next.
    private func focus(_ field: Field) {
        DispatchQueue.main.async { focusedField = field }
    }

    private func delete(_ snippet: Snippet) {
        if editingID == snippet.id { clear() }
        store.delete(snippet)
    }

    private func clear() {
        editingID = nil
        isAdding = false
        focusedField = nil
        trigger = ""
        text = ""
    }
}

// MARK: - Row

/// One snippet: the phrase in quotes, the first line of its text, Edit and Delete.
private struct SnippetRow: View {
    let snippet: Snippet
    let onEdit: () -> Void
    let onDelete: () -> Void

    /// One line of the text, so the list scans; the full text lives in the editor.
    private var preview: String {
        snippet.text
            .split(whereSeparator: \.isNewline)
            .first.map(String.init) ?? snippet.text
    }

    var body: some View {
        HStack(alignment: .center, spacing: DS.Space.roomy) {
            Text("“\(snippet.trigger)”")
                .font(DS.Font.body)
                .foregroundStyle(DS.Color.ink)
                .frame(width: DS.Material.editorFieldWidth, alignment: .leading)
            Text(preview)
                .font(DS.Font.body)
                .foregroundStyle(DS.Color.inkSecondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            RowActions(onEdit: onEdit, onDelete: onDelete)
        }
        .padding(.horizontal, DS.Space.rowPadX)
        .frame(minHeight: DS.Material.cardRowHeight)
    }
}
