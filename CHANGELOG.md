# Changelog

All notable changes to HomeReel. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- A title you do not own opens a full page, not a small card: poster, whole description, scores, genres, cast, and crew from Plex's online database. Cast and crew open their own pages.
- A role filter above a person's filmography (All, Actor, Director, Writer, Producer, and so on), with the number of credits in each.
- Scrubbing previews the new point: the video pauses, and once your swipe rests the picture shows the frame you are pointing at. Select goes there, Menu goes back to where you were, and an edge click moves the preview by 10 seconds.
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
- Sign-in tries the server's HTTPS address first, and accepts an address only if it reports the expected server.
- The player closes at once and saves in the background, so a missing network never holds it open.
- `scripts/plex_inventory.py` finds your libraries instead of assuming their ids.
- Keychain items now stay on this device.
- The version comes from `project.yml` alone.

### Fixed

- A long biography on a person's page scrolled its top off the screen with no way back. The text is now in pieces that take focus one by one, and so is the name, so Up and Down scroll both ways.
- A cast member of a title you do not own said "Plex has no online page for this person". Online cast records name the person by a text id, which is now used.
- Some titles you do not own said "The server sent an answer HomeReel could not read". The online record carries streaming details the page never uses, and they made the whole title unreadable. The page now reads only what it shows, and one odd field no longer costs the title.
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

### Removed

- Developer environment variables and sample data from Release builds.

## [0.1.0] - 2026-11-06

First public version.
