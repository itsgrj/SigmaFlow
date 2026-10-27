import AppKit
import Carbon.HIToolbox
import Foundation

/// Takes whatever text is selected in the frontmost app, rewrites it, and puts the result
/// back in its place.
///
/// There is no API for "read the selection in another app", so this does what a person
/// would: press ⌘C, read the pasteboard, then press ⌘V with the new text. Two details make
/// it safe rather than destructive:
///
/// - The pasteboard's `changeCount` is watched rather than its contents. Comparing strings
///   would mistake "the user copied this same text a minute ago" for "nothing is selected".
/// - Whatever the user had on the pasteboard is put back afterwards, so a rewrite never
///   costs them the thing they were about to paste.
///
/// The replacement lands as a normal paste, which means ⌘Z in the host app undoes it.
@MainActor
enum SelectionRewriter {
    private static var isRunning = false

    static func apply(_ style: WritingStyle, controller: DictationController) {
        guard !isRunning else { return }
        isRunning = true

        Task { @MainActor in
            defer { isRunning = false }
            do {
                let selected = try copySelection()
                controller.beginStyleActivity(style.name, message: "Rewriting")

                let engine = StyleEngines.current()
                let rewritten = try await withThrowingTaskGroup(of: String.self) { group in
                    group.addTask { try await engine.rewrite(selected, style: style) }
                    group.addTask {
                        try await Task.sleep(for: .seconds(45))
                        throw StyleError.timedOut
                    }
                    guard let first = try await group.next() else { throw StyleError.timedOut }
                    group.cancelAll()
                    return first
                }

                paste(rewritten)
                controller.endStyleActivity()
                Log.inject.info("style \(style.name, privacy: .public) applied (\(selected.count) → \(rewritten.count) chars)")
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                controller.failStyleActivity(style.name, message: message)
                Log.inject.error("style \(style.name, privacy: .public) failed: \(message, privacy: .public)")
            }
        }
    }

    // MARK: - Pasteboard

    private static var savedItems: [[String: Data]] = []

    /// Presses ⌘C and waits for the frontmost app to answer.
    private static func copySelection() throws -> String {
        let pasteboard = NSPasteboard.general
        savedItems = snapshot()
        let before = pasteboard.changeCount

        press(keyCode: CGKeyCode(kVK_ANSI_C), command: true)

        // Apps answer a copy at wildly different speeds; poll instead of guessing one delay.
        let deadline = Date().addingTimeInterval(0.7)
        while Date() < deadline {
            if pasteboard.changeCount != before,
               let text = pasteboard.string(forType: .string),
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return text
            }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.03))
        }
        restore()
        throw StyleError.noSelection
    }

    private static func paste(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        press(keyCode: CGKeyCode(kVK_ANSI_V), command: true)

        // Give the host app time to read the pasteboard before handing it back.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            restore()
        }
    }

    private static func snapshot() -> [[String: Data]] {
        NSPasteboard.general.pasteboardItems?.compactMap { item in
            var stored: [String: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) { stored[type.rawValue] = data }
            }
            return stored.isEmpty ? nil : stored
        } ?? []
    }

    private static func restore() {
        guard !savedItems.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let items = savedItems.map { stored -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in stored {
                item.setData(data, forType: NSPasteboard.PasteboardType(type))
            }
            return item
        }
        pasteboard.writeObjects(items)
        savedItems = []
    }

    /// Synthesises a keystroke into whatever app is frontmost. The HUD is a non-activating
    /// panel, so that is still the user's app and not us.
    private static func press(keyCode: CGKeyCode, command: Bool) {
        let source = CGEventSource(stateID: .combinedSessionState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        else { return }
        if command {
            down.flags = .maskCommand
            up.flags = .maskCommand
        }
        // SigmaFlow's own keys never count as typing (TypedWords).
        down.setIntegerValueField(.eventSourceUserData, value: TypedWords.ownEventMark)
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }
}
