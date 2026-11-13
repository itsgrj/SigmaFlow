import Foundation

/// A Zoho Desk ticket, read through the user's own Zoho MCP server, for Autowrite to write
/// from alongside the screen.
///
/// Nothing is judged and cut (Gokul, 5 Nov 2026): what looks like noise, a signature, is
/// often the only place the real writer of a shared-mailbox reply is named. The one thing
/// left out is repetition. Every email quotes the whole chain below it, so by default the
/// newest email comes in full and the others as Desk's own opening lines; when a limit still
/// forces it, the oldest goes first.
struct DeskTicket: Sendable {
    struct Entry: Sendable {
        enum Kind: Sendable { case email, internalNote, publicComment }

        let kind: Kind
        let date: Date
        let threadID: String?
        /// "Maya Chen <maya@…>" for an email, the agent's name for a note.
        let author: String
        let to: String
        let cc: String
        /// Desk's summary of an email (its first lines); a note in full.
        let opening: String
        /// The email's whole plain text, quoted history and all, once fetched.
        var full: String?
    }

    let number: String
    let subject: String
    let status: String
    let customer: String
    let assignee: String
    /// Oldest first. Drafts are never here.
    var entries: [Entry]

    /// The ticket as the prompt carries it, at most `limit` characters. Over the limit, the
    /// oldest full emails go first, then the tail of the newest (its oldest quotes), then the
    /// oldest lines of the list.
    func text(limit: Int) -> String {
        var list = entries.map(Self.line)
        var fulls = entries.filter { $0.full != nil }
        var cut: Int?

        func assemble() -> String {
            var parts = [header]
            if !list.isEmpty {
                parts.append("Every message on the ticket, oldest first. Emails show only their opening lines here.\n" + list.joined(separator: "\n"))
            }
            if !fulls.isEmpty {
                let intro = fulls.count == 1
                    ? "The newest email in full, as Desk has it (the emails before it are quoted inside):"
                    : "Every email in full, oldest first, as Desk has them (each quotes the ones before it):"
                let emails = fulls.map { entry in
                    var body = entry.full ?? ""
                    if let cut, entry.threadID == fulls.last?.threadID {
                        body = String(body.prefix(cut)) + "\n[older quoted emails left out]"
                    }
                    return "<email date=\"\(Self.when(entry.date))\" from=\"\(entry.author)\">\n\(body)\n</email>"
                }
                parts.append(intro + "\n" + emails.joined(separator: "\n"))
            }
            return parts.joined(separator: "\n\n")
        }

        var result = assemble()
        while result.count > limit {
            if fulls.count > 1 {
                fulls.removeFirst()
            } else if let only = fulls.first, cut == nil {
                let room = limit - (result.count - (only.full ?? "").count) - 40
                if room > 500 { cut = room } else { fulls = [] }
            } else if !fulls.isEmpty {
                fulls = []
            } else if list.count > 1 {
                list.removeFirst()
            } else {
                return String(result.prefix(limit))
            }
            result = assemble()
        }
        return result
    }

    private var header: String {
        """
        Zoho Desk ticket #\(number): \(subject)
        Status: \(status). Customer: \(customer). Assigned to: \(assignee). Times are \(TimeZone.current.identifier).
        """
    }

    private static func line(_ entry: Entry) -> String {
        let at = when(entry.date)
        switch entry.kind {
        case .email:
            let cc = entry.cc.isEmpty ? "" : ", cc \(entry.cc)"
            return "- \(at) · email from \(entry.author) to \(entry.to)\(cc): \(entry.opening)"
        case .internalNote:
            return "- \(at) · internal note by \(entry.author), never seen by the customer: \(entry.opening)"
        case .publicComment:
            return "- \(at) · comment by \(entry.author), visible to the customer: \(entry.opening)"
        }
    }

    private static func when(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened, locale: Locale(identifier: "en_GB"), timeZone: .current))
    }
}

/// Finds a ticket and reads it through Zoho MCP's Desk tools. Nothing here knows one
/// person's account: the org comes from the server, the data centre from the link, the tool
/// names from the server's own list.
enum DeskReader {
    enum Detail: String, Sendable {
        /// The newest email in full, the rest as opening lines.
        case newest
        /// Every email in full.
        case every
    }

    /// What names a ticket: its number as people see it (#20431), Desk's internal id, or
    /// a Desk link, which carries the id and the portal.
    struct Reference: Sendable {
        var number: String?
        var id: String?
        var portal: String?

        init?(_ text: String) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.contains("/") {
                // Both link shapes Desk uses: …/agent/<portal>/<dept>/tickets/details/<id>
                // and the older …/support/<portal>/ShowHomePage.do#Cases/dv/<id>.
                id = trimmed.firstMatch(of: /(?:tickets\/details\/|#Cases\/dv\/)(\d{10,})/).map { String($0.1) }
                portal = trimmed.firstMatch(of: /\/(?:agent|support)\/([^\/#?]+)/).map { String($0.1) }
                if id == nil { return nil }
            } else {
                let digits = trimmed.filter(\.isNumber)
                guard !digits.isEmpty, digits.count == trimmed.filter({ $0 != "#" && $0 != " " }).count else { return nil }
                // Internal ids are 15 to 19 digits; ticket numbers are far shorter.
                if digits.count >= 15 { id = digits } else { number = digits }
            }
        }
    }

    enum Failure: LocalizedError {
        case missingTools([String])
        case notFound(String)
        case unreadable(String)

        var errorDescription: String? {
            switch self {
            case .missingTools(let names):
                "Turn on these Zoho Desk tools on your Zoho MCP server: \(names.joined(separator: ", "))."
            case .notFound(let what):
                "Couldn't find ticket \(what) in any Zoho Desk portal this server can read."
            case .unreadable(let what):
                "Zoho Desk sent back something unexpected for \(what)."
            }
        }
    }

    /// What to ask for when signing in: Zoho Desk, and only to read.
    static let scopes: @Sendable (String) -> Bool = { $0.hasPrefix("desk.") && $0.hasSuffix(".read") }

    private static let conversationPage = 200
    private static let parallelReads = 6

    static func read(_ reference: Reference, detail: Detail, client: MCPClient) async throws -> DeskTicket {
        let names = try await client.toolNames()
        func tool(_ operation: String) -> String? {
            names.first { $0 == operation || $0.hasSuffix("Desk_\(operation)") }
        }
        let lookup = reference.id != nil ? "getTicket" : "searchTickets"
        let needed = ["getOrganizations", lookup, "getTicketConversations", "getThread"]
        let missing = needed.filter { tool($0) == nil }
        guard missing.isEmpty else { throw Failure.missingTools(missing) }

        // Every portal the server can see, the one the link names first, then the default.
        let orgs = try payload(try await client.call(tool("getOrganizations")!, [:]))["data"] as? [[String: Any]] ?? []
        let ordered = orgs.sorted { a, b in
            func rank(_ org: [String: Any]) -> Int {
                if let portal = reference.portal, (org["portalName"] as? String)?.caseInsensitiveCompare(portal) == .orderedSame { return 0 }
                return org["isDefault"] as? Bool == true ? 1 : 2
            }
            return rank(a) < rank(b)
        }

        var found: (ticket: [String: Any], org: String)?
        for org in ordered {
            guard let orgID = string(org["id"]) else { continue }
            // A key that isn't allowed into this portal answers with an error; try the next.
            if let id = reference.id {
                if let ticket = try? payload(try await client.call(tool("getTicket")!, [
                    "path_variables": ["ticketId": id],
                    "query_params": ["orgId": orgID, "include": ["contacts", "assignee"]] as [String: any Sendable],
                ])), ticket["id"] != nil {
                    found = (ticket, orgID)
                }
            } else if let number = reference.number {
                if let result = try? payload(try await client.call(tool("searchTickets")!, [
                    "query_params": ["orgId": orgID, "ticketNumber": [number]] as [String: any Sendable],
                ])), let ticket = (result["data"] as? [[String: Any]])?.first {
                    found = (ticket, orgID)
                }
            }
            if found != nil { break }
        }
        guard let found, let ticketID = string(found.ticket["id"]) else {
            throw Failure.notFound(reference.number.map { "#\($0)" } ?? reference.id ?? "")
        }
        let (ticket, orgID) = found

        // The whole conversation, a page at a time.
        var items: [[String: Any]] = []
        while true {
            let page = try payload(try await client.call(tool("getTicketConversations")!, [
                "path_variables": ["ticketId": ticketID],
                "query_params": ["orgId": orgID, "from": items.count, "limit": conversationPage] as [String: any Sendable],
            ]))["data"] as? [[String: Any]] ?? []
            items += page
            if page.count < conversationPage { break }
        }
        var entries = items.compactMap(entry).sorted { $0.date < $1.date }

        // The full text: the newest email, or every one.
        let wanted = entries.indices.filter { entries[$0].kind == .email }
        let fetch = (detail == .newest ? Array(wanted.suffix(1)) : wanted)
            .compactMap { index in entries[index].threadID.map { (index, $0) } }
        let getThread = tool("getThread")!
        let texts = try await withThrowingTaskGroup(of: (Int, String?).self) { group in
            var results: [Int: String] = [:]
            var pending = fetch[...]
            func addNext() {
                guard let next = pending.popFirst() else { return }
                let (index, threadID) = next
                group.addTask {
                    let thread = try payload(try await client.call(getThread, [
                        "path_variables": ["ticketId": ticketID, "threadId": threadID],
                        "query_params": ["orgId": orgID, "include": "plainText"],
                    ]))
                    let text = (thread["plainText"] as? String) ?? (thread["content"] as? String).map(plain(fromHTML:))
                    return (index, text)
                }
            }
            for _ in 0..<parallelReads { addNext() }
            while let (index, text) = try await group.next() {
                results[index] = text
                addNext()
            }
            return results
        }
        for (index, text) in texts { entries[index].full = text }

        let contact = ticket["contact"] as? [String: Any]
        let contactName = [contact?["firstName"], contact?["lastName"]].compactMap { $0 as? String }.joined(separator: " ")
        let contactEmail = (contact?["email"] as? String) ?? (ticket["email"] as? String) ?? ""
        let account = (contact?["account"] as? [String: Any])?["accountName"] as? String
        let assignee = ticket["assignee"] as? [String: Any]
        let assigneeName = [assignee?["firstName"], assignee?["lastName"]].compactMap { $0 as? String }
            .filter { !$0.isEmpty }.joined(separator: " ")

        return DeskTicket(
            number: string(ticket["ticketNumber"]) ?? reference.number ?? "",
            subject: ticket["subject"] as? String ?? "",
            status: ticket["status"] as? String ?? "",
            customer: "\(contactName) <\(contactEmail)>" + (account.map { " (\($0))" } ?? ""),
            assignee: assigneeName.isEmpty ? "nobody" : assigneeName,
            entries: entries
        )
    }

    private static func entry(_ item: [String: Any]) -> DeskTicket.Entry? {
        switch item["type"] as? String {
        case "thread":
            guard item["status"] as? String != "DRAFT", let date = date(item["createdTime"]) else { return nil }
            let author = (item["fromEmailAddress"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? ((item["author"] as? [String: Any])?["name"] as? String) ?? "someone"
            return DeskTicket.Entry(
                kind: .email, date: date, threadID: string(item["id"]), author: author,
                to: item["to"] as? String ?? "", cc: item["cc"] as? String ?? "",
                opening: item["summary"] as? String ?? "", full: nil)
        case "comment":
            guard let date = date(item["commentedTime"]) else { return nil }
            let author = (item["commenter"] as? [String: Any])?["name"] as? String ?? "an agent"
            return DeskTicket.Entry(
                kind: item["isPublic"] as? Bool == true ? .publicComment : .internalNote,
                date: date, threadID: nil, author: author, to: "", cc: "",
                opening: plain(fromHTML: item["content"] as? String ?? ""), full: nil)
        default:
            return nil
        }
    }

    /// The answer inside a tool's text: Zoho MCP wraps Desk's reply as
    /// `{"status": "success", "data": {…}}`, and a refusal as `"status": "failure"`.
    private static func payload(_ text: String) throws -> [String: Any] {
        guard let top = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
            throw Failure.unreadable("a tool's answer")
        }
        if top["status"] as? String == "failure" {
            let message = (top["data"] as? [String: Any])?["message"] as? String ?? "refused"
            throw MCPClient.Failure.tool(message)
        }
        return top["data"] as? [String: Any] ?? top
    }

    private static func string(_ value: Any?) -> String? {
        switch value {
        case let text as String: text
        case let number as NSNumber: number.stringValue
        default: nil
        }
    }

    private static func date(_ value: Any?) -> Date? {
        guard let text = value as? String else { return nil }
        return (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(text))
            ?? (try? Date.ISO8601FormatStyle().parse(text))
    }

    /// A note's HTML as text: line breaks kept, pictures named, tags and entities gone.
    static func plain(fromHTML html: String) -> String {
        var text = html
        let rules: [(String, String)] = [
            ("<(style|script|head)[^>]*>[\\s\\S]*?</\\1>", ""),
            ("<img[^>]*>", "[picture]"),
            ("<(br|/p|/div|/li|/tr|/h[1-6])[^>]*>", "\n"),
            ("<[^>]+>", ""),
        ]
        for (pattern, replacement) in rules {
            text = text.replacingOccurrences(of: pattern, with: replacement, options: [.regularExpression, .caseInsensitive])
        }
        for (entity, character) in [("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#34;", "\""), ("&#39;", "'"), ("&amp;", "&")] {
            text = text.replacingOccurrences(of: entity, with: character)
        }
        text = text.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
