import Foundation
import Observation

/// What the overlay shows while you dictate.
enum OverlayMode: String, CaseIterable, Sendable {
    /// Words appear as you speak; the overlay grows with the text.
    case live
    /// Recording light, timer, and level only. Words appear when they're inserted.
    case minimal

    var displayName: String {
        switch self {
        case .live: "Live transcript"
        case .minimal: "Minimal"
        }
    }
}

@MainActor
@Observable
final class Settings {
    static let shared = Settings()

    var pushToTalkKey: PushToTalkKey {
        didSet { persistPushToTalkKey() }
    }

    /// The last recorded custom shortcut, kept even while a preset is selected, so
    /// picking "custom" again restores it instead of demanding a new recording.
    var savedCustomCombo: HotkeyCombo? {
        didSet {
            if let savedCustomCombo, let data = try? JSONEncoder().encode(savedCustomCombo) {
                defaults.set(data, forKey: Keys.customHotkey)
            }
        }
    }

    /// Which model transcribes. See `SpeechModelID` for the catalog.
    var activeModel: SpeechModelID {
        didSet { defaults.set(activeModel.rawValue, forKey: Keys.activeModel) }
    }

    /// Which microphone records. `nil` means the system default input.
    var microphoneID: String? {
        didSet {
            if let microphoneID {
                defaults.set(microphoneID, forKey: Keys.microphoneID)
            } else {
                defaults.removeObject(forKey: Keys.microphoneID)
            }
        }
    }

    /// Live transcript in the overlay, or the minimal recording indicator.
    var overlayMode: OverlayMode {
        didSet { defaults.set(overlayMode.rawValue, forKey: Keys.overlayMode) }
    }

    /// Power mode: hold Right ⌥ with Right ⌘ and the dictation is sent the moment it lands
    /// (Return is pressed after the paste). Only means anything while Right ⌘ is the
    /// push-to-talk key, since the two keys sit side by side.
    var powerMode: Bool {
        didSet { defaults.set(powerMode, forKey: Keys.powerMode) }
    }

    /// When a call app turns the microphone on, offer to record the call as a meeting
    /// (docs/mockups/meeting-call-detect.html). On to start with.
    var askToRecordCalls: Bool {
        didSet { defaults.set(askToRecordCalls, forKey: Keys.askToRecordCalls) }
    }

    /// Run the cleanup pass before injecting. Off = raw engine output.
    var cleanupEnabled: Bool {
        didSet { defaults.set(cleanupEnabled, forKey: Keys.cleanupEnabled) }
    }

    /// Use the on-device LLM for cleanup instead of the deterministic rule pass.
    var smartCleanup: Bool {
        didSet { defaults.set(smartCleanup, forKey: Keys.smartCleanup) }
    }

    /// The default style every dictation is typed in: capitals and punctuation only.
    var defaultStyle: DefaultStyle {
        didSet { defaults.set(defaultStyle.rawValue, forKey: Keys.defaultStyle) }
    }

    /// Which model rewrites text when a style shortcut is pressed.
    var styleEngine: StyleEngineChoice {
        didSet { defaults.set(styleEngine.rawValue, forKey: Keys.styleEngine) }
    }

    /// What SigmaFlow follows every time Autowrite writes (docs/mockups/autowrite-page.html,
    /// round 1 2A 3A): how to sound, how to sign off, who people are. Autowrite only; styles
    /// and smart cleanup never read it.
    var autowriteInstructions: String {
        didSet { defaults.set(autowriteInstructions, forKey: Keys.autowriteInstructions) }
    }

    /// Play a short tick when capture starts and stops.
    var soundEnabled: Bool {
        didSet { defaults.set(soundEnabled, forKey: Keys.soundEnabled) }
    }

    /// Which system sound marks the start of a recording. `SystemSounds.silent` for none.
    var startSound: String {
        didSet { defaults.set(startSound, forKey: Keys.startSound) }
    }

    /// Which system sound marks the end of a recording.
    var stopSound: String {
        didSet { defaults.set(stopSound, forKey: Keys.stopSound) }
    }

    /// Pause whatever's playing when a recording starts; resume a moment after it ends.
    var pauseMediaWhileRecording: Bool {
        didSet { defaults.set(pauseMediaWhileRecording, forKey: Keys.pauseMedia) }
    }

    /// After typing into another app, watch that field briefly; a word the user fixes
    /// becomes a dictionary rule, announced in the HUD with a few seconds to undo.
    var learnFromCorrections: Bool {
        didSet { defaults.set(learnFromCorrections, forKey: Keys.learnFromCorrections) }
    }

    /// The page the main window opens on: the one that was open last time.
    var lastPage: String {
        didSet { defaults.set(lastPage, forKey: Keys.lastPage) }
    }

    /// The tab that was open on each tabbed page, keyed by page name.
    var openTabs: [String: String] {
        didSet { defaults.set(openTabs, forKey: Keys.openTabs) }
    }

    /// Where the SigmaFlow folder is: a bookmark, which follows the folder when it is moved
    /// on the same disk, and the path it was last seen at, for the message when it is lost.
    /// Never exported: a folder on one Mac means nothing on the next.
    var sigmaFlowFolderBookmark: Data? {
        didSet { defaults.set(sigmaFlowFolderBookmark, forKey: Keys.sigmaFlowFolderBookmark) }
    }

    var sigmaFlowFolderPath: String? {
        didSet { defaults.set(sigmaFlowFolderPath, forKey: Keys.sigmaFlowFolderPath) }
    }

    /// The first open has been walked through (docs/mockups/onboarding.html). Until it has,
    /// the app opens on the setup window instead of the main one.
    var firstOpenDone: Bool {
        didSet { defaults.set(firstOpenDone, forKey: Keys.firstOpenDone) }
    }

    private let defaults = UserDefaults.standard

    // MARK: - Export

    /// The keys worth carrying to another Mac. The microphone is left out on purpose: a
    /// device id from one machine means nothing on the next.
    private static let portableKeys = [
        Keys.pushToTalkKey, Keys.customHotkey, Keys.activeModel, Keys.overlayMode,
        Keys.cleanupEnabled, Keys.smartCleanup, Keys.soundEnabled,
        Keys.startSound, Keys.stopSound, Keys.pauseMedia, Keys.styleEngine, Keys.learnFromCorrections,
        Keys.defaultStyle, Keys.powerMode, Keys.askToRecordCalls, Keys.autowriteInstructions,
    ]

    /// A JSON-safe snapshot of the portable settings.
    func exported() -> [String: Any] {
        var out: [String: Any] = [:]
        for key in Self.portableKeys {
            guard let value = defaults.object(forKey: key) else { continue }
            if let data = value as? Data {
                out[key] = ["base64": data.base64EncodedString()]
            } else if value is String || value is Bool || value is NSNumber {
                out[key] = value
            }
        }
        return out
    }

    /// Applies a snapshot from `exported()`, then re-reads everything so the UI follows.
    func apply(exported snapshot: [String: Any]) {
        for key in Self.portableKeys {
            guard let value = snapshot[key] else { continue }
            if let wrapped = value as? [String: Any], let base64 = wrapped["base64"] as? String,
               let data = Data(base64Encoded: base64) {
                defaults.set(data, forKey: key)
            } else {
                defaults.set(value, forKey: key)
            }
        }
        reloadFromDefaults()
    }

    private func reloadFromDefaults() {
        let storedCombo = defaults.data(forKey: Keys.customHotkey)
            .flatMap { try? JSONDecoder().decode(HotkeyCombo.self, from: $0) }
        savedCustomCombo = storedCombo
        switch defaults.string(forKey: Keys.pushToTalkKey) {
        case "rightCommand": pushToTalkKey = .rightCommand
        case "custom": pushToTalkKey = storedCombo.map { .custom($0) } ?? .rightOption
        default: pushToTalkKey = .rightOption
        }
        if let stored = SpeechModelID(rawValue: defaults.string(forKey: Keys.activeModel) ?? "") {
            activeModel = stored
        }
        overlayMode = OverlayMode(rawValue: defaults.string(forKey: Keys.overlayMode) ?? "") ?? overlayMode
        powerMode = defaults.object(forKey: Keys.powerMode) as? Bool ?? powerMode
        askToRecordCalls = defaults.object(forKey: Keys.askToRecordCalls) as? Bool ?? askToRecordCalls
        cleanupEnabled = defaults.object(forKey: Keys.cleanupEnabled) as? Bool ?? cleanupEnabled
        smartCleanup = defaults.object(forKey: Keys.smartCleanup) as? Bool ?? smartCleanup
        soundEnabled = defaults.object(forKey: Keys.soundEnabled) as? Bool ?? soundEnabled
        startSound = defaults.string(forKey: Keys.startSound) ?? startSound
        stopSound = defaults.string(forKey: Keys.stopSound) ?? stopSound
        pauseMediaWhileRecording = defaults.object(forKey: Keys.pauseMedia) as? Bool ?? pauseMediaWhileRecording
        styleEngine = StyleEngineChoice(rawValue: defaults.string(forKey: Keys.styleEngine) ?? "") ?? styleEngine
        autowriteInstructions = defaults.string(forKey: Keys.autowriteInstructions) ?? autowriteInstructions
        defaultStyle = DefaultStyle(rawValue: defaults.string(forKey: Keys.defaultStyle) ?? "") ?? defaultStyle
        learnFromCorrections = defaults.object(forKey: Keys.learnFromCorrections) as? Bool ?? learnFromCorrections
    }

    private enum Keys {
        static let pushToTalkKey = "pushToTalkKey"
        static let customHotkey = "customHotkey"
        static let cleanupEnabled = "cleanupEnabled"
        static let soundEnabled = "soundEnabled"
        static let engine = "engine"
        static let activeModel = "activeModel"
        static let smartCleanup = "smartCleanup"
        static let overlayMode = "overlayMode"
        static let powerMode = "powerMode"
        static let askToRecordCalls = "askToRecordCalls"
        static let microphoneID = "microphoneID"
        static let pauseMedia = "pauseMediaWhileRecording"
        static let styleEngine = "styleEngine"
        static let autowriteInstructions = "autowriteInstructions"
        static let defaultStyle = "defaultStyle"
        static let startSound = "startSound"
        static let stopSound = "stopSound"
        static let learnFromCorrections = "learnFromCorrections"
        static let sigmaFlowFolderBookmark = "sigmaFlowFolderBookmark"
        static let sigmaFlowFolderPath = "sigmaFlowFolderPath"
        static let lastPage = "lastPage"
        static let openTabs = "openTabs"
        static let firstOpenDone = "firstOpenDone"
    }

    private func persistPushToTalkKey() {
        switch pushToTalkKey {
        case .rightOption:
            defaults.set("rightOption", forKey: Keys.pushToTalkKey)
        case .rightCommand:
            defaults.set("rightCommand", forKey: Keys.pushToTalkKey)
        case .custom(let combo):
            defaults.set("custom", forKey: Keys.pushToTalkKey)
            savedCustomCombo = combo
        }
    }

    private init() {
        let storedCombo = defaults.data(forKey: Keys.customHotkey)
            .flatMap { try? JSONDecoder().decode(HotkeyCombo.self, from: $0) }
        savedCustomCombo = storedCombo

        // "fn" was an option in earlier builds; swallowing it broke fn-key features, so
        // it's gone. Anyone who had it lands back on the default.
        switch defaults.string(forKey: Keys.pushToTalkKey) {
        case "rightCommand":
            pushToTalkKey = .rightCommand
        case "custom":
            pushToTalkKey = storedCombo.map { .custom($0) } ?? .rightOption
        default:
            pushToTalkKey = .rightOption
        }

        // Apple by default: no download, no dependency, live text while speaking.
        // Migration: the old two-engine setting maps onto the model catalog.
        if let stored = SpeechModelID(rawValue: defaults.string(forKey: Keys.activeModel) ?? "") {
            activeModel = stored
        } else if defaults.string(forKey: Keys.engine) == "parakeet" {
            activeModel = .parakeetV3
        } else {
            activeModel = .apple
        }
        microphoneID = defaults.string(forKey: Keys.microphoneID)
        overlayMode = OverlayMode(rawValue: defaults.string(forKey: Keys.overlayMode) ?? "") ?? .live
        // Off until switched on: sending without a Return press is a choice, not a default.
        powerMode = defaults.object(forKey: Keys.powerMode) as? Bool ?? false
        askToRecordCalls = defaults.object(forKey: Keys.askToRecordCalls) as? Bool ?? true
        cleanupEnabled = defaults.object(forKey: Keys.cleanupEnabled) as? Bool ?? true
        smartCleanup = defaults.object(forKey: Keys.smartCleanup) as? Bool ?? false
        soundEnabled = defaults.object(forKey: Keys.soundEnabled) as? Bool ?? true
        // The pair the app shipped with, so existing installs sound unchanged.
        startSound = defaults.string(forKey: Keys.startSound) ?? "Tink"
        stopSound = defaults.string(forKey: Keys.stopSound) ?? "Pop"
        pauseMediaWhileRecording = defaults.object(forKey: Keys.pauseMedia) as? Bool ?? true
        learnFromCorrections = defaults.object(forKey: Keys.learnFromCorrections) as? Bool ?? true
        lastPage = defaults.string(forKey: Keys.lastPage) ?? ""
        openTabs = defaults.dictionary(forKey: Keys.openTabs) as? [String: String] ?? [:]
        // Apple by default: styles work on a fresh install with no key and no account.
        styleEngine = StyleEngineChoice(rawValue: defaults.string(forKey: Keys.styleEngine) ?? "") ?? .apple
        autowriteInstructions = defaults.string(forKey: Keys.autowriteInstructions) ?? ""
        // Casual to start, as the Figma tiles show it.
        defaultStyle = DefaultStyle(rawValue: defaults.string(forKey: Keys.defaultStyle) ?? "") ?? .casual
        sigmaFlowFolderBookmark = defaults.data(forKey: Keys.sigmaFlowFolderBookmark)
        sigmaFlowFolderPath = defaults.string(forKey: Keys.sigmaFlowFolderPath)
        // An install from before the first open existed has opened its main window, which
        // remembers a page: that Mac is set up already and never sees the setup window.
        firstOpenDone = defaults.object(forKey: Keys.firstOpenDone) != nil
            ? defaults.bool(forKey: Keys.firstOpenDone)
            : defaults.string(forKey: Keys.lastPage) != nil
    }
}
