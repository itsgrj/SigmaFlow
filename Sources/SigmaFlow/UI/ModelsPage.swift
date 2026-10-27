import SwiftUI

/// Models, to Figma windows 24 and 24B: the engine that turns your voice into text,
/// grouped by capability on two tabs. One model is active at a time. Installed, active,
/// downloading and not yet downloaded all sit in the same column at the right, so a
/// progress line becomes a Use button in the same spot when it lands.
struct ModelsPage: View {
    @State private var settings = Settings.shared
    @State private var library = ModelLibrary.shared

    enum Tab: String { case english, multilingual }

    private var tab: Binding<Tab> {
        Binding(
            get: { Tab(rawValue: settings.openTabs["models"] ?? "") ?? .english },
            set: { settings.openTabs["models"] = $0.rawValue }
        )
    }

    private var models: [SpeechModelID] {
        SpeechModelID.allCases.filter { $0.isEnglishOnly == (tab.wrappedValue == .english) }
    }

    var body: some View {
        PageScroll {
            PageHeader(
                "Models",
                subtitle: "The engine that turns your voice into text. Every engine runs on this Mac; nothing you say leaves it."
            )
            TabStrip(tabs: [(.english, "English only"), (.multilingual, "Multilingual")], selection: tab)
        } content: {
            Card {
                let rows = models
                ForEach(Array(rows.enumerated()), id: \.element) { index, model in
                    ModelRow(model: model, library: library, settings: settings)
                    if index < rows.count - 1 { CardDivider() }
                }
            }
        }
        .onAppear { library.refresh() }
    }
}

/// One model: name, blurb and three aligned facts at the left, the two gauges in the
/// middle, and the one action that fits its state in a fixed column at the right.
private struct ModelRow: View {
    let model: SpeechModelID
    let library: ModelLibrary
    let settings: Settings

    private var isActive: Bool { settings.activeModel == model }

    var body: some View {
        HStack(alignment: .center, spacing: DS.Space.wide) {
            VStack(alignment: .leading, spacing: DS.Space.tight) {
                Text(model.displayName)
                    .font(DS.Font.body)
                    .foregroundStyle(DS.Color.ink)
                Text(model.blurb)
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: DS.Space.measureNarrow, alignment: .leading)
                // Three columns that line up across rows at the Figma width. The row is
                // built for 1160 and the window goes down to 980, where this column loses
                // about 180 points; the facts then stack rather than hold their line, because
                // a line that will not give way grows the page past the window and drags the
                // sidebar off its left edge.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 0) {
                        Text(model.languages)
                            .frame(width: DS.Material.factsLanguagesWidth, alignment: .leading)
                        Text(model.sizeText)
                            .frame(width: DS.Material.factsSizeWidth, alignment: .leading)
                        Text(model.deliveryText)
                    }
                    .fixedSize()
                    VStack(alignment: .leading, spacing: DS.Space.captionGap) {
                        Text(model.languages)
                        Text(model.sizeText)
                        Text(model.deliveryText)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
                .font(DS.Font.caption)
                .foregroundStyle(DS.Color.inkSecondary)
                if case .failed(let message) = library.state(of: model) {
                    Text(message)
                        .font(DS.Font.caption)
                        .foregroundStyle(DS.Color.ink)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .leading, spacing: DS.Material.gaugeRowGap) {
                GaugeLine(label: "Accuracy", value: model.accuracy)
                GaugeLine(label: "Speed", value: model.speed)
            }

            HStack(spacing: DS.Space.tight) {
                Spacer(minLength: 0)
                action
            }
            .frame(width: DS.Material.actionSlotWidth, height: DS.Control.height)
        }
        .padding(.horizontal, DS.Space.rowPadX)
        .padding(.vertical, DS.Space.rowPadY)
    }

    @ViewBuilder
    private var action: some View {
        if isActive {
            TagChip(text: "Active")
        } else {
            switch library.state(of: model) {
            case .builtIn:
                useButton
            case .downloaded:
                AppButton(title: "", icon: "trash-can") { library.delete(model) }
                useButton
            case .downloading(let fraction):
                AppButton(title: "", icon: "close") { library.cancelDownload(model) }
                ProgressLine(fraction: fraction)
            case .notDownloaded, .failed:
                AppButton(title: "Download", kind: .secondary, icon: "download") { library.download(model) }
            }
        }
    }

    private var useButton: some View {
        AppButton(title: "Use", kind: .secondary, fixedWidth: DS.Material.useButtonWidth) {
            settings.activeModel = model
        }
    }
}
