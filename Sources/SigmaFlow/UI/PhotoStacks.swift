import SwiftUI

/// A conversation's photos in the list: three stacks of up to three, nine at most, picked at
/// random from the whole conversation, and +N for the rest (docs/mockups/notes-home.html,
/// Gokul's picks 16 Oct 2026). Each stack sits at an angle, one photo behind the other; the
/// photo under the pointer rises a little and comes to the front.
///
/// The pick changes with `seed`, which the page renews each time it appears: random, but
/// still while you look.
struct PhotoStacks: View {
    let photos: [URL]
    let seed: UInt64

    private static let shown = 9
    private static let stacks = 3

    @State private var hovered: URL?

    var body: some View {
        let picked = Self.pick(photos, seed: seed)
        // Dealt like cards, one to each stack in turn: two photos make two stacks of one.
        let dealt = (0..<Self.stacks).map { stack in picked.enumerated().filter { $0.offset % Self.stacks == stack }.map(\.element) }
        HStack(spacing: DS.Space.snug) {
            HStack(spacing: DS.Material.stackGap) {
                ForEach(Array(dealt.enumerated()), id: \.offset) { _, stack in
                    if !stack.isEmpty { pile(stack) }
                }
            }
            // Always three stacks wide, filled from the left, so stacks line up down the list.
            .frame(width: Self.areaWidth, alignment: .leading)
            Text(photos.count > Self.shown ? "+\(photos.count - Self.shown)" : "")
                .font(DS.Font.monoSmall)
                .foregroundStyle(DS.Color.dim)
                .frame(width: DS.Material.stackCountWidth, alignment: .leading)
        }
    }

    /// One stack: the first photo in front, each one behind it a step up and to the right.
    private func pile(_ stack: [URL]) -> some View {
        let step = DS.Material.stackStep
        return ZStack(alignment: .bottomLeading) {
            ForEach(Array(stack.enumerated().reversed()), id: \.element) { depth, url in
                let isHovered = hovered == url
                photo(url)
                    .offset(x: CGFloat(depth) * step, y: -CGFloat(depth) * step * 0.75)
                    .scaleEffect(isHovered ? DS.Material.stackHoverScale : 1, anchor: .bottom)
                    .offset(y: isHovered ? -DS.Material.stackLift : 0)
                    .shadow(color: .black.opacity(isHovered ? 0.6 : 0), radius: isHovered ? 6 : 0, y: 3)
                    .zIndex(isHovered ? 10 : Double(stack.count - depth))
                    .onHover { inside in
                        withAnimation(.easeOut(duration: DS.Motion.stackLift)) {
                            if inside { hovered = url } else if hovered == url { hovered = nil }
                        }
                    }
            }
        }
        .frame(
            width: DS.Material.stackPhotoWidth + step * 2,
            height: DS.Material.stackPhotoHeight + step * 1.5, alignment: .bottomLeading)
    }

    private func photo(_ url: URL) -> some View {
        Group {
            if let image = ThumbCache.small(url) {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                DS.Color.controlFill
            }
        }
        .frame(width: DS.Material.stackPhotoWidth, height: DS.Material.stackPhotoHeight)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.chip / 2))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.chip / 2).strokeBorder(DS.Color.border, lineWidth: DS.Border.hairline))
    }

    private static var areaWidth: CGFloat {
        let one = DS.Material.stackPhotoWidth + DS.Material.stackStep * 2
        return one * CGFloat(stacks) + DS.Material.stackGap * CGFloat(stacks - 1)
    }

    /// Nine at random: each photo's place in a shuffle made from its name and the seed.
    static func pick(_ photos: [URL], seed: UInt64) -> [URL] {
        func key(_ url: URL) -> UInt64 {
            var hash: UInt64 = 0xcbf2_9ce4_8422_2325 ^ seed
            for byte in url.lastPathComponent.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3 }
            return hash
        }
        return Array(photos.sorted { key($0) < key($1) }.prefix(shown))
    }
}
