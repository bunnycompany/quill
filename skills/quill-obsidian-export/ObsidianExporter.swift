//
//  ObsidianExporter.swift
//  Quill — Module 4 reference implementation
//
//  Requires: Xcode 16+, Swift 5.10+, macOS 15, App Sandbox with
//  com.apple.security.files.user-selected.read-write and
//  com.apple.security.files.bookmarks.app-scope entitlements.
//

import Foundation
import AppKit

// MARK: - Data model

/// Everything the parsing engine hands us about one finished meeting.
struct MeetingNote: Sendable {
    var title: String
    var date: Date
    var durationSeconds: Int
    var attendees: [String]
    var speakerSegments: [SpeakerSegment]
    var actionItems: [String]
    var keyTakeaways: [String]
    var transcriptSummary: String

    struct SpeakerSegment: Sendable {
        var speaker: String
        var start: TimeInterval
        var text: String
    }
}

// MARK: - Errors

enum ExportError: LocalizedError {
    case vaultNotConfigured
    case bookmarkStale
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

// MARK: - Helpers

private extension ISO8601DateFormatter {
    /// Configure for date-only output: 2026-08-12
    func formatDates() { formatOptions = [.withFullDate, .withDashSeparatorInDate] }
}

// MARK: - Vault selection (main-actor UI)

@MainActor
enum VaultPicker {
    static let bookmarkKey = "quill.vaultBookmark"

    /// Shows the folder picker; on success persists a security-scoped bookmark.
    /// Returns nil if the user cancelled.
    static func selectVault() throws -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose your Obsidian vault folder"
        panel.prompt = "Use as Vault"

        guard panel.runModal() == .OK, let url = panel.url else { return nil }

        let bookmark = try url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        UserDefaults.standard.set(bookmark, forKey: bookmarkKey)
        return url
    }
}

// MARK: - Exporter

/// Serializes all vault I/O; disk work runs off the main thread automatically.
actor ObsidianExporter {

    // MARK: Bookmark resolution

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

    // MARK: Rendering

    /// Escapes a string for a double-quoted YAML scalar.
    private nonisolated func yamlQuote(_ s: String) -> String {
        var out = s.replacingOccurrences(of: "\\", with: "\\\\")
        out = out.replacingOccurrences(of: "\"", with: "\\\"")
        out = out.replacingOccurrences(of: "\n", with: "\\n")
        return "\"\(out)\""
    }

    nonisolated func renderMarkdown(_ note: MeetingNote) -> String {
        let iso = ISO8601DateFormatter()
        iso.formatDates()

        let dateOnly = iso.string(from: note.date)
        let minutes = Int((Double(note.durationSeconds) / 60.0).rounded())

        var md = "---\n"
        md += "title: \(yamlQuote(note.title))\n"
        md += "date: \(dateOnly)\n"                // unquoted: Dataview parses as date
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
            for a in note.actionItems { md += "- [ ] \(a)\n" }
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

    // MARK: Naming

    /// "Weekly Sync!" -> "Weekly-Sync"; filesystem- and sync-safe.
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

    // MARK: Public API

    /// Writes the note into <vault>/Meetings/ atomically. Returns the file URL.
    @discardableResult
    func export(note: MeetingNote) throws -> URL {
        let vault = try openVault()
        defer { vault.stopAccessingSecurityScopedResource() }

        let url = try destination(in: vault, for: note)
        let data = Data(renderMarkdown(note).utf8)
        do {
            try data.write(to: url, options: [.atomic])
        } catch {
            throw ExportError.writeFailed(underlying: error)
        }
        return url
    }

    /// Clipboard export needs no vault and no sandbox grant.
    @MainActor
    static func copyToClipboard(note: MeetingNote, exporter: ObsidianExporter) {
        let md = exporter.renderMarkdown(note)
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(md, forType: .string)
    }
}
