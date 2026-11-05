import Accelerate
import AppKit
import AVFoundation
import CoreImage
import Foundation
import ScreenCaptureKit

/// Films a meeting recorded With video (docs/mockups/meeting-video.html, picks 03 20 31).
///
/// What it films (03): the call's own window when the call app is known, followed even while
/// something covers it; otherwise the screen the pointer is on, SigmaFlow's windows left out.
/// If the call's window closes part way, filming carries on with that screen.
///
/// At the screen's own size, up to 30 frames a second (20), HEVC on the media engine at about
/// 2 GB an hour. It goes to a staged .mov written in ten-second fragments, so a quit or a
/// crash still leaves a file that plays; `MeetingMovie` makes the meeting's .mp4 at Stop.
///
/// Stills (31): once a second a small grey copy of the frame is compared with the second
/// before and with the last still kept. A frame that has settled and differs from that still
/// in enough places is saved as a JPEG named by its time, like live notes' screenshots, and
/// becomes a row of its own in the transcript. Faces talking never settle; a new slide does.
/// The thresholds are a first guess, not yet measured on a real call.
///
/// The stream's callbacks run on `queue`; the state they touch sits behind
/// `nonisolated(unsafe)` and is only touched there, the same contract as `MeetingRecorder`.
final class MeetingVideo: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    /// Bits a second: about 2 GB an hour (20).
    private static let bitRate = 4_500_000
    private static let framesPerSecond: Int32 = 30
    private static let fragment = CMTime(seconds: 10, preferredTimescale: 600)
    private static let stillLongSide: CGFloat = 1920
    private static let printSize = (width: 64, height: 40)
    /// A print cell counts as changed past this many grey levels.
    private static let cellChange = 24
    /// Settled: fewer than this share of cells changed since the second before.
    private static let settled = 0.03
    /// New: at least this share changed since the last still.
    private static let changed = 0.06
    private static let firstStill: Double = 2
    private static let stillGap: Double = 5

    private let queue = DispatchQueue(label: "com.grj.sigmaflow.meeting-video", qos: .userInitiated)
    private let stillQueue = DispatchQueue(label: "com.grj.sigmaflow.meeting-stills", qos: .utility)
    private let context = CIContext(options: [.cacheIntermediates: false])

    private var stream: SCStream?
    private var configuration = SCStreamConfiguration()
    private nonisolated(unsafe) var isStopping = false

    private nonisolated(unsafe) var writer: AVAssetWriter?
    private nonisolated(unsafe) var input: AVAssetWriterInput?
    private nonisolated(unsafe) var startedAt: CMTime = .zero
    private nonisolated(unsafe) var frames = 0
    private nonisolated(unsafe) var stills: URL?
    private nonisolated(unsafe) var lastLook: Double = -.infinity
    private nonisolated(unsafe) var lastStillAt: Double = -.infinity
    private nonisolated(unsafe) var previousPrint: [UInt8]?
    private nonisolated(unsafe) var stillPrint: [UInt8]?

    struct Failure: LocalizedError {
        let reason: String
        var errorDescription: String? { reason }
    }

    /// Screen Recording, which macOS asks for once (and again now and then).
    static var isAllowed: Bool { CGPreflightScreenCaptureAccess() }

    /// Starts filming into `url` (a .mov), stills into `stills`. `startedAt` is the host-clock
    /// time the meeting's audio began, so the picture and the sound share one timeline.
    func start(to url: URL, stills: URL, startedAt: CMTime, call: CallWatcher.Call?) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let (filter, size) = try await Self.filter(for: call, in: content)

        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        writer.movieFragmentInterval = Self.fragment
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: size.width,
            AVVideoHeightKey: size.height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: Self.bitRate,
                AVVideoExpectedSourceFrameRateKey: Self.framesPerSecond,
                AVVideoMaxKeyFrameIntervalDurationKey: 2,
            ],
        ])
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else { throw Failure(reason: "the video writer refused its input") }
        writer.add(input)
        guard writer.startWriting() else {
            throw writer.error ?? Failure(reason: "the video writer would not start")
        }
        // Frames arrive a moment after the sound began; the gap before the first is left empty.
        writer.startSession(atSourceTime: startedAt)
        try? FileManager.default.createDirectory(at: stills, withIntermediateDirectories: true)
        queue.sync {
            self.writer = writer
            self.input = input
            self.startedAt = startedAt
            self.stills = stills
        }

        let config = SCStreamConfiguration()
        config.width = size.width
        config.height = size.height
        config.minimumFrameInterval = CMTime(value: 1, timescale: Self.framesPerSecond)
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        config.queueDepth = 8
        config.showsCursor = true
        config.scalesToFit = true
        config.preservesAspectRatio = true
        configuration = config
        try await run(filter)
        Log.meetings.info("filming \(size.width, privacy: .public)x\(size.height, privacy: .public)")
    }

    /// Stops filming and closes the file. True when it holds at least one frame.
    func stop() async -> Bool {
        isStopping = true
        try? await stream?.stopCapture()
        stream = nil
        let (writer, frames) = await withCheckedContinuation { continuation in
            queue.async {
                self.input?.markAsFinished()
                let pair = (self.writer, self.frames)
                self.writer = nil
                self.input = nil
                continuation.resume(returning: pair)
            }
        }
        guard let writer else { return false }
        await writer.finishWriting()
        if writer.status != .completed {
            Log.meetings.error("video didn't close: \(writer.error?.localizedDescription ?? "unknown", privacy: .public)")
        }
        return writer.status == .completed && frames > 0
    }

    private func run(_ filter: SCContentFilter) async throws {
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
    }

    // MARK: What to film

    /// The call's largest window when there is a call, else the screen under the pointer.
    private static func filter(
        for call: CallWatcher.Call?, in content: SCShareableContent
    ) async throws -> (SCContentFilter, (width: Int, height: Int)) {
        if let call, let window = callWindow(call, in: content) {
            let filter = SCContentFilter(desktopIndependentWindow: window)
            let scale = CGFloat(filter.pointPixelScale)
            return (filter, even(filter.contentRect.width * scale, filter.contentRect.height * scale))
        }
        return try await screenFilter(in: content)
    }

    private static func callWindow(_ call: CallWatcher.Call, in content: SCShareableContent) -> SCWindow? {
        let family = call.family.lowercased()
        let browser = call.browser?.lowercased()
        return content.windows
            .filter { window in
                guard let bundle = window.owningApplication?.bundleIdentifier.lowercased() else { return false }
                return (bundle.hasPrefix(family) || bundle == browser)
                    && window.isOnScreen && window.windowLayer == 0
                    && window.frame.width >= 320 && window.frame.height >= 240
            }
            .max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
    }

    private static func screenFilter(
        in content: SCShareableContent
    ) async throws -> (SCContentFilter, (width: Int, height: Int)) {
        let screen = await MainActor.run { () -> (id: CGDirectDisplayID, scale: CGFloat)? in
            let mouse = NSEvent.mouseLocation
            let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
            guard let screen, let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            else { return nil }
            return (CGDirectDisplayID(number.uint32Value), screen.backingScaleFactor)
        }
        guard let display = content.displays.first(where: { $0.displayID == screen?.id }) ?? content.displays.first
        else { throw Failure(reason: "no screen to film") }
        let ours = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        let filter = SCContentFilter(display: display, excludingApplications: ours, exceptingWindows: [])
        let scale = screen?.scale ?? 2
        return (filter, even(CGFloat(display.width) * scale, CGFloat(display.height) * scale))
    }

    private static func even(_ width: CGFloat, _ height: CGFloat) -> (width: Int, height: Int) {
        (max(2, Int(width) & ~1), max(2, Int(height) & ~1))
    }

    /// The call's window went (closed, or the call app quit): film the screen instead, at the
    /// size the file already has.
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        guard !isStopping else { return }
        Log.meetings.info("filming stopped (\(error.localizedDescription, privacy: .public)), the screen instead")
        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                let (filter, _) = try await Self.screenFilter(in: content)
                guard !isStopping else { return }
                try await run(filter)
            } catch {
                Log.meetings.error("couldn't go on filming: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: Frames

    func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, buffer.isValid,
              let infos = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = infos.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
              let pixels = buffer.imageBuffer, let input
        else { return }
        if input.isReadyForMoreMediaData, input.append(buffer) { frames += 1 }
        look(at: pixels, time: (buffer.presentationTimeStamp - startedAt).seconds)
    }

    /// Once a second: keep a still when the picture has settled on something new.
    private func look(at pixels: CVPixelBuffer, time: Double) {
        guard time >= Self.firstStill, time - lastLook >= 1, let stills else { return }
        lastLook = time
        guard let print = Self.print(of: pixels) else { return }
        defer { previousPrint = print }
        guard let previousPrint, Self.share(changedBetween: print, previousPrint) < Self.settled,
              time - lastStillAt >= Self.stillGap
        else { return }
        if let stillPrint, Self.share(changedBetween: print, stillPrint) < Self.changed { return }
        guard let image = still(of: pixels) else { return }
        stillPrint = print
        lastStillAt = time
        let url = stills.appendingPathComponent(MeetingNaming.clock(time).replacingOccurrences(of: ":", with: "-") + ".jpg")
        stillQueue.async { _ = NotesScreen.write(image, to: url) }
    }

    /// The frame as a picture at most `stillLongSide` across, drawn now: the stream reuses its
    /// buffers, so it can't be held for later.
    private func still(of pixels: CVPixelBuffer) -> CGImage? {
        var image = CIImage(cvPixelBuffer: pixels)
        let scale = min(1, Self.stillLongSide / max(image.extent.width, image.extent.height))
        if scale < 1 {
            image = image.applyingFilter("CILanczosScaleTransform", parameters: [
                kCIInputScaleKey: scale, kCIInputAspectRatioKey: 1,
            ])
        }
        return context.createCGImage(image, from: image.extent.integral)
    }

    /// The frame's brightness, shrunk to a few thousand cells, straight from the luma plane.
    private static func print(of pixels: CVPixelBuffer) -> [UInt8]? {
        guard CVPixelBufferGetPlaneCount(pixels) >= 1,
              CVPixelBufferLockBaseAddress(pixels, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(pixels, 0) else { return nil }
        var source = vImage_Buffer(
            data: base,
            height: vImagePixelCount(CVPixelBufferGetHeightOfPlane(pixels, 0)),
            width: vImagePixelCount(CVPixelBufferGetWidthOfPlane(pixels, 0)),
            rowBytes: CVPixelBufferGetBytesPerRowOfPlane(pixels, 0))
        let (width, height) = printSize
        var cells = [UInt8](repeating: 0, count: width * height)
        let error = cells.withUnsafeMutableBytes { bytes -> vImage_Error in
            var target = vImage_Buffer(
                data: bytes.baseAddress, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: width)
            return vImageScale_Planar8(&source, &target, nil, vImage_Flags(kvImageNoFlags))
        }
        return error == kvImageNoError ? cells : nil
    }

    private static func share(changedBetween a: [UInt8], _ b: [UInt8]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 1 }
        let moved = zip(a, b).reduce(0) { $0 + (abs(Int($1.0) - Int($1.1)) > cellChange ? 1 : 0) }
        return Double(moved) / Double(a.count)
    }
}

/// The meeting's .mp4 (15): the staged film and the meeting's sound in one file, made at Stop.
/// The picture is copied as it is, nothing encoded again; the sound is the meeting's own,
/// folded to one channel first when it is two-sided, so a call plays in both ears in any app.
enum MeetingMovie {
    static func make(film: URL, sound: URL, into movie: URL) async throws {
        var folded: URL?
        defer { if let folded { try? FileManager.default.removeItem(at: folded) } }
        var audio = sound
        if MeetingAudio.isTwoSided(sound) {
            let mono = FileManager.default.temporaryDirectory.appendingPathComponent("sigmaflow-\(UUID().uuidString).m4a")
            try MeetingAudio.fold(sound, into: mono)
            folded = mono
            audio = mono
        }

        let picture = AVURLAsset(url: film)
        let heard = AVURLAsset(url: audio)
        let composition = AVMutableComposition()
        guard let filmTrack = try await picture.loadTracks(withMediaType: .video).first,
              let video = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
        else { throw MeetingVideo.Failure(reason: "the film has no picture") }
        // The whole film from its own zero, the empty stretch before the first frame included,
        // so the picture stays level with the sound.
        try video.insertTimeRange(
            CMTimeRange(start: .zero, duration: try await picture.load(.duration)), of: filmTrack, at: .zero)
        if let soundTrack = try await heard.loadTracks(withMediaType: .audio).first,
           let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
            try track.insertTimeRange(
                CMTimeRange(start: .zero, duration: try await heard.load(.duration)), of: soundTrack, at: .zero)
        }
        guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough)
        else { throw MeetingVideo.Failure(reason: "the movie can't be written") }
        try? FileManager.default.removeItem(at: movie)
        try await export.export(to: movie, as: .mp4)
    }
}
