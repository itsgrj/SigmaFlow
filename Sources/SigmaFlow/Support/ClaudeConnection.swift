import AppKit
import Foundation
import Observation

/// Wires SigmaFlow's dictations, meetings and conversations into Claude Desktop.
///
/// Claude Desktop launches local programs that answer its questions over MCP; SigmaFlow's is
/// the helper inside this app. No account, no upload, no network: Claude reads the files on
/// this Mac only when a question asks for them.
///
/// Since 23 Oct 2026 (docs/mockups/ask-claude.html, picks 1B 2A 3C 4C) SigmaFlow joins Claude
/// as an extension. Connect writes a small `.mcpb` pointing at the helper in this copy of the
/// app and hands it to Claude, which comes to the front with its own Install box; Install
/// connects at once, with no restart (tested 21 Oct 2026 on Claude 2.42304.2, open for weeks).
/// The earlier way, an entry in `claude_desktop_config.json`, is read only when Claude starts,
/// and nobody quits Claude (Gokul). An install that still has that entry counts as connected,
/// and the entry comes out once the extension is in, or Claude lists every tool twice.
@MainActor @Observable
final class ClaudeConnection {
    static let shared = ClaudeConnection()

    enum Status: Equatable {
        case connected
        case notConnected
        case claudeNotInstalled
        case failed(String)
    }

    private(set) var status: Status = .notConnected

    /// After the file is handed over: look again this often, for this long, for the install.
    private static let watchEvery: Duration = .seconds(1)
    private static let watchFor = 600

    private var watch: Task<Void, Never>?
    private var activationObserver: NSObjectProtocol?

    private init() {
        refresh()
        // Installed or removed in Claude while SigmaFlow was behind it.
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in ClaudeConnection.shared.refresh() }
        }
    }

    /// The helper that speaks MCP, shipped inside the app bundle.
    static var helperURL: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/sigmaflow-mcp")
    }

    // MARK: Where Claude keeps things

    private static let claudeBundleID = "com.anthropic.claudefordesktop"
    /// Claude names a local extension `local.mcpb.<author>.<name>`, both lowercased.
    private static let extensionID = "local.mcpb.sigmaflow.sigmaflow"

    private static var claudeAppURL: URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: claudeBundleID)
    }

    private static var claudeSupport: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Claude", isDirectory: true)
    }

    private static var configURL: URL { claudeSupport.appendingPathComponent("claude_desktop_config.json") }
    private static var installationsURL: URL { claudeSupport.appendingPathComponent("extensions-installations.json") }
    private static var extensionSettingsURL: URL {
        claudeSupport.appendingPathComponent("Claude Extensions Settings", isDirectory: true)
            .appendingPathComponent("\(extensionID).json")
    }

    /// The `.mcpb` handed to Claude, rewritten on every Connect so it always points here.
    private static var extensionFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SigmaFlow", isDirectory: true)
            .appendingPathComponent("Claude", isDirectory: true)
    }

    // MARK: Status

    func refresh() {
        let now = Self.currentStatus()
        // A failure stays on screen until the next try, not until the next look.
        if case .failed = status, now == .notConnected { return }
        status = now
    }

    private static func currentStatus() -> Status {
        guard claudeAppURL != nil else { return .claudeNotInstalled }
        if extensionPointsHere {
            removeConfigEntry()
            return .connected
        }
        return configEntryPointsHere ? .connected : .notConnected
    }

    /// Installed, switched on in Claude, and launching this copy of the app. A path to an old
    /// copy is worse than nothing: Claude keeps trying to launch what isn't there.
    private static var extensionPointsHere: Bool {
        guard let data = try? Data(contentsOf: installationsURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let extensions = json["extensions"] as? [String: Any],
              let entry = extensions[extensionID] as? [String: Any],
              let manifest = entry["manifest"] as? [String: Any],
              let server = manifest["server"] as? [String: Any],
              let config = server["mcp_config"] as? [String: Any],
              let command = config["command"] as? String,
              command == helperURL.path
        else { return false }
        if let data = try? Data(contentsOf: extensionSettingsURL),
           let settings = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           settings["isEnabled"] as? Bool == false {
            return false
        }
        return true
    }

    private static var configEntryPointsHere: Bool {
        guard let servers = readConfig()["mcpServers"] as? [String: Any],
              let entry = servers["sigmaflow"] as? [String: Any],
              let command = entry["command"] as? String
        else { return false }
        return command == helperURL.path
    }

    // MARK: Connecting

    /// Hands SigmaFlow to Claude, which shows its own Install box; the install is picked up
    /// within a second of the click.
    func connect() {
        guard let app = Self.claudeAppURL else {
            status = .claudeNotInstalled
            return
        }
        guard FileManager.default.fileExists(atPath: Self.helperURL.path) else {
            status = .failed("The helper is missing from the app bundle. Rebuild SigmaFlow and try again.")
            return
        }
        do {
            let file = try Self.writeExtension()
            handToClaude(file, app: app)
            watchUntil { $0 == .connected }
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    /// Takes out the old settings-file entry, and opens Claude's page for the extension,
    /// where its Uninstall is: SigmaFlow doesn't edit Claude's list of extensions behind it.
    func disconnect() {
        Self.removeConfigEntry()
        if Self.extensionPointsHere, let app = Self.claudeAppURL, let file = try? Self.writeExtension() {
            handToClaude(file, app: app)
            watchUntil { $0 != .connected }
        }
        status = Self.currentStatus()
    }

    private func handToClaude(_ file: URL, app: URL) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open([file], withApplicationAt: app, configuration: configuration) { _, error in
            guard let error else { return }
            let message = error.localizedDescription
            Task { @MainActor in ClaudeConnection.shared.status = .failed(message) }
        }
        Log.app.info("handed \(file.path, privacy: .public) to Claude Desktop")
    }

    private func watchUntil(_ done: @escaping (Status) -> Bool) {
        watch?.cancel()
        watch = Task { @MainActor in
            for _ in 0..<Self.watchFor {
                try? await Task.sleep(for: Self.watchEvery)
                guard !Task.isCancelled else { return }
                let now = Self.currentStatus()
                if done(now) {
                    status = now
                    return
                }
            }
        }
    }

    // MARK: Asking

    /// A new chat in Claude, in Chat, with nothing typed in: text typed in from outside puts a
    /// red caution banner over Claude's box (tested 21 Oct 2026), so the question goes on the
    /// clipboard instead.
    func ask(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        guard let url = URL(string: "claude://claude.ai/new?surface=chat") else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: The extension file

    private static func writeExtension() throws -> URL {
        let fm = FileManager.default
        let staging = extensionFolder.appendingPathComponent("SigmaFlow", isDirectory: true)
        let file = extensionFolder.appendingPathComponent("SigmaFlow.mcpb")
        try? fm.removeItem(at: staging)
        try? fm.removeItem(at: file)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)

        let helper = helperURL.path
        var manifest: [String: Any] = [
            "manifest_version": "0.4",
            "name": "sigmaflow",
            "display_name": "SigmaFlow",
            "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0",
            "description": "Ask Claude about your meetings, conversations and dictations.",
            "long_description": longDescription,
            "tools": tools.map { ["name": $0.0, "description": $0.1] },
            "author": ["name": "SigmaFlow"],
            "server": [
                "type": "binary",
                "entry_point": helper,
                "mcp_config": ["command": helper, "args": [String]()],
            ],
            "compatibility": ["claude_desktop": ">=0.1.0", "platforms": ["darwin"]],
            "tools_generated": true,
        ]
        if let icon = iconPNG() {
            try icon.write(to: staging.appendingPathComponent("icon.png"))
            manifest["icon"] = "icon.png"
        }
        // Figma 3.24 cropped to the page: a made-up meeting, so no one's recordings ship in it.
        if let shot = Bundle.main.url(forResource: "screenshot-meeting", withExtension: "png", subdirectory: "ClaudeExtension") {
            try fm.copyItem(at: shot, to: staging.appendingPathComponent("screenshot-meeting.png"))
            manifest["screenshots"] = ["screenshot-meeting.png"]
        }
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: staging.appendingPathComponent("manifest.json"))

        // An .mcpb is a zip with manifest.json at its root.
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        zip.arguments = ["-c", "-k", "--norsrc", staging.path, file.path]
        try zip.run()
        zip.waitUntilExit()
        guard zip.terminationStatus == 0 else {
            throw NSError(domain: "SigmaFlow", code: Int(zip.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: "Could not make the file for Claude."])
        }
        return file
    }

    /// Claude's Install box carries a red note SigmaFlow can't change; the words under it are
    /// ours, and say plainly what Claude gets (Gokul, 23 Oct 2026: the box alone read as scary;
    /// Figma 3.22a). Markdown. Keep it true to SigmaFlowMCP: read-only, on this Mac.
    private static let longDescription = """
        Ask Claude about anything SigmaFlow wrote down for you: what a meeting decided, who said they’d do what, what was on a screenshot, something you dictated last week.

        **What Claude can read**

        - Your meetings and conversations, with their photos and screenshots
        - Your dictations

        **What SigmaFlow lets it do**

        - Read and search them. Nothing else: SigmaFlow can’t change, delete or send anything for Claude.
        - SigmaFlow’s part stays on this Mac and never goes online. What Claude reads goes into your chat with Claude, like anything you paste in.

        **About the red note above**

        SigmaFlow isn’t in Claude’s directory yet, so Claude can’t vouch for it. SigmaFlow’s part runs on your Mac like the app itself, and does only what’s listed here.
        """

    /// SigmaFlowMCP's tools, in the words Claude's box lists them in.
    private static let tools: [(String, String)] = [
        ("list_recordings", "Lists your meetings and conversations"),
        ("search_recordings", "Finds the moments where something was said"),
        ("read_recording", "Reads a meeting or conversation"),
        ("get_pictures", "Looks at a recording’s photos and screenshots"),
        ("search_transcripts", "Finds something you dictated"),
        ("recent_transcripts", "Reads your latest dictations"),
    ]

    /// The app icon for Claude's Install box and its list of extensions.
    private static func iconPNG() -> Data? {
        let side = 512
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0)
        else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSApp.applicationIconImage.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }

    // MARK: The old settings-file entry

    /// Removes only our entry. Anything else the user has connected stays untouched.
    private static func removeConfigEntry() {
        var config = readConfig()
        guard var servers = config["mcpServers"] as? [String: Any], servers["sigmaflow"] != nil else { return }
        servers.removeValue(forKey: "sigmaflow")
        config["mcpServers"] = servers
        guard let data = try? JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys])
        else { return }
        try? data.write(to: configURL, options: .atomic)
        Log.app.info("took SigmaFlow out of claude_desktop_config.json")
    }

    private static func readConfig() -> [String: Any] {
        guard let data = try? Data(contentsOf: configURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return json
    }
}
