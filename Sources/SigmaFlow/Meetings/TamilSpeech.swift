import Accelerate
import CoreML
import Foundation

/// Tamil speech on this Mac: AI4Bharat's IndicConformer 600M (MIT), in the CoreML copy at
/// `phequals/indic-conformer-600m-multilingual-coreml-rnnt`, with its Tamil head.
///
/// Chosen on 13 Oct 2026 against Whisper large-v3, Meta's Omnilingual and Parakeet on a real
/// 12-minute Tamil-English meeting: it was the only one that wrote whole spoken-Tamil
/// sentences, it invented nothing, and it heard the meeting in 3 seconds where Whisper took
/// 15 minutes. English words inside a Tamil sentence come out in Tamil letters ("கோர்ஸ்
/// நேம்"); whole English sentences are left to Parakeet (`MeetingProcessor`).
///
/// Downloaded the first time a meeting needs it (0.6 GB), never for someone whose meetings
/// are all English. The revision is pinned, so a change upstream cannot change transcripts.
actor TamilSpeech {
    static let shared = TamilSpeech()

    /// A word and where it sits in the audio handed over, in seconds.
    struct Word: Sendable {
        var text: String
        var start: Double
        var end: Double
    }

    // MARK: The files

    private static let repo = "phequals/indic-conformer-600m-multilingual-coreml-rnnt"
    private static let revision = "5590d07c06e95d461790ff753d4af536f0660197"

    private enum Part: String, CaseIterable {
        case encoder = "coreml/encoder/indic_conformer_encoder_int8"
        case jointEncoder = "coreml/rnnt/indic_conformer_joint_enc"
        case jointPredictor = "coreml/rnnt/indic_conformer_joint_pred"
        case jointPreNet = "coreml/rnnt/indic_conformer_joint_pre_net"
        case tamilHead = "coreml/rnnt/indic_conformer_joint_post_net_ta"
        case predictor = "coreml/rnnt/indic_conformer_rnnt_decoder_reconstructed"

        var name: String { String(rawValue.split(separator: "/").last!) }
        /// The pre-net is an activation with no weights; its package has an empty folder.
        var hasWeights: Bool { self != .jointPreNet }
        /// Bytes, for the download's progress. The encoder is almost all of it.
        var size: Int64 { self == .encoder ? 592_000_000 : 22_000_000 }
    }

    private static let metadata = ["metadata/vocab.json", "metadata/preprocessor_constants.bin"]

    private static var folder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SigmaFlow/Models/IndicConformer/\(revision)", isDirectory: true)
    }

    private static var readyMark: URL { folder.appendingPathComponent("ready") }

    nonisolated static var isDownloaded: Bool { FileManager.default.fileExists(atPath: readyMark.path) }

    // MARK: Decoding constants (the package's metadata/config.json)

    private static let blank = 256
    /// The prediction network's start token. Every later input is the head's own token id
    /// (0 to 255), not the id in the shared 22-language vocabulary: fed the shared id, the
    /// network repeats every sound ten times.
    private static let start: Int32 = 5632
    private static let symbolsPerFrame = 10
    private static let encoderFrames = 1024
    private static let melBands = 80
    /// Seconds per encoder step: 10 ms frames, eight to a step.
    private static let stepSeconds = 0.08
    static let sampleRate = 16000

    // MARK: Loading

    private struct Loaded {
        var encoder: MLModel
        var jointEncoder: MLModel
        var jointPredictor: MLModel
        var jointPreNet: MLModel
        var tamilHead: MLModel
        var predictor: MLModel
        var frontEnd: FrontEnd
        var vocab: [String]
    }

    private var loaded: Loaded?

    /// Downloads on first use, then loads once and keeps the models.
    func prepare(progress: @escaping @Sendable (Double) -> Void) async throws {
        if loaded != nil { return }
        if !Self.isDownloaded { try await Self.download(progress: progress) }
        progress(1)

        func model(_ part: Part, _ units: MLComputeUnits) throws -> MLModel {
            let config = MLModelConfiguration()
            config.computeUnits = units
            return try MLModel(contentsOf: Self.folder.appendingPathComponent("\(part.name).mlmodelc"), configuration: config)
        }
        let vocabData = try Data(contentsOf: Self.folder.appendingPathComponent("vocab.json"))
        guard let vocabs = try JSONSerialization.jsonObject(with: vocabData) as? [String: [String]],
              let tamil = vocabs["ta"], tamil.count == Self.blank + 1 else { throw Failure.damaged }
        let constants = try Data(contentsOf: Self.folder.appendingPathComponent("preprocessor_constants.bin"))
        // The encoder on the Neural Engine; the joint pieces are tiny and called thousands of
        // times a minute, where the CPU answers fastest.
        loaded = Loaded(
            encoder: try model(.encoder, .cpuAndNeuralEngine),
            jointEncoder: try model(.jointEncoder, .cpuOnly),
            jointPredictor: try model(.jointPredictor, .cpuOnly),
            jointPreNet: try model(.jointPreNet, .cpuOnly),
            tamilHead: try model(.tamilHead, .cpuOnly),
            predictor: try model(.predictor, .cpuOnly),
            frontEnd: try FrontEnd(constants),
            vocab: tamil)
    }

    enum Failure: LocalizedError {
        case download
        case damaged

        var errorDescription: String? {
            switch self {
            case .download: "Couldn't download the Tamil model."
            case .damaged: "The Tamil model is damaged."
            }
        }
    }

    private static func download(progress: @escaping @Sendable (Double) -> Void) async throws {
        let fm = FileManager.default
        try? fm.removeItem(at: folder)
        let staging = folder.appendingPathComponent("download", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)

        var files: [(path: String, size: Int64)] = metadata.map { ($0, 200_000) }
        for part in Part.allCases {
            files.append(("\(part.rawValue).mlpackage/Manifest.json", 1_000))
            files.append(("\(part.rawValue).mlpackage/Data/com.apple.CoreML/model.mlmodel", 1_000_000))
            if part.hasWeights {
                files.append(("\(part.rawValue).mlpackage/Data/com.apple.CoreML/weights/weight.bin", part.size))
            } else {
                try fm.createDirectory(
                    at: staging.appendingPathComponent("\(part.rawValue).mlpackage/Data/com.apple.CoreML/weights"),
                    withIntermediateDirectories: true)
            }
        }
        let total = Double(files.map(\.size).reduce(0, +))
        var done: Int64 = 0
        for file in files {
            let url = URL(string: "https://huggingface.co/\(repo)/resolve/\(revision)/\(file.path)")!
            let target = staging.appendingPathComponent(file.path)
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            let base = done
            try await fetch(url, to: target) { received in
                progress(0.9 * Double(base + min(received, file.size)) / total)
            }
            done += file.size
        }

        // CoreML runs compiled models; compile each package once, here, and keep only that.
        for part in Part.allCases {
            let compiled = try await MLModel.compileModel(at: staging.appendingPathComponent("\(part.rawValue).mlpackage"))
            try fm.moveItem(at: compiled, to: folder.appendingPathComponent("\(part.name).mlmodelc"))
        }
        for name in metadata {
            try fm.moveItem(
                at: staging.appendingPathComponent(name),
                to: folder.appendingPathComponent(URL(fileURLWithPath: name).lastPathComponent))
        }
        try? fm.removeItem(at: staging)
        try Data().write(to: readyMark)
        Log.meetings.info("tamil: model downloaded")
    }

    /// One file, with the bytes received so far reported twice a second. The temporary file
    /// is moved inside the completion handler, the only place it still exists.
    private static func fetch(_ url: URL, to target: URL, received: @escaping @Sendable (Int64) -> Void) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let task = URLSession.shared.downloadTask(with: url) { temporary, response, error in
                guard let temporary, (response as? HTTPURLResponse)?.statusCode == 200 else {
                    continuation.resume(throwing: error ?? Failure.download)
                    return
                }
                do {
                    try? FileManager.default.removeItem(at: target)
                    try FileManager.default.moveItem(at: temporary, to: target)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
            task.resume()
            Task {
                while task.state == .running {
                    received(task.countOfBytesReceived)
                    try? await Task.sleep(for: .milliseconds(500))
                }
            }
        }
    }

    // MARK: Hearing

    /// The words in a stretch of 16 kHz mono audio, up to about ten seconds.
    ///
    /// The model sometimes hears nothing at all in a stretch it hears perfectly when the
    /// stretch starts a quarter of a second later; the start alone decides it, not the
    /// length, the loudness or the chip. So a stretch that comes back empty or thin is tried
    /// again a little later in, and then in two halves cut at its quietest moment. On the
    /// 13 Oct meeting that took the empty stretches from 13 to 4.
    func words(_ samples: [Float]) throws -> [Word] {
        guard let loaded else { throw Failure.damaged }
        return try robust(samples, loaded: loaded, depth: 0)
    }

    /// Thin: fewer than four characters a second.
    private func isThin(_ words: [Word], seconds: Double) -> Bool {
        Double(Self.characters(words)) < 4 * seconds
    }

    private static func characters(_ words: [Word]) -> Int {
        words.isEmpty ? 0 : words.map { $0.text.unicodeScalars.count }.reduce(0, +) + words.count - 1
    }

    private func robust(_ samples: [Float], loaded: Loaded, depth: Int) throws -> [Word] {
        let rate = Double(Self.sampleRate)
        let seconds = Double(samples.count) / rate
        var best = try Self.hear(samples, loaded: loaded)
        if !isThin(best, seconds: seconds) || seconds < 1 { return best }

        for nudge in [0.25, 0.5, 0.8] {
            let skip = Int(nudge * rate)
            guard samples.count - skip >= Self.sampleRate / 2 else { break }
            let again = try Self.hear(Array(samples[skip...]), loaded: loaded).map { shifted($0, by: nudge) }
            if Self.characters(again) > Self.characters(best) { best = again }
            if !isThin(best, seconds: seconds) { return best }
        }

        if depth < 2, seconds > 2.5 {
            let cut = quietestPoint(samples)
            let left = try robust(Array(samples[..<cut]), loaded: loaded, depth: depth + 1)
            let right = try robust(Array(samples[cut...]), loaded: loaded, depth: depth + 1)
                .map { shifted($0, by: Double(cut) / rate) }
            let halves = left + right
            if Self.characters(halves) > Self.characters(best) { best = halves }
        }
        return best
    }

    private func shifted(_ word: Word, by seconds: Double) -> Word {
        Word(text: word.text, start: word.start + seconds, end: word.end + seconds)
    }

    /// The quietest 20 ms in the middle half.
    private func quietestPoint(_ samples: [Float]) -> Int {
        let frame = Self.sampleRate / 50
        let count = (samples.count - frame) / frame
        guard count > 4 else { return samples.count / 2 }
        var energies = [Float](repeating: 0, count: count)
        samples.withUnsafeBufferPointer { buffer in
            for index in 0..<count {
                vDSP_measqv(buffer.baseAddress! + index * frame, 1, &energies[index], vDSP_Length(frame))
            }
        }
        let low = count / 4, high = 3 * count / 4
        let quietest = (low..<high).min { energies[$0] < energies[$1] } ?? count / 2
        return quietest * frame
    }

    /// One pass: features, the encoder, then greedy RNNT decoding.
    ///
    /// Every prediction hands back autoreleased output buffers backed by IOSurfaces. Nothing
    /// drains them inside a long Swift task, and on 13 Oct 2026 a 12-minute meeting ran the
    /// system out of IOSurfaces and crashed. Hence a pool around the encoder and around each
    /// step.
    private nonisolated static func hear(_ samples: [Float], loaded: Loaded) throws -> [Word] {
        guard samples.count >= Self.sampleRate / 10 else { return [] }
        let (features, frames) = loaded.frontEnd.features(samples)
        let used = min(frames, Self.encoderFrames)

        let input = try MLMultiArray(shape: [1, NSNumber(value: Self.melBands), NSNumber(value: Self.encoderFrames)], dataType: .float32)
        let pointer = input.dataPointer.assumingMemoryBound(to: Float.self)
        pointer.initialize(repeating: 0, count: Self.melBands * Self.encoderFrames)
        let rowStride = input.strides[1].intValue, columnStride = input.strides[2].intValue
        for band in 0..<Self.melBands {
            for frame in 0..<used {
                pointer[band * rowStride + frame * columnStride] = features[band * frames + frame]
            }
        }
        let length = try MLMultiArray(shape: [1], dataType: .int32)
        length[0] = NSNumber(value: used)
        let (encoder, width, steps) = try autoreleasepool { () throws -> ([Float], Int, Int) in
            let encoded = try loaded.encoder.prediction(from: MLDictionaryFeatureProvider(dictionary: [
                "audio_signal": input, "length": length,
            ]))
            guard let outputs = encoded.featureValue(for: "outputs")?.multiArrayValue,
                  let lengths = encoded.featureValue(for: "encoded_lengths")?.multiArrayValue else { throw Failure.damaged }
            let steps = min(lengths[0].intValue, outputs.shape[2].intValue)
            let width = outputs.shape[1].intValue
            let floats = Floats(outputs)
            // Time-major copy: one step's values side by side.
            var copy = [Float](repeating: 0, count: steps * width)
            for time in 0..<steps {
                for index in 0..<width { copy[time * width + index] = floats[0, index, time] }
            }
            return (copy, width, steps)
        }

        var hidden = try MLMultiArray(shape: [2, 1, 640], dataType: .float32)
        var cell = try MLMultiArray(shape: [2, 1, 640], dataType: .float32)
        for array in [hidden, cell] {
            array.dataPointer.assumingMemoryBound(to: Float.self).initialize(repeating: 0, count: array.count)
        }
        var predicted = try Self.predict(Self.start, hidden: hidden, cell: cell, loaded: loaded)
        var tokens: [(id: Int, step: Int)] = []

        let step = try MLMultiArray(shape: [1, 1, NSNumber(value: width)], dataType: .float32)
        let stepPointer = step.dataPointer.assumingMemoryBound(to: Float.self)
        let sum = try MLMultiArray(shape: [1, 1, 640], dataType: .float32)
        let sumPointer = sum.dataPointer.assumingMemoryBound(to: Float.self)

        for time in 0..<steps {
            try autoreleasepool {
                encoder.withUnsafeBufferPointer { values in
                    stepPointer.update(from: values.baseAddress! + time * width, count: width)
                }
                let joined = try loaded.jointEncoder.prediction(from: MLDictionaryFeatureProvider(dictionary: ["input": step]))
                guard let frameOut = joined.featureValue(for: "output")?.multiArrayValue else { throw Failure.damaged }
                let frame = Floats(frameOut).all

                for _ in 0..<Self.symbolsPerFrame {
                    vDSP_vadd(frame, 1, predicted.output, 1, sumPointer, 1, 640)
                    let pre = try loaded.jointPreNet.prediction(from: MLDictionaryFeatureProvider(dictionary: ["input": sum]))
                    guard let activated = pre.featureValue(for: "output")?.multiArrayValue else { throw Failure.damaged }
                    let head = try loaded.tamilHead.prediction(from: MLDictionaryFeatureProvider(dictionary: ["input": activated]))
                    guard let logits = head.featureValue(for: "output")?.multiArrayValue else { throw Failure.damaged }
                    let scores = Floats(logits).all
                    var best: Float = 0
                    var position: vDSP_Length = 0
                    vDSP_maxvi(scores, 1, &best, &position, vDSP_Length(scores.count))
                    let token = Int(position)
                    if token == Self.blank { break }
                    tokens.append((token, time))
                    hidden = predicted.hidden
                    cell = predicted.cell
                    predicted = try Self.predict(Int32(token), hidden: hidden, cell: cell, loaded: loaded)
                }
            }
        }
        return Self.words(tokens, vocab: loaded.vocab)
    }

    private struct Prediction {
        var output: [Float]
        var hidden: MLMultiArray
        var cell: MLMultiArray
    }

    private nonisolated static func predict(_ token: Int32, hidden: MLMultiArray, cell: MLMultiArray, loaded: Loaded) throws -> Prediction {
        let target = try MLMultiArray(shape: [1, 1], dataType: .int32)
        target[0] = NSNumber(value: token)
        let length = try MLMultiArray(shape: [1], dataType: .int32)
        length[0] = 1
        let out = try loaded.predictor.prediction(from: MLDictionaryFeatureProvider(dictionary: [
            "targets": target, "target_length": length, "states_1": hidden, "cell_state_in": cell,
        ]))
        guard let raw = out.featureValue(for: "outputs")?.multiArrayValue,
              let newHidden = out.featureValue(for: "states")?.multiArrayValue,
              let newCell = out.featureValue(for: "cell_state_out")?.multiArrayValue else { throw Failure.damaged }
        let step = try MLMultiArray(shape: [1, 1, 640], dataType: .float32)
        let values = Floats(raw).all
        values.withUnsafeBufferPointer {
            step.dataPointer.assumingMemoryBound(to: Float.self).update(from: $0.baseAddress!, count: 640)
        }
        let joined = try loaded.jointPredictor.prediction(from: MLDictionaryFeatureProvider(dictionary: ["input": step]))
        guard let output = joined.featureValue(for: "output")?.multiArrayValue else { throw Failure.damaged }
        return Prediction(output: Floats(output).all, hidden: newHidden, cell: newCell)
    }

    /// Word pieces into words: a piece starting with "▁" starts a new word.
    private nonisolated static func words(_ tokens: [(id: Int, step: Int)], vocab: [String]) -> [Word] {
        var out: [Word] = []
        for token in tokens {
            let piece = vocab[token.id]
            let start = Double(token.step) * Self.stepSeconds
            let end = start + Self.stepSeconds
            if piece.hasPrefix("\u{2581}") || out.isEmpty {
                let text = String(piece.drop { $0 == "\u{2581}" })
                out.append(Word(text: text, start: start, end: end))
            } else {
                out[out.count - 1].text += piece
                out[out.count - 1].end = end
            }
        }
        return out.filter { !$0.text.isEmpty }
    }
}

// MARK: - The front end

/// NeMo's log-mel front end, as the model was trained with it: pre-emphasis 0.97, a 512-point
/// FFT every 10 ms over a 25 ms Hann window, 80 mel bands, a log, then each band normalised
/// over the stretch. Checked against the package's TorchScript preprocessor on 13 Oct 2026:
/// the largest difference was 5e-6.
///
/// The constants file is `IASRPC01`, four Int32 (n_fft 512, window 400, bins 257, bands 80),
/// three Float32 (pre-emphasis, log guard, std guard), the window, then the filterbank band
/// by band.
struct FrontEnd: Sendable {
    private let fftSize = 512
    private let hop = 160
    private let bins = 257
    private let bands = 80
    private let window: [Float]
    private let filters: [Float]
    private let preEmphasis: Float
    private let logGuard: Float
    private let stdGuard: Float

    init(_ data: Data) throws {
        guard data.count >= 36, String(data: data.prefix(8), encoding: .ascii) == "IASRPC01" else {
            throw TamilSpeech.Failure.damaged
        }
        func int(_ offset: Int) -> Int { Int(data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: Int32.self) }) }
        func float(_ offset: Int) -> Float { data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: Float.self) } }
        func floats(_ offset: Int, _ count: Int) -> [Float] {
            (0..<count).map { float(offset + 4 * $0) }
        }
        guard int(8) == fftSize, int(16) == bins, int(20) == bands else { throw TamilSpeech.Failure.damaged }
        let windowLength = int(12)
        guard data.count == 36 + 4 * (windowLength + bins * bands) else { throw TamilSpeech.Failure.damaged }
        preEmphasis = float(24)
        logGuard = float(28)
        stdGuard = float(32)
        // The window sits in the middle of the FFT frame, zero on either side.
        var padded = [Float](repeating: 0, count: fftSize)
        let left = (fftSize - windowLength) / 2
        for (index, value) in floats(36, windowLength).enumerated() { padded[left + index] = value }
        window = padded
        filters = floats(36 + 4 * windowLength, bins * bands)
    }

    /// Band-major features, `bands` rows of `frames` values, and the frame count.
    func features(_ samples: [Float]) -> (values: [Float], frames: Int) {
        let count = samples.count
        let frames = count / hop + 1

        // Pre-emphasis, then reflect half an FFT frame onto each end.
        // Plain loops here and below would cost seconds a meeting in a debug build, which is
        // what `make install` makes; vDSP is fast in either.
        var emphasised = [Float](repeating: 0, count: count)
        emphasised[0] = samples[0]
        samples.withUnsafeBufferPointer { x in
            emphasised.withUnsafeMutableBufferPointer { y in
                var minus = -preEmphasis
                vDSP_vsma(x.baseAddress!, 1, &minus, x.baseAddress! + 1, 1, y.baseAddress! + 1, 1, vDSP_Length(count - 1))
            }
        }
        let half = fftSize / 2
        var signal = [Float](repeating: 0, count: count + fftSize)
        signal.withUnsafeMutableBufferPointer { target in
            emphasised.withUnsafeBufferPointer { target.baseAddress!.advanced(by: half).update(from: $0.baseAddress!, count: count) }
        }
        for index in 0..<half {
            signal[half - 1 - index] = emphasised[min(count - 1, index + 1)]
            signal[half + count + index] = emphasised[max(0, count - 2 - index)]
        }

        // Power spectrum, frame by frame.
        let log2n = vDSP_Length(9)
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return ([], 0) }
        defer { vDSP_destroy_fftsetup(setup) }
        var power = [Float](repeating: 0, count: frames * bins)
        var frame = [Float](repeating: 0, count: fftSize)
        var real = [Float](repeating: 0, count: half)
        var imaginary = [Float](repeating: 0, count: half)
        for index in 0..<frames {
            signal.withUnsafeBufferPointer { buffer in
                vDSP_vmul(buffer.baseAddress! + index * hop, 1, window, 1, &frame, 1, vDSP_Length(fftSize))
            }
            real.withUnsafeMutableBufferPointer { realBuffer in
                imaginary.withUnsafeMutableBufferPointer { imaginaryBuffer in
                    var split = DSPSplitComplex(realp: realBuffer.baseAddress!, imagp: imaginaryBuffer.baseAddress!)
                    frame.withUnsafeBufferPointer { frameBuffer in
                        frameBuffer.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) {
                            vDSP_ctoz($0, 2, &split, 1, vDSP_Length(half))
                        }
                    }
                    vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                }
            }
            // zrip doubles every bin and packs the Nyquist bin into imaginary[0].
            let row = index * bins
            let dc = real[0] / 2, nyquist = imaginary[0] / 2
            real.withUnsafeMutableBufferPointer { realBuffer in
                imaginary.withUnsafeMutableBufferPointer { imaginaryBuffer in
                    var split = DSPSplitComplex(realp: realBuffer.baseAddress!, imagp: imaginaryBuffer.baseAddress!)
                    power.withUnsafeMutableBufferPointer { out in
                        vDSP_zvmags(&split, 1, out.baseAddress! + row, 1, vDSP_Length(half))
                        var quarter: Float = 0.25
                        vDSP_vsmul(out.baseAddress! + row, 1, &quarter, out.baseAddress! + row, 1, vDSP_Length(half))
                    }
                }
            }
            power[row] = dc * dc
            power[row + half] = nyquist * nyquist
        }

        // Mel bands: filters (bands x bins) times power transposed (bins x frames).
        var mel = [Float](repeating: 0, count: bands * frames)
        vDSP_mmul(filters, 1, transposed(power, rows: frames, columns: bins), 1, &mel, 1,
                  vDSP_Length(bands), vDSP_Length(frames), vDSP_Length(bins))
        var guardValue = logGuard
        var total = Int32(mel.count)
        mel.withUnsafeMutableBufferPointer { values in
            vDSP_vsadd(values.baseAddress!, 1, &guardValue, values.baseAddress!, 1, vDSP_Length(values.count))
            vvlogf(values.baseAddress!, values.baseAddress!, &total)
        }

        // Each band to zero mean and unit spread over the stretch.
        mel.withUnsafeMutableBufferPointer { values in
            for band in 0..<bands {
                let row = values.baseAddress! + band * frames
                var mean: Float = 0
                vDSP_meanv(row, 1, &mean, vDSP_Length(frames))
                var negative = -mean
                vDSP_vsadd(row, 1, &negative, row, 1, vDSP_Length(frames))
                var spread: Float = 0
                vDSP_svesq(row, 1, &spread, vDSP_Length(frames))
                var divisor = sqrt(max(spread / Float(max(1, frames - 1)), 5.9604644775390625e-08)) + stdGuard
                vDSP_vsdiv(row, 1, &divisor, row, 1, vDSP_Length(frames))
            }
        }
        return (mel, frames)
    }

    private func transposed(_ values: [Float], rows: Int, columns: Int) -> [Float] {
        var out = [Float](repeating: 0, count: values.count)
        vDSP_mtrans(values, 1, &out, 1, vDSP_Length(columns), vDSP_Length(rows))
        return out
    }
}

// MARK: - Reading model outputs

/// A CoreML output read as Float whatever it was stored as, honouring its strides.
struct Floats {
    private let array: MLMultiArray

    init(_ array: MLMultiArray) { self.array = array }

    /// Every value in order, for small outputs with one meaningful axis.
    var all: [Float] {
        let count = array.count
        switch array.dataType {
        case .float32:
            let pointer = array.dataPointer.assumingMemoryBound(to: Float.self)
            if isContiguous { return Array(UnsafeBufferPointer(start: pointer, count: count)) }
        case .float16:
            if isContiguous {
                var out = [Float](repeating: 0, count: count)
                var source = vImage_Buffer(data: array.dataPointer, height: 1, width: vImagePixelCount(count), rowBytes: count * 2)
                out.withUnsafeMutableBufferPointer { target in
                    var destination = vImage_Buffer(
                        data: target.baseAddress!, height: 1, width: vImagePixelCount(count), rowBytes: count * 4)
                    vImageConvert_Planar16FtoPlanarF(&source, &destination, 0)
                }
                return out
            }
        default:
            break
        }
        return (0..<count).map { array[$0].floatValue }
    }

    private var isContiguous: Bool {
        var expected = 1
        for axis in (0..<array.shape.count).reversed() {
            if array.shape[axis].intValue > 1, array.strides[axis].intValue != expected { return false }
            expected *= array.shape[axis].intValue
        }
        return true
    }

    subscript(a: Int, b: Int, c: Int) -> Float {
        let offset = a * array.strides[0].intValue + b * array.strides[1].intValue + c * array.strides[2].intValue
        switch array.dataType {
        case .float32: return array.dataPointer.assumingMemoryBound(to: Float.self)[offset]
        case .float16: return Float(array.dataPointer.assumingMemoryBound(to: Float16.self)[offset])
        default: return array[[NSNumber(value: a), NSNumber(value: b), NSNumber(value: c)]].floatValue
        }
    }
}
