import AppKit
import SwiftUI

/// The app's main window, to the Figma file "SigmaFlow 1.0": a sidebar on the rail with
/// the wordmark and seven pages, and a content column on the painting. Recording happens
/// through the hotkey, so the window's job is finding what you said and changing how the
/// app behaves. The page that was open last time opens again.
struct MainWindow: View {
    @Bindable var controller: DictationController

    @State private var section: Section
    @State private var settings = Settings.shared
    @State private var meetings = MeetingSession.shared
    @Environment(\.isSnapshotting) private var isSnapshotting

    init(controller: DictationController) {
        self.controller = controller
        _section = State(initialValue: Section(rawValue: Settings.shared.lastPage) ?? .transcriptions)
    }

    /// Sidebar order as reviewed on 10 Oct 2026. Meetings came back on 13 Oct 2026, after
    /// Transcriptions, in its simple form (docs/mockups/meetings-simple.html).
    enum Section: String, CaseIterable, Identifiable {
        case models
        case transcriptions
        case meetings
        case conversations
        case dictionary
        case snippets
        case styles
        /// Autowrite, after Styles (docs/mockups/write-a-reply.html rounds 2 and 3, 23 and 26 Oct 2026).
        case autowrite
        case settings

        var id: String { rawValue }

        var title: String {
            switch self {
            case .models: "Models"
            case .transcriptions: "Transcriptions"
            case .meetings: "Meetings"
            case .conversations: "Conversations"
            case .dictionary: "Dictionary"
            case .snippets: "Snippets"
            case .styles: "Styles"
            case .autowrite: "Autowrite"
            case .settings: "Settings"
            }
        }

        /// IBM Carbon icon names, drawn from Resources/Icons.
        var icon: String {
            switch self {
            case .models: "chip"
            case .transcriptions: "text--align--left"
            // The same microphone as Record meeting on the page, so the two read as one thing.
            case .meetings: "microphone"
            // Live notes' home (docs/mockups/notes-home.html, 1B 2C).
            case .conversations: "notebook"
            case .dictionary: "book"
            case .snippets: "text--short-paragraph"
            case .styles: "magic-wand"
            case .autowrite: "edit"
            case .settings: "settings"
            }
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            sidebar

            // The page gets exactly the width left beside the sidebar and no more. A
            // `.frame(maxWidth: .infinity)` grows to a child that is wider than its offer, so
            // a page that cannot fit the window would widen the whole row and centre it,
            // shoving the sidebar off the left edge. Inside a GeometryReader the row stays
            // the window's width and a page that is too wide runs off the right instead.
            GeometryReader { geo in
                Group {
                    switch section {
                    case .models: ModelsPage()
                    case .transcriptions: TranscriptionsPage(controller: controller)
                    case .meetings: MeetingsPage()
                    case .conversations: MeetingsPage(kind: .conversations)
                    case .dictionary: DictionaryPanel(controller: controller)
                    case .snippets: SnippetsPage(controller: controller)
                    case .styles: StylesPage(controller: controller)
                    case .autowrite: AutowritePage(controller: controller)
                    case .settings: SettingsPage(controller: controller)
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            }
        }
        .background { BackgroundImage() }
        .frame(minWidth: DS.Material.windowMinWidth, minHeight: DS.Material.windowMinHeight)
        .preferredColorScheme(.dark)
        .onChange(of: section) { _, new in settings.lastPage = new.rawValue }
        .onChange(of: settings.lastPage) { _, new in
            if let page = Section(rawValue: new), page != section { section = page }
        }
    }

    // MARK: Sidebar

    /// The rail: room for the traffic lights, the wordmark, seven items, the version at the
    /// foot read from the bundle. Vibrancy behind it, the rail tint over it.
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.clear.frame(height: DS.Material.titleBarClearance)

            Wordmark()
                .padding(.horizontal, DS.Space.wordmarkSide)
                .padding(.top, DS.Space.wordmarkTop)
                .padding(.bottom, DS.Space.wordmarkBottom)

            VStack(spacing: DS.Space.navGap) {
                ForEach(Section.allCases) { candidate in
                    navItem(candidate)
                }
            }
            .padding(.horizontal, DS.Space.navInset)

            Spacer()

            Text(Self.versionLabel)
                .font(DS.Font.data)
                .foregroundStyle(DS.Color.dim)
                .padding(.horizontal, DS.Space.wordmarkSide)
                .padding(.vertical, DS.Space.versionPadY)
        }
        .frame(width: DS.Material.sidebarWidth)
        .frame(maxHeight: .infinity)
        .background {
            if isSnapshotting {
                DS.Color.rail
            } else {
                RailGlass(material: .sidebar).overlay(DS.Color.rail)
            }
        }
        // The system focus ring would land on the first nav item whenever the window
        // becomes key; the selected fill already says which page is open.
        .focusEffectDisabled()
        .overlay(alignment: .trailing) {
            Rectangle().fill(DS.Color.border).frame(width: DS.Border.hairline)
        }
    }

    private static let versionLabel: String = {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }()

    private func navItem(_ candidate: Section) -> some View {
        let isActive = section == candidate
        return Button {
            withAnimation(DS.Motion.panel) { section = candidate }
        } label: {
            HStack(spacing: DS.Space.navItemGap) {
                CarbonIcon(name: candidate.icon, size: DS.Control.navIconSize)
                    .foregroundStyle(isActive ? DS.Color.ink : DS.Color.inkSecondary)
                Text(candidate.title)
                    .font(DS.Font.body)
                    .foregroundStyle(DS.Color.ink)
                if candidate == .meetings && meetings.isRecording {
                    Spacer(minLength: 0)
                    // A meeting is recording: the way back to it, from any page.
                    Circle()
                        .fill(DS.Color.ink)
                        .frame(width: DS.Control.liveDot, height: DS.Control.liveDot)
                }
            }
            .padding(.horizontal, DS.Space.navItemPadX)
            .frame(height: DS.Material.navRowHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isActive ? DS.Color.selectedFill : Color.clear, in: RoundedRectangle(cornerRadius: DS.Radius.control))
            .contentShape(RoundedRectangle(cornerRadius: DS.Radius.control))
        }
        .buttonStyle(.plain)
        .handCursor()
    }
}

// MARK: - Shared

/// Earlier bare underline search field, kept until the last page that uses it is rebuilt.
struct SearchField: View {
    @Binding var text: String
    let placeholder: String

    var body: some View {
        SearchBox(text: $text, placeholder: placeholder)
    }
}

/// The empty body of a list card: a line in ink, a centred caption, and at most one
/// button. Used when a page has nothing to list yet.
struct EmptyCardBody<Action: View>: View {
    let title: String
    let detail: String
    @ViewBuilder var action: Action

    init(_ title: String, detail: String, @ViewBuilder action: () -> Action = { EmptyView() }) {
        self.title = title
        self.detail = detail
        self.action = action()
    }

    var body: some View {
        VStack(spacing: DS.Space.roomy) {
            Text(title)
                .font(DS.Font.transcript)
                .foregroundStyle(DS.Color.ink)
            Text(detail)
                .font(DS.Font.caption)
                .foregroundStyle(DS.Color.inkSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: DS.Space.subtitleMeasure)
            action
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, DS.Space.emptyPadY)
        .padding(.horizontal, DS.Space.wide)
    }
}

struct EmptyPanel: View {
    let label: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.snug) {
            Text(label)
                .font(DS.Font.bodyEmphasis)
                .foregroundStyle(DS.Color.ink)
            Text(detail)
                .font(DS.Font.body)
                .foregroundStyle(DS.Color.inkSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.vertical, DS.Space.section)
    }
}
