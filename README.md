# Claude Usage

A macOS menu bar app showing Claude Code's 5-hour and weekly limits, refreshed
every minute.

```
64% · 16%
```

Click for the detail panel: each limit with a meter and reset countdown, extra
usage credits, a launch-at-login toggle, and Quit.

Bars and menu bar numbers turn amber at 75% and red at 90%.

## Build

```sh
./build.sh --install    # builds, installs to /Applications, launches
./build.sh              # builds to build/ClaudeUsage.app only
swift test              # 29 tests
```

There is no keychain prompt. The app reads Claude Code's item through
`/usr/bin/security`, which Claude Code itself uses to write the item, so the
item's ACL always trusts it. Reading it directly with `SecItemCopyMatching`
relied on a per-binary "Always Allow" grant, and Claude Code drops that grant
every time it renews its token, so macOS asked for the login password every few
hours.

## Diagnostics

```sh
/Applications/ClaudeUsage.app/Contents/MacOS/ClaudeUsage --probe
/Applications/ClaudeUsage.app/Contents/MacOS/ClaudeUsage --login-status
```

`--probe` runs the whole data path — keychain, token, HTTP, decode — and prints
the values, so the app can be checked without the GUI in the way.

## Sign-in and credential handling

Click **Sign In…** in the panel (or run `ClaudeUsage --sign-in`) once. It opens
claude.ai in the browser and gives the app **its own** login, using the same
request DSH makes (narrower scope sets are rejected by the sign-in page). The
token is only ever sent to the usage endpoint. The app keeps that login in its own keychain item
(`com.claudeusage.oauth`) and renews it on its own, so it never needs Claude
Code opened. DSH's subscription plugin works the same way.

Until you sign in, the app borrows Claude Code's token read-only. When that
token expires, the app asks you to sign in.

**The app never renews Claude Code's login.** Refresh tokens are single-use:
renewing Claude Code's invalidates the copy a running Claude Code holds, which
once logged Claude Code out into a `/login` loop that only deleting the keychain
item fixed. The app doesn't even read Claude Code's refresh token, so it has
nothing to renew it with. `Tests/ClaudeUsageCoreTests/ReadOnlyGuardTests.swift`
fails if Claude Code's item is written, its refresh token is read, or any token
exchange appears outside `ClaudeOAuth.swift`.

## Layout

| Path | Role |
| --- | --- |
| `Sources/ClaudeUsageCore/Credentials.swift` | Reads Claude Code's access token; no write path |
| `Sources/ClaudeUsageCore/AppGrant.swift` | The app's own login and its keychain item |
| `Sources/ClaudeUsageCore/ClaudeOAuth.swift` | Token exchange and renewal for the app's own login |
| `Sources/ClaudeUsageCore/SignIn.swift` | Browser sign-in with a localhost callback |
| `Sources/ClaudeUsageCore/TokenProvider.swift` | Own login first, borrowed token as fallback |
| `Sources/ClaudeUsageCore/UsageClient.swift` | Calls `/api/oauth/usage`, parses the payload |
| `Sources/ClaudeUsageCore/Formatting.swift` | Percentages, countdowns, severity thresholds |
| `Sources/ClaudeUsage/UsageStore.swift` | 60s polling, wake-from-sleep, last-known values |
| `Sources/ClaudeUsage/StatusItemController.swift` | Menu bar title and popover |
| `Sources/ClaudeUsage/UsagePanel.swift` | The detail panel |
