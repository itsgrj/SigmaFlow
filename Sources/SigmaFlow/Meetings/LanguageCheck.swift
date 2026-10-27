import CoreML
import Foundation

/// How likely a stretch of a meeting is to be Tamil.
///
/// SpeechBrain's VoxLingua107 ECAPA (Apache 2.0), 107 languages, converted to CoreML on
/// 13 Oct 2026 and shipped inside the app as `Resources/LanguageCheck/LanguageID.mlpackage` (41 MB,
/// float16; 8-bit weights halved it but changed 2 of 133 calls). Sound in, 107 log
/// probabilities out.
///
/// It hears Tamil well (0.98 and up on clear Tamil) and never hears Indian-accented English
/// as English: it guesses Telugu, Kannada, even Welsh. So it only answers "is this Tamil";
/// whether a stretch is English is Parakeet's confidence (`MeetingProcessor`).
actor LanguageCheck {
    static let shared = LanguageCheck()

    /// Positions in the model's label list.
    private static let tamil = 91
    private static let shortest = TamilSpeech.sampleRate
    private static let longest = TamilSpeech.sampleRate * 12

    private var model: MLModel?

    enum Failure: LocalizedError {
        case missing
        var errorDescription: String? { "The language check is missing from SigmaFlow." }
    }

    /// Compiled once per launch from the package inside the app.
    private func loaded() async throws -> MLModel {
        if let model { return model }
        guard let package = Bundle.main.resourceURL?.appendingPathComponent("LanguageCheck/LanguageID.mlpackage"),
              FileManager.default.fileExists(atPath: package.path) else { throw Failure.missing }
        let compiled = try await MLModel.compileModel(at: package)
        let config = MLModelConfiguration()
        // The pooling step's shape follows the input's length, which the GPU path refuses;
        // on the CPU it is also the fastest, 133 stretches in 1.8 s.
        config.computeUnits = .cpuOnly
        let loaded = try MLModel(contentsOf: compiled, configuration: config)
        model = loaded
        return loaded
    }

    /// 0 to 1. A stretch under a second is padded with silence; one over 12 s is cut.
    func tamilChance(_ samples: [Float]) async throws -> Double {
        let model = try await loaded()
        let count = min(max(samples.count, Self.shortest), Self.longest)
        let input = try MLMultiArray(shape: [1, NSNumber(value: count)], dataType: .float32)
        let pointer = input.dataPointer.assumingMemoryBound(to: Float.self)
        pointer.initialize(repeating: 0, count: count)
        for index in 0..<min(samples.count, count) { pointer[index] = samples[index] }
        // A pool, so each call's output buffers go when it ends (see TamilSpeech.hear).
        let logs = try autoreleasepool { () throws -> [Double] in
            let out = try Self.predict(model, ["audio": input])
            guard let scores = out.featureValue(for: "logprobs")?.multiArrayValue else { return [] }
            return Floats(scores).all.map(Double.init)
        }
        guard logs.count > Self.tamil else { return 0 }
        let top = logs.max() ?? 0
        let total = logs.map { exp($0 - top) }.reduce(0, +)
        return exp(logs[Self.tamil] - top) / total
    }

    /// The synchronous prediction, on the actor's own thread.
    private static func predict(_ model: MLModel, _ inputs: [String: Any]) throws -> MLFeatureProvider {
        try model.prediction(from: MLDictionaryFeatureProvider(dictionary: inputs))
    }
}
