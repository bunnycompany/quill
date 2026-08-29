//
//  LexiconStore.swift
//  Quill — vault-derived custom vocabulary ("learning over time").
//
//  Builds a lexicon of terms the user actually writes about — note titles,
//  #tags, [[wikilinks]], frontmatter attendees — plus a human-editable
//  <vault>/Quill/lexicon.md, and feeds it to the speech recognizer as
//  contextual strings so domain words are heard correctly.
//
//  Everything is local file I/O. The merged lexicon is cached in
//  Application Support so recognition benefits from it before the first
//  vault scan of a session completes.
//
//  MEMORY/COST CONTRACT:
//    • files larger than 1 MB are never read
//    • the merged lexicon is capped at `maxTerms` (~500)
//    • dedupe is case-insensitive; common English words are dropped
//

import Foundation

actor LexiconStore {

    // MARK: Tunables

    /// Hard cap on the merged lexicon.
    static let maxTerms = 500
    /// Files above this size are skipped during scans.
    static let maxFileBytes = 1_048_576   // 1 MB

    /// Small stopword set: pure-ASCII common words that would only dilute
    /// the recognizer's contextual boost.
    private static let stopwords: Set<String> = [
        "the", "and", "for", "with", "that", "this", "from", "have", "was",
        "are", "not", "but", "all", "can", "will", "one", "about", "into",
        "your", "our", "their", "his", "her", "its", "has", "had", "were",
        "been", "they", "them", "then", "than", "when", "what", "where",
        "which", "who", "how", "why", "you", "she", "him", "out", "get",
        "new", "note", "notes", "meeting", "meetings", "daily", "todo",
        "untitled", "index", "readme", "home", "inbox"
    ]

    // MARK: State

    /// Last merged lexicon (user file terms first, then vault-derived).
    private var merged: [String] = []
    private var loadedCache = false

    // MARK: Public API

    /// The current lexicon. Loads the Application Support cache on first
    /// call so callers get useful terms even before a scan has run.
    func lexicon() -> [String] {
        if merged.isEmpty && !loadedCache {
            loadedCache = true
            if let data = try? Data(contentsOf: Self.cacheURL()),
               let cached = try? JSONDecoder().decode([String].self, from: data) {
                merged = cached
            }
        }
        return merged
    }

    /// Full rebuild: scan the vault, merge in <vault>/Quill/lexicon.md
    /// (highest priority), persist the cache. Safe to call repeatedly.
    func rebuild(vaultURL: URL) {
        let accessing = vaultURL.startAccessingSecurityScopedResource()
        defer { if accessing { vaultURL.stopAccessingSecurityScopedResource() } }

        let userTerms = readOrCreateUserLexicon(vaultURL: vaultURL)
        let scanned = scanVault(vaultURL)

        // User file wins ordering; dedupe case-insensitively across both.
        var seen = Set<String>(), out: [String] = []
        for term in userTerms + scanned {
            let key = term.lowercased()
            guard !key.isEmpty, seen.insert(key).inserted else { continue }
            out.append(term)
            if out.count >= Self.maxTerms { break }
        }
        merged = out

        if let data = try? JSONEncoder().encode(merged) {
            try? data.write(to: (try? Self.cacheURL()) ?? URL(fileURLWithPath: "/dev/null"),
                            options: [.atomic])
        }
    }

    // MARK: - Learning from corrections

    /// Scan previously exported notes in <vault>/Meetings/ for speaker
    /// labels the user renamed away from "Speaker N" and append them to the
    /// "## Learned" section of lexicon.md. Append-only and deduped.
    ///
    /// When `enrollVoices` is true and a `store` is provided, a rename also
    /// ENROLLS a voice profile: the note is traced back to its recording via
    /// the exported path recorded by markExported, the mention's timestamp is
    /// matched to a segment's speaker_index, and that speaker's stored
    /// meeting_speaker centroid is running-averaged into the profile under
    /// the confirmed name. Labels still carrying the inferred "(?)" suffix
    /// are never enrolled; removing the suffix counts as confirmation.
    func learnFromEdits(vaultURL: URL,
                        store: QuillStore? = nil,
                        enrollVoices: Bool = false) async {
        let accessing = vaultURL.startAccessingSecurityScopedResource()
        defer { if accessing { vaultURL.stopAccessingSecurityScopedResource() } }

        let meetingsDir = vaultURL.appendingPathComponent("Meetings", isDirectory: true)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: meetingsDir, includingPropertiesForKeys: [.fileSizeKey]) else { return }

        var names: Set<String> = []
        for url in files where url.pathExtension == "md" {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            guard size <= Self.maxFileBytes,
                  let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let mentions = Self.editedSpeakerMentions(in: text)
            for m in mentions { names.insert(m.name) }

            // Voice enrollment for CONFIRMED names (no "(?)" suffix).
            if enrollVoices, let store,
               let recordingID = try? await store.recordingID(exportedPath: url.path) {
                // One enrollment per (speakerIndex, name) per file, so a
                // speaker with many utterances counts as one sample.
                var enrolled = Set<String>()
                for m in mentions where !m.inferred {
                    guard let index = try? await store.speakerIndex(
                              recordingID: recordingID, atStartSeconds: m.seconds),
                          enrolled.insert("\(index)|\(m.name)").inserted,
                          let centroid = try? await store.meetingSpeakerCentroid(
                              recordingID: recordingID, speakerIndex: index)
                    else { continue }
                    try? await store.enrollVoice(name: m.name, centroid: centroid)
                }
            }
        }
        guard !names.isEmpty else { return }
        appendLearned(names: names.sorted(), vaultURL: vaultURL)
        // Newly learned names should take effect immediately.
        rebuild(vaultURL: vaultURL)
    }

    /// A renamed speaker label found in an exported note.
    struct SpeakerMention: Sendable, Equatable {
        let name: String          // trimmed, "(?)" suffix stripped
        let seconds: Double       // whole-second utterance start timestamp
        let inferred: Bool        // label still carried the "(?)" suffix
    }

    /// Like editedSpeakerNames, but keeps each mention's timestamp (for
    /// tracing the rename back to a diarized segment) and whether the label
    /// still carries Quill's own inferred-"(?)" suffix. Names are user data:
    /// exact string, whitespace-trimmed only.
    static func editedSpeakerMentions(in markdown: String) -> [SpeakerMention] {
        var out: [SpeakerMention] = []
        for raw in markdown.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(raw)
            var name: String?
            var stamp: String?
            // **[hh:mm:ss] Name:** …
            if let r = line.range(of: #"^\*\*\[\d{2}:\d{2}:\d{2}\]\s+([^*:]+):\*\*"#,
                                  options: .regularExpression) {
                let inner = String(line[r])
                if let colon = inner.lastIndex(of: ":"),
                   let open = inner.firstIndex(of: "["),
                   let close = inner.firstIndex(of: "]") {
                    name = String(inner[inner.index(after: close)..<colon])
                    stamp = String(inner[inner.index(after: open)..<close])
                }
            }
            // **Name** [hh:mm:ss] …
            else if let r = line.range(of: #"^\*\*([^*\[\]]+)\*\*\s+\[(\d{2}:\d{2}:\d{2})\]"#,
                                       options: .regularExpression) {
                let inner = String(line[r])
                if let open = inner.firstIndex(of: "["),
                   let close = inner.firstIndex(of: "]") {
                    stamp = String(inner[inner.index(after: open)..<close])
                }
                name = inner
                    .replacingOccurrences(of: #"\[\d{2}:\d{2}:\d{2}\]"#, with: "",
                                          options: .regularExpression)
                    .replacingOccurrences(of: "*", with: "")
            }
            guard var n = name?.trimmingCharacters(in: .whitespaces),
                  !n.isEmpty, n.count <= 60, let stamp else { continue }
            n = n.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
                .trimmingCharacters(in: .whitespaces)
            // Quill's own inferred-match suffix: strip it, remember it.
            var inferred = false
            if n.hasSuffix("(?)") {
                inferred = true
                n = String(n.dropLast(3)).trimmingCharacters(in: .whitespaces)
            }
            guard !n.isEmpty else { continue }
            // Anything still matching the machine label was not edited.
            if n.range(of: #"^Speaker \d+$"#, options: .regularExpression) != nil { continue }
            let parts = stamp.split(separator: ":").compactMap { Double($0) }
            guard parts.count == 3 else { continue }
            out.append(SpeakerMention(name: n,
                                      seconds: parts[0] * 3600 + parts[1] * 60 + parts[2],
                                      inferred: inferred))
        }
        return out
    }

    /// Speaker labels in exported notes that differ from "Speaker N".
    /// renderMarkdown() emits `**[hh:mm:ss] Name:** text`; also accept the
    /// `**Name** [hh:mm:ss]` variant users sometimes reformat to.
    static func editedSpeakerNames(in markdown: String) -> [String] {
        var out: [String] = []
        for raw in markdown.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(raw)
            var name: String?
            // **[hh:mm:ss] Name:** …
            if let r = line.range(of: #"^\*\*\[\d{2}:\d{2}:\d{2}\]\s+([^*:]+):\*\*"#,
                                  options: .regularExpression) {
                let inner = String(line[r])
                if let colon = inner.lastIndex(of: ":"),
                   let close = inner.firstIndex(of: "]") {
                    name = String(inner[inner.index(after: close)..<colon])
                }
            }
            // **Name** [hh:mm:ss] …
            else if let r = line.range(of: #"^\*\*([^*\[\]]+)\*\*\s+\[\d{2}:\d{2}:\d{2}\]"#,
                                       options: .regularExpression) {
                name = String(line[r])
                    .replacingOccurrences(of: #"\[\d{2}:\d{2}:\d{2}\]"#, with: "",
                                          options: .regularExpression)
                    .replacingOccurrences(of: "*", with: "")
            }
            guard var n = name?.trimmingCharacters(in: .whitespaces),
                  !n.isEmpty, n.count <= 60 else { continue }
            n = n.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            // Anything still matching the machine label was not edited.
            if n.range(of: #"^Speaker \d+$"#, options: .regularExpression) != nil { continue }
            out.append(n)
        }
        return out
    }

    // MARK: - User lexicon file

    private func lexiconFileURL(vaultURL: URL) -> URL {
        vaultURL.appendingPathComponent("Quill", isDirectory: true)
            .appendingPathComponent("lexicon.md")
    }

    /// Reads <vault>/Quill/lexicon.md, creating it with a header if missing.
    private func readOrCreateUserLexicon(vaultURL: URL) -> [String] {
        let url = lexiconFileURL(vaultURL: vaultURL)
        if !FileManager.default.fileExists(atPath: url.path) {
            let header = """
            # Quill Lexicon

            Terms Quill should recognize during transcription — names, jargon,
            product words. One term per line; bullets are fine. Quill also adds
            speaker names it learns from your edits under "## Learned".

            """
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? Data(header.utf8).write(to: url, options: [.atomic])
            return []
        }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return Self.terms(fromLexiconMarkdown: text)
    }

    /// One term per line; "- " / "* " bullets allowed; headings/comments skipped.
    static func terms(fromLexiconMarkdown text: String) -> [String] {
        text.split(separator: "\n").compactMap { raw in
            var line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"), !line.hasPrefix("<!--") else { return nil }
            if line.hasPrefix("- ") || line.hasPrefix("* ") { line = String(line.dropFirst(2)) }
            line = line.trimmingCharacters(in: .whitespaces)
            // Prose from the header paragraph isn't a term.
            guard !line.isEmpty, line.count <= 60,
                  line.split(separator: " ").count <= 6 else { return nil }
            return line
        }
    }

    /// Append names to the "## Learned" section, creating it if needed.
    private func appendLearned(names: [String], vaultURL: URL) {
        let url = lexiconFileURL(vaultURL: vaultURL)
        _ = readOrCreateUserLexicon(vaultURL: vaultURL)   // ensure the file exists
        guard var text = try? String(contentsOf: url, encoding: .utf8) else { return }

        let existing = Set(Self.terms(fromLexiconMarkdown: text).map { $0.lowercased() })
        let fresh = names.filter { !existing.contains($0.lowercased()) }
        guard !fresh.isEmpty else { return }

        if !text.contains("## Learned") {
            if !text.hasSuffix("\n") { text += "\n" }
            text += "\n## Learned\n"
        }
        if !text.hasSuffix("\n") { text += "\n" }
        for name in fresh { text += "- \(name)\n" }
        try? Data(text.utf8).write(to: url, options: [.atomic])
    }

    // MARK: - Vault scan

    /// Walk the vault's markdown files collecting basenames, #tags,
    /// [[wikilinks]] and frontmatter attendees. Bounded by maxTerms.
    private func scanVault(_ vaultURL: URL) -> [String] {
        var seen = Set<String>(), out: [String] = []
        func add(_ term: String) {
            let t = term.trimmingCharacters(in: .whitespaces)
            let key = t.lowercased()
            guard t.count >= 3, t.count <= 60,
                  !Self.stopwords.contains(key),
                  seen.insert(key).inserted else { return }
            out.append(t)
        }

        let keys: [URLResourceKey] = [.fileSizeKey, .isRegularFileKey]
        guard let walker = FileManager.default.enumerator(
            at: vaultURL, includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return out }

        for case let url as URL in walker {
            if out.count >= Self.maxTerms { break }
            guard url.pathExtension.lowercased() == "md" else { continue }
            // Don't learn vocabulary from our own exports or the lexicon file.
            let path = url.path
            if path.contains("/Meetings/") || path.hasSuffix("Quill/lexicon.md") { continue }

            // Basename is a term even if the file is too big to read.
            add(url.deletingPathExtension().lastPathComponent)

            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            guard size <= Self.maxFileBytes,
                  let text = try? String(contentsOf: url, encoding: .utf8) else { continue }

            for term in Self.wikilinks(in: text) { add(term) }
            for term in Self.tags(in: text) { add(term) }
            for term in Self.frontmatterAttendees(in: text) { add(term) }
        }
        return out
    }

    /// `[[Page]]` and `[[Page|alias]]` → "Page" (and the alias).
    static func wikilinks(in text: String) -> [String] {
        matches(#"\[\[([^\[\]\n]+)\]\]"#, in: text).flatMap { inner -> [String] in
            inner.split(separator: "|").map {
                // Drop any #heading / ^block suffix.
                String($0.split(separator: "#").first ?? $0)
                    .trimmingCharacters(in: .whitespaces)
            }
        }
    }

    /// `#tag` and `#nested/tag` → "tag", "nested", "tag".
    static func tags(in text: String) -> [String] {
        matches(#"(?<![\w#])#([A-Za-z][\w/-]{2,})"#, in: text).flatMap {
            $0.split(separator: "/").map(String.init)
        }
    }

    /// YAML frontmatter `attendees:` — inline `[a, b]` or `- item` list.
    static func frontmatterAttendees(in text: String) -> [String] {
        guard text.hasPrefix("---") else { return [] }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        var inFrontmatter = false, inAttendees = false
        var out: [String] = []
        for (i, raw) in lines.enumerated() {
            let line = String(raw)
            if i == 0 { inFrontmatter = true; continue }
            if inFrontmatter && line.trimmingCharacters(in: .whitespaces) == "---" { break }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.lowercased().hasPrefix("attendees:") {
                inAttendees = true
                let rest = trimmed.dropFirst("attendees:".count)
                    .trimmingCharacters(in: .whitespaces)
                if rest.hasPrefix("[") {   // inline list
                    out += rest.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
                        .split(separator: ",")
                        .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \"'")) }
                    inAttendees = false
                }
                continue
            }
            if inAttendees {
                if trimmed.hasPrefix("- ") {
                    out.append(String(trimmed.dropFirst(2))
                        .trimmingCharacters(in: CharacterSet(charactersIn: " \"'")))
                } else if !trimmed.isEmpty {
                    inAttendees = false   // next key
                }
            }
        }
        return out.filter { !$0.isEmpty }
    }

    // MARK: - Small helpers

    private static func matches(_ pattern: String, in text: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        return re.matches(in: text, range: NSRange(location: 0, length: ns.length))
            .compactMap { m in
                m.numberOfRanges > 1 ? ns.substring(with: m.range(at: 1)) : nil
            }
    }

    private static func cacheURL() throws -> URL {
        let dir = try FileManager.default
            .url(for: .applicationSupportDirectory, in: .userDomainMask,
                 appropriateFor: nil, create: true)
            .appendingPathComponent("Quill", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("lexicon-cache.json")
    }
}
