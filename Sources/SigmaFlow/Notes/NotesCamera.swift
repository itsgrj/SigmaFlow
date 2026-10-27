import AVFoundation
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The camera for live notes: a photo every 30 seconds while it is on
/// (docs/mockups/live-notes.html, Gokul's picks 16 Oct 2026).
///
/// The camera runs the whole time it is on, so its green light is honest about it; between
/// photos nothing is kept. Each photo is made small (960 px on its long side, JPEG) and
/// written straight into the session's staging folder, so an hour of notes is a few MB.
final class NotesCamera: @unchecked Sendable {
    /// The long side of a saved photo, in pixels.
    private static let longSide = 960
    private static let quality = 0.7

    private let queue = DispatchQueue(label: "com.grj.sigmaflow.notes-camera")
    private var session: AVCaptureSession?
    private var output: AVCapturePhotoOutput?
    /// One capture's delegate, held until it reports.
    private var pending: [Int64: Capture] = [:]

    static var isAllowed: Bool { AVCaptureDevice.authorizationStatus(for: .video) == .authorized }

    /// Asks the first time; true when the camera may be used.
    static func requestAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: true
        case .notDetermined: await AVCaptureDevice.requestAccess(for: .video)
        default: false
        }
    }

    /// Turns the camera on. Does nothing without permission or without a camera.
    func start() {
        queue.async { [self] in
            guard session == nil, Self.isAllowed,
                  let device = AVCaptureDevice.default(for: .video),
                  let input = try? AVCaptureDeviceInput(device: device) else { return }
            let session = AVCaptureSession()
            session.beginConfiguration()
            session.sessionPreset = .high
            let output = AVCapturePhotoOutput()
            guard session.canAddInput(input), session.canAddOutput(output) else { return }
            session.addInput(input)
            session.addOutput(output)
            session.commitConfiguration()
            session.startRunning()
            self.session = session
            self.output = output
            Log.meetings.info("notes: camera on")
        }
    }

    func stop() {
        queue.async { [self] in
            session?.stopRunning()
            session = nil
            output = nil
            Log.meetings.info("notes: camera off")
        }
    }

    /// Takes one photo into `url`. False when the camera is off or the photo failed.
    func capture(to url: URL) async -> Bool {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                guard let session, session.isRunning, let output else {
                    continuation.resume(returning: false)
                    return
                }
                let settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
                let id = settings.uniqueID
                // Held in `pending` until it reports, then let go.
                let capture = Capture(url: url) { ok in
                    self.queue.async { self.pending[id] = nil }
                    continuation.resume(returning: ok)
                }
                pending[id] = capture
                output.capturePhoto(with: settings, delegate: capture)
            }
        }
    }

    /// Writes a photo small: the long side at `longSide`, as JPEG.
    fileprivate static func write(_ data: Data, to url: URL) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: longSide,
              ] as CFDictionary),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
        else { return false }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        return CGImageDestinationFinalize(destination)
    }

    private final class Capture: NSObject, AVCapturePhotoCaptureDelegate, @unchecked Sendable {
        let url: URL
        let done: (Bool) -> Void

        init(url: URL, done: @escaping (Bool) -> Void) {
            self.url = url
            self.done = done
        }

        func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
            guard error == nil, let data = photo.fileDataRepresentation() else {
                Log.meetings.error("notes: photo failed: \(error?.localizedDescription ?? "no data", privacy: .public)")
                done(false)
                return
            }
            done(NotesCamera.write(data, to: url))
        }
    }
}
