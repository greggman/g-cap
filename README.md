# G-Cap

A native macOS screen recorder. Records a screen, a window, or a region, with
system audio and/or microphone, in HEVC, H.264 or ProRes at native resolution.

Requires macOS 15 or later on Apple silicon.

## Install

Download `G-Cap.zip` from [Releases](../../releases), unzip it, and move
`G-Cap.app` to `/Applications`. The build is not signed or notarized, so
remove the quarantine flag before the first launch:

```sh
xattr -dr com.apple.quarantine /Applications/G-Cap.app
```

On first use macOS asks for Screen Recording permission (and Microphone
permission if you enable the mic). After granting Screen Recording, relaunch.

## Build

```sh
./build.sh   # builds build/G-Cap.app
open build/G-Cap.app
```

## Usage

- Choose **Screen**, **Window** or **Region** (Region → *Select…* / *Edit…*: drag the middle to move, edges or corners to resize, or drag on empty space to draw a new one; type an exact pixel size, lock an aspect ratio, or pick a preset; arrows nudge, Return or Done accepts, Esc cancels, Record starts right away).
- Toggle system audio / microphone. When both are on they are saved as separate audio tracks.
- Click **Record** (or ⇧⌘R). Stop from the window, ⇧⌘R, or the menu bar icon.
- Recordings go to `~/Movies/G-Cap` by default.

## Releases

Pushing a tag like `v0.1.0` makes GitHub Actions build the app and
attach `G-Cap.zip` to a GitHub release.

## License: [MIT](LICENSE.md)

