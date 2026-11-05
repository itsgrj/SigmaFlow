import AppKit
import AVFoundation
import SwiftUI

/// A meeting recorded with video, on its transcript (docs/mockups/meeting-video.html, 22; Figma
/// 3.26): the video in a column left of the lines, its own small bar under it (Pause or Play,
/// the time, a line to drag along), and its size and how much room it takes.
///
/// It plays through `MeetingPlayer`, the same clock as the header's Play and the filled line,
/// so a click on the picture, on Play, or on a line all move the one recording. Before it plays
/// it shows a still from the film.
struct MeetingVideoColumn: View {
    let meeting: Meeting
    let video: URL

    @State private var player = MeetingPlayer.shared
    @State private var poster: NSImage?
    @State private var pixels: CGSize?
    @State private var bytes: Int64?
    @State private var dragged: Double?

    private var isLoaded: Bool { player.playing == video }
    private var isPlaying: Bool { isLoaded && !player.isPaused }
    private var time: Double { dragged.map { $0 * meeting.duration } ?? (isLoaded ? player.elapsed : 0) }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.snug) {
            VStack(spacing: 0) {
                picture
                controls
            }
            .overlay(Rectangle().strokeBorder(DS.Color.border, lineWidth: DS.Border.hairline))
            HStack(spacing: DS.Space.wide) {
                if let pixels { fact("Video", "\(Int(pixels.width)) × \(Int(pixels.height))") }
                if let bytes { fact("Size", ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)) }
            }
        }
        .padding(DS.Space.snug)
        .frame(width: DS.Material.videoColumn, alignment: .topLeading)
        .task(id: video) { await load() }
    }

    private var picture: some View {
        ZStack {
            DS.Color.videoBacking
            if isLoaded, let playing = player.video {
                VideoSurface(player: playing)
            } else if let poster {
                Image(nsImage: poster).resizable().aspectRatio(contentMode: .fit)
            }
        }
        .aspectRatio(aspect, contentMode: .fit)
        .contentShape(Rectangle())
        .onTapGesture { toggle() }
    }

    private var aspect: CGFloat {
        guard let pixels, pixels.height > 0 else { return DS.Material.videoPoster.width / DS.Material.videoPoster.height }
        return pixels.width / pixels.height
    }

    private var controls: some View {
        HStack(spacing: DS.Space.snug) {
            Button(action: toggle) {
                CarbonIcon(name: isPlaying ? "pause" : "play", size: DS.Control.iconSizeSmall)
                    .foregroundStyle(DS.Color.inkSecondary)
            }
            .buttonStyle(.plain)
            .handCursor()
            Text("\(MeetingNaming.clock(time)) / \(MeetingNaming.clock(meeting.duration))")
                .font(DS.Font.mono)
                .foregroundStyle(DS.Color.inkSecondary)
                .fixedSize()
            scrubber
        }
        .padding(.horizontal, DS.Space.snug)
        .padding(.vertical, DS.Space.tight)
        .background(DS.Color.videoBacking)
    }

    /// Where the recording is, as a line; a click or a drag along it plays from there.
    private var scrubber: some View {
        GeometryReader { proxy in
            let fraction = meeting.duration > 0 ? min(1, max(0, time / meeting.duration)) : 0
            ZStack(alignment: .leading) {
                Rectangle().fill(DS.Color.gaugeOff).frame(height: DS.Border.bar)
                Rectangle().fill(DS.Color.ink).frame(width: proxy.size.width * fraction, height: DS.Border.bar)
                Circle()
                    .fill(DS.Color.ink)
                    .frame(width: DS.Material.videoKnob, height: DS.Material.videoKnob)
                    .offset(x: proxy.size.width * fraction - DS.Material.videoKnob / 2)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { dragged = min(1, max(0, $0.location.x / max(1, proxy.size.width))) }
                .onEnded { _ in
                    if let dragged { player.play(video, from: dragged * meeting.duration) }
                    dragged = nil
                })
        }
        .frame(height: DS.Material.videoKnob * 2)
    }

    private func fact(_ label: String, _ value: String) -> some View {
        HStack(spacing: DS.Space.snug) {
            Text(label).foregroundStyle(DS.Color.dim)
            Text(value).foregroundStyle(DS.Color.inkSecondary)
        }
        .font(DS.Font.caption)
    }

    private func toggle() {
        if isPlaying { player.pause() } else { player.play(video) }
    }

    /// The film's size, its room on disk, and a still from a second in (the first frame can
    /// come a moment after the sound starts).
    private func load() async {
        bytes = (try? video.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
        let asset = AVURLAsset(url: video)
        if let track = try? await asset.loadTracks(withMediaType: .video).first,
           let size = try? await track.load(.naturalSize) {
            pixels = size
        }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.maximumSize = DS.Material.videoPoster
        generator.appliesPreferredTrackTransform = true
        let at = CMTime(seconds: min(1, meeting.duration / 2), preferredTimescale: 600)
        if let still = try? await generator.image(at: at).image {
            poster = NSImage(cgImage: still, size: .zero)
        }
    }
}

/// The video's picture: AppKit's player layer, which SwiftUI has no view for.
private struct VideoSurface: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        let layer = AVPlayerLayer(player: player)
        layer.videoGravity = .resizeAspect
        view.layer = layer
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        (view.layer as? AVPlayerLayer)?.player = player
    }
}
