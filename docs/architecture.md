# CC-Relay — architecture (design contract)

The design contract: what each part of the app does and the rules it keeps.

## 1. Product in one paragraph

A menu-bar app. Click the icon: a 360 pt panel shows the current account as a large card and
every other account as a small card in a two-column grid, each with plan, subscription channel
and two quota bars (5-hour and weekly) with exact reset times. Click a card and Claude Desktop
restarts on that account — no confirmation, unless a Code task is still running. Conversations
follow you (two-way sync on switch) and the conversation you were in reopens. If Claude is
opened from the Dock on the default account while you chose another, the app puts it back.
Adding an account is: click "Add account", sign in, done.

The optional low-quota Code compaction is specified in `docs/low-quota-compaction.md`: a
Claude Code plugin watches each Desktop Code conversation's own usage and compacts it on its own
account before that account's limit, and before a switch moves a long conversation to another
account; CC-Relay writes the plugin's switch, asks before a switch and shows what it reports.
No simulated clicks or keystrokes are used.

The same plugin also continues native work after a switch. Core captures unfinished work from
the source profile's live conversations, and releases a request only after sync and launch
succeed and the target runtime is independently verified. The plugin continues the original
conversation and eligible agents, checks original Artifact watches, directly recreates verified
WebSocket Monitors and reattaches protected background commands to their original processes.
The main conversation then handles original output and subsequent work. See §9a and
[`native-work-continuity.md`](native-work-continuity.md).

## 2. Modules

| Target | Imports | Owns |
|---|---|---|
| `CompanionCore` | Foundation (+ CommonCrypto) | domain model, persistence, sync, backups, orchestration, quota parsing, formatting. Talks to the OS only through the protocols in §6. |
| `CompanionPlatform` | Core, AppKit, Darwin, SQLite3 | real adapters for §6 protocols, plus the sandbox adapters that drive `FakeClaude`. |
| `CompanionUI` | Core, SwiftUI, AppKit | theme, localization, view models, views, snapshot renderer. Never imports Platform. |
| `CCRelay` | all | `@main`, dependency wiring (live vs sandbox), app lifecycle. Thin. |
| `FakeClaude` | Foundation | stand-in Claude Desktop for sandbox mode and end-to-end tests. |
| `CompanionNativeWorker` | Core, Foundation, Darwin | bundled one-command executor, original process identity, private output, handoff and verified stop. Runs only commands enrolled by the native plugin. |

Dependency injection is by initializer. One `AppServices` value (built in the app target) holds
every service; views get view models, never services.

## 3. Environment and safety

- `AppPaths` (live / sandbox) is the only source of filesystem roots, including the Claude CLI
  home (`~/.claude`) and the Claude app bundle location. At launch the app looks for Claude in
  `/Applications/Claude.app`, then where Launch Services knows its bundle identifier
  (`ClaudeAppLocation`, which checks `CFBundleIdentifier` and never the name), and moves the bundle
  location there; with neither, the panel says so (`claudeNotFound`). No code builds a path from
  `NSHomeDirectory()` or `~` itself in the menu-bar application. The bundled native command
  worker uses its invoking plugin's HOME and an owner-only temporary execution root.
- `SafetyTripwire.assertLiveActionsAllowed()` is called at the top of every real adapter method
  that has an effect outside the app's own data dir (quit/launch Claude, write the login item,
  read the keychain, network). Tests run with `CC_RELAY_TEST=1`, so a test that reaches
  a real adapter fails loudly instead of acting.
- Sandbox mode (`CC_RELAY_SANDBOX=<dir>`) swaps every adapter for its sandbox twin:
  FakeClaude processes, fixture HTTP responses, a fixed fake keychain secret.
- `Clock` protocol (`now`, `sleep(for:)`) is injected everywhere time matters.

## 4. Domain model (Core)

- `ProfileFolder` — the directory name (`"Claude"`, `"Claude_Kxm2"`). `"Claude"` is the default
  profile. Identity of an account entry in our registry is the folder name.
- `AccountIdentity` — `accountUUID`, `activeOrganizationUUID?`, `knownOrganizationUUIDs`, plus
  `email?`, `plan?` filled from the network snapshot or caches (§7, §11).
- `ProfileStatus` — `.signedIn(AccountIdentity)` (a cached login: `lastKnownAccountUuid`
  present), `.awaitingSignIn` (no account and never had one), `.signedOut(lastAccountUUID?)`
  (no account now but session buckets exist, or the server rejected the sign-in cookie, or the
  cookie is gone),
  `.unreadable(reason)`.
- `ProfileSnapshot` — folder, URL, status, session buckets present, readable bucket, duplicate
  marker (another folder holds the same account UUID).
- `ManagedAccount` — `folder`, `displayName`, `addedAt`. Order in the registry = order in the UI
  (current account is always pulled out into the hero card).
- `Settings` — `autoSyncOnSwitch` (default true), `autoSwitchOnQuota` (default false, explicit opt-in), `autoCorrectDefaultLaunch` (always true: an
  earlier stored false is read as true, and nothing sets it), `autoCompactOnLowQuota` (default
  false: it works through the plugin, which turning it on installs), `launchAtLogin` (default false: the person turns it on), `language` (`.system` / `.zhHans` / `.en`), `appearance`
  (`.system` / `.light` / `.dark`; the panel window takes `aqua` / `darkAqua` or follows the system).
  Unknown enum values from a newer version read as `.system`.
- `QuotaSnapshot` — `folder`, `accountUUID`, `organizationUUID`, `plan`, `email`,
  `channel` (`.web`, `.appStore`, `.googlePlay`, `.unknown`), `fiveHour` and `sevenDay`
  (`usedPercent?`, `resetsAt?`), `fetchedAt`, `channelCheckedAt?`, `source`
  (`.network` / `.localHistory`). Never contains credentials.

## 5. Persistence (app data dir)

```
~/Library/Application Support/CC-Relay/
  state.json            registry + settings + in-flight records (schemaVersion, atomic writes)
  quota-cache.json      last successful QuotaSnapshot per folder (no secrets)
  quota-waits.json      waits claude.ai asked for that still stand, per folder and login
  Backups/<folder>/<YYYYMMDD-HHMMSS>[-n]/  session snapshots (§8)
  Backups/.trash/<YYYYMMDD>-<folder>-<YYYYMMDD-HHMMSS>[-n]/
  Archive/<folder>-<YYYYMMDD-HHMMSS>[-n]/   removed or merged-away profiles, moved whole
  AutoCompact/settings.json                 the compaction plugin's switch and language (§10)
  AutoCompact/sessions/<id>.json, results/[seen/]   reports: numbers and a failure's short reason
  AutoCompact/lock.json, test-request.json  the plugin's lease between conversations; a one-time test
  AutoCompact/switch-request.json, switch-result.json   compact one conversation before a switch; the answer
  NativeRecovery/active.json                current switch generation and target identity (§9a)
  NativeRecovery/requests/<cli-id>.json      work snapshot and one bound continuation request
  NativeRecovery/runtimes/<cli-id>/<instance-id>.json   plugin process reports, not identity authority
  NativeRecovery/results/<request-id>.json  durable claim, progress and execution evidence
  Logs/cc-relay.log (+ .1 .2, 1 MB each)
```

- Never create a file named `config.json` in this directory: profile scanners
  identify profiles by it, and this folder's name starts with "Claude".
- `state.json` fields: `schemaVersion`, `accounts: [ManagedAccount]`, `activeFolder`,
  `settings`, `pendingSignIns: [{folder, createdAt, returnToFolder, expectAccountUUID?}]`,
  `historyJobs: [HistoryJob]` (§10),
  `relaunchDebt: [folder]` (profiles we closed and still owe
  a relaunch, persisted *before* closing Claude), `knownUnmanagedFolders` (discovered profiles
  the user dismissed). Keys this version does not know are ignored and dropped on the next write.
- A corrupt `state.json` is copied aside as `state.corrupt-<stamp>.json` and treated as absent;
  the app never crashes on bad data.
- `StateStore` is an actor; every mutation is load → modify → atomic write.
- Native recovery records contain session/task IDs, source locations, process identities,
  status and short errors. The snapshot does not copy whole prompts or command bodies. Original
  transcripts remain in `~/.claude/projects/`; neither capture nor sync rewrites them.
- Protected commands additionally have a private one-time command specification, stdout/stderr,
  output cursor and ownership records under `/private/tmp/cc-relay-native-<uid>/<uuid>/<job-id>`.
  `NativeRecovery/commands/<job-id>/location.json` locates that directory. The worker inherits
  the source native shell sandbox and environment; no environment or account credential snapshot
  is persisted. Commands and output are private local task data. Temp cleanup is an explicit
  recovery failure and never authorizes re-executing an old command.

## 6. OS protocols (declared in Core, implemented in Platform)

```
ClaudeProcessControlling   runningInstances(), hasAnyProcess(), profilesInUse(), quitAll(timeout:beforeForce:), quit(instance:timeout:beforeForce:), launch(profile:deepLink:)
ClaudeLaunchMonitoring     AsyncStream of launches (pid, profile)
CodeTaskInspecting         activity() -> .idle | .busy([CodeTaskInfo]) | .unknown(reason)
NativeRuntimeInspecting    sessions(profile:), validate(report:profile:account:)
NativeConversationOpening open(profile:account:desktopSessionID:) into an already running instance
SafeStorageKeyProviding    password() async throws -> Data      (keychain via /usr/bin/security)
SessionCookieReading       sessionCookie(profile:) throws -> EncryptedCookie?   (read-only SQLite)
HTTPTransport              send(Request) async throws -> Response
LoginItemManaging          isEnabled, enable(executable:), disable()
FileRevealing              reveal(url) (Finder)
```

- `ClaudeInstance`: `pid`, `profileDirectory` (the default profile dir when no
  `--user-data-dir`), `startedAt`, `executableURL`. Main process only (helpers, crashpad and
  `Claude Helper*.app` processes never count, and never imply the default profile).
- argv is read with `sysctl KERN_PROCARGS2`, never by splitting `ps` output (paths have spaces).
  Both `--user-data-dir=<p>` and `--user-data-dir <p>` are understood.
- Real `quitAll`: snapshot the
  Desktop-owned process set first — main instances plus every descendant of a process whose
  executable lies inside the Claude bundle (helpers, crashpad, Desktop-hosted `claude` CLIs and
  their children), each identified by pid + start time + executable. For each main instance send
  a normal quit (`NSRunningApplication.terminate()`, so Desktop runs its own quit cleanup), poll
  every 250 ms for up to 20 s; then SIGTERM the remaining main PIDs and poll 5 s. Before any
  forced step call `beforeForce`; if nothing is left once it returns, the close succeeded;
  otherwise, if it returned false, stop without forcing. With `immediately` (the person chose
  "switch now", so Claude's own quit confirmation would only ask again) the normal quit, the
  SIGTERM and both waits are skipped and `beforeForce` comes first. Then force-terminate
  the exact survivors of the snapshot (mains first, then descendants) and poll 3 s. Success means
  no main instance and no surviving snapshot process remains. Rules: never signal a process that
  was not in the snapshot or whose identity changed; a main instance that appears during the
  close (someone reopened Claude) stops the close at once and is never touched; on failure the
  error lists only the profiles proven to have nothing left running (empty when that cannot be
  proven, e.g. a survivor that cannot be attributed to a profile).
- Real `launch`: `NSWorkspace` with `createsNewApplicationInstance = true` and
  `arguments = ["--user-data-dir=<absolute path>"]` — always explicit, also for the default
  profile, so a flagless launch can only come from someone else. A deep link
  (`claude://code/continue?session=<local_id>`, id validated as `local_` + 1–64 of
  `[A-Za-z0-9-]`) is passed as a URL in the same call so it reaches the new instance. If the
  link launch fails, fall back to a plain launch. Then poll `runningInstances()` every 250 ms for
  up to 30 s until a main instance with that profile exists; otherwise throw. Before throwing,
  the instance this open started (and only
  that one: a pid that was running before is never touched) gets a normal quit and, after 10 s,
  a forced one, followed by up to 3 s of exit confirmation. If it is still alive, return
  `launchCleanupFailed` and do not restore the previous account beside it.
- `hasAnyProcess()`: whether any live process from the Claude bundle is left, other than the
  detached crash reporter (`chrome_crashpad_handler`, parent launchd, no session, no task;
  `quitAll` still closes it). Helpers and the tasks under them can outlive a crashed main
  process, so an empty `runningInstances()` alone does not mean Claude is closed.
- `profilesInUse()`: the profiles those processes still use, attributed as a close attributes
  them (a main's flag or the default profile; a helper's own `--user-data-dir` or Crashpad
  `--database`, else its nearest main ancestor's), and `unattributed` when a live bundle process
  names none, such as a helper whose main is gone. Nothing is signalled. Removal checks it.
- Sandbox twins drive `FakeClaude` through `Process` and detect instances with the same argv
  reader, filtering on the FakeClaude executable path under the sandbox root.
- Core tests use in-memory fakes (`FakeProcessController`, `FakeTaskInspector`, …).
- `LiveNativeRuntimeInspector` independently binds a plugin report to an OS process and its
  owning Desktop profile. Two process snapshots and registry/argv reads must agree on the CLI
  PID, birth time, executable, parent chain, session ID and the Desktop main executable. The
  registry must name the Darwin PID domain and Desktop entry point; its `procStart` must match
  OS birth time. The Desktop ancestor's `--user-data-dir` must be the target, whose account and
  organization are checked through `ProfileConfigReader` before and after validation. A plugin
  report alone is never account evidence. Idle CLI sessions are enumerated too; a verified
  direct shell child also marks the source busy. PID reuse, changed ancestry or an old runtime
  cannot authorize a continuation.

## 7. Profiles and identity

- Candidates: directories in the profiles root named exactly `Claude` or starting with
  `Claude_` (case-sensitive), not symlinks, not our app data dir; plus any folder named in our
  registry or one of our pending sign-ins. A candidate is a profile if it has
  `config.json`, a `claude-code-sessions/` directory, or a pending sign-in.
- Account UUID = non-empty `config.json` `lastKnownAccountUuid`. Never read `oauth:*` keys,
  `buddy-tokens.json`, Local Storage, IndexedDB or cookies values for identity.
- Active organization = the org UUID whose `dxt:allowlistLastUpdated:<org>` value is the newest
  parseable RFC 3339 timestamp (fractional seconds optional). Ties → lexicographically smallest
  UUID, so the choice is deterministic. No valid stamp → unknown: sync and continuity for
  that profile are skipped with a visible warning, never guessed. Quota, email and plan still
  show: the quota service then reads the account's only organization (§11).
- Readable bucket = `claude-code-sessions/<accountUUID>/<activeOrg>/`.
- Email, plan and channel come from the network snapshot (§11) and its cache. No LevelDB
  parsing: a recursive scan of Local Storage payloads can mix accounts, and the network answer is
  authoritative.
- Status: `signedIn` when the UUID exists; `signedOut` when there is no UUID but account buckets
  exist, or §11 got 401/403 / found no session cookie; `awaitingSignIn` when neither; and
  `unreadable` when `config.json` exists but cannot be parsed.
- Two live folders with the same account UUID are both kept; both cards show a "duplicate"
  note (no merge in v1; the user can remove one). Orphan buckets of accounts not
  live anywhere are left alone (no ghost recovery in v1).
- Discovered profiles not in the registry (and not dismissed) appear as a "found an account"
  notice; one click adds them. No rescan button.

## 8. Sessions, sync, backups

- Session records are exactly the files `local_*.json` in a bucket. Copying every `.json` would
  carry `scheduled-tasks.json` between accounts and duplicate scheduled tasks, so
  `scheduled-tasks.json`, `waiting-input/`, `deleted_*` markers and anything else are never
  copied. Transcripts (`~/.claude/projects/…`) are never written.
- One-way sync source → target: traverse only `<sourceAccount>/` (all org subdirectories).
  Re-home: account component → target account. When both active orgs are known and differ and
  `<sourceAccount>/<sourceActiveOrg>/` exists: files there go to
  `<targetAccount>/<targetActiveOrg>/`; files under `<sourceAccount>/<targetActiveOrg>/` are
  skipped (residue of sessions filed under the wrong org); other org folders keep their org component.
  Orgs equal or unknown → keep the relative path and record a warning when unknown.
- Respect deletions: never copy `local_<id>.json` into a bucket that contains a
  `deleted_<id>` marker.
- Conflict rule: identical bytes → skip; target absent → copy; source mtime strictly newer →
  replace; otherwise keep the target and record a conflict. A non-regular target (symlink,
  directory) or any stat error other than "not found" → per-file error, never written through.
  A traversal error aborts that leg with an error (no silent partial success).
- Copies: stage as `<name>.cc-tmp-<random>` (never a `.json` suffix), preserve the source mode
  (fallback 0600) and mtime, fsync, rename over the target; remove the stage on failure.
- Two-way sync = leg A→B then leg B→A; unresolved conflicts = the intersection of both legs'
  conflict lists **by basename**.
- After each leg, rebuild `archived-sessions.idx` of every touched target bucket from the records
  actually present: explicit `isArchived` true → listed,
  false → not listed, absent → keep existing membership; output sorted; unchanged → not
  rewritten; malformed record or unsupported existing index → leave that index untouched and
  record an error; single-line JSON `{"v":1,"archived":[…]}` with no trailing newline; staged
  write, mode preserved (default 0600).
- `BackupManager`: before any write into a profile, snapshot its whole `claude-code-sessions`
  tree (plus `claude_desktop_config.json` when the operation will modify it) into
  `Backups/<folder>/<stamp>[-n]/`, staged in a `.partial` sibling and renamed into place only
  when complete, so a snapshot is whole or absent. Per-file mode and mtime preserved, dirs
  0700. Reuse the newest snapshot only when a fingerprint (sorted relative path, size,
  nanosecond mtime; ignoring `.DS_Store` and `._*`) of the current tree equals both the stored
  and the recomputed fingerprint of that snapshot. A failed stat of the tree (other than "not
  found") is an error, not "nothing to back up". If a mandatory backup fails, the write does not
  happen.
- Retention after each backup: newest five per folder stay; older ones are renamed into
  `Backups/.trash/<today YYYYMMDD>-<folder>-<stamp>`; trash entries whose name date is 30 days
  or more before today (local midnight) are deleted. Only names our parser accepts are touched.
  Pruning errors are logged and never fail the operation.
- Nothing ever writes into a profile while a Claude instance runs on it.

## 9. Switch orchestration (`SwitchCoordinator`, actor)

Automatic switching uses this same coordinator, gated by `autoSwitchOnQuota` and auto-sync.
A live, independently verified, unstopped native runtime must be present. The trigger is that
runtime's exhausted five-hour/weekly window or typed `classic.StopFailure(error: rate_limit)`,
or a matching successful network quota reading less than two minutes old. A generic transport
failure, stale cache or predicted reset never authorizes a close. Alternatives are refreshed
before selection; the panel's ranking applies to accounts with at least 10% five-hour
quota and nonzero weekly quota, those under 5% weekly last, excluding the same login and recent failures; all accounts are
read at once. No alternative: leave Desktop open, and read the others (the spent one with them)
again only once one may have become usable (`AutomaticSwitchPolicy.nextChance`: the last reset among the windows that hold an
account back, or the end of its exclusion; ten minutes when its figures cannot tell), or at once
when the source or the registered accounts and their logins change, the setting is turned on again,
or a reading that arrives meanwhile already shows one. The selected switch skips the task-guard question
and compaction, and always syncs whatever the sync setting says: it exists to carry the work on,
which needs the conversations in the next account. Settings, source identity and other open
profiles are checked again before closing. The check reads only the conversations' reports, never
their histories, and the work holds the switch back only where closing would cut a command off: a
background Bash that needed approval (no protected worker) waits until it ends (`commandRunning`,
shown nowhere, since the switch follows the command); protected commands go along. A report may
also carry the host's list of background tasks from its latest `Stop`/`SubagentStop`
(`hostWorkInventory`: IDs, types and states only, ended ones left out). Only a command goes on
while the account is spent, so only a listed shell the plugin does not protect holds the switch;
work that needs the model, a comment watch or an unknown type does not. Just before closing the list
is read again, also for conversations without a request, and a shell or a task attached to a
protected command that this batch does not carry holds the close too (`commandHolds`); the check
then runs again. A report without the list changes nothing. A spent account is left even with
nothing to carry on, a reply the person stopped, or a conversation that sends no report: the next
message goes to an account that can answer it, and a stopped reply is not taken up again. A
history that cannot be read or followed in full, before or after the close, or one too large to
hand over, goes on without its tasks: its request keeps `branchComplete: false`, nothing is replayed
from it, and the conversation continues from its own history. A protected command that may still
run without its exit permit from the new operation (its record missing or not matching) cannot be
handed over; the switch goes on, and a manual one says so with the `workContinuationUnavailable`
warning. A preparation that fails (its files cannot be written) waits ten minutes
(`continuationNotReady`). Each pause is logged once with its reason. The pause banner carries the moment it tries again where that is known
(`retryAt`): the next chance for another account, or the end of the ten minutes; `distantFuture`
when only another account signing in can let it go on. Artifact
comment watches never hold it: a watch stays with the account that published its page. A target
that fails to open or sign in is excluded for ten
minutes and another is tried after thirty seconds. When a carried conversation is in
`bypassPermissions` mode, a target whose `claude_desktop_config.json` does not set both the
account's bypass gate and choice fails with `targetCannotContinue` before anything closes; it is
excluded the same way and the next account is tried at the next check. When only such accounts
remain, the pause banner names one of them (`autoSwitchNeedsBypass`). A record whose mode cannot
be read decides nothing. Manual switches never make this check. A transfer that fails after
Claude closed (backup, sync, the post-close capture, or a carried conversation the target
could not be told to start, after which none is left marked there) cancels the batch and reopens the source
and its conversation instead of the target (`transferFailedReturnedToPreviousAccount`, or
`transferFailedNotReopened` when the source does not open either, which leaves the source owed);
automatic switching from that login then waits until its limit ends, ten minutes at least, and
turning the setting off and on lifts the wait. A manual switch with the same failure completes
with the `workContinuationUnavailable` warning. Any other failure would recur with every target,
so it waits ten minutes; a handoff that could not be prepared shows as the pause notice, not as a
failed switch. After a switch that a limit report alone caused (`limitSwitch`, the figures not
showing the account spent), a new rate-limit report from the target within ten minutes of its
start reads that account once, before anything is prepared: fresh figures with quota left stop
it with the `limitRepeated` pause, as the next account would most likely fare the same, and no
other account is read while that report stands. The pause ends with the report; spent or
unreadable figures, or a later report, switch as ever. A turn that fails with `account_on_hold` or
`oauth_org_not_allowed` makes the runtime report `accountRestricted`, which outweighs any limit
and any figures: from any verified conversation of the account, also a stopped one, it stops the
switch with that pause, up to the final check before the close, and reads nothing else. A reply
that gets through ends it, or a day. Manual switches never make this check. Unless a runtime report names a limit, only a fresh reading that shows the account
spent goes further: a fresh one with quota left ends a pause, and an older one decides nothing and
is not refreshed by the check. Conversation histories are read only once a limit is confirmed,
and one unchanged since its last complete read is not read again. See `native-work-continuity.md`.

One operation at a time (switch, add, history import, remove, auto-correct).
Steps, each emitted as a progress event the UI renders on the target card:

1. Validate before closing anything: target folder exists with a readable
   `config.json`; no operation in flight. Same account as current and Claude running → no-op.
   No Claude process at all (`hasAnyProcess()` false) → skip steps 2 and 4 and launch the target
   directly in step 7 (still with sync and continuity). Leftover helpers without a main instance
   go through steps 2 and 4 like a running Claude.
2. Task guard (§10). `.busy` or `.unknown` → the UI offers *wait then switch* (re-check every
   5 s, cancellable), *switch now*, *cancel*. Then compaction first, unless the user chose
   *switch now* or `autoCompactOnLowQuota` is off: the conversation step 3 would capture, when its
   transcript holds at least `AutoCompactLink.switchContextTokens` (300 000) of context (counted as
   in step 9) and its plugin reported within 120 s with `switchRequests` (an older plugin would
   never answer, so it is not asked), is compacted by that plugin on the account being left (§10). Write `AutoCompact/switch-request.json` (`id` = the time in ms, `sessionID` =
   its `cliSessionId`, `until` = 170 s ahead: the plugin begins nothing past it), emit step
   `compactingConversation`, and look for `switch-result.json` with that `id` every second for up
   to 180 s, or until `skipCompaction`. Once it says `compacting`, the wait runs up to 600 s more
   for the answer (`compactionRunLimit`): closing Claude under a `/compact` would waste it.
   Then remove the request and go on, whatever the answer. Not compacted — no report, an older
   plugin, the request not written, an answer other than `compacted`, no answer in time, still
   compacting at the end — adds the warning `notCompactedFirst`; a skip by the user adds nothing.
   After a wait the task check runs again, since a task may have begun meanwhile; its time adds
   to the task check's in the log line.
3. Continuity capture from the current profile's readable bucket: every
   `local_*.json` must parse with a `sessionId` equal to its basename; choose the greatest
   `lastFocusedAt`, ties by `lastActivityAt`. Capture problems become a warning, not a refusal.
4. Add to `relaunchDebt` the target and every other open profile except the one being left.
   Older records stay owed, however many closes come in between; one whose profile is open now
   is settled, since this close decides about that profile itself. Then `quitAll`, whose
   `beforeForce` re-checks the task guard (a task that became busy blocks forcing) unless the
   user chose *switch now*. Failure to close → drop only the records this close added, recheck
   what is running, reopen exactly the profiles the failure reports as closed and that are not
   running again (no sync, no deep link), and fail with `couldNotCloseClaude`. One of them that
   does not open, or all of them when what runs cannot be read, stays owed for the next pickup.
   The same recovery applies wherever an operation closes Claude (add account, history import,
   auto-correct).
5. If `autoSyncOnSwitch`, the profile being left is not the target, and both profiles have
   account + active org: back up both, two-way sync — also when Claude was already closed. Only
   with no Claude process left. Backup or sync failure does not stop the switch; it becomes a
   warning.
6. Continuity check in the target after the merge: same `sessionId` and `cliSessionId`, not
   archived, `worktreePath` or `cwd` exists, no `transcriptUnavailable`, and the transcript
   `~/.claude/projects/*/<cliSessionId>.jsonl` holds a row with `type` `user` or `assistant`
   whose `sessionId` equals that **cliSessionId** (lines up to 16 MiB; the CLI id must match
   `[A-Za-z0-9-]{1,64}`). Record the launch threshold (ms) just before launching.
7. Launch the target (with the deep link only if step 6 passed) and the bystanders; wait for the
   target instance (§6). The target's record leaves the debt, a bystander's once it opens (older
   records are reopened along with them); set `activeFolder`, report "switched".
   If the target does not open: still launch the owed bystanders, then reopen the profile being left
   (with the deep link of the captured conversation when step 3 succeeded), settle the debt, keep
   `activeFolder` on that profile, and fail with `returnedToPreviousAccount`. Only when that
   profile cannot be opened either does the result stay `couldNotOpenClaude`.
   `relaunchDebt` records leave the store only after their profile is open again (launched, or
   found already running, which is never launched twice). A launcher claims a record in memory
   first so no other launcher (the quit handler, say) takes it meanwhile; a failed launch or a
   crash mid-launch leaves the record for the next pickup. The target remains durable and
   claimed throughout its attempt: held from just before the close of step 4, since the sync
   writes into it, until the switch ends (`RelaunchDebt.hold`; no other launcher takes a held
   profile; a history import holds its target the same way, until just before its own launch).
   Only a confirmed clean failure transfers recovery to the previous account; the quit handler
   cannot claim either side of an unresolved attempt.
8. Continuity confirmation in the background: poll every 200 ms for up to 90 s for the target
   record with the same ids, unarchived, `lastFocusedAt` changed and ≥ threshold, while the
   target profile runs with unchanged account/org. Never resend the link. Timeout → warning
   "couldn't reopen your conversation".
9. Result: `.switched`, `.switchedWithWarnings([…])`, or `.failed(reason)`; then refresh quota
   for the target. When step 7 reopened a conversation, its size is logged. A conversation's
   size: read the last `assistant` row of its transcript that carries `message.usage` (scan from
   the end of the file) and add `input_tokens + cache_read_input_tokens +
   cache_creation_input_tokens + output_tokens`. Skip rows Claude Code writes itself
   (`message.model == "<synthetic>"`, such as the usage-limit error, or a zero total) and
   sub-agent rows (`isSidechain`). A `compact_boundary` system row or an `isCompactSummary` row
   newer than that answer means the conversation was just compacted: no size. Prompt caches
   belong to an account, so the first message on the new account re-reads that whole context
   uncached — the sudden quota drop users see; compacting on the old account reads it once from
   that account's cache, and the new account then writes only the summary. Only the numbers are
   read; nothing is logged but the total.

Every switch, and every auto-correct, leaves one line in the log, so reliability can be followed
over real use: `Switch <from> -> <to>: switched in N s`,
`failed after N s: <FailureReason>`, `the target did not open, back on <from>`, or `cancelled at
the task check` (`while compacting first`); then `tasks: none running | waited N s | switched now
after N s` or `Claude was closed`; for a conversation long enough, `compacted first: N -> M tokens
in N s`, `not compacted first (N tokens): <why>` or `compaction first skipped by the user after N
s`; and any warnings. Time at the task check and on the compaction first is reported apart from
the switch's own duration. A failed close names what was left running (`ClaudeProcessError.stillRunning.names`,
executable names only) and why the close stopped (`stall`): Claude opened again during the close, not
forced while a Code task ran, still there after a forced quit, or out of time. Each start logs
`Started version <version>`. Folder names only, never account names or emails. A click on the current
account is no switch and leaves no line.

Quitting the app while an operation runs: wait for it to end, then honour `relaunchDebt` and
exit. A switch still at the task check or in the compaction first has not closed Claude: it is
called off (`cancelled`) instead. An operation may be copying sessions into a profile it is
about to open, so opening that profile beside it, or quitting under it, would let Claude and the
copy write the same files; a three-minute limit only keeps a hung operation from holding the
quit. A profile such an operation still holds then stays owed and opens at the next start; the
rest opens as usual. On startup a non-empty `relaunchDebt` is honoured once, also beside a Claude that is
open: a profile already open is settled without a launch.

## 9a. Native work continuity

`NativeRecoveryCoordinator` is wired into the switch above and runs for switches with
`autoSyncOnSwitch`; the combined `cc-relay` plugin supplies the native runtime hooks
and bundles `CompanionNativeWorker`. No separate task tool or task-submission workflow exists.
Requests carry `requiredCapability: native-recovery-v6` and runtimes must report it; commands
need worker execution protocol 3. Anything older is refused rather than treated as compatible.

Account switches hold an OS file lease across app instances before any close/sync/launch.
Recovery commits use a short operation lease and compare the captured generation again after
awaits; a stale prepare or empty capture cannot replace or delete a newer generation.
Activation reservations and the focus return commit once under that lease.

1. **Capture.** After the task-guard choice and any compaction, before close, enumerate the
   source profile's live CLI sessions and read their transcripts side by side.
   `NativeWorkCapture` selects the active branch at a file-size boundary and records evidence
   pointers for unfinished work. A step that calls several tools leaves each result under its own
   call, so only the last one is on the branch: a pure result row whose parent is a call on the
   branch, and whose results all answer that call, is read right after it. The validated plugin
   report adds the live task inventory. Old
   pending entries without a live inventory do not wake an idle conversation; a continuing one
   lists them. Historical files alone never revive work on a cold launch. For a compact boundary
   with a preserved segment, only a complete physical tail-to-head chain, head-to-summary and
   summary-to-boundary links, a `user` summary with `isCompactSummary == true`, and matching
   head/anchor/tail metadata allow the obsolete logical back-edge to be removed. A valid older
   logical ancestor is retained. Real physical cycles, missing parents and malformed metadata
   still make the selected branch incomplete. Duplicate UUIDs use the latest physical row;
   normalization is a snapshot copy so checkpoints can re-evaluate appended rewrites. Newer
   Artifact stops continue to override older armed telemetry. An armed watch stays with the
   account that published its page, which no other account can open. A conversation with
   nothing but an armed watch is not captured; when its plugin reports `watch-reopen-v1`, any
   conversation with armed watches, carried or not, becomes a `NativeLeftWatch` of the batch with
   those `pages`, leaving out a page already kept for another account, also one that has opened
   since (an older record without `pages` holds all of its conversation's). The batch's watches
   are recorded under `left-watches/<folder>.json` once Desktop has closed. The plugin reads these
   records, a week at most, and neither connects nor reports a watch kept for another account than
   the one its runtime is open on: in a switch's recovery, that is the account the request
   targets, and the continuation's watch calls on those other pages are refused; on an ordinary
   reopen they are skipped, the runtime's account
   being the one its start's note names, or the one `open-accounts.json` lists for the Claude among
   its parent processes. CC-Relay writes that list on every rescan: each open Claude's PID and
   start, in UTC to the second as `ps` shows it, with its account. With the account unknown, every
   kept watch is skipped for now: the other watches go on, and the runtime looks for its account
   every 30 seconds for six minutes, as CC-Relay lists an open Claude within five; a watch that
   turns out to be its own is then restored, without reading the history again. Before CC-Relay next opens that account (a switch to it, or a return to
   it after a failed switch), `prepareLeftWatchReopen` writes Desktop's quit-resume marker on those
   records, leaving out conversations the opening carries on, and a one-time
   `watch-reopen/<sessionID>.json` note naming the account; the plugin uses the note at start, unless it can
   tell that it runs on another account, and drops Desktop's continue that follows, so only the
   ordinary reopen recovery runs. A failed opening records them again and takes its notes back. An account found open that CC-Relay did not open for them (the
   current one, or one opened beside it with its own profile) cannot be told to start them: each
   conversation picks its watch up when it is opened there. Either way the records stay, marked
   `opened`: nothing waits for that account any more, and they only say whose pages they are. The
   ordinary reopen recovery knows only the CLI session: when its branch does not connect, it looks
   for the conversation's Desktop record in each profile's session buckets and connects a fork
   through the ancestors that record's bucket links, as a switch's capture does.
2. **Close and reconcile.** Persist the generation with `ready = false`. Sample explicit user
   stops again just before close. After close, continue each read from its in-memory
   checkpoint (same inode, unchanged bytes before the old end; else a full read), resolve work
   completed during shutdown, and issue the exit permits again so their window starts now. A
   history that no longer reads whole after the close is a capture failure, never finished
   work. A generation whose requests cannot all be saved puts back what it wrote over, the
   operation, requests and exit permits of a generation still waiting before it included: no
   caller holds it to cancel. A generation called off before Claude closes puts the same files
   back; past the close the runtime the earlier one waited for is gone, and nothing comes back.
   A file it would write over that is there but cannot be read
   stops it before it writes anything, as that file could not be put back.
3. **Release.** Backups and sync must succeed and the target must launch before `ready`. A
   failure invalidates the batch; a rollback to the source creates a new generation for it.
   Just before the launch, each prepared conversation's target record gets Desktop's own
   quit-while-working marker so Desktop starts its CLI; a record waiting for the person or
   stopped by them is left alone. An unattended switch marks all of them or none: one that
   cannot be marked puts back those already marked, and the switch goes back. The plugin holds Desktop's resulting continue for the
   continuation, or drops it for a handoff that needs no model turn.
4. **Bind.** A request binds to a runtime whose report is at most 30 s old, matches the target
   account/org and the original Desktop and CLI session IDs, was born after the switch began and
   passes `NativeRuntimeInspecting.validate`. Once bound, it stays healthy while that process
   lives; report age alone never revokes it.
5. **Activate.** Conversations without a bound runtime are opened one at a time through
   `NativeConversationOpening`, which hands the conversation URL to LaunchServices only while
   the target profile's Desktop is the only Desktop running (otherwise `ambiguousTarget`, left
   to the user). No Apple event is sent and no permission is requested. Each attempt is
   persisted first and waits up to 30 s for a handshake within a 90–300 s window; the focus
   returns once to the primary conversation. A later manual open still binds within the
   request's 24 h lifetime.
6. **Restore concrete work.** The plugin durably claims the request, reattaches protected
   commands and command monitors to their original worker, recreates verified WebSocket
   monitors with their remaining deadline, resumes interrupted agents by ID through
   `SendMessage` and rechecks Artifact comment watches at their original URL, except those another
   account keeps.
7. **Continue.** If work remains, the original conversation receives a `[Continuation requestID=…]`
   marker and one sentence: "Please continue the unfinished work from where it was interrupted,
   following the original instructions and scope of authorization." Work snapshots and evidence
   remain in the local request and result files. The prompt never executes command recovery.

**Command protection.** A background Bash command or command Monitor is enrolled only when
`$.tool.check` allows its original input outright and the merged settings hold no PreToolUse
hook (`$.tool.check` consults neither those hooks nor the classifier). Every other command runs
unmodified, so the dialog, the auto-mode classifier and the policy see it; it does not survive a
switch and the local recovery receipt records it. The `tool.check` hook decides an enrolled wrapper by its
original alone: allow, unless the original no longer is or the wrapper itself is denied. The
wrapper writes the native shell's functions and aliases (zsh: functions, aliases and `fpath`;
bash: functions and aliases) into the job folder, named by shell; the worker sources them in the
same kind of shell, deletes them and `eval`s the original text with no positional parameters.
A trailing comment keeps the original's first line visible in the task list. Reattaching after
a switch requires the original to still be allowed outright; otherwise the worker is stopped.

**Worker.** The original runs once, in an orphaned worker that owns its process group; native
clients only stream its output. A one-time execution journal survives missing mutable state. Worker
and clients wait on kqueue file, folder and process events, with timers only for deadlines and
permit expiry and a 10 s backstop. An exit the queue reports can come before the process table shows
the process gone, with no second event, so while it still shows they look again every 25 ms. The
worker ends the command when its CLI or native client exits without a valid exit permit: TERM to the
owned group, up to half a second for it to end, then KILL to the group until two looks in a row 25
ms apart find it empty, all before the leader is reaped so the group number cannot be reused. A
process the command was starting as the signal went out can show up after an empty look, so one look
is no proof. Stop confirmation includes live members of the owned group. Adoption and the next exit
permit share a private ownership lock; per-request adoption files keep stale writers out; Monitor
consumers reserve their cursor first.

**Exit permits.** A permit is written before close, written again once Desktop has closed, and
extended by the poll when less than 2 min remain while the conversation waits, until 5 min
after the activation window. A permit for a command the target already adopted is never
extended, so the target's own exit ends it as in any conversation.

**Polling.** The engine reads only the operation record every 5 s. An operation is polled every
2 s for 15 minutes after it was created, every 30 s afterwards, and not at all once every
request is final (resolved, blocked, stopped, expired or closed by a final receipt), when
`finishedAt` is recorded. The poll holds `OperationGate` in background mode; a user action and a
default-launch correction wait behind it instead of being dropped.

**Summary and notice.** `NativeRecoverySummary` keeps `waiting`, `submitted`, `executing`,
`ended`, `inspected` and `attention` distinct and says when it is `finished`. A `turnFinished`
receipt counts as ended, a turn that finished in words alone included, unless every step it took
failed. What the person decided is not counted: a source stopped by hand before the switch, and a
`yielded` receipt (a newer instruction or the person's stop took over). The protected commands a
stopped source left running end with the switch, since no permit carries them across: those not
finished by themselves nor stopped before the switch began are counted as `endedWithSwitch`, told
in a neutral line, never as a problem. An operation with nothing else shows no notice. Only work
under way makes a conversation part of an operation: armed comment watches alone do not.

The summary also names the accounts (`from`, the operation's `sourceProfile`, none after a return
from a failed transfer; `to`) and whether it is `settling`: within `settlingTime` (30 s) of
`readyAt`, when the target account opened, its conversations may not have reported yet. A
settling summary is never `finished`, so polling goes on until a problem held back meanwhile can
be shown. The panel shows one of three states: **正在接续 / Continuing work** while anything is
waiting, submitted or executing, or while a problem is settling; **接续成功 / Work continued**
once everything ended or was inspected, both with a second line "从 A 换到 B" (only the target,
`switchedTo`, when the two names do not fit one line); **接续受阻 / Work blocked** with one line
of reason, or the number of conversations when their reasons differ, and the records button.
Continuing is the notice kind `inProgress`, drawn as three dots where the others have a tick or the
yellow mark.
`endedWithSwitch` is a line under the state, or the whole notice when nothing else happened. A
notice's ID includes its state, so the next state shows again after one was closed; a finished
notice seen in the panel goes when it closes. A completed switch sets the next automatic check to
`settlingTime` from then and clears the last account's pause, so the target's conversations have
reported whether one runs a command before the next check, and a wait the last account was in does
not carry over to the one just opened.

**Cleanup.** At launch and when an operation finishes, `prune()` removes runtime reports silent
for a day, requests and receipts of other operations after a week, and ended commands with
their execution folder after three days. A command whose worker still lives is never removed.

The batch covers the source profile's original live conversations and pending continuations.
Bystander profiles keep the window-reopen behaviour; their tasks are not included. Default-
launch correction and history import never create recovery requests.

## 10. Other flows

- **Task guard** (`CodeTaskInspecting`): from the process
  table, take every process whose executable basename is `claude` and whose ancestor chain
  reaches any executable inside the Claude bundle; a bundled CLI itself also qualifies.
  This includes helpers and their tasks after the main process exits. For each, read
  `~/.claude/sessions/<pid>.json`; it is valid only
  if `pid` matches, whitespace-normalized `procStart` equals the process start time formatted as
  `EEE MMM d HH:mm:ss yyyy` in **UTC** (`en_US_POSIX`), and `entrypoint == "claude-desktop"`.
  `status == "busy"` → busy; `idle` with a direct child whose basename is `sh`, `bash`, `zsh` or
  `fish` → busy; anything else, or an invalid record → unknown. Busy wins over unknown.
- **Auto-correct default launch** (`LaunchCorrector`): on a launch event **without an explicit
  profile flag** (`hasExplicitProfileFlag == false`, i.e. someone else opened Claude on the
  default profile) while `activeFolder` is another signed-in profile, the setting is on and no
  operation is in flight → quit that instance and launch the active profile (no sync, no task
  guard needed for a fresh instance). The scoped close checks pid + start time + executable,
  owns only that main and its descendants, and preserves other running instances. The active
  profile is launched only if it is not already open. At most once per 60 s; a second default
  launch inside
  that window disables correction for 10 minutes and shows a notice (loop guard).
- **Current account follows Claude** (`AccountFollowing`, on every rescan with no
  operation in flight and no pending sign-in; a flagged launch event triggers a rescan): when no
  running main instance has `activeFolder`'s profile, the managed account of the newest running
  instance with an explicit profile flag becomes `activeFolder` (a flagless default launch only
  counts when auto-correct is off — otherwise it is auto-correct's). This keeps the hero card
  honest after a switch made without this app.
- **Found and dismissed accounts**: a signed-in, unmanaged, non-pending profile gets a
  `foundAccount` banner unless dismissed (`knownUnmanagedFolders`) — and a dismissed one gets it
  again while Claude has it open, unless it was dismissed during that same opening (kept in memory
  until no running instance has it). Dismissed ones are listed in
  Settings (`ignoredFolders`) with "add back" (`addFoundAccount`). A notice's dialog ignores taps for
  0.6 s after it appears, so a dialog that pops up under the pointer is not hit by a click meant
  for what was there.
- **Add account**: task guard → create `Claude_<6 random [a-z0-9]>` (mode 0700, no collision) →
  persist a pending sign-in with `returnToFolder` → close Claude → launch the new profile → poll
  every 2 s for sign-in: `lastKnownAccountUuid` present, an active org stamp present, and a
  `sessionKey` cookie row present (presence only) → fetch account details (§11); default name =
  email local part, deduplicated with `-2`, `-3`; explicit authentication rejection → keep
  waiting for sign-in, and that cookie is not sent again until it changes (remembered in memory,
  so at most once per launch); account mismatch → report the mismatch; other network failure → name
  `新账号` and retry later
  → register, make active, and run the initial history import (below). Signing in to an account that is already registered → offer
  "keep both" or "discard the new folder". Cancel: close Claude, archive the new folder,
  relaunch `returnToFolder`. The new profile does not open: unless a Claude, or a helper of one, still uses
  it, archive the empty folder, drop the pending sign-in and the history job, owe
  `returnToFolder` again when it was open, relaunch it, and fail with `couldNotOpenClaude`.
- **Initial history import** (only when `autoSyncOnSwitch` is on; this is how a new
  account gets every other account's conversations at once — two-way sync on a switch only
  covers the two accounts involved): donors = every other managed signed-in profile with a known
  active org whose readable bucket exists, pinned (folder, account, org) when the add starts.
  After sign-in, a `HistoryJob` is persisted with `paused = true, issue = interrupted`
  **before** closing Claude; then: close (with task guard) → back up the target (including
  `claude_desktop_config.json`) → one-way sync each still valid donor into the target → inherit
  the Code "bypass permissions" opt-in (keep any
  explicit target choice; a source `true` only when the target gate is already `true`; never
  copy the gate; refuse if the file changed meanwhile) → relaunch the new account → remove the
  job on full success, otherwise keep it paused with `failed` / `unavailable` and show a banner
  with a retry action. Never retried automatically.
- **Remove**: refused for the active account, the last account, and any profile detected running
  (or when running state cannot be determined). Running includes a helper or a task under one
  that outlived its main process (`profilesInUse()`); a live Claude process that names no profile
  leaves the state undetermined. Rename the folder into `Archive/`; then clean registry, pending,
  history jobs, the relaunch record (Claude would start an empty profile in a missing folder, so
  a relaunch also skips one that is gone) and quota cache, reporting partial cleanup separately
  from "not moved". Never deletes.
- **Rename**: inline in the card; trimmed, 1–20 characters, any script.
- **Signed out**: the card says "sign in again"; this is actionable on the current card too.
  Clicking it switches to the profile so Claude shows its sign-in page; sign-in detection as for add, with `expectAccountUUID` checked — a
  different account signing in is reported, not silently accepted. A confirmed sign-in reads its
  quota at once (forced): the failure behind "sign in again" is often seconds old, and the
  throttle or a recent reading would otherwise keep the card on it. Signing in again keeps the
  same login in `config.json`, so only a new `sessionKey` cookie can confirm it; the turned-down
  one is not sent again. A completed switch to another account ends the wait: the window it
  was waited in is closed.
- **Login item**: writable startup installs a missing item when the saved setting is enabled,
  including old installations that saved the default without creating it. Existing items are
  preserved. If installation fails, persist the setting as disabled so the UI stays honest. The
  item is the app itself under the system login-item service (`SMAppService.mainApp`), listed by
  name in System Settings. When the person turned it off there (`requiresApproval`), that choice
  stands and enabling fails. When the service turns the app down for another reason, a LaunchAgent
  plist `local.cc-relay.plist` does the job instead (Label = bundle id, ProgramArguments =
  [executable], RunAtLoad, ProcessType Interactive; effective at next login; never loaded or
  unloaded).
- **The Claude Code plugin** (`ClaudeCodePluginInstalling`): ready means `~/.claude/settings.json`
  enables `cc-relay@cc-relay-local` and sets `env.CLAUDE_CODE_ENABLE_FUNCTION_HOOKS` to "1", and
  `plugins/installed_plugins.json` lists it. Core looks at startup and each time the panel opens
  (`CompanionSnapshot.pluginReady`, nil until then). While it is missing, turning on auto-switch or
  auto-compact opens a dialog instead (`PluginDialogState`: asking, installing, done, installedButOff,
  failed). Its main
  button sends `installPlugin`: the hooks variable goes into `settings.json` after the old file is copied
  beside it (`settings.json.cc-relay-backup-<UTC time>`; a link, a folder or anything but a JSON object is
  refused), then Claude Code's own `plugin marketplace add <app>/Contents/Resources/Plugins`,
  `plugin install` and, if still needed, `plugin enable` run through `/usr/bin/env` with that variable.
  The program is the newest Claude Code that Claude Desktop keeps under an account folder
  (`claude-code/<version>/<build>/claude.app`), else one in `~/.local/bin`, `~/.claude/local`,
  `/opt/homebrew/bin` or `/usr/local/bin`. The receipt names the outcome (installed; no Claude Code,
  settings unusable, not finished); the feature turns on only after an install it confirms, and stays off
  otherwise. When an operation under way refuses turning it on, the dialog says the plugin is in and
  the feature is not (`installedButOff`). The sandbox writes the same two files inside itself.
  After an app update Claude Code still records the older version (`installed_plugins.json`), or
  reads the plugin from where the app was (`known_marketplaces.json`, a `directory` source):
  `needsUpdate` compares both with `<app>/Contents/Resources/Plugins/cc-relay/.claude-plugin/plugin.json`,
  and Core runs the install by itself once it starts. The install does only what is missing:
  `plugin marketplace add` when the marketplace reads another folder (adding it again under the
  same name points it there and keeps what is installed from it), `plugin install` when absent,
  `plugin update cc-relay@cc-relay-local --scope user` when installed but not current. Nothing shows
  unless that fails: then `CompanionSnapshot.pluginUpdateFailed` puts one row in Settings whose retry
  sends `installPlugin`, and an install that succeeds clears it. Both modules report the version they
  loaded with (`hooks/version.js`): the compactor's status as `version`, a runtime report as
  `pluginVersion`.
- **Low-quota compaction** (spec in `docs/low-quota-compaction.md`):
  the plugin decides and compacts by itself, from the conversation's own usage figures, so it needs
  neither this app's web reads nor this app running. CC-Relay writes `AutoCompact/settings.json`
  (`enabled` = `autoCompactOnLowQuota`, `minContextTokens` 100 000, the plugin's language) at startup
  and whenever the switch or the language changes. Each scan reads `sessions/*.json` (a conversation
  reporting within 120 s is live; Settings shows live / last report / none) and moves every new
  `results/*.json` to `results/seen/`, logging one line per result (with the host's reason when it
  did not compact) and showing the newest as a banner (`Banner.autoCompacted`) until the panel has
  shown it and closed; a task paused at the hard line and not resumed always shows one, as a
  warning to tell it to go on; one with trigger `switch` (made for §9 step 2) only when it compacted, as
  the switch's result covers the rest, and until a later opening has shown it, since it arrives as
  Claude comes back to the front and closes the panel. Never a `config.json` under the data directory (§5).
- Cookie: `<profile>/Cookies`, or `<profile>/Network/Cookies` only when the first is missing;
  SQLite read-only with a 3 s busy timeout (WAL visible). `meta.version` (default 0). Newest
  `sessionKey` for host `claude.ai` / `.claude.ai`; blob 1…65 536 bytes.
- Decryption (`ChromiumCookieDecryptor`, pure, Core): password from
  `/usr/bin/security find-generic-password -w -s "Claude Safe Storage"` (memory only) → PBKDF2-
  HMAC-SHA1, salt `saltysalt`, 1003 iterations, 16-byte key → require `v10` prefix and block
  alignment → AES-128-CBC, IV = 16 × `0x20`, strict PKCS#7 → if version ≥ 24, require > 32 bytes
  and a leading SHA-256(host_key) (constant-time compare), strip it → non-empty UTF-8 without
  CR, LF, `;`, NUL.
- HTTP (`ClaudeWebClient` over `HTTPTransport`): GET `https://claude.ai` + path with
  `Cookie: sessionKey=…`, `Accept: application/json`, `Origin: https://claude.ai`,
  `Referer: https://claude.ai/`, and a Desktop-like User-Agent built from the installed Claude
  and Electron versions (Info.plist). 20 s timeout, no redirects (a redirect is a failure),
  responses capped at 2 MiB.
- `/api/account`: `uuid` must equal the profile's account; `email_address`; membership = the one
  whose `organization.uuid` is the profile's active org, else the only membership, else error.
  Plan from `analytics_subscription_plan` (lowercased, trimmed, `claude_` prefix removed):
  free→Free, pro→Pro, max→Max (refined to Max 5×/Max 20× by `rate_limit_tier` containing
  `max_5x` / `max_20x`), max_5x→Max 5×, max_20x→Max 20×, team→Team, enterprise→Enterprise;
  unknown → empty (never borrowed from another membership).
- `/api/organizations/{org}/usage` (org validated as a 36-char UUID): `five_hour`, `seven_day`
  each optional with `utilization` (0…100, else invalid response) and `resets_at`; at least one
  window must have a percentage.
- `/api/organizations/{org}/subscription_details`: channel from `subscription_details_url`
  (`apps.apple.com` → App Store, `play.google.com` → Google Play, other URL → web, missing →
  unknown); at most once per day per folder; failures keep the previous channel.
- Errors: 401, claude.ai's own JSON 403 to the account read, or no sign-in cookie left in the
  profile → marked signed out (card says "sign in again" and shows no old figures). The same
  cookie is not sent again on every read: the panel, the timer and an automatic switch's read of
  the other accounts try it once an hour, in case the refusal was about something else, and at once
  when the cookie changes; the user's retry goes through. A 403 that is
  a page from something on the way (a challenge, a network filter), or one to the usage or plan
  read after the account read accepted the session, is `refused`: the sign-in stands. A 429, also to the
  subscription read alone (whose figures then stand) or to the sign-in check, is `rateLimited`: nothing
  reads that login, forced or not, the sign-in check included, before the wait it asked for
  (`Retry-After` in seconds or as a date, a day at most) or else five minutes doubling with each 429
  in a row, an hour at most; never under a minute. `quota-waits.json` keeps the wait across
  launches. A read that works or another login in the folder ends it, and a wait
  longer than a day (the clock moved back) is over. The card names the minute it ends. Other
  failures keep the last cached reading, marked stale. After the keychain refuses the Safe Storage key,
  automatic refreshes do not ask it again (no repeated prompts); only a forced refresh (the
  user's retry) or the account-details read while adding an account asks again. Response bodies, cookies and keys never reach logs,
  cache or UI.
- Cache: only successful readings, keyed by folder, shown only while account and org still
  match (any org while the profile names none). Single flight per folder; a non-forced refresh
  skips a reading younger than 10 min unless a recorded reset has passed; 2-minute attempt
  throttle per folder, also after failures. A flight, a failure and the throttle belong to the
  login (account and org) they were about: once the folder holds another login, a refresh waits
  for the old flight instead of joining it, the old answer is dropped, and the old failure and
  throttle no longer apply.
- Cadence: the current account every 10 min ± 90 s jitter and right after a switch. Every panel
  opening reads all signed-in accounts at once, whatever the age of their readings, skipping only
  an account tried within the last 30 s, and never asks the keychain. So the timer's start at
  launch gets the cookie key from the first encrypted sign-in cookie (current account first; no
  network read, and not after a refusal, like an automatic refresh): a stored reading still fresh
  skips the first refresh, and the first opening would otherwise report the keychain as refused.
  Offline fallback for percent
  used: the newest `plan-usage-history.json` sample for the profile's org, labelled with its time.
- Display: remaining = floor(100 − utilization). A reset time that has passed shows 100 % with
  "reset, refreshing…" until a fresh reading arrives (never presented as a confirmed value).
  Countdown text is recomputed every minute locally; reset times within ±1 s of a minute snap to
  that minute.

## 12. UI contract (CompanionUI)

Visual style: card layout in the Claude Code desktop palette.

- Panel width 360 pt; panel padding 14; card corner radius 14; panel corner radius 16; grid gap
  8; hero padding 14; tile padding 12.
- Typography: the system's fonts (SF Pro / PingFang SC / SF Mono via `.monospacedDigit()`), except
  the wordmark, set in DynaPuff Bold: the app carries it with its SIL Open Font License in
  `Contents/Resources/Fonts`, which `ATSApplicationFontsPath` activates at launch, and SF Rounded
  stands in where it is missing. The wordmark, the settings title and the back button's word
  (both SF Rounded) are art lettering: a fill over a 1.5 pt `#5A3E2B` outline and a 2.6 pt drop.
  Sizes: 20 wordmark, whose capitals stand as tall as the system face's at 21; 18 semibold
  settings title, 15 dialog titles and hero name, 14 tile name and settings
  labels, 13 confirmations and segmented choices, 12 secondary, 11 captions, settings details and
  section headings, 10 tags; plan labels bold, otherwise regular and medium. Every `Text` is
  single-line (`lineLimit(1)`) or a paragraph pre-broken on `\n` whose every line fits its slot
  (`TextFitTests` measures each against its role's width); names truncate at the tail; nothing
  wraps, except a passing confirmation that names an account, which may take two lines.
- Colors (light / dark): panel `#FAF9F5` / `#262624`, card `#FFFFFF` / `#30302E`, hairline
  `#E8E5DA` / `#3D3C38`, dashed `#D6D2C4` / `#55534D`, text primary `#141413` / `#F5F4EE`,
  secondary `#73726C` / `#A6A39A`, tertiary `#A3A198` / `#8A877F`, bar track `#EEEBE2` /
  `#45443F`, quota bars green `#5E9E3A` / `#8CC46A`, blue `#3B7DD8` / `#6CA6EC`, yellow
  `#E0B030` / `#E6BE45`, red `#D64C3A` / `#E7705D`, the same levels as text (percentages, result
  lines) `#3B6D11` / `#A3D17F`, `#1F5FA8` / `#93C0F2`, `#8A6100` / `#ECC75E`, `#BC4A34` /
  `#EE8A76`, reading at 4.5:1 on panel and card,
  accent clay `#D97757` (both), accent text `#B5532F` / `#EE9E82`, suggested-card
  text `#56693F` / `#B5C79A`, dialog buttons clay `#B5532F` and red `#BC4A34` with white text (both),
  the passing confirmation's card `#141413` at 86 % with `#FAF9F5` text / `#F5F4EE` at 94 % with
  `#141413` text; its undo button `#F2A07F` / `#B5532F`. Plan labels look like a game's rare cards,
  the same in both schemes: their colours flowing sideways once every 4 s under a gloss split at
  the middle, a 1 pt light rim, a 3 pt glow, bold white text over a 1 pt shadow, and a slanted
  light sweeping across every 3.4 s. Each strip of colours ends on its first so the flow has no
  seam. Pro violets `#6A1FE0` `#9B4DFF` `#D6A8FF` `#B05CFF` `#7B2FF7` `#E08CFF` `#8A3CFF`; Max 5×
  and a Max of unknown size a game-card gold `#E08A00` `#FFB800` `#FFE066` `#FFC21A` `#F29B00`
  `#FFD84D` `#FFAA00`; every other plan teal `#0E9F8E` `#19C6B0` `#7EF0DC` `#22D3B8` `#0FB5A0`
  `#5CE6CF` `#14BFA6`; Max 20× a rainbow `#FF4D6D` `#FF9F43` `#FFD43B` `#3DDC84` `#22B8F0`
  `#7C6CFF` `#E35BF5`. The cartoon buttons share a `#5A3E2B` outline: the gear `#F4C3A4`, the
  refresh arrow `#A9DCCB`, the back arrow `#D2C7F4`. Settings rows start with a 26 pt pastel
  square and a symbol in its ink (both schemes): launch `#DCE5CF`/`#3B4A28`, sync
  `#DCE8F7`/`#24518C`, compaction `#E6E1F8`/`#4B3C9E`, auto-switch `#D5EEE9`/`#1D5F57`, switch
  confirmation `#F4DDB0`/`#6B4512`, backups
  `#F5CDB9`/`#5A2E1E`, quit `#F8D7D0`/`#A33A26`, a dismissed account `#E4E2DD`/`#5F5E5A`. Buddy skins and ink, the same in both schemes, by weekly level: ok `#C4E3A8`/`#24400F`,
  fair `#BFD8F6`/`#173D6B`, mid `#F8DA86`/`#5E3F05`, low `#F6B7AA`/`#66200F`, empty or unknown
  `#E4E2DD`/`#5F5E5A`; cheeks
  clay at 32 %, outline the ink at 14 %. The current-account card has a 1 pt clay border at 55 %
  opacity, the suggested card one in quota ok at 60 %.
- Quota level by *remaining*: above 50 ok (green), 30–50 fair (blue), 11–29 mid (yellow), 10 or
  less low (red); bar fill never thinner than 2 %. Buddies follow the same four levels (below).
- Reset lines start with a small refresh symbol, then:
  5-hour `HH:mm · X 小时 Y 分后` / `HH:mm · in Xh Ym` (minutes only under an hour; window not
  started → `未计时` / `Not started`); weekly `M月d日 周E HH:mm` / `EEE, MMM d, HH:mm`.
  24-hour clock, system time zone, followed when it changes. Hover shows the full sentence.
- Components: menu-bar item (the current account's buddy, 18 pt like the icons beside it, square at
  rest whatever its mood, drawn as on its card; it stands still and moves only while the pointer is
  over it and, for a moment, when its face changes (a new quota level, another account): it perks
  up or sighs as its colour blends; still under Reduce Motion; clicks go through it to the button;
  its accessibility label carries the current account name and ` · NN%`, the floored 5-hour
  remaining, or the switch in progress), panel header (the wordmark
  centred, "CC-" filled `#F2A584` and "Relay" like the refresh arrow, with the
  refresh-all and settings buttons on the right and a space as wide as them on the left),
  current-account card (36 pt buddy; name, plan label, channel — no card shows an address,
  "current" marker, two quota blocks side by side), the suggested card under it once the current
  account is out (the same layout with a "suggested" marker and a reason line; a click switches to
  it like its tile), or a one-line note instead when no account is usable, account tile (24 pt buddy; name, plan label,
  channel line, two stacked quota blocks), where a card has no figures to show either grey
  placeholder bars while its first reading is on its way or a tinted note (yellow "quota
  unavailable", red "sign in again", clay "waiting for sign-in"); a dashed empty seat when there
  is no other account; a centred "+ add account" capsule between the cards above and the tiles; the card menu (rename and remove, the
  current account's remove greyed with a note), opened by a secondary click (an AppKit overlay
  that takes only right and control clicks) or the "⋯" button a card shows under the pointer or
  keyboard focus (Tab reaches it with macOS keyboard navigation on; VoiceOver has a "more
  actions" action on the card), and driven by the arrows, Return, Esc and Tab; dialogs in the middle of the
  panel (switch, add, rename, remove, notices); the passing confirmation, with an undo button
  after a removal; settings screen inside the panel.
- Header buttons: the refresh arrow reads every signed-in account's quota (`refreshQuota(nil)`);
  it turns for at least 0.7 s, the figures pulse meanwhile, then pop once as the arrow swings back
  and settles, and "quota updated" passes in the middle. It is greyed and does nothing while an
  operation runs. The gear turns 90° on hover and 180° under a press; the arrow 60° and 120°.
- Notices: snapshot banners and results that need reading (warnings, failures) wait in a dialog in
  the middle of the panel over the dimmed page, one at a time; any other dialog goes first. A
  dialog's answers are its action (filled), its second action, and "got it" where nothing else
  puts it away: that hides it while the notice lasts (the view model keeps the ids and forgets
  each once the notice goes), a result's "got it" dismisses the result. Clean results away from
  the current card, "switching back" (with a turning arc) and the panel's own confirmations
  (quota updated, version copied, backups folder opened) pass in a card in the middle that blocks
  nothing; it steps aside while a dialog is up. A confirmation fades after 1.9 s, a result when it expires. Results on the current card
  stay its result line. A clean switch or add, and a failed one, end in their own dialog instead
  (below); a removal the panel confirmed passes without Core's own word on it.
- Dialogs: one card in the middle of the panel, a picture over a title, a line of body where there
  is one, and full-width answers: the main one filled (clay; red when it removes an account),
  quieter text ones under it (red when they interrupt tasks or discard the new account, gray
  otherwise). Clicks in a dialog's first 0.6 s do nothing; Return is the main answer, Esc the way
  out. The switch's dialog goes from the question to its end without closing: the account in use
  and the target as buddies side by side with three dots running between, then "switch to X?"
  with "don't ask again" (only for a switch a click starts while "confirm switches" is on; Core's
  own switches never ask), the task guard's question (its title says how many Code tasks run, or
  that it could not tell; waiting shows a turning arc and what it waits for), compacting first,
  the four steps ticking off over a progress bar, done (a tick, the target perks up, the dialog
  stays 1.2 s) or failed (the step under way crossed out, the target sighs under a red "!", the
  reason, retry without asking or close). The add dialog shows closing Claude, signing in (cancel),
  importing history and opening Claude, then added (name, plan and channel, 1.4 s), the same
  account twice (keep both, discard the new one) or failed (retry, close). Rename: the name in a
  field, Return saves, Esc cancels, empty or over 20 characters says so under it. Remove asks
  first; on yes the card leaves at once and the passing confirmation offers undo for 4 s, and only
  then, once any operation under way has ended, is `.remove` sent. A second removal in that time
  sends the first at once and keeps its own 4 s.
- Settings: a back arrow and the centred title, then groups rising in one after another, each a
  small grey heading over a card. Appearance (system / light / dark, a segmented control whose
  highlight slides), Language (segmented), General (launch at login), Switching (confirm switches,
  on by default; auto-switch, an enabled control initially off; auto-sync),
  Compaction (auto-compact with the plugin's status under it: a breathing green dot when live,
  yellow when not heard from, gray "off"), dismissed accounts when there are any, Other (open the backups folder; quit, which asks inline
  first). A row with a switch flips it wherever it is clicked; its knob springs across and
  stretches under a press. The version line at the bottom copies itself through the pasteboard
  writer the app gives the view model (tests and previews give none).
- Height: the account page is as tall as it is, up to 720 pt or what the screen leaves below
  the menu bar (`PanelPlacement.heightLimit`), whichever is less. Past that the header,
  current card, suggested card and the add button stay in place and the account list
  scrolls under them (`PinnedTopLayout`), with a hairline between the two once it has scrolled
  on macOS 15 and later, which report the scroll offset; a top so tall that the list would get
  less than 160 pt scrolls in its own place instead. The settings page scrolls as a whole past the screen limit. An invisible
  copy of a shown dialog keeps the panel at least as tall as it. `SnapshotRenderer` sets `drawsStill`, which lays these parts
  out without scroll views, since ImageRenderer draws none.
- Motion (`Motion`): hover outlines and presses 0.15 s, a pressed card shrinking to 98 %; a dialog
  or the card menu pops in over the dimming page and the settings page slides in from the right,
  both on a short spring; a turning arc while a sign-in, tasks or a compaction are awaited
  (`ActivitySpinner`), and a light passing over the step under way on the switch's progress bar
  (`Sheen`), both placed from the clock at each frame. No height animates, as the window takes each new height in one step a moment after the
  content, which keeps to the top meanwhile: a result line or dismissed account that arrives gets
  its space at once and fades in over 0.22 s, and one that leaves fades out where it was before its space closes
  (`FadingRows`); quota bars, percentages and buddies follow a new reading over 0.45 s on a pass of
  their own, once the card has its new layout (`Following`), numbers rolling and faces
  cross-fading. A dialog and a passing confirmation pop in on a short spring; plan labels' light and
  flow and the compaction dot are placed from the clock (the light's `ShineSchedule` asks for
  frames only while it sweeps). With Reduce motion on in macOS nothing moves or fades and every change shows at
  once; `drawsStill` pictures stand still. While the panel is closed (`PanelViewModel.panelOpen`, set by
  the window) everything on it that moves on its own holds its frame (`motionPaused`: every timeline is
  paused) and goes on from the clock when it opens; unlike `drawsStill` nothing else changes, and a closed
  panel costs no processor time.
- Buddies: one rounded square for every account, drawn on a 36 pt design. Its face follows the
  5-hour remaining at the quota levels (ok big smile, fair small smile, mid slight frown, low
  half-closed eyes and a yawn) and its colour the weekly remaining at the quota levels; a used-up week is a gray
  sleeping buddy with a "z" whatever the 5-hour window says, and an account with no quota to show
  (signed out, awaiting sign-in, unreadable, nothing read) a gray one with a flat mouth. It is the
  card's figures that decide, stale ones included. It moves (`BuddyMotion`, drawn in a `Canvas`
  each frame): loops by mood (eyes, body and mouth: a bounce, a sway, a droop and jerk, a nod
  and yawn, a slow breath with a rising "z"), each account starting at its own point and pace;
  standing taller the more awake; eyes following the pointer, further the more awake; a hover
  reaction; one buddy at a time making a move of its own about every 2.2 s, picked by how awake it
  is; a perk when a new reading wakes it a level and a sigh when one tires it; an excited hop while
  a switch heads to it. Reduce motion and `drawsStill` keep it still.
- Suggested card (`Recommender`): only once the current account is out (under 10 % of its
  5 hours, week spent, or quota unknown) or there is none. While it can be used nothing shows: a
  switch restarts Claude and a long conversation is read again in full on the next account.
  Among the other accounts with weekly quota left and at least 10 % of their 5 hours, the one
  whose weekly limit resets on the nearest day as the reset line shows it (snapped minute, system
  time zone); same day: the larger 5-hour remaining, then the earlier reset, then registry order;
  a week that has not started counts as resetting seven days from now; a week under 5 % ranks
  after all of these, as a long conversation can use it up within minutes and Claude closes again.
  The reason line gives
  that day and why the current account is out (week spent, before 5-hour low; or quota unknown).
  No usable other account: the note "none ready". One account: nothing. An account being
  removed is not a candidate, nor a folder signed in to the current login (the same account and
  organization in its quota reading), which shares the current quota.
- `L10n`: one table with zh-Hans and en for every key; a test fails if any key misses a language.
  Core reports typed events and errors; the UI maps them to text.
- Text-fit test: every localized string is measured with the real font it is drawn in at its size and
  must fit its slot width at a 360 pt panel; the longest reset strings
  (`12月31日 周三 23:59`, `23:59 · 4 小时 59 分后`, `Wed, Dec 31, 23:59`, `23:59 · in 4h 59m`)
  are included.
- `SnapshotRenderer` renders fixture states (zh/en × light/dark, plus switching, task-guard,
  signed-out and waiting-for-sign-in states) to PNG for review.

## 13. Testing

- Core: unit tests with temp dirs; `SandboxFixture` builds realistic profile trees (buckets,
  `archived-sessions.idx`, `config.json` keys, `~/.claude/sessions` registry records,
  transcripts).
- Orchestration: `SwitchCoordinator` and friends end-to-end with in-memory fakes + real file IO
  in temp dirs, including every refusal path and the crash/relaunch-debt path.
- Platform: FakeClaude end-to-end, argv parsing, cookie decryption against vectors we generate,
  HTTP parsing from fixture JSON. No network, no keychain.
- Native recovery: capture tests use structured transcripts; injected process/registry/config
  tests reject stale runtimes, wrong profiles and PID reuse; coordinator and actual switch
  integration tests cover generation changes, source stops, rollback, sync failures and runtime
  binding. Plugin Node tests check claims and execution evidence; native hooks-host tests load
  the plugin without sending model requests. These do not establish a real account switch or
  successful restoration of a live task. Current evidence is recorded in
  [`native-work-continuity.md`](native-work-continuity.md).
- UI: view-model tests, L10n completeness, text fit, snapshot generation.
- `scripts/run-sandbox.sh` runs the full app against a generated sandbox (FakeClaude, fixture
  HTTP), safe on the developer machine.

## 14. App facade (the only surface the UI talks to)

Declared in Core (`Sources/CompanionCore/Facade/`), implemented by the orchestration layer
(`CompanionEngine`), consumed by `CompanionUI` view models and by fakes in UI tests, so the UI never
depends on how the orchestration works.

```swift
public protocol CompanionFacade: Sendable {
    /// Emits the full current snapshot immediately, then again after every change.
    func snapshots() -> AsyncStream<CompanionSnapshot>
    /// Never throws: outcomes arrive through the next snapshots (operation, lastResult, banners).
    func perform(_ action: CompanionAction) async
    /// For utility actions whose confirmation the panel shows: their actual result.
    func performWithReceipt(_ action: CompanionAction) async -> CompanionActionReceipt
}
```

- `CompanionSnapshot`: `accounts: [AccountSummary]` (registry order), `currentFolder`,
  `claudeRunning`, `operation: OperationState?`, `lastResult: OperationResult?` (with `id` and
  `finishedAt`, so the UI can show it once), `taskGuardPrompt: TaskGuardPrompt?`,
  `banners: [Banner]`, `pendingAdd: PendingAddState?`, `settings`, `appVersion`.
  `appVersion` is `AppVersion.display`: `CFBundleShortVersionString`, then the `CompanionRevision`
  that `scripts/build-app.sh` and `run-sandbox.sh` write into Info.plist (the short commit hash, with
  "+" for uncommitted changes, new untracked files included; empty outside a git checkout) in parentheses, as "0.1.0 (5d42a6f)".
- `AccountSummary`: `folder`, `displayName`, `status` (signedIn / signedOut / awaitingSignIn /
  unreadable), `email?`, `plan?`, `channel`, `quota: QuotaSnapshot?`, `quotaFreshness`
  (fresh / stale / refreshing / resetPassed / unavailable), `quotaFailure?` (why the latest read
  failed, shown with the last figures), `duplicateOf: ProfileFolder?`.
- `OperationState`: `switching(target, step, completedSteps)` with steps `compactingConversation`
  (only for a long conversation, §9 step 2), `closingClaude`, `syncingSessions`, `openingClaude`,
  `reopeningConversation`; `waitingForTasks(target)`;
  `addingAccount(phase)` with phases `closingClaude`, `waitingForSignIn`, `importingHistory`, `openingClaude`; `removing(folder)`; `autoCorrecting`.
- `OperationResult`: `switched(to, warnings)`, `added(folder, warnings)`, `removed(folder,
  partialCleanup)`, `failed(operation, reason: FailureReason)`; `warnings` and
  `FailureReason` are enums the UI localizes (no free text from Core). `OperationWarning` includes
  `notCompactedFirst`, `workContinuationUnavailable`; `FailureReason` includes `returnedToPreviousAccount`,
  `transferFailedReturnedToPreviousAccount`, `transferFailedNotReopened` and `targetCannotContinue`.
- `TaskGuardPrompt`: `target`, `busyCount`, `unknown: Bool`, `isWaiting: Bool`.
- `Banner`: `foundAccount(folder)`, `autoCorrected(to)`, `autoCorrectPaused`, `autoSwitchPaused(reason)`,
  `autoSwitchNeedsBypass(account)`, `watchesStayed(account, titles)` (conversations whose comment watch stays with
  that account, shown while another account is current),
  `historyImportPaused(folder, issue)`, `nativeRecovery(summary)`, `quotaUnavailable` (the keychain refused the key that
  decrypts the sign-in cookies; its retry sends `refreshQuota(nil)`).
- `CompanionAction`: `switchTo(folder)`, `taskGuard(.waitThenSwitch | .switchNow | .cancel)`,
  `skipCompaction`,
  `addAccount`, `cancelAddAccount`, `resolveDuplicateAdd(.keepBoth | .discardNew)`,
  `rename(folder, name)`, `remove(folder)`, `addFoundAccount(folder)`, `dismissFoundAccount(folder)`,
  `retryHistoryImport(folder)`, `refreshQuota(folder?)`, `panelOpened`, `setAutoSync(Bool)`, `setAutoSwitch(Bool)`,
  `setAutoCompact(Bool)`, `setLaunchAtLogin(Bool)`, `setLanguage(AppLanguage)`,
  `setAppearance(AppAppearance)`,
  `openBackupsFolder`, `openRecoveryFolder`, `dismissResult(id)`, `quitApp`.
- `CompanionActionReceipt`: `quotaRefresh(updated, requested)`, `backupsOpened`,
  `recoveryFolderOpened`, `failed`, `notPerformed`, `unreported`.

## 15. Scope of v1

v1 is the one-click switching experience, with the initial history import for a new account
(and the Code "bypass permissions" preference inheritance) and the low-quota Code compaction
(§10) with its Settings switch, plus native work continuity (§9a). **Not built in v1:** merging duplicate profiles, diagnostics
export, system notifications.
