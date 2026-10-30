# Platform adapter integration

Construct live adapters with the application's `AppPaths`. Construction performs no OS action.
Live throwing entry points refuse tests and sandbox mode through `SafetyTripwire`. The two
nonthrowing protocols instead finish the launch stream or return unknown task activity when
refused. No notification adapter is provided in v1.

`runningInstances()` fails closed if a matched main process has unreadable or malformed argv.
Launch monitors skip such a record and log a fixed message without its arguments. Explicit
default-profile launches retain `hasExplicitProfileFlag == true`.

## Sandbox assembly

Copy the built `FakeClaude` executable into the sandbox (its basename must stay `FakeClaude`)
and inject that copy's URL into both the controller and monitor. Profile directories must also
be inside the sandbox. Internal symlinks are refused, including dangling links. Observation
starts when `launches()` is called; each subscription includes currently visible instances once.
Cancel the consumer task to stop monitoring. Children launched by the controller are retained
until they exit; callers should invoke `quitAll` when shutting down the sandbox app.

The scripted adapters use the following files, all relative to the injected sandbox root:

| File | Format |
| --- | --- |
| `task-state.json` | `{"status":"idle"}`, `{"status":"unknown"}`, or `{"status":"busy","tasks":[{"pid":42,"sessionId":"fixture-session","cwd":"/sandbox/project","shellChild":43}]}`. Task metadata and `shellChild` are optional. Missing/corrupt state returns unknown. |
| `fixtures/http/api/account.json` | Raw response body for `/api/account`. Other request paths use the same nested path plus `.json`; `/` uses `index.json`. Query strings are ignored. Missing fixtures return 404. |
| `home/Library/LaunchAgents/local.cc-relay.plist` | Generated XML login item of the sandbox. Enabling/disabling only changes this file. |

The task inspector accepts an alternate `stateFile` within the sandbox.
`SandboxSessionCookieReader` reads the injected sandbox profile's SQLite database and returns
the encrypted bytes, optional plaintext column, host, and database version. It does not decrypt.
`FixedSafeStorageKeyProvider` takes explicitly injected fixture bytes.

Assembly seeds the script files and HTTP fixtures above when it uses `SandboxFixture`.

FakeClaude needs a profile directory: `--user-data-dir`, or, for a launch without that flag (a
stand-in for opening Claude from the Dock), the directory in `FAKE_CLAUDE_DEFAULT_PROFILE`. The
external-launch monitor test instead places the flag after `--`, so the production argv parser
sees no effective profile flag while the stand-in still writes only to a temporary directory.

## Checks that need the real applications

- Verify NSWorkspace opens a distinct Claude main process with the explicit profile argument,
  delivers a continuity URL to that instance, and falls back to plain launch on a URL-open error.
- Verify NSWorkspace launch notifications arrive with readable argv for Dock/Spotlight/updater
  launches and retain the explicit-flag distinction.
- Verify Claude's normal AppKit quit runs its cleanup, followed by the SIGTERM and force stages
  only if needed. Budgets cap the 20/5/3-second stage limits and polling is every 250 ms.
- Verify the CLI registry, cookie/meta schema, keychain permission/failure behavior, and installed
  Claude/Electron Info.plist versions against the real applications.
- Verify Finder accepts a reveal request, that `SMAppService.mainApp` registers the installed app
  (System Settings lists it under Login Items) and opens it at the next login, and that the
  fallback plist is consumed at next login when the service refuses the app.
  No adapter loads or unloads a launchd job.
- Verify production URLSession/TLS behavior only in a separately authorized runtime check.
  Automated transport tests use a local URLProtocol exclusively and perform no network IO.
