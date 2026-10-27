import Foundation

/// The default style shapes every dictation, in every app, with no account and no key.
/// The three differ only in capitals and punctuation (Gokul, 10 Oct 2026); everything
/// else about the text is left alone. Runs after cleanup and before the dictionary, so a
/// name the dictionary guarantees keeps its capitals whatever the style.
enum DefaultStyle: String, CaseIterable, Sendable {
    case formal
    case casual
    case lowercase

    /// The name on the tile. The third was Gokul's choice, 10 Oct 2026.
    var displayName: String {
        switch self {
        case .formal: "Formal"
        case .casual: "Casual"
        case .lowercase: "Retarded"
        }
    }

    var caption: String {
        switch self {
        case .formal: "Capitals and full punctuation"
        case .casual: "Capitals, lighter punctuation"
        case .lowercase: "No capitals, lighter punctuation"
        }
    }

    /// The same sentence in each style, shown on the tile.
    var example: String {
        apply(to: "Hey, are you free for lunch tomorrow? Let's do 12 if that works for you.")
    }

    func apply(to text: String) -> String {
        switch self {
        case .formal:
            return text
        case .casual:
            return Self.lighten(text)
        case .lowercase:
            return Self.lighten(text).lowercased()
        }
    }

    /// Lighter punctuation: commas and semicolons go, and so does a single full stop at
    /// the very end. Question and exclamation marks stay, as do full stops between
    /// sentences, which is where the reader needs them.
    private static func lighten(_ text: String) -> String {
        var result = text
            .replacingOccurrences(of: "[,;]+", with: "", options: .regularExpression)
            .replacingOccurrences(of: "[ \\t]{2,}", with: " ", options: .regularExpression)
        if result.hasSuffix(".") && !result.hasSuffix("..") {
            result.removeLast()
        }
        return result
    }
}
