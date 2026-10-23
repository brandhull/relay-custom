# Changelog

Relay uses `MAJOR.MINOR.PATCH` versioning, shared by the iOS and Mac apps:

- **PATCH** for bug fixes and small polish.
- **MINOR** for new features or visible improvements that don't break anything.
- **MAJOR** for rare, large shifts (a redesign, dropping older OS versions).

The version lives in `project.yml` (`MARKETING_VERSION`), along with the build
number (`CURRENT_PROJECT_VERSION`), which goes up on every build shipped to a
device and never resets. Each release is tagged `vMAJOR.MINOR.PATCH`.

## 1.2.0 (build 3) — 2026-10-23

### Added
- "Suggest title" button (sparkles) next to the title on the Edit screen. It
  transcribes the recording on-device and writes a short sentence-case title
  with Apple Intelligence. Only appears where Apple Intelligence is available;
  never runs automatically.

## 1.1.0 (build 2) — 2026-10-08

### Added
- Default Show picker in Settings.
- Tap the waveform on the Edit screen to move the playhead; play resumes from there.
- Green Done button on the Edit screen: stops playback and returns to Record.
- Tapping the Library tab while already in Library returns to the Library list.
- Version and build number shown under Settings → About.

### Changed
- "Continue to Episode Details" is now "Episode Details", at half width.
- Baserow token and Craft API URL fields are masked, like the Transistor API key.

### Fixed
- Uploads failing with "No show selected": Episode Details showed the first
  show but never saved it on the episode.
- iOS: resuming a paused recording while the mic is still in use (e.g. mid-call)
  now stays paused with a message instead of showing "Recording" while capturing nothing.

## 1.0.0

Initial release: iOS/iPadOS recorder with Transistor, Baserow and Craft
publishing, plus the Mac app (Record, Library, Edit, Settings).
