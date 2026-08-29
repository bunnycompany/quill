---
name: quill-storage-history
description: Teaches a complete beginner how to build Quill's Component 5 — the local SQLite history & cache layer — from zero macOS/Swift knowledge to a working, migration-safe, privacy-first storage engine with pruning and transcript caching.
---

# Quill Component 5: SQLite Local History & Cache

You are going to build the **memory** of Quill: the part that remembers every recording you ever made, every speaker segment the diarizer found, and every markdown note the AI engine produced — all stored **on your Mac only**, in a single file, with zero network access and zero telemetry.

This module assumes you have **never written Swift** and have **never used SQLite**. Everything is explained from zero.

---

## 1. Concepts (from zero)

### 1.1 What is a database, and why not just files?

Quill could dump JSON files in a folder. But then: "show me all meetings longer than 30 minutes with Speaker 3 in them" means opening every file. A **database** is a file format plus a query engine: you describe *what* you want (SQL), and it finds it fast using indexes.

### 1.2 What is SQLite?

SQLite is a database engine that is:

- **Embedded** — no server process. It's a C library your app links against. The whole database is **one file on disk** (e.g. `quill.sqlite`).
- **Already on every Mac** — Apple ships `libsqlite3` with macOS. You add `import SQLite3` and you're done. No package to download. This matters for Quill's "tiny & performant" principle.
- **Transactional (ACID)** — a write either fully happens or fully doesn't, even if the app crashes mid-write.
- **Local-only by design** — SQLite cannot make network calls. It is structurally incapable of leaking your meeting transcripts. Perfect for privacy-first.

### 1.3 SQL in 90 seconds

SQL (Structured Query Language) is the language you speak to SQLite:

```sql
CREATE TABLE recording (id INTEGER PRIMARY KEY, title TEXT);  -- define a table
INSERT INTO recording (title) VALUES ('Weekly Sync');          -- add a row
SELECT id, title FROM recording WHERE title LIKE '%Sync%';     -- read rows
UPDATE recording SET title = 'Sync' WHERE id = 1;              -- change rows
DELETE FROM recording WHERE id = 1;                            -- remove rows
```

- A **table** is like a spreadsheet: columns (typed) and rows.
- A **PRIMARY KEY** uniquely identifies a row. `INTEGER PRIMARY KEY` in SQLite is an auto-incrementing row id.
- A **FOREIGN KEY** is a column that points at another table's primary key ("this segment belongs to recording 42").
- An **index** is a sorted lookup structure that makes `WHERE`/`ORDER BY` on a column fast.
- A **transaction** (`BEGIN … COMMIT`) groups writes so they succeed or fail as one unit.

### 1.4 The SQLite3 C API vs. GRDB

Two ways to use SQLite from Swift:

| | SQLite3 C API (`import SQLite3`) | GRDB (Swift package) |
|---|---|---|
| Dependencies | none — ships with macOS | one third-party package |
| Ergonomics | manual, verbose, pointer-y | Swifty, Codable support |
| Binary size | zero added | small but nonzero |
| Learning value | you understand what's really happening | abstracts it away |

**Quill uses the raw C API.** It fits "tiny," and learning it teaches you memory management discipline you'll need everywhere else in Quill. (GRDB is a great choice too; a comparison is in `reference/grdb-vs-capi.md`.)

### 1.5 The C API mental model

Everything revolves around two opaque pointer types:

- `OpaquePointer` to a **connection** (`sqlite3 *`) — an open database file. You get one from `sqlite3_open_v2`, you must `sqlite3_close` it.
- `OpaquePointer` to a **prepared statement** (`sqlite3_stmt *`) — a compiled SQL query. Lifecycle: `sqlite3_prepare_v2` → `sqlite3_bind_*` (fill in `?` placeholders) → `sqlite3_step` (run / fetch next row) → `sqlite3_column_*` (read values) → `sqlite3_finalize` (destroy). **Every prepare must be paired with a finalize or you leak memory.**

C functions return `Int32` result codes: `SQLITE_OK` (0), `SQLITE_ROW` (a row is ready), `SQLITE_DONE` (finished), or an error code.

### 1.6 Swift concepts you need

- **Optionals** (`String?`) — a value that might be absent. SQL `NULL` maps to `nil`.
- **`throws` / `try`** — Swift's error handling. Our store throws a `StoreError` when SQLite reports failure.
- **`struct` vs `class`** — structs are value types (copied), classes are reference types. Row models are structs; the store (which owns a C resource) is a class-like actor.
- **`actor`** — a Swift Concurrency type that serializes access to its state. Only one task can be inside an actor's methods at a time. This is how we make the store thread-safe *without locks*: SQLite connections are not safe to use from multiple threads simultaneously, so we wrap the connection in an actor and the compiler enforces safety.
- **`async` / `await`** — calling an actor method from outside is asynchronous; you `await` it.
- **`defer`** — runs a block when the current scope exits, no matter how (return, throw). We use `defer { sqlite3_finalize(stmt) }` so statements are *always* cleaned up. This is the single most important leak-prevention tool in this module.
- **`deinit`** — runs when a class/actor is deallocated; we close the connection there as a backstop.
- **`Codable`** — automatic JSON encode/decode for structs; used for the cached parsed-note payload.

### 1.7 Migrations

Version 1 of Quill ships with some schema. Version 2 adds a column. Users who already have a `quill.sqlite` from v1 must be **upgraded in place without losing data**. A **migration** is a numbered, ordered, run-exactly-once SQL script. SQLite gives us a free integer slot in the file header, `PRAGMA user_version`, to record which migration we've reached.

### 1.8 WAL, pruning, and caching — the ops vocabulary

- **WAL (write-ahead logging)** — a journal mode where writes append to a `-wal` side file and readers keep reading the main file. Readers never block the writer. Always turn it on for app databases.
- **Pruning** — Quill records forever, but disks don't grow forever. A pruning policy deletes old *derived* data (cached transcripts, raw segments) past a retention window while keeping lightweight history rows. Also: `VACUUM` rebuilds the file to reclaim the freed space.
- **Cache** — the diarization + transcription of a 1-hour meeting can take minutes of compute. We cache the result keyed by a **content hash** of the audio, so re-processing the same recording is instant.

---

## 2. Architecture: where this fits in Quill

```
AudioRecorderEngine ──(finished recording, WAV/CAF file + metadata)──▶ QuillStore.insertRecording
DiarizationEngine  ──(segments: speaker, start, end, text)──────────▶ QuillStore.insertSegments
LocalAIParsingEngine ─(structured note JSON + markdown)─────────────▶ QuillStore.saveNote / cache
ObsidianExporter   ◀─(reads note + segments to render .md)────────── QuillStore.fetch…
PopoverView (SwiftUI) ◀─(history list, search)──────────────────────  QuillStore.recentRecordings
```

`QuillStore` is an **actor** owning one SQLite connection to
`~/Library/Application Support/Quill/quill.sqlite`. Every other engine talks to it with `await`. Nothing in this layer touches the network — there is no URLSession import anywhere in this component, and that is a deliberate, checkable invariant (see Checkpoint).

**Data model** (full DDL in `reference/schema.sql`):

- `recording` — one row per capture session: started_at, duration, title, audio file path, content hash, vault export path.
- `segment` — one row per diarized utterance: recording_id (FK), speaker_index, start/end seconds, text.
- `note` — one row per recording: the structured note (attendees, action items…) as JSON, plus rendered markdown.
- `transcript_cache` — content-hash-keyed cache of expensive pipeline output, prunable.
- Indexes on `recording(started_at)`, `segment(recording_id)`, `transcript_cache(last_accessed_at)`.

Deletes cascade: removing a recording removes its segments and note (`ON DELETE CASCADE`), so pruning can't strand orphan rows.

---

## 3. Step-by-step implementation walkthrough

You will build four files. Finished versions live in `code/` in this folder — type them yourself first, then diff.

### Step 0 — Project setup

In Xcode 16: File ▸ New ▸ Project ▸ macOS ▸ App, name `Quill`, interface SwiftUI, language Swift. No packages needed. Create a group `Storage` and add the files below to the app target. `import SQLite3` just works — the module map for the system library is built in.

### Step 1 — Errors and the SQLITE_TRANSIENT trick

Create `Storage/SQLiteSupport.swift`:

```swift
import Foundation
import SQLite3

/// Every failure from the storage layer surfaces as one of these.
/// LocalizedError gives us a human-readable message for logs/UI.
enum StoreError: Error, LocalizedError {
    case openFailed(message: String)
    case prepareFailed(sql: String, message: String)
    case stepFailed(sql: String, message: String)
    case migrationFailed(version: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .openFailed(let m):          "Could not open database: \(m)"
        case .prepareFailed(let s, let m): "Prepare failed (\(m)) for SQL: \(s)"
        case .stepFailed(let s, let m):    "Step failed (\(m)) for SQL: \(s)"
        case .migrationFailed(let v, let m): "Migration \(v) failed: \(m)"
        }
    }
}

/// The C header defines SQLITE_TRANSIENT as `((sqlite3_destructor_type)-1)`,
/// a function-pointer cast Swift cannot import. We rebuild it by hand.
/// Passing it to sqlite3_bind_text tells SQLite: "copy this string NOW,
/// don't keep my pointer." Without it, Swift may free the temporary C string
/// before SQLite reads it -> garbage data or crashes.
let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
```

**Why `SQLITE_TRANSIENT` matters:** when you write `sqlite3_bind_text(stmt, 1, "hello", -1, SQLITE_TRANSIENT)`, Swift creates a *temporary* C string that dies at the end of the call. `SQLITE_TRANSIENT` forces SQLite to copy it immediately. Passing `nil` there (which means `SQLITE_STATIC`, "pointer stays valid") is the #1 beginner data-corruption bug in Swift + SQLite.

### Step 2 — Row models

Create `Storage/Models.swift`:

```swift
import Foundation

/// One capture session. A struct: plain value, cheap to copy, Sendable
/// so it can cross actor boundaries safely.
struct Recording: Identifiable, Sendable, Equatable {
    var id: Int64                 // SQLite rowid (INTEGER PRIMARY KEY)
    var startedAt: Date
    var durationSeconds: Double
    var title: String
    var audioPath: String?        // nil once audio is pruned
    var contentHash: String       // SHA-256 of the audio; cache key
    var exportedPath: String?     // where ObsidianExporter wrote the .md
}

struct Segment: Identifiable, Sendable, Equatable {
    var id: Int64
    var recordingID: Int64
    var speakerIndex: Int         // 0-based -> rendered as "Speaker 1"
    var startSeconds: Double
    var endSeconds: Double
    var text: String
}

/// The AI engine's structured output. Codable: we store it as one JSON
/// blob because Quill never queries *inside* it — the queryable fields
/// (date, duration) already live on `recording`.
struct ParsedNote: Codable, Sendable, Equatable {
    var attendees: [String]
    var actionItems: [String]
    var keyTakeaways: [String]
    var markdown: String          // final Dataview-ready markdown
}
```

**Design note:** we store timestamps as Unix epoch `REAL` (seconds since 1970) because it sorts numerically, converts trivially to `Date(timeIntervalSince1970:)`, and avoids timezone string parsing.

### Step 3 — The migration runner

Create `Storage/Migrations.swift`:

```swift
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

    /// Runs every not-yet-applied migration inside a transaction.
    static func migrate(_ db: OpaquePointer) throws {
        var current = Int(readUserVersion(db))
        while current < all.count {
            let sql = all[current]
            // One transaction per migration: a failure rolls the whole
            // step back and leaves user_version untouched.
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
        defer { sqlite3_finalize(stmt) }   // ALWAYS finalize (leak trap #1)
        return sqlite3_step(stmt) == SQLITE_ROW ? sqlite3_column_int(stmt, 0) : 0
    }

    /// sqlite3_exec runs multi-statement SQL strings (perfect for DDL).
    static func exec(_ db: OpaquePointer, _ sql: String) throws {
        var errMsg: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &errMsg) == SQLITE_OK else {
            let message = errMsg.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(errMsg)           // C gave us memory; C frees it
            throw StoreError.stepFailed(sql: sql, message: message)
        }
    }
}
```

Read that twice. The pattern *prepare → defer finalize → step → read* and the pattern *BEGIN → work → COMMIT, ROLLBACK on catch* repeat through the whole store.

### Step 4 — The store actor

Create `Storage/QuillStore.swift`. This is the big one; the complete annotated file is at `code/QuillStore.swift`. The walkthrough below shows every technique it uses; the full file just has more methods built from the same parts.

**4a. Opening the database:**

```swift
import Foundation
import SQLite3

actor QuillStore {
    private let db: OpaquePointer
    private let jsonEncoder = JSONEncoder()
    private let jsonDecoder = JSONDecoder()

    /// Default on-disk location. Application Support is the sanctioned
    /// home for app-private data; it is inside the user's home dir,
    /// backed up by Time Machine, and never leaves the machine.
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
        // FULLMUTEX: serialized mode — belt-and-braces on top of the actor.
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
                  | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url.path, &handle, flags, nil) == SQLITE_OK,
              let handle else {
            let msg = handle.map { String(cString: sqlite3_errmsg($0)) }
                      ?? "out of memory"
            sqlite3_close(handle)          // must close even on failure
            throw StoreError.openFailed(message: msg)
        }
        db = handle
        try Migrations.exec(db, "PRAGMA journal_mode = WAL")     // readers don't block writer
        try Migrations.exec(db, "PRAGMA foreign_keys = ON")      // OFF by default!
        try Migrations.exec(db, "PRAGMA busy_timeout = 5000")    // wait, don't error, on contention
        try Migrations.migrate(db)
    }

    deinit {
        // v2 API: safe even if a statement leaked; connection dies once
        // the last statement is finalized. Backstop, not primary cleanup.
        sqlite3_close_v2(db)
    }
```

Note `PRAGMA foreign_keys = ON` — SQLite ships with foreign keys **disabled** for historical reasons, and it's per-connection. Forget this and `ON DELETE CASCADE` silently does nothing.

**4b. A reusable prepare/bind helper:**

```swift
    /// Binds a heterogeneous parameter list to ?1, ?2, ... placeholders.
    /// nil binds SQL NULL.
    private func prepare(_ sql: String,
                         _ params: [(any Sendable)?]) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK,
              let stmt else {
            throw StoreError.prepareFailed(
                sql: sql, message: String(cString: sqlite3_errmsg(db)))
        }
        for (i, param) in params.enumerated() {
            let idx = Int32(i + 1)                     // bind is 1-indexed!
            switch param {
            case nil:                sqlite3_bind_null(stmt, idx)
            case let v as Int64:     sqlite3_bind_int64(stmt, idx, v)
            case let v as Int:       sqlite3_bind_int64(stmt, idx, Int64(v))
            case let v as Double:    sqlite3_bind_double(stmt, idx, v)
            case let v as String:    sqlite3_bind_text(stmt, idx, v, -1,
                                                       SQLITE_TRANSIENT)
            case let v as Date:      sqlite3_bind_double(
                                        stmt, idx, v.timeIntervalSince1970)
            default:
                sqlite3_finalize(stmt) // don't leak on the error path either
                throw StoreError.prepareFailed(
                    sql: sql, message: "unsupported bind type")
            }
        }
        return stmt
    }

    /// Runs a statement expected to produce no rows (INSERT/UPDATE/DELETE).
    private func run(_ sql: String,
                     _ params: [(any Sendable)?] = []) throws {
        let stmt = try prepare(sql, params)
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw StoreError.stepFailed(
                sql: sql, message: String(cString: sqlite3_errmsg(db)))
        }
    }
```

**4c. Writes** — parameterized, never string-interpolated (SQL injection + quoting bugs):

```swift
    @discardableResult
    func insertRecording(startedAt: Date, title: String,
                         audioPath: String?, contentHash: String) throws -> Int64 {
        try run("""
            INSERT INTO recording
                (started_at, duration_seconds, title, audio_path, content_hash)
            VALUES (?1, 0, ?2, ?3, ?4)
            """, [startedAt, title, audioPath, contentHash])
        return sqlite3_last_insert_rowid(db)   // the new row's id
    }

    /// Segments arrive in bulk after diarization. One transaction:
    /// ~100x faster than 500 auto-committed inserts, and atomic.
    func insertSegments(_ segments: [Segment], recordingID: Int64) throws {
        try Migrations.exec(db, "BEGIN IMMEDIATE")
        do {
            for s in segments {
                try run("""
                    INSERT INTO segment
                        (recording_id, speaker_index, start_seconds,
                         end_seconds, text)
                    VALUES (?1, ?2, ?3, ?4, ?5)
                    """, [recordingID, s.speakerIndex,
                          s.startSeconds, s.endSeconds, s.text])
            }
            try Migrations.exec(db, "COMMIT")
        } catch {
            try? Migrations.exec(db, "ROLLBACK")
            throw error
        }
    }
```

**4d. Reads** — the `while step == SQLITE_ROW` loop:

```swift
    func recentRecordings(limit: Int = 50) throws -> [Recording] {
        let stmt = try prepare("""
            SELECT id, started_at, duration_seconds, title,
                   audio_path, content_hash, exported_path
            FROM recording ORDER BY started_at DESC LIMIT ?1
            """, [limit])
        defer { sqlite3_finalize(stmt) }
        var out: [Recording] = []
        while sqlite3_step(stmt) == SQLITE_ROW {   // column read is 0-indexed
            out.append(Recording(
                id: sqlite3_column_int64(stmt, 0),
                startedAt: Date(timeIntervalSince1970:
                                sqlite3_column_double(stmt, 1)),
                durationSeconds: sqlite3_column_double(stmt, 2),
                title: String(cString: sqlite3_column_text(stmt, 3)),
                audioPath: sqlite3_column_type(stmt, 4) == SQLITE_NULL
                    ? nil : String(cString: sqlite3_column_text(stmt, 4)),
                contentHash: String(cString: sqlite3_column_text(stmt, 5)),
                exportedPath: sqlite3_column_type(stmt, 6) == SQLITE_NULL
                    ? nil : String(cString: sqlite3_column_text(stmt, 6))))
        }
        return out
    }
```

Note the asymmetry that trips everyone: **bind indexes start at 1, column indexes start at 0.**

**4e. Transcript cache** (`cacheTranscript` / `cachedTranscript` in the full file) stores the pipeline output JSON keyed by `content_hash`, using `INSERT … ON CONFLICT(content_hash) DO UPDATE` (an "upsert") and bumping `last_accessed_at` on every read so the pruner can evict least-recently-used entries.

**4f. Pruning policy** — Quill's policy, implemented in `prune(policy:)`:

1. Recordings older than `retentionDays` (default 365): keep the `recording` row (history is tiny), but `UPDATE … SET audio_path = NULL` after deleting the audio file, and `DELETE FROM segment` for them (the note's markdown survives — it's the useful artifact).
2. `transcript_cache` is capped at `maxCacheBytes` (default 256 MB): delete LRU rows (`ORDER BY last_accessed_at ASC`) until under budget.
3. Occasionally `VACUUM` (never inside a transaction — it will error) to return disk space.

The full annotated implementation is in `code/QuillStore.swift`; the policy knobs live in a small `PrunePolicy` struct so the UI can expose them later.

### Step 5 — Wire-up and smoke test

Anywhere early in app startup (e.g. your `AppDelegate`):

```swift
Task {
    do {
        let store = try QuillStore(url: QuillStore.defaultURL())
        let id = try await store.insertRecording(
            startedAt: .now, title: "Smoke test",
            audioPath: nil, contentHash: UUID().uuidString)
        let rows = try await store.recentRecordings()
        print("Inserted \(id); store now has \(rows.count) recording(s).")
    } catch { print("Store failure: \(error)") }
}
```

Run, check the console, then inspect the file yourself from Terminal:

```bash
sqlite3 ~/Library/Application\ Support/Quill/quill.sqlite \
  "SELECT id, datetime(started_at,'unixepoch'), title FROM recording;"
```

Seeing your row come back from the raw `sqlite3` CLI proves the whole stack.

### Step 6 — Verify: leaks and cancellation

- Product ▸ Profile ▸ **Leaks** instrument: insert/read in a loop for a minute; the leaks track must stay flat. Any `malloc` leak pointing into `libsqlite3` means a missing `sqlite3_finalize` — audit every `prepare` for a paired `defer { sqlite3_finalize… }`.
- Cancellation: actor methods here are synchronous once entered, so a cancelled `Task` simply never observes the result — no partial state, because multi-statement writes are transactional. Long batch loops (pruning thousands of rows) should call `try Task.checkCancellation()` between transactions, never inside one.

---

## 4. Common pitfalls & memory-leak traps

1. **Leaked statements** — every `sqlite3_prepare_v2` needs `sqlite3_finalize`, on *every* path. Fix pattern: `defer { sqlite3_finalize(stmt) }` immediately after a successful prepare, and an explicit finalize on the prepare-helper's own error paths. Symptom: Leaks instrument shows growing `libsqlite3` allocations; `sqlite3_close` (v1) returns `SQLITE_BUSY`.
2. **`SQLITE_STATIC`/`nil` destructor on temporary strings** — SQLite stores your soon-dead pointer; you get corrupted text or crashes, *sometimes*, later. Always `SQLITE_TRANSIENT` for Swift strings.
3. **Forgetting `PRAGMA foreign_keys = ON`** — cascades silently don't run; pruning leaves orphan segments forever (a slow disk leak). It's per-connection; set it in `init`.
4. **String-interpolated SQL** — `"…WHERE title = '\(title)'"` breaks on any apostrophe ("Ben's 1:1") and is an injection hole. Always `?` + bind.
5. **One connection, many threads** — SQLite connections aren't concurrently shareable. The actor is the fix; never let the raw `db` pointer escape the actor (don't return it, don't capture it in a `Task.detached`).
6. **Unbounded inserts outside transactions** — 500 segment inserts = 500 fsyncs. Batch in one transaction (Step 4c); this is the storage-layer sibling of the audio engine's bounded circular buffer.
7. **`VACUUM` inside a transaction** — returns `SQLITE_ERROR: cannot VACUUM from within a transaction`. Run it standalone, off the hot path.
8. **Blocking the main thread** — calling the store synchronously from SwiftUI stalls the popover. All access is `await`ed; the actor hops off the main thread automatically.
9. **`String(cString:)` on a NULL column** — `sqlite3_column_text` returns NULL for SQL NULL, and force-feeding that crashes. Check `sqlite3_column_type(stmt, i) == SQLITE_NULL` first (Step 4d).
10. **Editing a shipped migration** — old users' `user_version` says it already ran; their schema now diverges from new installs. Append-only, forever.
11. **Privacy regressions** — no `URLSession`, no analytics SDK, no logging transcript text via `os_log` at default level (logs are readable in Console.app). Log ids and counts, never content.

---

## 5. Exercises

Answers in `reference/answers.md` (and summarized in the collapsible below). Attempt each before peeking.

**Exercise 1 (easy) — NULL-safe text helper.** Reading nullable text columns takes four lines in Step 4d. Write `func columnText(_ stmt: OpaquePointer?, _ index: Int32) -> String?` that returns `nil` for SQL NULL, and refactor `recentRecordings` to use it.

**Exercise 2 (easy-medium) — duration update.** Add `func updateDuration(recordingID: Int64, seconds: Double) throws` to the store using the `run` helper, and explain why binding the `Double` instead of interpolating it still matters even though a `Double` can't inject SQL.

**Exercise 3 (medium) — full-text search.** Write a v3 migration adding an FTS5 virtual table over segment text (`CREATE VIRTUAL TABLE segment_fts USING fts5(text, content='segment', content_rowid='id')`), plus triggers keeping it in sync on INSERT/DELETE, and a `searchSegments(matching:) throws -> [Segment]` store method using `WHERE segment_fts MATCH ?1`.

**Exercise 4 (hard) — cache budget enforcement.** Implement `enforceCacheBudget(maxBytes: Int64) throws -> Int` that deletes least-recently-used `transcript_cache` rows until `SUM(byte_size) <= maxBytes`, in a single transaction, returning the number of rows evicted — without loading all rows into memory (hint: a window-function query with `SUM(byte_size) OVER (ORDER BY last_accessed_at DESC)` can find the cutoff in one pass).

<details>
<summary><strong>Answers (click to expand)</strong></summary>

**1.**
```swift
func columnText(_ stmt: OpaquePointer?, _ index: Int32) -> String? {
    guard let c = sqlite3_column_text(stmt, index) else { return nil }
    return String(cString: c)
}
```
`sqlite3_column_text` already returns NULL for SQL NULL, so the type check is optional — the `guard let` covers it. In `recentRecordings`, `audioPath: columnText(stmt, 4)`, `exportedPath: columnText(stmt, 6)`, and non-null columns become `columnText(stmt, 3) ?? ""`.

**2.**
```swift
func updateDuration(recordingID: Int64, seconds: Double) throws {
    try run("UPDATE recording SET duration_seconds = ?1 WHERE id = ?2",
            [seconds, recordingID])
}
```
Binding still matters for: consistency (one rule, no case analysis per call site), locale-proof formatting (`"\(d)"` can produce `1e-05` or locale surprises through formatters), and statement-cache friendliness — the SQL text stays identical across calls so SQLite can reuse the compiled plan.

**3.** Migration (append as `all[2]`):
```sql
CREATE VIRTUAL TABLE segment_fts USING fts5(
    text, content='segment', content_rowid='id');
INSERT INTO segment_fts(rowid, text) SELECT id, text FROM segment;
CREATE TRIGGER segment_ai AFTER INSERT ON segment BEGIN
    INSERT INTO segment_fts(rowid, text) VALUES (new.id, new.text);
END;
CREATE TRIGGER segment_ad AFTER DELETE ON segment BEGIN
    INSERT INTO segment_fts(segment_fts, rowid, text)
    VALUES ('delete', old.id, old.text);
END;
```
Store method: join back to `segment` (`SELECT s.* FROM segment s JOIN segment_fts f ON s.id = f.rowid WHERE segment_fts MATCH ?1`) and read rows exactly like `recentRecordings`. Full code in `reference/answers.md`.

**4.** Core query — find the access-time cutoff where the running total (newest first) crosses the budget, then delete everything at or older than it:
```sql
DELETE FROM transcript_cache WHERE last_accessed_at <= COALESCE(
  (SELECT last_accessed_at FROM (
      SELECT last_accessed_at,
             SUM(byte_size) OVER (ORDER BY last_accessed_at DESC
                 ROWS UNBOUNDED PRECEDING) AS running
      FROM transcript_cache)
   WHERE running > ?1
   ORDER BY last_accessed_at DESC LIMIT 1), -1);
```
Wrap in BEGIN/COMMIT, then `sqlite3_changes(db)` gives the evicted count. `COALESCE(…, -1)` makes the DELETE a no-op when already under budget. Full annotated version in `reference/answers.md`.

</details>

---

## 6. Checkpoint checklist

Before calling Component 5 done:

- [ ] App builds clean on Xcode 16 / macOS 15 with zero warnings in `Storage/`.
- [ ] `quill.sqlite` appears in `~/Library/Application Support/Quill/` on first launch; `PRAGMA user_version` (via `sqlite3` CLI) equals the migration count.
- [ ] Fresh install and an old-file upgrade (copy a v1 file in, relaunch) both reach the latest schema without data loss.
- [ ] Insert 1,000 recordings + 50,000 segments in a loop under the **Leaks** instrument: flat leak track, and memory returns to baseline afterwards.
- [ ] `insertSegments` of 10k rows completes in well under a second (transaction batching works).
- [ ] Deleting a recording removes its segments and note (foreign keys are ON).
- [ ] Prune with a 0-day retention leaves recording rows but no segments, NULL audio paths, and the audio files gone from disk.
- [ ] Cache: same content hash twice → second pipeline run is skipped; budget enforcement evicts LRU first.
- [ ] `grep -rn "URLSession\|Network\|analytics" Storage/` returns nothing — the layer is provably offline.
- [ ] No transcript text in Console.app logs.
- [ ] Cancelling a long prune between transactions leaves the DB consistent (no partial batch).

---

**Files in this module:** `code/QuillStore.swift`, `code/Migrations.swift`, `code/Models.swift`, `code/SQLiteSupport.swift` (complete, typeable implementations) · `reference/schema.sql` (full DDL) · `reference/sqlite-c-api-cheatsheet.md` · `reference/grdb-vs-capi.md` · `reference/answers.md`.
