import Foundation

// MARK: - Input types (from DiarizationEngine, module 3a)

/// One diarized utterance. Struct of value types: Sendable and Codable for free.
struct TranscriptSegment: Codable, Sendable, Equatable {
    let speaker: String        // "Speaker 1", "Speaker 2", …
    let text: String
    let start: TimeInterval    // seconds from meeting start
    let end: TimeInterval
}

/// Facts known before analysis (the recorder supplies these).
struct MeetingMetadata: Codable, Sendable {
    let title: String
    let date: Date
    let duration: TimeInterval
}

// MARK: - Output model

struct MeetingNote: Codable, Sendable {
    let metadata: MeetingMetadata
    let attendees: [String]
    let summary: String
    let keyTakeaways: [String]
    let actionItems: [ActionItem]
    /// Transcript shown in the note body (cleaned when the AI pass ran).
    let speakerTimestamps: [TranscriptSegment]
    /// True when an on-device model produced the summary/takeaways/actions.
    /// False → rule-based path: the renderer emits a warning callout and
    /// omits the analysis sections instead of presenting noise as insight.
    var usedAI: Bool = false
    /// The untouched transcript, kept in a collapsed block whenever the
    /// AI cleanup rewrote `speakerTimestamps`. Nil when the main transcript
    /// is already verbatim.
    var verbatimTranscript: [TranscriptSegment]? = nil

    struct ActionItem: Codable, Sendable {
        let owner: String      // a speaker label, or "Unassigned"
        let task: String
    }
}

// MARK: - Deterministic markdown renderer

extension MeetingNote {
    /// True when an AI pass rewrote the transcript, so a distinct cleaned
    /// version exists that is worth filing separately from the raw record.
    var hasCleanedTranscript: Bool {
        usedAI && (verbatimTranscript?.isEmpty == false)
    }

    /// How the transcript section is rendered.
    /// - standard: cleaned body + collapsed verbatim (single self-contained note)
    /// - rawOnly:  the untouched transcript only — the canonical archival note
    /// - cleanedOnly: the cleaned transcript only — filed under Meetings/cleaned/
    enum Rendering { case standard, rawOnly, cleanedOnly }

    /// Same MeetingNote -> byte-identical markdown. The LLM never writes markdown;
    /// this function does, so Obsidian Dataview fields stay machine-stable.
    /// `crossLink` (a bare note name) adds a one-line pointer to the sibling
    /// raw/cleaned note so the two folders stay navigable.
    func renderMarkdown(_ mode: Rendering = .standard,
                        crossLink: String? = nil) -> String {
        let day = Self.dayFormatter.string(from: metadata.date)
        let minutes = Int((metadata.duration / 60).rounded())

        var md = """
        ---
        type: meeting
        title: "\(metadata.title.replacingOccurrences(of: "\"", with: "'"))"
        date: \(day)
        duration: \(minutes)
        attendees: [\(attendees.map { "\"\($0)\"" }.joined(separator: ", "))]
        ---

        # \(metadata.title)
        """

        if mode == .cleanedOnly {
            md += "\n\n> [!note] AI-cleaned transcript. The verbatim record is in [[\(crossLink ?? "the raw note")]]."
        } else if let crossLink, hasCleanedTranscript {
            md += "\n\n> [!note] A cleaned-up transcript is in [[\(crossLink)]]."
        }

        if !usedAI {
            // Honest labeling: the rule-based path cannot analyze content,
            // so we say so instead of dressing statistics up as insight.
            md += "\n\n> [!warning] Transcript only — no AI summary was generated on this pass."
        }

        md += "\n\n## Summary\n\(summary)"

        // Analysis sections come only from a real model. The rule-based
        // path leaves them empty and they are omitted entirely.
        if usedAI {
            md += "\n\n## Key Takeaways"
            if keyTakeaways.isEmpty { md += "\n- *(none identified)*" }
            for t in keyTakeaways { md += "\n- \(t)" }

            md += "\n\n## Action Items"
            if actionItems.isEmpty {
                md += "\n- *(none identified)*"
            } else {
                for item in actionItems {
                    md += "\n- [ ] \(item.task) *(\(item.owner))*"
                }
            }
        }

        // Pick the transcript for this rendering. `speakerTimestamps` holds the
        // cleaned text when the AI pass ran; `verbatimTranscript` holds the raw.
        let body: [TranscriptSegment]
        switch mode {
        case .cleanedOnly: body = speakerTimestamps
        case .rawOnly:     body = verbatimTranscript ?? speakerTimestamps
        case .standard:    body = speakerTimestamps
        }

        md += "\n\n## Speaker Timestamps\n"
        for seg in body {
            md += "\n**[\(Self.timestamp(seg.start))] \(seg.speaker):** \(seg.text)"
        }

        // Only the self-contained note buries the verbatim inline; the split
        // rawOnly/cleanedOnly notes live in separate files instead.
        if mode == .standard, let verbatim = verbatimTranscript, !verbatim.isEmpty {
            md += "\n\n<details><summary>Verbatim transcript</summary>\n"
            for seg in verbatim {
                md += "\n**[\(Self.timestamp(seg.start))] \(seg.speaker):** \(seg.text)"
            }
            md += "\n\n</details>"
        }
        return md + "\n"
    }

    private static func timestamp(_ t: TimeInterval) -> String {
        let s = Int(t)
        return String(format: "%02d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
    }

    /// en_US_POSIX: immune to user locale/calendar, per Apple's guidance for
    /// machine-readable dates. Static let = created once, thread-safe.
    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        return f
    }()
}
