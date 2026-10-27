import Foundation

// SigmaFlow's MCP server.
//
// Not a server in the usual sense: nothing listens on a port and nothing touches the
// network. Claude Desktop launches this binary as a child process and talks to it over the
// pipe between them, one JSON object per line. It reads the same runs.jsonl the app writes
// and answers questions about it, and since 16 Oct 2026 the meetings and conversations in the
// SigmaFlow folder too, transcripts, photos and screenshots (Recordings.swift).
//
// Transcripts are never uploaded, copied, or indexed anywhere. They are read from disk when
// a question actually asks for them, and only what a question touches is ever returned.

// MARK: - The transcript file

/// A single dictation, decoded from the app's log. Deliberately a separate, smaller type
/// than the app's `DictationRun`: this binary must not depend on the app target, and it
/// only needs three fields.
struct Transcript: Decodable {
    let id: UUID?
    let date: Date
    let engine: String
    let text: String
}

enum Store {
    /// Since 19 Oct 2026 dictations live in the SigmaFlow folder, `Dictations/.dictations.jsonl`
    /// beside the month files. The app's own folder still holds any that are waiting for
    /// the SigmaFlow folder to be found, under the old name.
    static var runsURLs: [URL] {
        let folder = Recordings.root.appendingPathComponent("Dictations", isDirectory: true)
            .appendingPathComponent(".dictations.jsonl")
        let waiting = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SigmaFlow", isDirectory: true)
            .appendingPathComponent("runs.jsonl")
        return [folder, waiting]
    }

    /// Re-read on every call. The file is small, and a cached copy would go stale the
    /// moment the user dictated anything.
    static func all() -> [Transcript] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var seen = Set<UUID>()
        var out: [Transcript] = []
        for url in runsURLs {
            guard let contents = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for line in contents.split(separator: "\n") {
                guard let item = try? decoder.decode(Transcript.self, from: Data(line.utf8)) else { continue }
                if let id = item.id {
                    guard !seen.contains(id) else { continue }
                    seen.insert(id)
                }
                out.append(item)
            }
        }
        return out.sorted { $0.date > $1.date }
    }
}

let dateFormatter: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    return f
}()

@MainActor
func render(_ items: [Transcript]) -> String {
    guard !items.isEmpty else {
        return "No transcripts matched. The user may not have dictated anything yet."
    }
    return items.map { item in
        "[\(dateFormatter.string(from: item.date))] (\(item.engine))\n\(item.text)"
    }.joined(separator: "\n\n---\n\n")
}

// MARK: - Tools

let tools: [[String: Any]] = [
    [
        "name": "search_transcripts",
        "description": """
            Search everything the user has dictated through SigmaFlow. Returns whole \
            transcripts whose text contains the query, newest first. Use this to answer \
            questions about what the user has said, decided, or noted at any point.
            """,
        "inputSchema": [
            "type": "object",
            "properties": [
                "query": ["type": "string", "description": "Words to look for. Case-insensitive."],
                "limit": ["type": "integer", "description": "Maximum transcripts to return. Default 20."],
            ],
            "required": ["query"],
        ],
    ],
    [
        "name": "recent_transcripts",
        "description": """
            Return the user's most recent dictations, newest first, optionally limited to \
            those on or after a date. Use this to review a period rather than search for a \
            term.
            """,
        "inputSchema": [
            "type": "object",
            "properties": [
                "limit": ["type": "integer", "description": "Maximum transcripts to return. Default 20."],
                "since": ["type": "string", "description": "ISO 8601 date or timestamp. Only transcripts on or after this are returned."],
            ],
        ],
    ],
]

@MainActor
func callTool(name: String, arguments: [String: Any]) -> String {
    let limit = max(1, min(200, arguments["limit"] as? Int ?? 20))
    let all = Store.all()

    switch name {
    case "search_transcripts":
        let query = (arguments["query"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return "Provide a query to search for." }
        let hits = all.filter { $0.text.localizedCaseInsensitiveContains(query) }
        return render(Array(hits.prefix(limit)))

    case "recent_transcripts":
        var items = all
        if let since = arguments["since"] as? String {
            // Accept a bare date as well as a full timestamp; a date alone means midnight.
            let parsed = dateFormatter.date(from: since)
                ?? ISO8601DateFormatter().date(from: since)
                ?? {
                    let f = DateFormatter()
                    f.dateFormat = "yyyy-MM-dd"
                    f.timeZone = .current
                    return f.date(from: since)
                }()
            if let parsed {
                items = items.filter { $0.date >= parsed }
            }
        }
        return render(Array(items.prefix(limit)))

    default:
        return "Unknown tool: \(name)"
    }
}

// MARK: - The briefing

/// Sent once at `initialize`; Claude Desktop puts it in front of every chat that has these
/// tools. It carries what the data can't say about itself. Keep it in step with the app:
/// when meetings, speakers or the .md change, this is the third place to look after
/// MeetingMarkdown and Recordings.swift.
let instructions = """
    SigmaFlow is a Mac app that turns the user's speech into text, entirely on their Mac. \
    These tools read what it has saved. There are three kinds of record.

    Dictations (search_transcripts, recent_transcripts): the user's own words, spoken into \
    whatever app they were typing in, so they are first person and addressed to someone \
    else (an email, a chat message, a note). Usually tidied for punctuation and capitals. \
    A dictation can contain a saved snippet the user triggered by a short phrase, so a long \
    stock passage may not have been spoken word for word. The user also keeps them as one \
    Markdown file a month in ~/SigmaFlow/Dictations.

    Meetings: recorded calls and meetings, and audio files the user added. Conversations: \
    notes taken live in a room, in person, often with camera photos of the room (one every \
    30 seconds) and screenshots of the user's screen. Each sits in its own folder in \
    ~/SigmaFlow, named by date, weekday, start time and length, for example \
    "[ 13 Oct ] Tue 2.30 pm - 48 min", with " - <title>" added when the user renamed it. \
    Line times count from the start of the recording, not the time of day.

    Reading speakers:
    - Speakers are numbered (Speaker 1, 2, 3) within one recording only. Speaker 1 in one \
    meeting is not Speaker 1 in another. Only names the user typed in carry meaning across \
    recordings.
    - The user is not labelled. Do not assume Speaker 1 is the user; infer it from what is \
    said, or ask.
    - Who said what is a machine's guess and is sometimes wrong. Several people on one \
    laptop mic can be merged into one speaker, and a line can go to the wrong person. When \
    it matters (a promise, a decision, a quote), say who it appears to be and that the \
    attribution may be off.
    - On a call, the user's side and the other side were heard separately and numbered \
    together, in the order each person first spoke.

    Reading the words:
    - Transcripts are speech recognition, not minutes. Expect misheard names, products and \
    jargon, missing words, and the odd wrong word. Read past them; when a misheard word \
    changes the meaning, say so instead of quoting it as fact.
    - A recording marked "Language: Tamil and English" has Tamil lines in Tamil script, \
    and English words spoken inside a Tamil sentence also come out in Tamil letters. That \
    is expected. Translate or summarise in the language the user writes to you in.
    - Screenshots show the user's own screen at that moment; photos show the room. Use \
    get_pictures when what was on screen or who was present matters to the question.
    - A picture can carry a short description ("shows: …"), written on the user's Mac by \
    a small vision model a few minutes after the recording ends: a sentence on what is in \
    it, then words it could read. search_recordings matches these too. It is a machine's \
    reading and can miss or misread things; look at the picture before relying on a detail.

    Answering: cite the recording's name and the line time (for example [12:30]) for \
    anything you report, so the user can find it. Start with list_recordings or \
    search_recordings to find the right recording, then read_recording, reading long ones \
    a stretch at a time with from and to.
    """

// MARK: - JSON-RPC over stdio

@MainActor
func send(_ object: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: object),
          var line = String(data: data, encoding: .utf8)
    else { return }
    line.append("\n")
    FileHandle.standardOutput.write(Data(line.utf8))
}

@MainActor
func reply(id: Any, result: [String: Any]) {
    send(["jsonrpc": "2.0", "id": id, "result": result])
}

@MainActor
func replyError(id: Any, code: Int, message: String) {
    send(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]])
}

@MainActor
func handle(_ message: [String: Any]) {
    let method = message["method"] as? String ?? ""
    let id = message["id"]

    switch method {
    case "initialize":
        // Echo the client's protocol version when it names one, so this keeps working as
        // the spec moves rather than pinning to whatever was current at build time.
        let params = message["params"] as? [String: Any]
        let version = params?["protocolVersion"] as? String ?? "2024-11-05"
        guard let id else { return }
        reply(id: id, result: [
            "protocolVersion": version,
            "capabilities": ["tools": [:] as [String: Any]],
            "serverInfo": ["name": "sigmaflow", "version": "1.2.0"],
            "instructions": instructions,
        ])

    case "tools/list":
        guard let id else { return }
        reply(id: id, result: ["tools": tools + recordingTools])

    case "tools/call":
        guard let id else { return }
        let params = message["params"] as? [String: Any] ?? [:]
        let name = params["name"] as? String ?? ""
        let arguments = params["arguments"] as? [String: Any] ?? [:]
        // Meetings and conversations answer with their own blocks, images among them.
        let content = RecordingTools.call(name, arguments)
            ?? [["type": "text", "text": callTool(name: name, arguments: arguments)]]
        reply(id: id, result: ["content": content, "isError": false])

    case "ping":
        guard let id else { return }
        reply(id: id, result: [:])

    default:
        // Notifications carry no id and must never be answered.
        guard let id else { return }
        replyError(id: id, code: -32601, message: "Method not found: \(method)")
    }
}

// One JSON object per line, until the pipe closes and Claude Desktop is done with us.
while let line = readLine(strippingNewline: true) {
    guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
    guard let data = line.data(using: .utf8),
          let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { continue }
    handle(message)
}
