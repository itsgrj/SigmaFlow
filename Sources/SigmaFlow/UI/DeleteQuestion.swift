import SwiftUI

/// What a delete is about to take, waiting for the user's answer.
struct DeleteQuestion: Identifiable {
    enum Subject {
        case meetings([Meeting])
        /// One photo or screenshot, as the transcript names it ("Photos/…jpg").
        case picture(Meeting, path: String, time: Double, isScreenshot: Bool)
        /// Dictations from the Transcriptions page.
        case transcriptions([DictationRun])
    }

    let id = UUID()
    let subject: Subject
}

/// The small window every delete stops at (docs/mockups/delete-recordings.html round 2, 4).
/// It opens in the middle of the page, never under the pointer, so a second click lands on
/// nothing; Delete stays dim for a moment, so the double-click that opened it can't also
/// answer it. Cancel is the white button, and both Return and Esc press it: Delete needs a
/// click of its own. A click outside cancels too.
struct DeleteQuestionView: View {
    let question: DeleteQuestion
    /// "meeting", "conversation".
    let noun: String
    let onCancel: () -> Void
    let onDelete: () -> Void

    @State private var isArmed = false

    var body: some View {
        ZStack {
            DS.Color.questionVeil
                .contentShape(Rectangle())
                .onTapGesture(perform: onCancel)
            VStack(alignment: .leading, spacing: DS.Space.base) {
                Text(title)
                    .font(DS.Font.rowTitleLarge)
                    .foregroundStyle(DS.Color.ink)
                details
                HStack(spacing: DS.Space.snug) {
                    Spacer(minLength: 0)
                    AppButton(title: "Cancel", kind: .inverted, action: onCancel)
                    AppButton(title: "Delete", kind: .secondary, isEnabled: isArmed, action: onDelete)
                }
                .padding(.top, DS.Space.snug)
            }
            .padding(DS.Material.questionPad)
            .frame(width: DS.Material.questionWidth, alignment: .leading)
            .background(DS.Color.questionFill, in: RoundedRectangle(cornerRadius: DS.Radius.card))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.card).strokeBorder(DS.Color.borderStrong, lineWidth: DS.Border.hairline))
            .shadow(color: DS.Shadow.window.color, radius: DS.Shadow.window.radius, x: DS.Shadow.window.x, y: DS.Shadow.window.y)
            // Return and Esc: both are Cancel.
            Group {
                Button("", action: onCancel).keyboardShortcut(.defaultAction)
                Button("", action: onCancel).keyboardShortcut(.cancelAction)
            }
            .opacity(0)
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
        }
        .task {
            try? await Task.sleep(for: .seconds(DS.Motion.deleteArm))
            isArmed = true
        }
    }

    private var title: String {
        switch question.subject {
        case .meetings(let meetings):
            meetings.count == 1 ? "Delete this \(noun)?" : "Delete \(meetings.count) \(noun)s?"
        case .picture(_, _, _, let isScreenshot):
            isScreenshot ? "Delete this screenshot?" : "Delete this photo?"
        case .transcriptions(let runs):
            runs.count == 1 ? "Delete this \(noun)?" : "Delete \(runs.count.formatted()) \(noun)s?"
        }
    }

    /// The names of what goes, or the picture itself: never a word on how deleting works.
    @ViewBuilder
    private var details: some View {
        switch question.subject {
        case .meetings(let meetings):
            let limit = DS.Material.questionNames
            VStack(alignment: .leading, spacing: DS.Space.tight) {
                ForEach(meetings.prefix(limit), id: \.id) { meeting in
                    Text(meeting.name).lineLimit(1).truncationMode(.middle)
                }
                if meetings.count > limit { Text("and \(meetings.count - limit) more") }
            }
            .font(DS.Font.mono)
            .foregroundStyle(DS.Color.inkSecondary)
        case .transcriptions(let runs):
            let limit = DS.Material.questionNames
            VStack(alignment: .leading, spacing: DS.Space.tight) {
                ForEach(runs.prefix(limit), id: \.id) { run in
                    Text(run.text).lineLimit(1).truncationMode(.tail)
                }
                if runs.count > limit { Text("and \((runs.count - limit).formatted()) more") }
            }
            .font(DS.Font.mono)
            .foregroundStyle(DS.Color.inkSecondary)
        case .picture(let meeting, let path, let time, _):
            VStack(alignment: .leading, spacing: DS.Space.snug) {
                Group {
                    if let image = ThumbCache.image(meeting.folder.appendingPathComponent(path)) {
                        Image(nsImage: image).resizable().scaledToFill()
                    } else {
                        DS.Color.controlFill
                    }
                }
                .frame(width: DS.Material.questionThumbWidth, height: DS.Material.questionThumbHeight)
                .clipShape(RoundedRectangle(cornerRadius: DS.Radius.chip))
                .overlay(RoundedRectangle(cornerRadius: DS.Radius.chip).strokeBorder(DS.Color.border, lineWidth: DS.Border.hairline))
                Text("[\(MeetingNaming.clock(time))]")
                    .font(DS.Font.mono)
                    .foregroundStyle(DS.Color.inkSecondary)
            }
        }
    }
}
