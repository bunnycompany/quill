import Foundation
import SQLite3

/// Quill's local history & cache. An actor: the compiler guarantees only
/// one task at a time touches the (non-thread-safe) SQLite connection.
/// Privacy invariant: this file must never import networking of any kind.
actor QuillStore {

    // MARK: - State

    private let db: OpaquePointer
    private let jsonEncoder = JSONEncoder()
    private let jsonDecoder = JSONDecoder()

    // MARK: - Lifecycle

    /// Default on-disk location: ~/Library/Application Support/Quill/quill.sqlite
    static func defaultURL() throws -> URL {
        let dir = try FileManager.default
            .url(for: .applicationSupportDirectory, in: .userDomainMask,
                 appropriateFor: nil, create: true)
            .appendingPathComponent("Quill", isDirectory: true)
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("quill.sqlite")
    }

    init(url: URL) throws {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
                  | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url.path, &handle, flags, nil) == SQLITE_OK,
              let handle else {
            let msg = handle.map { String(cString: sqlite3_errmsg($0)) }
                      ?? "out of memory"
            sqlite3_close(handle)              // must close even on failure
            throw StoreError.openFailed(message: msg)
        }
        db = handle
        try Migrations.exec(db, "PRAGMA journal_mode = WAL")
        try Migrations.exec(db, "PRAGMA foreign_keys = ON")   // OFF by default!
        try Migrations.exec(db, "PRAGMA busy_timeout = 5000")
        try Migrations.migrate(db)
    }

    deinit {
        // Backstop, not primary cleanup: v2 close survives leaked statements.
        sqlite3_close_v2(db)
    }

    // MARK: - Low-level helpers

    /// Binds a heterogeneous parameter list to ?1, ?2, ... (1-indexed!).
    private func prepare(_ sql: String,
                         _ params: [(any Sendable)?]) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK,
              let stmt else {
            throw StoreError.prepareFailed(
                sql: sql, message: String(cString: sqlite3_errmsg(db)))
        }
        for (i, param) in params.enumerated() {
            let idx = Int32(i + 1)
            switch param {
            case nil:               sqlite3_bind_null(stmt, idx)
            case let v as Int64:    sqlite3_bind_int64(stmt, idx, v)
            case let v as Int:      sqlite3_bind_int64(stmt, idx, Int64(v))
            case let v as Double:   sqlite3_bind_double(stmt, idx, v)
            case let v as String:   sqlite3_bind_text(stmt, idx, v, -1,
                                                      SQLITE_TRANSIENT)
            case let v as Date:     sqlite3_bind_double(
                                        stmt, idx, v.timeIntervalSince1970)
            default:
                sqlite3_finalize(stmt)         // no leaks on error paths
                throw StoreError.prepareFailed(
                    sql: sql, message: "unsupported bind type")
            }
        }
        return stmt
    }

    /// Runs a statement expected to produce no rows.
    private func run(_ sql: String,
                     _ params: [(any Sendable)?] = []) throws {
        let stmt = try prepare(sql, params)
        defer { sqlite3_finalize(stmt) }       // ALWAYS finalize
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw StoreError.stepFailed(
                sql: sql, message: String(cString: sqlite3_errmsg(db)))
        }
    }

    /// NULL-safe text column read (Exercise 1's answer, used throughout).
    private func columnText(_ stmt: OpaquePointer?, _ index: Int32) -> String? {
        guard let c = sqlite3_column_text(stmt, index) else { return nil }
        return String(cString: c)
    }

    private func transaction<T>(_ body: () throws -> T) throws -> T {
        try Migrations.exec(db, "BEGIN IMMEDIATE")
        do {
            let result = try body()
            try Migrations.exec(db, "COMMIT")
            return result
        } catch {
            try? Migrations.exec(db, "ROLLBACK")
            throw error
        }
    }

    // MARK: - Recordings

    @discardableResult
    func insertRecording(startedAt: Date, title: String,
                         audioPath: String?, contentHash: String) throws -> Int64 {
        try run("""
            INSERT INTO recording
                (started_at, duration_seconds, title, audio_path, content_hash)
            VALUES (?1, 0, ?2, ?3, ?4)
            """, [startedAt, title, audioPath, contentHash])
        return sqlite3_last_insert_rowid(db)
    }

    func updateDuration(recordingID: Int64, seconds: Double) throws {
        try run("UPDATE recording SET duration_seconds = ?1 WHERE id = ?2",
                [seconds, recordingID])
    }

    func markExported(recordingID: Int64, path: String) throws {
        try run("UPDATE recording SET exported_path = ?1 WHERE id = ?2",
                [path, recordingID])
    }

    func deleteRecording(id: Int64) throws {
        // Segments and note go with it via ON DELETE CASCADE.
        try run("DELETE FROM recording WHERE id = ?1", [id])
    }

    func recentRecordings(limit: Int = 50) throws -> [Recording] {
        let stmt = try prepare("""
            SELECT id, started_at, duration_seconds, title,
                   audio_path, content_hash, exported_path
            FROM recording ORDER BY started_at DESC LIMIT ?1
            """, [limit])
        defer { sqlite3_finalize(stmt) }
        var out: [Recording] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.append(Recording(
                id: sqlite3_column_int64(stmt, 0),
                startedAt: Date(timeIntervalSince1970:
                                sqlite3_column_double(stmt, 1)),
                durationSeconds: sqlite3_column_double(stmt, 2),
                title: columnText(stmt, 3) ?? "",
                audioPath: columnText(stmt, 4),
                contentHash: columnText(stmt, 5) ?? "",
                exportedPath: columnText(stmt, 6)))
        }
        return out
    }

    // MARK: - Segments

    /// Bulk insert in one transaction: atomic and ~100x faster than
    /// row-by-row autocommit.
    func insertSegments(_ segments: [Segment], recordingID: Int64) throws {
        try transaction {
            for s in segments {
                try run("""
                    INSERT INTO segment
                        (recording_id, speaker_index, start_seconds,
                         end_seconds, text)
                    VALUES (?1, ?2, ?3, ?4, ?5)
                    """, [recordingID, s.speakerIndex,
                          s.startSeconds, s.endSeconds, s.text])
            }
        }
    }

    func segments(recordingID: Int64) throws -> [Segment] {
        let stmt = try prepare("""
            SELECT id, recording_id, speaker_index,
                   start_seconds, end_seconds, text
            FROM segment WHERE recording_id = ?1 ORDER BY start_seconds
            """, [recordingID])
        defer { sqlite3_finalize(stmt) }
        var out: [Segment] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.append(Segment(
                id: sqlite3_column_int64(stmt, 0),
                recordingID: sqlite3_column_int64(stmt, 1),
                speakerIndex: Int(sqlite3_column_int64(stmt, 2)),
                startSeconds: sqlite3_column_double(stmt, 3),
                endSeconds: sqlite3_column_double(stmt, 4),
                text: columnText(stmt, 5) ?? ""))
        }
        return out
    }

    // MARK: - Notes

    func saveNote(_ note: ParsedNote, recordingID: Int64) throws {
        let json = String(decoding: try jsonEncoder.encode(note),
                          as: UTF8.self)
        try run("""
            INSERT INTO note (recording_id, json, markdown, created_at)
            VALUES (?1, ?2, ?3, ?4)
            ON CONFLICT(recording_id) DO UPDATE SET
                json = excluded.json,
                markdown = excluded.markdown,
                created_at = excluded.created_at
            """, [recordingID, json, note.markdown, Date()])
    }

    func note(recordingID: Int64) throws -> ParsedNote? {
        let stmt = try prepare(
            "SELECT json FROM note WHERE recording_id = ?1", [recordingID])
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW,
              let json = columnText(stmt, 0) else { return nil }
        return try? jsonDecoder.decode(ParsedNote.self,
                                       from: Data(json.utf8))
    }

    // MARK: - Transcript cache

    /// Upsert the expensive pipeline output keyed by audio content hash.
    func cacheTranscript(contentHash: String, payloadJSON: String) throws {
        try run("""
            INSERT INTO transcript_cache
                (content_hash, payload_json, created_at,
                 last_accessed_at, byte_size)
            VALUES (?1, ?2, ?3, ?3, ?4)
            ON CONFLICT(content_hash) DO UPDATE SET
                payload_json = excluded.payload_json,
                last_accessed_at = excluded.last_accessed_at,
                byte_size = excluded.byte_size
            """, [contentHash, payloadJSON, Date(),
                  Int64(payloadJSON.utf8.count)])
    }

    /// Returns the cached payload and bumps last_accessed_at (LRU signal).
    func cachedTranscript(contentHash: String) throws -> String? {
        let stmt = try prepare("""
            SELECT payload_json FROM transcript_cache WHERE content_hash = ?1
            """, [contentHash])
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW,
              let payload = columnText(stmt, 0) else { return nil }
        try run("""
            UPDATE transcript_cache SET last_accessed_at = ?1
            WHERE content_hash = ?2
            """, [Date(), contentHash])
        return payload
    }

    // MARK: - Pruning

    /// Applies Quill's retention policy. Old recordings keep their history
    /// row and note markdown, but lose raw segments and the audio file.
    /// The cache is trimmed LRU-first to its byte budget.
    func prune(policy: PrunePolicy = PrunePolicy()) throws -> PruneResult {
        var result = PruneResult()
        let cutoff = Date().addingTimeInterval(
            -Double(policy.retentionDays) * 86_400).timeIntervalSince1970

        // Pass 1: delete expired audio files from disk (outside the
        // transaction — file I/O shouldn't hold a write lock).
        let pathsStmt = try prepare("""
            SELECT audio_path FROM recording
            WHERE started_at < ?1 AND audio_path IS NOT NULL
            """, [cutoff])
        var paths: [String] = []
        while sqlite3_step(pathsStmt) == SQLITE_ROW {
            if let p = columnText(pathsStmt, 0) { paths.append(p) }
        }
        sqlite3_finalize(pathsStmt)
        for p in paths where FileManager.default.fileExists(atPath: p) {
            try? FileManager.default.removeItem(atPath: p)
            result.audioFilesDeleted += 1
        }

        // Pass 2: one transaction for all row changes.
        try transaction {
            try run("""
                DELETE FROM segment WHERE recording_id IN
                    (SELECT id FROM recording WHERE started_at < ?1)
                """, [cutoff])
            result.segmentsDeleted = Int(sqlite3_changes(db))

            try run("""
                UPDATE recording SET audio_path = NULL
                WHERE started_at < ?1 AND audio_path IS NOT NULL
                """, [cutoff])
            result.recordingsAffected = Int(sqlite3_changes(db))

            // Cache budget: delete LRU rows past the cutoff found by a
            // running-total window scan (newest-first).
            try run("""
                DELETE FROM transcript_cache WHERE last_accessed_at <= COALESCE(
                  (SELECT last_accessed_at FROM (
                      SELECT last_accessed_at,
                             SUM(byte_size) OVER (ORDER BY last_accessed_at DESC
                                 ROWS UNBOUNDED PRECEDING) AS running
                      FROM transcript_cache)
                   WHERE running > ?1
                   ORDER BY last_accessed_at DESC LIMIT 1), -1)
                """, [policy.maxCacheBytes])
            result.cacheRowsEvicted = Int(sqlite3_changes(db))
        }

        // VACUUM must run OUTSIDE any transaction.
        if policy.vacuumAfterPrune {
            try Migrations.exec(db, "VACUUM")
        }
        return result
    }
}
