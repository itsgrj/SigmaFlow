import SwiftUI

// Ask Claude, from Meetings and Conversations (docs/mockups/ask-claude.html, picked 23 Oct
// 2026: 1B 2A 3C 4C; Figma 3.21 to 3.24, 4.23, 4.24). Two places, two jobs (Gokul): the list
// page adds SigmaFlow to Claude, once, for every recording; a transcript asks about that one.

/// Along the foot of the list page until Claude Desktop has SigmaFlow, so Record meeting stays
/// the only button at the top. The whole bar is one button; it goes for good once Claude has
/// SigmaFlow (2A).
struct ClaudeAskBar: View {
    /// "meeting", "conversation".
    let noun: String
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: DS.Space.base) {
                CarbonIcon(name: "anthropic", size: DS.Control.iconSize)
                    .foregroundStyle(DS.Color.inkSecondary)
                Text("Ask Claude about your \(noun)s")
                    .font(DS.Font.body)
                    .foregroundStyle(isHovering ? DS.Color.ink : DS.Color.inkSecondary)
                Spacer(minLength: DS.Space.base)
                Text("Once, for every \(noun)")
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.dim)
                // Drawn as a compact secondary button; the bar around it is the button.
                Text("Add to Claude")
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.ink)
                    .padding(.horizontal, DS.Control.padXCompact)
                    .frame(height: DS.Control.heightCompact)
                    .overlay(
                        RoundedRectangle(cornerRadius: DS.Radius.control)
                            .strokeBorder(isHovering ? DS.Color.borderStrong : DS.Color.border, lineWidth: DS.Border.hairline))
            }
            .padding(.leading, DS.Space.rowPadX)
            .padding(.trailing, DS.Space.snug)
            .frame(height: DS.Material.askBarHeight)
            .background(DS.Color.glass, in: RoundedRectangle(cornerRadius: DS.Radius.card))
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.card)
                    .strokeBorder(DS.Color.borderStrong, lineWidth: DS.Border.hairline))
            .contentShape(RoundedRectangle(cornerRadius: DS.Radius.card))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .handCursor()
    }
}

/// Where Ask Claude sits, so the questions open under it, above everything on the page.
struct AskClaudeAnchor: PreferenceKey {
    static let defaultValue: Anchor<CGRect>? = nil
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = value ?? nextValue()
    }
}

/// The questions under Ask Claude: three about this recording, a fourth when it has pictures,
/// and Ask your own. Picking one copies it with the recording's name and opens a new chat in
/// Claude, where it is pasted (4C).
struct AskClaudeQuestions: View {
    let meeting: Meeting
    /// "meeting", "conversation".
    let noun: String
    let onPick: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: DS.Space.tight) {
                Eyebrow("Ask about this \(noun)")
                Text("Pick one. SigmaFlow copies it and opens Claude for you to paste.")
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, DS.Space.snug)
            .padding(.bottom, DS.Space.snug)
            ForEach(questions, id: \.self) { question in
                QuestionRow(text: question, isOwn: false) { onPick(lead + question) }
            }
            QuestionRow(text: "Ask your own", isOwn: true) { onPick(lead) }
        }
        .padding(.top, DS.Space.base)
        .padding([.horizontal, .bottom], DS.Space.snug)
        .frame(width: DS.Material.askQuestionsWidth, alignment: .leading)
        .background(DS.Color.questionFill, in: RoundedRectangle(cornerRadius: DS.Radius.card))
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.card)
                .strokeBorder(DS.Color.borderStrong, lineWidth: DS.Border.hairline))
        .shadow(color: DS.Shadow.hud.color, radius: DS.Shadow.hud.radius, x: DS.Shadow.hud.x, y: DS.Shadow.hud.y)
    }

    /// Tells Claude which recording: its folder name, exactly as SigmaFlow's helper lists it.
    private var lead: String { "About my SigmaFlow \(noun) \(meeting.name): " }

    private var questions: [String] {
        var out = ["What did we decide?"]
        let speakers = meeting.speakerLabels
        if speakers.count > 1 { out.append("What did \(speakers[1]) say they would do?") }
        out.append("Write a follow-up email to everyone")
        if meeting.lines.contains(where: { !$0.photos.isEmpty || !$0.screens.isEmpty }) {
            out.append("What was in the pictures?")
        }
        return out
    }
}

private struct QuestionRow: View {
    let text: String
    let isOwn: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: DS.Space.snug) {
                Text(text)
                    .font(DS.Font.body)
                    .foregroundStyle(isOwn ? DS.Color.inkSecondary : DS.Color.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
                CarbonIcon(name: "copy", size: DS.Control.iconSizeSmall)
                    .foregroundStyle(DS.Color.dim)
            }
            .padding(.horizontal, DS.Space.snug)
            .padding(.vertical, DS.Space.snug)
            .background(isHovering ? DS.Color.hoverFill : Color.clear, in: RoundedRectangle(cornerRadius: DS.Radius.chip))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .handCursor()
    }
}
