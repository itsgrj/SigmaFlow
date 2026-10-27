import AppKit
import CoreGraphics
import Foundation
import FoundationModels
import ImageIO
import UniformTypeIdentifiers
import Vision

// Autowrite (docs/mockups/write-a-reply.html, round 2 picks 1A 2A 3B 4A, 23 Oct 2026;
// Figma 8.1 to 8.6 and O6.1 to O6.4). Hold the key, say what you want written, let go:
// SigmaFlow reads the screen the pointer is on, writes it with the engine picked on the
// Styles page, and types it where the cursor is. It reads the screen and nothing else (no
// meetings, conversations or dictations: a transcript can put a line under the wrong
// speaker, and a reply would repeat it as fact). It never presses Return.

/// Which key holds Autowrite open: Right ⌥, unless Right ⌥ is the push-to-talk key, in
/// which case Right ⌘. Power mode is Right ⌥ added to a held Right ⌘, so the key that goes
/// down first decides which one it is.
enum WriteKey {
    static func key(besides pushToTalk: PushToTalkKey) -> PushToTalkKey {
        pushToTalk == .rightOption ? .rightCommand : .rightOption
    }
}

/// What SigmaFlow saw when the key went down: the app in front, the words on the screen,
/// and the screen as a picture for an engine that can look at one.
struct ScreenContext: Sendable {
    var appName: String?
    var text: String
    var jpeg: Data?

    static let empty = ScreenContext(appName: nil, text: "", jpeg: nil)

    /// `--write-check` writes against this message instead of the screen.
    static let sampleSender = "Priya Raman"
    static let sampleMessage = "Could we go through the pricing deck on Thursday at 10? Also, would you add the Q3 numbers to slide 4?"
    static let sample = ScreenContext(
        appName: "Mail",
        text: "From: \(sampleSender)\nSubject: Pricing deck for Thursday\n\n\(sampleMessage)",
        jpeg: nil
    )
    /// `--write-check … --sample chat`: a chat message written like a letter, which is what
    /// got a GRJ sign-off in Cliq (27 Oct 2026).
    static let sampleChat = ScreenContext(
        appName: "Zoho Cliq",
        text: "Meera Nair\nAvailable\n\nHi Sam,\n\nHere's the bot I've been working on: https://example.com/bots/digest\n\nPlease take a look and let me know your thoughts. Its still a work in progress, so there might be a few bugs.\n\n12:50 PM",
        jpeg: nil
    )
}

enum ScreenReader {
    /// A picture's long side when it goes to a model; Anthropic shrinks anything larger.
    private static let pictureLongSide = 1568
    private static let pictureQuality = 0.7

    /// Reads the screen now. Without Screen Recording it asks once and writes from what you
    /// said alone.
    static func read() async -> ScreenContext {
        let appName = await MainActor.run { NSWorkspace.shared.frontmostApplication?.localizedName }
        guard NotesScreen.isAllowed else {
            await MainActor.run { _ = NotesScreen.requestAccess() }
            return ScreenContext(appName: appName, text: "", jpeg: nil)
        }
        guard let image = await NotesScreen.image() else {
            return ScreenContext(appName: appName, text: "", jpeg: nil)
        }
        return ScreenContext(appName: appName, text: words(in: image), jpeg: jpeg(of: image))
    }

    /// The words on the screen, top to bottom, by Apple Vision on this Mac.
    private static func words(in image: CGImage) -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        let handler = VNImageRequestHandler(cgImage: image)
        guard (try? handler.perform([request])) != nil else { return "" }
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }

    private static func jpeg(of image: CGImage) -> Data? {
        let shrink = min(1, Double(pictureLongSide) / Double(max(image.width, image.height)))
        let width = Int(Double(image.width) * shrink), height = Int(Double(image.height) * shrink)
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let small = context.makeImage() else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, small, [kCGImageDestinationLossyCompressionQuality: pictureQuality] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}

// MARK: - The prompt

enum WritePrompt {
    /// How much of the screen's words go in. Apple's model has about 4,000 tokens for the
    /// whole exchange; a cloud model has room for a full screen.
    static let appleScreenLimit = 6_000
    static let cloudScreenLimit = 24_000
    /// Apple's model reads this many words of the custom instructions; what's left of its
    /// window after the screen goes to the reply. A cloud model reads them whole.
    static let appleInstructionWords = 300

    /// The custom instructions from the Autowrite page, set apart and named as standing
    /// ones, so the spoken ask still wins where the two disagree.
    static func system(instructions: String) -> String {
        let trimmed = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return system() }
        return system() + """


        They have written instructions for everything you write for them. Follow them, \
        unless what they say out loud asks for something different:
        <custom_instructions>
        \(trimmed)
        </custom_instructions>
        """
    }

    static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace).count
    }

    /// The text up to the end of its `limit`th word, line breaks kept.
    static func firstWords(_ text: String, limit: Int) -> String {
        var count = 0
        var inWord = false
        for index in text.indices {
            let isSpace = text[index].isWhitespace
            if !isSpace && !inWord {
                count += 1
                if count > limit { return String(text[..<index]) }
            }
            inWord = !isSpace
        }
        return text
    }

    /// No sign-off of its own (27 Oct 2026): it used to sign emails with the Mac account's
    /// first name, which on Gokul's Mac is GRJ, and Apple's model put that under chat
    /// messages written like letters. Whoever wants one asks in the custom instructions.
    static func system() -> String {
        let name = NSFullUserName()
        let who = name.isEmpty ? "the user" : name
        return """
        You write text for \(who) to put into the text box they are typing in. They say out \
        loud what they want written, and you can see what is on their screen.

        - Reply with only the text for the box: no preamble, no quotation marks, no notes.
        - Use what is on the screen to get names, facts and context right, and match the \
        language and tone of what they are replying to. A chat gets a short line; an email \
        gets a greeting.
        - Don't end with a sign-off or their name, unless their custom instructions ask for one.
        - Keep it short unless they ask for more.
        - If they ask a question, answer it briefly, as text for the box.
        - Write as them, in the first person.
        - Never invent facts that are not on the screen or in what they said. If something \
        needed is missing, leave a short [placeholder].
        """
    }

    /// `instructions` are the custom instructions, for Apple's model only: it passed over them
    /// in its instructions and followed them here, beside the ask. A cloud model gets them in
    /// the system prompt instead (`system(instructions:)`).
    static func user(ask: String, context: ScreenContext, screenLimit: Int, instructions: String = "") -> String {
        // The instruction is set apart and named as one, last, then the task: a small model
        // otherwise takes the spoken words for the text to type and hands them straight back.
        var parts: [String] = []
        let app = context.appName.flatMap { $0.isEmpty ? nil : " (in \($0))" } ?? ""
        if !context.text.isEmpty {
            parts.append("On their screen\(app):\n<screen>\n\(context.text.prefix(screenLimit))\n</screen>")
        } else if !app.isEmpty {
            parts.append("They are\(app).")
        }
        let standing = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        if !standing.isEmpty {
            parts.append("Their custom instructions, for everything you write for them (follow them unless what they said asks otherwise):\n<custom_instructions>\n\(standing)\n</custom_instructions>")
        }
        parts.append("Their instruction, said out loud (do not repeat it, carry it out):\n<instruction>\n\(ask)\n</instruction>")
        parts.append("Now write the text they asked for, ready to go in the box, and nothing else.")
        return parts.joined(separator: "\n\n")
    }

    /// Models sometimes wrap the whole reply in quotation marks despite being told not to.
    static func tidy(_ text: String) -> String {
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for (open, close) in [("\"", "\""), ("“", "”")] where result.count > 1 && result.hasPrefix(open) && result.hasSuffix(close) {
            let inner = result.dropFirst(open.count).dropLast(close.count)
            if !inner.contains(open) { result = String(inner).trimmingCharacters(in: .whitespacesAndNewlines) }
        }
        return result
    }

    /// What starts a line a model puts in front of the writing, and what such a line names.
    /// Both must be there, so "Sure, here's my availability:" stays: that one is the writing.
    private static let preambleOpeners = ["sure", "certainly", "of course", "okay", "ok,", "absolutely", "here's", "here’s", "here is"]
    private static let preambleNames = ["text", "reply", "response", "message", "email", "e-mail", "draft", "thank you", "asked for", "requested", "the box"]

    /// The writing without a "Sure, here's the text for the box:" line in front of it: one
    /// short first line, ending in a colon, that talks about the text. Apple's model wrote one
    /// in 20 of 50 replies (27 Oct 2026), and telling it not to only made it worse: naming the
    /// words took it to 46 of 50, and a one-field reply wrote worse text. While the writing
    /// streams (`finished` false), a first line that may still become one shows nothing yet.
    static func withoutPreamble(_ text: String, finished: Bool) -> String {
        let leading = text.drop(while: \.isWhitespace)
        guard let lineEnd = leading.firstIndex(of: "\n") else {
            if finished { return text }
            let start = leading.lowercased()
            return preambleOpeners.contains { start.hasPrefix($0) || $0.hasPrefix(start) } ? "" : text
        }
        let line = leading[..<lineEnd].trimmingCharacters(in: .whitespaces)
        let lower = line.lowercased()
        guard line.hasSuffix(":"), wordCount(line) <= 16,
              preambleOpeners.contains(where: { lower.hasPrefix($0) }),
              preambleNames.contains(where: { lower.contains($0) })
        else { return text }
        return String(leading[lineEnd...].drop(while: \.isWhitespace))
    }
}

// MARK: - Engines

/// Writes the text for an ask, yielding the whole of it so far each time more arrives.
protocol WritingEngine: Sendable {
    func write(ask: String, context: ScreenContext) -> AsyncThrowingStream<String, Error>
}

enum WriteEngines {
    /// The engine on the Styles page and the Autowrite page's custom instructions, both read
    /// each time so a change there applies at once.
    @MainActor
    static func current(_ choice: StyleEngineChoice? = nil) throws -> any WritingEngine {
        let instructions = Settings.shared.autowriteInstructions
        let engine: any WritingEngine
        switch choice ?? Settings.shared.styleEngine {
        case .apple:
            engine = AppleWriter(instructions: WritePrompt.firstWords(instructions, limit: WritePrompt.appleInstructionWords))
        case .claude:
            guard let key = Keychain.anthropicKey, !key.isEmpty else { throw CloudTextError.missingKey(.anthropic) }
            engine = CloudWriter(credentials: CloudCredentials(provider: .anthropic, apiKey: key), instructions: instructions)
        case .openRouter:
            guard let key = Keychain.openRouterKey, !key.isEmpty else { throw CloudTextError.missingKey(.openRouter) }
            engine = CloudWriter(credentials: CloudCredentials(provider: .openRouter, apiKey: key), instructions: instructions)
        }
        return WithoutPreamble(engine: engine)
    }
}

/// Any engine, with `WritePrompt.withoutPreamble` over everything it writes, so a
/// "Sure, here's the text:" line is neither typed nor seen in the overlay.
struct WithoutPreamble: WritingEngine {
    let engine: any WritingEngine

    func write(ask: String, context: ScreenContext) -> AsyncThrowingStream<String, Error> {
        let pieces = engine.write(ask: ask, context: context)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var text = ""
                    for try await sofar in pieces {
                        text = sofar
                        continuation.yield(WritePrompt.withoutPreamble(sofar, finished: false))
                    }
                    continuation.yield(WritePrompt.withoutPreamble(text, finished: true))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

extension StyleEngineChoice {
    /// The engine's name as Autowrite shows it.
    var shortName: String {
        switch self {
        case .apple: "Apple Intelligence"
        case .claude: "Claude"
        case .openRouter: "OpenRouter"
        }
    }

    /// A cloud engine needs its key before it can write.
    var hasKey: Bool {
        switch self {
        case .apple: true
        case .claude: Keychain.hasAnthropicKey
        case .openRouter: Keychain.hasOpenRouterKey
        }
    }
}

/// Apple's model on this Mac. It reads the screen's words only; it cannot look at pictures.
struct AppleWriter: WritingEngine {
    let instructions: String

    func write(ask: String, context: ScreenContext) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard SystemLanguageModel.default.availability == .available else {
                        throw StyleError.appleModelUnavailable(
                            FoundationModelFormatter.unavailableReason ?? "The on-device model is unavailable.")
                    }
                    let session = LanguageModelSession(instructions: WritePrompt.system())
                    let stream = session.streamResponse(
                        to: WritePrompt.user(ask: ask, context: context, screenLimit: WritePrompt.appleScreenLimit, instructions: instructions),
                        options: GenerationOptions(temperature: 0.4, maximumResponseTokens: 800)
                    )
                    for try await snapshot in stream { continuation.yield(snapshot.content) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Claude or OpenRouter, with the user's own key from the Styles page.
struct CloudWriter: WritingEngine {
    let credentials: CloudCredentials
    let instructions: String

    func write(ask: String, context: ScreenContext) -> AsyncThrowingStream<String, Error> {
        let pieces = CloudTextClient.stream(
            system: WritePrompt.system(instructions: instructions),
            user: WritePrompt.user(ask: ask, context: context, screenLimit: WritePrompt.cloudScreenLimit),
            jpeg: credentials.provider == .anthropic ? context.jpeg : nil,
            maxTokens: 1_500,
            temperature: 0.4,
            credentials: credentials,
            timeout: 30
        )
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var text = ""
                    for try await piece in pieces {
                        text += piece
                        continuation.yield(text)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

// MARK: - Checking it from the command line

/// `SigmaFlow --write-check "ASK" [--engine apple|claude|openRouter] [--sample chat]` writes for the ask
/// against a sample message, printing the writing as it arrives, and quits instead
/// of starting the app. Safe to run beside the installed copy.
@MainActor
enum WriteCheck {
    static func runIfRequested() -> Bool {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--write-check"), index + 1 < args.count else { return false }
        let ask = args[index + 1]
        let choice = args.firstIndex(of: "--engine").flatMap { $0 + 1 < args.count ? StyleEngineChoice(rawValue: args[$0 + 1]) : nil }
        let sample = args.firstIndex(of: "--sample").map { $0 + 1 < args.count && args[$0 + 1] == "chat" } == true
            ? ScreenContext.sampleChat : .sample
        Task { @MainActor in
            let started = Date()
            do {
                let engine = try WriteEngines.current(choice)
                var shown = ""
                for try await sofar in engine.write(ask: ask, context: sample) {
                    // Each step is the whole text so far; print only what is new.
                    if sofar.hasPrefix(shown) {
                        FileHandle.standardOutput.write(Data(sofar.dropFirst(shown.count).utf8))
                    } else {
                        FileHandle.standardOutput.write(Data("\n\(sofar)".utf8))
                    }
                    shown = sofar
                }
                print("\n\n[\((choice ?? Settings.shared.styleEngine).shortName), \(String(format: "%.1f", Date().timeIntervalSince(started))) s]")
                exit(0)
            } catch {
                print("error: \(error.localizedDescription)")
                exit(1)
            }
        }
        return true
    }
}
