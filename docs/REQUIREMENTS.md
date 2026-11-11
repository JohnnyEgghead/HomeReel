# HomeReel requirements

What the app must do. `scripts/test.sh` is how these are checked. Anything that changes here belongs in `CHANGELOG.md` too.

## Scope

A native Apple TV app for a Plex Media Server you run yourself. Movies and TV Shows only. `README.md` lists the known limits.

## Rules

| Id | Requirement |
| --- | --- |
| R-1 | Play the original file. Never request video or audio transcoding. The server may resize pictures. |
| R-2 | Show Movie and TV libraries only. |
| R-3 | In the app, keep the Plex token and TV key in the Keychain. Never write them to files or logs. (`scripts/plex_inventory.py` is a developer tool, not the app: it reads a token file on your Mac, which is mode 600, and writes its table with mode 600 too.) |
| R-4 | Send the Plex token only to your server and to Plex's own services. |
| R-5 | Use the native tvOS look and standard focus. |
| R-6 | Keep optional features off by default, with no personal defaults in the code. |
| R-7 | Never show a failure as an empty result. Say what failed, and offer a way forward. |
| R-8 | A redirect to another host is refused, so a token or TV key never follows it. The video file itself is the exception, because the player engine makes that request. |

## Features

| Id | Requirement |
| --- | --- |
| F-1 | Sign in with a plex.tv code, or with a server address and token. A code sign-in uses only a server your account owns, never one shared with you. |
| F-2 | Find a reachable, direct address for the server, and confirm it is that server before the token is sent. The order is the local HTTPS address, the local plain address, then other direct HTTPS addresses. Never use a relay. |
| F-3 | Home shows Continue Watching, Recently Added Movies, and Recently Added TV Shows, all as posters. |
| F-4 | Movies and TV Shows show poster grids with sort, an unwatched filter, and an A-Z strip. |
| F-5 | Detail pages show artwork, description, cast, the file format, Play or Resume, and Mark Watched or Unwatched. |
| F-6 | Search covers movies and shows. |
| F-7 | The player skips by edge click and opens an info panel by swiping down. A swipe previews a new point on the timeline: the video pauses and shows the frame at that point. Select goes there, Menu goes back to where you were, and lifting the finger does nothing. |
| F-8 | The player offers subtitle and audio menus. The subtitle choice is remembered per show, with a default language in Settings. |
| F-9 | Position and watched state go back to Plex. A title counts as watched at 90 percent. |
| F-10 | Ratings show on movies, shows, and episodes. People open a page with a biography, what you own with them, and their credits, which a role filter narrows. |
| F-18 | A credit for a title you do not own opens a page with its poster, whole description, scores, cast, and crew from Plex's online database. |
| F-11 | An Up Next screen appears when an episode ends. |
| F-17 | Episodes show the day they first aired, when Plex has it, on the episode page and in the season list. |
| F-12 | Movies and TV Shows offer a Scan Library button. |
| F-13 | Optional: a Picture tab switches a Sony BRAVIA TV between Dolby Vision modes. |
| F-14 | Sign-out removes the sign-in and everything cached from that server. Subtitle choices stay, and are kept per server. |
| F-15 | Each launch asks the saved address who it is before the token is sent. If it is not the server you signed in to, the app asks plex.tv where that server is now. A refused token, from any screen, returns to sign-in and says why, but only after plex.tv itself also refuses it. If plex.tv says the token is fine, or cannot be reached, the sign-in is kept and a message says so. |
| F-16 | After the app is left (the TV button) and opened again during playback, the video is rebuilt at the same place and comes back paused. Nothing the remote does counts while it rebuilds, and a failed rebuild says so. |

## Decisions that changed

| Was | Now | Why |
| --- | --- | --- |
| A separate Diagnostics screen | A route and format line in the player overlay | It shows the same facts while the video plays. |
| 2 engines, AVPlayer plus AetherEngine | AetherEngine only | It handled every sample type on its own. |
