-- Quill local history & cache: full DDL (result of running all migrations).
-- Timestamps: Unix epoch seconds (REAL). All data local-only.
PRAGMA journal_mode = WAL;
PRAGMA foreign_keys = ON;      -- per-connection; set on every open!

CREATE TABLE recording (
    id               INTEGER PRIMARY KEY,          -- rowid alias
    started_at       REAL    NOT NULL,             -- epoch seconds
    duration_seconds REAL    NOT NULL DEFAULT 0,
    title            TEXT    NOT NULL,             -- e.g. "2026-08-12 Sync"
    audio_path       TEXT,                         -- NULL once audio pruned
    content_hash     TEXT    NOT NULL UNIQUE,      -- SHA-256 of audio
    exported_path    TEXT                          -- vault .md path or NULL
);
CREATE INDEX idx_recording_started ON recording(started_at DESC);

CREATE TABLE segment (
    id             INTEGER PRIMARY KEY,
    recording_id   INTEGER NOT NULL
                   REFERENCES recording(id) ON DELETE CASCADE,
    speaker_index  INTEGER NOT NULL,               -- 0-based
    start_seconds  REAL    NOT NULL,
    end_seconds    REAL    NOT NULL,
    text           TEXT    NOT NULL
);
CREATE INDEX idx_segment_recording ON segment(recording_id);

CREATE TABLE note (
    recording_id INTEGER PRIMARY KEY
                 REFERENCES recording(id) ON DELETE CASCADE,
    json         TEXT NOT NULL,                    -- ParsedNote as JSON
    markdown     TEXT NOT NULL,                    -- rendered note
    created_at   REAL NOT NULL
);

CREATE TABLE transcript_cache (
    content_hash     TEXT PRIMARY KEY,
    payload_json     TEXT NOT NULL,                -- pipeline output
    created_at       REAL NOT NULL,
    last_accessed_at REAL NOT NULL,                -- LRU eviction key
    byte_size        INTEGER NOT NULL
);
CREATE INDEX idx_cache_accessed ON transcript_cache(last_accessed_at);

-- Optional v3 (Exercise 3): full-text search over segments.
-- CREATE VIRTUAL TABLE segment_fts USING fts5(
--     text, content='segment', content_rowid='id');
