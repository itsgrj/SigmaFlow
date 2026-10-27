import AppKit
import SwiftUI

/// IBM Carbon icons, from the SVGs bundled in Resources/Icons, drawn as template images so
/// they take whatever foreground colour the surrounding text has.
///
/// Every icon in the app comes through here. The name is Carbon's own file name, e.g.
/// `text--align--left`, `trash-can`, `checkmark`. A missing file draws nothing rather than
/// crashing, and logs once, so a typo shows up in Console instead of the UI.
struct CarbonIcon: View {
    let name: String
    var size: CGFloat = 16

    var body: some View {
        if let image = CarbonIconCache.image(named: name) {
            Image(nsImage: image)
                .renderingMode(.template)
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
        } else {
            Color.clear.frame(width: size, height: size)
        }
    }
}

@MainActor
enum CarbonIconCache {
    private static var cache: [String: NSImage] = [:]
    private static var missing: Set<String> = []

    static func image(named name: String) -> NSImage? {
        if let cached = cache[name] { return cached }
        guard !missing.contains(name) else { return nil }
        guard let url = Bundle.main.resourceURL?
                .appendingPathComponent("Icons", isDirectory: true)
                .appendingPathComponent("\(name).svg"),
              let image = NSImage(contentsOf: url)
        else {
            missing.insert(name)
            Log.app.error("Carbon icon missing: \(name, privacy: .public).svg")
            return nil
        }
        // Template: macOS uses the alpha as a mask and tints with the current colour.
        image.isTemplate = true
        image.size = NSSize(width: 32, height: 32)
        cache[name] = image
        return image
    }

    /// For AppKit call sites that need an NSImage sized for a menu bar or button.
    static func nsImage(named name: String, size: CGFloat) -> NSImage? {
        guard let source = image(named: name) else { return nil }
        let copy = source.copy() as! NSImage
        copy.size = NSSize(width: size, height: size)
        copy.isTemplate = true
        return copy
    }
}
