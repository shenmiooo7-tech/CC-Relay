# CC-Relay: compaction and native continuity

One hooks entry point loads two modules: the quota compactor, which reports a paused task as
still paused when the host drops its continuation prompt, and native continuity, which lets work in a Claude Desktop Code conversation go on in the same
conversation after CC-Relay switches the account. No new tool and no separate task workflow
are involved; the conversation keeps using its own Bash, Monitor, Agent and Artifact tools.

Compaction and account-switch continuations share the same English sentence: "Please continue
the unfinished work from where it was interrupted, following the original instructions and scope
of authorization." Their request markers use `Continuation`, without a project name. Compaction
outcomes remain in the app's notice and local results.

## Reporting

In every Desktop conversation the module identifies its Claude CLI parent PID and the matching
Desktop session registry entry, and reports busy state, a user stop and the live inventory of
background Bash, Monitor and agent tasks. A report is a candidate, never proof of identity:
CC-Relay validates the PID, process birth and owning profile itself. Changes are reported as
they happen and a heartbeat proves the runtime every five seconds.

The plugin also reports exhausted five-hour/weekly windows and the host's typed
`classic.StopFailure(error: rate_limit)` event. CC-Relay's opt-in Auto-switch setting uses these
verified reports to switch accounts and resume the original conversation. Network failures,
server overload and quoted error text are not limit signals. A user's stop withdraws the signal;
a successful new turn clears a prior rate-limit failure. The source plugin never retries model
work merely to test the limit. `session.measure` reports changing quota immediately, with the
five-second heartbeat as a fallback. A turn that fails with `account_on_hold` or
`oauth_org_not_allowed` is reported as `accountRestricted`, which outweighs any limit signal: CC-Relay
then does not switch by itself. A person's stop does not withdraw it; a reply that gets through does,
and it lapses after a day.

## Protected background commands

A background Bash command or command Monitor is handed to the bundled
`bin/CompanionNativeWorker` only when the person's rules or mode allow its original input
outright and no PreToolUse hook is configured. Everything else runs exactly as it would without
this plugin, so the permission dialog, the auto-mode classifier and the policy see the real
command; such a command stops with Claude and the local recovery receipt records it.

For an enrolled command:

- The permission check of the wrapper is decided by the original: it is allowed without a
  dialog, refused when the wrapper itself is refused, and not started when the original would
  now ask.
- The native shell writes its functions and aliases into the job's private folder; the worker
  loads them into the same kind of shell, deletes them and runs the original text once, in the
  inherited working directory, environment and shell sandbox. A trailing comment keeps the
  original's first line visible in the task list.
- Clients only stream output. A stop through the interface or TaskStop ends the whole owned
  process group and must be acknowledged. Worker and clients wait on events, not timers.
- When Claude closes for a switch, an exit permit keeps the command alive until the target
  conversation attaches its native tool to the same process and output. Reattaching requires the
  original to be allowed outright there too; otherwise the command is stopped.

## Continuing after a switch

The module acts only on a request armed for its exact runtime instance, and saves and reads back
a claim before doing anything. Then it restores concrete work first: protected commands are
reattached, WebSocket monitors are recreated from their one verified original call with the
remaining deadline (when compaction or the host's message limit hides that call, the worker reads
it from the full transcript on the verified branch, in memory only), interrupted agents are resumed by ID through `SendMessage`, and armed
Artifact comment watches are checked at their original URL. Socket connection and automatic
comment replies are verified separately; when replies were previously armed, one ordinary
`ArtifactComments watch` reattaches them if the native session's user-turn, named-link, consent
and editor conditions allow it, then inventory is checked. `resume_replies` only reverses a
recorded stop and is not used to repair an unwired connection. Native refusal or a watch without
reply wiring stays an attention result; a successful tool receipt alone never proves recovery.
Stopped watches, declined permissions and another live responder are respected. Artifacts are
never republished by recovery. Monitor events of an agent go back to that agent once its continuation
is accepted. Finally the original conversation receives a `[Continuation requestID=…]` marker and
one sentence: "Please continue the unfinished work from where it was interrupted, following the
original instructions and scope of authorization." Full work snapshots and recovery evidence stay
in the local request and result files, rather than being appended to the prompt. The host puts
a line naming the sender before a plugin's prompt and before a message to an agent; the turn is
recognised by the marker that follows it, and a person quoting the marker inside their own words
starts no automatic turn.

A conversation with only armed Artifact watches stays closed during a switch: the page belongs to
the account that published it, which the target account cannot open. CC-Relay starts it again,
for the watch alone, the next time it opens that account, when this plugin reported
`watch-reopen-v1`: it marks the conversation for Desktop to start and leaves a one-time note at
`NativeRecovery/watch-reopen/<sessionID>.json`, naming that account. The plugin uses the note as
the conversation starts, unless it can tell that it runs on another account, and drops Desktop's continue that follows within two minutes, so no model
turn begins; the ordinary reopen below restores the watch. That reopen restores only the watches
kept for the account the conversation runs in, and leaves those kept for any other: the account is
the one the note names, or the one `NativeRecovery/open-accounts.json` lists for the Claude among
the runtime's parent processes, matched by PID and start time read with `ps`. Unknown, every kept
watch is left for now, and the reopen looks again every 30 seconds for six minutes, as CC-Relay
lists an open Claude within five. An ordinary reopened
conversation needs no switch ticket: after allowing ten seconds for the host's own restoration,
the worker reads its unique original transcript and persisted native monitor intent, including records absent from compacted
in-memory history. Already restored watches are left alone. Connecting watches receive at most
six checks ten seconds apart; mutation calls are not repeated. The native host can report
`connected: true` with `connecting: true` before its handshake is complete. That remains waiting,
with replies not yet ready; only a completed handshake can confirm restoration. Six unconfirmed
checks end with an attention result. Reopen receipts are saved under
`NativeRecovery/artifacts/<sessionID>/<instanceID>.json`; an incomplete recovery also shows a
native toast. A connected watch alone never counts as restored automatic replies. The native
host may require approval or refuse to enable replies; that result remains visible and no
permission check is bypassed.

An unwired watch receipt does not erase the original automatic-reply intent. An explicit or
persisted stop does clear it. Pure-watch recovery only confirms an existing connected watch whose
native inventory explicitly reports `auto_reply: none`. The current host has no guaranteed
watch-only creation option: an ordinary `watch` can implicitly arm replies from prior consent,
and `replies: false` is not an opt-out. A missing pure watch or an unconfirmed reply state therefore
needs attention without a mutation; an existing responder is left unchanged. Reply-only restrictions
do not prevent read-only confirmation of an existing pure watch.
Startup transcript reads retry up to three times ten seconds apart; exhausted failures produce
an attention receipt and one toast with the actual reason. A fresh session without an original
transcript stays quiet. Directory enumeration, bucket lookup and transcript read permission errors
are failures, not empty new sessions, so they follow the same retry and error path.

Reopen and switch tests in Claude Code's own test host cover pure watches and automatic replies
through handshake completion and timeout. Startup retry tests run the compiled worker against
directories with actual OS read-permission failures. Neither replaces a real-account
comment/reply test.

Claude Desktop sends a conversation whose turn its quit interrupted a request of its own to
continue, under the person's origin. That request is not taken for the person's words. While a
switch's continuation for the conversation is on its way to this runtime, it is held back and the
continuation takes its place, so the work goes on once, with what survived the switch attached
again. It goes out after all when nothing claims the continuation within two minutes or the
continuation needs no prompt, and a continuation claimed after that gives way. A conversation
CC-Relay started for its comment watch alone drops it once, as above.

Completed work and explicit stops are never revived, and an automatic continuation never runs an
original command again. A newer user instruction, or the person's stop during the continuation,
supersedes it: its tools are blocked even if cancelling its turn fails, and its receipt says
`yielded`, which CC-Relay does not report as a problem. A message the person sends over the
continuation's running turn, one queued to wait its turn or a command included, stops that turn,
so the message runs in a turn of its own. A step that fails inside the continuation, and a
reattached command that later fails or is stopped, are results of the work, not of the
continuation. The compactor's own pause is told apart by its host origin and turn.
Claims, receipts and statuses (`queued`, `executing`, `turnFinished`, `inspected`, `yielded`,
`needsAttention`) are distinct and none certifies the original task complete. A final receipt
stays as it is when the person writes or stops afterwards, whatever a resumed agent's blocked
tools or a stale turn do then, and a comment watch still connecting is no longer waited for; the
receipt still records that the person took over (`revoked`), so the worker attaches nothing more.

## Files

Claims, receipts and reports live under
`~/Library/Application Support/CC-Relay/NativeRecovery`. Protected commands keep their
one-time specification, output, cursor and permits in an owner-only folder under
`/private/tmp/cc-relay-native-<uid>/`, located through `commands/<job-id>/location.json`.
No credential or environment snapshot is written. CC-Relay removes finished records later.

## Compatibility

Requests carry `requiredCapability: native-recovery-v6`, which this module reports; commands
need worker execution protocol 3. The plugin and its worker ship together; source installs stage
a complete marketplace with a built worker before the normal install. Commands started before
the module was loaded cannot be protected afterwards.

## Tests

`node --test tests/*.test.js` covers ticket binding, claims, duplicate prevention, the
protection and permission rules, user stops and execution evidence; the worker suite runs the
real worker against private fixture processes and a local WebSocket server, so build it with
`scripts/test.sh` first. `claude plugin test` loads both modules through the hooks host without
sending model requests. None of these establishes that a real account switch has been accepted.
