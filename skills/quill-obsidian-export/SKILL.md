---
name: quill-obsidian-export
description: Zero-to-undergrad teaching module for building Quill's ObsidianExporter on macOS — sandbox-safe vault selection with security-scoped bookmarks, Dataview-compatible YAML frontmatter generation, deterministic file naming, atomic writes, clipboard export, and sync-conflict avoidance. Complete annotated Swift 5.10+/macOS 15 code included.
---

# Quill Module 4: ObsidianExporter

You are building the component that takes Quill's finished meeting notes (a structured summary produced by the LocalAIParsingEngine) and lands them safely in the user's Obsidian vault as a Markdown file — even though Quill is a sandboxed app that, by default, is not allowed to touch that folder at all.

Everything is local. No network. No cloud. The only "sync" we worry about is *other* software (iCloud Drive, Obsidian Sync, Syncthing) watching the same folder — and we must not corrupt or clobber files while they watch.

---

## 1. Concepts (from zero)

Read these in order. Each builds on the previous.

### 1.1 Markdown and Obsidian

**Markdown** is a plain-text format where `# Heading`, `- bullet`, and `**bold**` render as formatted text. An Obsidian **vault** is just a normal folder of `.md` files; Obsidian is an app that renders and links them. Because a vault is "just files," any program that can write files can create notes — that is our whole integration strategy. No API, no plugin required.

### 1.2 YAML frontmatter and Dataview

Obsidian notes may begin with a **frontmatter** block: YAML (a human-readable key/value format) fenced by `---` lines at the very top of the file:

```markdown
---
date: 2026-08-12
duration_minutes: 42
attendees:
  - Speaker 1
  - Speaker 2
tags: [meeting, quill]
---

# Weekly Sync
```

**Dataview** is a popular Obsidian plugin that treats frontmatter keys as a queryable database (`TABLE date, duration_minutes FROM #meeting`). "Dataview-compatible" means: lowercase snake_case keys, ISO-8601 dates (`2026-08-12`), plain scalars/lists (no nested maps where a scalar is expected), and correctly quoted strings. We will generate this block ourselves with a tiny escaper rather than pulling in a YAML library — the subset we emit is small enough to own.

### 1.3 The macOS App Sandbox

A sandboxed Mac app runs in a jail: it can read/write only its own container (`~/Library/Containers/<bundle-id>/`) plus whatever the *user personally grants* through an `NSOpenPanel` (the standard file/folder picker). The moment the user picks a folder in that panel, the OS hands your process a temporary permission to that URL. Quit the app, and the permission evaporates.

Why sandbox at all? Mac App Store requires it, and for a privacy-first app it's a genuine feature: even if Quill had a bug, it *cannot* read your documents.

### 1.4 Security-scoped bookmarks

The fix for "permission evaporates on quit" is a **security-scoped bookmark**: an opaque blob of bytes (produced by `url.bookmarkData(options: .withSecurityScope)`) that encodes "the user granted this app access to this folder." You store the blob (in `UserDefaults` or your SQLite DB), and on next launch you resolve it back into a URL and call `startAccessingSecurityScopedResource()` before touching the folder, and `stopAccessingSecurityScopedResource()` when done. Forgetting the stop call leaks a kernel resource — one of this module's signature pitfalls.

Two entitlements make this work (set in the `.entitlements` file):
- `com.apple.security.files.user-selected.read-write` — allows NSOpenPanel grants
- `com.apple.security.files.bookmarks.app-scope` — allows persisting them as bookmarks

### 1.5 Atomic writes

If Quill is half-way through writing `Sync.md` when the machine sleeps, or when Obsidian Sync scans the folder, a naive `write()` leaves a truncated file. An **atomic write** avoids this: write the full content to a temporary file *in the same volume*, then `rename()` it over the destination. `rename` is atomic at the filesystem level — observers see either the old file or the complete new file, never a torn one. Foundation gives us this via `Data.write(to:options:.atomic)`; we'll also see the manual `FileManager.replaceItemAt` variant used when we need to preserve the destination's identity.

### 1.6 Sync-conflict avoidance

Sync tools (iCloud, Obsidian Sync) resolve "two writers changed the same file" by duplicating it (`Sync (conflicted copy).md`). Our policy: **never overwrite a file we didn't just create**. If `2026-08-12-Sync.md` exists, we probe `2026-08-12-Sync-2.md`, `-3`, … until we find a free name. Combined with atomic writes, Quill can never produce a torn file nor stomp a user's edits.

### 1.7 NSPasteboard

The macOS clipboard. `NSPasteboard.general.clearContents()` then `setString(_:forType:.string)` puts text on it. That's the entire "clipboard export" feature — useful when the user hasn't configured a vault yet.

### 1.8 Swift concepts you'll use

- **`struct` vs `class`**: structs are value types (copied on assignment) — we use them for data like `MeetingNote`. Classes are reference types — we use `final class` for the exporter because it holds state (the bookmark) and does I/O.
- **`throws` / `do–try–catch`**: Swift's error handling. Functions that can fail are marked `throws`; callers `try` them.
- **`enum` with associated values**: perfect for typed errors (`case vaultNotConfigured`).
- **Swift Concurrency (`actor`, `async/await`)**: an `actor` is a class whose state can only be touched by one task at a time — free thread safety. File I/O off the main thread keeps the menubar UI responsive.
- **`defer`**: runs a block when the current scope exits, no matter how (return, throw). The idiomatic way to guarantee `stopAccessingSecurityScopedResource()` is called.

---

## 2. Architecture: where this fits in Quill

```
AudioRecorderEngine ──► DiarizationEngine ──► LocalAIParsingEngine
                                                     │
                                              MeetingNote (struct)
                                                     │
                              ┌──────────────────────┴───────────┐
                              ▼                                  ▼
                      ObsidianExporter (this module)      SQLite history
                        │           │
                        ▼           ▼
              Vault/Meetings/…md  NSPasteboard
```

`ObsidianExporter` is a **pure sink**: it receives a fully-formed `MeetingNote` value and has no knowledge of audio, ML, or the UI. The PopoverView talks to it in exactly three ways:

1. `selectVault()` — user picks a folder; we persist a bookmark.
2. `export(note:)` — render markdown, write atomically into `<vault>/Meetings/`.
3. `copyToClipboard(note:)` — same rendering, different destination.

It is an `actor` so concurrent exports (user smashes the button) serialize safely, and all disk I/O stays off the main thread automatically. The *only* main-thread piece is the NSOpenPanel (AppKit UI must run on main), which we isolate with `@MainActor`.

---

## 3. Step-by-step implementation

Create `ObsidianExporter.swift` in your Quill Xcode project (File → New → Swift File). The complete final file also lives in [`ObsidianExporter.swift`](ObsidianExporter.swift) in this folder — type it in yourself first, then diff.

### Step 0 — Entitlements

In Xcode: target → Signing & Capabilities → App Sandbox must be ON, with **User Selected File: Read/Write**. Then open the `.entitlements` file as source and confirm/add:

```xml
<key>com.apple.security.app-sandbox</key><true/>
<key>com.apple.security.files.user-selected.read-write</key><true/>
<key>com.apple.security.files.bookmarks.app-scope</key><true/>
```

Without the bookmarks key, `bookmarkData(options: .withSecurityScope)` throws at runtime. This is the #1 "why doesn't it work" for beginners.

### Step 1 — The data model

```swift
import Foundation

/// Everything the parsing engine hands us about one finished meeting.
/// A struct: pure data, value semantics, trivially Sendable across actors.
struct MeetingNote: Sendable {
    var title: String                 // "Weekly Sync"
    var date: Date                    // meeting start
    var durationSeconds: Int
    var attendees: [String]           // ["Speaker 1", "Speaker 2"]
    var speakerSegments: [SpeakerSegment]
    var actionItems: [String]
    var keyTakeaways: [String]
    var transcriptSummary: String     // body prose from the local AI engine

    struct SpeakerSegment: Sendable {
        var speaker: String           // "Speaker 1"
        var start: TimeInterval       // seconds from meeting start
        var text: String
    }
}
```

Annotation: `Sendable` tells the compiler this value is safe to pass between concurrency domains (UI → exporter actor). All stored properties are themselves Sendable value types, so conformance is checked for free.

### Step 2 — Typed errors

```swift
enum ExportError: LocalizedError {
    case vaultNotConfigured
    case bookmarkStale            // vault moved/deleted; user must re-pick
    case accessDenied
    case writeFailed(underlying: Error)

    var errorDescription: String? {
        switch self {
        case .vaultNotConfigured: "No Obsidian vault selected yet."
        case .bookmarkStale:      "The saved vault location is no longer valid. Please choose it again."
        case .accessDenied:       "macOS denied access to the vault folder."
        case .writeFailed(let e): "Couldn't write the note: \(e.localizedDescription)"
        }
    }
}
```

Annotation: `LocalizedError` lets SwiftUI show `error.localizedDescription` directly in an alert. Each case names a *user-meaningful* failure, not an implementation detail.

### Step 3 — Vault selection + bookmark persistence

```swift
import AppKit

/// Owns the "which folder is the vault?" question.
/// @MainActor because NSOpenPanel is AppKit UI.
@MainActor
enum VaultPicker {
    static let bookmarkKey = "quill.vaultBookmark"

    /// Shows the folder picker; on success persists a security-scoped bookmark.
    static func selectVault() throws -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose your Obsidian vault folder"
        panel.prompt = "Use as Vault"

        guard panel.runModal() == .OK, let url = panel.url else { return nil }

        // The magic: encode the user's grant into a persistable blob.
        let bookmark = try url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        UserDefaults.standard.set(bookmark, forKey: bookmarkKey)
        return url
    }
}
```

Annotation: `runModal()` blocks until the user answers — fine on the main actor for a menubar utility. We store the bookmark in `UserDefaults`; in full Quill you could mirror it into the SQLite settings table, but `UserDefaults` is the canonical home for a single small blob.

### Step 4 — The exporter actor: resolving the bookmark

```swift
/// Serializes all vault I/O. Actor = compiler-enforced "one export at a time".
actor ObsidianExporter {

    /// Resolves the persisted bookmark into a live, access-started URL.
    /// Caller MUST balance with stopAccessingSecurityScopedResource().
    private func openVault() throws -> URL {
        guard let data = UserDefaults.standard.data(forKey: VaultPicker.bookmarkKey) else {
            throw ExportError.vaultNotConfigured
        }
        var stale = false
        let url: URL
        do {
            url = try URL(
                resolvingBookmarkData: data,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            )
        } catch {
            throw ExportError.bookmarkStale
        }
        if stale {
            // The folder moved; the bookmark still resolved, but refresh it
            // so it keeps working. If refresh fails, force a re-pick.
            guard url.startAccessingSecurityScopedResource() else {
                throw ExportError.accessDenied
            }
            defer { url.stopAccessingSecurityScopedResource() }
            guard let fresh = try? url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            ) else { throw ExportError.bookmarkStale }
            UserDefaults.standard.set(fresh, forKey: VaultPicker.bookmarkKey)
        }
        guard url.startAccessingSecurityScopedResource() else {
            throw ExportError.accessDenied
        }
        return url
    }
```

Annotation: the `stale` dance is real-world code you rarely see in tutorials — bookmarks go stale when the vault is moved or restored from backup. Note the *nested* start/stop pair inside the stale branch (needed to mint a fresh bookmark) is balanced by `defer`, and the *outer* start is balanced by the caller's `defer` (next step).

### Step 5 — YAML frontmatter (Dataview-compatible)

```swift
    // MARK: - Rendering

    /// Escapes a string for a double-quoted YAML scalar.
    private nonisolated func yamlQuote(_ s: String) -> String {
        var out = s.replacingOccurrences(of: "\\", with: "\\\\")
        out = out.replacingOccurrences(of: "\"", with: "\\\"")
        out = out.replacingOccurrences(of: "\n", with: "\\n")
        return "\"\(out)\""
    }

    nonisolated func renderMarkdown(_ note: MeetingNote) -> String {
        let iso = ISO8601DateFormatter()
        iso.formatDates()   // helper below sets .withFullDate

        let dateOnly = iso.string(from: note.date)          // 2026-08-12
        let minutes = Int((Double(note.durationSeconds) / 60.0).rounded())

        var md = "---\n"
        md += "title: \(yamlQuote(note.title))\n"
        md += "date: \(dateOnly)\n"                          // bare ISO date: Dataview parses as date
        md += "duration_minutes: \(minutes)\n"
        md += "attendees:\n"
        for a in note.attendees { md += "  - \(yamlQuote(a))\n" }
        md += "tags: [meeting, quill]\n"
        md += "generated_by: quill\n"
        md += "---\n\n"

        md += "# \(note.title)\n\n"
        md += note.transcriptSummary + "\n\n"

        if !note.keyTakeaways.isEmpty {
            md += "## Key Takeaways\n\n"
            for t in note.keyTakeaways { md += "- \(t)\n" }
            md += "\n"
        }
        if !note.actionItems.isEmpty {
            md += "## Action Items\n\n"
            for a in note.actionItems { md += "- [ ] \(a)\n" }   // Obsidian task checkboxes
            md += "\n"
        }
        if !note.speakerSegments.isEmpty {
            md += "## Speaker Timestamps\n\n"
            for seg in note.speakerSegments {
                let m = Int(seg.start) / 60, s = Int(seg.start) % 60
                md += String(format: "- **%@** [%02d:%02d] %@\n", seg.speaker, m, s, seg.text)
            }
        }
        return md
    }
```

And the small formatter helper (top level of the file):

```swift
private extension ISO8601DateFormatter {
    func formatDates() { formatOptions = [.withFullDate, .withDashSeparatorInDate] }
}
```

Annotation: `nonisolated` marks rendering as pure — no actor state touched — so tests and the clipboard path can call it without `await`. Dataview rules honored: snake_case keys, unquoted ISO date (Dataview only recognizes dates when *not* quoted), quoted free-text strings, flat list for attendees, `- [ ]` produces real Obsidian tasks.

### Step 6 — File naming + conflict-free destination

```swift
    /// "Weekly Sync!" -> "Weekly-Sync"; keeps names filesystem- and sync-safe.
    private nonisolated func slug(_ title: String) -> String {
        let allowed = CharacterSet.alphanumerics
        let words = title.unicodeScalars.split { !allowed.contains($0) }
        let joined = words.map(String.init).joined(separator: "-")
        return joined.isEmpty ? "Meeting" : joined
    }

    /// Meetings/2026-08-12-Sync.md, or -2, -3… if taken. Never overwrites.
    private func destination(in vault: URL, for note: MeetingNote) throws -> URL {
        let iso = ISO8601DateFormatter(); iso.formatDates()
        let base = "\(iso.string(from: note.date))-\(slug(note.title))"

        let dir = vault.appendingPathComponent("Meetings", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        var candidate = dir.appendingPathComponent(base + ".md")
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = dir.appendingPathComponent("\(base)-\(n).md")
            n += 1
        }
        return candidate
    }
```

Annotation: the exists-check + suffix loop is our sync-conflict policy from §1.6. There is a tiny TOCTOU window (file created between check and write) — acceptable here because the only other writer of `Meetings/*.md` with this exact name pattern is Quill itself, and the actor serializes Quill's own writes.

### Step 7 — Atomic export + clipboard

```swift
    // MARK: - Public API

    @discardableResult
    func export(note: MeetingNote) throws -> URL {
        let vault = try openVault()
        defer { vault.stopAccessingSecurityScopedResource() }   // ALWAYS balanced

        let url = try destination(in: vault, for: note)
        let data = Data(renderMarkdown(note).utf8)
        do {
            // .atomic = write temp file on same volume, then rename over dest.
            try data.write(to: url, options: [.atomic])
        } catch {
            throw ExportError.writeFailed(underlying: error)
        }
        return url
    }

    /// Clipboard needs no vault, no sandbox grant — works with zero setup.
    @MainActor
    static func copyToClipboard(note: MeetingNote, exporter: ObsidianExporter) {
        let md = exporter.renderMarkdown(note)   // nonisolated: no await needed
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(md, forType: .string)
    }
}
```

Annotation: `defer` guarantees the stop call even when `destination` or `write` throws. `NSPasteboard` must be used from the main actor. `@discardableResult` lets callers ignore the returned URL (e.g., a background auto-export).

### Step 8 — Wiring into the PopoverView (usage sketch)

```swift
// In your SwiftUI view model:
@MainActor @Observable final class ExportViewModel {
    private let exporter = ObsidianExporter()
    var lastError: String?

    func chooseVault() {
        do { _ = try VaultPicker.selectVault() }
        catch { lastError = error.localizedDescription }
    }

    func exportTask(_ note: MeetingNote) {
        Task {
            do { _ = try await exporter.export(note: note) }
            catch { lastError = error.localizedDescription }
        }
    }
}
```

Annotation: the `Task { await … }` hop is where the actor pays off — disk I/O runs off the main thread, the popover never beachballs.

**Build check**: ⌘B. The file should compile with zero warnings under Swift strict concurrency (`SWIFT_STRICT_CONCURRENCY = complete`).

---

## 4. Common pitfalls & memory/resource-leak traps

1. **Unbalanced `startAccessingSecurityScopedResource()`** — each start consumes a kernel resource; leak enough and *all* file access starts failing with no useful error. Rule: every `start` is immediately followed by `defer { stop }` on the next line. Grep your code for `startAccessing` and count the `stop`s.
2. **Missing `bookmarks.app-scope` entitlement** — `bookmarkData(options: .withSecurityScope)` throws `Cocoa error 256`. Check entitlements before debugging code.
3. **Storing the URL instead of the bookmark** — a plain URL string persisted to disk carries no permission; next launch every write fails with permission denied even though "the path is right."
4. **Quoted dates in YAML** — `date: "2026-08-12"` is a *string* to Dataview; queries like `WHERE date >= date(2026-08-01)` silently return nothing. Emit dates unquoted.
5. **Non-atomic writes** — `FileHandle`-based or append-style writing lets sync engines upload torn files. Always `.atomic` (or `replaceItemAt`).
6. **Temp file on the wrong volume** — if you hand-roll atomic writes, the temp file must be on the same volume as the destination or the rename degrades to copy+delete (not atomic). `.atomic` handles this; `FileManager.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: destination, create: true)` is the manual way.
7. **Retain cycle in the export Task** — `Task { self.export… }` inside a class captures `self` strongly; for a long-lived view model that's usually fine, but if the task can outlive the model use `[weak self]` and honor `Task.isCancelled` so a cancelled recording doesn't still write a file.
8. **NSOpenPanel off the main thread** — AppKit UI from a background actor crashes or deadlocks. Keep `VaultPicker` `@MainActor`.
9. **Filename characters** — `/` and `:` in meeting titles produce broken paths or Finder-mangled names. Always slugify (Step 6).
10. **Overwriting user edits** — if the user annotated today's note in Obsidian and you re-export, overwriting destroys their edits and triggers sync conflicts. Our exists-check + `-2` suffix policy makes this impossible.

---

## 5. Exercises

### Exercise 1 (easy) — Frontmatter field
Add a `location: "Recorded on this Mac"` field to the frontmatter, and a `source_app_version` field read from the bundle. Verify Dataview can `TABLE source_app_version FROM #quill`.

### Exercise 2 (medium) — Duplicate-content guard
Right now exporting the same note twice creates `-2`. Change `destination(in:for:)` so that if the existing file's *content is byte-identical* to what we'd write, `export` returns the existing URL without writing. (Hint: you'll need to restructure so the rendered `Data` is available when choosing the destination.)

### Exercise 3 (hard) — Stale-bookmark recovery UX
When `openVault()` throws `.bookmarkStale`, the user currently just sees an error. Build the full recovery loop: the view model catches `.bookmarkStale`, presents the NSOpenPanel again on the main actor, persists the new bookmark, and *retries the same export once* — all without duplicating export logic and without retry loops if the user cancels the panel.

### Exercise 4 (stretch) — Manual atomic replace
Reimplement the write using `FileManager.replaceItemAt(_:withItemAt:)` with a temp file from `.itemReplacementDirectory`, preserving the destination file's identity (so Obsidian's open tab doesn't "lose" the file). When would this matter vs `.atomic`?

<details>
<summary><strong>Answers</strong></summary>

**Exercise 1.** In `renderMarkdown`, after `generated_by`:

```swift
md += "location: \(yamlQuote("Recorded on this Mac"))\n"
let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
md += "source_app_version: \(yamlQuote(version))\n"
```

**Exercise 2.** Render first, pass the data in:

```swift
private func destination(in vault: URL, for note: MeetingNote, content: Data) throws -> (url: URL, alreadyWritten: Bool) {
    let iso = ISO8601DateFormatter(); iso.formatDates()
    let base = "\(iso.string(from: note.date))-\(slug(note.title))"
    let dir = vault.appendingPathComponent("Meetings", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    var candidate = dir.appendingPathComponent(base + ".md")
    var n = 2
    while FileManager.default.fileExists(atPath: candidate.path) {
        if let existing = try? Data(contentsOf: candidate), existing == content {
            return (candidate, true)                    // identical: no-op export
        }
        candidate = dir.appendingPathComponent("\(base)-\(n).md"); n += 1
    }
    return (candidate, false)
}
```

and in `export`: render `data` first, call the new signature, skip the write when `alreadyWritten`.

**Exercise 3.** Key idea: a single retry flag, not a loop, and the panel on `@MainActor`:

```swift
@MainActor
func exportWithRecovery(_ note: MeetingNote) async {
    do {
        _ = try await exporter.export(note: note)
    } catch ExportError.bookmarkStale, ExportError.vaultNotConfigured {
        // Re-pick on main actor; nil means user cancelled: stop, no retry.
        guard let _ = try? VaultPicker.selectVault() else { return }
        do { _ = try await exporter.export(note: note) }      // exactly one retry
        catch { lastError = error.localizedDescription }
    } catch {
        lastError = error.localizedDescription
    }
}
```

No duplicated logic — both paths call the same `export`. Catching two cases in one clause handles first-run too.

**Exercise 4.**

```swift
let tmpDir = try FileManager.default.url(
    for: .itemReplacementDirectory, in: .userDomainMask,
    appropriateFor: url, create: true)                  // same volume as destination
let tmp = tmpDir.appendingPathComponent(UUID().uuidString + ".md")
try data.write(to: tmp)                                 // plain write to temp
_ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
```

It matters when *updating an existing file in place*: `replaceItemAt` preserves the destination's file identity/metadata where a plain rename-based `.atomic` write creates a brand-new inode — some apps (and sync engines tracking file IDs) treat that as delete+create rather than an edit. For our create-only policy `.atomic` is sufficient; if Quill ever gains "update today's note," switch to `replaceItemAt`.

</details>

---

## 6. Checkpoint checklist

Before moving to the next module, verify all of these:

- [ ] App Sandbox ON with user-selected read/write and `bookmarks.app-scope` entitlements; project builds with strict concurrency `complete` and zero warnings.
- [ ] Choosing a vault via the popover persists a bookmark; after **quitting and relaunching**, export still writes into the vault (this is the real bookmark test).
- [ ] Exported file appears as `Meetings/2026-08-12-Sync.md`; exporting again yields `-2.md`, never an overwrite.
- [ ] Frontmatter renders in Obsidian's Properties panel; a Dataview `TABLE date, duration_minutes, attendees FROM #meeting` query lists the note with `date` recognized as a date.
- [ ] Titles containing `/`, `:`, emoji, or empty strings produce valid filenames.
- [ ] Clipboard export works with **no** vault configured.
- [ ] Grep check: every `startAccessingSecurityScopedResource` is paired with a `defer`red stop.
- [ ] Instruments (Leaks + Allocations) shows no growth across 50 repeated exports; kill the vault folder mid-test and confirm `.bookmarkStale` surfaces instead of a crash.
- [ ] You can explain, out loud, why the temp file must live on the same volume for atomicity.

**Supporting files in this folder**: [`ObsidianExporter.swift`](ObsidianExporter.swift) (complete final source), [`yaml-dataview-cheatsheet.md`](yaml-dataview-cheatsheet.md) (frontmatter rules quick reference).
