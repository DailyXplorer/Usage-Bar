# Product decisions

Rules Usage Bar follows. Change one only together with the code and tests that
implement it.

## D1 Every Claude window is optional

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

## D2 Claude menu bar value

The Claude segment shows the first available of: the `limits[]` entry with
`is_active == true`; the session window; the weekly all-models window; the most
used model-scoped weekly window. It is shown as percent remaining, like every
other provider, with no extra marker in the menu bar image. The accessibility
label names the window ("Claude weekly limit, 25 percent left").

## D3 Claude data sources

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

## D4 Claude 429 pause

A 429 on the usage endpoint pauses it until `Retry-After` when that is greater
than zero, otherwise for 5, 15, 30, then 60 minutes on consecutive 429s. Any
pause is capped at 60 minutes. The pause is stored per account (a hash of the
account id, never a token) and survives relaunch; the refresh button does not
bypass it. While paused, the Claude section keeps the last values and says
"Anthropic paused usage updates. Showing values from ‹time›. Next try at
‹time›." The backoff resets on the next success.

## D5 Claude plan name

From `GET /api/oauth/profile` → `organization.plan_display_name` (for example
"Ultra", shown as "Claude Ultra"), requested with Claude Code's profile request
shape and cached for 24 hours. Otherwise the label derived from the sign-in's
`subscriptionType` and `rateLimitTier`. When Claude Code's saved copy or the
quota check supplies the usage, the stored profile name for that account is
used without a profile request; without one, the sign-in is read (never
renewed) for its label.

## D6 Claude usage credits

"Usage credits" (`extra_usage`, when `is_enabled`: spent / monthly limit in the
account currency, amounts in minor units) and the credit windows `cinder_cove`
and `wattle_ember` appear as rows in the Claude section when present. They never
drive the menu bar.

## D7 Claude token renewal

Usage Bar renews an expired Claude Code token the way Claude Code does, with
these guarantees: a single in-flight renewal whose network call and atomic
write-back cannot be cancelled by a caller; the stored credential is re-read
just before writing and a newer token written by Claude Code wins; every unknown
field (for example `mcpOAuth`) is preserved; rotated tokens are never lost when
a verification read fails; a 401 triggers one renewal and one retry.

## D8 Popover and menu bar settings

Each provider has two settings: "Popover" (the provider is fetched and has a
section) and "Menu bar" (a subset of the popover providers). Hiding a provider
from the menu bar does not stop fetching it. Migration from the old
`menuBarProviders` key: the menu bar set is the old set; the popover set is the
old set plus every provider whose credential is detected. A provider shown in
the popover without a usable credential shows one short line saying how to sign
in instead of disappearing.

## D9 Refresh cadence

Codex every 3 minutes; Claude per D3; Cursor, OpenCode Go and Command Code every
5 minutes. After wake or a network change, fetching waits until the network path
is satisfied, and a network error in the first seconds after wake is never
shown. The popover footer states the last update time ("Updated 2 min ago"),
not a fixed interval.

## D10 Server pauses expire

Every server-requested pause (`Retry-After` or backoff, any provider) is capped
at 60 minutes and expires; nothing can block a provider forever, including a
pause restored from an earlier run.

## D11 Reset windows

A window whose reset time has passed since its data was fetched is shown as
reset (full remaining, "Reset, waiting for new data") until new data arrives. It
never shows the old percentage or "Limit reached" after its reset.

## D12 ⌘Q in the popover

⌘Q while the popover panel is the key window closes the panel instead of
quitting. Quitting stays available from the Quit button and from ⌘Q in other
windows.

## D13 Plain error text

Error text says what happened and what to do, with no HTTP codes, URLs or
exception text.

## D14 Codex usage

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

## D19 Update checks

The GitHub update check runs at most every 6 hours when the popover opens, plus
the daily check at launch. A failing automatic install backs off per version
instead of downloading again on every open. The relaunch helper verifies the
new process started and retries once.
