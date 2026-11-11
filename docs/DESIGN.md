# How HomeReel is built

A short tour for people who want to read or change the code.

## Rules the app follows

- **Original files only.** The app asks Plex for the original media file and plays it directly. It never requests video or audio transcoding. The one thing it asks the server to resize is pictures (posters and photos).
- **Movies and TV Shows only.** Other library types are ignored.
- **Native tvOS look.** System components, system fonts, standard focus. Custom pieces (the player overlay, focus rings) follow the same style.
- **Secrets stay in the Keychain.** The Plex token, and the optional TV key, are never written to files or logs. Every request sends the token as a header, never in an address. Calls to the server and plex.tv go through a session with no URL cache (`URLSession.uncached`), because a URL cache saves each request on disk with its headers. Pictures are fetched the same way and saved by hand under an address with no headers. The player gets the token as `LoadOptions.httpHeaders`, so video and subtitle addresses hold no token, and logs never show one.
- **Local network.** Sign-in tries the local HTTPS address first, then the local plain address (some routers block `*.plex.direct` names), then other direct HTTPS addresses. It only accepts an address whose `/identity` reports the server's own id, and every launch asks the saved address again before the token is sent. If it no longer answers as that server, plex.tv is asked for the current address. A typed address has no id from plex.tv, so the first connection records the one the server reports. The optional TV is reached over plain HTTP.

## Layout

| Folder | What is in it |
| --- | --- |
| `HomeReel/App` | App start, `AppModel` (sign-in state, settings) and `Session` (one per sign-in: the connection, libraries, and fetched details, dropped whole at sign-out or when the token is refused), and a pretend Plex server for tests (Debug builds only). |
| `HomeReel/Core/Plex` | `PlexClient` (library, search, watched state, progress), models, sign-in with the plex.tv code, and the online database for people and credits. |
| `HomeReel/Core` | Ratings and crew helpers, the Keychain and the `SecretStore` that wraps it (with an in-memory copy for tests), formatting, `AlphaIndex` (letters for the A-Z strip), the optional Sony TV client (`Bravia.swift`). |
| `HomeReel/Core/Playback` | Rules for resuming, subtitle and audio labels, sidecar subtitles. |
| `HomeReel/UI` | Screens: Home, Movies and TV Shows, detail pages, person page, search, settings, and the sign-in screen. `Components.swift` holds shared pieces, including `ImageStore`, which loads and caches pictures. |
| `HomeReel/UI/Player` | The player: `PlayerModel` (state), `PlayerView` (screen and remote), `PlayerPanel` (info, subtitles, audio, picture), `SubtitleOverlay` (draws the subtitle text). |
| `HomeReel/Fixtures` | Made-up sample answers from a Plex server. Unit tests and the pretend server read them. Release builds leave them out. |

Playback uses [AetherEngine](https://github.com/superuser404notfound/AetherEngine), which handles MKV, Dolby Vision, HDR10, DTS, TrueHD and older formats.

## Tests

- `HomeReelTests` are unit tests. They answer network calls from saved sample responses (`HomeReel/Fixtures`, made-up data) through a stub.
- `HomeReelUITests` press the Siri Remote in the simulator against the pretend server.
- `scripts/test.sh` runs everything on your Mac. There is no hosted CI.
- A few tricks for UI tests: a page opened with `-open` starts with focus on the tab bar, so press Down first; menus opened with a press and hold are not buttons in the accessibility tree.
- `scripts/check_test_script.sh` proves `scripts/test.sh` reports a failure, using stand-in tools.

## Developer switches

Release builds leave out the pretend server, its sample data, the environment variables, and the arguments that need them (`-fixture`, `-tv`, `-tvkey`, `-showend`, `-showpanel`, `-nextfail`, `-banner`). One exception: a Release build still looks for `-fixture` in one place, to shorten the library scan polling interval (`LibraryView.swift`). The other launch arguments exist in every build, but only developer tools can set them on an Apple TV.

`-fixture <mode>` runs the app against the pretend server:

| Mode | What the pretend server does |
| --- | --- |
| `normal` | Answers from the sample data. |
| `empty` | No libraries. |
| `offline` | No network at all. |
| `unauthorized` | Rejects the token. |
| `signedout` | Starts at the sign-in screen. |
| `libraryerror` | Library and Continue Watching requests fail. |
| `scanerror` | A library scan fails. |
| `discovererror` | Plex's online database fails. |
| `detailerror` | The online details of a title fail, but a person's page still loads. |
| `longbio` | A person's biography is far taller than the screen. |
| `removeerror` | Remove from Continue Watching fails. |
| `watcherror` | Watched marks fail. |
| `rolemiss` | A person's role record finds nothing, so only their online credits match. |
| `tvoff` | The TV does not answer. |
| `tvasleep` | The TV reports standby. |
| `tvstuck` | The TV ignores changes. |

Launch arguments:

| Argument | What it does |
| --- | --- |
| `-tab home\|movies\|shows\|search\|settings` | Starts on that tab. |
| `-query <text>` | Starts the search with this text. |
| `-open <ratingKey>` | Opens that item. |
| `-autoepisode 1` | With `-open` on a season, opens its first episode. |
| `-person 1` | With `-open`, opens the first cast member's page. |
| `-autoplay 1` | Starts playback when the page opens. |
| `-mute 1` | Mutes playback, so simulator runs stay quiet. |
| `-startat <seconds>` | Starts playback at this position. |
| `-sub <n>` | Selects subtitle track n. |
| `-panel info\|subtitles\|audio\|picture` | Opens the info panel on that tab after playback starts. |
| `-showpanel <tab>` | Opens the info panel without playing anything. |
| `-showend 1` | Jumps to the end-of-episode screen. |
| `-nextfail 1` | With `-showend`, fails the next-episode look-up, so Try Again can be tested. |
| `-banner <text>` | With `-showend`, shows this message while the end screen is up. |
| `-tv on` | With `-fixture`, turns on TV control. |
| `-tvkey <key>` | With `-fixture`, sets the TV key. The pretend TV accepts `fixture-key`. |

Environment variables for the app (simulator and `devicectl`):

| Variable | What it does |
| --- | --- |
| `HR_SERVER`, `HR_TOKEN` | Seed a sign-in without the code flow. Both are needed. |
| `HR_TV_HOST`, `HR_TV_PSK` | Seed the TV address and key. |
| `HR_TV_ENABLED` | `1` turns TV control on. |

`NavigationShotTests` skip unless asked. They read these from the test runner, so set them with a `TEST_RUNNER_` prefix: `HR_LIVE_TOKEN`, `HR_LIVE_SERVER`, `HR_LIVE_SEASON`, `HR_SHOT_PATH`, and the `HR_FOCUS_*` family.

## Optional feature (off by default)

- **TV picture mode:** a Picture tab in the player panel talks to a Sony BRAVIA TV (`/sony/video`, `/sony/system`) to switch Dolby Vision modes. It needs the TV's address and pre-shared key (Settings > TV Picture).
