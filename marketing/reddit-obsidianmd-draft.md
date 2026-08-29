# r/ObsidianMD draft

**Title:** I built a free, local meeting recorder that files speaker-labeled transcripts straight into your vault (Dataview-ready)

**Body:**

Menubar app for Apple Silicon Macs. Press record during a meeting; when you stop, a note lands in `YourVault/Meetings/`:

- YAML frontmatter (date, duration, attendees) that Dataview can query
- Speaker-labeled transcript with timestamps ("Speaker 1 [00:04:12]: …")
- The audio itself embedded as a playable `![[m4a]]`
- Summary + action items via Apple Intelligence when your Mac has it — and when it doesn't, it says "transcript only" instead of making things up

Everything runs on-device (Apple's speech recognition + local diarization). No cloud, no account, no bot joining your calls, no subscription. MIT licensed.

Two vault-native touches I'm proud of: it builds a custom vocabulary from your vault (note titles, tags, wikilinks) so your project names transcribe correctly, and there's a `Quill/lexicon.md` note in your vault you can edit to teach it words. Rename "Speaker 1" to a real name in any note and it learns that too.

Alpha software, so expect rough edges — install and caveats at https://quill.systems

Happy to answer anything, and genuinely looking for feature requests from heavy Dataview users.

---

# Obsidian forum (Share & Showcase) draft

**Title:** Quill — free, on-device meeting recorder that writes speaker-labeled notes into your vault

Use the same body as above, minus the Reddit-isms; keep the thread updated with each release (evergreen SEO home).
