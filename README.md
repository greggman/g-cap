# G-Cap

A native macOS screen recorder. Records a screen, a window, or a region, with
system audio and/or microphone, in HEVC, H.264 or ProRes at native resolution.

Requires macOS 15 or later.

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
./build.sh            # builds build/G-Cap.app for this Mac
UNIVERSAL=1 ./build.sh   # arm64 + x86_64
open build/G-Cap.app
```

## Usage

- Choose **Screen**, **Window** or **Region** (Region → *Select…*, then drag; Esc cancels).
- Toggle system audio / microphone. When both are on they are saved as separate audio tracks.
- Click **Record** (or ⇧⌘R). Stop from the window, ⇧⌘R, or the menu bar icon.
- Recordings go to `~/Movies/G-Cap` by default.

## Releases

Pushing a tag like `v0.1.0` makes GitHub Actions build a universal app and
attach `G-Cap.zip` to a GitHub release.
