# Repository Guidelines

## Project Structure & Module Organization

ScreenRecorder is a native macOS 15+ application built with SwiftUI, ScreenCaptureKit, and AVFoundation. `Sources/RecorderCore/` contains reusable validation, recording states, resolution rules, and file naming. `Sources/ScreenRecorder/` contains the UI, capture service, and video editor. XCTest suites live in `Tests/RecorderCoreTests/` and `Tests/MediaTests/`. Application metadata and entitlements live in `Config/`; build tools live in `scripts/`. Keep generated recordings, fixtures, caches, and application bundles under ignored `build/` or `.build/` directories.

## Build, Test, and Development Commands

- `./scripts/build.sh`: build the Release `.app` for Intel and Apple Silicon using Xcode.
- `open build/DerivedData/Build/Products/Release/ScreenRecorder.app`: launch the application with its bundle identity and privacy declarations.
- `./scripts/test.sh`: run all Swift Package XCTest suites.
- `./scripts/test.sh --filter RecordingModelsTests`: run core unit tests.
- `python3 scripts/generate-project.py`: regenerate the checked-in Xcode project after adding or removing Swift source files.

Use Xcode 16.4 or newer. Xcode and Swift Package builds share the same sources; tests run through Swift Package Manager.

## Coding Style & Naming Conventions

Use four-space indentation, `UpperCamelCase` types, and `lowerCamelCase` methods and properties. Keep UI strings in concise Chinese. Confine observable UI state to `@MainActor`; process preview frames on the dedicated capture queue. Keep geometry and validation independently testable in RecorderCore. No formatter or linter is currently configured.

## Testing Guidelines

Use XCTest with descriptive `test…` method names. Test coordinate conversion, time boundaries, state gates, cancellation, and source-file preservation. Media tests require macOS media services and explicitly skip unavailable VideoToolbox sessions. Report skips separately from passes; no numerical coverage threshold is configured. Follow `docs/VALIDATION.md` for permission, audio, display, and long-recording checks.

## Commit & Pull Request Guidelines

No Git history existed at project creation. Use concise imperative subjects, such as `Fix rotated video crop coordinates`. PR descriptions should explain behavior, validation, skipped checks, and remaining platform limitations. Include screenshots for UI changes.

## Privacy & Configuration

Keep recordings, credentials, and personal paths out of commits. Preserve original videos during editing. Request permissions only when needed, and never silently overwrite existing output files. Do not modify the sibling Badminton project.
