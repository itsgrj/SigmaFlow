import Darwin
import Foundation

// The helper a browser starts for SigmaFlow's extension (native messaging host
// com.grj.sigmaflow; docs/mockups/browser-extension.html). It is Contents/MacOS/
// sigmaflow-browser in the app, named in the small manifest SigmaFlow writes into each
// browser's NativeMessagingHosts folder.
//
// A relay and nothing more: frames from the extension on stdin go to SigmaFlow's socket,
// frames from the socket go to stdout. Both sides use Chrome's framing, a 4-byte length in
// the Mac's byte order, then that much JSON, so most frames pass through untouched. Two are
// its own: `browser` to SigmaFlow when it connects, naming the browser that started it (its
// parent process), and `status` to the extension whenever SigmaFlow comes or goes.
//
// It never exits while the browser keeps the port open, waiting for SigmaFlow when it isn't
// running: the open port is what keeps the extension's worker alive. The browser closing the
// port (stdin at its end) is the only way out.

signal(SIGPIPE, SIG_IGN)

/// The longest frame either side may send. Chrome's own limit to a host is 4 GB; SigmaFlow
/// never needs more than a page's words.
let longestFrame = 64 << 20

func readExactly(_ fd: Int32, _ count: Int) -> Data? {
    var data = Data(count: count)
    var done = 0
    while done < count {
        let n = data.withUnsafeMutableBytes { read(fd, $0.baseAddress! + done, count - done) }
        if n > 0 {
            done += n
        } else if n < 0, errno == EINTR {
            continue
        } else {
            return nil
        }
    }
    return data
}

func readFrame(_ fd: Int32) -> Data? {
    guard let header = readExactly(fd, 4) else { return nil }
    let length = Int(header.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) })
    guard length <= longestFrame else { return nil }
    return length == 0 ? Data() : readExactly(fd, length)
}

func writeAll(_ fd: Int32, _ data: Data) -> Bool {
    var done = 0
    while done < data.count {
        let n = data.withUnsafeBytes { write(fd, $0.baseAddress! + done, data.count - done) }
        if n > 0 {
            done += n
        } else if n < 0, errno == EINTR {
            continue
        } else {
            return false
        }
    }
    return true
}

func frame(_ payload: Data) -> Data {
    var length = UInt32(payload.count)
    var data = Data(bytes: &length, count: 4)
    data.append(payload)
    return data
}

func json(_ object: [String: Any]) -> Data {
    (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
}

/// The browser that started this helper: the bundle around its parent process, found by the
/// first `Contents/MacOS` in its path. Not by `.app`: Chrome runs from a copy of itself named
/// `Google Chrome.app.bundle` in a temporary folder (its code-sign clone), and the bundle's
/// own Info.plist still says com.google.Chrome.
func browser() -> [String: Any] {
    let pid = getppid()
    var buffer = [UInt8](repeating: 0, count: Int(MAXPATHLEN) * 4)
    let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
    var info: [String: Any] = ["type": "browser", "pid": Int(pid)]
    guard length > 0 else {
        info["error"] = "proc_pidpath \(errno)"
        return info
    }
    let path = String(decoding: buffer.prefix(Int(length)), as: UTF8.self)
    guard let end = path.range(of: "/Contents/MacOS/") else {
        info["error"] = "not in an app: \(path)"
        return info
    }
    let url = URL(fileURLWithPath: String(path[..<end.lowerBound]))
    info["path"] = url.path
    info["bundle"] = Bundle(url: url)?.bundleIdentifier ?? ""
    return info
}

let socketPath = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/SigmaFlow/browser.sock").path

func connectToApp() -> Int32? {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(socketPath.utf8)
    guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
        close(fd)
        return nil
    }
    withUnsafeMutableBytes(of: &address.sun_path) { raw in
        raw.copyBytes(from: bytes)
        raw[bytes.count] = 0
    }
    let connected = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard connected == 0 else {
        close(fd)
        return nil
    }
    return fd
}

/// The socket to SigmaFlow. One lock per direction: each side's frames go out whole.
final class Relay: @unchecked Sendable {
    private let outLock = NSLock()
    private let appLock = NSLock()
    private var app: Int32 = -1
    private var told: Bool?

    /// To the extension. The relay thread and `status` both write here.
    func toExtension(_ payload: Data) {
        outLock.lock()
        defer { outLock.unlock() }
        _ = writeAll(STDOUT_FILENO, frame(payload))
    }

    /// To SigmaFlow, when it is there; dropped when it isn't (the extension knows from
    /// `status`, and every request SigmaFlow makes carries its own wait).
    func toApp(_ payload: Data) {
        appLock.lock()
        defer { appLock.unlock() }
        guard app >= 0 else { return }
        _ = writeAll(app, frame(payload))
    }

    private func tell(_ isThere: Bool) {
        guard told != isThere else { return }
        told = isThere
        toExtension(json(["type": "status", "app": isThere]))
    }

    /// Connects, relays until SigmaFlow goes, and waits for it to come back, for good.
    func run() {
        let hello = frame(json(browser()))
        while true {
            guard let fd = connectToApp() else {
                tell(false)
                sleep(2)
                continue
            }
            guard writeAll(fd, hello) else {
                close(fd)
                sleep(2)
                continue
            }
            appLock.lock()
            app = fd
            appLock.unlock()
            tell(true)
            while let payload = readFrame(fd) {
                toExtension(payload)
            }
            appLock.lock()
            app = -1
            close(fd)
            appLock.unlock()
            tell(false)
            sleep(1)
        }
    }
}

let relay = Relay()
Thread { relay.run() }.start()

while let payload = readFrame(STDIN_FILENO) {
    relay.toApp(payload)
}
exit(0)
