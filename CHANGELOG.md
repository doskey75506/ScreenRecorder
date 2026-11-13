# Changelog

## Unreleased

### Fixed

- Open the desktop drag overlay immediately from Area; request display authorization after selection when needed.
- Present source pickers for the existing preview stream so the one-stream limit cannot suppress a replacement picker.
- Keep Area, Screen, and Window as parallel first-level actions and pin save-folder and recording controls outside the settings scroll view.
- Add a visible cancellation path for source selection and reject mismatched display authorization.

### Added

- Drag-to-select screen recording areas, with live region previews, cancellation, and full-display reset.
- Screen and window recording with optional source audio and microphone capture.
- Video cropping, trimming, conversion, compression, and ordered clip concatenation.
- Source-file snapshots and collision-safe output names.
- English and Simplified Chinese interfaces, with English as the default and a remembered language choice.
- GitHub Actions validation on Intel and Apple Silicon, including real media tests and universal app artifacts.
- English and Chinese README documents and a GitHub maintenance guide.
