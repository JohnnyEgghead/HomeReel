# Changelog

All notable changes to HomeReel. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- A message on the sign-in screen when Plex rejects a token.
- A Try Again button when the next-episode look-up fails.
- A banner when a watched mark cannot be saved.
- Person pages say when your library could not be read.
- A Try Again button when a later page of a library fails to load.
- Save and Test in Settings now checks the TV key.
- `docs/REQUIREMENTS.md`, `docs/MAINTENANCE.md`, this changelog, and `scripts/check_test_script.sh`.

### Changed

- Sign-in tries the server's HTTPS address first, and accepts an address only if it reports the expected server.
- The player closes at once and saves in the background, so a missing network never holds it open.
- `scripts/plex_inventory.py` finds your libraries instead of assuming their ids.
- Keychain items now stay on this device.
- The version comes from `project.yml` alone.

### Fixed

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
