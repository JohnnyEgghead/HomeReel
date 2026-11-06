# How HomeReel is built

A short tour for people who want to read or change the code.

## Rules the app follows

- **Original files only.** The app asks Plex for the original media file and plays it directly. It never requests video or audio transcoding. The one thing it asks the server to resize is pictures (posters and photos).
- **Movies and TV Shows only.** Other library types are ignored.
- **Native tvOS look.** System components, system fonts, standard focus. Custom pieces (the player overlay, focus rings) follow the same style.
- **Secrets stay in the Keychain.** The Plex token, and the optional TV key, are never written to files or logs. Picture requests send the token as a header, so the picture cache holds no token. Video and subtitle addresses do carry it, because the player opens them directly; the app never stores or logs those addresses.
- **Local network.** The server and the optional TV are reached over plain HTTP on your home network (App Transport Security allows local networking only).

## Layout

| Folder | What is in it |
| --- | --- |
| `HomeReel/App` | App start, `AppModel` (sign-in state, settings, caches), and a pretend Plex server for tests (Debug builds only). |
| `HomeReel/Core/Plex` | `PlexClient` (library, search, watched state, progress), models, sign-in with the plex.tv code, and the online database for people and credits. |
| `HomeReel/Core` | Ratings and crew helpers, Keychain, formatting, the optional Sony TV client (`Bravia.swift`). |
| `HomeReel/Core/Playback` | Rules for resuming, subtitle and audio labels, sidecar subtitles. |
| `HomeReel/UI` | Screens: Home, Movies and TV Shows, detail pages, person page, search, settings. |
| `HomeReel/UI/Player` | The player: `PlayerModel` (state), `PlayerView` (screen and remote), `PlayerPanel` (info, subtitles, audio, picture). |

Playback uses [AetherEngine](https://github.com/superuser404notfound/AetherEngine), which handles MKV, Dolby Vision, HDR10, DTS, TrueHD and older formats.

## Tests

- `HomeReelTests` are unit tests. They answer network calls from saved sample responses (`HomeReel/Fixtures`, made-up data) through a stub.
- `HomeReelUITests` press the Siri Remote in the simulator against the pretend server. Start the app the same way with `-fixture normal` (other modes: `empty`, `offline`, `unauthorized`, `libraryerror`, `signedout`, `scanerror`, `discovererror`, `removeerror`, `tvoff`, `tvasleep`, `tvstuck`).
- `scripts/test.sh` runs everything on your Mac. There is no hosted CI.
- A few tricks for UI tests: a page opened with `-open` starts with focus on the tab bar, so press Down first; menus opened with a press and hold are not buttons in the accessibility tree.

## Optional feature (off by default)

- **TV picture mode:** a Picture tab in the player panel talks to a Sony BRAVIA TV (`/sony/video`, `/sony/system`) to switch Dolby Vision modes. It needs the TV's address and pre-shared key (Settings > TV Picture).
