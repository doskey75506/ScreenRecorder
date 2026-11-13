# ScreenRecorder

[![CI](https://github.com/doskey75506/ScreenRecorder/actions/workflows/ci.yml/badge.svg)](https://github.com/doskey75506/ScreenRecorder/actions/workflows/ci.yml)

English | [简体中文](README.zh-CN.md)

A native macOS app for screen recording, video editing, conversion, and compression. Built with SwiftUI, ScreenCaptureKit, AVFoundation, and FFmpeg. Recording and editing happen locally; no Python runtime or browser service is needed to run the app.

## Features

- Record a display or app window, with optional source audio and microphone input.
- Drag a rectangle on a display to record only the selected screen area.
- Crop video, trim time ranges, and join selected clips from multiple videos.
- Export H.264, HEVC, VP9, or AV1 in compatible MP4, MOV, MKV, and WebM containers.
- Choose original resolution, 1080p, or a 640 × 480 bounding box, without upscaling.
- Choose High quality, Balanced, or Small file, with an estimated output size.
- Preserve source files through independent editing snapshots and separate output files.
- Switch between English and Simplified Chinese instantly. English is the default; your choice is remembered.

## Requirements

- **macOS 15 or later**.
- **Xcode 16.4 or later** to build from source.
- **FFmpeg and ffprobe** for editing, conversion, compression, and additional recording formats:

```sh
brew install ffmpeg
```

The app searches `/opt/homebrew/bin`, `/usr/local/bin`, and `Contents/Resources/Tools` inside its bundle. Only available encoders are offered. The build does not bundle Homebrew executables or libraries, so install FFmpeg separately on each Mac that needs editing or conversion. Native H.264 MP4 recording works without FFmpeg.

## Build and run

```sh
git clone https://github.com/doskey75506/ScreenRecorder.git
cd ScreenRecorder
./scripts/build.sh
open build/DerivedData/Build/Products/Release/ScreenRecorder.app
```

Alternatively, open `ScreenRecorder.xcodeproj` and run the `ScreenRecorder` scheme. The build script creates a universal app containing both `x86_64` and `arm64`, with an ad hoc signature. No Apple developer account is required. The app is not notarized and is intended for local development and use.

Launch the `.app` or run through Xcode so macOS can identify the app for privacy permissions. `swift run` is for development rather than normal use. Closing the main window leaves the app running in the menu bar.

## Record

1. Click **Choose display / window** and choose a source in the macOS sharing picker.
2. Select the codec, container, resolution, and save folder. Defaults are **H.264 MP4, 30 fps, original resolution, and SDR**.
3. Enable source audio and/or a microphone if needed. Grant permissions when macOS asks.
4. Click **Start recording**, then **Stop and save** when finished. You can also stop from the menu bar.
5. The recording opens in the editor for trimming, cropping, or conversion.

Recordings default to `~/Movies/ScreenRecorder/`; a different save folder is remembered. Resizing a source window does not change the output canvas after recording starts. To record a browser tab, move it into its own browser window and select that window.

The language menu at the top right switches between **English / 简体中文** without restarting or clearing your project. Native macOS pickers, dialogs, and system errors follow the system language.

### Record a screen area

Click **Select screen area…**. On macOS 15.2+, choose a display in the system sharing picker if one is not already selected. The app temporarily hides its main window and shows a selection overlay on that display. Drag a rectangle and release to confirm, or press **Esc** / right-click to cancel. A selection stays within one display; repeat the selection to use a different area.

The preview and recording both capture only the selected rectangle. The sidebar shows its physical pixel dimensions; resolution presets scale that area while preserving its aspect ratio. Tiny selections are rejected and dimensions are rounded inward to whole, even pixels. Cancelling keeps the previous source and area. **Use full display** removes the area restriction. Source and area controls are locked while recording.

On macOS 15.0–15.1, this mode needs Screen Recording permission in System Settings; macOS may require restarting the app after granting it. Select the rectangle on the desired display. Area selection limits the **picture**, while source audio continues to follow the selected display. It does not isolate audio to the rectangle.

## Edit, convert, and compress

Open **Edit / Convert / Compress**, then click **Import video…**. Drag the crop corners, move the crop frame, or enter pixel margins. Set the start and end times, preview the selection, and export. Keep the full frame and duration to convert an entire video.

Formats without native playback, such as some MKV or WebM files, use still-frame previews. Adjust the time range to view the corresponding frames; editing and conversion remain available.

### Join clips

1. Import one or more videos. Use **Source video** to switch between them.
2. Set a time range and crop, then click **Add to clip list**. You can add multiple, repeated, or overlapping ranges from the same video.
3. Use the arrows to reorder clips or the minus button to remove one. Select a clip, edit it, and click **Update selected clip** to commit the changes.
4. Click **Export joined video…**. Only clips in the list are exported, in list order. Uncommitted draft changes are excluded.

The first clip and resolution setting determine the output canvas. Other clips fit proportionally with black bars as needed. Frame rates and audio sample rates are normalized; silent clips receive silence when mixed with clips containing audio.

With an empty list, export processes only the current selection. **Clear list** returns to this mode. **New project** clears the editing session while preserving originals and exported files. Projects are not saved across app restarts.

### Source-file protection

Importing creates an independent temporary snapshot. Previews and repeated exports use that snapshot, so moving, deleting, or modifying an external source does not break clips already loaded. APFS uses copy-on-write clones where possible; other filesystems may require a full copy and additional space. Snapshots are removed when the session closes or a new project begins.

Exports never overwrite the source. Existing output names receive a numeric suffix. Cancelling removes unfinished output. Interrupted recordings retain any data already written, but the file may not be playable.

## Formats and output size

| Video codec | Containers |
| --- | --- |
| H.264 | MP4 / MOV / MKV |
| HEVC / H.265 | MP4 / MOV / MKV |
| VP9 | WebM / MKV |
| AV1 | MP4 / WebM / MKV |

WebM uses Opus audio; other containers use AAC. AV1 can be slow to encode. When ScreenCaptureKit cannot record a selected combination directly, the app records a `*-source.mp4` and converts it after stopping. That source recording is retained if conversion fails or is cancelled.

The compact resolution fits within **640 × 480**, so a 16:9 video becomes **640 × 360**. All resolution presets preserve aspect ratio and avoid upscaling.

Output size depends primarily on **bitrate × duration**. Quality presets set a bitrate budget informed by the source. Estimates include audio and container overhead, but actual size varies with content and variable-rate encoding. High quality can produce a file larger than the original. Compression is lossy; repeated compression cannot restore detail.

## Development and tests

| Path | Purpose |
| --- | --- |
| `Sources/RecorderCore/` | Geometry, validation, recording state, localization, and export settings |
| `Sources/ScreenRecorder/` | SwiftUI interface, capture, preview, and editing services |
| `Tests/RecorderCoreTests/` | Core and language tests |
| `Tests/MediaTests/` | Real media conversion and editing tests |
| `Config/` | App metadata, entitlements, and icon |
| `scripts/` | Build, test, fixture, project-generation, and CI tools |

```sh
./scripts/test.sh                           # All XCTest suites
./scripts/test.sh --filter RecordingModelsTests
./scripts/test.sh --filter LocalizationTests
python3 scripts/generate-project.py          # After adding/removing Swift sources
./scripts/ci.sh                             # Tests, including required media coverage
```

Xcode and Swift Package Manager share the same sources. Media tests generate temporary fixtures using FFmpeg software encoders and check crop coordinates, rotation, compression, format combinations, concatenation, cancellation, and source preservation. Local tests explicitly skip when required tools are unavailable; CI treats skipped tests as failures. No numerical coverage threshold is configured.

### GitHub Actions

[CI](https://github.com/doskey75506/ScreenRecorder/actions/workflows/ci.yml) runs on pushes, pull requests, and manual dispatch. Both Intel and Apple Silicon macOS runners execute the full test suite, verify the generated Xcode project, build the universal Release app, and verify its signature and architectures. Each job uploads test reports, logs, and a zipped app. Install FFmpeg separately to use editing features in a downloaded CI build.

See [CONTRIBUTING.md](CONTRIBUTING.md) for GitHub version maintenance, [CHANGELOG.md](CHANGELOG.md) for changes, and [docs/VALIDATION.md](docs/VALIDATION.md) for validation records and manual checks. `./scripts/create-fixture.sh` generates an optional test video with two audio tracks.

## Permissions and limitations

- Screen and microphone access are controlled by macOS in **System Settings → Privacy & Security**.
- Protected content may not be captured. Source audio follows the selected sharing scope; the app excludes its own playback audio.
- Recording targets 30 fps; static content, system load, and hardware can affect actual frame delivery.
- Pause recording, a multitrack timeline, transitions, subtitles, filters, HDR, automatic updates, and App Store distribution are not provided.
- CI does not validate permission prompts, actual screen or microphone capture, long recordings, or subjective playback quality. These require manual checks.
