import AVFoundation
import Foundation

/// The meeting's one audio file holds both sides of a call: the microphone on the left
/// channel, the call on the right. It plays as an ordinary recording anywhere, and the
/// transcript can still tell the user's own words from everyone else's, because the two
/// channels are never mixed. A meeting with no call side stays a mono file.
///
/// Everything here streams in chunks: two hours of audio at 16 kHz is close to half a
/// gigabyte per side as floats, which is not a thing to hold in memory.
enum MeetingAudio {
    private static let chunk: AVAudioFrameCount = 16_000 * 10

    /// Writes `mic` and `call` (both 16 kHz mono) side by side into `stereo`.
    static func merge(mic: URL, call: URL, into stereo: URL) throws {
        let left = try AVAudioFile(forReading: mic)
        let right = try AVAudioFile(forReading: call)
        let mono = MeetingRecorder.outputFormat
        guard let both = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: MeetingRecorder.sampleRate, channels: 2, interleaved: false)
        else { throw CocoaError(.fileWriteUnknown) }
        let out = try AVAudioFile(
            forWriting: stereo,
            settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: MeetingRecorder.sampleRate,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 48_000,
            ],
            commonFormat: .pcmFormatFloat32, interleaved: false)

        guard let a = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: chunk),
              let b = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: chunk),
              let pair = AVAudioPCMBuffer(pcmFormat: both, frameCapacity: chunk)
        else { throw CocoaError(.fileWriteUnknown) }

        while true {
            a.frameLength = 0
            b.frameLength = 0
            if left.framePosition < left.length { try left.read(into: a, frameCount: chunk) }
            if right.framePosition < right.length { try right.read(into: b, frameCount: chunk) }
            let frames = max(a.frameLength, b.frameLength)
            guard frames > 0, let l = pair.floatChannelData?[0], let r = pair.floatChannelData?[1],
                  let la = a.floatChannelData?[0], let rb = b.floatChannelData?[0]
            else { break }
            // The shorter side is padded with silence; the two start within a few
            // milliseconds of each other, which is what keeps them aligned.
            for i in 0..<Int(frames) {
                l[i] = i < Int(a.frameLength) ? la[i] : 0
                r[i] = i < Int(b.frameLength) ? rb[i] : 0
            }
            pair.frameLength = frames
            try out.write(from: pair)
        }
    }

    static func isTwoSided(_ url: URL) -> Bool {
        (try? AVAudioFile(forReading: url))?.fileFormat.channelCount == 2
    }

    /// Splits a two-sided recording into two 16 kHz mono files in a temporary folder:
    /// the microphone and the call, in that order.
    static func split(_ stereo: URL) throws -> (mic: URL, call: URL) {
        let source = try AVAudioFile(forReading: stereo)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("sigmaflow-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let micURL = folder.appendingPathComponent("mic.caf")
        let callURL = folder.appendingPathComponent("call.caf")
        let mono = MeetingRecorder.outputFormat
        let mic = try AVAudioFile(forWriting: micURL, settings: mono.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let call = try AVAudioFile(forWriting: callURL, settings: mono.settings, commonFormat: .pcmFormatFloat32, interleaved: false)

        guard let pair = AVAudioPCMBuffer(pcmFormat: source.processingFormat, frameCapacity: chunk),
              let l = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: chunk),
              let r = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: chunk)
        else { throw CocoaError(.fileReadUnknown) }
        while source.framePosition < source.length {
            try source.read(into: pair, frameCount: chunk)
            let frames = Int(pair.frameLength)
            guard frames > 0, let channels = pair.floatChannelData,
                  let ld = l.floatChannelData?[0], let rd = r.floatChannelData?[0] else { break }
            for i in 0..<frames {
                ld[i] = channels[0][i]
                rd[i] = channels[1][i]
            }
            l.frameLength = pair.frameLength
            r.frameLength = pair.frameLength
            try mic.write(from: l)
            try call.write(from: r)
        }
        return (micURL, callURL)
    }

    /// The loudest sample in a file, read in chunks: a call side under this is empty.
    static func peak(_ url: URL) -> Float {
        guard let file = try? AVAudioFile(forReading: url),
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunk) else { return 0 }
        var loudest: Float = 0
        while file.framePosition < file.length, (try? file.read(into: buffer, frameCount: chunk)) != nil {
            guard let data = buffer.floatChannelData?[0], buffer.frameLength > 0 else { break }
            for i in 0..<Int(buffer.frameLength) { loudest = max(loudest, abs(data[i])) }
        }
        return loudest
    }
}
