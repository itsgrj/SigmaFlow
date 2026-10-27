import AppKit
import Carbon.HIToolbox
import Foundation

/// A recorded custom shortcut: one regular key plus the modifiers held with it.
struct HotkeyCombo: Codable, Hashable, Sendable {
    var keyCode: Int64
    var control: Bool
    var option: Bool
    var shift: Bool
    var command: Bool
    /// Human-readable form, e.g. "⌃⌥D". Built at capture time from the actual keystroke.
    var display: String

    /// The modifier bits that must be down alongside the key. Union masks are correct
    /// here — a custom shortcut doesn't care which side's Option is held.
    var requiredFlags: CGEventFlags {
        var flags = CGEventFlags()
        if control { flags.insert(.maskControl) }
        if option { flags.insert(.maskAlternate) }
        if shift { flags.insert(.maskShift) }
        if command { flags.insert(.maskCommand) }
        return flags
    }
}

/// What holds the mic open: one of the two dedicated right-hand modifiers, or a
/// shortcut the user recorded themselves.
enum PushToTalkKey: Hashable, Sendable {
    case rightOption
    case rightCommand
    case custom(HotkeyCombo)

    var keyCode: Int64 {
        switch self {
        case .rightOption: Int64(kVK_RightOption)   // 61
        case .rightCommand: Int64(kVK_RightCommand) // 54
        case .custom(let combo): combo.keyCode
        }
    }

    /// Device-*dependent* bit for this specific physical key.
    ///
    /// `CGEventFlags.maskAlternate` is the union mask — it's set whenever *either* Option
    /// key is down. Using it means: hold Left ⌥, tap Right ⌥, and the release is invisible
    /// (the union bit is still set by the left key), so `onRelease` never fires. The mic
    /// stays open, the HUD stays up, and the next press is swallowed too.
    ///
    /// These raw values are the NX_DEVICE* masks from IOKit's event system; they carry the
    /// left/right distinction that the public `CGEventFlags` constants discard.
    var flag: CGEventFlags {
        switch self {
        case .rightOption: CGEventFlags(rawValue: 0x40)   // NX_DEVICERALTKEYMASK
        case .rightCommand: CGEventFlags(rawValue: 0x10)  // NX_DEVICERCMDKEYMASK
        case .custom: CGEventFlags()                       // custom keys ride keyDown/keyUp
        }
    }

    var displayName: String {
        switch self {
        case .rightOption: "Right ⌥"
        case .rightCommand: "Right ⌘"
        case .custom(let combo): combo.display
        }
    }
}

/// Watches for the held push-to-talk shortcut using a `CGEventTap`.
///
/// A tap is required rather than `NSEvent.addGlobalMonitor` because left/right modifier
/// discrimination doesn't surface through the higher-level APIs, and a custom shortcut's
/// keystrokes must be swallowed so they don't also type into the focused app. This needs
/// Accessibility permission; without it `CGEvent.tapCreate` returns nil.
@MainActor
final class HotkeyMonitor {
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var isPressed = false

    var key: PushToTalkKey = .rightOption
    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?
    /// Esc means cancel, everywhere. Return `true` to swallow the keystroke (a recording
    /// or processing run was abandoned); `false` lets Esc through to whatever app has it.
    var onEscape: (() -> Bool)?
    /// Option plus 1…5 applies a style to the selection. Return `true` when a style claimed
    /// the key, so it never types a character into the user's document.
    var onStyleKey: ((String) -> Bool)?
    /// Any ordinary key going down that is not one of ours. Latched recording listens to
    /// this: typing means you are done talking. The key is never swallowed.
    var onOtherKey: (() -> Void)?
    /// Option plus Delete takes back the last learned correction while its notice is up.
    /// Return `true` to swallow the keystroke.
    var onUndoKey: (() -> Bool)?
    /// ⌃⌥M starts or stops a meeting recording from anywhere. Return `true` to swallow it.
    var onMeetingKey: (() -> Bool)?
    /// ⌃⌥N opens or stops live notes from anywhere. Return `true` to swallow it.
    var onNotesKey: (() -> Bool)?
    /// Right ⌘ + S: a screenshot into live notes (Gokul, 16 Oct 2026, 4A). Read from the
    /// device-dependent bit, so Left ⌘ + S stays Save. Return `true` to swallow it.
    var onScreenshotKey: (() -> Bool)?
    /// Right ⌥ going down or up, reported only while Right ⌘ is the push-to-talk key: held
    /// together they are Power mode's send. Read from the device-dependent bit on every
    /// modifier change, so it is already current when the ⌘ release arrives. Never swallowed.
    var onCompanionChange: ((Bool) -> Void)?
    private var companionDown = false
    /// Autowrite's key (`WriteKey`): the right-hand modifier that isn't push-to-talk.
    /// Down on its own, it holds Autowrite open; down while push-to-talk is already held,
    /// it is Power mode's companion and nothing here. Any other key while it is held is
    /// reported (`onWriteInterrupted`) and let through, so ⌥ and ⌘ shortcuts keep working.
    var writeKey: PushToTalkKey?
    var onWritePress: (() -> Void)?
    var onWriteRelease: (() -> Void)?
    var onWriteInterrupted: (() -> Void)?
    private var writePressed = false
    /// Every key a person pressed that SigmaFlow let through, sorted for counting typed
    /// words (`TypedWords`). Never swallowed.
    var onTyping: ((TypedWords.Keystroke) -> Void)?

    /// Option-number keycodes. 5 is 23, not 22 — the ANSI number row is not contiguous.
    private static let styleKeyCodes: [Int64: String] = [
        18: "1", 19: "2", 20: "3", 21: "4", 23: "5",
    ]

    /// - Returns: `false` if the tap couldn't be created — almost always missing Accessibility permission.
    @discardableResult
    func start() -> Bool {
        stop()

        // The modifier presets live on flagsChanged; a custom shortcut's regular key
        // lives on keyDown/keyUp. One tap watches all three.
        let mask = (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(refcon).takeUnretainedValue()

                // CGEvent isn't Sendable, so pull out the plain values before crossing into
                // actor-isolated code. The tap was added to the main run loop, so this
                // callback genuinely does run on the main thread.
                let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
                let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
                let flags = event.flags
                // Typing, for Insights: only keys going down that a person pressed, never
                // SigmaFlow's own (they carry its mark), and only the count leaves here.
                var typed: TypedWords.Keystroke?
                if type == .keyDown, event.getIntegerValueField(.eventSourceUserData) != TypedWords.ownEventMark {
                    var length = 0
                    var units = [UniChar](repeating: 0, count: 4)
                    event.keyboardGetUnicodeString(maxStringLength: units.count, actualStringLength: &length, unicodeString: &units)
                    let characters = String(utf16CodeUnits: units, count: length)
                    typed = TypedWords.keystroke(keyCode: keyCode, flags: flags, characters: characters)
                }
                let consume = MainActor.assumeIsolated {
                    let consume = monitor.handle(type: type, keyCode: keyCode, flags: flags, isRepeat: isRepeat)
                    if !consume, let typed { monitor.onTyping?(typed) }
                    return consume
                }
                return consume ? nil : Unmanaged.passUnretained(event)
            },
            userInfo: refcon
        ) else {
            Log.hotkey.error("tapCreate failed — Accessibility permission missing?")
            return false
        }

        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        Log.hotkey.info("listening for \(self.key.displayName)")
        return true
    }

    func stop() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        }
        tap = nil
        runLoopSource = nil
        isPressed = false
        writePressed = false
        if companionDown {
            companionDown = false
            onCompanionChange?(false)
        }
    }

    // MARK: - Tap callback

    /// - Returns: `true` if the event should be swallowed rather than passed along.
    private func handle(type: CGEventType, keyCode: Int64, flags: CGEventFlags, isRepeat: Bool) -> Bool {
        // The system disables a tap that runs too slowly or is interrupted; re-arm it.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return false
        }

        // Esc first: it outranks every shortcut, including a custom combo built on it.
        if type == .keyDown, keyCode == Int64(kVK_Escape), !isRepeat,
           let onEscape, onEscape() {
            return true
        }

        // A key going down while Autowrite's key is held: it was a shortcut, not a hold.
        // Reported first, then the key goes on to whatever it is (a style key included).
        if type == .keyDown, writePressed, !isRepeat {
            onWriteInterrupted?()
        }

        // Option plus a number, with nothing else held. Checked before push-to-talk so a
        // custom shortcut built on Option cannot shadow the style keys.
        if type == .keyDown, !isRepeat,
           let styleKey = Self.styleKeyCodes[keyCode],
           flags.contains(.maskAlternate),
           !flags.contains(.maskCommand), !flags.contains(.maskControl), !flags.contains(.maskShift),
           let onStyleKey, onStyleKey(styleKey) {
            return true
        }

        // Option plus Delete, nothing else held, only while a correction notice is showing.
        if type == .keyDown, !isRepeat, keyCode == Int64(kVK_Delete),
           flags.contains(.maskAlternate),
           !flags.contains(.maskCommand), !flags.contains(.maskControl), !flags.contains(.maskShift),
           let onUndoKey, onUndoKey() {
            return true
        }

        // Control + Option + M, with neither Command nor Shift: the meeting toggle.
        if type == .keyDown, !isRepeat, keyCode == Int64(kVK_ANSI_M),
           flags.contains(.maskControl), flags.contains(.maskAlternate),
           !flags.contains(.maskCommand), !flags.contains(.maskShift),
           let onMeetingKey, onMeetingKey() {
            return true
        }

        // Control + Option + N, the same way: live notes.
        if type == .keyDown, !isRepeat, keyCode == Int64(kVK_ANSI_N),
           flags.contains(.maskControl), flags.contains(.maskAlternate),
           !flags.contains(.maskCommand), !flags.contains(.maskShift),
           let onNotesKey, onNotesKey() {
            return true
        }

        // Right ⌘ + S, nothing else held: only claimed while live notes are open.
        if type == .keyDown, !isRepeat, keyCode == Int64(kVK_ANSI_S),
           flags.contains(PushToTalkKey.rightCommand.flag),
           !flags.contains(.maskControl), !flags.contains(.maskAlternate), !flags.contains(.maskShift),
           let onScreenshotKey, onScreenshotKey() {
            return true
        }

        // Any other regular key: report it and let it through. Modifiers on their own ride
        // flagsChanged and never reach here, so holding Command does not count.
        if type == .keyDown, !isRepeat, keyCode != key.keyCode {
            onOtherKey?()
        }

        // Autowrite's key on its own. Ignored while push-to-talk is held (Power mode's
        // companion, handled below); its release always counts once its press did.
        if type == .flagsChanged, let writeKey, keyCode == writeKey.keyCode {
            let down = flags.contains(writeKey.flag)
            if down != writePressed, writePressed || !isPressed {
                writePressed = down
                if down { onWritePress?() } else { onWriteRelease?() }
                return true
            }
        }

        if case .custom(let combo) = key {
            return handleCustom(combo, type: type, keyCode: keyCode, flags: flags, isRepeat: isRepeat)
        }

        if type == .flagsChanged, key == .rightCommand {
            let companion = flags.contains(PushToTalkKey.rightOption.flag)
            if companion != companionDown {
                companionDown = companion
                onCompanionChange?(companion)
            }
        }

        guard type == .flagsChanged, keyCode == key.keyCode else { return false }
        // Push-to-talk pressed while Autowrite's key is held belongs to neither.
        guard !writePressed else { return false }

        let nowPressed = flags.contains(key.flag)
        guard nowPressed != isPressed else { return false }
        isPressed = nowPressed

        if nowPressed { onPress?() } else { onRelease?() }

        // Dedicated right-hand modifiers are safe to consume.
        return true
    }

    /// Hold-to-talk for a recorded shortcut: press fires when the key goes down with the
    /// combo's modifiers held; release fires when the key comes back up. Everything the
    /// shortcut generates — the press, the autorepeats, the release — is swallowed so it
    /// never types into the focused app.
    private func handleCustom(
        _ combo: HotkeyCombo, type: CGEventType, keyCode: Int64, flags: CGEventFlags, isRepeat: Bool
    ) -> Bool {
        guard keyCode == combo.keyCode else { return false }

        switch type {
        case .keyDown:
            if isPressed { return true }  // swallow autorepeat while held
            guard !isRepeat, flags.contains(combo.requiredFlags) else { return false }
            isPressed = true
            onPress?()
            return true
        case .keyUp:
            guard isPressed else { return false }
            isPressed = false
            onRelease?()
            return true
        default:
            return false
        }
    }
}
