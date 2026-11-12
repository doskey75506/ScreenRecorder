# Contributing

## GitHub workflow

The canonical repository is [doskey75506/ScreenRecorder](https://github.com/doskey75506/ScreenRecorder), with `main` as the default branch. Treat GitHub version maintenance as part of every code update: inspect local changes and the remote branch, preserve unrelated work, run the relevant checks, update documentation, commit, push, and check the resulting CI run. Report the commit and CI outcome, including failures or pending checks.

Use the existing SSH authentication for `git@github.com:doskey75506/ScreenRecorder.git`. Never commit credentials or copy private keys into the project. Access remains subject to the owner's GitHub and SSH settings; do not replace or broaden credentials as part of routine maintenance.

Before changing code, check `git status` and fetch the remote. Use focused commits with imperative subjects, such as `Add English interface and persistent language switching`. Do not force-push or rewrite published history. Keep the English [README](README.md) and [Chinese README](README.zh-CN.md) in sync when behavior or commands change. Record user-facing changes in [CHANGELOG.md](CHANGELOG.md).

If the working directory has no Git metadata, preserve the existing remote history using a real checkout. In restricted local sessions, `build/github-checkout/` is an ignored publishing checkout; synchronize only intended source and documentation changes into it, inspect the diff, and push from there. Do not initialize a replacement history or upload generated caches and recordings.

## Validation

Use Xcode 16.4+ on macOS 15+ and install FFmpeg with `brew install ffmpeg`.

```sh
./scripts/test.sh
./scripts/build.sh
./scripts/ci.sh
```

Regenerate the Xcode project with `python3 scripts/generate-project.py` after adding or removing Swift source files. Commit the regenerated project alongside the source change. CI runs the complete XCTest suite on Intel and Apple Silicon, rejects skipped media tests, verifies the generated project, builds a universal app, and checks signatures and architectures.

PRs should explain behavior changes, validation, skips, and remaining platform limitations; include screenshots for interface changes. Screen capture permissions, audio routing, and long recordings require manual checks from [docs/VALIDATION.md](docs/VALIDATION.md).

## Release versions

Keep ordinary changes in the changelog's **Unreleased** section. A release requires a green CI run and deliberate release approval; do not create a tag for every commit. For a release, update `CFBundleShortVersionString` and increment `CFBundleVersion` in `Config/Info.plist`, move the relevant changelog entries to a dated version section, and create a matching `vMAJOR.MINOR.PATCH` tag. Never move an existing release tag. CI artifacts are development builds, not notarized releases.
