@preconcurrency import CoreML
import CoreGraphics
import Foundation
import ImageIO

// Google's EmbeddingGemma 2 (Apache 2.0) as Core ML, in FluidInference's copy
// `FluidInference/embeddinggemma-2-coreml`: text and pictures in one 768-number space, so a
// typed "red t-shirt" can be compared with a photo itself, not only with what was written
// about it (Gokul's red t-shirt question, 19 Oct 2026: Gemma's description of one of the two
// red t-shirts never said red; the photos themselves ranked both first).
//
// The text side is adapted from FluidInference/FluidUse (Apache 2.0), EmbeddingGemma2Manager,
// trimmed to what search needs. The picture side follows the model card and Hugging Face's
// Gemma4ImageProcessor; on the 19 Oct test pictures it matches sentence-transformers.

enum EmbeddingGemma2Error: Error, LocalizedError {
    case invalidAsset(String)
    case predictionFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidAsset(let reason): "The search model is damaged: \(reason)"
        case .predictionFailed(let reason): "The search model failed: \(reason)"
        }
    }
}

/// The task prefixes the model was trained with. Lines, descriptions and the words on a
/// picture are documents; what the user types is a query. Pictures take no prefix.
enum EmbeddingGemma2Prompt: Sendable {
    case document
    case searchQuery

    func apply(to text: String) -> String {
        switch self {
        case .document: "title: none | text: \(text)"
        case .searchQuery: "task: search result | query: \(text)"
        }
    }
}

/// Text into vectors on the Neural Engine. The package holds fixed-shape functions sharing one
/// set of weights: `embed_<S>` for one text of up to S tokens, and `pack_256`, eight short texts
/// in one call. The 262k-row token table is read from a memory-mapped bf16 file.
final class EmbeddingGemma2Text: Sendable {
    static let lengths = [32, 48, 64, 128, 256, 512]
    static let hiddenSize = 512
    static let dimension = 768
    static let packLength = 256
    static let packSlots = 8
    static let imageStartId: Int32 = 255_999  // <|image>
    static let imageEndId: Int32 = 258_882  // <image|>

    let tokenizer: EmbeddingGemma2Tokenizer
    private let models: [Int: MLModel]
    private let packModel: MLModel
    private let table: Data
    private let embedScale = Float(hiddenSize).squareRoot()

    /// `directory` holds `EmbeddingGemma2Text.mlmodelc`, `embeddings.bf16` and `tokenizer.json`.
    init(directory: URL) async throws {
        let modelURL = directory.appendingPathComponent("EmbeddingGemma2Text.mlmodelc")
        guard let table = try? Data(contentsOf: directory.appendingPathComponent("embeddings.bf16"), options: .alwaysMapped),
              table.count % (Self.hiddenSize * 2) == 0 else {
            throw EmbeddingGemma2Error.invalidAsset("embeddings.bf16")
        }
        tokenizer = try EmbeddingGemma2Tokenizer(tokenizerJsonURL: directory.appendingPathComponent("tokenizer.json"))
        func function(_ name: String) async throws -> MLModel {
            let configuration = MLModelConfiguration()
            configuration.computeUnits = .cpuAndNeuralEngine
            configuration.functionName = name
            return try await MLModel.load(contentsOf: modelURL, configuration: configuration)
        }
        var models: [Int: MLModel] = [:]
        for length in Self.lengths { models[length] = try await function("embed_\(length)") }
        self.models = models
        packModel = try await function("pack_256")
        self.table = table
    }

    /// Vectors for many texts, in order. Texts that fit are packed eight to a 256-token call,
    /// with up to eight calls in flight (Core ML's async prediction is thread-safe).
    func embed(_ texts: [String], prompt: EmbeddingGemma2Prompt, maxTokens: Int = 256) async throws -> [[Float]] {
        let limit = min(max(maxTokens, 3), Self.lengths.last!)
        let tokenized = texts.map { tokenizer.encode(prompt.apply(to: $0), maxLength: limit) }
        var bins: [[Int]] = []
        var singles: [Int] = []
        var current: [Int] = []
        var used = 0
        for (index, ids) in tokenized.enumerated() {
            guard ids.count <= Self.packLength else {
                singles.append(index)
                continue
            }
            if used + ids.count > Self.packLength || current.count == Self.packSlots {
                bins.append(current)
                current = []
                used = 0
            }
            current.append(index)
            used += ids.count
        }
        if !current.isEmpty { bins.append(current) }
        let jobs: [[Int]] = bins + singles.map { [$0] }
        let packedJobs = bins.count
        return try await withThrowingTaskGroup(of: [(Int, [Float])].self) { group in
            var result = [[Float]](repeating: [], count: texts.count)
            var next = 0
            func addJob() {
                guard next < jobs.count else { return }
                let job = jobs[next]
                let packed = next < packedJobs
                next += 1
                group.addTask {
                    if packed {
                        return zip(job, try await self.embedPacked(job.map { tokenized[$0] })).map { ($0, $1) }
                    }
                    return [(job[0], try await self.embed(ids: tokenized[job[0]]))]
                }
            }
            for _ in 0..<min(8, jobs.count) { addJob() }
            for try await pairs in group {
                for (index, vector) in pairs { result[index] = vector }
                addJob()
            }
            return result
        }
    }

    func embed(_ text: String, prompt: EmbeddingGemma2Prompt) async throws -> [Float] {
        try await embed(ids: tokenizer.encode(prompt.apply(to: text), maxLength: Self.lengths.last!))
    }

    /// A picture's vector: `<bos> <|image> tokens <image|> <eos>` through the text model, where
    /// `tokens` are the first `count` rows of `EmbeddingGemma2Vision`'s output.
    func embed(imageTokens tokens: MLMultiArray, count: Int) async throws -> [Float] {
        let total = count + 4
        guard let length = Self.lengths.first(where: { $0 >= total }) else {
            throw EmbeddingGemma2Error.predictionFailed("\(count) picture tokens do not fit")
        }
        let tokenStride = tokens.strides[tokens.strides.count - 2].intValue
        return try await run(length: length, count: total) { destination in
            writeEmbeddings([tokenizer.bosId, Self.imageStartId], to: destination)
            let target = destination + 2 * Self.hiddenSize
            for row in 0..<count {
                for column in 0..<Self.hiddenSize {
                    let index = row * tokenStride + column
                    target[row * Self.hiddenSize + column] =
                        tokens.dataType == .float16
                        ? tokens.dataPointer.assumingMemoryBound(to: Float16.self)[index]
                        : Float16(tokens.dataPointer.assumingMemoryBound(to: Float.self)[index])
                }
            }
            writeEmbeddings(
                [Self.imageEndId, tokenizer.eosId] + [Int32](repeating: tokenizer.padId, count: length - total),
                to: destination + (2 + count) * Self.hiddenSize)
        }
    }

    /// One `pack_256` call for up to eight token sequences that fit in 256 tokens together.
    private func embedPacked(_ sequences: [[Int32]]) async throws -> [[Float]] {
        let length = Self.packLength
        let embeds = try MLMultiArray(shape: [1, NSNumber(value: length), NSNumber(value: Self.hiddenSize)], dataType: .float16)
        let bias = try MLMultiArray(shape: [1, 1, NSNumber(value: length), NSNumber(value: length)], dataType: .float16)
        let positions = try MLMultiArray(shape: [NSNumber(value: length), 1], dataType: .float16)
        let pool = try MLMultiArray(shape: [NSNumber(value: Self.packSlots), NSNumber(value: length)], dataType: .float16)
        let embedPointer = embeds.dataPointer.assumingMemoryBound(to: Float16.self)
        let biasPointer = bias.dataPointer.assumingMemoryBound(to: Float16.self)
        let positionPointer = positions.dataPointer.assumingMemoryBound(to: Float16.self)
        let poolPointer = pool.dataPointer.assumingMemoryBound(to: Float16.self)
        biasPointer.update(repeating: -10_000, count: length * length)
        positionPointer.update(repeating: 0, count: length)
        poolPointer.update(repeating: 0, count: Self.packSlots * length)
        var offset = 0
        for (slot, ids) in sequences.enumerated() {
            writeEmbeddings(ids, to: embedPointer + offset * Self.hiddenSize)
            let weight = Float16(1 / Float(ids.count))
            for row in offset..<(offset + ids.count) {
                for column in offset..<(offset + ids.count) { biasPointer[row * length + column] = 0 }
                positionPointer[row] = Float16(row - offset)
                poolPointer[slot * length + row] = weight
            }
            offset += ids.count
        }
        // Padding rows attend to themselves so their softmax stays finite; the pool ignores them.
        writeEmbeddings([Int32](repeating: tokenizer.padId, count: length - offset), to: embedPointer + offset * Self.hiddenSize)
        for row in offset..<length { biasPointer[row * length + row] = 0 }
        let input = try MLDictionaryFeatureProvider(dictionary: [
            "inputs_embeds": MLFeatureValue(multiArray: embeds), "attention_bias": MLFeatureValue(multiArray: bias),
            "positions": MLFeatureValue(multiArray: positions), "pool": MLFeatureValue(multiArray: pool),
        ])
        let output = try await packModel.prediction(from: input)
        guard let matrix = output.featureValue(for: "embedding")?.multiArrayValue,
              matrix.count == Self.packSlots * Self.dimension else {
            throw EmbeddingGemma2Error.predictionFailed("missing packed embedding output")
        }
        // [8, 768] or [1, 8, 768]: the row stride is the second-to-last one.
        let rowStride = matrix.strides[matrix.strides.count - 2].intValue
        return (0..<sequences.count).map { slot in
            (0..<Self.dimension).map { column in
                let index = slot * rowStride + column
                return matrix.dataType == .float16
                    ? Float(matrix.dataPointer.assumingMemoryBound(to: Float16.self)[index])
                    : matrix.dataPointer.assumingMemoryBound(to: Float.self)[index]
            }
        }
    }

    /// Token rows (bf16, times √512, as fp16) for `ids`, written contiguously at `destination`.
    private func writeEmbeddings(_ ids: [Int32], to destination: UnsafeMutablePointer<Float16>) {
        let rows = table.count / (Self.hiddenSize * 2)
        table.withUnsafeBytes { raw in
            let bf16 = raw.bindMemory(to: UInt16.self)
            for (position, id) in ids.enumerated() {
                let row = min(max(Int(id), 0), rows - 1) * Self.hiddenSize
                let target = destination + position * Self.hiddenSize
                for column in 0..<Self.hiddenSize {
                    target[column] = Float16(Float(bitPattern: UInt32(bf16[row + column]) << 16) * embedScale)
                }
            }
        }
    }

    private func embed(ids: [Int32]) async throws -> [Float] {
        let padded = ids + [Int32](repeating: tokenizer.padId, count: max(Self.lengths.last!, ids.count) - ids.count)
        let length = Self.lengths.first { $0 >= ids.count } ?? Self.lengths.last!
        return try await run(length: length, count: ids.count) { destination in
            writeEmbeddings(Array(padded.prefix(length)), to: destination)
        }
    }

    /// One `embed_<length>` call: `fill` writes `length` rows of fp16 inputs; the first `count` are attended.
    private func run(length: Int, count: Int, fill: (UnsafeMutablePointer<Float16>) throws -> Void) async throws -> [Float] {
        guard let model = models[length] else { throw EmbeddingGemma2Error.predictionFailed("no model for \(length)") }
        let embeds = try MLMultiArray(shape: [1, NSNumber(value: length), NSNumber(value: Self.hiddenSize)], dataType: .float16)
        let mask = try MLMultiArray(shape: [1, NSNumber(value: length)], dataType: .float16)
        let maskPointer = mask.dataPointer.assumingMemoryBound(to: Float16.self)
        try fill(embeds.dataPointer.assumingMemoryBound(to: Float16.self))
        for position in 0..<length { maskPointer[position] = position < count ? 1 : 0 }
        let input = try MLDictionaryFeatureProvider(dictionary: [
            "inputs_embeds": MLFeatureValue(multiArray: embeds), "attention_mask": MLFeatureValue(multiArray: mask),
        ])
        let output = try await model.prediction(from: input)
        guard let vector = output.featureValue(for: "embedding")?.multiArrayValue, vector.count == Self.dimension else {
            throw EmbeddingGemma2Error.predictionFailed("missing embedding output")
        }
        if vector.dataType == .float16 {
            let pointer = vector.dataPointer.assumingMemoryBound(to: Float16.self)
            return (0..<Self.dimension).map { Float(pointer[$0]) }
        }
        let pointer = vector.dataPointer.assumingMemoryBound(to: Float.self)
        return Array(UnsafeBufferPointer(start: pointer, count: Self.dimension))
    }
}

/// Pictures into tokens in the text model's space, on the GPU (the model card: faster than the
/// Neural Engine at every size, since attention over all patches grows with their square).
/// The 280-token function, the model's default and what the 19 Oct test measured.
final class EmbeddingGemma2Vision: Sendable {
    static let tokens = 280
    static let patchSize = 16
    static let pooling = 3
    static let maxPatches = tokens * pooling * pooling
    static let patchValues = patchSize * patchSize * 3
    static let width = 768

    private let model: MLModel
    /// `position_embeddings.f16`: [2][1024][768], x then y.
    private let positionTable: Data

    /// `directory` holds `EmbeddingGemma2Vision.mlmodelc` and `position_embeddings.f16`.
    init(directory: URL) async throws {
        guard let table = try? Data(contentsOf: directory.appendingPathComponent("position_embeddings.f16"), options: .alwaysMapped),
              table.count == 2 * 1024 * Self.width * 2 else {
            throw EmbeddingGemma2Error.invalidAsset("position_embeddings.f16")
        }
        positionTable = table
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuAndGPU
        configuration.functionName = "vision_\(Self.tokens)"
        model = try await MLModel.load(
            contentsOf: directory.appendingPathComponent("EmbeddingGemma2Vision.mlmodelc"), configuration: configuration)
    }

    /// The largest size that keeps the picture's shape, fits the patch budget, and has sides in
    /// whole 48 px steps (Gemma4ImageProcessor's `get_aspect_ratio_preserving_size`).
    static func targetSize(width: Int, height: Int) -> (width: Int, height: Int) {
        let step = patchSize * pooling
        let factor = (Double(maxPatches * patchSize * patchSize) / Double(width * height)).squareRoot()
        var targetHeight = Int((factor * Double(height) / Double(step)).rounded(.down)) * step
        var targetWidth = Int((factor * Double(width) / Double(step)).rounded(.down)) * step
        let longest = (maxPatches / (pooling * pooling)) * step
        if targetHeight == 0 {
            targetHeight = step
            targetWidth = min(max(1, width / max(height, 1)) * step, longest)
        } else if targetWidth == 0 {
            targetWidth = step
            targetHeight = min(max(1, height / max(width, 1)) * step, longest)
        }
        return (targetWidth, targetHeight)
    }

    /// The picture's tokens and how many of the 280 rows are real.
    func tokens(for url: URL) async throws -> (tokens: MLMultiArray, count: Int) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw EmbeddingGemma2Error.predictionFailed("can't read \(url.lastPathComponent)")
        }
        let (width, height) = Self.targetSize(width: image.width, height: image.height)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw EmbeddingGemma2Error.predictionFailed("can't draw \(url.lastPathComponent)")
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let pixels = context.data?.assumingMemoryBound(to: UInt8.self) else {
            throw EmbeddingGemma2Error.predictionFailed("no pixels")
        }

        let n = Self.maxPatches
        let columns = width / Self.patchSize
        let rows = height / Self.patchSize
        let patches = try MLMultiArray(shape: [1, NSNumber(value: n), NSNumber(value: Self.patchValues)], dataType: .float16)
        let positions = try MLMultiArray(shape: [1, NSNumber(value: n), 2], dataType: .float16)
        let embeddings = try MLMultiArray(shape: [1, NSNumber(value: n), NSNumber(value: Self.width)], dataType: .float16)
        let valid = try MLMultiArray(shape: [1, NSNumber(value: n)], dataType: .float16)
        let pool = try MLMultiArray(shape: [NSNumber(value: Self.tokens), NSNumber(value: n)], dataType: .float16)
        let patchPointer = patches.dataPointer.assumingMemoryBound(to: Float16.self)
        let positionPointer = positions.dataPointer.assumingMemoryBound(to: Float16.self)
        let embeddingPointer = embeddings.dataPointer.assumingMemoryBound(to: Float16.self)
        let validPointer = valid.dataPointer.assumingMemoryBound(to: Float16.self)
        let poolPointer = pool.dataPointer.assumingMemoryBound(to: Float16.self)
        patchPointer.update(repeating: 0, count: n * Self.patchValues)
        positionPointer.update(repeating: -1, count: n * 2)
        embeddingPointer.update(repeating: 0, count: n * Self.width)
        validPointer.update(repeating: 0, count: n)
        poolPointer.update(repeating: 0, count: Self.tokens * n)

        let pooledColumns = columns / Self.pooling
        let weight = Float16(1.0 / Float(Self.pooling * Self.pooling))
        positionTable.withUnsafeBytes { raw in
            let table = raw.bindMemory(to: Float16.self)
            for y in 0..<rows {
                for x in 0..<columns {
                    let patch = y * columns + x
                    // Each patch is [16 rows][16 columns][RGB], scaled to 0...1.
                    let base = patchPointer + patch * Self.patchValues
                    for py in 0..<Self.patchSize {
                        let line = pixels + ((y * Self.patchSize + py) * width + x * Self.patchSize) * 4
                        for px in 0..<Self.patchSize {
                            let at = (py * Self.patchSize + px) * 3
                            base[at] = Float16(Float(line[px * 4]) / 255)
                            base[at + 1] = Float16(Float(line[px * 4 + 1]) / 255)
                            base[at + 2] = Float16(Float(line[px * 4 + 2]) / 255)
                        }
                    }
                    positionPointer[patch * 2] = Float16(Float(x))
                    positionPointer[patch * 2 + 1] = Float16(Float(y))
                    let target = embeddingPointer + patch * Self.width
                    for column in 0..<Self.width {
                        target[column] = Float16(Float(table[x * Self.width + column]) + Float(table[(1024 + y) * Self.width + column]))
                    }
                    validPointer[patch] = 1
                    // Pooled 3 by 3, left to right, then top to bottom.
                    let token = (y / Self.pooling) * pooledColumns + x / Self.pooling
                    poolPointer[token * n + patch] = weight
                }
            }
        }
        let input = try MLDictionaryFeatureProvider(dictionary: [
            "patches": MLFeatureValue(multiArray: patches), "positions": MLFeatureValue(multiArray: positions),
            "position_embeddings": MLFeatureValue(multiArray: embeddings), "valid": MLFeatureValue(multiArray: valid),
            "pool": MLFeatureValue(multiArray: pool),
        ])
        let output = try await model.prediction(from: input)
        guard let tokens = output.featureValue(for: "image_tokens")?.multiArrayValue else {
            throw EmbeddingGemma2Error.predictionFailed("missing picture tokens")
        }
        return (tokens, (rows / Self.pooling) * pooledColumns)
    }
}
