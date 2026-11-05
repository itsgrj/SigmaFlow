import Foundation

/// The website a browser call is on, so a recording says "Zoho Cliq" or "Google Meet"
/// rather than "Dia" (Gokul, 4 Nov 2026: a Cliq call and a meeting looked the same).
///
/// Core Audio says which browser has the microphone, never which tab. So the browser is
/// asked, over Apple Events, for the addresses of its open tabs, and those are matched
/// against the call sites below. The window titles Accessibility gives are no use: Dia cuts
/// them short behind its profile name ("WORK: (33) Global View -…"), and Chromium shows no
/// page addresses without turning on its whole accessibility tree, which slows it for as
/// long as it runs. Asking costs one system question per browser, the first time; refused,
/// or a browser with no Apple Events (Firefox), the recording keeps the browser's name.
/// The addresses are read in memory and only the site's name is kept.
///
/// Which tab: a meeting room (a Meet code, a Zoom web client) wins wherever it is, the
/// front window's first; then a chat app with calls in a window's front tab, front window
/// first; then one in any tab, only when it is the only such app open. Cliq sits open all
/// day, so a Meet joined beside it must not be called Cliq.
enum CallSite {
    private struct Site: Sendable {
        let name: String
        /// Matches a tab's address.
        let matches: @Sendable (URL) -> Bool
        /// A page that is the call itself, not an app you can call from.
        let isRoom: Bool
    }

    private static func host(_ url: URL) -> String { url.host()?.lowercased() ?? "" }

    /// `host` is `domain` or one of its subdomains.
    private static func on(_ domain: String) -> @Sendable (URL) -> Bool {
        { url in host(url) == domain || host(url).hasSuffix("." + domain) }
    }

    /// Zoho's sites live under every country's domain, and a company's own: cliq.zoho.in,
    /// meeting.zohocorp.com, …
    private static func zoho(_ service: String) -> @Sendable (URL) -> Bool {
        { url in host(url).hasPrefix(service + ".zoho") }
    }

    /// Only an address that can only be the call itself is a room. A Zoho Meeting page or a
    /// Webex one stays open after the meeting (Gokul had one open with no call on), so those
    /// count as apps.
    private static let sites: [Site] = [
        Site(name: "Google Meet", matches: {
            on("meet.google.com")($0) && $0.path().wholeMatch(of: /\/[a-z]{3}-[a-z]{4}-[a-z]{3}\/?/) != nil
        }, isRoom: true),
        Site(name: "Zoom", matches: { on("zoom.us")($0) && ($0.path().hasPrefix("/wc/") || $0.path().hasPrefix("/j/")) }, isRoom: true),
        Site(name: "Jitsi Meet", matches: { on("meet.jit.si")($0) && $0.path().count > 1 }, isRoom: true),
        Site(name: "Google Meet", matches: on("meet.google.com"), isRoom: false),
        Site(name: "Zoom", matches: on("zoom.us"), isRoom: false),
        Site(name: "Zoho Meeting", matches: zoho("meeting"), isRoom: false),
        Site(name: "Zoho Cliq", matches: zoho("cliq"), isRoom: false),
        Site(name: "Webex", matches: on("webex.com"), isRoom: false),
        Site(name: "Whereby", matches: on("whereby.com"), isRoom: false),
        Site(name: "Microsoft Teams", matches: { on("teams.microsoft.com")($0) || on("teams.live.com")($0) || on("teams.cloud.microsoft")($0) }, isRoom: false),
        Site(name: "Slack", matches: on("app.slack.com"), isRoom: false),
        Site(name: "Discord", matches: on("discord.com"), isRoom: false),
        Site(name: "Skype", matches: on("web.skype.com"), isRoom: false),
    ]

    private struct Tab {
        let url: URL
        /// The tab showing in its window.
        let isFront: Bool
    }

    /// The call site among the browser's tabs, or nil when none is open or the browser
    /// won't say. Waits while macOS asks the user, so it never runs on the main thread.
    static func name(in browser: String) async -> String? {
        await withCheckedContinuation { done in
            queue.async { done.resume(returning: pick(tabs(of: browser))) }
        }
    }

    /// One question at a time.
    private static let queue = DispatchQueue(label: "com.grj.sigmaflow.callsite")
    /// Long enough to answer macOS's question the first time; a browser answers in a blink.
    private static let patience: DispatchTimeInterval = .seconds(60)

    private static func pick(_ tabs: [Tab]) -> String? {
        func site(_ tab: Tab) -> Site? { sites.first { $0.matches(tab.url) } }
        let front = tabs.filter(\.isFront)
        if let room = (front + tabs).lazy.compactMap(site).first(where: \.isRoom) { return room.name }
        if let app = front.lazy.compactMap(site).first { return app.name }
        let open = Set(tabs.compactMap { site($0)?.name })
        return open.count == 1 ? open.first : nil
    }

    /// Every tab's address, window by window, front window first: "A" before the front tab
    /// of each window, "T" before every tab. Chromium browsers say `active tab`, Safari and
    /// its family `current tab`.
    private static func tabs(of browser: String) -> [Tab] {
        let front = browser.lowercased().hasPrefix("com.apple.safari") ? "current tab" : "active tab"
        let source = """
        tell application id "\(browser)"
            set out to ""
            repeat with w in windows
                try
                    set out to out & "A " & (URL of \(front) of w) & linefeed
                end try
                try
                    set urls to URL of every tab of w
                    repeat with u in urls
                        try
                            set out to out & "T " & (u as text) & linefeed
                        end try
                    end repeat
                end try
            end repeat
            return out
        end tell
        """
        // osascript, not NSAppleScript: off the main thread NSAppleScript waited for a reply
        // that never came (4 Nov 2026), and on it the app would hang while macOS asks. A
        // child process asks in SigmaFlow's name all the same.
        nonisolated(unsafe) let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return []
        }
        let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + patience, execute: watchdog)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()
        guard process.terminationStatus == 0 else {
            Log.meetings.info("call site: \(browser, privacy: .public) wouldn't say (\(process.terminationStatus))")
            return []
        }
        return String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap { line in
            guard line.count > 2, let url = URL(string: String(line.dropFirst(2))) else { return nil }
            return Tab(url: url, isFront: line.hasPrefix("A "))
        }
    }
}
