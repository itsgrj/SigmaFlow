import AppKit
import SwiftUI

// Search on Meetings and Conversations, as picked on 19 Oct 2026
// (docs/mockups/picture-search.html: 01 B, 02 A, 03 B, 04 A, 05 B). The list stays a list of
// recordings; under each one that matched sit up to three of its moments, then "N more". A
// picture shows what is on it, with the typed words lit when they are there. Clicking a
// picture opens it large first, with Go to this moment; clicking a line opens the transcript
// at it.

/// One place a search landed, under its recording in the list.
struct MomentRow: View {
    let moment: SearchMoment
    let folder: URL
    let query: String
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: DS.Space.base) {
                Text(MeetingNaming.clock(moment.start))
                    .font(DS.Font.mono)
                    .foregroundStyle(DS.Color.dim)
                    .frame(width: DS.Material.momentTimeColumn, alignment: .leading)
                if let path = moment.path {
                    MomentThumb(url: folder.appendingPathComponent(path))
                }
                VStack(alignment: .leading, spacing: DS.Space.captionGap) {
                    Eyebrow(label, color: DS.Color.dim)
                    Text(words)
                        .font(DS.Font.caption)
                        .foregroundStyle(DS.Color.inkSecondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(.leading, DS.Space.rowPadX + DS.Material.momentIndent)
            .padding(.trailing, DS.Space.rowPadX)
            .padding(.vertical, DS.Material.momentPadY)
            .background(isHovering ? DS.Color.hoverFill : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .handCursor()
    }

    private var label: String {
        switch moment.kind {
        case .line: moment.speaker ?? "Said"
        case .photo: "Photo"
        case .screenshot: "Screenshot"
        }
    }

    /// A line's words, or what is on a picture: the stretch with the typed words in it, lit,
    /// or, when it matched by meaning, the first thing Gemma said it saw (02 A).
    private var words: AttributedString {
        if moment.kind == .line { return Self.lit(moment.text, query) }
        for text in [moment.read, moment.seen] {
            let flat = Self.flat(text)
            if let range = flat.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) {
                return Self.lit(Self.around(flat, range), query)
            }
        }
        let first = Self.flat(moment.seen).components(separatedBy: ". ").first ?? ""
        return AttributedString(String(first.prefix(DS.Material.momentSnippet)))
    }

    private static func flat(_ text: String) -> String {
        text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: " / ")
    }

    /// Some words either side of the match, never more than the snippet's length.
    private static func around(_ text: String, _ range: Range<String.Index>) -> String {
        let room = max(0, DS.Material.momentSnippet - text.distance(from: range.lowerBound, to: range.upperBound))
        let start = text.index(range.lowerBound, offsetBy: -min(room / 3, text.distance(from: text.startIndex, to: range.lowerBound)))
        let end = text.index(range.upperBound, offsetBy: min(room - room / 3, text.distance(from: range.upperBound, to: text.endIndex)))
        return (start > text.startIndex ? "…" : "") + text[start..<end] + (end < text.endIndex ? "…" : "")
    }

    /// The typed words in ink and underlined wherever they appear, as the transcript does.
    static func lit(_ text: String, _ query: String) -> AttributedString {
        guard !query.isEmpty else { return AttributedString(text) }
        var out = AttributedString()
        var rest = text[...]
        while let match = rest.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) {
            out.append(AttributedString(String(rest[..<match.lowerBound])))
            var word = AttributedString(String(rest[match]))
            word.underlineStyle = Text.LineStyle(pattern: .solid)
            word.foregroundColor = DS.Color.ink
            out.append(word)
            rest = rest[match.upperBound...]
        }
        out.append(AttributedString(String(rest)))
        return out
    }
}

/// A picture in a moment: the list's small copy, never the full photo.
private struct MomentThumb: View {
    let url: URL

    var body: some View {
        Group {
            if let image = ThumbCache.small(url) {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                DS.Color.editorFill
            }
        }
        .frame(width: DS.Material.momentThumbWidth, height: DS.Material.momentThumbHeight)
        .clipped()
        .overlay(Rectangle().strokeBorder(DS.Color.border, lineWidth: DS.Border.hairline))
    }
}

/// "12 more in this conversation": every moment of that recording, in place.
struct MoreMomentsRow: View {
    let count: Int
    let noun: String
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Text("\(count.formatted()) more in this \(noun)")
                .font(DS.Font.caption)
                .foregroundStyle(isHovering ? DS.Color.inkSecondary : DS.Color.dim)
                .padding(.leading, DS.Space.rowPadX + DS.Material.momentIndent + DS.Material.momentTimeColumn + DS.Space.base)
                .padding(.vertical, DS.Material.momentPadY)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .handCursor()
    }
}

/// A picture opened from search, large over the page, with when it was taken and the way to
/// its moment in the transcript (03 B). A click outside or Esc closes it; Return goes.
struct PictureViewer: View {
    let url: URL
    /// "[ 14 Oct ] Wed 10.05 am, 02:32".
    let caption: String
    let onGo: () -> Void
    let onClose: () -> Void

    var body: some View {
        ZStack {
            DS.Color.questionVeil
                .contentShape(Rectangle())
                .onTapGesture(perform: onClose)
            VStack(spacing: DS.Space.base) {
                if let image = ThumbCache.image(url) {
                    // Exactly the picture's shape, so the edge sits on the picture.
                    let scale = min(DS.Material.pictureViewWidth / max(image.size.width, 1),
                                    DS.Material.pictureViewHeight / max(image.size.height, 1))
                    Image(nsImage: image)
                        .resizable()
                        .frame(width: image.size.width * scale, height: image.size.height * scale)
                        .overlay(Rectangle().strokeBorder(DS.Color.border, lineWidth: DS.Border.hairline))
                }
                HStack(spacing: DS.Space.roomy) {
                    Text(caption)
                        .font(DS.Font.caption)
                        .foregroundStyle(DS.Color.inkSecondary)
                    AppButton(title: "Go to this moment", kind: .secondary, trailingIcon: "arrow--right", action: onGo)
                }
            }
            .padding(DS.Material.questionPad)
            .background(DS.Color.questionFill, in: RoundedRectangle(cornerRadius: DS.Radius.card))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.card).strokeBorder(DS.Color.borderStrong, lineWidth: DS.Border.hairline))
            .shadow(color: DS.Shadow.window.color, radius: DS.Shadow.window.radius, x: DS.Shadow.window.x, y: DS.Shadow.window.y)
            Group {
                Button("", action: onGo).keyboardShortcut(.defaultAction)
                Button("", action: onClose).keyboardShortcut(.cancelAction)
            }
            .opacity(0)
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
        }
    }
}
