import AppKit
import CoreGraphics
import Foundation
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

/// Screenshots for live notes (docs/mockups/live-notes.html, Gokul's picks 16 Oct 2026):
/// the whole screen the pointer is on, with SigmaFlow's own windows left out, so a
/// screenshot shows what was being shown and never the notes card over it.
///
/// Saved as JPEG at most 1920 px on the long side: a PNG of a Retina screen is several MB,
/// and with one every 15 seconds an hour would run past a gigabyte.
enum NotesScreen {
    private static let longSide = 1920
    private static let quality = 0.8
    /// A screenshot this alike to the last one is not kept (every 15 s only).
    private static let sameScreen = 2.0
    private static let printSize = (width: 32, height: 20)

    /// Screen Recording, which macOS asks for once.
    static var isAllowed: Bool { CGPreflightScreenCaptureAccess() }

    /// Opens the system's ask the first time; true only once it is allowed.
    @discardableResult
    static func requestAccess() -> Bool { CGRequestScreenCaptureAccess() }

    /// A thumbnail-sized grey copy, to tell a changed screen from an unchanged one.
    typealias Print = [UInt8]

    /// Takes a screenshot into `url`. With `unlessSameAs`, a screen that hasn't changed
    /// since that print is not saved. Returns whether it was saved, and the new print.
    static func capture(to url: URL, unlessSameAs previous: Print? = nil) async -> (saved: Bool, print: Print?) {
        guard isAllowed, let image = await image() else { return (false, previous) }
        let print = Self.print(of: image)
        if let previous, let print, difference(previous, print) < sameScreen { return (false, previous) }
        return (write(image, to: url), print)
    }

    /// The screen the pointer is on, SigmaFlow's windows left out. Autowrite reads it too.
    static func image() async -> CGImage? {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            let screen = await MainActor.run { () -> (id: CGDirectDisplayID, scale: CGFloat)? in
                let mouse = NSEvent.mouseLocation
                let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
                guard let screen, let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
                else { return nil }
                return (CGDirectDisplayID(number.uint32Value), screen.backingScaleFactor)
            }
            guard let screen, let display = content.displays.first(where: { $0.displayID == screen.id }) ?? content.displays.first
            else { return nil }
            let ours = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
            let filter = SCContentFilter(display: display, excludingApplications: ours, exceptingWindows: [])
            let config = SCStreamConfiguration()
            let width = Double(display.width) * screen.scale, height = Double(display.height) * screen.scale
            let shrink = min(1, Double(longSide) / max(width, height))
            config.width = Int(width * shrink)
            config.height = Int(height * shrink)
            config.showsCursor = false
            return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        } catch {
            Log.meetings.error("notes: screenshot failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private static func write(_ image: CGImage, to url: URL) -> Bool {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
        else { return false }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        return CGImageDestinationFinalize(destination)
    }

    private static func print(of image: CGImage) -> Print? {
        let (width, height) = printSize
        var pixels = Print(repeating: 0, count: width * height)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? pixels : nil
    }

    /// The mean difference between two prints, 0 to 255.
    private static func difference(_ a: Print, _ b: Print) -> Double {
        guard a.count == b.count, !a.isEmpty else { return .infinity }
        let total = zip(a, b).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) }
        return Double(total) / Double(a.count)
    }
}
