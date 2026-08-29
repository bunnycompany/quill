import Foundation
import SQLite3

/// All schema changes, in order. NEVER edit or reorder a shipped entry —
/// only append. `PRAGMA user_version` records how far a given database
/// file has been upgraded.
enum Migrations {
    /// Index i holds the SQL that upgrades user_version i -> i+1.
    static let all: [String] = [
        // v0 -> v1: initial schema.
        """
        CREATE TABLE recording (
            id               INTEGER PRIMARY KEY,
            started_at       REAL    NOT NULL,
            duration_seconds REAL    NOT NULL DEFAULT 0,
            title            TEXT    NOT NULL,
            audio_path       TEXT,
            content_hash     TEXT    NOT NULL UNIQUE,
            exported_path    TEXT
        );
        CREATE INDEX idx_recording_started ON recording(started_at DESC);

        CREATE TABLE segment (
            id             INTEGER PRIMARY KEY,
            recording_id   INTEGER NOT NULL
                           REFERENCES recording(id) ON DELETE CASCADE,
            speaker_index  INTEGER NOT NULL,
            start_seconds  REAL    NOT NULL,
            end_seconds    REAL    NOT NULL,
            text           TEXT    NOT NULL
        );
        CREATE INDEX idx_segment_recording ON segment(recording_id);

        CREATE TABLE note (
            recording_id INTEGER PRIMARY KEY
                         REFERENCES recording(id) ON DELETE CASCADE,
            json         TEXT NOT NULL,
            markdown     TEXT NOT NULL,
            created_at   REAL NOT NULL
        );
        """,
        // v1 -> v2: transcript cache keyed by audio content hash.
        """
        CREATE TABLE transcript_cache (
            content_hash     TEXT PRIMARY KEY,
            payload_json     TEXT NOT NULL,
            created_at       REAL NOT NULL,
            last_accessed_at REAL NOT NULL,
            byte_size        INTEGER NOT NULL
        );
        CREATE INDEX idx_cache_accessed ON transcript_cache(last_accessed_at);
        """,
    ]

    /// Runs every not-yet-applied migration, each in its own transaction.
    static func migrate(_ db: OpaquePointer) throws {
        var current = Int(readUserVersion(db))
        while current < all.count {
            let sql = all[current]
            try exec(db, "BEGIN IMMEDIATE")
            do {
                try exec(db, sql)
                try exec(db, "PRAGMA user_version = \(current + 1)")
                try exec(db, "COMMIT")
            } catch {
                try? exec(db, "ROLLBACK")
                throw StoreError.migrationFailed(
                    version: current + 1,
                    message: String(cString: sqlite3_errmsg(db)))
            }
            current += 1
        }
    }

    private static func readUserVersion(_ db: OpaquePointer) -> Int32 {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA user_version", -1, &stmt, nil)
                == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW ? sqlite3_column_int(stmt, 0) : 0
    }

    /// sqlite3_exec runs multi-statement SQL strings (perfect for DDL).
    static func exec(_ db: OpaquePointer, _ sql: String) throws {
        var errMsg: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &errMsg) == SQLITE_OK else {
            let message = errMsg.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(errMsg)
            throw StoreError.stepFailed(sql: sql, message: message)
        }
    }
}
