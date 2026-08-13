# AGENTS.md

Instructions for coding agents working on **Usage Bar**
(`https://github.com/DailyXplorer/Usage-Bar`).

Humans install the app from [README.md](README.md). This file is how you change
the code, open a pull request, and ship a GitHub release that existing installs
can update.

## What this repo is

SwiftUI macOS 14+ **menu bar extra** (no Dock icon). It shows Codex, Claude
Code, and Cursor usage limits. The installed app is always
`/Applications/UsageBar.app`. In-app updates download
`UsageBar.app.zip` from GitHub Releases.

English UI. No `//` comments in generated Swift. Do not commit `.build/`.

## Everyday commands

```sh
swift test
scripts/build-app.sh
```

`scripts/build-app.sh` compiles Release, ad-hoc signs, and installs
`/Applications/UsageBar.app`. On GitHub Actions it skips that install and
writes `.build/UsageBar.app.zip`.

```sh
scripts/build-app.sh --no-install
scripts/build-app.sh --no-install --zip
swift build && ./.build/debug/UsageBar
```

The debug binary is not the `.app`. Do not tell users to run it.

## Pull requests

1. Branch from up-to-date `main`. Use a short name (`fix/menu-overlap`,
   `feat/update-check`).
2. One concern per PR. Do not mix a feature with a release tag or a README
   rewrite unless the PR *is* that rewrite.
3. Match existing Swift style. Keep the interface in English. Do not add `//`
   comments.
4. Add or extend tests next to the behavior you change
   (`Tests/UsageBarTests`).
5. Run `swift test` and fix failures before opening the PR.
6. Commit in the repo’s style: imperative, one or two sentences, **why** more
   than **what**. Example: `Keep the menu window off the screen edge`.
7. Push the branch and open a PR against `main`.
8. Title: imperative summary. Body:
   - what changed and why
   - how you tested (`swift test`, plus a manual pass if UI is involved)
9. Do not bump `Support/Info.plist` versions in a feature PR. The release
   workflow stamps `CFBundleShortVersionString` / `CFBundleVersion` from the
   git tag.
10. Do not push `v*` tags from a feature branch. Tags are for `main` after
    merge (see below).
11. Do not force-push `main`. Do not skip hooks.

Manual UI check when the menu, settings, or updater changed:

- `scripts/build-app.sh` then open `/Applications/UsageBar.app`
- confirm the menu bar extra, Settings, launch-at-login, and Updates

## Releases

Users update from GitHub Releases. A tag on `main` is what ships.

### Versioning

- Tags: `vMAJOR.MINOR.PATCH` (semver). Example: `v1.1.0`.
- The updater compares the tag (leading `v` stripped) to the running app’s
  `CFBundleShortVersionString`.
- GitHub’s “latest” release must include an asset named **`UsageBar.app.zip`**
  (`AppDistribution.assetName`). Any other name and `scripts/install.sh` plus
  the in-app updater will miss it.

### Cut a release (after the PR is merged)

Work on `main`, clean working tree, tests green:

```sh
git checkout main
git pull origin main
swift test
git tag v1.1.0
git push origin v1.1.0
```

Bump MAJOR for breakages, MINOR for features, PATCH for fixes. Never retag a
version that already has a zip attached.

`.github/workflows/release.yml` then:

1. Builds with `USAGEBAR_VERSION` from the tag.
2. Creates the GitHub Release.
3. Attaches `.build/UsageBar.app.zip`.
4. Generates notes from PRs merged since the previous tag (`generate_release_notes`).

Wait until the **Release** workflow is green and the zip is on the release
page. Only then is `scripts/install.sh` / Settings → Updates able to see it.

Do not create the release zip by hand and upload it unless the workflow is
broken. If you must, the file name still has to be `UsageBar.app.zip`.

### What users get

- New installs: README one-liner or the zip from that release, into
  Applications.
- Existing installs: daily GitHub check (optional auto-install), or the
  **Check for Updates** / **Install x.y.z** button, with those PR notes in
  Settings.

## Layout agents should know

| Path | Role |
| --- | --- |
| `Sources/UsageBar/` | App sources |
| `Support/Info.plist` | Bundle id `com.usagebar.app`; default version `1.0` |
| `scripts/build-app.sh` | Build, sign, install, optional zip |
| `scripts/install.sh` | Download latest GitHub zip → Applications |
| `.github/workflows/release.yml` | Tag `v*` → release + zip + PR notes |
| `Sources/UsageBar/AppDistribution.swift` | GitHub owner/repo/asset name |
| `Sources/UsageBar/AppUpdater.swift` | In-app GitHub updater |
| `Sources/UsageBar/LaunchAtLogin.swift` | Login item; copies to Applications if needed |

Menu bar label: always a single `Image` from `MenuBarLabelImage`. Do not go
back to sibling views in `MenuBarExtra`’s label.

## Out of scope unless asked

- Apple Developer ID / notarization (builds are ad-hoc signed).
- Sparkle. Updates are GitHub Releases only.
- Changing `AppDistribution.assetName` without updating `install.sh`, the
  workflow, tests, and README together.
