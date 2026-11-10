# Claude Usage

A macOS menu bar app showing Claude's 5-hour and weekly limits for one or more
accounts, refreshed every two minutes.

```
64% · 16%
```

Click for the detail panel: each limit with a meter and reset countdown, extra
usage credits, and a launch-at-login toggle. Right-click for **Add Account…**,
**Remove** for each account, and **Quit** (⌘Q).

Bars and menu bar numbers turn amber at 75% and red at 90%.

## Build

```sh
./build.sh --install    # builds, installs to /Applications, launches
./build.sh              # builds to build/ClaudeUsage.app only
swift test
```

There is no keychain prompt: every keychain access goes through
`/usr/bin/security`, which the app's items trust.

## Diagnostics

```sh
/Applications/ClaudeUsage.app/Contents/MacOS/ClaudeUsage --probe
/Applications/ClaudeUsage.app/Contents/MacOS/ClaudeUsage --login-status
```

`--probe` runs the whole data path (keychain, tokens, HTTP, decode) for every
account and prints the values, so the app can be checked without the GUI.

## Accounts

Click **Sign In…** in the panel (or run `ClaudeUsage --sign-in`). It opens
claude.ai in the browser and gives the app its own login, independent of Claude
Code, which it renews by itself. To sign in another account, right-click the
menu bar item and choose **Add Account…**: switch accounts in the browser first,
or sign-in just renews the one already listed. To renew an expired account, add
it again.

With one account the panel looks as before. With two or more, the menu bar shows
them combined and the panel lists **All accounts** first, then each account's
own limits. Combined means one pool: each window's percentage is the average of
the accounts' percentages, and it resets when the soonest account resets.

A Claude sign-in lasts about 30 days no matter how often it renews. When one
runs out, only that account shows a sign-in error, and the others keep updating.
`--probe` prints each sign-in's end date.

Each account is a keychain item under the `com.claudeusage.oauth` service, keyed
by email. The app never reads or renews Claude Code's login.
`Tests/ClaudeUsageCoreTests/ReadOnlyGuardTests.swift` fails if a source file
names Claude Code's item or any token exchange appears outside `ClaudeOAuth.swift`.

## Layout

| Path | Role |
| --- | --- |
| `Sources/ClaudeUsageCore/AppGrant.swift` | Accounts, their grants, and their keychain items |
| `Sources/ClaudeUsageCore/ClaudeOAuth.swift` | Token exchange and renewal for the app's own login |
| `Sources/ClaudeUsageCore/SignIn.swift` | Browser sign-in with a localhost callback |
| `Sources/ClaudeUsageCore/TokenProvider.swift` | Per-account tokens and renewal |
| `Sources/ClaudeUsageCore/UsageClient.swift` | Calls `/api/oauth/usage` for each account, parses the payload |
| `Sources/ClaudeUsageCore/CombinedUsage.swift` | Pools several accounts into one snapshot |
| `Sources/ClaudeUsageCore/Formatting.swift` | Percentages, countdowns, severity thresholds |
| `Sources/ClaudeUsage/UsageStore.swift` | 60s polling, wake-from-sleep, last-known values |
| `Sources/ClaudeUsage/StatusItemController.swift` | Menu bar title and popover |
| `Sources/ClaudeUsage/UsagePanel.swift` | The detail panel |
