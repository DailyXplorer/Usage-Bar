# Conventions

Single source of truth for names and Git hygiene in this repository.
Humans and agents follow this file. Workflow, tests, and how to ship a
release stay in [AGENTS.md](AGENTS.md).

English everywhere that ships or is reviewed: UI, commits, PR titles,
PR bodies, issue titles, branch descriptions, and user-facing docs.

## Principles

1. One concern per branch, commit, and pull request.
2. Names describe **intent**, not implementation.
3. Prefer the shortest name that is still unambiguous.
4. Imperative mood for anything Git will show as a subject
   (“If applied, this will…”).
5. Explain **why** in the body. The diff already shows **how**.

## Branches

Trunk is `main`. Do not commit on it except for the documented release
tag step in [AGENTS.md](AGENTS.md).

Format (Conventional Branch, short aliases):

```text
<type>/<description>
```

`description` is kebab-case: lowercase `a-z`, `0-9`, hyphens. No
underscores, spaces, consecutive hyphens, or leading/trailing hyphens.
Two to five words. Dots only on `release/` version strings.

| Type | Use for | Example |
| --- | --- | --- |
| `feat/` | New user-visible capability | `feat/update-check` |
| `fix/` | Bug fix | `fix/menu-overlap` |
| `docs/` | Documentation only | `docs/conventions` |
| `chore/` | Maintenance, deps, config | `chore/ci-cache` |
| `ci/` | GitHub Actions / scripts | `ci/release-runner` |
| `refactor/` | Same behavior, different shape | `refactor/usage-store` |
| `hotfix/` | Urgent fix against what users run | `hotfix/updater-crash` |
| `release/` | Release preparation only | `release/v1.2.0` |

Prefer purpose prefixes over agent prefixes (`t3code/`, `cursor/`,
`claude/`, `codex/`, `ai/`). Those prefixes exist in Conventional
Branch for tooling; they do not replace `feat/` / `fix/` on a PR
branch.

This repo does **not** use long-lived `develop`. Cut a release from
`main` as in [AGENTS.md](AGENTS.md). Do not open `release/` branches
unless the release itself needs a PR.

```text
Good:  feat/cursor-usage-settings
Good:  fix/menu-overlap
Bad:   Fix/MenuOverlap
Bad:   feat/new_feature
Bad:   t3code/83e29efc          (opaque; no purpose)
Bad:   feat/add-login-and-rewrite-readme
```

## Commits

This project does **not** require Conventional Commits type prefixes
(`feat:`, `fix:`). Versioning is tag-driven (SemVer on `main`), and
release notes come from merged PRs.

Subject (required):

- Imperative, capitalized, no trailing period
- One line, aim for ≤72 characters
- Completes: “If applied, this commit will …”
- **Why** over a restatement of the diff

Body (when the subject is not enough):

- Blank line after the subject
- One or two short sentences
- Wrap near 72 characters
- Optional `Refs: #123` / `Closes #123` trailers

Do not mix unrelated concerns in one commit. Do not skip hooks.

```text
Good:
Keep the menu window off the screen edge

The popover was flush with the display edge on small screens, so the
first row was easy to miss.

Good:
Apply Instrument Sans to native Settings buttons

SwiftUI .font does not reach AppKit NSButton, so the update control
was still using the system face.

Bad:
fixed stuff
Bad:
feat(ui): resolve footer press appearance
Bad:
Update files.
Bad:
WIP
```

Merge commits created by GitHub (`Merge pull request #N …`) are
allowed. Do not hand-write merge commits that mix two features.

## Pull requests

Open against up-to-date `main`. One concern per PR: do not mix a
feature with a release tag, a version bump, or an unrelated README
rewrite.

### Title

Same rules as a commit subject: imperative summary, no type prefix,
no trailing period. GitHub’s release notes generator uses PR titles.

```text
Good:  Keep the menu window off the screen edge
Good:  Add Cursor usage pools to Settings
Bad:   feat: add cursor settings
Bad:   Updates
Bad:   Fix issue
```

### Body

```markdown
## Summary

- What changed and why (not a file list)

## Test plan

- `swift test`
- Manual pass if the menu, Settings, or updater changed:
  `scripts/build-app.sh`, then `/Applications/UsageBar.app`
```

Link related issues with `Closes #N` or `Refs #N`. Call out breaking
behavior, migration, or anything reviewers should read first.

Keep the PR small enough to review in one sitting. Self-review the
diff before asking for review.

Do **not** bump `Support/Info.plist` versions in a feature PR. Do
**not** push `v*` tags from a feature branch. Do **not** force-push
`main`.

## Issues

Title: short imperative or problem statement in English.

```text
Good:  Menu popover clips on the left screen edge
Good:  Show Cursor usage next to Codex and Claude
Bad:   bug
Bad:   please fix
```

Describe expected vs actual behavior, macOS version, and how to
reproduce. One issue per problem.

## Tags, versions, and release assets

| Thing | Pattern | Example |
| --- | --- | --- |
| Git tag | `vMAJOR.MINOR.PATCH` | `v1.1.0` |
| `CFBundleShortVersionString` | tag without `v` (stamped by the release workflow) | `1.1.0` |
| Bundle identifier | reverse-DNS, lowercase | `com.usagebar.app` |
| Release zip | exact name | `UsageBar.app.zip` |
| Checksum | exact name | `UsageBar.app.zip.sha256` |

SemVer: MAJOR for breakages, MINOR for features, PATCH for fixes.
Never retag a version that already has a zip attached. Tags belong on
`main` after merge. Asset names are part of the public contract; do
not rename them without updating `install.sh`, the workflow, tests,
and the README together.

The installed app is always `/Applications/UsageBar.app` (Finder:
**Usage Bar**). Product module and target stay `UsageBar`.

## Files, folders, and scripts

| Kind | Convention | Example |
| --- | --- | --- |
| Swift source | PascalCase, one primary type per file | `MenuBarLabelImage.swift` |
| Swift tests | `TypeNameTests.swift` next to the behavior | `AppUpdaterTests.swift` |
| Scripts | kebab-case, executable | `scripts/build-app.sh` |
| Markdown / docs images | kebab-case | `docs/usage-bar-codex-opencode.png` |
| This file | uppercase root doc | `CONVENTIONS.md`, `AGENTS.md`, `README.md` |
| GitHub workflows | kebab-case | `.github/workflows/release.yml` |
| Resources | descriptive, stable names | `InstrumentSans.ttf`, `AppIcon.svg` |

Do not commit `.build/`. Do not add a new top-level folder without a
reason that does not fit `Sources/`, `Tests/`, `scripts/`, `Support/`,
`docs/`, or `.github/`.

JSON keys from third-party APIs stay as the vendor sent them
(`snake_case` in `CodingKeys`). Swift properties mapped from those
keys are `lowerCamelCase`.

## Swift names

Follow the [Swift API Design Guidelines](https://swift.org/documentation/api-design-guidelines/).
Clarity at the point of use first.

| Kind | Case | Example |
| --- | --- | --- |
| Types, protocols | UpperCamelCase | `UsageModel`, `LimitBucket` |
| Everything else | lowerCamelCase | `usedPercent`, `startAutomaticChecks()` |
| Enum cases | lowerCamelCase | `.codex`, `.claude`, `.cursor`, `.opencode` |
| Constants / statics | lowerCamelCase | `AppDistribution.assetName` |

- No Objective-C style prefixes (`UBUsageModel`). The module name is
  the namespace.
- Name methods by side effects: verbs mutate (`sort()`), nouns or
  `-ed`/`-ing` forms return a value (`sorted()`).
- Protocols that *are* a thing read as nouns; capabilities use
  `-able` / `-ible` / `-ing`.
- Booleans read as assertions: `isVisible`, `hasSettingsWindow`.
- Avoid repeating the type in the name (`usageResponse` not
  `usageResponseObject`).
- User-visible strings are English. Do not add `//` comments in
  Swift.

Match existing files: `*Service.swift` for network/session work,
`*View.swift` for SwiftUI screens, `*Tests.swift` for tests.

## Tests

Name the type after the production type plus `Tests`. Name methods
after the behavior they lock:

```swift
func menuBarLabelIsASingleImage()
```

not `test1()`. Put new tests in `Tests/UsageBarTests`. Run
`swift test` before opening a PR.

## Documentation and UI copy

- Sentence case for headings in GitHub Markdown (`## Pull requests`).
- Title Case for macOS UI labels that already use it (**Settings…**,
  **Launch at login**).
- American spelling is fine; stay consistent with nearby copy.
- Do not document the debug binary as the way users run the app.

## Sources

These conventions adapt, they do not replace, the following:

- [Conventional Branch 1.1.0](https://conventionalbranch.org/)
- [How to Write a Git Commit Message](https://cbea.ms/git-commit/)
  (Tim Pope / Chris Beams: imperative, subject/body, why over how)
- [GitHub: Helping others review your changes](https://docs.github.com/en/pull-requests/collaborating-with-pull-requests/getting-started/helping-others-review-your-changes)
- [Semantic Versioning](https://semver.org/)
- [Swift API Design Guidelines](https://swift.org/documentation/api-design-guidelines/)

Conventional Commits is intentionally not required here: this repo
stamps versions from git tags and writes release notes from PRs, not
from commit type prefixes.
