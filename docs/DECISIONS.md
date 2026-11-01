# Product decisions

Rules Usage Bar follows. Change one only together with the code and tests that
implement it.

## Claude

### D1 Every Claude window is optional

Verified Ultra accounts (the former Max 20x) have no 5-hour session window;
unverified Ultra accounts and other plans may have one. Usage Bar never invents
a session row and shows an error only when the response holds no window at all
("Claude returned no limits."). `limits[]` is the primary list. The legacy keys
`five_hour`, `seven_day`, `seven_day_opus`, `seven_day_sonnet`,
`seven_day_oauth_apps` and `seven_day_cowork` are the fallback when `limits`
gives no usable entry. Unknown `kind` values are kept and get a readable label
from their kind or group. Labels follow Claude Code's `/usage`: "Current
session", "Current week (all models)", "Current week (‹model display name›)".
Decoding is lenient: a malformed entry drops only that entry.

### D2 Claude menu bar value

The Claude segment shows the first available of: the `limits[]` entry with
`is_active == true`; the session window; the weekly all-models window; the most
used model-scoped weekly window. It is shown as percent remaining, like every
other provider, with no extra marker in the menu bar image. The accessibility
label names the window ("Claude weekly limit, 25 percent left").

### D3 Claude data sources

In this order:

1. Claude Code's own saved copy: `~/.claude.json` → `cachedUsageUtilization`
   (`fetchedAtMs`, `accountUuid`, `utilization`). Used when it is at most one
   hour old, its account matches `oauthAccount.accountUuid` in the same file,
   and it is newer than Usage Bar's own data. No network request.
2. `GET https://api.anthropic.com/api/oauth/usage` with Claude Code's request
   shape (`User-Agent: claude-cli/‹version› (external, cli)` with a pinned
   recent version, `anthropic-beta: oauth-2025-04-20`, JSON `Accept` and
   `Content-Type`), through a session with no URL cache. Background refresh at
   most every 15 minutes. Opening the popover refetches only when the data is
   older than 5 minutes and the last call was at least 60 seconds ago. The
   refresh button follows the same 60-second floor.
3. Optional, off by default (Settings → Claude): while source 2 is paused by a
   429, at most once every 15 minutes, the quota check Claude Code itself sends
   (Haiku 4.5, `max_tokens: 1`, user text "quota"). Usage Bar reads the
   `anthropic-ratelimit-unified-*` headers (also on a 429 or `rejected`
   response) and normalises 0–1 utilisation and unix-second resets to the usage
   endpoint's model. Rows the headers cannot provide keep their last values.

### D4 Claude 429 pause

A 429 on the usage endpoint pauses it until `Retry-After` when that is greater
than zero, otherwise for 5, 15, 30, then 60 minutes on consecutive 429s. Any
pause is capped at 60 minutes. The pause is stored per account (a hash of the
account id, never a token) and survives relaunch; the refresh button does not
bypass it. While paused, the Claude section keeps the last values and says
"Anthropic paused usage updates. Showing values from ‹time›. Next try at
‹time›." The backoff resets on the next success.

### D5 Claude plan name

From `GET /api/oauth/profile` → `organization.plan_display_name` (for example
"Ultra", shown as "Claude Ultra"), requested with Claude Code's profile request
shape and cached for 24 hours. Otherwise the label derived from the sign-in's
`subscriptionType` and `rateLimitTier`. When Claude Code's saved copy or the
quota check supplies the usage, the stored profile name for that account is
used without a profile request; without one, the sign-in is read (never
renewed) for its label.

### D6 Claude usage credits

"Usage credits" (`extra_usage`, when `is_enabled`: spent / monthly limit in the
account currency, amounts in minor units) and the credit windows `cinder_cove`
and `wattle_ember` appear as rows in the Claude section when present. They never
drive the menu bar.

### D7 Claude token renewal

Usage Bar renews an expired Claude Code token the way Claude Code does, with
these guarantees: a single in-flight renewal whose network call and atomic
write-back cannot be cancelled by a caller; the stored credential is re-read
just before writing and a newer token written by Claude Code wins; every unknown
field (for example `mcpOAuth`) is preserved; rotated tokens are never lost when
a verification read fails; a 401 triggers one renewal and one retry.

## All providers

### D8 Popover and menu bar settings

Each provider has two settings: "Popover" (the provider is fetched and has a
section) and "Menu bar" (a subset of the popover providers). Hiding a provider
from the menu bar does not stop fetching it. Migration from the old
`menuBarProviders` key: the menu bar set is the old set; the popover set is the
old set plus every provider whose credential is detected. A provider shown in
the popover without a usable credential shows one short line saying how to sign
in instead of disappearing.

### D9 Refresh cadence

Codex every 3 minutes; Claude per D3; Cursor, OpenCode Go and Command Code every
5 minutes. After wake or a network change, fetching waits until the network path
is satisfied, and a network error in the first seconds after wake is never
shown. The popover footer states the last update time ("Updated 2 min ago"),
not a fixed interval.

### D10 Server pauses expire

Every server-requested pause (`Retry-After` or backoff, any provider) is capped
at 60 minutes and expires; nothing can block a provider forever, including a
pause restored from an earlier run.

### D11 Reset windows

A window whose reset time has passed since its data was fetched is shown as
reset (full remaining, "Reset, waiting for new data") until new data arrives. It
never shows the old percentage or "Limit reached" after its reset.

### D12 ⌘Q in the popover

⌘Q while the popover panel is the key window closes the panel instead of
quitting. Quitting stays available from the Quit button and from ⌘Q in other
windows.

### D13 Plain error text

Error text says what happened and what to do, with no HTTP codes, URLs or
exception text.

## Codex

### D14 Codex usage

`rate_limit_reached_type` is decoded as an object (`{type}`), leniently, and
never fails the section. `credits` shows as a "Credits" row (the balance when
`has_credits`, "Unlimited" when `unlimited`), `spend_control` as "Monthly Credit
Limit", and every `additional_rate_limits[]` entry as its own row named from
`limit_name`. There is no dedicated Spark row; a Spark limit returned by the
server appears like any other additional limit. Usage Bar never sends
`x-openai-codex-luna-reserve`. The menu bar shows the more constrained (lowest
remaining) of the primary and secondary windows. Usage Bar does not renew the
Codex token: when the access token's JWT `exp` has passed, the section says
"Codex sign-in expired. Open Codex to renew it." without calling the server.

## Updater

### D19 Update checks

The GitHub update check runs at most every 6 hours when the popover opens, plus
the daily check at launch. A failing automatic install backs off per version
instead of downloading again on every open. The relaunch helper verifies the
new process started and retries once.

## Cursor, Grok, OpenCode Go, Command Code

### D15 Cursor and Grok accounts

Cursor and Grok accounts can be combined into one plan (The X Subscription).
`GetSandUsageStatus.isUnified` tells the two account shapes apart.

- Unified account (`isUnified == true`): one **Weekly usage** bar from
  `usagePercent`, reset at `nextResetTimestampUtc`, with `cursorPlanName` as
  the plan badge. This bar is the Cursor value in the menu bar. **Cursor
  Models**, **Other Models** and a separate **Grok Bot** bar are not shown.
  When `GetCurrentPeriodUsage.spendLimitUsage.individualLimit` is above zero,
  an **Additional usage** row shows `individualUsed / individualLimit` in
  dollars, reset at the end of the billing cycle. A pooled Enterprise
  allowance or a missing percentage shows no weekly bar.
- Pending account merge (`unifyPendingMerge` present on an account that is not
  unified): the section says "Account merge in progress" instead of a 0 % bar.
- Legacy account: **Cursor Models** and **Other Models** stay. When
  `GetPlanInfo.planInfo.includedUsagePeriod` is weekly, their reset is
  `includedUsageResetsAt`; otherwise it is the billing-cycle end. A **Grok
  Bot** bar appears only when Sand reports a separate non-zero pool
  (`hasNonZeroIncludedLimit == true`, no zero or pooled allowance, a
  percentage present).
- Enum values are accepted in their long (`SAND_BILLING_BRAND_GROK`,
  `INCLUDED_USAGE_PERIOD_WEEKLY`) and short (`GROK`, `WEEKLY`) forms. Unknown
  values and extra fields never fail the section; out-of-range timestamps are
  dropped.
- The three RPCs run once per refresh. There is no separately polled Grok Bot
  endpoint.

### D16 Cursor sign-in sources

Tried in order; the first usable source wins:

1. The Cursor editor's saved sign-in (`state.vscdb`, key
   `cursorAuth/accessToken`), opened read-only. A plaintext value is used as
   is. A value prefixed `cursor-safe-storage:v1:` is Electron safeStorage data:
   base64, a `v10` header, AES-128-CBC with a 16-space IV and PKCS#7 padding,
   keyed by PBKDF2-HMAC-SHA1 (salt `saltysalt`, 1003 rounds, 16 bytes) of the
   **Cursor Safe Storage** Keychain password (account `Cursor`). Usage Bar
   reads that item itself, not through `/usr/bin/security`, so an "Always
   Allow" covers only Usage Bar. The read may ask the user once; the password
   is kept in memory only. A refused read, or a password that no longer
   decrypts the login, waits an hour before the next Keychain read, so a user
   who chose "Allow" sees at most one prompt per hour. A failed read of the
   Settings token waits the same hour instead of blocking until relaunch.
2. The Grok Bot app's sign-in is **not** read. Its `sandSealedFile` files
   belong to its local agent and use a second, app-specific AES-256-GCM layer
   whose key sits in the app's own secret store; its Cursor token store is an
   internal, multi-account format, and the app rotates the token itself.
   Reading it would mean depending on private internals for no gain over
   source 3.
3. A **Cursor session token** pasted in Settings (the `WorkosCursorSessionToken`
   cookie from cursor.com; the cookie's user prefix is stripped). It is stored
   in Usage Bar's own Keychain item and never shown again.

A failed Grok Bot status call (client error or refused token) falls back to
the legacy layout; a server error keeps the last values. Usage Bar never
renews a Cursor or Grok token. A token whose JWT `exp` has
passed is skipped without a request. File and Keychain reads run off the main
thread with a timeout. When no source works, the section explains how to sign
in.

### D17 OpenCode Go key

The `opencode-go` key comes from OpenCode's `opencode.db` first (table
`credential`, active row first, then the newest), opened read-only through
SQLite's read-only mode so WAL content is honoured and nothing is written. The
legacy `auth.json` is the fallback. The popover does not print plan prices:
Go limits are per model and change over time.

### D18 Command Code numbers

- Spend this period comes from `usage/summary.totalCost`, with
  `totalMonthlyCredits` as a fallback.
- The monthly bar follows the official CLI: the pool is remaining monthly plus
  purchased plus free credits; the total is the plan's monthly credits (at
  least the remaining monthly credits) plus purchased and free credits when
  the subscription is active, otherwise spend plus pool.
- Plan names and credits follow the CLI table, matched by longest prefix: Go
  10, GOAT 70, Pro 30, Pro (v1) 80, Provider 15, Max 150, Ultra 300, Teams Pro
  40.
- No plan is hidden: Provider shows its 15-credit pool. An account with no
  rolling window, monthly pool or org limit keeps its section (per D8) and says
  that Command Code returned no limits.
- `whoami?limits=1` runs on every refresh, and each `orgLimits` entry becomes a
  spend-limit row (`$spent of $limit` with its interval). The 5-hour and weekly
  windows are hidden when `windowLimits.limited` is false; the monthly pool
  still shows.
