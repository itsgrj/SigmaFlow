import Foundation
import Testing

@testable import SigmaFlowDictionary

/// Runs the shared behavioural contract in `shared/dictionary-test-vectors.json`.
///
/// The Windows app reimplements this logic in C# and runs the identical file. That's the
/// only thing keeping two independent implementations honest — there's no shared binary, and
/// no Windows machine to check against by hand.
struct VectorTests {
    struct Vectors: Decodable {
        let version: Int
        let cases: [Case]
        let learningCases: [LearningCase]
    }

    struct Case: Decodable {
        let name: String
        let entries: [Entry]
        let input: String
        let expected: String
        let expectedCorrections: [ExpectedCorrection]
    }

    struct Entry: Decodable {
        let kind: String
        var hear: String?
        let write: String
        var isEnabled: Bool?

        var asEntry: DictionaryEntry {
            DictionaryEntry(
                kind: kind == "correction" ? .correction : .term,
                write: write,
                hear: hear ?? "",
                isEnabled: isEnabled ?? true
            )
        }
    }

    struct ExpectedCorrection: Decodable {
        let to: String
        let count: Int
    }

    /// One before/after edit and the rule, if any, SigmaFlow may offer for it.
    struct LearningCase: Decodable {
        let name: String
        let before: String
        let after: String
        /// Both present when a rule may be offered; both absent when the edit must be
        /// refused. Refusals are most of the file, and the reason it exists.
        let hear: String?
        let write: String?

        var expected: LearnedCorrection? {
            guard let hear, let write else { return nil }
            return LearnedCorrection(hear: hear, write: write)
        }
    }

    static func load() throws -> Vectors {
        let url = try #require(
            Bundle.module.url(forResource: "dictionary-test-vectors", withExtension: "json")
        )
        return try JSONDecoder().decode(Vectors.self, from: Data(contentsOf: url))
    }

    @Test("every shared vector produces the contracted output")
    func vectors() throws {
        let vectors = try Self.load()
        #expect(vectors.cases.isEmpty == false)

        for testCase in vectors.cases {
            let corrector = DictionaryCorrector(entries: testCase.entries.map(\.asEntry))
            let (text, applied) = corrector.apply(to: testCase.input)

            #expect(text == testCase.expected, "\(testCase.name): text")
            #expect(
                applied.count == testCase.expectedCorrections.count,
                "\(testCase.name): correction count — got \(applied.map(\.to))"
            )

            // Order-insensitive: which rule fires first is an implementation detail of the
            // longest-first sort, but *what* fired and how often is contractual.
            for expected in testCase.expectedCorrections {
                let match = applied.first { $0.to == expected.to }
                #expect(match != nil, "\(testCase.name): expected a correction to “\(expected.to)”")
                #expect(match?.count == expected.count, "\(testCase.name): count for “\(expected.to)”")
            }
        }
    }

    @Test("every learning vector is offered or refused as contracted")
    func learningVectors() throws {
        let vectors = try Self.load()
        #expect(vectors.learningCases.isEmpty == false)

        for testCase in vectors.learningCases {
            let proposed = LearnedCorrection.propose(from: testCase.before, to: testCase.after)
            let got = proposed.map { $0.hear + " → " + $0.write } ?? "no proposal"
            #expect(proposed == testCase.expected, "\(testCase.name): got \(got)")
        }
    }

    @Test("bias list is capped and de-duplicated")
    func biasList() {
        let entries = (0..<100).map { DictionaryEntry.term("Word\($0)") }
            + [DictionaryEntry.term("Word0")]
        let phrases = DictionaryCorrector.biasPhrases(from: entries)

        #expect(phrases.count == DictionaryCorrector.biasLimit)
        #expect(Set(phrases).count == phrases.count)
    }

    @Test("disabled entries are excluded from biasing")
    func biasSkipsDisabled() {
        let entries = [
            DictionaryEntry(kind: .term, write: "Kept"),
            DictionaryEntry(kind: .term, write: "Skipped", isEnabled: false),
        ]
        #expect(DictionaryCorrector.biasPhrases(from: entries) == ["Kept"])
    }

    @Test("an ordinary word used as a trigger is flagged")
    func warnsOnCommonWord() {
        let entry = DictionaryEntry.correction(hear: "cloud", write: "Claude")
        #expect(DictionaryWarning.check(entry).isEmpty == false)
    }

    @Test("a distinctive phrase is not flagged")
    func doesNotWarnOnDistinctivePhrase() {
        let entry = DictionaryEntry.correction(hear: "clawed code", write: "Claude Code")
        #expect(DictionaryWarning.check(entry).isEmpty)
    }
}
