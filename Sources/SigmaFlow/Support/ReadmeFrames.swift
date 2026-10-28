import AVFoundation
import AppKit
import CoreImage
import SigmaFlowDictionary
import SwiftUI

/// A developer aid: `SigmaFlow --readme-frames DIR [--scenes dictation,notes,…]` plays each
/// README scene through SigmaFlow's real overlay, cards and pages, with made-up words and a
/// made-up SigmaFlow folder, draws every frame, writes DIR/<scene>.png as an animated PNG
/// and quits (docs/mockups/readme-showcase.html; Gokul, 28 Oct 2026: the pictures must be
/// the app).
///
/// The panels are SigmaFlow's own, on screen for the length of a scene, driven by staged
/// state (the `stageForPicture` methods) instead of a microphone. The pages are the real
/// main window, reading a made-up SigmaFlow folder built in the temporary folder; the real
/// one, its bookmark and the run log are never read or written. Each frame draws the
/// SwiftUI content with `cacheDisplay`, which needs no screen-recording grant. The window
/// server's blur is not in that drawing, so the glass is rebuilt from the same tokens: the
/// desktop blurred behind the card, `hudGlass` over it, the `borderStrong` edge, the `hud`
/// shadow. The desktop, the other apps' windows and the key are stand-ins; they are not
/// SigmaFlow, so their sizes live in `Stage`, not `DS`.
@MainActor
enum ReadmeFrames {
    static func runIfRequested(controller: DictationController) -> Bool {
        let args = CommandLine.arguments
        // `--cleanup-check "TEXT" …`: what each cleanup makes of what was said, so the
        // README's "What you say" table shows only what SigmaFlow really writes.
        if let index = args.firstIndex(of: "--cleanup-check") {
            NSApp.setActivationPolicy(.accessory)
            Task {
                for said in args.dropFirst(index + 1) {
                    print("said:  \(said)")
                    print("rules: \(await RuleBasedFormatter().format(said))")
                    print("smart: \(await FoundationModelFormatter().format(said))\n")
                }
                NSApp.terminate(nil)
            }
            return true
        }
        guard let index = args.firstIndex(of: "--readme-frames"), index + 1 < args.count else { return false }
        NSApp.setActivationPolicy(.accessory)
        let directory = URL(fileURLWithPath: args[index + 1], isDirectory: true)
        var scenes = ReadmeScene.allCases
        if let flag = args.firstIndex(of: "--scenes"), flag + 1 < args.count {
            scenes = args[flag + 1].split(separator: ",").compactMap { ReadmeScene(rawValue: String($0)) }
        }
        Task { @MainActor in
            // The main window opens with any launch; it has no part in the pictures.
            try? await Task.sleep(for: .seconds(1))
            for window in NSApp.windows where !(window is NSPanel) { window.orderOut(nil) }
            if Settings.shared.overlayMode != .live {
                print("readme frames: the overlay is set to hide the words, so they will not show")
            }
            // Pages open on the page and tab these say; both are put back at the end.
            let settings = Settings.shared
            let lastPage = settings.lastPage, openTabs = settings.openTabs
            do {
                let root = try MadeUpFolder.build()
                MeetingLibrary.shared.stageForPicture(root: root)
                MeetingLibrary.conversations.reload()
                RunStore.shared.reload()
                TypedWords.shared.stagedToday = MadeUpFolder.typedToday
                PathBar.stagedHome = MadeUpFolder.home
            } catch {
                print("readme frames: the made-up folder failed: \(error)")
                return NSApp.terminate(nil)
            }
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for scene in scenes {
                let started = Date()
                do {
                    let take = Take()
                    try await take.record { try await scene.play(on: take, controller: controller) }
                    let file = directory.appendingPathComponent("\(scene.rawValue).png")
                    try take.movie.write(to: file)
                    let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0
                    print("readme frames: \(file.lastPathComponent), \(take.frames) frames, \(size / 1024) KB, \(Int(Date().timeIntervalSince(started))) s")
                } catch {
                    print("readme frames: \(scene.rawValue) failed: \(error)")
                }
            }
            settings.lastPage = lastPage
            settings.openTabs = openTabs
            TypedWords.shared.stagedToday = nil
            NSApp.terminate(nil)
        }
        return true
    }
}

// MARK: - The stand-in desktop

/// The made-up Mac a scene sits on, at real size: 720 by 450 points of a desktop, the
/// overlay above the Dock, drawn into 960 by 600 pixels so SigmaFlow fills the picture.
private enum Stage {
    static let size = CGSize(width: 720, height: 450)
    static let pixels = CGSize(width: 960, height: 600)
    static var scale: CGFloat { pixels.width / size.width }
    static let menuBar: CGFloat = 24
    static let dockHeight: CGFloat = 56
    static let dockBottom: CGFloat = 6
    static let dockIcons = 7
    static let dockIcon: CGFloat = 42
    /// The overlay's bottom edge sits this far above the Dock.
    static let hudAboveDock: CGFloat = 16
    static let notesHeight: CGFloat = 330
    /// The main window a little over its smallest, where the page fills the picture and a
    /// recording's whole name still fits on its row.
    static let pageWindow = CGSize(width: 1080, height: 675)
    static let windowRadius: CGFloat = 10
    static let frameInterval: Duration = .milliseconds(66)
    static var dockTop: CGFloat { size.height - dockBottom - dockHeight }
    /// The overlay, the learned-word card and the call card: centred above the Dock.
    static func aboveDock(_ card: CGSize) -> CGPoint {
        CGPoint(x: (size.width - card.width) / 2, y: dockTop - hudAboveDock - card.height)
    }
}

/// What the stand-in desktop shows at a moment. A change draws it again; otherwise the
/// last drawing, and its blurred copy behind the glass, are reused.
private struct Props: Equatable {
    enum Window: Equatable {
        case none
        /// A code editor with an agent's box, holding what landed.
        case agent(String)
        /// A chat with a prospect, and the reply box.
        case chat(reply: String)
        /// A plain document: its title, its words, and the words shown selected.
        case document(title: String, text: String, selected: String?)
        /// A video call.
        case call
        /// A slide deck, for a meeting in a room.
        case slides
        /// Finder in the SigmaFlow folder: its rows, the one selected, and the file open beside it.
        case files(rows: [String], selected: Int?, text: String?)
        /// Claude Desktop with SigmaFlow added: the question, the tool it used, the answer so far.
        case claude(tool: String?, answer: String)
    }
    var app = "Finder"
    var window = Window.none
    /// The key held, shown in the corner; nil shows none.
    var key: String?
    var keyDown = false

    static let chatFrame = CGRect(x: 24, y: 40, width: 672, height: 212)
}

private struct StageView: View {
    let props: Props

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let image = BackgroundImage.image {
                Image(nsImage: image).resizable().scaledToFill()
                    .frame(width: Stage.size.width, height: Stage.size.height).clipped()
            }
            menuBar
            window
            dock
            if let key = props.key { keyCap(key) }
        }
        .frame(width: Stage.size.width, height: Stage.size.height, alignment: .topLeading)
        .environment(\.colorScheme, .dark)
    }

    private var menuBar: some View {
        HStack(spacing: 18) {
            Text(props.app).fontWeight(.semibold)
            Text("File"); Text("Edit"); Text("View")
            Spacer()
            Text("Thu 22 Oct  2:30 PM")
        }
        .font(.system(size: 13))
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .frame(width: Stage.size.width, height: Stage.menuBar)
        .background(.black.opacity(0.35))
    }

    private var dock: some View {
        HStack(spacing: 8) {
            ForEach(0..<Stage.dockIcons, id: \.self) { index in
                RoundedRectangle(cornerRadius: 10)
                    .fill(.white.opacity(index == 3 ? 0.42 : 0.26))
                    .frame(width: Stage.dockIcon, height: Stage.dockIcon)
            }
        }
        .padding(7)
        .background(RoundedRectangle(cornerRadius: 16).fill(.black.opacity(0.35)))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.white.opacity(0.14)))
        .frame(width: Stage.size.width)
        .offset(y: Stage.dockTop)
    }

    private func keyCap(_ key: String) -> some View {
        Text(key.uppercased())
            .font(DS.Font.eyebrow)
            .tracking(DS.Font.eyebrowTracking)
            .foregroundStyle(props.keyDown ? .black : DS.Color.inkSecondary)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(props.keyDown ? DS.Color.ink : .black.opacity(0.6))
            .overlay(Rectangle().strokeBorder(props.keyDown ? DS.Color.ink : DS.Color.dim))
            .offset(x: 16, y: Stage.dockTop - 46 + (props.keyDown ? 2 : 0))
    }

    @ViewBuilder private var window: some View {
        switch props.window {
        case .none: EmptyView()
        case .agent(let text): AgentWindow(text: text).offset(x: 24, y: 40)
        case .chat(let reply): ChatWindow(reply: reply).offset(x: Props.chatFrame.minX, y: Props.chatFrame.minY)
        case .document(let title, let text, let selected): DocumentWindow(title: title, text: text, selected: selected).offset(x: 60, y: 44)
        case .call: CallWindow().offset(x: 24, y: 36)
        case .slides: SlidesWindow().offset(x: 16, y: 60)
        case .files(let rows, let selected, let text):
            FinderWindow(rows: rows, selected: selected).offset(x: 16, y: 38)
            if let text { FileWindow(text: text).offset(x: 268, y: 104) }
        case .claude(let tool, let answer): ClaudeWindow(tool: tool, answer: answer).offset(x: 60, y: 36)
        }
    }
}

/// Another app's window, drawn plainly so it never competes with SigmaFlow's own.
private struct StandInWindow<Content: View>: View {
    let title: String
    let size: CGSize
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                ForEach(0..<3, id: \.self) { _ in Circle().fill(.white.opacity(0.22)).frame(width: 12, height: 12) }
                Spacer()
                Text(title).font(.system(size: 13)).foregroundStyle(.white.opacity(0.6))
                Spacer()
                Color.clear.frame(width: 52, height: 1)
            }
            .padding(.horizontal, 14)
            .frame(height: 34)
            Divider().overlay(.white.opacity(0.08))
            content.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(width: size.width, height: size.height)
        .background(Color(white: 0.115))
        .clipShape(RoundedRectangle(cornerRadius: Stage.windowRadius))
        .overlay(RoundedRectangle(cornerRadius: Stage.windowRadius).strokeBorder(.white.opacity(0.12)))
        .shadow(color: .black.opacity(0.5), radius: 24, y: 14)
    }
}

/// Words in a box with the cursor after the last one, wherever they wrap.
private struct TypedText: View {
    let text: String
    var selected: String? = nil
    var size: CGFloat = 15

    var body: some View {
        styled.font(.system(size: size)).lineSpacing(3)
    }

    private var styled: Text {
        let cursor = Text("\u{258F}").fontWeight(.light).foregroundStyle(.white)
        guard let selected, let range = text.range(of: selected) else { return Text(text).foregroundStyle(.white) + cursor }
        let before = Text(String(text[..<range.lowerBound])).foregroundStyle(.white)
        let picked = Text(AttributedString(String(text[range]), attributes: AttributeContainer().backgroundColor(.blue.opacity(0.75))))
            .foregroundStyle(.white)
        let after = Text(String(text[range.upperBound...])).foregroundStyle(.white)
        return before + picked + after
    }
}

private struct AgentWindow: View {
    let text: String
    private static let code = [
        "export async function signup(req: Request) {",
        "  const { email } = await req.json()",
        "  const user = await db.users.create({ email })",
        "  await sendWelcome(user)",
        "  return Response.json(user)",
        "}",
    ]

    var body: some View {
        StandInWindow(title: "signup.ts", size: CGSize(width: 672, height: 228)) {
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(Self.code, id: \.self) { Text($0) }
                }
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.white.opacity(0.5))
                .padding(16)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                Divider().overlay(.white.opacity(0.08))
                VStack(alignment: .leading) {
                    Text("Agent").font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.6))
                    Spacer()
                    TypedText(text: text, size: 14)
                        .padding(10)
                        .frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading)
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.white.opacity(0.18)))
                }
                .padding(12)
                .frame(width: 290)
            }
        }
    }
}

private struct ChatWindow: View {
    let reply: String

    var body: some View {
        StandInWindow(title: "Maya Chen, Northwind", size: Props.chatFrame.size) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 12) {
                    RoundedRectangle(cornerRadius: 6).fill(Color(white: 0.35)).frame(width: 36, height: 36)
                        .overlay(Text("M").font(.system(size: 16, weight: .semibold)).foregroundStyle(.white))
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text("Maya Chen").font(.system(size: 14, weight: .semibold))
                            Text("Northwind  10:42").font(.system(size: 12)).foregroundStyle(.white.opacity(0.45))
                        }
                        Text("Thanks for the demo. Two things before I take it to my boss: pricing for 40 seats, and is SSO included?")
                            .font(.system(size: 14))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .foregroundStyle(.white)
                }
                .padding(16)
                Spacer(minLength: 0)
                Group {
                    if reply.isEmpty {
                        Text("Message Maya Chen").font(.system(size: 14)).foregroundStyle(.white.opacity(0.4))
                    } else {
                        TypedText(text: reply, size: 14)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, minHeight: 62, alignment: .topLeading)
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.white.opacity(0.18)))
                .padding(14)
            }
        }
    }
}

private struct DocumentWindow: View {
    let title: String
    let text: String
    let selected: String?

    var body: some View {
        StandInWindow(title: title, size: CGSize(width: 600, height: 220)) {
            TypedText(text: text, selected: selected, size: 17).padding(22)
        }
    }
}

private struct CallWindow: View {
    var body: some View {
        StandInWindow(title: "Northwind discovery call", size: CGSize(width: 672, height: 300)) {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 6) {
                ForEach(["Maya Chen", "Jon Park", "Amara Diallo", "You"], id: \.self) { name in
                    ZStack(alignment: .bottomLeading) {
                        Color(white: 0.17)
                        Circle().fill(Color(white: 0.3)).frame(width: 52, height: 52)
                            .overlay(Text(String(name.prefix(1))).font(.system(size: 22, weight: .semibold)).foregroundStyle(.white.opacity(0.8)))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        Text(name).font(.system(size: 12)).foregroundStyle(.white.opacity(0.75)).padding(8)
                    }
                    .frame(height: 124)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
            }
            .padding(6)
        }
    }
}

private struct SlidesWindow: View {
    var body: some View {
        StandInWindow(title: "Q1 launch.key", size: CGSize(width: 276, height: 200)) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Three channels,\none launch.").font(.system(size: 20, weight: .semibold))
                Text("Email, webinar, LinkedIn").font(.system(size: 12)).foregroundStyle(.white.opacity(0.5))
            }
            .foregroundStyle(.white.opacity(0.75))
            .padding(22)
        }
    }
}

/// Finder showing a month of meetings. A row that starts with spaces is inside the one above.
private struct FinderWindow: View {
    let rows: [String]
    let selected: Int?

    var body: some View {
        StandInWindow(title: "10 October", size: CGSize(width: 440, height: 300)) {
            VStack(alignment: .leading, spacing: 0) {
                Text("SigmaFlow  ›  Meetings  ›  2026  ›  10 October")
                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.45))
                    .padding(.horizontal, 12).padding(.vertical, 8)
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    let inside = row.hasPrefix(" ")
                    let name = row.trimmingCharacters(in: .whitespaces)
                    HStack(spacing: 7) {
                        Image(systemName: inside ? (name.hasSuffix(".md") ? "doc.text" : "waveform") : "folder.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(inside ? .white.opacity(0.7) : Color(red: 0.45, green: 0.68, blue: 0.95))
                            .frame(width: 16)
                        Text(name).font(.system(size: 12)).lineLimit(1).foregroundStyle(.white.opacity(0.9))
                        Spacer(minLength: 0)
                    }
                    .padding(.leading, inside ? 34 : 12).padding(.trailing, 10)
                    .frame(height: 24)
                    .background(index == selected ? Color.blue.opacity(0.75) : .clear)
                }
            }
        }
    }
}

/// A meeting's .md opened in a plain text editor, as any app would show it.
private struct FileWindow: View {
    let text: String

    var body: some View {
        StandInWindow(title: "Northwind discovery call.md", size: CGSize(width: 440, height: 290)) {
            Text(text)
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(.white.opacity(0.85))
                .lineSpacing(2)
                .padding(14)
        }
    }
}

/// Claude Desktop with SigmaFlow added, answering from a meeting.
private struct ClaudeWindow: View {
    let tool: String?
    let answer: String

    var body: some View {
        StandInWindow(title: "Claude", size: CGSize(width: 600, height: 320)) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Spacer()
                    Text("What did Northwind need before they’d sign?")
                        .font(.system(size: 14)).foregroundStyle(.white)
                        .padding(.horizontal, 14).padding(.vertical, 9)
                        .background(RoundedRectangle(cornerRadius: 14).fill(Color(white: 0.2)))
                }
                if let tool {
                    Label(tool, systemImage: "wrench.and.screwdriver")
                        .font(.system(size: 12)).foregroundStyle(.white.opacity(0.55))
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.white.opacity(0.15)))
                }
                Text(answer).font(.system(size: 14)).foregroundStyle(.white.opacity(0.92)).lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(20)
        }
    }
}

/// A whiteboard for the camera to have taken, drawn rather than borrowed.
private struct WhiteboardView: View {
    let title: String
    let lines: [String]

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color(white: 0.55)
            Rectangle().fill(Color(white: 0.96)).padding(14)
            VStack(alignment: .leading, spacing: 12) {
                Text(title).font(.custom("Marker Felt", size: 40)).foregroundStyle(Color(red: 0.7, green: 0.15, blue: 0.12))
                ForEach(lines, id: \.self) { Text($0).font(.custom("Marker Felt", size: 30)) }
            }
            .foregroundStyle(Color(red: 0.12, green: 0.3, blue: 0.66))
            .padding(40)
        }
        .frame(width: 640, height: 400)
    }

    @MainActor
    func jpeg() -> Data? {
        let renderer = ImageRenderer(content: self)
        renderer.scale = 1
        guard let image = renderer.cgImage else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .jpeg, properties: [.compressionFactor: 0.85])
    }
}

// MARK: - The made-up SigmaFlow folder

/// Meetings, conversations and a year of dictations for the pages to read: a sales team, a
/// launch, and an AI builder's week. Written with SigmaFlow's own writers, so the files are
/// exactly what the app makes.
@MainActor
private enum MadeUpFolder {
    static let typedToday = 66
    /// Stands in for the home folder, so the made-up folder reads as Home › SigmaFlow.
    static var home: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("SigmaFlow README", isDirectory: true)
    }
    static var root: URL { home.appendingPathComponent("SigmaFlow", isDirectory: true) }

    struct Recording {
        let date: Date
        let minutes: Double
        let title: String?
        let app: String?
        let language: MeetingLanguage
        let lines: [MeetingLine]
        var pictures: [String: WhiteboardView] = [:]
    }

    static func date(_ day: Int, _ hour: Int, _ minute: Int) -> Date {
        Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute)) ?? Date()
    }

    static func line(_ seconds: Double, _ speaker: String?, _ text: String) -> MeetingLine {
        MeetingLine(start: seconds, speaker: speaker, text: text)
    }

    static let northwindDate = date(22, 14, 30)

    static var meetings: [Recording] {
        [
            Recording(date: northwindDate, minutes: 32, title: nil, app: "Zoom", language: .english, lines: [
                line(0, "Speaker 1", "Thanks for making time. What’s slowing your team down today?"),
                line(38, "Speaker 2", "Our reps spend about an hour a day writing up calls in the CRM."),
                line(72, "Speaker 3", "And security won’t sign off on anything without SSO."),
                line(100, "Speaker 1", "Both are covered on the Team plan. I’ll send pricing for 40 seats by Friday."),
                line(125, "Speaker 2", "Great. Can you add a two-week pilot to the quote?"),
                line(141, "Speaker 1", "Yes. A pilot with five reps, and we review the numbers together after."),
                line(166, "Speaker 3", "Send the security questionnaire too, and I’ll get it to our CISO."),
                line(190, "Speaker 1", "Will do. I’ll put all three in one email today."),
            ]),
            Recording(date: date(21, 10, 0), minutes: 45, title: "Pipeline review", app: "Google Meet", language: .english, lines: [
                line(0, "Speaker 1", "Let’s start with the deals closing this month."),
                line(21, "Speaker 2", "Northwind is the big one. They want SSO and a pilot."),
            ]),
            Recording(date: date(19, 10, 0), minutes: 26, title: "Campaign plan review", app: nil, language: .tamil, lines: [
                line(0, "Speaker 1", "சரி, இந்த வாரத்துக்குள்ள கேம்பெயின் பிளானை முடிச்சிடலாம்."),
                line(12, "Speaker 2", "Sounds good. I’ll draft the launch emails tonight."),
                line(19, "Speaker 1", "வெபினார் தேதியை தர்ஸ்டேக்குள்ள கன்ஃபர்ம் பண்ணிடுங்க."),
                line(31, "Speaker 2", "Sure, by Thursday."),
                line(36, "Speaker 1", "நல்லது. அப்போ லிங்க்ட்இன் போஸ்ட்டையும் ரெடி பண்ணிடலாம்."),
                line(52, "Speaker 2", "I’ll share the draft in the channel tomorrow morning."),
                line(60, "Speaker 1", "சூப்பர். அடுத்த வாரம் ரிசல்ட்ஸ் பார்க்கலாம்."),
            ]),
            Recording(date: date(16, 11, 30), minutes: 52, title: "Agent evals sync", app: "Zoom", language: .english, lines: [
                line(0, "Speaker 1", "The new eval set caught three regressions in the planner."),
                line(30, "Speaker 2", "Let’s gate the release on it from now on."),
            ]),
        ]
    }

    static var conversations: [Recording] {
        let launch = date(20, 11, 5), pricing = date(14, 16, 0)
        let launchPhoto = photoPath(launch, 189), pricingPhoto = photoPath(pricing, 400)
        return [
            Recording(date: date(23, 9, 10), minutes: 15, title: "Standup", app: nil, language: .english, lines: [
                line(0, "Speaker 1", "Yesterday I shipped the onboarding fix."),
                line(14, "Speaker 2", "Today I’m on the webinar landing page."),
            ]),
            Recording(date: launch, minutes: 48, title: "Q1 launch plan", app: nil, language: .english, lines: [
                line(182, "Speaker 1", "So the launch runs on three channels: email, LinkedIn and the webinar."),
                MeetingLine(start: 189, speaker: "Speaker 2", text: "Email goes out a week before the webinar.",
                            photos: [launchPhoto], descriptions: [launchPhoto: "a whiteboard with the Q1 launch plan in three steps: email, webinar, LinkedIn"]),
                line(195, "Speaker 1", "Take a photo of the whiteboard before we wipe it."),
                line(202, "Speaker 2", "And the LinkedIn post goes out on webinar day."),
            ], pictures: [launchPhoto: WhiteboardView(title: "Q1 LAUNCH", lines: ["1. Email, a week before", "2. Webinar, 14 Jan", "3. LinkedIn post, same day"])]),
            Recording(date: pricing, minutes: 31, title: "Pricing page workshop", app: nil, language: .english, lines: [
                line(380, "Speaker 1", "Three plans, and Team is the one we point to."),
                MeetingLine(start: 400, speaker: "Speaker 2", text: "SSO only on Team and up.",
                            photos: [pricingPhoto], descriptions: [pricingPhoto: "a whiteboard listing three pricing plans: Free, Team and Enterprise"]),
            ], pictures: [pricingPhoto: WhiteboardView(title: "PRICING PAGE", lines: ["Free: 1 seat", "Team: SSO, 40+ seats", "Enterprise: talk to us"])]),
        ]
    }

    static func photoPath(_ date: Date, _ seconds: Int) -> String {
        "Photos/\(MeetingNaming.stem(for: date)) - \(String(format: "%02d-%02d", seconds / 60, seconds % 60)).jpg"
    }

    /// Builds the folder fresh in the temporary folder and returns it.
    static func build() throws -> URL {
        let fm = FileManager.default
        try? fm.removeItem(at: home)
        for (kind, recordings) in [("Meetings", meetings), ("Conversations", conversations)] {
            for recording in recordings {
                let name = MeetingNaming.name(for: recording.date, duration: recording.minutes * 60, title: recording.title)
                let folder = root.appendingPathComponent(kind, isDirectory: true)
                    .appendingPathComponent(MeetingNaming.yearFolder(for: recording.date), isDirectory: true)
                    .appendingPathComponent(MeetingNaming.monthFolder(for: recording.date), isDirectory: true)
                    .appendingPathComponent(name, isDirectory: true)
                try fm.createDirectory(at: folder.appendingPathComponent("Photos"), withIntermediateDirectories: true)
                for (path, board) in recording.pictures {
                    try board.jpeg()?.write(to: folder.appendingPathComponent(path))
                }
                try silence(to: folder.appendingPathComponent("\(name).m4a"))
                let speakers = Set(recording.lines.compactMap(\.speaker)).count
                let markdown = MeetingMarkdown.render(
                    name: name, date: recording.date, duration: recording.minutes * 60, lines: recording.lines,
                    audioFileName: "\(name).m4a", app: recording.app, language: recording.language, speakers: speakers)
                try markdown.write(to: folder.appendingPathComponent("\(name).md"), atomically: true, encoding: .utf8)
            }
        }
        try fm.createDirectory(at: root.appendingPathComponent("Dictations"), withIntermediateDirectories: true)
        return root
    }

    /// The year of dictations Insights reads, written once the library points here.
    static func writeDictations() {
        let sentences = [
            "Add rate limiting to the signup endpoint, 10 requests a minute per IP, and write a test for it.",
            "Hi Maya, 40 seats puts you on our Team plan, and SSO is included. I’ll send the quote by tomorrow.",
            "Draft three subject lines for the webinar email and keep each under 50 characters.",
            "Refactor the planner so each tool call is logged with its latency and its result.",
            "Quick update: the Northwind pilot starts Monday with five reps.",
            "Summarise the eval results in a table and flag anything that got worse since last week.",
            "Thanks for the call today. Here is what we agreed and what happens next.",
            "Move the launch post to Thursday morning and tag the design team.",
        ]
        var runs: [DictationRun] = []
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        var generator = SystemRandomNumberGenerator()
        for back in stride(from: 330, through: 0, by: -1) {
            guard let day = calendar.date(byAdding: .day, value: -back, to: today) else { continue }
            let weekday = calendar.component(.weekday, from: day)
            let weekend = weekday == 1 || weekday == 7
            // Busier as the year goes on, quieter at weekends; today is a full day.
            let count = back == 0 ? 140 : weekend ? Int.random(in: 0...3, using: &generator)
                : Int.random(in: (40 + (330 - back) / 6)...(70 + (330 - back) / 5), using: &generator)
            for index in 0..<count {
                // Today's run back from now, so the whole day is already in the past.
                let at = back == 0 ? Date().addingTimeInterval(Double(-60 - index * 90))
                    : day.addingTimeInterval(Double(9 * 3600 + index * 600))
                guard calendar.isDate(at, inSameDayAs: day) else { continue }
                let text = sentences[(back + index) % sentences.count]
                runs.append(DictationRun(date: at, engine: "Parakeet Unified EN", audioSeconds: 6, processSeconds: 0.3, text: text))
            }
        }
        RunLog.record(runs)
    }

    /// A second of silence in the recorder's own format, so a made-up meeting has its audio.
    private static func silence(to url: URL) throws {
        let file = try AVAudioFile(forWriting: url, settings: MeetingRecorder.fileSettings)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 16_000) else { return }
        buffer.frameLength = 16_000
        try file.write(from: buffer)
    }
}

// MARK: - Recording a scene

/// One scene being played: the props, the real panels or page on top, and the frames so far.
@MainActor
private final class Take {
    /// A real SigmaFlow panel, and where its card sits on the desktop.
    struct Card {
        let panel: NSPanel
        let place: (CGSize) -> CGPoint
    }

    /// The real main window, and the part of it the picture shows, in window points.
    struct Page {
        let window: NSWindow
        let crop: CGRect
    }

    var props = Props()
    var cards: [Card] = []
    var page: Page?
    /// Autowrite's spotlight: dims all but this rectangle of the desktop.
    var spotlight: CGRect?
    var spotlightOn = false
    var movie = AnimatedPNG(width: Int(Stage.pixels.width), height: Int(Stage.pixels.height))
    private(set) var frames = 0

    private var spotlightAlpha: CGFloat = 0
    private var drawnProps: Props?
    private var backdrop: CGImage?
    private var blurred: CGImage?
    private let ci = CIContext()

    /// The desktop as it is drawn now, for Autowrite's small picture of the screen.
    var screen: NSImage? { backdrop.map { NSImage(cgImage: $0, size: Stage.size) } }

    func record(_ script: () async throws -> Void) async throws {
        let ticker = Task { @MainActor [self] in
            var pending: (image: CGImage, at: Date)?
            while !Task.isCancelled {
                if let image = self.frame() {
                    let now = Date()
                    if let pending {
                        self.movie.add(pending.image, milliseconds: Int(now.timeIntervalSince(pending.at) * 1000))
                    }
                    pending = (image, now)
                    self.frames += 1
                }
                try? await Task.sleep(for: Stage.frameInterval)
            }
            if let pending { self.movie.add(pending.image, milliseconds: 66) }
        }
        defer { ticker.cancel() }
        try await script()
        ticker.cancel()
        _ = await ticker.value
    }

    /// Draws the props now, so a scene can read `screen` before the first frame.
    func drawProps() {
        guard drawnProps != props else { return }
        drawnProps = props
        let renderer = ImageRenderer(content: StageView(props: props))
        renderer.scale = Stage.scale
        backdrop = renderer.cgImage
        blurred = backdrop.flatMap(blur)
    }

    private func frame() -> CGImage? {
        let width = Int(Stage.pixels.width), height = Int(Stage.pixels.height)
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        context.interpolationQuality = .high
        if let page {
            guard let view = page.window.contentView, let image = snapshot(view, page.crop) else { return nil }
            context.draw(image, in: CGRect(origin: .zero, size: Stage.pixels))
            return context.makeImage()
        }
        drawProps()
        guard let backdrop, let blurred else { return nil }
        // Points from here on, the picture's scale applied once.
        context.scaleBy(x: Stage.scale, y: Stage.scale)
        let whole = CGRect(origin: .zero, size: Stage.size)
        context.draw(backdrop, in: whole)
        drawSpotlight(in: context)
        for card in cards { draw(card, in: context, behind: blurred) }
        return context.makeImage()
    }

    /// The SwiftUI content of a view, at the screen's scale: the part `rect` names, in the
    /// view's own top-left points.
    private func snapshot(_ view: NSView, _ rect: CGRect) -> CGImage? {
        let local = view.isFlipped ? rect : CGRect(x: rect.minX, y: view.bounds.height - rect.maxY, width: rect.width, height: rect.height)
        guard let rep = view.bitmapImageRepForCachingDisplay(in: local) else { return nil }
        view.cacheDisplay(in: local, to: rep)
        return rep.cgImage
    }

    /// The same dim as `Spotlight`, fading as its windows do.
    private func drawSpotlight(in context: CGContext) {
        let step = CGFloat(0.066 / (spotlightOn ? DS.Motion.fadeIn : DS.Motion.fadeOut))
        spotlightAlpha = min(1, max(0, spotlightAlpha + (spotlightOn ? step : -step)))
        guard let hole = spotlight, spotlightAlpha > 0 else { return }
        let flipped = CGRect(x: hole.minX, y: Stage.size.height - hole.maxY, width: hole.width, height: hole.height)
        let path = CGMutablePath()
        path.addRect(CGRect(origin: .zero, size: Stage.size))
        path.addPath(CGPath(roundedRect: flipped, cornerWidth: DS.Material.spotlightCorner, cornerHeight: DS.Material.spotlightCorner, transform: nil))
        context.saveGState()
        context.addPath(path)
        context.setFillColor(NSColor.black.withAlphaComponent(DS.Material.spotlightDim * spotlightAlpha).cgColor)
        context.fillPath(using: .evenOdd)
        context.restoreGState()
    }

    /// The card as the window server would show it: shadow, the desktop blurred behind it,
    /// the tint, the content, the edge. Drawn at the panel's own fade.
    private func draw(_ card: Card, in context: CGContext, behind blurred: CGImage) {
        let panel = card.panel
        guard panel.isVisible, panel.alphaValue > 0.01,
              let glass = panel.contentView, let hosting = glass.subviews.last else { return }
        let size = glass.bounds.size
        let visible = hosting.convert(glass.bounds, from: glass).intersection(hosting.bounds)
        guard size.width > 0, size.height > 0, !visible.isEmpty,
              let rep = hosting.bitmapImageRepForCachingDisplay(in: visible) else { return }
        hosting.cacheDisplay(in: visible, to: rep)
        guard let content = rep.cgImage else { return }

        let origin = card.place(size)
        // Core Graphics counts from the bottom.
        let rect = CGRect(x: origin.x, y: Stage.size.height - origin.y - size.height, width: size.width, height: size.height)
        let radius = DS.Radius.hud
        let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        let shadow = DS.Shadow.hud

        context.saveGState()
        context.setAlpha(panel.alphaValue)
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        context.saveGState()
        context.setShadow(offset: CGSize(width: shadow.x, height: -shadow.y), blur: shadow.radius, color: NSColor(shadow.color).cgColor)
        context.addPath(path)
        context.setFillColor(NSColor.black.cgColor)
        context.fillPath()
        context.restoreGState()
        context.saveGState()
        context.addPath(path)
        context.clip()
        context.draw(blurred, in: CGRect(origin: .zero, size: Stage.size))
        context.setFillColor(NSColor(DS.Color.hudGlass).cgColor)
        context.fill(rect)
        context.draw(content, in: rect)
        context.restoreGState()
        context.addPath(CGPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), cornerWidth: radius, cornerHeight: radius, transform: nil))
        context.setStrokeColor(NSColor(DS.Color.borderStrong).cgColor)
        context.setLineWidth(DS.Border.hairline)
        context.strokePath()
        context.endTransparencyLayer()
        context.restoreGState()
    }

    private func blur(_ image: CGImage) -> CGImage? {
        let input = CIImage(cgImage: image)
        let output = input.clampedToExtent().applyingGaussianBlur(sigma: DS.Material.blurRadius * Stage.scale).cropped(to: input.extent)
        return ci.createCGImage(output, from: input.extent)
    }
}

// MARK: - The scenes

private enum ReadmeScene: String, CaseIterable {
    case dictation, autowrite, learns, styles, meetings, notes, tamil, search, insights, files, claude

    @MainActor
    func play(on take: Take, controller: DictationController) async throws {
        switch self {
        case .dictation: try await Self.dictation(take, controller)
        case .autowrite: try await Self.autowrite(take, controller)
        case .learns: try await Self.learns(take, controller)
        case .styles: try await Self.styles(take, controller)
        case .meetings: try await Self.meetings(take, controller)
        case .notes: try await Self.notes(take)
        case .tamil: try await Self.tamil(take, controller)
        case .search: try await Self.search(take, controller)
        case .insights: try await Self.insights(take, controller)
        case .files: try await Self.files(take)
        case .claude: try await Self.claude(take)
        }
    }

    private static func wait(_ seconds: Double) async throws {
        try await Task.sleep(for: .milliseconds(Int(seconds * 1000)))
    }

    /// A voice's level, moving the way speech does: louder on words, dipping between.
    private static func speechLevel(_ tick: Int) -> Float {
        Float(0.35 + 0.3 * abs(sin(Double(tick) * 0.9)) + Double.random(in: 0...0.25))
    }

    @MainActor
    private static func overlay(_ take: Take, _ controller: DictationController) -> HUDPanel {
        let hud = HUDPanel(controller: controller)
        take.cards = [Take.Card(panel: hud, place: Stage.aboveDock)]
        return hud
    }

    /// Talks into the overlay a word about every third of a second, a little faster than
    /// the flow shows them, so it catches up after the key comes up, as it does.
    @MainActor
    private static func speak(
        _ sentence: String, into controller: DictationController, writing: Bool = false, screen: NSImage? = nil
    ) async throws -> String {
        var said: [String] = []
        var tick = 0
        for word in sentence.split(separator: " ").map(String.init) {
            said.append(word)
            for _ in 0..<4 {
                controller.stageForPicture(.listening, transcript: said.joined(separator: " "), level: speechLevel(tick),
                                           isWriting: writing, screen: screen)
                tick += 1
                try await wait(0.08)
            }
        }
        for _ in 0..<6 {
            controller.stageForPicture(.listening, transcript: said.joined(separator: " "), level: 0.05, isWriting: writing, screen: screen)
            try await wait(0.08)
        }
        return said.joined(separator: " ")
    }

    /// What a fresh install writes from what was heard: the rule cleanup, then the
    /// dictionary. The pictures show this, never a sentence written by hand.
    @MainActor
    private static func written(_ heard: String, dictionary: [DictionaryEntry] = []) async -> String {
        let cleaned = await RuleBasedFormatter().format(heard)
        return DictionaryCorrector(entries: dictionary).apply(to: cleaned).text
    }

    /// Hold the key, say it, let go: the overlay through Processing, then the words land.
    @MainActor
    private static func dictate(
        _ sentence: String, _ take: Take, _ controller: DictationController, hud: HUDPanel,
        dictionary: [DictionaryEntry] = [], landing: (String) -> Void
    ) async throws {
        take.props.keyDown = true
        controller.stageForPicture(.starting, transcript: "", level: 0)
        hud.present()
        try await wait(0.25)
        let said = try await speak(sentence, into: controller)
        take.props.keyDown = false
        controller.stageForPicture(.finishing, transcript: said, level: 0)
        let text = await written(said, dictionary: dictionary)
        try await wait(0.9)
        controller.stageForPicture(.idle, transcript: "", level: 0)
        hud.dismiss()
        try await wait(0.15)
        landing(text)
    }

    /// Hold Right ⌘, talk to a coding agent with an um and an uh in it, let go.
    @MainActor
    private static func dictation(_ take: Take, _ controller: DictationController) async throws {
        let hud = overlay(take, controller)
        take.props = Props(app: "Code", window: .agent(""), key: "Right ⌘")
        try await wait(0.9)
        // As the speech model hands it over: its own capitals and commas, the fillers still in.
        try await dictate(
            "Um, add rate limiting to the signup endpoint, uh, ten requests a minute per IP, and write a test for it.",
            take, controller, hud: hud) { take.props.window = .agent($0) }
        try await wait(3.2)
    }

    /// Click in the reply, hold Right ⌥, say what to answer; SigmaFlow reads the screen and writes it.
    @MainActor
    private static func autowrite(_ take: Take, _ controller: DictationController) async throws {
        let hud = overlay(take, controller)
        take.props = Props(app: "Slack", window: .chat(reply: ""), key: "Right ⌥")
        take.spotlight = Props.chatFrame
        try await wait(0.9)
        take.props.keyDown = true
        take.drawProps()
        let screen = take.screen
        controller.stageForPicture(.starting, transcript: "", level: 0, isWriting: true, screen: screen)
        take.spotlightOn = true
        hud.present()
        try await wait(0.3)
        let ask = try await speak("tell maya forty seats is the team plan, SSO is included, quote by tomorrow",
                                  into: controller, writing: true, screen: screen)
        take.props.keyDown = false
        let reply = "Hi Maya, glad the demo landed. 40 seats puts you on our Team plan, and SSO is included. I’ll send the full quote by tomorrow."
        var written: [String] = []
        for word in reply.split(separator: " ").map(String.init) {
            written.append(word)
            controller.stageForPicture(.finishing, transcript: ask, level: 0,
                                       writing: .init(phase: .writing, ask: ask, text: written.joined(separator: " ")), screen: screen)
            try await wait(0.07)
        }
        try await wait(0.6)
        controller.stageForPicture(.idle, transcript: "", level: 0)
        hud.dismiss()
        take.spotlightOn = false
        try await wait(0.15)
        take.props.window = .chat(reply: reply)
        try await wait(3.2)
    }

    /// Fix a name once, the card adds it, and the next dictation spells it right.
    @MainActor
    private static func learns(_ take: Take, _ controller: DictationController) async throws {
        let title = "Launch checklist"
        let first = "Deploy the preview to Ver sell before the demo."
        take.props = Props(app: "Notes", window: .document(title: title, text: first, selected: nil))
        try await wait(1.0)
        take.props.window = .document(title: title, text: first, selected: "Ver sell")
        try await wait(0.7)
        var typed = ""
        for letter in "Vercel" {
            typed.append(letter)
            take.props.window = .document(title: title, text: first.replacingOccurrences(of: "Ver sell", with: typed), selected: nil)
            try await wait(0.11)
        }
        let fixed = "Deploy the preview to Vercel before the demo."
        try await wait(0.6)

        final class Holder { var panel: CorrectionNoticePanel? }
        let holder = Holder()
        let card = CorrectionNoticePanel(
            spoken: "Ver sell", written: "Vercel", window: DS.Motion.noticeWindow,
            onExpire: { holder.panel?.showAdded() }, onUndo: {}, onDecline: { holder.panel?.dismiss() })
        holder.panel = card
        take.cards = [Take.Card(panel: card, place: Stage.aboveDock)]
        card.present()
        try await wait(DS.Motion.noticeWindow + DS.Motion.addedHold + 0.6)

        let hud = overlay(take, controller)
        take.props.key = "Right ⌘"
        try await wait(0.4)
        let learned = DictionaryEntry(kind: .correction, write: "Vercel", hear: "Ver sell")
        try await dictate("The Ver sell build is green.", take, controller, hud: hud, dictionary: [learned]) {
            take.props.window = .document(title: title, text: fixed + "\n" + $0, selected: nil)
        }
        try await wait(3.0)
    }

    /// Select a rough draft, press ⌥2, and the style rewrites it in place.
    @MainActor
    private static func styles(_ take: Take, _ controller: DictationController) async throws {
        let hud = overlay(take, controller)
        let title = "Launch post, draft"
        let rough = "so we shipped the new onboarding today. signups are up 18% in the first week which is wild. huge thanks to the design team"
        take.props = Props(app: "Notes", window: .document(title: title, text: rough, selected: nil), key: "⌥ 2")
        try await wait(1.1)
        take.props.window = .document(title: title, text: rough, selected: rough)
        try await wait(0.7)
        take.props.keyDown = true
        try await wait(0.25)
        take.props.keyDown = false
        controller.stageForPicture(.idle, transcript: "", level: 0, style: .init(name: "Launch post", message: "Rewriting"))
        hud.present()
        try await wait(1.8)
        controller.stageForPicture(.idle, transcript: "", level: 0)
        hud.dismiss()
        take.props.window = .document(
            title: title,
            text: "We shipped a new onboarding this week, and signups are up 18% in the first seven days. Huge thanks to our design team for making it happen.",
            selected: nil)
        try await wait(3.4)
    }

    /// The main window on a page, the part `crop` names, reading the made-up folder.
    @MainActor
    private static func showPage(_ take: Take, controller: DictationController, crop: CGRect) -> NSWindow {
        let size = Stage.pageWindow
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: page(controller, size))
        window.center()
        window.orderFrontRegardless()
        take.page = Take.Page(window: window, crop: crop)
        return window
    }

    /// Draws the page again from the staged settings: a new page view reads them on init.
    @MainActor
    private static func redraw(_ window: NSWindow, _ controller: DictationController) {
        window.contentView = NSHostingView(rootView: page(controller, window.frame.size))
    }

    @MainActor
    private static func page(_ controller: DictationController, _ size: CGSize) -> some View {
        MainWindow(controller: controller)
            .frame(width: size.width, height: size.height)
            .environment(\.colorScheme, .dark)
    }

    /// The whole window, sidebar too, trimmed to the picture's shape.
    private static let pageCrop = CGRect(x: 0, y: 0, width: Stage.pageWindow.width, height: Stage.pageWindow.width * Stage.pixels.height / Stage.pixels.width)

    /// A call starts, SigmaFlow asks, the meeting is recorded, and it is written down and named.
    @MainActor
    private static func meetings(_ take: Take, _ controller: DictationController) async throws {
        take.props = Props(app: "Zoom", window: .call)
        let model = CallPromptModel()
        let card = CallPromptPanel(model: model)
        take.cards = [Take.Card(panel: card, place: Stage.aboveDock)]
        try await wait(0.8)
        card.present()
        try await wait(2.4)
        model.stage = .recording
        card.reanchor()
        try await wait(DS.Motion.callConfirmHold)
        card.dismiss()
        try await wait(0.5)

        let library = MeetingLibrary.shared
        guard let meeting = library.meetings.first(where: { $0.date == MadeUpFolder.northwindDate }) else { return }
        Settings.shared.lastPage = MainWindow.Section.meetings.rawValue
        MeetingsPage.staged = (meeting.id, "")
        let window = showPage(take, controller: controller, crop: pageCrop)
        try await wait(2.0)
        // The title arrives, as the on-device model's would.
        let renamed = library.rename(meeting, title: "Northwind discovery call")
        MeetingsPage.staged = (renamed, "")
        redraw(window, controller)
        try await wait(4.0)
        window.orderOut(nil)
        MeetingsPage.staged = nil
    }

    /// A Tamil and English meeting, written down in both.
    @MainActor
    private static func tamil(_ take: Take, _ controller: DictationController) async throws {
        guard let meeting = MeetingLibrary.shared.meetings.first(where: { $0.language == .tamil }) else { return }
        Settings.shared.lastPage = MainWindow.Section.meetings.rawValue
        MeetingsPage.staged = (meeting.id, "")
        let window = showPage(take, controller: controller, crop: pageCrop)
        try await wait(4.0)
        window.orderOut(nil)
        MeetingsPage.staged = nil
    }

    /// Typing "whiteboard" on Conversations finds the photos of whiteboards.
    @MainActor
    private static func search(_ take: Take, _ controller: DictationController) async throws {
        Settings.shared.lastPage = MainWindow.Section.conversations.rawValue
        MeetingsPage.staged = (nil, "")
        let window = showPage(take, controller: controller, crop: pageCrop)
        try await wait(1.2)
        var typed = ""
        for letter in "whiteboard" {
            typed.append(letter)
            MeetingsPage.staged = (nil, typed)
            redraw(window, controller)
            try await wait(0.1)
        }
        try await wait(4.0)
        window.orderOut(nil)
        MeetingsPage.staged = nil
    }

    /// Today's share, the year of squares and the bookcase, from a made-up year.
    @MainActor
    private static func insights(_ take: Take, _ controller: DictationController) async throws {
        MadeUpFolder.writeDictations()
        RunStore.shared.reload()
        Settings.shared.lastPage = MainWindow.Section.transcriptions.rawValue
        Settings.shared.openTabs["transcriptions"] = "insights"
        let window = showPage(take, controller: controller, crop: pageCrop)
        try await wait(4.0)
        window.orderOut(nil)
    }

    /// The SigmaFlow folder in Finder: a month of meetings by date and title, one opened, and
    /// its file read in a plain editor, exactly as SigmaFlow wrote it.
    @MainActor
    private static func files(_ take: Take) async throws {
        let library = MeetingLibrary.shared
        // Named by the meetings scene; on its own, this scene names it the same way.
        if let call = library.meetings.first(where: { $0.date == MadeUpFolder.northwindDate }), !call.name.contains("Northwind") {
            _ = library.rename(call, title: "Northwind discovery call")
        }
        let month = library.meetings.filter { Calendar.current.component(.month, from: $0.date) == 10 }
        guard let open = month.first(where: { $0.name.contains("Northwind") }) ?? month.first else { return }
        var rows = month.map(\.name)
        take.props = Props(app: "Finder", window: .files(rows: rows, selected: nil, text: nil))
        try await wait(1.0)
        let index = rows.firstIndex(of: open.name) ?? 0
        take.props.window = .files(rows: rows, selected: index, text: nil)
        try await wait(0.8)
        rows.insert(contentsOf: ["  \(open.name).md", "  \(open.name).m4a"], at: index + 1)
        take.props.window = .files(rows: rows, selected: index, text: nil)
        try await wait(0.6)
        take.props.window = .files(rows: rows, selected: index + 1, text: nil)
        try await wait(0.6)
        let text = open.transcriptURL.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        let shown = text.components(separatedBy: "\n").prefix(16).joined(separator: "\n")
        take.props.window = .files(rows: rows, selected: index + 1, text: shown)
        try await wait(4.5)
    }

    /// Asking Claude about a meeting: it uses SigmaFlow's tools, reads the transcript, answers.
    @MainActor
    private static func claude(_ take: Take) async throws {
        take.props = Props(app: "Claude", window: .claude(tool: nil, answer: ""))
        try await wait(1.0)
        take.props.window = .claude(tool: "SigmaFlow: search_recordings “Northwind”", answer: "")
        try await wait(1.0)
        take.props.window = .claude(tool: "SigmaFlow: read_recording, Northwind discovery call", answer: "")
        try await wait(0.9)
        let answer = "Two things, from the 22 Oct discovery call: SSO, because their security team won’t sign off without it, and a faster way for reps to write up calls. You said both are on the Team plan and promised pricing for 40 seats by Friday. They also asked for a two-week pilot and the security questionnaire."
        var said: [String] = []
        for word in answer.split(separator: " ").map(String.init) {
            said.append(word)
            take.props.window = .claude(tool: "SigmaFlow: read_recording, Northwind discovery call", answer: said.joined(separator: " "))
            try await wait(0.06)
        }
        try await wait(3.6)
    }

    /// A launch planning session in a room: the card writes it down, a photo of the board.
    @MainActor
    private static func notes(_ take: Take) async throws {
        let session = NotesSession.shared
        let photo = FileManager.default.temporaryDirectory.appendingPathComponent("readme-whiteboard.jpg")
        try WhiteboardView(title: "Q1 LAUNCH", lines: ["1. Email, a week before", "2. Webinar, 14 Jan", "3. LinkedIn post, same day"])
            .jpeg()?.write(to: photo)

        let startClock = 11 * 60 + 2.0
        session.stageForPicture(open: true, lines: [], elapsed: startClock, level: 0, photos: [])
        let panel = NotesPanel(session: session)
        take.cards = [Take.Card(panel: panel) { size in
            CGPoint(x: Stage.size.width - size.width - DS.Material.notesInset, y: Stage.menuBar + DS.Material.notesInset)
        }]
        take.props = Props(app: "Keynote", window: .slides)
        try await wait(0.5)
        panel.present()
        // The card's height is the user's; this one was made shorter to fit the picture.
        panel.setFrame(NSRect(x: panel.frame.minX, y: panel.frame.maxY - Stage.notesHeight,
                              width: panel.frame.width, height: Stage.notesHeight), display: true)

        let script: [(text: String, photo: Bool)] = [
            ("So the launch runs on three channels: email, LinkedIn and the webinar.", false),
            ("Email goes out a week before the webinar.", true),
            ("Take a photo of the whiteboard before we wipe it.", false),
            ("And the LinkedIn post goes out on webinar day.", false),
        ]
        var lines: [NoteLine] = []
        var photos: [NotePhoto] = []
        var clock = startClock
        var tick = 0
        for (index, line) in script.enumerated() {
            let start = clock
            lines.append(NoteLine(id: index, start: start, text: ""))
            var said: [String] = []
            for word in line.text.split(separator: " ").map(String.init) {
                said.append(word)
                lines[index].text = said.joined(separator: " ")
                for _ in 0..<4 {
                    clock += 0.08
                    session.stageForPicture(open: true, lines: lines, elapsed: clock, level: speechLevel(tick), photos: photos)
                    tick += 1
                    try await wait(0.08)
                }
            }
            if line.photo { photos.append(NotePhoto(time: start + 1, url: photo)) }
            // A second of quiet ends a line.
            for _ in 0..<12 {
                clock += 0.08
                session.stageForPicture(open: true, lines: lines, elapsed: clock, level: 0.04, photos: photos)
                try await wait(0.08)
            }
        }
        try await wait(2.0)
        panel.dismiss()
        try await wait(0.5)
        session.stageForPicture(open: false, lines: [], elapsed: 0, level: 0, photos: [])
    }
}
