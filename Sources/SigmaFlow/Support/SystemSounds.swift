import AppKit
import Foundation

/// The ticks that mark the start and end of a recording.
///
/// macOS ships a set of short system sounds and every one of them is already on disk, so
/// there is nothing to bundle and nothing to license. The list is read from the system
/// rather than hardcoded, so a new macOS release that adds or drops a sound is handled
/// without a code change; the known set is only a fallback if that read ever fails.
enum SystemSounds {
    /// The stored value that means "stay quiet for this event".
    static let silent = "None"

    /// Every system sound available on this Mac, alphabetical, with silence first.
    static var available: [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: "/System/Library/Sounds"))?
            .compactMap { name -> String? in
                let url = URL(fileURLWithPath: name)
                guard url.pathExtension == "aiff" else { return nil }
                return url.deletingPathExtension().lastPathComponent
            }
            .sorted()

        return [silent] + (names?.isEmpty == false ? names! : fallback)
    }

    /// Shipped with every macOS release for many years. Used only if the directory read
    /// fails, so the picker is never empty.
    private static let fallback = [
        "Basso", "Blow", "Bottle", "Frog", "Funk", "Glass", "Hero",
        "Morse", "Ping", "Pop", "Purr", "Sosumi", "Submarine", "Tink",
    ]

    /// Plays a sound by name. Silence and unknown names are no-ops rather than errors:
    /// a sound that vanished in a macOS update should not break dictation.
    static func play(_ name: String) {
        guard name != silent, !name.isEmpty else { return }
        NSSound(named: name)?.play()
    }

    @MainActor
    static func playStart() {
        guard Settings.shared.soundEnabled else { return }
        play(Settings.shared.startSound)
    }

    @MainActor
    static func playStop() {
        guard Settings.shared.soundEnabled else { return }
        play(Settings.shared.stopSound)
    }
}
