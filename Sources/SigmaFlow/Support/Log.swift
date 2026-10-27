import OSLog

enum Log {
    static let audio = Logger(subsystem: "com.grj.sigmaflow", category: "audio")
    static let speech = Logger(subsystem: "com.grj.sigmaflow", category: "speech")
    static let hotkey = Logger(subsystem: "com.grj.sigmaflow", category: "hotkey")
    static let inject = Logger(subsystem: "com.grj.sigmaflow", category: "inject")
    static let app = Logger(subsystem: "com.grj.sigmaflow", category: "app")
    static let meetings = Logger(subsystem: "com.grj.sigmaflow", category: "meetings")
    static let search = Logger(subsystem: "com.grj.sigmaflow", category: "search")
}
