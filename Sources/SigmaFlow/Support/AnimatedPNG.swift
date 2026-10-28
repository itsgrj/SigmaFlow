import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Writes frames as an animated PNG, which GitHub, every browser and Finder's preview play
/// in a loop. Made for `--readme-frames` (Support/ReadmeFrames.swift).
///
/// ImageIO can write an animated PNG, but every frame whole; a README picture where only
/// the overlay changes would be tens of megabytes. Here each frame after the first is only
/// the rectangle that changed since the one before, and a frame identical to the last just
/// holds the last one longer. ImageIO still does the compression: each rectangle is written
/// as an ordinary PNG and its image data lifted into the animation.
struct AnimatedPNG {
    private struct Frame {
        var image: CGImage
        var milliseconds: Int
    }

    private var frames: [Frame] = []
    private var last: [UInt8] = []
    private let width: Int
    private let height: Int

    /// Every frame must be this size and opaque.
    init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }

    var isEmpty: Bool { frames.isEmpty }

    /// Adds a frame shown for `milliseconds`. A frame the same as the one before only holds
    /// that one longer.
    mutating func add(_ image: CGImage, milliseconds: Int) {
        let pixels = Self.pixels(of: image, width: width, height: height)
        if pixels == last, !frames.isEmpty {
            frames[frames.count - 1].milliseconds += milliseconds
            return
        }
        frames.append(Frame(image: image, milliseconds: milliseconds))
        last = pixels
    }

    /// Holds the last frame a little longer, so the loop rests before it starts again.
    mutating func hold(milliseconds: Int) {
        guard !frames.isEmpty else { return }
        frames[frames.count - 1].milliseconds += milliseconds
    }

    enum Failure: Error { case encode, mismatch }

    func write(to url: URL) throws {
        guard let first = frames.first else { return }
        let full = try Self.chunks(ofPNG: Self.png(first.image))
        guard let header = full.first(where: { $0.type == "IHDR" }) else { throw Failure.encode }

        var out = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        var sequence: UInt32 = 0
        Self.append(chunk: "IHDR", header.body, to: &out)
        // The colour chunks ImageIO wrote (sRGB, ICC, gamma) belong before the animation.
        for chunk in full where ["sRGB", "iCCP", "gAMA", "cHRM", "pHYs"].contains(chunk.type) {
            Self.append(chunk: chunk.type, chunk.body, to: &out)
        }
        var control = Data()
        control.appendBigEndian(UInt32(frames.count))
        control.appendBigEndian(UInt32(0))  // loop for ever
        Self.append(chunk: "acTL", control, to: &out)

        var previous = Self.pixels(of: first.image, width: width, height: height)
        for (index, frame) in frames.enumerated() {
            var rect = CGRect(x: 0, y: 0, width: width, height: height)
            var data: [Data]
            if index == 0 {
                data = full.filter { $0.type == "IDAT" }.map(\.body)
            } else {
                let pixels = Self.pixels(of: frame.image, width: width, height: height)
                rect = Self.changed(from: previous, to: pixels, width: width, height: height)
                previous = pixels
                guard let part = frame.image.cropping(to: rect) else { throw Failure.encode }
                let chunks = try Self.chunks(ofPNG: Self.png(part))
                // The rectangle must be written the way the first frame was, or its bytes
                // would be read wrongly; ImageIO is consistent for one bitmap format.
                guard let partHeader = chunks.first(where: { $0.type == "IHDR" }),
                      partHeader.body.suffix(5) == header.body.suffix(5) else { throw Failure.mismatch }
                data = chunks.filter { $0.type == "IDAT" }.map(\.body)
            }
            var fc = Data()
            fc.appendBigEndian(sequence); sequence += 1
            fc.appendBigEndian(UInt32(rect.width))
            fc.appendBigEndian(UInt32(rect.height))
            fc.appendBigEndian(UInt32(rect.minX))
            fc.appendBigEndian(UInt32(rect.minY))
            fc.appendBigEndian(UInt16(min(frame.milliseconds, Int(UInt16.max))))
            fc.appendBigEndian(UInt16(1000))
            fc.append(0)  // dispose: leave it
            fc.append(0)  // blend: replace
            Self.append(chunk: "fcTL", fc, to: &out)
            for body in data {
                if index == 0 {
                    Self.append(chunk: "IDAT", body, to: &out)
                } else {
                    var fd = Data()
                    fd.appendBigEndian(sequence); sequence += 1
                    fd.append(body)
                    Self.append(chunk: "fdAT", fd, to: &out)
                }
            }
        }
        Self.append(chunk: "IEND", Data(), to: &out)
        try out.write(to: url)
    }

    // MARK: Pixels

    /// RGBA bytes, rows from the top, for comparing frames.
    private static func pixels(of image: CGImage, width: Int, height: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        bytes.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return bytes
    }

    /// The smallest rectangle, top-left origin, holding every pixel that changed. One pixel
    /// when nothing did, which a caller never sees: identical frames were merged on `add`.
    /// Rows are compared whole first, so only the changed band is read pixel by pixel; a
    /// debug build, which `make install` makes, would otherwise take minutes.
    private static func changed(from old: [UInt8], to new: [UInt8], width: Int, height: Int) -> CGRect {
        let stride = width * 4
        return old.withUnsafeBufferPointer { a in
            new.withUnsafeBufferPointer { b in
                let differs = { (y: Int) in memcmp(a.baseAddress! + y * stride, b.baseAddress! + y * stride, stride) != 0 }
                guard let minY = (0..<height).first(where: differs),
                      let maxY = (0..<height).reversed().first(where: differs) else {
                    return CGRect(x: 0, y: 0, width: 1, height: 1)
                }
                var minX = width, maxX = -1
                for y in minY...maxY {
                    let row = y * stride
                    // From each end inward: the changed span is usually narrow.
                    var x = 0
                    while x < minX, memcmp(a.baseAddress! + row + x * 4, b.baseAddress! + row + x * 4, 3) == 0 { x += 1 }
                    minX = min(minX, x)
                    var r = width - 1
                    while r > maxX, memcmp(a.baseAddress! + row + r * 4, b.baseAddress! + row + r * 4, 3) == 0 { r -= 1 }
                    maxX = max(maxX, r)
                }
                return CGRect(x: minX, y: minY, width: max(1, maxX - minX + 1), height: maxY - minY + 1)
            }
        }
    }

    // MARK: PNG chunks

    private struct Chunk {
        let type: String
        let body: Data
    }

    private static func png(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)
        else { throw Failure.encode }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw Failure.encode }
        return data as Data
    }

    private static func chunks(ofPNG data: Data) throws -> [Chunk] {
        let bytes = [UInt8](data)
        var chunks: [Chunk] = []
        var offset = 8
        while offset + 12 <= bytes.count {
            let length = Int(bytes[offset]) << 24 | Int(bytes[offset + 1]) << 16 | Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])
            let type = String(bytes: bytes[(offset + 4)..<(offset + 8)], encoding: .ascii) ?? ""
            guard offset + 12 + length <= bytes.count else { throw Failure.encode }
            chunks.append(Chunk(type: type, body: Data(bytes[(offset + 8)..<(offset + 8 + length)])))
            offset += 12 + length
        }
        return chunks
    }

    private static func append(chunk type: String, _ body: Data, to out: inout Data) {
        out.appendBigEndian(UInt32(body.count))
        let typed = Data(type.utf8) + body
        out.append(typed)
        out.appendBigEndian(crc32(typed))
    }

    private static let crcTable: [UInt32] = (0..<256).map { n in
        var c = UInt32(n)
        for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data { crc = crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
        return crc ^ 0xFFFF_FFFF
    }
}

private extension Data {
    mutating func appendBigEndian<T: FixedWidthInteger>(_ value: T) {
        Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
    }
}
