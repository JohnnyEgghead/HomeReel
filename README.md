# HomeReel

A native Apple TV (tvOS) client for a Plex Media Server on your home network. **Movies and TV Shows only.** It plays the original files with no server-side video or audio transcoding.

Personal project, shared as open source. Works with Plex. Not affiliated with or endorsed by Plex (see "Trademarks" below).

## What it does

- **Sign in** with the plex.tv code flow (enter a 4-letter code at plex.tv/link on your phone), or type a server address and token.
- **Home:** Continue Watching, Recently Added Movies, Recently Added TV Shows.
- **Movies and TV Shows:** 6-column poster grids, sort (title, date added, year, rating), an unwatched filter, and an A-Z strip that follows the selected poster.
- **Detail pages:** artwork, description, cast with photos, file format line, Play or Resume, Mark Watched or Unwatched.
- **Search** across movies and shows.
- **Player:** direct play of the original file through [AetherEngine](https://github.com/superuser404notfound/AetherEngine). Handles MKV with Dolby Vision, HDR10, Atmos, DTS and TrueHD, and legacy AVI. Swipe the remote to scrub, click the edges to skip 10 seconds, swipe down for the info panel.
- **Info panel while playing:** description and cast, subtitle menu (text, picture, and sidecar files), audio menu. Your subtitle choice is remembered per show, with a default language in Settings.
- **Progress sync:** position and watched state go back to Plex.
- **Ratings and people:** critic and audience scores (Rotten Tomatoes, TMDB, IMDb) on movies, shows and episodes. Cast and crew open a page with a biography, what you own with them, and their full filmography from Plex's online database.
- **TV episodes:** episode scores in the season list, an "Up Next" screen when an episode ends, and Menu goes to the season's episode list.
- **Home:** Continue Watching has a press-and-hold menu (resume, start over, mark watched or unwatched, open series or season, remove). Recently Added TV Shows is one poster per series.
- **Scan Library** button on Movies and TV Shows.
- **Optional, off by default:** a Picture tab in the player panel that switches a Sony BRAVIA TV between Dolby Vision picture modes over your home network (Settings > TV Picture).

## Known limits

- **One library of each type.** The Movies and TV Shows tabs and the Home rows use only the first Movie library and the first TV library on the server. Search covers all of them.
- **One file per title.** A title with 2 or more files plays the first one listed. There is no version picker.
- **Sidecar subtitles must be text.** SRT, ASS and VTT files work. Picture subtitles in idx/sub side files are skipped.
- **Fancy ASS subtitles are simplified.** Positioned or animated effects draw in the normal place.
- **The Unwatched filter does not refresh on its own.** A title you just finished stays listed until you toggle the filter.
- **Not included:** trailers, collections, playlists, and a Top Shelf extension.

## Build and install

Needs Xcode 27, XcodeGen (`brew install xcodegen`), and an Apple Development certificate. Set up signing first:

1. Copy `Config/Local.example.xcconfig` to `Config/Local.xcconfig` (git ignores it), and set `DEVELOPMENT_TEAM` to your own team.
2. In `project.yml`, change `bundleIdPrefix` and the 3 `PRODUCT_BUNDLE_IDENTIFIER` values to ids you own.

Then build and install:

    xcodegen generate
    # find your Apple TV with: xcrun devicectl list devices
    xcodebuild -project HomeReel.xcodeproj -scheme HomeReel -destination "platform=tvOS,id=<udid>" \
      -derivedDataPath build-device -allowProvisioningUpdates -allowProvisioningDeviceRegistration build
    xcrun devicectl device install app --device <udid> build-device/Build/Products/Debug-appletvos/HomeReel.app

The Apple TV must be awake and in developer mode.

## Tests

    scripts/test.sh          # unit tests and simulator UI tests, about 7 minutes
    scripts/test.sh unit     # unit tests only

The UI tests press the Siri Remote against a pretend Plex server built into Debug builds. Run the app the same way with `-fixture normal|empty|offline|unauthorized|libraryerror|signedout`.

Other launch arguments for development: `-tab home|movies|shows|search|settings`, `-open <ratingKey>`, `-autoplay 1`, `-mute 1`. Environment variables `HR_SERVER` and `HR_TOKEN` seed a sign-in without the code flow (simulator and `devicectl` only).

## Library inventory

`scripts/plex_inventory.py http://<server>:32400` lists the containers, codecs, HDR types, and subtitle formats in your libraries (read-only), to see what the player needs to handle. It reads the token from `~/.config/homereel/plex-token`, which is never in this repo.

## Privacy and security

- Your Plex token is stored only in the Apple TV's Keychain. It is never in this repo, and the app sends it only to your own server and to plex.tv.
- The app talks to your server over plain HTTP on your home network (an App Transport Security exception for local networking). Do not expose your server this way over the internet.
- To scan for secrets before you commit: `gitleaks git --no-banner .` (settings in `.gitleaks.toml`).
- Found a security problem? See `SECURITY.md`.

## Licenses

HomeReel code: MIT (see `LICENSE`). It links AetherEngine (LGPL-3.0 with an App Store exception), FFmpeg libraries (LGPL-2.1) and two MIT packages. See `THIRD-PARTY-NOTICES.md` for each one.

## Trademarks

Plex and Plex Media Server are trademarks of Plex, Inc. HomeReel is an independent app, is not affiliated with or endorsed by Plex, and uses no Plex logo. Other names are trademarks of their owners.

## More

- `docs/DESIGN.md`: how the code is organized and tested.
- `THIRD-PARTY-NOTICES.md`: licenses of the packages used.
