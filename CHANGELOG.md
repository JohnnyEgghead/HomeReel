# Changelog

All notable changes to HomeReel. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- A title you do not own opens a full page, not a small card: poster, whole description, scores, genres, cast, and crew from Plex's online database. Cast and crew open their own pages.
- A role filter above a person's filmography (All, Actor, Director, Writer, Producer, and so on), with the number of credits in each.
- Scrubbing previews the new point: the video pauses, and once your swipe rests the picture shows the frame you are pointing at. Select goes there, Menu goes back to where you were, and an edge click moves the preview by 10 seconds.
- Episode air dates, on the episode page and in each season's episode list, when Plex has one.
- A message on the sign-in screen when Plex rejects a token.
- A Try Again button when the next-episode look-up fails.
- A banner when a watched mark cannot be saved.
- Person pages say when your library could not be read.
- A Try Again button when a later page of a library fails to load.
- Save and Test in Settings now checks the TV key.
- `docs/REQUIREMENTS.md`, `docs/MAINTENANCE.md`, this changelog, and `scripts/check_test_script.sh`.

### Changed

- Continue Watching shows posters, like Recently Added. Episodes show their show's poster.
- Lifting a finger from the remote no longer seeks. A swipe must also travel further before it counts, so a resting thumb does not start a scrub.
- Sign-in with a code uses only a server your account owns. A server shared with you is no longer picked when you own none.
- Sign-in tries the server's HTTPS address first, and accepts an address only if it reports the server's own id. A typed address records its server's id the first time it connects.
- The player closes at once and saves in the background, so a missing network never holds it open.
- `scripts/plex_inventory.py` finds your libraries instead of assuming their ids.
- Keychain items now stay on this device.
- The version is set in `project.yml`. The tracked project file holds a copy, so run `xcodegen generate` after changing it.
- The README installs the Release build, and `scripts/test.sh` also builds Release for the Apple TV.
- The Plex token travels only as a header. Video and subtitle addresses no longer hold it, and no request that carries it is saved in a URL cache. Old caches are cleared once, on the first launch of this version.

### Fixed

- A long biography on a person's page scrolled its top off the screen with no way back. The text is now in pieces that take focus one by one, and so is the name, so Up and Down scroll both ways.
- A cast member of a title you do not own said "Plex has no online page for this person". Online cast records name the person by a text id, which is now used.
- Some titles you do not own said "The server sent an answer HomeReel could not read". The online record carries streaming details the page never uses, and they made the whole title unreadable. The page now reads only what it shows, and one odd field no longer costs the title.

- Clearing the picture cache (at sign-out, and once after an update) now repeats its removal from the app's shared cache, because one removal could be lost. That cache is where earlier versions kept requests with the token.
- On a real Apple TV 4K (3rd generation), the screen saver starts while a video is paused (tried with the Release build).
- Leaving the app mid-movie and coming back left a black, frozen player with no message. The picture is now rebuilt at the same place and comes back paused, or the player says it could not. Tried on an Apple TV 4K (3rd generation): leaving mid-movie and pressing Play returned to the same place.
- A server that answered with a redirect could carry the Plex token (or the TV key) to another host. Redirects to another host are now refused. Video files are not covered, because the player engine makes that request.
- A single refused request deleted the saved token. Now plex.tv is asked first, and the token is deleted only if plex.tv also refuses it.
- Home asked the server about a movie or TV library that did not exist when the account had none.
- A home-video library filed under Plex's newer `tv.plex.agents.none` agent showed up among the movies.
- A message shown while the end-of-episode screen was up was hidden under it.
- A message that arrived while the player was open (such as a failed watched mark) was hidden under it.
- A detail page that could not load its full details said nothing. It now says why, with Try Again.
- A page of unreadable items was shown as an empty library, and single unreadable items vanished without a word. Both are now reported.
- A scan that outlasted the wait was shown as finished. It now says the server is still scanning, and one or two missed checks no longer fail it.
- A failed next episode no longer closes the end screen, and Open Series or Open Season say when they fail.
- One dropped check during code sign-in ended the sign-in. The code is now rechecked until it expires.
- A mistyped server address was saved. It is now refused with a message.
- Errors from an unreadable server answer showed Swift internals. They now show a plain sentence.
- A Keychain that would not answer looked like a signed-out Apple TV. A failed save of the TV settings, or of sign-out, is now reported.
- A copy of an item marked unwatched elsewhere could keep showing as watched. The newer copy now wins.
- Skip, scrub, and play did something while the video was still loading.
- The screen saver could not start while paused or on the end screen.
- AetherEngine is pinned to the exact version, so a package update never arrives on its own.
- `scripts/plex_inventory.py` sends its token in a header, refuses addresses that are not http or https, and writes its table with mode 600.

- A server that changed address needed a new sign-in. Each launch now checks the saved address, and finds the server again through plex.tv.
- A refused token from any screen left a dead page. It now returns to sign-in and says why.
- Details fetched for one sign-in could show after the next. Each sign-in now owns its data.
- Subtitle choices are kept per server.

- Pressing Cancel during sign-in could show a failure.
- A failed next-episode look-up said "That was the last episode".
- Person pages said "Not in your library" when the server could not be reached.
- Signing in to another server could show person pages from the old one.
- One odd item from the server failed a whole page.
- Play on an item without file details blamed the file during a network failure.
- A server path without a leading slash could crash the app.
- `http://host/` as a typed address became `http://host/:32400`.
- Player errors showed internal details.
- Stale list copies could hide a viewing from another device.
- Plex could show a session after playback ended.
- Plex kept showing a session after you watched to the end, because no "stopped" report was sent.
- A place that could not be saved on exit now says so.
- Continue Watching could list home videos and other libraries the app does not show.
- A quick change of sort or filter could leave a library list holding pages from both.
- Picking a subtitle track with no language turned subtitles off the next time.

### Removed

- Developer environment variables and sample data from Release builds.

## [0.1.0] - 2026-11-06

First public version.
