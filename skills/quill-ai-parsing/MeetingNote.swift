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
    let speakerTimestamps: [TranscriptSegment]

    struct ActionItem: Codable, Sendable {
        let owner: String      // a speaker label, or "Unassigned"
        let task: String
    }
}

// MARK: - Deterministic markdown renderer

extension MeetingNote {
    /// Same MeetingNote -> byte-identical markdown. The LLM never writes markdown;
    /// this function does, so Obsidian Dataview fields stay machine-stable.
    func renderMarkdown() -> String {
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

        ## Summary
        \(summary)

        ## Key Takeaways
        """
        for t in keyTakeaways { md += "\n- \(t)" }

        md += "\n\n## Action Items"
        if actionItems.isEmpty {
            md += "\n- *(none identified)*"
        } else {
            for item in actionItems {
                md += "\n- [ ] \(item.task) *(\(item.owner))*"
            }
        }

        md += "\n\n## Speaker Timestamps\n"
        for seg in speakerTimestamps {
            md += "\n**[\(Self.timestamp(seg.start))] \(seg.speaker):** \(seg.text)"
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
