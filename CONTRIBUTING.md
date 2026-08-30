# Contributing to Usage Bar

Keep each change focused. Explain why the change is needed and test the behavior
it affects.

## Before you start

- Search the existing [issues](https://github.com/DailyXplorer/Usage-Bar/issues)
  and [pull requests](https://github.com/DailyXplorer/Usage-Bar/pulls).
- Use the [bug report template](https://github.com/DailyXplorer/Usage-Bar/issues/new?template=bug_report.md)
  for a reproducible defect.
- Open an issue before a large feature or behavior change so maintainers can
  agree on the scope before implementation.

## Set up the project

Usage Bar requires macOS 14 or newer and the
[Xcode Command Line Tools](https://developer.apple.com/download/all/?q=command%20line%20tools).

Fork the repository, then replace `YOUR_USERNAME` in these commands:

```sh
git clone git@github.com:YOUR_USERNAME/Usage-Bar.git
cd Usage-Bar
git remote add upstream https://github.com/DailyXplorer/Usage-Bar.git
git fetch upstream
swift test
```

Build the universal app bundle without installing it:

```sh
scripts/build-app.sh --no-install
```

## Create a branch

Start from the latest `main` and use a purpose prefix:

```sh
git fetch upstream
git switch -c fix/menu-overlap upstream/main
```

Use `feat/`, `fix/`, `docs/`, `chore/`, `ci/`, or `refactor/` as appropriate.
Write the description in kebab-case with two to five words. See
[CONVENTIONS.md](CONVENTIONS.md) for the full naming rules and examples.

## Make a change

- Keep one concern in each branch, commit, and pull request.
- Match the Swift and SwiftUI patterns in nearby files. This project does not
  require SwiftFormat or SwiftLint.
- Keep the interface, commit messages, pull requests, and documentation in
  English.
- Add or update tests in `Tests/UsageBarTests` for changed behavior.
- Update documentation when setup, behavior, or a public contract changes.
- Do not add `//` comments to Swift files.
- Do not commit `.build/`.
- Do not change `Support/Info.plist` versions or create a `v*` tag in a feature
  branch.

## Commit the change

Write an imperative subject without a type prefix or trailing period. Keep the
subject under 72 characters when possible. Use the body to explain why the
change is needed when the subject is not enough.

For example, use `Keep the menu window off the screen edge`, not
`fix(ui): adjust menu position`.

## Validate the change

Run the test suite before every pull request:

```sh
swift test
```

If the build, packaging, installer, or updater changes, build the universal app:

```sh
scripts/build-app.sh --no-install
```

If the menu, Settings, or updater changes, install and open the app:

```sh
scripts/build-app.sh
open /Applications/UsageBar.app
```

Check the changed flow in the installed app. The debug binary is not the app
that users install.

## Open a pull request

1. Push the branch to your fork.
2. Open a pull request against `DailyXplorer/Usage-Bar:main`.
3. Use an imperative title without a type prefix or trailing period. For
   example, use `Keep the menu window off the screen edge`.
4. Complete the pull request template with the reason for the change and the
   exact checks that passed.
5. Add screenshots or a recording for visible changes.
6. Review the diff and keep the pull request small enough to review in one
   sitting.

By contributing, you agree that your contribution is licensed under the
[MIT License](LICENSE).
