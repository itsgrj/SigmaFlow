import AppKit
import CoreAudio
import Foundation

/// Notices a call starting and ending, by watching which apps have the microphone open
/// (docs/mockups/meeting-call-detect.html, picks A A A B).
///
/// Core Audio lists every process doing audio, with whether it is reading input; nothing to
/// grant for that. Only call apps count: Zoom, Teams, FaceTime, Slack, Webex, Discord and
/// every browser. Voice-note apps (WhatsApp, Telegram) are left out on purpose: a ten-second
/// voice note would ask to record a meeting. SigmaFlow's own use of the mic never counts.
///
/// A browser cannot say which tab has the mic, so the card names the browser. A call is over
/// when its app has let go of the mic for `endGrace` seconds: Zoom drops the mic for a moment
/// when you switch microphones, and that must not end a recording.
@MainActor
final class CallWatcher {
    static let shared = CallWatcher()

    struct Call: Equatable {
        /// The app's own name, for the card: "Zoom", "Google Chrome".
        let app: String
        /// The bundle-id family the app's processes share, for matching later polls.
        let family: String
    }

    /// The call in progress, if any.
    private(set) var current: Call?
    var onStart: ((Call) -> Void)?
    var onEnd: ((Call) -> Void)?

    private var task: Task<Void, Never>?
    private var lastSeen: Date?
    private static let pollInterval: Duration = .seconds(2)
    private static let endGrace: TimeInterval = 5

    /// Call apps that are not browsers, by bundle-id prefix, matched ignoring case.
    private static let callApps: [(prefix: String, name: String)] = [
        ("us.zoom.", "Zoom"),
        ("com.microsoft.teams", "Microsoft Teams"),
        ("com.apple.FaceTime", "FaceTime"),
        ("com.tinyspeck.slackmacgap", "Slack"),
        ("com.cisco.webex", "Webex"),
        ("Cisco-Systems.Spark", "Webex"),
        ("com.hnc.Discord", "Discord"),
    ]

    /// Browsers, by bundle-id prefix ignoring case, so betas and nightlies count too. Every
    /// app the Mac can open a web link in counts as well (`installedBrowsers`), so a browser
    /// missing here still works; this list covers the well-known ones when they aren't
    /// registered for links. Until 19 Oct 2026 browsers were matched by the label of the
    /// process holding the mic, case by case, and Dia, whose helper is
    /// `company.thebrowser.browser.helper` with a lowercase b, never asked once.
    private static let browsers: [String] = [
        "com.apple.Safari",                     // Safari, Technology Preview
        "com.google.Chrome",                    // Chrome, Beta, Dev, Canary
        "org.chromium.",                        // Chromium, Thorium
        "com.microsoft.edgemac",                // Edge and its channels
        "org.mozilla.firefox",                  // Firefox, Developer Edition
        "org.mozilla.nightly",
        "com.brave.Browser",
        "company.thebrowser.",                  // Arc, Dia
        "com.operasoftware.",                   // Opera, Opera GX, Opera Air
        "com.vivaldi.Vivaldi",
        "com.duckduckgo.macos.browser",
        "com.kagi.kagimacOS",                   // Orion
        "app.zen-browser.zen",
        "ai.perplexity.comet",
        "com.openai.atlas",
        "com.pushplaylabs.sidekick",
        "ru.yandex.desktop.yandex-browser",
        "com.naver.Whale",
        "net.waterfox.waterfox",
        "io.gitlab.librewolf-community",
        "one.ablaze.floorp",
        "com.sigmaos.sigmaos.macos",
        "io.wavebox.wavebox",
    ]

    /// Bundle ids, lowercased, of every app this Mac can open a web link in.
    private var installedBrowsers: Set<String> = []
    private var browsersLooked: Date = .distantPast
    private static let browsersEvery: TimeInterval = 60

    private init() {}

    func start() {
        guard task == nil else { return }
        task = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.poll()
                try? await Task.sleep(for: Self.pollInterval)
            }
        }
    }

    private func poll() {
        let using = callAppsUsingInput()
        if let current {
            if using.contains(where: { $0.family == current.family }) {
                lastSeen = Date()
            } else if let lastSeen, Date().timeIntervalSince(lastSeen) >= Self.endGrace {
                self.current = nil
                self.lastSeen = nil
                Log.meetings.info("call ended in \(current.app, privacy: .public)")
                onEnd?(current)
            }
        } else if let call = using.first {
            current = call
            lastSeen = Date()
            Log.meetings.info("call started in \(call.app, privacy: .public)")
            onStart?(call)
        }
    }

    /// Call apps with the microphone open right now, never SigmaFlow itself.
    private func callAppsUsingInput() -> [Call] {
        lookForBrowsers()
        let own = ProcessInfo.processInfo.processIdentifier
        var calls: [Call] = []
        for process in Self.processObjects() where Self.isRunningInput(process) {
            let pid = Self.pid(of: process)
            guard pid != own, let call = call(bundle: Self.bundleID(of: process), pid: pid) else { continue }
            if !calls.contains(call) { calls.append(call) }
        }
        return calls
    }

    /// Which call a process reading the mic belongs to, if any. A helper is known by the app
    /// it sits inside, whatever it calls itself.
    private func call(bundle: String?, pid: pid_t) -> Call? {
        let app = Self.containingApp(of: pid)
        for id in [bundle, app?.bundle].compactMap({ $0?.lowercased() }) {
            if let match = Self.callApps.first(where: { id.hasPrefix($0.prefix.lowercased()) }) {
                return Call(app: match.name, family: match.prefix)
            }
        }
        if let app, isBrowser(app.bundle) {
            return Call(app: app.name, family: app.bundle.lowercased())
        }
        // Safari, Orion and DuckDuckGo hear through WebKit's own process, which sits in no
        // app. The browser in front is the one that just joined; otherwise it's Safari.
        if bundle?.lowercased().hasPrefix("com.apple.webkit.") == true {
            let front = NSWorkspace.shared.frontmostApplication
            let name = front.flatMap { app in
                app.bundleIdentifier.map(isBrowser) == true ? app.localizedName : nil
            }
            return Call(app: name ?? "Safari", family: "com.apple.webkit")
        }
        return nil
    }

    private func isBrowser(_ bundle: String) -> Bool {
        let id = bundle.lowercased()
        return installedBrowsers.contains(id) || Self.browsers.contains { id.hasPrefix($0.lowercased()) }
    }

    /// Asks Launch Services once a minute, so a browser installed while SigmaFlow runs counts.
    private func lookForBrowsers() {
        guard Date().timeIntervalSince(browsersLooked) >= Self.browsersEvery,
              let web = URL(string: "https://example.com") else { return }
        browsersLooked = Date()
        installedBrowsers = Set(NSWorkspace.shared.urlsForApplications(toOpen: web)
            .compactMap { Bundle(url: $0)?.bundleIdentifier?.lowercased() })
    }

    /// The app a process sits inside, by the outermost `.app` in its path: Dia's mic is held
    /// by `/Applications/Dia.app/Contents/Frameworks/…/Browser Helper.app/…`, Firefox's by
    /// `Firefox.app/Contents/MacOS/plugin-container.app/…`.
    private static func containingApp(of pid: pid_t) -> (bundle: String, name: String)? {
        var buffer = [UInt8](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        let path = String(decoding: buffer.prefix(Int(length)), as: UTF8.self)
        guard let end = path.range(of: ".app/") else { return nil }
        let url = URL(fileURLWithPath: String(path[..<end.lowerBound]) + ".app")
        guard let bundle = Bundle(url: url)?.bundleIdentifier else { return nil }
        return (bundle, url.deletingPathExtension().lastPathComponent)
    }

    // MARK: Core Audio

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }

    private static func processObjects() -> [AudioObjectID] {
        var address = address(kAudioHardwarePropertyProcessObjectList)
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var objects = [AudioObjectID](repeating: kAudioObjectUnknown, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &objects) == noErr else { return [] }
        return objects
    }

    private static func isRunningInput(_ process: AudioObjectID) -> Bool {
        var address = address(kAudioProcessPropertyIsRunningInput)
        var running: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(process, &address, 0, nil, &size, &running) == noErr && running != 0
    }

    private static func pid(of process: AudioObjectID) -> pid_t {
        var address = address(kAudioProcessPropertyPID)
        var pid: pid_t = -1
        var size = UInt32(MemoryLayout<pid_t>.size)
        _ = AudioObjectGetPropertyData(process, &address, 0, nil, &size, &pid)
        return pid
    }

    private static func bundleID(of process: AudioObjectID) -> String? {
        var address = address(kAudioProcessPropertyBundleID)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(process, &address, 0, nil, &size, &value) == noErr, let value else { return nil }
        let bundle = value.takeRetainedValue() as String
        return bundle.isEmpty ? nil : bundle
    }
}
