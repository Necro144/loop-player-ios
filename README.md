# Loop Player

A music and video player for your own files on iPhone. Pick a folder in iCloud Drive or On My iPhone and it plays everything inside it, subfolders too. No accounts, no streaming, nothing leaves the phone. Built for iOS 16 and later, so it runs on 16.4.1. Pure black OLED theme. Made by Necro.

## Features

- **Folders**: pick one or more folders (iCloud Drive or On My iPhone). They are remembered after the app closes. Songs stay where they are; the app only reads them. iCloud files that are not downloaded yet download when you play them.
- **Files**: MP3, M4A, AAC, WAV, FLAC, AIFF, MP4, MOV (and M4V, CAF, M4B). Title, artist, album and artwork come from the file's tags. If there are none, the file name is used ("Artist - Title.mp3" is understood).
- **Library**: Songs, Albums, Artists, Folders (browse subfolders), Videos, Favorites, Recently Played, Most Played, and search across everything. Sort songs by title, artist, album, date or length.
- **Playback**: loop one song, repeat all, shuffle, speed 0.5× to 2×, sleep timer (minutes or end of song, with a fade-out), queue with Play Next / Add to Queue, reorder and remove. It keeps playing in the background and with the screen locked.
- **Lock screen and Control Center**: artwork, title, seek bar, play/pause, next/previous, repeat and shuffle.
- **Video**: videos play with picture in the player, or full screen (rotate for landscape). The sound keeps going when you leave the app.
- **YouTube-style touches**: double-tap the left or right side of the artwork or video to jump 10 seconds; swipe it to change song; swipe the mini player up to open the full player.
- **Playlists**: make your own, reorder, rename, add songs from any screen.
- **Remembers where you were**: the queue, song and position come back next time.
- **AirPlay** button in the player. Unplugging headphones pauses; phone calls and other interruptions pause and then resume.
- **Fast with big libraries**: scanning runs in the background, the library is cached, and only new or changed files are read again. Pull down on Home or Library to scan again.

## Getting the IPA

Take `LoopPlayer.ipa` from the latest release, or from the **Actions** tab (artifact `LoopPlayer-ipa`, a zip). It is unsigned, so install it with:

- **TrollStore** (iOS 16.4.1 is supported): permanent, no expiry.
- **AltStore** or **Sideloadly**: sign it with your Apple ID. A free account needs a refresh every 7 days.

## Releases

Each release has its own "What's new" and the IPA. To publish one, add `release-notes/vX.Y.Z.md`, commit, then push the tag `vX.Y.Z` on its own.

## Tests

Both run on an iOS 16.4 simulator, by hand from the Actions tab (Run workflow) or by pushing a `test-*` branch, to save build minutes.

- `Simulator test on iOS 16.4` makes a small test library (`test/make_media.sh`), scans it, plays, loops, opens the video player and saves screenshots.
- `Folder picker test on iOS 16.4` uses the real Files picker the way you do: Choose a Folder, open a "Suno Songs" folder (one inside the app, one directly in On My iPhone), tap Open, play, then close and reopen the app to check the folder is remembered.

If a folder does not show up on the phone, Settings > Folder Log shows what happened.

## Building it yourself

Needs a Mac with Xcode and [XcodeGen](https://github.com/yonaskolb/XcodeGen): `xcodegen generate`, open `LoopPlayer.xcodeproj`, run. `tools/make_icon.py` redraws the app icon.
