# Exercise answers (full versions)

## Exercise 1 — NULL-safe text helper

```swift
private func columnText(_ stmt: OpaquePointer?, _ index: Int32) -> String? {
    guard let c = sqlite3_column_text(stmt, index) else { return nil }
    return String(cString: c)
}
```

`sqlite3_column_text` returns NULL for SQL NULL, so `guard let` alone is
sufficient — no separate `sqlite3_column_type` check needed. Refactored use
in `recentRecordings`:

```swift
title: columnText(stmt, 3) ?? "",
audioPath: columnText(stmt, 4),
contentHash: columnText(stmt, 5) ?? "",
exportedPath: columnText(stmt, 6)
```

(This helper is already integrated in `code/QuillStore.swift`.)

## Exercise 2 — duration update

```swift
func updateDuration(recordingID: Int64, seconds: Double) throws {
    try run("UPDATE recording SET duration_seconds = ?1 WHERE id = ?2",
            [seconds, recordingID])
}
```

Why bind a Double instead of interpolating, even though it can't inject SQL:

1. **One rule everywhere.** "Always bind" needs no per-call-site safety
   analysis; the next person copying your pattern with a String stays safe.
2. **Formatting hazards.** `"\(d)"` can yield scientific notation
   (`1e-05`) or, via formatters, locale decimal commas — both change or
   break the SQL.
3. **Statement reuse.** Identical SQL text lets SQLite (or a future
   statement cache) reuse the compiled plan instead of re-parsing.

## Exercise 3 — FTS5 full-text search

Migration (append as the next element of `Migrations.all`):

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

Notes: `content='segment'` makes it an *external content* table — the text
is stored once, in `segment`; FTS keeps only the index. The special
`'delete'` insert is how external-content FTS5 tables are told about
removals. (If you ever UPDATE segment text, add an `AFTER UPDATE` trigger
doing delete-then-insert.)

Store method:

```swift
func searchSegments(matching query: String) throws -> [Segment] {
    let stmt = try prepare("""
        SELECT s.id, s.recording_id, s.speaker_index,
               s.start_seconds, s.end_seconds, s.text
        FROM segment s
        JOIN segment_fts f ON s.id = f.rowid
        WHERE segment_fts MATCH ?1
        ORDER BY s.recording_id, s.start_seconds
        """, [query])
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
```

Caveat: MATCH syntax treats `"`, `*`, `-`, `AND/OR/NOT` specially; for raw
user input, quote it (`"\"" + query.replacingOccurrences(of: "\"", with: "\"\"") + "\""`)
to search it literally.

## Exercise 4 — cache budget enforcement

```swift
/// Evicts least-recently-used cache rows until total byte_size <= maxBytes.
/// Returns the number of rows evicted. Single pass, constant memory.
func enforceCacheBudget(maxBytes: Int64) throws -> Int {
    try transaction {
        // Walk rows newest-access-first accumulating a running byte total.
        // The first row whose running total EXCEEDS the budget marks the
        // cutoff: it and everything accessed at-or-before it must go.
        try run("""
            DELETE FROM transcript_cache WHERE last_accessed_at <= COALESCE(
              (SELECT last_accessed_at FROM (
                  SELECT last_accessed_at,
                         SUM(byte_size) OVER (
                             ORDER BY last_accessed_at DESC
                             ROWS UNBOUNDED PRECEDING) AS running
                  FROM transcript_cache)
               WHERE running > ?1
               ORDER BY last_accessed_at DESC LIMIT 1), -1)
            """, [maxBytes])
        return Int(sqlite3_changes(db))
    }
}
```

Why it works:

- The window function computes a prefix sum without loading rows into app
  memory; SQLite streams it.
- `WHERE running > ?1 ORDER BY last_accessed_at DESC LIMIT 1` picks the
  *newest* row that pushes the total over budget — everything from that
  access time down is evicted, keeping the most-recently-used prefix that
  fits.
- `COALESCE(..., -1)` turns "already under budget" (subquery returns no
  row) into a cutoff of -1 epoch seconds, matching nothing: the DELETE is
  a no-op.
- Wrapping in a transaction makes eviction atomic; `sqlite3_changes` right
  after the DELETE reports rows removed.

Edge case: ties on `last_accessed_at` are evicted together (`<=`), which
may overshoot slightly below budget — acceptable, and it guarantees the
invariant. This logic ships inside `prune(policy:)` in
`code/QuillStore.swift`.
