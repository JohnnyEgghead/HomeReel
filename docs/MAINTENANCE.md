# HomeReel maintenance

## Tools and versions

| Resource | Version | Used for |
| --- | --- | --- |
| Xcode | 27.2 | Build and test |
| Swift | 6.4 (language mode 6.0) | Language |
| tvOS | 18.0 or later | Minimum supported |
| XcodeGen | 2.46.0 | Makes the Xcode project from `project.yml` |
| Python | 3 | `scripts/plex_inventory.py`, and `tools/make_appicon.py` (needs Pillow) |
| gitleaks | 8.30.1 | Secret scan |
| AetherEngine | 7.58.0 | Playback |
| FFmpegBuild | 3.13.0 (FFmpeg n8.1.3) | Media libraries |
| LibDovi | 2.1.0 | Dolby Vision metadata |
| SMBClient | 0.3.1 | Resolved with AetherEngine, not linked |

`HomeReel.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved` holds the exact package versions.

## Before every change lands

1. Run `scripts/test.sh`.
2. Run `gitleaks git --no-banner .` for a change that touches sample data or settings.
3. Add the change to `CHANGELOG.md`.

## Updating packages

No scanner checks these packages, and the FFmpeg libraries are prebuilt binaries from 1 maintainer, so an update needs a person.

1. Read the package's release notes. Check whether the FFmpeg version in `BUILD-INFO.txt` moved, and read FFmpeg's security page for that version.
2. Check that each license still matches `THIRD-PARTY-NOTICES.md`, and that FFmpeg still builds without `--enable-gpl`.
3. Update in Xcode, then run `scripts/test.sh`.
4. Play a real file of each kind on a real Apple TV. The simulator cannot prove Dolby Vision, Atmos, or DTS.
5. Update the tables above and in `THIRD-PARTY-NOTICES.md`.

Check for updates about every 3 months, and soon after any FFmpeg security release.

## Making a version

1. Set `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in `project.yml`. Nothing else holds the version.
2. Move the `Unreleased` notes in `CHANGELOG.md` under the new version.
3. Run `scripts/test.sh` and `scripts/check_test_script.sh`.

Handing out a built app has extra license duties. See `THIRD-PARTY-NOTICES.md`.
