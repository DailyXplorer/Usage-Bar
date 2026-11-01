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
   is kept in memory only, dropped when it no longer decrypts, and a refused
   read is not retried for an hour.
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
- `whoami?limits=1` runs on every refresh, and each `orgLimits` entry becomes a
  spend-limit row (`$spent of $limit` with its interval). The 5-hour and weekly
  windows are hidden when `windowLimits.limited` is false; the monthly pool
  still shows.
