import Accelerate
import AVFoundation
import Foundation

/// Call tones, made silent before anything listens.
///
/// A browser call rings while it connects and beeps three times when it hangs up, and the
/// call side hears both as loudly as a voice. IndicConformer wrote the ringing down as
/// "ஹம் ஹம் ஹம்" and the hang-up as "உம் உம் உம்", and the diarizer gave the ringing a voice
/// of its own (4 Nov 2026, a Cliq call in Dia). A tone differs from a voice in one way that is
/// easy to measure: nearly all of its sound sits at one or two pitches, where a voice spreads
/// over its harmonics and keeps moving.
///
/// Measured on the five calls of 2 and 4 Nov 2026, 4.4 hours: the ringing (398 Hz), the
/// hang-up beeps (367 Hz) and a tone mid-meeting (414 Hz) put 97 to 99% of a window's sound
/// in its six strongest bins for 0.3 to 1.3 s at a time. Above 300 Hz, speech never stayed
/// that pure for five windows in a row. Below it, mains hum (148 Hz) did, which is why the
/// floor is there.
///
/// The tones become silence in a copy that the models and the diarizer hear. The meeting's
/// own file keeps every sound.
enum MeetingTones {
    /// 128 ms windows, every 32 ms, at 16 kHz.
    private static let window = 2048
    private static let hop = 512
    private static let log2n = vDSP_Length(11)
    /// A tone starts where windows are this pure,
    private static let pure: Float = 0.97
    /// this many in a row,
    private static let run = 5
    /// at this pitch or above.
    private static let lowest: Double = 300
    /// It carries on either side while windows stay this pure at about the same pitch,
    private static let fading: Float = 0.9
    /// within this many bins (8 Hz each) of it.
    private static let drift = 3
    /// Windows quieter than this (dB below full scale) are never a tone.
    private static let quiet: Float = -50

    /// `url` with its tones silent, written into `folder`, or `url` itself when it has none.
    static func silenced(_ url: URL, into folder: URL) throws -> URL {
        let tones = try find(in: url)
        guard !tones.isEmpty else { return url }
        let seconds = Double(tones.reduce(0) { $0 + $1.count }) / MeetingRecorder.sampleRate
        Log.meetings.info("meeting: \(tones.count) call tones silenced, \(seconds, format: .fixed(precision: 1))s")

        let source = try AVAudioFile(forReading: url)
        let format = source.processingFormat
        let out = folder.appendingPathComponent("\(UUID().uuidString).caf")
        let copy = try AVAudioFile(forWriting: out, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let chunk = AVAudioFrameCount(format.sampleRate * 10)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else { throw CocoaError(.fileWriteUnknown) }
        var position = 0
        while source.framePosition < source.length {
            try source.read(into: buffer, frameCount: chunk)
            let frames = Int(buffer.frameLength)
            guard frames > 0, let channels = buffer.floatChannelData else { break }
            let here = position..<(position + frames)
            for tone in tones where tone.overlaps(here) {
                let from = max(tone.lowerBound, here.lowerBound), to = min(tone.upperBound, here.upperBound)
                for channel in 0..<Int(format.channelCount) {
                    vDSP_vclr(channels[channel] + (from - position), 1, vDSP_Length(to - from))
                }
            }
            try copy.write(from: buffer)
            position += frames
        }
        return out
    }

    /// The tones in a file, as sample ranges, oldest first.
    static func find(in url: URL) throws -> [Range<Int>] {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let chunk = AVAudioFrameCount(format.sampleRate * 10)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk),
              let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))
        else { throw CocoaError(.fileReadUnknown) }
        defer { vDSP_destroy_fftsetup(setup) }

        var hann = [Float](repeating: 0, count: window)
        vDSP_hann_window(&hann, vDSP_Length(window), Int32(vDSP_HANN_NORM))
        let half = window / 2
        var frame = [Float](repeating: 0, count: window)
        var real = [Float](repeating: 0, count: half), imaginary = [Float](repeating: 0, count: half)
        var power = [Float](repeating: 0, count: half)
        // Per window: the share of its sound in the six strongest bins (0 when quiet), and
        // the strongest bin.
        var purity: [Float] = [], peaks: [Int] = []

        var pending: [Float] = []
        var share = 1 / Float(format.channelCount)
        while file.framePosition < file.length {
            try file.read(into: buffer, frameCount: chunk)
            let frames = Int(buffer.frameLength)
            guard frames > 0, let channels = buffer.floatChannelData else { break }
            var mono = [Float](repeating: 0, count: frames)
            mono.withUnsafeMutableBufferPointer { out in
                for channel in 0..<Int(format.channelCount) {
                    vDSP_vsma(channels[channel], 1, &share, out.baseAddress!, 1, out.baseAddress!, 1, vDSP_Length(frames))
                }
            }
            pending += mono

            var start = 0
            while start + window <= pending.count {
                var level: Float = 0
                pending.withUnsafeBufferPointer { samples in
                    vDSP_measqv(samples.baseAddress! + start, 1, &level, vDSP_Length(window))
                    vDSP_vmul(samples.baseAddress! + start, 1, hann, 1, &frame, 1, vDSP_Length(window))
                }
                start += hop
                guard 10 * log10(level + 1e-18) > quiet else {
                    purity.append(0)
                    peaks.append(0)
                    continue
                }
                real.withUnsafeMutableBufferPointer { re in
                    imaginary.withUnsafeMutableBufferPointer { im in
                        var split = DSPSplitComplex(realp: re.baseAddress!, imagp: im.baseAddress!)
                        frame.withUnsafeBytes {
                            vDSP_ctoz($0.bindMemory(to: DSPComplex.self).baseAddress!, 2, &split, 1, vDSP_Length(half))
                        }
                        vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                        vDSP_zvmags(&split, 1, &power, 1, vDSP_Length(half))
                    }
                }
                power[0] = 0  // the DC and Nyquist terms
                var total: Float = 0
                vDSP_sve(power, 1, &total, vDSP_Length(half))
                var strongest: Float = 0, peak = 0
                for pick in 0..<6 {
                    var value: Float = 0
                    var index: vDSP_Length = 0
                    vDSP_maxvi(power, 1, &value, &index, vDSP_Length(half))
                    if pick == 0 { peak = Int(index) }
                    strongest += value
                    power[Int(index)] = 0
                }
                purity.append(total > 0 ? strongest / total : 0)
                peaks.append(peak)
            }
            pending.removeFirst(start)
        }
        return ranges(purity: purity, peaks: peaks, lowestBin: Int((lowest * Double(window) / format.sampleRate).rounded(.up)))
    }

    /// Runs of pure, steady windows, widened over the tone's own start and end.
    private static func ranges(purity: [Float], peaks: [Int], lowestBin: Int) -> [Range<Int>] {
        var out: [Range<Int>] = []
        var index = 0
        while index < purity.count {
            guard purity[index] >= pure, peaks[index] >= lowestBin else { index += 1; continue }
            var end = index
            while end + 1 < purity.count, purity[end + 1] >= pure, peaks[end + 1] >= lowestBin { end += 1 }
            defer { index = end + 1 }
            guard end - index + 1 >= run else { continue }

            let pitches = peaks[index...end]
            let low = pitches.min()! - drift, high = pitches.max()! + drift
            func continues(_ at: Int) -> Bool { purity[at] >= fading && (low...high).contains(peaks[at]) }
            var first = index
            while first > 0, continues(first - 1) { first -= 1 }
            while end + 1 < purity.count, continues(end + 1) { end += 1 }

            let range = (first * hop)..<(end * hop + window)
            if let last = out.last, last.upperBound >= range.lowerBound {
                out[out.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
            } else {
                out.append(range)
            }
        }
        return out
    }
}
