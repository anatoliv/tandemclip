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

## Releasing — and how changes reach users

The key thing to understand: `brew install --cask tandemclip` and Sparkle both
install the **pre-built, notarized DMG from tandemclip.com** — not the source in
this repo. GitHub only supplies the cask *recipe* (`Casks/tandemclip.rb`);
tandemclip.com supplies the *binary*. That splits your work into two cases.

**1. You push code or docs (not a release).** Editing Swift, the README, tests,
etc. and pushing has **no effect** on installed apps or Homebrew users — the DMG
doesn't change, so nobody's TandemClip changes. Just push; nothing else to do.

**2. You want users to actually get the change (ship a version).** Cut a full
release — this is the only path that reaches users:

1. Bump `CFBundleShortVersionString` **and** `CFBundleVersion` in
   `Packaging/Info.plist` (the appcast check refuses a build number that isn't
   higher than the last release).
2. Add a `CHANGELOG.md` entry (and a "What's New" entry in `HelpContent.swift`).
3. Run `Scripts/release.sh` with your signing env vars and `PUBLISH=1` +
   `PUBLISH_DEST` (see the README's *Releasing* section). One command builds →
   notarizes → publishes the DMG + `appcast.xml` to the web host → **rewrites
   `Casks/tandemclip.rb`** with the new version and the new DMG's `sha256`.
4. `git add Casks/tandemclip.rb`, commit, push, then tag `vX.Y.Z`.

After that, existing users auto-update via Sparkle (from `appcast.xml`), and
Homebrew users get it on their next `brew update && brew upgrade`.

**Gotchas**

- **Never hand-edit `version` / `sha256` in the cask.** The `sha256` must
  byte-match the published DMG; `release.sh` computes it from the real build. A
  hand-bumped version without a republished DMG will 404 or fail the checksum.
- **Publish the DMG before (or in the same run as) pushing the cask.** Because
  `release.sh` publishes *and* syncs the cask together, only commit the cask
  after a successful `release.sh` run — then they can't drift apart.
- `auto_updates true` in the cask is intentional: it tells Homebrew the app
  self-updates via Sparkle, so `brew upgrade` won't fight the in-app updater.

## Reporting security issues

Please do not open a public issue for security vulnerabilities. See
[SECURITY.md](SECURITY.md).
