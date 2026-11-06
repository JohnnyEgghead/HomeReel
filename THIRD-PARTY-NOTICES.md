# Third-party notices

HomeReel's own code is MIT licensed (see `LICENSE`). It uses the packages below, pulled in with Swift Package Manager at the versions pinned in `HomeReel.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`. Each package keeps its own license.

| Package | Version | License | Used for |
| --- | --- | --- | --- |
| [AetherEngine](https://github.com/superuser404notfound/AetherEngine) | 7.58.0 | LGPL-3.0 with an App Store / DRM exception | Playing the original media files (MKV, Dolby Vision, HDR10, DTS, TrueHD, AVI) |
| [FFmpegBuild](https://github.com/superuser404notfound/FFmpegBuild) | 3.13.0 | LGPL-2.1-or-later (FFmpeg libraries; libzvbi LGPL-2.0-or-later; dav1d BSD-2-Clause; zimg WTFPL) | FFmpeg libraries used by AetherEngine, shipped as dynamic frameworks. Built without `--enable-gpl` and `--enable-version3`. |
| [LibDovi](https://github.com/superuser404notfound/LibDovi) | 2.1.0 | MIT (packaging); libdovi itself is MIT or Apache-2.0, used here under MIT | Reading Dolby Vision metadata |
| [SMBClient](https://github.com/kishikawakatsumi/SMBClient) | 0.3.1 | MIT | Pulled in by AetherEngine for network file access |

The full license texts are in each package's repository (and in `FFmpegBuild/LICENSES/`), and Xcode downloads them with the sources into `build/SourcePackages/checkouts/` when you build.

## What this means for you

- **Building from source:** nothing extra. HomeReel is open source, so the LGPL "you can relink with a modified library" rule is met: change a package version in `project.yml` and rebuild.
- **Handing out a built app (an `.ipa`, TestFlight, the App Store):** keep these notices with it, show the license texts somewhere reasonable (for example a Licenses screen), and keep the FFmpeg frameworks dynamic. AetherEngine's exception covers store distribution. Check the package licenses again first.
- **Patents:** some codecs that FFmpeg can decode are covered by patents in some countries. HomeReel is shared as source code only.

## Trademarks

Plex and Plex Media Server are trademarks of Plex, Inc. HomeReel is an independent app. It is not affiliated with or endorsed by Plex, and it uses no Plex logo. "Dolby Vision", "Dolby Atmos", "HDR10", "Apple TV" and "tvOS" are trademarks of their owners, named here only to say what the app can play or run on. "BRAVIA" and "Sony" are trademarks of Sony Group Corporation, named only for the optional TV picture control.
