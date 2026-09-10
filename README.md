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
swift test              # 22 tests
```

The first launch asks for keychain access. Choose **Always Allow**.

## Diagnostics

```sh
/Applications/ClaudeUsage.app/Contents/MacOS/ClaudeUsage --probe
/Applications/ClaudeUsage.app/Contents/MacOS/ClaudeUsage --login-status
```

`--probe` runs the whole data path — keychain, token, HTTP, decode — and prints
the values, so the app can be checked without the GUI in the way.

## Credential handling

**This app reads Claude Code's keychain item and never writes it.**

That rule exists because violating it broke a real login. OAuth refresh tokens
here are single-use: refreshing the shared grant invalidates the token a running
Claude Code holds in memory, which logs the user out into a `/login` loop that
only deleting the keychain item clears. It is not a race that tighter locking
would fix — rotation invalidates another process's live copy by design.

So when the token has expired, the app shells out to `claude auth status` and
re-reads the keychain. Claude Code owns the grant, so Claude Code renews it.
That command makes no inference request and consumes no usage.

`Tests/ClaudeUsageCoreTests/ReadOnlyGuardTests.swift` fails the build if
`SecItemUpdate`, `SecItemAdd`, `SecItemDelete`, `grant_type`, or `refresh_token`
appears anywhere under `Sources/`.

A token from `claude setup-token` cannot be used instead: it carries only
`user:inference`, and `/api/oauth/usage` requires `user:profile`.

## Layout

| Path | Role |
| --- | --- |
| `Sources/ClaudeUsageCore/Credentials.swift` | Reads the keychain item; no write path |
| `Sources/ClaudeUsageCore/CredentialRenewer.swift` | Delegates renewal to the Claude Code CLI |
| `Sources/ClaudeUsageCore/TokenProvider.swift` | Serves a valid token, renewing via the CLI |
| `Sources/ClaudeUsageCore/UsageClient.swift` | Calls `/api/oauth/usage`, parses the payload |
| `Sources/ClaudeUsageCore/Formatting.swift` | Percentages, countdowns, severity thresholds |
| `Sources/ClaudeUsage/UsageStore.swift` | 60s polling, wake-from-sleep, last-known values |
| `Sources/ClaudeUsage/StatusItemController.swift` | Menu bar title and popover |
| `Sources/ClaudeUsage/UsagePanel.swift` | The detail panel |
