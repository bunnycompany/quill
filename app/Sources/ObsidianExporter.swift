//
//  ObsidianExporter.swift
//  Quill — writes MeetingNote markdown into the selected Obsidian vault.
//
//  Integration note: the vault URL is owned by AppState (security-scoped
//  bookmark under "quill.vault.bookmark") and passed in per export, so
//  there is exactly one source of truth for vault selection.
//

import Foundation
import AVFoundation

enum ExportError: LocalizedError {
    case vaultNotConfigured
    case writeFailed(underlying: Error)

    var errorDescription: String? {
        switch self {
        case .vaultNotConfigured: "No Obsidian vault selected yet."
        case .writeFailed(let e): "Couldn't write the note: \(e.localizedDescription)"
        }
    }
}

/// Serializes all vault I/O; disk work runs off the main thread automatically.
actor ObsidianExporter {

    // MARK: Naming

    /// "Weekly Sync!" -> "Weekly-Sync"; filesystem- and sync-safe.
    private nonisolated func slug(_ title: String) -> String {
        let allowed = CharacterSet.alphanumerics
        let words = title.unicodeScalars.split { !allowed.contains($0) }
        let joined = words.map(String.init).joined(separator: "-")
        return joined.isEmpty ? "Meeting" : joined
    }

    /// Meetings/2026-08-13-Title.md, or -2, -3… if taken. Never overwrites.
    private func destination(in vault: URL, for note: MeetingNote) throws -> URL {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withFullDate, .withDashSeparatorInDate]
        let base = "\(iso.string(from: note.metadata.date))-\(slug(note.metadata.title))"

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

    /// Writes the note into <vault>/Meetings/ atomically. When `audioURL` is
    /// given, also converts the CAF to m4a (Obsidian can't play CAF) into
    /// Meetings/attachments/ and appends an ![[embed]] to the note.
    @discardableResult
    func export(note: MeetingNote, vaultURL: URL, audioURL: URL? = nil) async throws -> URL {
        let accessing = vaultURL.startAccessingSecurityScopedResource()
        defer { if accessing { vaultURL.stopAccessingSecurityScopedResource() } }

        let url = try destination(in: vaultURL, for: note)
        let noteName = url.deletingPathExtension().lastPathComponent

        // When an AI pass produced a distinct cleaned transcript, file it as
        // its own note under Meetings/cleaned/ and cross-link the two. The raw
        // note in Meetings/ stays the canonical archival record.
        let split = note.hasCleanedTranscript
        var markdown = split
            ? note.renderMarkdown(.rawOnly, crossLink: noteName)
            : note.renderMarkdown()

        if let audioURL {
            do {
                let name = try await convertToM4A(from: audioURL,
                                                  meetingsDir: url.deletingLastPathComponent(),
                                                  baseName: noteName)
                markdown += "\n## Recording\n\n![[attachments/\(name)]]\n"
            } catch {
                // Audio embed is best-effort; the note must never be lost to it.
                markdown += "\n<!-- audio conversion failed: \(error.localizedDescription) -->\n"
            }
        }

        do {
            try Data(markdown.utf8).write(to: url, options: [.atomic])
        } catch {
            throw ExportError.writeFailed(underlying: error)
        }

        if split {
            // Best-effort: a failure here must not lose the raw note above.
            let cleanedDir = url.deletingLastPathComponent()
                .appendingPathComponent("cleaned", isDirectory: true)
            try? FileManager.default.createDirectory(at: cleanedDir,
                                                     withIntermediateDirectories: true)
            let cleanedURL = cleanedDir.appendingPathComponent(noteName + ".md")
            let cleaned = note.renderMarkdown(.cleanedOnly, crossLink: noteName)
            try? Data(cleaned.utf8).write(to: cleanedURL, options: [.atomic])
        }

        return url
    }

    /// CAF -> AAC m4a into Meetings/attachments/. Returns the file name.
    private func convertToM4A(from source: URL, meetingsDir: URL,
                              baseName: String) async throws -> String {
        let dir = meetingsDir.appendingPathComponent("attachments", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent(baseName + ".m4a")
        try? FileManager.default.removeItem(at: dest)

        let asset = AVURLAsset(url: source)
        guard let session = AVAssetExportSession(asset: asset,
                                                 presetName: AVAssetExportPresetAppleM4A) else {
            throw ExportError.writeFailed(underlying: NSError(
                domain: "Quill", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "No m4a export session"]))
        }
        session.outputURL = dest
        session.outputFileType = .m4a
        await session.export()
        if let error = session.error { throw ExportError.writeFailed(underlying: error) }
        return dest.lastPathComponent
    }
}
