# PlexPlus

A standalone **native Plex client** for **macOS and iPadOS**, extracted from the
"Plex Player" container in ContainerPlus. No web views — it talks to the Plex
API directly and plays video in `AVPlayer`.

## Features
- **Sign in** with Plex's PIN linking flow — the app opens plex.tv in your
  browser and shows the code; the auth token is stored in the keychain.
- **Server discovery** via `plex.tv/api/v2/resources`, testing each connection
  (local → remote → relay) and using the first that responds.
- **Browse** On Deck, Recently Added, and your libraries, drilling into shows →
  seasons → episodes.
- **Library switcher** with favorite libraries (reorderable) and a
  "Browse all servers" section.
- **Library tabs**: Recommended (Plex hubs), Browse (sortable, Shows vs
  Episodes for TV), and Playlists; Play All / Shuffle All.
- **Minimizable player**: collapse playback into a bottom mini-bar and keep
  browsing while the video plays.
- **Playback quality**: Original or 1080p/720p/480p transcodes (resumes at the
  current position).
- **Audio & subtitle** track selection.
- **Queue**: long-press a poster for "Play Next" / "Add to Queue".
- **Media info** (resolution, codecs, bitrate, container, size, file path) and
  an optional, confirmed **Delete from Plex** action.
- **Settings**: default streaming quality, network debug overlay, delete
  opt-in. All persisted.
- Direct play for AVFoundation-friendly containers (mp4/mov/m4v); everything
  else falls back to the Plex universal transcoder (HLS).

## Build & run
1. Open `PlexPlus.xcodeproj` in Xcode 16 or later.
2. Pick a run destination:
   - **My Mac** (macOS 14+), or
   - an **iPad** simulator / device (iPadOS 17+).
3. In *Signing & Capabilities*, pick your team (automatic signing) — or, on
   Mac, "Sign to Run Locally".
4. Run (⌘R).

The single app target is multiplatform (`SUPPORTED_PLATFORMS = iphoneos
iphonesimulator macosx`, device family iPhone/iPad). On iPad, reaching a
server on your LAN triggers the system local-network permission prompt
(declared via `NSLocalNetworkUsageDescription`).

## Project layout
The Xcode project uses a **file-system-synchronized group**, so every file in
`PlexPlus/` is compiled automatically — no need to edit the project when
adding files.

| File | Role |
| --- | --- |
| `PlexPlusApp.swift` | App entry point (hosts `PlexPlayerContainerView`) |
| `PlexPlayerView.swift` | Player UI + `PlexPlayerViewModel` |
| `PlexAPI.swift` / `PlexModels.swift` | Plex API client + Codable models |
| `PlexCache.swift` | On-disk metadata cache |
| `PlexPreferences.swift` | Persisted settings |
| `KeychainHelper.swift` | Small keychain wrapper |
| `PlatformSupport.swift` | Cross-platform colors + system-browser helper |

## Relationship to ContainerPlus
The Plex files are a copy of the ones in the ContainerPlus repo (which is left
untouched). Fixes made to `PlexAPI.swift` / `PlexPlayerView.swift` in one
project must be ported to the other by hand.

> Note: the transcode URL uses sensible default parameters; depending on your
> server and media you may want to tune bitrate/quality in
> `PlexAPI.transcodeURL`.
