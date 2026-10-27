import SigmaFlowDictionary
import AppKit
import SwiftUI

/// Dictionary, to Figma window 21: names, products and terms the engines mishear, each
/// with the spelling you want typed. Search and Add word above the card, one row per rule
/// with Edit and Delete, and the learning switch in the footer.
///
/// The editor sits at the head of the card only while it is in use: Add word opens it
/// empty, Edit opens it with that rule, and Add, Save, Cancel or Esc close it
/// (docs/mockups/ui-audit.html, 04). "When I say this" left empty adds a plain term the
/// engines should know; the row then reads "any spelling".
struct DictionaryPanel: View {
    @Bindable var controller: DictationController

    @State private var store = DictionaryStore.shared
    @State private var settings = Settings.shared
    @State private var query = ""
    @State private var hear = ""
    @State private var write = ""
    /// Set while a row's rule is loaded into the editor.
    @State private var editingID: UUID?
    /// Set by Add word; the editor also shows while a rule is being edited.
    @State private var isAdding = false
    @FocusState private var focusedField: Field?
    @Environment(\.isSnapshotting) private var isSnapshotting

    private enum Field { case hear, write }

    private var isEditorOpen: Bool { isAdding || editingID != nil }

    private var entries: [DictionaryEntry] {
        let found = store.filtered(by: query)
        return isSnapshotting ? Array(found.prefix(DS.Material.snapshotRows + 1)) : found
    }

    var body: some View {
        ListPage {
            PageHeader(
                "Dictionary",
                subtitle: "Names, products and terms the engines mishear, each with the spelling you want typed."
            )
            ListToolbar(query: $query, placeholder: "Search entries", count: countLabel, addTitle: "Add word", onAdd: startAdding)
            Card {
                if isEditorOpen {
                    editor
                    CardDivider()
                }
                if store.entries.isEmpty {
                    EmptyCardBody(
                        "No words yet",
                        detail: "Add the first one above. When you fix a word right after SigmaFlow types it, it is added here for you."
                    )
                } else if entries.isEmpty {
                    EmptyCardBody("Nothing matches that search", detail: "Try fewer letters, or the other spelling.")
                } else {
                    CardScroll {
                        ForEach(entries) { entry in
                            DictionaryRow(entry: entry, onEdit: { edit(entry) }, onDelete: { delete(entry) })
                            CardDivider()
                        }
                    }
                }
            } footer: {
                learningFooter
            }
        }
        .onExitCommand { if isEditorOpen { clear() } }
    }

    private var countLabel: String {
        let count = store.entries.count
        return "\(count.formatted()) entr\(count == 1 ? "y" : "ies")"
    }

    // MARK: Editor

    private var editor: some View {
        EditorRow {
            HStack(alignment: .top, spacing: DS.Space.roomy) {
                LabeledField(label: "When I say this") {
                    FormField(prompt: "sigma flo", text: $hear, onSubmit: save)
                        .focused($focusedField, equals: .hear)
                }
                LabeledField(label: "SigmaFlow should type") {
                    FormField(prompt: "SigmaFlow", text: $write, onSubmit: save)
                        .focused($focusedField, equals: .write)
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
    }

    private var isValid: Bool {
        !write.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func save() {
        let trimmedWrite = write.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedHear = hear.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedWrite.isEmpty else { return }
        if let editingID, var existing = store.entries.first(where: { $0.id == editingID }) {
            existing.kind = trimmedHear.isEmpty ? .term : .correction
            existing.write = trimmedWrite
            existing.hear = trimmedHear
            store.update(existing)
        } else {
            store.add(
                DictionaryEntry(
                    id: UUID(),
                    kind: trimmedHear.isEmpty ? .term : .correction,
                    write: trimmedWrite,
                    hear: trimmedHear,
                    isEnabled: true
                )
            )
        }
        clear()
    }

    /// Opens the editor empty, with the cursor in its first box. A rule half-edited stays
    /// loaded: pressing Add word then only moves the cursor back.
    private func startAdding() {
        isAdding = true
        focus(.hear)
    }

    private func edit(_ entry: DictionaryEntry) {
        editingID = entry.id
        hear = entry.kind == .correction ? entry.hear : ""
        write = entry.write
        focus(.write)
    }

    /// The field is drawn in the same update that opens the editor; focus it on the next.
    private func focus(_ field: Field) {
        DispatchQueue.main.async { focusedField = field }
    }

    private func delete(_ entry: DictionaryEntry) {
        if editingID == entry.id { clear() }
        store.delete(entry)
    }

    private func clear() {
        editingID = nil
        isAdding = false
        focusedField = nil
        hear = ""
        write = ""
    }

    // MARK: Footer

    /// The switch that lets SigmaFlow add rules from the words you fix yourself. It lives
    /// here, where the rules it writes land, and nowhere else.
    private var learningFooter: some View {
        HStack(alignment: .center, spacing: DS.Space.roomy) {
            VStack(alignment: .leading, spacing: DS.Space.captionGap) {
                Text("Learn from my corrections")
                    .font(DS.Font.body)
                    .foregroundStyle(DS.Color.ink)
                Text("When you edit a word after SigmaFlow transcribes it, the correction is recorded here so the next transcriptions get that word right.")
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: DS.Space.measureFooter, alignment: .leading)
            }
            Spacer(minLength: 0)
            Toggle("", isOn: $settings.learnFromCorrections)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .tint(DS.Color.blue700)
        }
        .padding(.horizontal, DS.Space.rowPadX)
        .padding(.vertical, DS.Space.rowPadY)
        .background(DS.Color.footer)
    }
}

// MARK: - Row

/// One rule: what the engine hears at the left, what gets typed in the middle, Edit and
/// Delete at the right. A plain term reads "any spelling" on the left.
private struct DictionaryRow: View {
    let entry: DictionaryEntry
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: DS.Space.roomy) {
            Text(entry.kind == .correction ? entry.hear : "any spelling")
                .font(DS.Font.body)
                .foregroundStyle(DS.Color.inkSecondary)
                .frame(width: DS.Material.editorFieldWidth, alignment: .leading)
            Text(entry.write)
                .font(DS.Font.body)
                .foregroundStyle(DS.Color.ink)
                .frame(maxWidth: .infinity, alignment: .leading)
            RowActions(onEdit: onEdit, onDelete: onDelete)
        }
        .padding(.horizontal, DS.Space.rowPadX)
        .frame(minHeight: DS.Material.cardRowHeight)
    }
}
