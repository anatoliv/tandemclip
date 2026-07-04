# Contributing to TandemClip

Thanks for your interest. Issues and pull requests are welcome.

## Building

TandemClip is a Swift Package Manager project targeting macOS 13+.

```sh
swift build --build-system native   # native (llbuild) engine
swift test  --build-system native   # run the test suite
```

> The default SwiftPM build engine hangs on the Sparkle-linked build, so pass
> `--build-system native` for both build and test.

To produce a runnable `.app` bundle:

```sh
Scripts/make-app.sh                 # build + ad-hoc sign (this machine only)
open build/TandemClip.app
```

## Guidelines

- Keep pull requests focused on a single change.
- Run `swift test --build-system native` and make sure it passes.
- Match the existing code style — no reformatting unrelated code.
- UI code draws from the design tokens in `Sources/tandemclip/Theme.swift`, not
  raw sizes/radii. `Scripts/check-release.sh` runs a drift lint that fails on raw
  `cornerRadius:` / `.system(size:)` values in view code. See
  `docs/design/DESIGN_SYSTEM.md`.
- For user-facing changes, add a line to `CHANGELOG.md` under an "Unreleased"
  heading.

## Reporting security issues

Please do not open a public issue for security vulnerabilities. See
[SECURITY.md](SECURITY.md).
