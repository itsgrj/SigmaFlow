import AppKit
import ApplicationServices
import Foundation

/// Puts text into whatever field currently has keyboard focus.
///
/// Two strategies, in order:
/// 1. **Accessibility** — set `kAXSelectedTextAttribute` on the focused element. Clean and
///    instant, and it leaves the pasteboard untouched.
/// 2. **Pasteboard + ⌘V** — works in Electron apps and anything else with a half-hearted
///    AX implementation. The previous pasteboard contents are restored afterwards.
///
/// The catch that makes this non-obvious: **many apps return `.success` from the AX write
/// and then do nothing.** Electron (Cursor, VS Code, Slack, Discord), Chrome, and most
/// terminal emulators all report `kAXSelectedTextAttribute` as settable, accept the write,
/// and silently drop it. So the return value is not evidence of anything — strategy 1 is
/// only trusted when the insertion point can be *observed* to have moved.
///
/// This all works because the HUD is a non-activating panel: focus never leaves the user's
/// target app, so "the focused element" is still their text field.
@MainActor
enum TextInjector {
    /// - Parameter pressingReturn: Power mode. Return is pressed once the text has landed,
    ///   so a chat message goes out without the user touching the key.
    /// - Returns: the element that had focus when the text went in, so a caller can keep
    ///   an eye on it afterwards (the correction learner), or nil if none could be found.
    @discardableResult
    static func insert(_ text: String, pressingReturn: Bool = false) -> AXUIElement? {
        guard !text.isEmpty else { return nil }

        let target = focusedElement()
        switch insertViaAccessibility(text) {
        case .inserted:
            Log.inject.info("inserted via AX (\(text.count) chars)")
            if pressingReturn {
                Task { @MainActor in
                    try? await Task.sleep(for: returnDelay)
                    postReturn()
                }
            }
        case .unverified(let reason):
            Log.inject.info("AX insert not verified (\(reason, privacy: .public)) — pasting")
            insertViaPasteboard(text, pressingReturn: pressingReturn)
        }
        return target
    }

    /// How long Return waits behind the text. Apps take the paste asynchronously (Electron
    /// and browser fields most of all); a Return that overtakes it sends an empty message.
    private static let returnDelay: Duration = .milliseconds(150)

    /// Whatever has keyboard focus right now, system-wide.
    static func focusedElement() -> AXUIElement? {
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            AXUIElementCreateSystemWide(),
            kAXFocusedUIElementAttribute as CFString,
            &focused
        ) == .success, let focused else { return nil }
        return unsafeDowncast(focused as AnyObject, to: AXUIElement.self)
    }

    /// Whether what has focus takes typing. Autowrite copies instead of typing only on a
    /// clear no: an element that reads as neither (or no element at all) is typed into, as a
    /// dictation would be.
    enum Focus { case text, notText, unknown }

    static func focus() -> Focus {
        guard let element = focusedElement() else { return .unknown }
        var role: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
        let textRoles: Set<String> = [
            kAXTextFieldRole as String, kAXTextAreaRole as String, kAXComboBoxRole as String, "AXSearchField",
        ]
        if let role = role as? String, textRoles.contains(role) { return .text }
        for attribute in [kAXSelectedTextAttribute, kAXValueAttribute] {
            var settable: DarwinBoolean = false
            if AXUIElementIsAttributeSettable(element, attribute as CFString, &settable) == .success, settable.boolValue {
                return .text
            }
        }
        return role == nil ? .unknown : .notText
    }

    /// Puts text on the clipboard and leaves it there (Autowrite's Copied).
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// The full text of a field, or nil when the app does not expose it (most Electron
    /// and browser fields do not).
    static func stringValue(of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success,
              let value else { return nil }
        return (value as AnyObject) as? String
    }

    private enum AXOutcome {
        case inserted
        case unverified(String)
    }

    // MARK: - Strategy 1: Accessibility, verified

    private static func insertViaAccessibility(_ text: String) -> AXOutcome {
        let systemWide = AXUIElementCreateSystemWide()

        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focused
        ) == .success, let focused else {
            return .unverified("no focused element")
        }

        let element = unsafeDowncast(focused as AnyObject, to: AXUIElement.self)

        var settable: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(
            element,
            kAXSelectedTextAttribute as CFString,
            &settable
        ) == .success, settable.boolValue else {
            return .unverified("selected text not settable")
        }

        // Without a readable insertion point there's no way to tell a real insert from a
        // silently-dropped one, so don't gamble — go straight to the fallback.
        guard let before = selectedRange(of: element) else {
            return .unverified("no readable selection range")
        }

        guard AXUIElementSetAttributeValue(
            element,
            kAXSelectedTextAttribute as CFString,
            text as CFString
        ) == .success else {
            return .unverified("set attribute failed")
        }

        guard let after = selectedRange(of: element) else {
            return .unverified("selection range unreadable after write")
        }

        // Deliberately a *movement* check, not an exact-length check. Falling back after a
        // write that actually landed would paste the text a second time, and a duplicated
        // paragraph is far worse than a missing one. Some apps normalize newlines or run
        // autocorrect, so the caret can legitimately advance by something other than the
        // UTF-16 count — only a completely unmoved selection proves nothing happened.
        let unchanged = after.location == before.location && after.length == before.length
        guard !unchanged else {
            return .unverified("selection unmoved at \(before.location)")
        }

        return .inserted
    }

    private static func selectedRange(of element: AXUIElement) -> CFRange? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &value
        ) == .success, let value else { return nil }

        let axValue = unsafeDowncast(value as AnyObject, to: AXValue.self)
        guard AXValueGetType(axValue) == .cfRange else { return nil }

        var range = CFRange()
        guard AXValueGetValue(axValue, .cfRange, &range) else { return nil }
        return range
    }

    // MARK: - Strategy 2: Pasteboard + ⌘V

    private static func insertViaPasteboard(_ text: String, pressingReturn: Bool) {
        let pasteboard = NSPasteboard.general
        let saved = pasteboard.pasteboardItems?.compactMap { item -> [NSPasteboard.PasteboardType: Data] in
            var copy: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) { copy[type] = data }
            }
            return copy
        }

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        Task { @MainActor in
            // Give the target app a moment to observe the new pasteboard generation before
            // ⌘V arrives, or a fast paste can grab the *previous* contents.
            try? await Task.sleep(for: .milliseconds(40))
            postCommandV()
            Log.inject.info("pasted (\(text.count) chars)")
            if pressingReturn {
                try? await Task.sleep(for: returnDelay)
                postReturn()
            }

            // The paste is asynchronous in the target app; restore only once it's had time
            // to read the pasteboard.
            try? await Task.sleep(for: .milliseconds(500))
            restore(saved, to: pasteboard)
        }
    }

    private static func postCommandV() {
        guard let source = CGEventSource(stateID: .privateState) else { return }
        let vKey: CGKeyCode = 9 // kVK_ANSI_V

        guard let down = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false)
        else { return }

        // Set explicitly rather than inheriting live hardware modifier state — the user may
        // still be resting a finger on something.
        down.flags = .maskCommand
        up.flags = .maskCommand
        // SigmaFlow's own keys never count as typing (TypedWords).
        down.setIntegerValueField(.eventSourceUserData, value: TypedWords.ownEventMark)

        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    /// A plain Return. The flags are cleared on purpose: Power mode means Right ⌥ may still
    /// be held, and Option-Return is a new line in most chat apps, not a send.
    private static func postReturn() {
        guard let source = CGEventSource(stateID: .privateState) else { return }
        let returnKey: CGKeyCode = 36 // kVK_Return

        guard let down = CGEvent(keyboardEventSource: source, virtualKey: returnKey, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: returnKey, keyDown: false)
        else { return }

        down.flags = []
        up.flags = []
        down.setIntegerValueField(.eventSourceUserData, value: TypedWords.ownEventMark)
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        Log.inject.info("pressed Return (Power mode)")
    }

    private static func restore(
        _ saved: [[NSPasteboard.PasteboardType: Data]]?,
        to pasteboard: NSPasteboard
    ) {
        guard let saved, !saved.isEmpty else { return }
        pasteboard.clearContents()
        let items = saved.map { entry -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in entry { item.setData(data, forType: type) }
            return item
        }
        pasteboard.writeObjects(items)
    }
}
