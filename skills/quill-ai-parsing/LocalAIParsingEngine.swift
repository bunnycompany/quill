import Foundation
import FoundationModels

// MARK: - Chunking

/// Splits a transcript into token-budgeted chunks, cutting only on
/// speaker-turn boundaries. Stateless namespace (uninstantiable enum).
enum TranscriptChunker {
    /// ~4 chars/token is a serviceable English estimate.
    static func estimateTokens(_ text: String) -> Int { max(1, text.count / 4) }

    static func chunk(
        _ segments: [TranscriptSegment],
        budgetTokens: Int = 2500
    ) -> [[TranscriptSegment]] {
        var chunks: [[TranscriptSegment]] = []
        var current: [TranscriptSegment] = []
        var currentTokens = 0

        for seg in segments {
            let cost = estimateTokens("\(seg.speaker): \(seg.text)\n")
            if currentTokens + cost > budgetTokens && !current.isEmpty {
                chunks.append(current)
                current = []
                currentTokens = 0
            }
            current.append(seg)
            currentTokens += cost
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    static func promptText(for chunk: [TranscriptSegment]) -> String {
        chunk.map { "\($0.speaker): \($0.text)" }.joined(separator: "\n")
    }
}

// MARK: - Guided-generation schema (Foundation Models, macOS 26+)

@available(macOS 26.0, *)
@Generable
struct ChunkAnalysis {
    @Guide(description: "2-3 sentence factual summary of this transcript portion. Only facts stated in the transcript.")
    var summary: String

    @Guide(description: "Key decisions or important points, each a single short sentence.")
    var keyTakeaways: [String]

    @Guide(description: "Concrete tasks someone committed to. Empty if none.")
    var actionItems: [ExtractedAction]
}

@available(macOS 26.0, *)
@Generable
struct ExtractedAction {
    @Guide(description: "Speaker label of who owns the task, e.g. 'Speaker 1', or 'Unassigned'.")
    var owner: String

    @Guide(description: "The task, phrased as an imperative, under 15 words.")
    var task: String
}

// MARK: - Engine

actor LocalAIParsingEngine {

    enum EngineError: Error { case emptyTranscript }

    enum Progress: Sendable {
        case chunking, analyzing(chunk: Int, of: Int), reducing, done
    }

    func makeNote(
        from segments: [TranscriptSegment],
        metadata: MeetingMetadata,
        onProgress: @Sendable (Progress) -> Void = { _ in }
    ) async throws -> MeetingNote {
        guard !segments.isEmpty else { throw EngineError.emptyTranscript }

        onProgress(.chunking)
        let chunks = TranscriptChunker.chunk(segments)
        let attendees = Self.distinctSpeakers(in: segments)

        var analyses: [Analysis] = []
        analyses.reserveCapacity(chunks.count)

        for (i, chunk) in chunks.enumerated() {
            try Task.checkCancellation()   // Stop button aborts between chunks
            onProgress(.analyzing(chunk: i + 1, of: chunks.count))
            analyses.append(try await analyze(chunk: chunk))
        }

        onProgress(.reducing)
        try Task.checkCancellation()
        let merged = try await reduce(analyses)

        onProgress(.done)
        return MeetingNote(
            metadata: metadata,
            attendees: attendees,
            summary: merged.summary,
            keyTakeaways: merged.keyTakeaways,
            actionItems: merged.actionItems.map {
                MeetingNote.ActionItem(owner: $0.owner, task: $0.task)
            },
            speakerTimestamps: segments
        )
    }

    /// OS-version-independent internal analysis value.
    struct Analysis: Sendable {
        var summary: String
        var keyTakeaways: [String]
        var actionItems: [(owner: String, task: String)]
    }

    // MARK: Per-chunk analysis with availability fallback

    private func analyze(chunk: [TranscriptSegment]) async throws -> Analysis {
        if #available(macOS 26.0, *),
           case .available = SystemLanguageModel.default.availability {
            return try await analyzeWithModel(chunk: chunk)
        }
        return RuleBasedAnalyzer.analyze(chunk: chunk)
    }

    @available(macOS 26.0, *)
    private func analyzeWithModel(chunk: [TranscriptSegment]) async throws -> Analysis {
        // Fresh session per chunk: a session keeps its transcript in context,
        // and it is a local so it never outlives a cancelled task.
        let session = LanguageModelSession(instructions: """
            You analyze meeting transcript excerpts. Extract only facts \
            explicitly present in the transcript. Never invent names, dates, \
            or commitments. Speakers are labeled 'Speaker N'; refer to them \
            only by those labels.
            """)

        let prompt = """
            Analyze this meeting transcript excerpt:

            \(TranscriptChunker.promptText(for: chunk))
            """

        let response = try await session.respond(
            to: prompt,
            generating: ChunkAnalysis.self,
            options: GenerationOptions(temperature: 0.1)
        )
        let a = response.content
        return Analysis(
            summary: a.summary,
            keyTakeaways: a.keyTakeaways,
            actionItems: a.actionItems.map { ($0.owner, $0.task) }
        )
    }

    // MARK: Reduce

    private func reduce(_ analyses: [Analysis]) async throws -> Analysis {
        guard analyses.count > 1 else { return analyses[0] }

        let takeaways = Self.dedupe(analyses.flatMap(\.keyTakeaways))
        let actions = Self.dedupeActions(analyses.flatMap(\.actionItems))

        let combined = analyses.map(\.summary).joined(separator: " ")
        var finalSummary = combined
        if #available(macOS 26.0, *),
           case .available = SystemLanguageModel.default.availability {
            let session = LanguageModelSession(instructions:
                "You condense meeting notes. Be factual; add nothing new.")
            let response = try await session.respond(
                to: "Rewrite as one coherent 2-4 sentence meeting summary:\n\n\(combined)",
                generating: String.self,
                options: GenerationOptions(temperature: 0.1)
            )
            finalSummary = response.content
        }
        return Analysis(summary: finalSummary,
                        keyTakeaways: takeaways,
                        actionItems: actions)
    }

    // MARK: Deterministic helpers

    static func distinctSpeakers(in segments: [TranscriptSegment]) -> [String] {
        var seen = Set<String>(), out: [String] = []
        for s in segments where seen.insert(s.speaker).inserted { out.append(s.speaker) }
        return out.sorted()
    }

    static func dedupe(_ items: [String]) -> [String] {
        var seen = Set<String>(), out: [String] = []
        for i in items {
            let key = i.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            if seen.insert(key).inserted { out.append(i) }
        }
        return out
    }

    static func dedupeActions(_ items: [(owner: String, task: String)])
        -> [(owner: String, task: String)] {
        var seen = Set<String>(), out: [(String, String)] = []
        for i in items where seen.insert(i.task.lowercased()).inserted { out.append(i) }
        return out
    }
}

// MARK: - Rule-based fallback (no Apple Intelligence required)

enum RuleBasedAnalyzer {
    private static let commitmentMarkers = [
        "i'll ", "i will ", "we'll ", "we will ", "we need to ", "i need to ",
        "let's ", "todo", "action item", "follow up", "make sure"
    ]

    static func analyze(chunk: [TranscriptSegment]) -> LocalAIParsingEngine.Analysis {
        var actions: [(owner: String, task: String)] = []
        for seg in chunk {
            let lower = seg.text.lowercased()
            if commitmentMarkers.contains(where: lower.contains) {
                actions.append((owner: seg.speaker,
                                task: String(seg.text.prefix(120))))
            }
        }
        var longest: [String: TranscriptSegment] = [:]
        for seg in chunk where seg.text.count > (longest[seg.speaker]?.text.count ?? 0) {
            longest[seg.speaker] = seg
        }
        let takeaways = longest.values
            .sorted { $0.start < $1.start }
            .map { "\($0.speaker): \(String($0.text.prefix(140)))" }

        let speakers = LocalAIParsingEngine.distinctSpeakers(in: chunk)
        let minutes = Int(((chunk.last?.end ?? 0) - (chunk.first?.start ?? 0)) / 60)
        return .init(
            summary: "Discussion between \(speakers.joined(separator: ", ")) "
                   + "covering \(chunk.count) exchanges over ~\(max(minutes, 1)) minutes. "
                   + "(On-device AI unavailable; rule-based summary.)",
            keyTakeaways: takeaways,
            actionItems: actions
        )
    }
}
