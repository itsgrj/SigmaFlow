import AppKit
import Foundation
import SwiftUI

/// A developer aid, like `--transcribe-meeting`:
/// `SigmaFlow --search-check FOLDER QUERIES.txt [--raw]` reads every recording under FOLDER
/// exactly as the app does after Stop (lines, then each picture's words, description and
/// look), writes the descriptions into those .md files, then runs each line of QUERIES.txt
/// through search and prints what it found, with scores. `--raw` prints every moment's score
/// before the cutoff, best first, which is how `SearchIndex`'s numbers were chosen.
///
/// It runs instead of the app and keeps its index in `Application Support/SigmaFlow/SearchCheck`,
/// so it never touches the SigmaFlow folder or the real index. Point it at a copy.
@MainActor
enum SearchCheck {
    static func runIfRequested() -> Bool {
        let args = CommandLine.arguments
        guard let flag = args.firstIndex(of: "--search-check"), flag + 2 < args.count else { return false }
        NSApp.setActivationPolicy(.accessory)
        let folder = URL(fileURLWithPath: args[flag + 1])
        let queries = ((try? String(contentsOfFile: args[flag + 2], encoding: .utf8)) ?? "")
            .components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let raw = args.contains("--raw")
        // `--render DIR`: each query's results drawn with the list's own rows, into DIR.
        let render = args.firstIndex(of: "--render").flatMap { $0 + 1 < args.count ? URL(fileURLWithPath: args[$0 + 1]) : nil }
        SearchIndex.root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SigmaFlow/SearchCheck", isDirectory: true)
        Task { @MainActor in
            await run(folder: folder, queries: queries, raw: raw, render: render)
            NSApp.terminate(nil)
        }
        return true
    }

    private static func recordings(in folder: URL) -> [Meeting] {
        let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil)
        var found: [Meeting] = []
        while let url = enumerator?.nextObject() as? URL {
            if url.pathExtension == "md", let meeting = MeetingLibrary.read(url.deletingLastPathComponent()) { found.append(meeting) }
        }
        return found.sorted { $0.date > $1.date }
    }

    private static func run(folder: URL, queries: [String], raw: Bool, render: URL?) async {
        var started = Date()
        for meeting in recordings(in: folder) {
            let t = Date()
            await PictureReader.shared.read(meeting, folderName: "Check") {}
            print("read \(meeting.name): \(meeting.lines.count) rows, \(String(format: "%.1f", Date().timeIntervalSince(t))) s")
        }
        print("all read in \(Int(Date().timeIntervalSince(started))) s\n")
        let meetings = recordings(in: folder)
        for (number, query) in queries.enumerated() {
            started = Date()
            let vector = try? await SearchEncoder.shared.query(query)
            let hits = await SearchIndex.shared.search(query, vector: vector, meetings: meetings, folderName: "Check", raw: raw)
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            print("“\(query)”  \(hits.count) recording\(hits.count == 1 ? "" : "s"), \(ms) ms")
            if raw {
                // The same photo every 30 s, or the same line in many recordings, once each.
                let all = meetings.flatMap { meeting in (hits[meeting.id]?.all ?? []).map { (meeting, $0) } }
                var seen = Set<String>()
                let distinct = all.sorted(by: { $0.1.score > $1.1.score }).filter { meeting, moment in
                    seen.insert(moment.text.isEmpty ? meeting.name + moment.seen : moment.text).inserted
                }
                for (meeting, moment) in distinct.prefix(30) { print("   \(line(moment, in: meeting))") }
            } else {
                for meeting in meetings {
                    guard let hit = hits[meeting.id] else { continue }
                    print("  \(meeting.name)  (\(hit.total))")
                    for moment in hit.moments { print("     \(line(moment, in: meeting))") }
                }
            }
            print("")
            if let render, !raw {
                draw(Results(query: query, meetings: meetings.filter { hits[$0.id] != nil }, hits: hits),
                     to: render.appendingPathComponent(String(format: "%02d.png", number)), size: nil)
                // The large view once, for the first picture any search found.
                let firstPicture = meetings.lazy.compactMap { m in hits[m.id]?.moments.first { $0.path != nil }.map { (m, $0) } }.first
                if number == 0, let (meeting, moment) = firstPicture, let path = moment.path {
                    let viewer = PictureViewer(
                        url: meeting.folder.appendingPathComponent(path),
                        caption: "\(MeetingNaming.stem(for: meeting.date)), \(MeetingNaming.clock(moment.start))",
                        onGo: {}, onClose: {})
                        .background(BackgroundImage())
                    draw(viewer, to: render.appendingPathComponent("viewer.png"), size: CGSize(width: 1160, height: 760))
                }
            }
        }
    }

    /// One query's answer as the list draws it: each recording's name, its moments, "N more".
    private struct Results: View {
        let query: String
        let meetings: [Meeting]
        let hits: [String: SearchHit]

        var body: some View {
            VStack(alignment: .leading, spacing: 0) {
                Text("“\(query)”").font(DS.Font.title).foregroundStyle(DS.Color.ink).padding(DS.Space.roomy)
                ForEach(meetings, id: \.id) { meeting in
                    let hit = hits[meeting.id]!
                    CardDivider()
                    Text(meeting.name).font(DS.Font.transcript).foregroundStyle(DS.Color.ink)
                        .padding(.horizontal, DS.Space.rowPadX).padding(.vertical, DS.Space.rowPadY)
                    ForEach(hit.moments) { MomentRow(moment: $0, folder: meeting.folder, query: query) {} }
                    if hit.total > hit.moments.count {
                        MoreMomentsRow(count: hit.total - hit.moments.count, noun: "conversation") {}
                    }
                }
            }
            .frame(width: 900, alignment: .leading)
            .background(DS.Color.questionFill)
        }
    }

    private static func draw(_ view: some View, to file: URL, size: CGSize?) {
        let renderer = ImageRenderer(content: view
            .frame(width: size?.width, height: size?.height)
            .environment(\.colorScheme, .dark)
            .environment(\.isSnapshotting, true))
        renderer.scale = 2
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let image = renderer.nsImage, let tiff = image.tiffRepresentation,
           let data = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            try? data.write(to: file)
        }
    }

    private static func line(_ moment: SearchMoment, in meeting: Meeting) -> String {
        let what: String
        switch moment.kind {
        case .line: what = "\(moment.speaker ?? ""): \(moment.text)"
        case .photo, .screenshot:
            what = "\(moment.kind == .photo ? "PHOTO" : "SCREEN") w\(String(format: "%.3f", moment.wordsScore)) l\(String(format: "%.3f", moment.lookScore)) \(moment.seen.prefix(90))"
        }
        let short = meeting.name.components(separatedBy: " - ").first ?? meeting.name
        return String(format: "%.3f", moment.score) + (moment.isExact ? " =" : "  ") + " \(short) [\(MeetingNaming.clock(moment.start))] " + what.replacingOccurrences(of: "\n", with: " / ")
    }
}
