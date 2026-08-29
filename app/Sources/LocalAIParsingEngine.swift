import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

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

// MARK: - Apple Intelligence availability

/// One place to answer "can the on-device model run right now?". Used by
/// the UI (show the toggle only when true) and the engine (silent fallback).
enum AppleIntelligence {
    static var isAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            if case .available = SystemLanguageModel.default.availability {
                return true
            }
        }
        #endif
        return false
    }
}

// MARK: - Engine

actor LocalAIParsingEngine {

    enum EngineError: Error { case emptyTranscript }

    enum Progress: Sendable {
        case chunking, analyzing(chunk: Int, of: Int), reducing, done
    }

    /// `cleanupEnabled`: user opt-in ("Clean up transcript"). Only when it
    /// is on AND the on-device model is available does any AI run; every
    /// failure silently falls back to the raw transcript — the note is
    /// never lost to the model.
    /// `lexicon`: vocabulary the cleaner may correct mis-hearings toward.
    func makeNote(
        from segments: [TranscriptSegment],
        metadata: MeetingMetadata,
        cleanupEnabled: Bool = false,
        lexicon: [String] = [],
        onProgress: @Sendable (Progress) -> Void = { _ in }
    ) async throws -> MeetingNote {
        guard !segments.isEmpty else { throw EngineError.emptyTranscript }

        onProgress(.chunking)
        let chunks = TranscriptChunker.chunk(segments)
        let attendees = Self.distinctSpeakers(in: segments)

        // ---- Optional Apple Intelligence pass (OFF by default) -------------
        var noteSegments = segments          // what the note body shows
        var verbatim: [TranscriptSegment]?   // collapsed block when cleaned
        var aiAnalysis: Analysis?

        #if canImport(FoundationModels)
        if cleanupEnabled, #available(macOS 26.0, *), AppleIntelligence.isAvailable {
            let cleaner = TranscriptCleaner(lexicon: lexicon)
            var cleaned: [TranscriptSegment] = []
            var anyCleaned = false
            for (i, chunk) in chunks.enumerated() {
                try Task.checkCancellation()
                onProgress(.analyzing(chunk: i + 1, of: chunks.count))
                let result = await cleaner.clean(chunk: chunk)
                anyCleaned = anyCleaned || result.changed
                cleaned.append(contentsOf: result.segments)
            }
            if anyCleaned {
                noteSegments = cleaned
                verbatim = segments
            }
            // Real analysis from the model; nil on any failure → honest
            // rule-based fallback below.
            onProgress(.reducing)
            aiAnalysis = await Self.analyzeWithModel(chunks: chunks)
        }
        #endif

        // ---- Fallback: factual, non-interpretive note ----------------------
        // The rule-based path does NOT invent takeaways or action items.
        let analysis = aiAnalysis ?? Self.factualAnalysis(segments: segments,
                                                          metadata: metadata)

        onProgress(.done)
        return MeetingNote(
            metadata: metadata,
            attendees: attendees,
            summary: analysis.summary,
            keyTakeaways: analysis.keyTakeaways,
            actionItems: analysis.actionItems.map {
                MeetingNote.ActionItem(owner: $0.owner, task: $0.task)
            },
            speakerTimestamps: noteSegments,
            usedAI: aiAnalysis != nil,
            verbatimTranscript: verbatim
        )
    }

    /// OS-version-independent internal analysis value.
    struct Analysis: Sendable {
        var summary: String
        var keyTakeaways: [String]
        var actionItems: [(owner: String, task: String)]
    }

    // MARK: Rule-based path — facts only, no fabricated analysis

    /// Duration, speaker count, word count. Nothing interpretive: without a
    /// real model we refuse to dress statistics up as insight.
    static func factualAnalysis(segments: [TranscriptSegment],
                                metadata: MeetingMetadata) -> Analysis {
        let minutes = max(1, Int((metadata.duration / 60).rounded()))
        let speakers = distinctSpeakers(in: segments).count
        let words = segments.reduce(0) {
            $0 + $1.text.split(separator: " ").count
        }
        return Analysis(
            summary: "\(minutes) min recording · \(speakers) speaker\(speakers == 1 ? "" : "s") · ~\(words) words transcribed.",
            keyTakeaways: [],
            actionItems: []
        )
    }

    // MARK: - Apple Intelligence analysis

    #if canImport(FoundationModels)
    /// Ask the on-device model for a summary, takeaways and action items.
    /// Returns nil on ANY failure so the caller falls back cleanly.
    @available(macOS 26.0, *)
    private static func analyzeWithModel(chunks: [[TranscriptSegment]]) async -> Analysis? {
        var partials: [Analysis] = []
        for chunk in chunks {
            guard !Task.isCancelled else { return nil }
            let instructions = """
            You summarize meeting transcripts. Given a transcript excerpt, \
            respond with EXACTLY this plain-text format and nothing else:
            SUMMARY: <2-3 sentence factual summary>
            TAKEAWAY: <one key point> (repeat the TAKEAWAY line per point, max 5)
            ACTION: <speaker label> | <committed task> (repeat per item; omit if none)
            Only report what is actually said. Never invent content.
            """
            do {
                let session = LanguageModelSession(instructions: instructions)
                let reply = try await session.respond(
                    to: TranscriptChunker.promptText(for: chunk))
                partials.append(parseAnalysis(reply.content))
            } catch {
                return nil   // any model failure → rule-based fallback
            }
        }
        guard !partials.isEmpty else { return nil }
        return Analysis(
            summary: partials.map(\.summary).filter { !$0.isEmpty }
                .joined(separator: " "),
            keyTakeaways: dedupe(partials.flatMap(\.keyTakeaways)),
            actionItems: dedupeActions(partials.flatMap(\.actionItems))
        )
    }

    private static func parseAnalysis(_ text: String) -> Analysis {
        var summary = "", takeaways: [String] = []
        var actions: [(owner: String, task: String)] = []
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("SUMMARY:") {
                summary += (summary.isEmpty ? "" : " ")
                    + line.dropFirst(8).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("TAKEAWAY:") {
                let t = line.dropFirst(9).trimmingCharacters(in: .whitespaces)
                if !t.isEmpty { takeaways.append(t) }
            } else if line.hasPrefix("ACTION:") {
                let rest = line.dropFirst(7)
                let parts = rest.split(separator: "|", maxSplits: 1)
                let owner = parts.first.map {
                    $0.trimmingCharacters(in: .whitespaces) } ?? "Unassigned"
                let task = parts.count > 1
                    ? parts[1].trimmingCharacters(in: .whitespaces)
                    : rest.trimmingCharacters(in: .whitespaces)
                if !task.isEmpty {
                    actions.append((owner: owner.isEmpty ? "Unassigned" : owner,
                                    task: task))
                }
            }
        }
        return Analysis(summary: summary, keyTakeaways: takeaways,
                        actionItems: actions)
    }
    #endif

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

// MARK: - Transcript cleaner (Apple Intelligence, optional)

#if canImport(FoundationModels)
/// Per-batch cleanup of the raw transcript: punctuation, casing, filler
/// words, and mis-hearings corrected ONLY toward phonetically-close lexicon
/// terms. Content must never be added or removed — the instructions forbid
/// it, and any error keeps the raw text.
@available(macOS 26.0, *)
struct TranscriptCleaner {
    let lexicon: [String]

    struct Result {
        let segments: [TranscriptSegment]
        let changed: Bool
    }

    /// Clean one chunk of utterances. Errors → raw text back, unchanged.
    func clean(chunk: [TranscriptSegment]) async -> Result {
        let vocab = lexicon.prefix(100).joined(separator: ", ")
        let instructions = """
        You clean up automatic speech-recognition transcripts. For each \
        input line "N: text", output the SAME number of lines "N: cleaned \
        text" in the same order. Fix punctuation and casing, remove \
        disfluencies (um, uh, false starts). If a word looks like a \
        mis-hearing of one of these known terms, and ONLY if it sounds \
        phonetically close, replace it with the term: \(vocab.isEmpty ? "(none)" : vocab). \
        NEVER add new content, never drop sentences, never paraphrase or \
        summarize. Output only the numbered lines.
        """
        let numbered = chunk.enumerated()
            .map { "\($0.offset): \($0.element.text)" }
            .joined(separator: "\n")
        do {
            let session = LanguageModelSession(instructions: instructions)
            let reply = try await session.respond(to: numbered)

            // Map "N: text" replies back onto segments; any line the model
            // failed to return keeps its raw text.
            var cleanedByIndex: [Int: String] = [:]
            for raw in reply.content.split(separator: "\n") {
                let line = raw.trimmingCharacters(in: .whitespaces)
                guard let colon = line.firstIndex(of: ":"),
                      let idx = Int(line[line.startIndex..<colon]) else { continue }
                let text = line[line.index(after: colon)...]
                    .trimmingCharacters(in: .whitespaces)
                if !text.isEmpty { cleanedByIndex[idx] = text }
            }
            var changed = false
            let out = chunk.enumerated().map { i, seg -> TranscriptSegment in
                guard let text = cleanedByIndex[i], text != seg.text else { return seg }
                changed = true
                return TranscriptSegment(speaker: seg.speaker, text: text,
                                         start: seg.start, end: seg.end)
            }
            return Result(segments: out, changed: changed)
        } catch {
            return Result(segments: chunk, changed: false)   // silent fallback
        }
    }
}
#endif
