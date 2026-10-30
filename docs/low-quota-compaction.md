# Low-quota Code compaction

Goal: a long Claude Desktop Code conversation is compacted **on the account it is on, before that
account runs out of usage**. Prompt caches belong to an account, so continuing an uncompacted
conversation on another account re-reads all of it there; compacting while the old account's cache
is warm costs a fraction of that (about 0.1 × the context to read it from cache, plus the summary)
and the new account then only writes the short summary.

## Who does what

- **The plugin** (`Plugins/cc-relay`) runs inside every Desktop Code
  conversation, reads that conversation's own usage figures after every reply and at every step
  of a long task, and compacts it itself. It needs neither CC-Relay's web quota reads nor
  CC-Relay running.
- **CC-Relay** writes the plugin's switch and language, shows whether the plugin reports, and
  shows and logs each compaction.

Everything they share lives in `~/Library/Application Support/CC-Relay/AutoCompact/`: numbers,
plus the host's one-line reason when a compaction did not happen, never conversation text:

| File | Writer | Content |
| --- | --- | --- |
| `settings.json` | CC-Relay | `enabled`, `minContextTokens` (100 000), `language` (`zh-Hans` or `en`). Missing: on, English. Never named `config.json`: profile scanners take a folder holding one for a Claude profile. |
| `sessions/<sessionID>.json` | plugin | Status every 30 s and after every reply: context tokens, the window nearest its limit and its percent used, both lines, busy, state, and `switchRequests: true` (it answers a request before a switch). |
| `results/<finishedAt>-<sessionID>.json` | plugin | One per compaction: trigger (`early` / `hard` / `switch`), status (`compacted` / `skipped` / `failed`), tokens before and after, percent before and after, whether a paused task was resumed, for one skipped or failed, or a paused task that could not go on, the host's reason on one line (`error`, at most 200 characters), and `trace`: what the host did in fixed words (the command `resolved` / `rejected` / `timed out`; the hook saw it `compacted` / `skipped` / `failed` / `not seen`). CC-Relay moves each to `results/seen/` once reported. |
| `test-request.json` | by hand | `{ id, sessionID, until }`: a one-time test, see below. The plugin never removes it. |
| `switch-request.json` | CC-Relay | `{ id, sessionID, until }`: compact this conversation now, before a switch; no compaction begins for it past `until`. See below. CC-Relay removes it once the switch goes on. |
| `switch-result.json` | plugin | `{ id, sessionID, status: 'compacting', startedAt }` once the compaction for the request has begun, then `{ id, sessionID, status, tokensBefore, tokensAfter, error, startedAt, finishedAt }`: the answer to the last request before a switch. |
| `lock.json` | plugin | A five-minute lease, so conversations on the same Mac compact one at a time. While the owner's `/compact` still runs, past the 15-minute timeout too, it renews the lease every half minute for at most 30 minutes and gives it back when the command ends; a conversation that is gone lets it lapse within five minutes. |

## When the plugin compacts

Only in Desktop Code sessions (`session.start` not interactive, `CLAUDE_CODE_ENTRYPOINT` is
`claude-desktop`), and only a conversation with at least `minContextTokens` of context whose own
last model request was within the last hour (older, its cache is gone and compacting would
re-read everything). A turn counts, and so does every tool call of the conversation
itself, so a task that runs for hours in one turn stays recent; a subagent's tool call (it
carries `agentId`) does not, since it says nothing about the conversation's own cache. The
usage window that decides is whichever of `five_hour` and `seven_day` is closest to its limit.

- **Early line** (88 % used, 12 % left): after the reply that ends at or above it, the conversation is
  compacted between turns. A conversation idle but recently used is compacted on the 30-second
  timer when usage crosses the line through other work. An early compaction that waited for
  another conversation's lease and finds a turn begun meanwhile gives way: its `/compact`
  would wait behind the whole turn, and the turn's hard line would be blind until then. The next
  reply tries again.
- **Hard line** (92 % used, 8 % left): for a long task still running. At the next tool call (the tools
  of the previous step have finished) the plugin ends its own turn with `$.turn.abort`, refuses
  that tool call, compacts, and submits `[Continuation pauseID=…]` followed by one English sentence:
  "Please continue the unfinished work from where it was interrupted, following the original
  instructions and scope of authorization." The prompt is the same in both interface languages;
  compaction outcomes stay in the local result and the app's notice. The task resumes whether or
  not the compaction worked; after a failure it tries twice more, 10 s apart. The switch is read
  again right before a turn is stopped, so one just turned off stops nothing, and several tool
  calls of the same step stop it once, with one prompt to go on. The prompt goes out
  before anything else that could fail (learning the cost, writing the result); when the host
  refuses it (a rejected call or a returned `drop`), or returns no valid acceptance receipt,
  the result says so (`resumed: false`, `error` starting `the task could not be
  resumed:`), also for a task that found the window's compaction already done. When the guard of
  the turn that prompt starts fails, that turn is stopped too, and unless the person took over the
  task is reported the same way: in the compaction's result, or, if that already said it went on,
  in a second result that says it did not. A paused task
  waits for a compaction the person or the engine is running, and one that ended after the pause
  counts as done, so the plugin continues the task without compacting again.
- **How it compacts**: it runs `/compact` through `$.command.run({ command: 'compact' })`,
  as if the person typed it; the host queues the command until the conversation is idle. The
  plugin's own `session.compact` hook passes every compaction through unchanged and notes what the
  one it asked for did: a summary, a veto and its reason, or an error. The same hook counts every
  compaction of the conversation itself while it runs, so no `/compact` is asked for while the
  person's or the engine's own is under way; one the plugin queued earlier is skipped, with one
  line saying so, when another compaction ended before it could run, and counts as compacted (its
  trace says `compacted meanwhile`). A conversation that shrank to less than half counts as compacted too. A
  `/compact` that has not finished after 15 minutes is given up and ends the window's attempts,
  since it may still be queued. `$.session.compact` is not called directly: Desktop refuses it,
  idle or not.
- **Lines only move earlier** (compaction must finish on the old account): the
  plugin learns what a compaction costs (percent of the window per 100 000 tokens, from the usage
  before and after each one, kept in `$.store`) and watches how fast usage rises. A rise counts
  only when the new figure comes within two minutes of the previous one first appearing, and only
  for 30 minutes. An idle conversation's figure may not refresh, so a rise that piled up while it
  sat idle, or while the Mac slept, is not taken for one step. With `need` = estimated cost + the
  largest rise still counted, the early line is `min(88, 100 − clamp(3 × need, 8, 25))` and the
  hard line `min(92, 100 − clamp(1.5 × need, 4, 15))`. Before the first measurement a cost of 4 %
  is assumed, which gives exactly 88 and 92 once no rise counts; only a costly compaction (a very
  long conversation) keeps them earlier. Nothing starts at 99 % or more.
- **Once per window**: per conversation and window reset, at most three attempts and never again
  after one that compacted or that another hook declined. The mark says which, so a
  paused task that finds the window done is told truthfully whether that attempt compacted.
  Attempts are counted before the call, so a crash cannot turn into repeated summaries. A queued or retried attempt checks again right
  before it starts that the conversation still qualifies (the switch, the usage and its window,
  the size, the line); one that no longer does is recorded as `skipped`, and a paused task goes on
  without a command. A conversation never starts a second `/compact` while its last one has not
  ended.
- **Test request**: to see the whole automatic flow without waiting for a limit, a
  `test-request.json` names one conversation and an expiry (`until`, milliseconds, about ten
  minutes ahead). Until then that conversation's early line is 0 and nothing else changes: the
  switch, the 100 000-token minimum, a turn within the hour and once per window still decide. So
  it compacts after its next reply, or on the half-minute check when it is idle but recent, and
  CC-Relay shows and logs it like any early compaction. The result carries the request's id as
  `test`. Afterwards the line is back where it belongs.
- **Before a switch**: when CC-Relay is about to move a conversation of at least 300 000 tokens
  to another account, it names it in `switch-request.json`, with `until` 170 s ahead: no
  compaction begins for it after that. The conversation looks for a request every 2 s and
  compacts at once, whatever its usage and whether or not it was compacted this window; each
  request is answered once. The switch, the 100 000-token minimum, a turn within the hour, a turn
  running and the 99 % stop still decide, and a refusal is answered at once as `skipped` with its
  reason. Another conversation's lease is waited for until `until` (`failed`), and a lease taken past
  `until`, as after the Mac slept during the wait, begins nothing either; once it is free,
  these are checked again before the compaction begins, since the account may have reached 99 %
  meanwhile. A compaction that begins, the request's own or one already under way in the
  conversation (the person's own `/compact` included), is first reported in
  `switch-result.json` as `compacting`, and then waited for to its end rather than cut short, as
  long as CC-Relay keeps the request; one taken back is answered `skipped` (the switch went on
  without it), and nothing begins once it is. Meanwhile the early and hard lines keep out. The
  host gives no context size between a compaction and the next response, so a conversation
  compacted with no response since, by the plugin or the person, is answered `compacted` with the
  size that compaction reported, also when a task paused for it has begun its turn again.
  The answer then replaces the `compacting` line, and a compaction it ran is also recorded in
  `results/` with trigger `switch`. It goes out whatever fails on the way: a cost or a record
  that cannot be kept leaves it as it is, and any other failure is answered `failed` with its
  reason.
- **No instructions**: the command is a bare `/compact`; text after it would show in the
  conversation as if the person had written it. Claude Code's own summary already keeps the task's goal and progress, the files, the
  decisions, what is still open and the person's messages.

## CC-Relay's side

- `AutoCompactLink` writes `settings.json` at startup and whenever the switch or the language
  changes, reads the session statuses (a conversation that reported within 120 s is live) and takes
  new results.
- Each scan logs one line per new result (`Auto-compact (hard line, task paused and resumed):
  compacted, 812000 -> 74000 tokens.`; one that did not compact ends with `Reason: …`, masked like
  every log line) and shows the newest as a notice (a dialog in the middle of the panel) until the panel has shown it and closed, or the user puts it away. A declined compaction shows no banner; a failed one asks the user to send `/compact`; a paused task that was not resumed always shows a warning that asks the user to tell it to go on, after sending `/compact` when the compaction failed. One made before a switch shows a banner only when it compacted (the switch result covers the rest), and still on the next opening of the panel, since Claude coming back to the front closes it.
- Before a switch, when the plugin is on, Claude is open, no task is running (or the wait for one
  is over), and the conversation to continue has at least 300 000 tokens by its transcript and
  is reported live by a plugin with `switchRequests` (an older one would never answer, so it is
  not asked and the switch says the conversation was not compacted), the switch writes
  `switch-request.json`, shows "compacting
  first" on the target card with a sheet that can skip it, and waits up to three minutes for
  `switch-result.json` with that id to answer or say `compacting`. Once a compaction has begun
  it waits up to ten more minutes for the answer, since closing Claude under a `/compact` would
  throw away what it has done. Then it removes the request and goes on, whatever the answer,
  after asking again about running Code tasks, since one may have begun during the wait. A conversation that was not compacted, unless the user skipped, adds one line to the
  switch result, and the switch's log line says how the compaction went. Quitting CC-Relay
  during the wait calls the switch off, with Claude left as it was.
- Settings shows, under the switch, "plugin connected", "last reported at HH:mm" or "no report yet", and "off" while the switch is off.

## Claude Code interface used

Only calls declared in Claude Code's published type declarations
(`mods/types/claude-code.d.ts` in `anthropics/claude-code`) and described in the public proposal
(anthropics/claude-code#91870): the events `session.start` (`isInteractive`), `turn.start`
(`turnId`), `turn.complete`, `turn.abort`, `tool.call` (answered with `{ deny }`) and
`session.compact` (passed through), and the calls `$.session.id`, `$.session.usage`
(`context.tokens`, `rateLimits[].kind / percentUsed / resetsAt`), `$.command.run({ command })`
("queued and run once the session is idle"; `args` "may be left out"; it rejects inside a hook the
turn is waiting on, so the plugin calls it from a timer), `$.turn.abort({ turnId })` ("a hook may
end its own turn"), `$.prompt.submit({ text })`, `$.fs.read` / `$.fs.write`, `$.clock.now` / `after` / `every`,
`$.store.get` / `set` and `$.env.get`. The host lets a hooks module make only the calls its source
scan found (the engine says so in `claude plugin test`), so the plugin spells each call out as
`$.noun.verb(…)`, never through an alias.

## Setup

The plugin uses Claude Code's hooks-module ("mods") feature, which Anthropic can switch off
remotely. Run `scripts/install-plugin.sh` with `CLAUDE_CLI` set
to a Claude Code CLI if `claude` is not on `PATH` (`CC_RELAY_MARKETPLACE` can point at the
installed app's `Contents/Resources/Plugins`). The script validates the plugin, keeps a dated
backup of `~/.claude/settings.json`, sets `CLAUDE_CODE_ENABLE_FUNCTION_HOOKS=1` there and installs
the plugin. Conversations started afterwards load it.

## Verification

- `node --test Plugins/cc-relay/tests/*.test.js` runs the plugin against a fake `$`:
  early line, hard-line pause and resume, idle and short conversations, the 99 % stop, the switch,
  waiting for another conversation's lease, the check again before a queued start, an early
  compaction giving way to a turn begun while it waited, a task over an hour in one turn, a
  paused task behind a declined compaction, a paused task that goes on even when the cost of its
  compaction cannot be kept and one that cannot be told to go on, the switch read again before a
  pause, two tool calls of one step stopping it once, one `/compact` at a time per conversation, the lease
  kept while a command runs, retries, the self-adjusting lines, and every way `/compact` can
  answer (compacted, vetoed, failed inside, refused, ended without compacting, never ending) with
  the reason kept for each; and the request before a switch: answered once, for its own
  conversation only, refused at once when it cannot be met, waiting for a running compaction or
  another conversation's lease and giving up on either when it expires, let go when taken back
  meanwhile, an early attempt and the hard line staying out while it runs, and compacting again
  within a window.
- `claude plugin test Plugins/cc-relay` runs `tests/engine.test.ts` in Claude Code's own
  hooks engine: one early-line compaction through a bare `/compact`, a hard-line pause that
  compacts and resumes, and a compaction passed through unchanged. Hooks in a test may make no calls of their
  own, so its stand-in `/compact` shrinks the conversation directly instead of raising
  `session.compact`.
- `scripts/test.sh` covers CC-Relay's side (`AutoCompactLinkTests`, engine and panel tests).
- A test request shows the whole flow at any usage (pick an unimportant
  conversation of at least 100 000 tokens, send it a message, then name its session in
  `test-request.json`); a real
  limit shows the 88 % and 92 % lines themselves (`docs/手动测试清单.md` §11). When it does not compact, the result's `error` and `trace` say why.

## Limits

- Desktop Code conversations only; terminal `claude` sessions are left alone.
- Compaction costs some usage itself, which is why it happens early; at 99 % it is not started.
- Ending a turn stops tools the turn still has running, such as a background command.
- Two conversations that take the lease in the same instant can still both compact. A lock
  without expiry is not used: a conversation that dies while queued, and Claude quits on every account switch, would block
  every other conversation until someone cleared it by hand.
- If Anthropic switches hooks modules off, the plugin stops reporting and Settings shows the last
  report time; the user then compacts by hand.
