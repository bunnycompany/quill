# GRDB vs. the raw SQLite3 C API for Quill

Quill uses the raw C API. Here is the honest trade-off so you can defend
(or revisit) that decision.

## GRDB (github.com/groue/GRDB.swift)

Pros:
- Records map to Codable structs: `try Recording.fetchAll(db)` — no bind/column code.
- `DatabaseMigrator` gives named, ordered migrations out of the box.
- `DatabaseQueue`/`DatabasePool` solve threading; `ValueObservation` can drive SwiftUI lists reactively.
- Battle-tested; catches many misuse bugs at compile time.

Cons:
- A third-party dependency to track, audit, and update (Quill principle: tiny, auditable).
- Adds binary size and build time.
- Hides the C lifecycle — fine until you need a feature it doesn't wrap.

## Raw C API

Pros: zero dependencies (ships with macOS), zero added binary size, total
control, and you learn the real machine — `defer`-based cleanup discipline
transfers directly to Core Audio and ScreenCaptureKit work elsewhere in Quill.

Cons: verbose, easy to leak statements, stringly-typed SQL, you write your
own migration runner (~40 lines, see `code/Migrations.swift`).

## Rule of thumb

- Teaching, tiny utilities, hard "no dependencies" constraints → C API.
- Product code with a growing schema and reactive UI needs → GRDB is the
  pragmatic choice; everything taught in this module (schema design,
  migrations, WAL, pruning, transactions) applies unchanged underneath it.

## Rosetta stone

| Task | C API (this module) | GRDB |
|---|---|---|
| Open | `sqlite3_open_v2` + PRAGMAs | `DatabaseQueue(path:)` (WAL default in Pool) |
| Migrate | `Migrations.migrate(db)` | `DatabaseMigrator.registerMigration` |
| Insert | prepare/bind/step | `try recording.insert(db)` |
| Query | step loop + columns | `try Recording.order(...).fetchAll(db)` |
| Transaction | BEGIN/COMMIT/ROLLBACK | `try dbQueue.write { ... }` |
| Observe | (poll / notify manually) | `ValueObservation.tracking { ... }` |
