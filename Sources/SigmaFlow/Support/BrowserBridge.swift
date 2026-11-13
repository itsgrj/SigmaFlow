import AppKit
import Darwin
import Foundation
import Observation
import SwiftUI

// SigmaFlow in the browser (docs/mockups/browser-extension.html, picks 01 02 04 07 09,
// 12 Nov 2026). Browsers don't let Accessibility read their text boxes, so in Gmail, Cliq on
// the web or a help desk the correction learner never fired, and Autowrite only had a
// screenshot to read. A Chromium extension (BrowserExtension/) does both from inside the page:
// the text of the box SigmaFlow just typed into, and the page's words while the Autowrite key
// is held. Nothing else, and nothing leaves this Mac.
//
//   extension  <- native messaging ->  sigmaflow-browser  <- unix socket ->  this file
//
// The browser starts the helper (Sources/SigmaFlowBrowserHost) from the manifest written here
// into its NativeMessagingHosts folder; the helper connects to `browser.sock` and relays. One
// connection per browser profile that has the extension.

/// A Chromium browser SigmaFlow's extension runs in. Safari needs an app extension built in
/// Xcode, which SwiftPM can't build; Firefox would need a manifest of its own.
struct KnownBrowser: Identifiable, Hashable, Sendable {
    let id: String  // bundle identifier
    let name: String
    /// Where its native messaging manifests live, under ~/Library/Application Support.
    let hostsFolder: String

    static let all: [KnownBrowser] = [
        KnownBrowser(id: "company.thebrowser.dia", name: "Dia", hostsFolder: "Dia/User Data/NativeMessagingHosts"),
        KnownBrowser(id: "com.google.Chrome", name: "Chrome", hostsFolder: "Google/Chrome/NativeMessagingHosts"),
        KnownBrowser(id: "company.thebrowser.Browser", name: "Arc", hostsFolder: "Arc/User Data/NativeMessagingHosts"),
        KnownBrowser(id: "com.brave.Browser", name: "Brave", hostsFolder: "BraveSoftware/Brave-Browser/NativeMessagingHosts"),
        KnownBrowser(id: "com.microsoft.edgemac", name: "Edge", hostsFolder: "Microsoft Edge/NativeMessagingHosts"),
        KnownBrowser(id: "com.vivaldi.Vivaldi", name: "Vivaldi", hostsFolder: "Vivaldi/NativeMessagingHosts"),
        KnownBrowser(id: "org.chromium.Chromium", name: "Chromium", hostsFolder: "Chromium/NativeMessagingHosts"),
    ]

    static func with(bundleID: String?) -> KnownBrowser? {
        guard let bundleID else { return nil }
        return all.first { $0.id.caseInsensitiveCompare(bundleID) == .orderedSame }
    }

    @MainActor var appURL: URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) }
    @MainActor var isInstalled: Bool { appURL != nil }
    @MainActor var icon: NSImage? { appURL.map { NSWorkspace.shared.icon(forFile: $0.path) } }

    var manifestURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support")
            .appendingPathComponent(hostsFolder)
            .appendingPathComponent("\(BrowserBridge.hostName).json")
    }
}

/// What Autowrite read of a page: the site, its title and its words.
struct PageRead: Sendable, Equatable {
    let host: String
    let title: String
    let text: String

    var words: Int { WritePrompt.wordCount(text) }
}

@MainActor
@Observable
final class BrowserBridge {
    static let shared = BrowserBridge()

    nonisolated static let hostName = "com.grj.sigmaflow"
    /// Fixed by the public key in BrowserExtension/manifest.json, whose private half is kept
    /// off the repo (~/.config/sigmaflow/browser-extension-key.pem): the Chrome Web Store keeps
    /// the ID of a first upload that carries it.
    nonisolated static let extensionID = "gcaepogaaolbllpamlfmbdnliikmmgfj"
    /// The extension's page on the Chrome Web Store, once it is there. Until then Add hands the
    /// browser the folder to load (`install(in:)`).
    static let storeURL: URL? = nil

    /// Browsers whose extension is connected right now, by bundle identifier.
    private(set) var connected: Set<String> = []
    /// Add was pressed and the extension hasn't said hello yet: Settings shows how to finish.
    private(set) var waiting: Set<String> = []

    private let server = BridgeServer()
    private var peers: [Int: String] = [:]  // connection -> browser bundle identifier
    private var pending: [String: CheckedContinuation<Data?, Never>] = [:]
    private var started = false

    private init() {}

    nonisolated static var folder: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/SigmaFlow")
    }

    nonisolated static var socketURL: URL { folder.appendingPathComponent("browser.sock") }

    /// Where the extension is copied for a browser to load while it isn't on the store.
    static var extensionFolder: URL { folder.appendingPathComponent("Browser Extension") }

    // MARK: Starting

    /// Listens for the helper, and writes the helper's manifest into every installed browser
    /// that hasn't been removed, so the extension finds SigmaFlow however it was installed.
    func start() {
        guard !started else { return }
        started = true
        server.onFrame = { connection, data in
            Task { @MainActor in BrowserBridge.shared.received(data, from: connection) }
        }
        server.onClose = { connection in
            Task { @MainActor in BrowserBridge.shared.closed(connection) }
        }
        if !server.listen(at: Self.socketURL) {
            Log.app.error("browser: couldn't listen at \(Self.socketURL.path, privacy: .public)")
        }
        for browser in KnownBrowser.all where browser.isInstalled && isAdded(browser) {
            writeManifest(for: browser)
        }
        if FileManager.default.fileExists(atPath: Self.extensionFolder.path) { copyExtension() }
    }

    func isAdded(_ browser: KnownBrowser) -> Bool {
        !Settings.shared.browsersRemoved.contains(browser.id)
    }

    func isConnected(_ browser: KnownBrowser) -> Bool { connected.contains(browser.id) }

    /// The browser in front, when its extension is connected.
    func connectedBrowser(_ app: NSRunningApplication?) -> KnownBrowser? {
        guard let browser = KnownBrowser.with(bundleID: app?.bundleIdentifier), connected.contains(browser.id) else { return nil }
        return browser
    }

    // MARK: Add and Remove (Settings, Connections; the one-time card)

    func add(_ browser: KnownBrowser) {
        Settings.shared.browsersRemoved.removeAll { $0 == browser.id }
        writeManifest(for: browser)
        guard !connected.contains(browser.id) else { return }
        waiting.insert(browser.id)
        install(in: browser)
    }

    func remove(_ browser: KnownBrowser) {
        if !Settings.shared.browsersRemoved.contains(browser.id) { Settings.shared.browsersRemoved.append(browser.id) }
        waiting.remove(browser.id)
        try? FileManager.default.removeItem(at: browser.manifestURL)
        for (connection, id) in peers where id == browser.id {
            server.close(connection)
        }
    }

    /// The store page in that browser once there is one. Until then: the folder copied out,
    /// shown in Finder, and the browser's extensions page opened beside it, where it is
    /// dragged in with Developer mode on.
    private func install(in browser: KnownBrowser) {
        guard let app = browser.appURL else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        if let store = Self.storeURL {
            NSWorkspace.shared.open([store], withApplicationAt: app, configuration: configuration)
            return
        }
        copyExtension()
        NSWorkspace.shared.activateFileViewerSelecting([Self.extensionFolder])
        if let extensions = URL(string: "chrome://extensions") {
            NSWorkspace.shared.open([extensions], withApplicationAt: app, configuration: configuration)
        }
    }

    /// The extension from inside the app, copied fresh, so an update reaches the browser at
    /// its next reload.
    private func copyExtension() {
        guard let source = Bundle.main.resourceURL?.appendingPathComponent("BrowserExtension"),
              FileManager.default.fileExists(atPath: source.path) else { return }
        let destination = Self.extensionFolder
        try? FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: destination)
        do {
            try FileManager.default.copyItem(at: source, to: destination)
        } catch {
            Log.app.error("browser: couldn't copy the extension: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// The small file that tells the browser where the helper is and which extension may
    /// start it.
    private func writeManifest(for browser: KnownBrowser) {
        let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/sigmaflow-browser")
        guard FileManager.default.fileExists(atPath: helper.path) else { return }
        let manifest: [String: Any] = [
            "name": Self.hostName,
            "description": "SigmaFlow",
            "path": helper.path,
            "type": "stdio",
            "allowed_origins": ["chrome-extension://\(Self.extensionID)/"],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        else { return }
        let url = browser.manifestURL
        if (try? Data(contentsOf: url)) == data { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {
            Log.app.error("browser: couldn't write the manifest for \(browser.name, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: Asking the page

    /// The box SigmaFlow just typed into, in the browser in front: remembered by the page under
    /// a token, and its text now. Nil when the page has no box with the focus, the site is
    /// switched off, or the extension doesn't answer in time.
    func watchField(in browser: KnownBrowser) async -> (token: String, text: String)? {
        let token = UUID().uuidString
        guard let (connection, answer) = await ask(browser, ["type": "field.watch", "token": token], id: token, wait: .seconds(1)),
              answer["ok"] as? Bool == true, let text = answer["text"] as? String
        else { return nil }
        fieldConnections[token] = connection
        return (token, text)
    }

    /// What that box holds now; nil once it is gone (the tab closed, the box left the page).
    func readField(_ token: String) async -> String? {
        guard let connection = fieldConnections[token],
              let answer = await ask(connection, ["type": "field.read", "token": token], wait: .seconds(1)),
              answer["ok"] as? Bool == true
        else { return nil }
        return answer["text"] as? String
    }

    func forgetField(_ token: String) {
        guard let connection = fieldConnections.removeValue(forKey: token),
              let data = try? JSONSerialization.data(withJSONObject: ["type": "field.forget", "token": token])
        else { return }
        server.send(data, to: connection)
    }

    private var fieldConnections: [String: Int] = [:]

    /// The page in front, for Autowrite (pick 09).
    func readPage(in browser: KnownBrowser) async -> PageRead? {
        guard let (_, answer) = await ask(browser, ["type": "page.read"], id: UUID().uuidString, wait: .milliseconds(1500)),
              answer["ok"] as? Bool == true,
              let text = answer["text"] as? String, !text.isEmpty
        else { return nil }
        return PageRead(
            host: answer["host"] as? String ?? "", title: answer["title"] as? String ?? "", text: text)
    }

    /// Every connection of `browser` (one per profile) is asked in turn; the first that
    /// answers yes wins. Only the profile whose window is in front has a page with the focus,
    /// and the others say no at once.
    private func ask(_ browser: KnownBrowser, _ message: [String: Any], id: String, wait: Duration) async -> (Int, [String: Any])? {
        let connections = peers.filter { $0.value == browser.id }.map(\.key).sorted()
        for (index, connection) in connections.enumerated() {
            var asked = message
            asked["id"] = connections.count == 1 ? id : "\(id)-\(index)"
            guard let data = try? JSONSerialization.data(withJSONObject: asked),
                  let reply = await send(data, id: asked["id"] as? String ?? id, to: connection, wait: wait),
                  Self.isYes(reply), let answer = Self.decode(reply)
            else { continue }
            return (connection, answer)
        }
        return nil
    }

    /// One request to one connection.
    private func ask(_ connection: Int, _ message: [String: Any], wait: Duration) async -> [String: Any]? {
        var message = message
        let id = UUID().uuidString
        message["id"] = id
        guard let data = try? JSONSerialization.data(withJSONObject: message),
              let reply = await send(data, id: id, to: connection, wait: wait) else { return nil }
        return Self.decode(reply)
    }

    /// Sends a request and waits for the reply with its `id`, or gives up after `wait`.
    private func send(_ data: Data, id: String, to connection: Int, wait: Duration) async -> Data? {
        let timeout = Task { @MainActor in
            try? await Task.sleep(for: wait)
            BrowserBridge.shared.resolve(id, with: nil)
        }
        let reply: Data? = await withCheckedContinuation { continuation in
            pending[id] = continuation
            server.send(data, to: connection)
        }
        timeout.cancel()
        return reply
    }

    private nonisolated static func decode(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private nonisolated static func isYes(_ data: Data) -> Bool {
        decode(data)?["ok"] as? Bool == true
    }

    private func resolve(_ id: String, with data: Data?) {
        pending.removeValue(forKey: id)?.resume(returning: data)
    }

    // MARK: From the helper

    private func received(_ data: Data, from connection: Int) {
        guard let message = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        if let id = message["id"] as? String, pending[id] != nil {
            resolve(id, with: data)
            return
        }
        switch message["type"] as? String {
        case "browser":
            // The helper's first word: which browser started it.
            guard let bundle = message["bundle"] as? String, let browser = KnownBrowser.with(bundleID: bundle) else {
                Log.app.info("browser: a helper from \(message["bundle"] as? String ?? "?", privacy: .public), not a browser SigmaFlow knows")
                return
            }
            peers[connection] = browser.id
        case "hello":
            guard let id = peers[connection] else { return }
            connected.insert(id)
            waiting.remove(id)
            Log.app.info("browser: extension \(message["version"] as? String ?? "?", privacy: .public) connected in \(id, privacy: .public)")
        case "openApp":
            openConnections()
        default:
            break
        }
    }

    private func closed(_ connection: Int) {
        guard let id = peers.removeValue(forKey: connection) else { return }
        fieldConnections = fieldConnections.filter { $0.value != connection }
        if !peers.values.contains(id) { connected.remove(id) }
    }

    /// The toolbar card's Open SigmaFlow: the main window on Settings, Connections.
    private func openConnections() {
        Settings.shared.openTabs["settings"] = SettingsPage.Tab.connections.rawValue
        Settings.shared.lastPage = MainWindow.Section.settings.rawValue
        NSApp.activate()
        if let window = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix("main") == true }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            (NSApp.delegate as? AppDelegate)?.openMainWindow?()
        }
    }
}

// MARK: - The socket

/// The listening socket and its connections, on threads of their own. Frames are Chrome's:
/// a 4-byte length in the Mac's byte order, then the JSON. Everything it hears goes to the
/// main actor through `onFrame` and `onClose`.
final class BridgeServer: @unchecked Sendable {
    var onFrame: @Sendable (Int, Data) -> Void = { _, _ in }
    var onClose: @Sendable (Int) -> Void = { _ in }

    private let lock = NSLock()
    private var listener: Int32 = -1
    private var sockets: [Int: Int32] = [:]
    private var nextID = 1
    private static let longestFrame = 64 << 20

    func listen(at url: URL) -> Bool {
        signal(SIGPIPE, SIG_IGN)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        unlink(url.path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(url.path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            Darwin.close(fd)
            return false
        }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        // Only this user's processes may connect.
        guard bound == 0, chmod(url.path, 0o600) == 0, Darwin.listen(fd, 8) == 0 else {
            Darwin.close(fd)
            return false
        }
        listener = fd
        Thread { [self] in acceptLoop(fd) }.start()
        return true
    }

    private func acceptLoop(_ fd: Int32) {
        while true {
            let client = accept(fd, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                return
            }
            var on: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            lock.lock()
            let id = nextID
            nextID += 1
            sockets[id] = client
            lock.unlock()
            Thread { [self] in readLoop(id, client) }.start()
        }
    }

    private func readLoop(_ id: Int, _ fd: Int32) {
        while let header = Self.read(fd, 4) {
            let length = Int(header.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) })
            guard length <= Self.longestFrame, let payload = length == 0 ? Data() : Self.read(fd, length) else { break }
            onFrame(id, payload)
        }
        lock.lock()
        let wasOpen = sockets.removeValue(forKey: id) != nil
        lock.unlock()
        if wasOpen { Darwin.close(fd) }
        onClose(id)
    }

    func send(_ payload: Data, to id: Int) {
        lock.lock()
        defer { lock.unlock() }
        guard let fd = sockets[id] else { return }
        var length = UInt32(payload.count)
        var frame = Data(bytes: &length, count: 4)
        frame.append(payload)
        var done = 0
        while done < frame.count {
            let n = frame.withUnsafeBytes { Darwin.write(fd, $0.baseAddress! + done, frame.count - done) }
            if n > 0 { done += n } else if n < 0, errno == EINTR { continue } else { return }
        }
    }

    /// Ends a connection; its read loop then reports it closed.
    func close(_ id: Int) {
        lock.lock()
        let fd = sockets.removeValue(forKey: id)
        lock.unlock()
        if let fd { shutdown(fd, SHUT_RDWR); Darwin.close(fd) }
    }

    private static func read(_ fd: Int32, _ count: Int) -> Data? {
        var data = Data(count: count)
        var done = 0
        while done < count {
            let n = data.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress! + done, count - done) }
            if n > 0 { done += n } else if n < 0, errno == EINTR { continue } else { return nil }
        }
        return data
    }
}

// MARK: - Checking it

/// `SigmaFlow --browser-check [SECONDS] [--browser chrome] [--draw FOLDER]`, in place of the app (quit the running copy first: the
/// two share the socket). Listens like the app, waits for a browser's extension to connect,
/// then asks it what a dictation and Autowrite would: the box with the focus, read twice, and
/// the page. Prints what came back and quits. Nothing is typed, saved or learned.
enum BrowserCheck {
    static func runIfRequested() -> Bool {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--browser-check") else { return false }
        let seconds = index + 1 < args.count ? Double(args[index + 1]) ?? 30 : 30
        func value(_ flag: String) -> String? {
            args.firstIndex(of: flag).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
        }
        Task { @MainActor in
            let bridge = BrowserBridge.shared
            bridge.start()
            print("waiting up to \(Int(seconds)) s for a browser's extension at \(BrowserBridge.socketURL.path)")
            let deadline = Date().addingTimeInterval(seconds)
            while bridge.connected.isEmpty, Date() < deadline {
                try? await Task.sleep(for: .milliseconds(200))
            }
            // `--browser NAME` asks only that browser: a check run beside a real browser with
            // the extension must not read whatever page the person has open there.
            let only = value("--browser")?.lowercased()
            let wanted = { (id: String) in only == nil || KnownBrowser.with(bundleID: id)?.name.lowercased() == only }
            while only != nil, !bridge.connected.contains(where: wanted), Date() < deadline {
                try? await Task.sleep(for: .milliseconds(200))
            }
            guard let id = bridge.connected.first(where: wanted), let browser = KnownBrowser.with(bundleID: id) else {
                print("no extension connected")
                exit(1)
            }
            print("connected: \(browser.name)")
            if let (token, text) = await bridge.watchField(in: browser) {
                print("box: \(text)")
                print("box again: \(await bridge.readField(token) ?? "(gone)")")
                bridge.forgetField(token)
            } else {
                print("box: none with the focus")
            }
            if let page = await bridge.readPage(in: browser) {
                print("page: \(page.host), \"\(page.title)\", \(page.words) words")
                print(String(page.text.prefix(300)))
                if let folder = value("--draw") { drawScan(into: URL(fileURLWithPath: folder)) }
            } else {
                print("page: nothing")
            }
            exit(0)
        }
        return true
    }
}

extension BrowserCheck {
    /// `--draw FOLDER`: the overlay's framed picture for a read page, at 4x, as scan.png, over
    /// a plain stand-in for the screenshot.
    @MainActor
    static func drawScan(into folder: URL) {
        let picture = NSImage(size: NSSize(width: DS.Material.writeThumbWidth * 8, height: DS.Material.writeThumbHeight * 8))
        picture.lockFocus()
        NSColor(DS.Color.inkSecondary).setFill()
        NSRect(origin: .zero, size: picture.size).fill()
        picture.unlockFocus()
        let renderer = ImageRenderer(content: ScreenScan(image: picture)
            .padding(DS.Space.snug)
            .background(DS.Color.glass)
            .environment(\.colorScheme, .dark))
        renderer.scale = 4
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let image = renderer.nsImage, let tiff = image.tiffRepresentation,
           let data = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            try? data.write(to: folder.appendingPathComponent("scan.png"))
            print("drew \(folder.appendingPathComponent("scan.png").path)")
        }
    }
}
