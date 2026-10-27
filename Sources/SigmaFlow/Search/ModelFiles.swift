import CryptoKit
import Foundation

/// Where the search models live and how they arrive: pinned files, downloaded once into
/// `Application Support/SigmaFlow/Models/`, the same way the Tamil model is. A folder counts
/// only once every file is in and its `ready` mark is written, so a download cut off half way
/// is simply done again.
enum ModelFiles {
    static var root: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SigmaFlow/Models", isDirectory: true)
    }

    enum Failure: LocalizedError {
        case download(String)
        case checksum(String)

        var errorDescription: String? {
            switch self {
            case .download(let file): "Couldn't download \(file)."
            case .checksum(let file): "\(file) arrived damaged."
            }
        }
    }

    static func isReady(_ folder: URL) -> Bool {
        FileManager.default.fileExists(atPath: folder.appendingPathComponent("ready").path)
    }

    static func markReady(_ folder: URL) throws {
        try Data().write(to: folder.appendingPathComponent("ready"))
    }

    /// Files of one Hugging Face repository at a pinned revision, into `folder`, keeping their
    /// paths. Files already there from an earlier, interrupted attempt are kept.
    static func fetch(repo: String, revision: String, files: [String], into folder: URL) async throws {
        let fm = FileManager.default
        for file in files {
            let target = folder.appendingPathComponent(file)
            if fm.fileExists(atPath: target.path) { continue }
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try await fetch(URL(string: "https://huggingface.co/\(repo)/resolve/\(revision)/\(file)")!, to: target)
        }
    }

    /// One file, moved into place inside the completion handler, the only place the
    /// temporary file still exists. A partial file never sits at `target`.
    static func fetch(_ url: URL, to target: URL, sha256: String? = nil) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let task = URLSession.shared.downloadTask(with: url) { temporary, response, error in
                guard let temporary, (response as? HTTPURLResponse)?.statusCode == 200 else {
                    continuation.resume(throwing: error ?? Failure.download(url.lastPathComponent))
                    return
                }
                do {
                    if let sha256 {
                        let data = try Data(contentsOf: temporary, options: .alwaysMapped)
                        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                        guard digest == sha256 else { throw Failure.checksum(url.lastPathComponent) }
                    }
                    try? FileManager.default.removeItem(at: target)
                    try FileManager.default.moveItem(at: temporary, to: target)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
            task.resume()
        }
    }
}
