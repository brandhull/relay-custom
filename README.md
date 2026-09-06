# Relay

A native SwiftUI podcast recorder for iPhone and iPad, built around Transistor.fm publishing — with optional Baserow metadata sync and on-device transcription/summarization pushed to Craft.

This is the full-featured version, actively used day to day. For a stripped variant that keeps only Transistor publishing + iCloud backup (no Baserow, no Craft), see [relay](https://github.com/brandhull/relay).

## What it does

- **Record** — tap to start/stop, prefers a connected external mic (USB-C or Bluetooth) over the built-in one automatically. Keeps recording in the background if the screen locks or you switch apps, and pauses cleanly (rather than silently dropping audio) if a call or another interruption comes in.
- **Edit** — trim in place or as a copy, back up to iCloud, push episode metadata + audio to Baserow, or transcribe/summarize to a Craft document.
- **Publish** — fill in episode details, then upload to Transistor.fm as a draft, scheduled, or published episode in one action.
- **Sync** — settings and API credentials follow you across devices via iCloud (Keychain for secrets, `NSUbiquitousKeyValueStore` for everything else).
- **Flag a moment** — mark a timestamp mid-recording, then jump between flags on the Edit screen's waveform.
- **Shortcuts** — Start Recording, Import Recording, and Export Recording are available as native iOS Shortcuts actions (and free Siri phrases), for automations outside the app itself.
- Universal iPhone/iPad, full rotation support on both.

## Stack

- Native SwiftUI, no third-party dependencies
- [xcodegen](https://github.com/yonaskolb/XcodeGen) — `project.yml` is the source of truth; `.xcodeproj` is generated, not committed
- Transistor.fm, Baserow, and Craft REST APIs
- `SFSpeechRecognizer` for on-device transcription (chunked to work around its per-request duration limit) and Apple's on-device FoundationModels framework for summarization (iOS 26+)

## Building

```bash
xcodegen generate
open Relay.xcodeproj
```

Requires a paid Apple Developer team (set `DEVELOPMENT_TEAM` in `project.yml`) for the iCloud Key-Value Storage entitlement the settings sync depends on.

## Configuration

All API keys/tokens are entered in-app under Settings — nothing is hardcoded. You'll need:
- A [Transistor.fm](https://transistor.fm) API key
- A [Baserow](https://baserow.io) API token + table ID (optional)
- A Craft "All Documents" API connection URL (optional)
