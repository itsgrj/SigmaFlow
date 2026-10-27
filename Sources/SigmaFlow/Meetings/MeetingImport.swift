import AVFoundation
import CoreMedia
import Foundation

/// A recording dropped onto the Meetings page, made into a meeting's audio file.
///
/// Every dropped file is converted, as a copy, to exactly what `MeetingRecorder` writes:
/// AAC, 16 kHz, mono. Two reasons, both silent if skipped. The library only sees .m4a files,
/// so an .mp3 filed as-is would vanish from the page. And a two-channel file reads as a call
/// (`MeetingAudio.isTwoSided`: microphone left, call right), so an ordinary stereo recording
/// would be split down the middle and transcribed as two sides. The user's original is only
/// ever read (Gokul, 15 Oct 2026, docs/mockups/meeting-drop-audio.html, picks 1A 2B 3A 4B).
///
/// Anything AVFoundation can open works, video included (a Zoom or Meet download keeps its
/// sound only). Ogg and Opus, WhatsApp's voice notes, cannot be opened and say so.
enum MeetingImport {
    enum Failure: Error {
        case noSound
    }

    private static let chunk: AVAudioFrameCount = 16_000 * 10

    /// Seconds of sound in a file, or a throw when there is no sound to read.
    static func length(of source: URL) async throws -> Double {
        let asset = AVURLAsset(url: source)
        guard try await !asset.loadTracks(withMediaType: .audio).isEmpty else { throw Failure.noSound }
        let seconds = try await asset.load(.duration).seconds
        guard seconds.isFinite, seconds > 0 else { throw Failure.noSound }
        return seconds
    }

    /// Writes `source`'s sound into `dest` in the recorder's format, a chunk at a time so a
    /// two-hour file is never held in memory. Returns the seconds written.
    static func convert(
        _ source: URL, into dest: URL, progress: @escaping @Sendable (Double) -> Void
    ) async throws -> Double {
        let asset = AVURLAsset(url: source)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard !tracks.isEmpty else { throw Failure.noSound }
        let total = try await asset.load(.duration).seconds

        // The reader does the resampling and the mix down to one channel.
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: MeetingRecorder.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw Failure.noSound }
        reader.add(output)

        try? FileManager.default.removeItem(at: dest)
        let file = try AVAudioFile(
            forWriting: dest, settings: MeetingRecorder.fileSettings, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: MeetingRecorder.outputFormat, frameCapacity: chunk) else {
            throw Failure.noSound
        }
        guard reader.startReading() else { throw reader.error ?? Failure.noSound }

        var written: AVAudioFramePosition = 0
        while let sample = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(sample), let channel = buffer.floatChannelData?[0] else { continue }
            // One sample buffer can be larger than the chunk; copy it out in pieces.
            let frames = CMSampleBufferGetNumSamples(sample)
            var offset = 0
            while offset < frames {
                let count = min(frames - offset, Int(chunk))
                let status = CMBlockBufferCopyDataBytes(
                    block, atOffset: offset * MemoryLayout<Float>.size, dataLength: count * MemoryLayout<Float>.size,
                    destination: channel)
                guard status == kCMBlockBufferNoErr else { throw Failure.noSound }
                buffer.frameLength = AVAudioFrameCount(count)
                try file.write(from: buffer)
                offset += count
                written += AVAudioFramePosition(count)
            }
            if total > 0 { progress(min(1, Double(written) / MeetingRecorder.sampleRate / total)) }
        }
        if reader.status == .failed { throw reader.error ?? Failure.noSound }
        guard written > 0 else { throw Failure.noSound }
        return Double(written) / MeetingRecorder.sampleRate
    }
}
