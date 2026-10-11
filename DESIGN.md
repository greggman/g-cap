# G-Cap design

A native macOS screen recorder (Swift, SwiftUI, ScreenCaptureKit, AVAssetWriter).
Requires macOS 15+.

Native was chosen over Electron because Electron's MediaRecorder only produces
WebM with little control over quality. Native gives hardware HEVC/H.264 at a
chosen bitrate, or ProRes, plus system and microphone audio directly from
ScreenCaptureKit.

Note: You can download from [Releases] but you will need to remove the quarantine
because the build is unsigned/un-notarized.

```sh
xattr -dr com.apple.quarantine <path-to.app>
```

Or you can download and build yourself.

## Requirements

1. Capture video and audio (system audio and/or microphone).
2. High quality: native pixel resolution, up to 60 fps, generous bitrates or ProRes.
3. Capture a whole screen, a single window, or a dragged-out region.

## Structure

- `CaptureEngine` owns the `SCStream` and forwards sample buffers, on one
  serial queue, to `Recorder`.
- `Recorder` writes a `.mov` with `AVAssetWriter`: one video track, plus
  separate tracks for system audio and the microphone.
- `RegionEditor` shows a dimmed overlay on every screen with an editable
  rectangle (move, resize from edges/corners, aspect lock, exact pixel size,
  presets) and a floating panel; the region and aspect are remembered.
  While recording, `RegionOutline` draws a red frame around the region. G-Cap's
  own windows are excluded from capture, so neither appears in the video.
- `AppState` holds the UI state and builds the `SCContentFilter` /
  `SCStreamConfiguration`.
