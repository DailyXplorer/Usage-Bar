# UsageBar

Small macOS menu bar app (SwiftUI) that shows your **Codex** (ChatGPT plan),
**Claude Code** (Anthropic plan) and **Cursor** usage limits: **percentage
remaining** and time until reset.

<p align="center">
  <img src="docs/screenshot.png" alt="UsageBar in the macOS menu bar, with the popover open" width="380">
</p>

In the menu bar: `‹ChatGPT logo› 99% ‹Claude logo› 99% ‹Cursor logo› 99%` — the
Codex primary window, Claude Code's **All models** bar (the weekly all-models
limit), then Cursor's **Cursor Models** pool (Grok and Composer). Settings let
you pick which plans appear. The popover breaks down every window on each side.

The whole label is **composed off-screen into a single template image**
(`MenuBarLabelImage`), and that is deliberate: `MenuBarExtra` renders only one
image and one text in its label, drops an image interpolated into a string, and
freezes the view hierarchy on first render — a segment added later by an `if`
would never appear. A single `Image` whose value alone changes works around all
three constraints. Do not go back to sibling views: two tests lock this in.

## Install

macOS 14 or newer. The app installs into **Applications** as
`/Applications/UsageBar.app` (Finder shows **Usage Bar**). It runs in the menu
bar only — no Dock icon.

### Option 1 — GitHub release (no Xcode)

1. Open the [latest release](https://github.com/DailyXplorer/Usage-Bar/releases/latest).
2. Download **`UsageBar.app.zip`**.
3. Unzip it.
4. Drag **Usage Bar** into **Applications**.
5. Open it from Applications.

If macOS refuses the first launch (ad-hoc signature), in Finder:
**right-click → Open**.

### Option 2 — one command

```sh
curl -fsSL https://raw.githubusercontent.com/DailyXplorer/Usage-Bar/main/scripts/install.sh | sh
```

That downloads `UsageBar.app.zip` from the latest GitHub release, installs it
to Applications, and launches it.

### After install

- Open the popover from the menu bar icon.
- **Settings…** → **Launch at login** to start Usage Bar when you log in.
- **Settings…** → **Updates** to check GitHub or turn on automatic installs.
  When a newer release exists, an **Update** button also appears in the popover.

You need a Codex CLI login (`codex login`) for ChatGPT limits, a Claude Code
login for Anthropic limits, and a signed-in Cursor app for Cursor limits.
Missing accounts are hidden, not errors.

### From source

Needs [Xcode Command Line Tools](https://developer.apple.com/download/all/?q=command%20line%20tools):

```sh
git clone https://github.com/DailyXplorer/Usage-Bar.git
cd Usage-Bar
chmod +x scripts/build-app.sh
scripts/build-app.sh
```

That compiles a release build and installs `/Applications/UsageBar.app`.

```sh
scripts/build-app.sh --no-install          # only .build/UsageBar.app
scripts/build-app.sh --no-install --zip    # also .build/UsageBar.app.zip
swift test                                 # unit tests
swift build && ./.build/debug/UsageBar     # debug binary, not the .app
```

Agents and maintainers: contributing, PRs, and cutting a GitHub release are in
[AGENTS.md](AGENTS.md).

## How it works

### Codex

- Reads `~/.codex/auth.json` (the same file the Codex CLI uses) to get the
  ChatGPT `access_token` and `account_id`.
- Queries the official endpoint `https://chatgpt.com/backend-api/wham/usage`
  (the same one `codex /status` uses).
- Shows the primary window ("weekly", "5h", … depending on the duration the
  backend returns, same heuristic as the CLI) and the secondary window when
  present.

### Claude Code

- Reads the OAuth token from the macOS keychain through `/usr/bin/security`,
  exactly the way Claude Code writes it — that is what avoids a keychain
  authorization prompt on every launch. Falls back to
  `~/.claude/.credentials.json`. No token is ever copied or rewritten.
- Queries `https://api.anthropic.com/api/oauth/usage`, the endpoint Claude Code
  uses for its `/usage` command.
- Mirrors Claude Code's three built-in bars: **Session 5h**,
  **Week · All models** and **Week · ‹model›** (the pinned per-model limit,
  e.g. Opus), each with its reset time.
- If there is no Claude Code session, the section is simply hidden.

### Cursor

- Reads the session from Cursor's local store
  (`~/Library/Application Support/Cursor/User/globalStorage/state.vscdb`):
  `cursorAuth/accessToken` and `cursorAuth/stripeMembershipType`. No token is
  ever copied or rewritten.
- Queries `https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage`,
  the same dashboard usage endpoint.
- Mirrors Cursor's two plan pools: **Cursor Models** (Grok and Composer) and
  **Other Models** (third-party models billed at API rates), each with the
  billing-cycle reset. The menu bar shows the Cursor Models pool.
- If there is no Cursor session, the section is simply hidden.

All accounts are queried in parallel: a slow backend does not block the others,
and an error on one side does not wipe out the other sides' bars.

### Going easy on the endpoints

Claude's and Cursor's usage endpoints return **429** if you hit them too often.
Three safeguards:

- the last state is **persisted** (`UserDefaults`) and redisplayed before any
  request, so restarting the app costs no network call and never shows "–" when
  the value is already known;
- a request is only issued when the data is more than 5 minutes old (so opening
  the popover does not systematically trigger a call; the "Retry" button does
  force one);
- on 429, **progressive backoff** (5 → 15 → 30 → 60 min), during which the last
  known values stay on screen.

`Updated at` timestamps the **data**, not the last attempt: a failed refresh
never passes stale state off as fresh. Persisted percentages are frozen at
capture time, but countdowns are recomputed from the reset time when read back.

- Shows the **% remaining** (e.g. 66% remaining = 34% used).
- Refreshes automatically every 5 minutes and when the popover opens.

## Design

- English interface.
- **Instrument Sans** typeface (variable, bundled in the app), including for the
  menu bar label. Careful: since the file is variable, only one face is
  registered (`InstrumentSans-Regular`). Weights go through the `wght` axis
  (`AppTheme.nsFont`); asking for "InstrumentSans-SemiBold" by name fails and
  **silently** falls back to the system font.
- **Hugeicons** `chat-gpt`, `claude` and `cursor` logos (Logos category,
  stroke · rounded), bundled as SVG and rendered as templates so they follow
  the menu bar theme.

## Requirements

- macOS 14+ (Sonoma or newer)
- Signed in to the Codex CLI with a ChatGPT account: `codex login`
- For the Claude side: signed in to Claude Code (`claude`, then `/login`)
- For the Cursor side: signed in to the Cursor app
- To **build from source**: Xcode Command Line Tools (`xcode-select --install`)

## Notes

- The app runs as an accessory agent: no Dock icon, menu bar only.
- No data leaves your machine beyond the usage requests to chatgpt.com,
  api.anthropic.com and api2.cursor.sh, identical to the ones the CLIs and
  Cursor itself make, and the optional GitHub Releases check for updates.
- **Keychain**: the `Claude Code-credentials` entry is created by Claude Code
  through `/usr/bin/security`, so its ACL only trusts that binary. The app goes
  through the same path: no authorization prompt, including after a rebuild
  (the app is ad-hoc signed, so its signature changes every time).
- The Claude token is refreshed by Claude Code itself. If it has expired and
  Claude Code has not run in a while, the section shows "Claude token expired"
  until the next time Claude Code opens.
- The Cursor token is read from Cursor's local session store. If it has expired,
  the section shows "Cursor token expired" until the next time Cursor opens.

## License

The code in this project is licensed under the **MIT** license — see
[LICENSE](LICENSE).

Bundled third-party assets keep their own:

- **Instrument Sans** (`Sources/UsageBar/Resources/Fonts/InstrumentSans.ttf`) —
  © 2022 The Instrument Sans Project Authors, under the
  [SIL Open Font License 1.1](https://openfontlicense.org). The license ships
  alongside the font
  ([`Fonts/OFL.txt`](Sources/UsageBar/Resources/Fonts/OFL.txt)), as the OFL
  requires: if you redistribute the app or the repo, keep that file next to the
  `.ttf`.
- **Hugeicons** (`chat-gpt.svg`, `claude.svg`, `cursor.svg`) — icons from the
  free set, MIT licensed, no attribution required.

The ChatGPT/OpenAI, Claude/Anthropic and Cursor logos remain the property of
their respective owners; they are used here to identify the services being
queried, not to imply any affiliation. This project is affiliated with neither
OpenAI, Anthropic nor Cursor.
