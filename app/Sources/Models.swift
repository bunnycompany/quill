import Foundation

/// One capture session. Value type, Sendable across actor boundaries.
struct Recording: Identifiable, Sendable, Equatable {
    var id: Int64
    var startedAt: Date
    var durationSeconds: Double
    var title: String
    var audioPath: String?        // nil once audio has been pruned
    var contentHash: String       // SHA-256 of the audio; cache key
    var exportedPath: String?     // where ObsidianExporter wrote the .md
}

/// One diarized utterance.
struct Segment: Identifiable, Sendable, Equatable {
    var id: Int64
    var recordingID: Int64
    var speakerIndex: Int         // 0-based -> rendered as "Speaker 1"
    var startSeconds: Double
    var endSeconds: Double
    var text: String
}

/// The LocalAIParsingEngine's structured output, stored as one JSON blob.
struct ParsedNote: Codable, Sendable, Equatable {
    var attendees: [String]
    var actionItems: [String]
    var keyTakeaways: [String]
    var markdown: String          // final Dataview-ready markdown
}

/// A known voice: name + running-mean speaker embedding.
/// BIOMETRIC DATA — stored only in the local SQLite file, never networked,
/// deletable via QuillStore.deleteProfile(name:).
struct VoiceProfile: Sendable, Equatable {
    var name: String
    var centroid: [Float]         // L2-normalized
    var sampleCount: Int
}

/// Knobs for the pruning policy; will surface in Settings UI later.
struct PrunePolicy: Sendable, Equatable {
    var retentionDays: Int = 365      // segments + audio older than this go
    var maxCacheBytes: Int64 = 256 * 1024 * 1024
    var vacuumAfterPrune: Bool = false
}

/// What a prune pass actually did (for logging counts, never content).
struct PruneResult: Sendable, Equatable {
    var recordingsAffected: Int = 0
    var segmentsDeleted: Int = 0
    var cacheRowsEvicted: Int = 0
    var audioFilesDeleted: Int = 0
}
