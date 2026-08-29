# SQLite3 C API from Swift — cheatsheet

`import SQLite3` — ships with macOS, no package needed.

## Lifecycle

| Step | Call | Notes |
|---|---|---|
| Open | `sqlite3_open_v2(path, &db, flags, nil)` | flags: `SQLITE_OPEN_READWRITE \| SQLITE_OPEN_CREATE \| SQLITE_OPEN_FULLMUTEX` |
| Close | `sqlite3_close_v2(db)` | v2 tolerates unfinalized statements |
| Prepare | `sqlite3_prepare_v2(db, sql, -1, &stmt, nil)` | compiles SQL |
| Bind | `sqlite3_bind_*(stmt, idx, value)` | **idx starts at 1** |
| Step | `sqlite3_step(stmt)` | `SQLITE_ROW` = row ready, `SQLITE_DONE` = finished |
| Read | `sqlite3_column_*(stmt, idx)` | **idx starts at 0** |
| Reset | `sqlite3_reset(stmt)` | rerun same statement |
| Finalize | `sqlite3_finalize(stmt)` | REQUIRED per prepare — use `defer` |

## Bind / column pairs

| Swift type | Bind | Column |
|---|---|---|
| Int64 | `sqlite3_bind_int64` | `sqlite3_column_int64` |
| Double / Date(epoch) | `sqlite3_bind_double` | `sqlite3_column_double` |
| String | `sqlite3_bind_text(stmt, i, s, -1, SQLITE_TRANSIENT)` | `String(cString: sqlite3_column_text(stmt, i))` — may be NULL! |
| nil | `sqlite3_bind_null` | check `sqlite3_column_type(stmt, i) == SQLITE_NULL` |
| Data | `sqlite3_bind_blob(..., SQLITE_TRANSIENT)` | `sqlite3_column_blob` + `sqlite3_column_bytes` |

`SQLITE_TRANSIENT` isn't importable — define:
```swift
let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
```
Always use it for Swift strings/data; `nil` (= STATIC) causes corruption.

## Result codes
`SQLITE_OK` 0 · `SQLITE_ROW` 100 · `SQLITE_DONE` 101 · `SQLITE_BUSY` 5 ·
`SQLITE_CONSTRAINT` 19. Error text: `String(cString: sqlite3_errmsg(db))`.

## Misc
- `sqlite3_last_insert_rowid(db)` — id of last INSERT.
- `sqlite3_changes(db)` — rows affected by last statement.
- `sqlite3_exec(db, sql, nil, nil, &err)` — multi-statement SQL (DDL); free `err` with `sqlite3_free`.

## PRAGMAs to set on every open
```sql
PRAGMA journal_mode = WAL;     -- readers never block the writer
PRAGMA foreign_keys = ON;      -- cascades are OFF by default
PRAGMA busy_timeout = 5000;    -- wait 5s instead of SQLITE_BUSY
```

## The two golden patterns
```swift
// Statement: prepare -> defer finalize -> bind -> step -> read
let stmt = try prepare(sql, params)
defer { sqlite3_finalize(stmt) }
while sqlite3_step(stmt) == SQLITE_ROW { /* read columns */ }

// Transaction: BEGIN -> work -> COMMIT, ROLLBACK on catch
try exec(db, "BEGIN IMMEDIATE")
do { /* writes */ ; try exec(db, "COMMIT") }
catch { try? exec(db, "ROLLBACK"); throw error }
```

## Gotchas ranked by pain
1. Missing `finalize` → memory leak (Leaks instrument shows libsqlite3).
2. STATIC destructor on temp string → intermittent garbage.
3. Bind 1-indexed, column 0-indexed.
4. `foreign_keys` off → cascades silently skipped.
5. `VACUUM` inside a transaction → error.
6. String-interpolated SQL → quoting bugs + injection.
