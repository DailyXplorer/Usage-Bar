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
from their kind or group. Labels follow Claude Code's `/usage` wording in the
app's Title Case: "Current Session", "Current Week (All Models)", "Current Week
(‹model display name›)". A name the server provides, such as a model display
name, keeps its own spelling inside the label.
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
   most every 15 minutes, including after a network error that may have
   reached Anthropic (a timeout); only a request that never left the Mac
   (no connection, host not found) is retried sooner. Opening the popover
   refetches only when the data is older than 5 minutes and the last call was
   at least 60 seconds ago. The refresh button follows the same 60-second
   floor.
3. Optional, off by default (Settings → Claude): while source 2 is paused by a
   429, at most once every 15 minutes, the quota check Claude Code itself sends
   (Haiku 4.5, `max_tokens: 1`, user text "quota"). Usage Bar reads the
   `anthropic-ratelimit-unified-*` headers (also on a 429 or `rejected`
   response) and normalises 0–1 utilisation and unix-second resets to the usage
   endpoint's model. Rows the headers cannot provide keep their last values.

### D4 Claude 429 pause

A 429 (or a 403 without an error envelope, D22) on the usage endpoint pauses it until `Retry-After` when that is greater
than zero, otherwise for 5, 15, 30, then 60 minutes on consecutive 429s. Any
pause is capped at 60 minutes. The pause is stored per account (a hash of the
account id from `~/.claude.json`, or of the sign-in's refresh token when no
account id is known; never the token itself) and survives relaunch; the
refresh button does not bypass it. While paused, the Claude section keeps the
last values and says "Anthropic paused usage updates. Showing values from
‹time›. Next try at ‹time›." Times are a short clock time in the system's 12-
or 24-hour format, with "tomorrow", "yesterday" or a short weekday when the
time is not today. The backoff resets on the next success.

### D5 Claude plan name

From `GET /api/oauth/profile` → `organization.plan_display_name` (for example
"Ultra", shown as "Ultra"; see D5b), requested with Claude Code's profile request
shape. D23 says when it is requested. Otherwise the label derived from the
sign-in's `subscriptionType` and `rateLimitTier`: `max` with the 20x tier is
"Ultra", the 5x tier is "Max 5x", any other plan keeps its own name. A raw key
such as `max_20x` is never shown. When Claude Code's saved copy supplies the
usage, the stored profile name for that account is used without a profile
request; without one, the sign-in is read (never renewed) for its label.

### D6 Claude usage credits

"Usage Credits" (`extra_usage`, when `is_enabled`: spent / monthly limit in the
account currency, amounts in minor units) and the credit windows `cinder_cove`
and `wattle_ember` appear as rows in the Claude section when present. They never
drive the menu bar. Their amounts read "$12.50 / $50.00 spent", the one format
every money row uses for every provider.

### D7 Claude token renewal

Usage Bar renews an expired Claude Code token the way Claude Code does, with
these guarantees: a single in-flight renewal whose network call and atomic
write-back cannot be cancelled by a caller; the stored credential is re-read
just before writing and a newer token written by Claude Code wins; every unknown
field (for example `mcpOAuth`) is preserved; rotated tokens are never lost when
a verification read fails; a 401 triggers one renewal and one retry.

### D22 Claude 403 on the usage endpoint

A 403 is classified the way Claude Code classifies it. When the body carries an
Anthropic error envelope (`{"error":{"type":…}}`), it is an auth rejection: the
section says "This Claude Code sign-in cannot read usage (‹error type›). Run
claude in Terminal, then /login." and nothing is paused. The error type is shown
only when it is a plain lowercase identifier. Any other 403 is a throttle,
handled exactly like a 429 (D4, D10): it pauses until `Retry-After` when that is
greater than zero, otherwise for 5, 15, 30, then 60 minutes; the attempt counter
advances with every throttle of either kind and resets on the next success; the
section shows the throttle text of D4. The "/login" hint appears only for an
auth rejection.

### D23 Claude plan refresh

The profile request (D5) is sent at most once every 24 hours whenever a usable
Claude token is available, whatever the usage call returned: after a 200, a
throttle, a server error or an undecodable reply, and also while the usage
endpoint is paused. The result is stored per account and survives a restart. It
is not sent while an auth rejection (a 401 after renewal, or a 403 with an error
envelope) is the usage call's answer, with an expired token, or when the usage
request never reached Anthropic. After a failed profile request the next try
comes an hour later. A profile failure is never shown to the user.

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
not a fixed interval. A provider section adds its own freshness line only when
it tells more than the footer: its data is older than twice its refresh
interval or its last attempt failed ("Saved data from …"), it has only saved
data with no successful refresh yet, or it is paused (the pause line). While
every provider is fresh, only the footer states the time.

### D10 Server pauses expire

Every server-requested pause (`Retry-After` or backoff, any provider) is capped
at 60 minutes and expires; nothing can block a provider forever, including a
pause restored from an earlier run.

### D10b Rejected responses are logged

Every non-2xx answer to a usage or profile request of any provider is logged
through `os.Logger` (subsystem: the bundle id, category: the provider) as one
line with the provider, the endpoint name, the HTTP status, Anthropic's error
type when the body has one, and `Retry-After` when present, all marked public.
Nothing else is logged: no token, key, account or organization id, email, body
text or usage value. The error type and `Retry-After` pass a strict pattern
before they are written.

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

### D5b Plan badges name the plan only

Every provider's plan badge shows the plan name and never the provider brand:
"Ultra" (the former Max 20x), "Max 5x", "Pro", "Plus", "Team", "Enterprise", "Go";
never "Claude Ultra" or "Cursor Pro". The provider icon beside the badge
already names the service. A leading brand word in a server or sign-in value
("Claude ", "Cursor ", "ChatGPT ", "Codex ", "OpenCode ", "Command Code ") is
dropped when a plan name remains after it. A plan whose own name contains a
brand, such as "SuperGrok", stays as written.

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

- Unified account (`isUnified == true`): one **Weekly Usage** bar from
  `usagePercent`, reset at `nextResetTimestampUtc`, with `cursorPlanName` as
  the plan badge. This bar is the Cursor value in the menu bar. **Cursor
  Models**, **Other Models** and a separate **Grok Bot** bar are not shown.
  When `GetCurrentPeriodUsage.spendLimitUsage.individualLimit` is above zero,
  an **Additional Usage** row shows `individualUsed / individualLimit` in
  dollars ("$12.00 / $50.00 spent"), reset at the end of the billing cycle. A pooled Enterprise
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
3. A **Cursor session token** pasted in Settings: the `WorkosCursorSessionToken`
   cookie of cursor.com, whose value is `<user id>%3A%3A<access token>` (or
   `::` once decoded). The field accepts the raw access token, `Bearer <token>`,
   the cookie value with either separator, the `name=value` pair, or a whole
   `Cookie:` header line, trims whitespace, and keeps only the access token.
   Anything that is not a three-part token with a readable expiry is refused
   with a short message, and so is a token that expires within a minute; a
   Cursor API key, an encrypted editor value or another cookie is refused
   rather than exchanged. The token is stored in Usage Bar's own Keychain item
   and never shown again. The cookie's token is the editor's access token
   wrapped with the user id, which the editor sends as `Bearer` to the same
   endpoints; no client is seen sending the cookie's token itself to
   `api2.cursor.sh`, so that last step rests on this shared shape.

A failed Grok Bot status call (client error or refused token) falls back to
the legacy layout; a server error keeps the last values. Usage Bar never
renews a Cursor or Grok token. A token whose JWT `exp` has
passed is skipped without a request. File and Keychain reads run off the main
thread with a timeout. When no source works, the section explains how to sign
in.

### D17 OpenCode Go key

The `opencode-go` key comes from OpenCode's `opencode.db` first (table
`credential`, active row first, then the newest), opened through SQLite's
read-only mode so WAL content is honoured and no row is written (SQLite may
still create its `-shm` index next to the file). When that open fails and no
`-wal`, `-shm` or `-journal` file exists, the file is opened as immutable.
Every read has a deadline. The legacy `auth.json` is the fallback. The popover does not print plan prices:
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
  spend-limit row ("$5.50 / $20.00 spent this month", the period taken from its
  interval). The 5-hour and weekly
  windows are hidden when `windowLimits.limited` is false; the monthly pool
  still shows.

### D24 Signed-out OpenCode Go and Command Code

- Two consecutive 401s on the same saved key mean the provider is signed out.
  A 401 on a different key starts the count again, and any success clears it.
  The key is compared through a short SHA-256 fingerprint, which is the only
  thing stored; the key itself is never persisted.
- The signed-out provider drops its values, its plan and its persisted
  snapshot rows, and its section shows one line: "Signed out of OpenCode Go:
  the saved key no longer works. Run /connect in OpenCode, or hide OpenCode Go
  in Settings." (Command Code: "Run cmd login in Terminal"). Its menu bar
  segment shows `--%`, as Cursor does when signed out.
- While signed out, the saved key is sent to the provider at most once an
  hour. The normal 5-minute cycle still reads the credential locally, so a new
  key is tried at once. The provider returns to normal as soon as a request
  succeeds.
- The state survives a restart.

## Notifications and pace

### D20 Threshold notifications

- Usage Bar posts macOS notifications through `UNUserNotificationCenter`,
  behind the `UsageNotifying` protocol. Settings → Notifications holds
  **Notify when a limit runs low** (default on) with **Warn at** 50%, 30%, 20%
  (default) or 10% left, and **Notify when a limit resets** (default on).
- A low warning is sent when a window's percentage left is at or below the
  chosen threshold. A second notification is sent when the limit is reached
  (0% left or the provider's limit-reached status). Both follow the first
  switch.
- A reset notification is sent only for a window that warned or reached its
  limit in the period that ended, when fresh data shows the next period. A
  window that comes back idle after its period ended (0% used, no reset time)
  also counts as reset.
- Covered: every time window with a percentage and a reset time of a provider
  shown in the popover (D8): sessions, weeklies, model-scoped weeklies, Codex
  primary, secondary and additional windows, Cursor weekly, OpenCode Go and
  Command Code windows. Credit, balance and spend-limit rows never notify
  (Cursor's additional usage and Command Code org limits are spend limits).
- One notification per window, threshold and reset period. The record is kept
  in `UserDefaults` across relaunches and dropped once its period has passed.
  A window is identified by provider, row and length class (5 hours, day,
  week, calendar month of 28 to 31 days, year), never the exact length, so a
  billing cycle of another length is still the same window.
  A reset time that drifts by less than 30 minutes is the same period. Lowering
  the threshold can warn again at the new one; raising it does not repeat a
  warning.
- Only fresh data notifies: never saved data from launch, a reply that carried
  no usage, data older than
  twice its refresh interval, a failed read, a paused provider, or a window
  in the D11 "reset, waiting for new data" state.
- Text: provider, window, what happened, reset time. For example "Claude
  weekly limit: 20% left" / "Resets Tue at 14:00.", "Codex 5-hour limit
  reached" / "Resets at 15:30.", "Claude weekly limit has reset".
- Permission is requested when the first notification is due, or when the
  user turns a switch on. If macOS denies it, Settings shows one line saying
  notifications are off for Usage Bar in System Settings, with a button that
  opens that pane. Clicking a notification opens the popover.

### D21 Pace forecast

- For a time window with a known length and reset time, past the first 5% of
  the window and at 3% used or more, usage is projected linearly to the reset.
- Only when the projection exceeds 100% does the row show "Runs out in
  ~<duration> at this pace" in the warning colour, at the trailing edge of its
  "% Left" line under the reset time. Otherwise nothing extra shows.
- Window length comes from the data (Codex `limit_window_seconds`, a period
  start and end where given) or the documented fixed lengths (5-hour session,
  7-day week, 30-day month). Unknown length means no forecast. Reached limits
  and credit or spend rows never forecast.
- Popover only; the menu bar is unchanged. No new badges, ticks or rows.
