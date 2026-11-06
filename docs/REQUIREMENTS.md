# HomeReel requirements

What the app must do. `scripts/test.sh` is how these are checked. Anything that changes here belongs in `CHANGELOG.md` too.

## Scope

A native Apple TV app for a Plex Media Server you run yourself. Movies and TV Shows only. `README.md` lists the known limits.

## Rules

| Id | Requirement |
| --- | --- |
| R-1 | Play the original file. Never request video or audio transcoding. The server may resize pictures. |
| R-2 | Show Movie and TV libraries only. |
| R-3 | Keep the Plex token and TV key in the Keychain. Never write them to files or logs. |
| R-4 | Send the Plex token only to your server and to Plex's own services. |
| R-5 | Use the native tvOS look and standard focus. |
| R-6 | Keep optional features off by default, with no personal defaults in the code. |
| R-7 | Never show a failure as an empty result. Say what failed, and offer a way forward. |

## Features

| Id | Requirement |
| --- | --- |
| F-1 | Sign in with a plex.tv code, or with a server address and token. |
| F-2 | Find a reachable, direct address for the server: HTTPS first, then a plain local address. Never use a relay. |
| F-3 | Home shows Continue Watching, Recently Added Movies, and Recently Added TV Shows. |
| F-4 | Movies and TV Shows show poster grids with sort, an unwatched filter, and an A-Z strip. |
| F-5 | Detail pages show artwork, description, cast, the file format, Play or Resume, and Mark Watched or Unwatched. |
| F-6 | Search covers movies and shows. |
| F-7 | The player scrubs by swipe, skips by edge click, and opens an info panel by swiping down. |
| F-8 | The player offers subtitle and audio menus. The subtitle choice is remembered per show, with a default language in Settings. |
| F-9 | Position and watched state go back to Plex. A title counts as watched at 90 percent. |
| F-10 | Ratings show on movies, shows, and episodes. People open a page with a biography, what you own with them, and their credits. |
| F-11 | An Up Next screen appears when an episode ends. |
| F-12 | Movies and TV Shows offer a Scan Library button. |
| F-13 | Optional: a Picture tab switches a Sony BRAVIA TV between Dolby Vision modes. |
| F-14 | Sign-out removes the sign-in and everything cached from that server. |

## Decisions that changed

| Was | Now | Why |
| --- | --- | --- |
| A separate Diagnostics screen | A route and format line in the player overlay | It shows the same facts while the video plays. |
| 2 engines, AVPlayer plus AetherEngine | AetherEngine only | It handled every sample type on its own. |
