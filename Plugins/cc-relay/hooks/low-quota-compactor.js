// Compacts a long Claude Desktop Code conversation on the account it is on, before that account's
// usage limit is reached, so the conversation is not re-read in full on the next account. It reads
// this session's own usage figures and writes to CC-Relay's folder a status the app shows
// and one result per compaction: numbers, plus the host's short reason when one fails, never
// conversation text. CC-Relay's switch is settings.json there (never config.json: profile
// scanners take a folder holding one for a Claude profile); a test-request.json there lowers one
// named conversation's early line to 0 for a few minutes, to show the whole flow at work; a
// switch-request.json there asks for one conversation to be compacted now, before CC-Relay
// moves it to another account.

import { PLUGIN_VERSION as VERSION } from './version.js'
import { CONTINUATION_TEXT } from './continuation-text.js'

const TICK_MS = 30_000
// An hour without a request of the conversation itself (a turn, or a tool call within one) and the
// prompt cache is gone: compacting would re-read everything.
const RECENT_MS = 60 * 60_000
const LOCK_MS = 5 * 60_000
const RETRY_MS = 2_000
// Waiting for another conversation's compaction may take its whole lease.
const WAITS = LOCK_MS / RETRY_MS
// After a failed compaction a paused task tries this many more times, then goes on without one.
const FAILURES = 2
const FAILURE_RETRY_MS = 10_000
// /compact runs once the conversation is idle and a long one takes minutes; this long means stuck.
const COMMAND_TIMEOUT_MS = 15 * 60_000
// A /compact still running keeps the lease renewed for up to this long; after that it counts as lost.
const HOLD_MS = 30 * 60_000
const TIMED_OUT = Symbol('timed out')
const FIRST_TRY = { waits: 0, failures: 0 }
const ATTEMPTS = 3
// The user's lines: compact with 12 % of the window left, stop a long task with 8 % left. They
// only ever move earlier, when a compaction is measured to need more room than that.
const EARLY_LINE = 88
const HARD_LINE = 92
// Until a compaction has been measured, assume one costs this many percent of the window.
const ASSUMED_COST = 4
// Past this point a compaction would most likely be cut off by the limit itself.
const LAST_START = 99
// Two readings this close together measure how fast usage is going; across a longer gap (the Mac
// asleep, use on another device) a rise says nothing about the next step.
const STEP_GAP_MS = 2 * 60_000
// A fast rise moves the lines earlier for this long; then they return to 12 % and 8 % left.
const STEP_MEMORY_MS = 30 * 60_000
const WINDOWS = new Set(['five_hour', 'seven_day'])
const DEFAULTS = { enabled: true, minContextTokens: 100_000, language: 'en' }
const TEST_FILE = 'test-request.json'
const SWITCH_FILE = 'switch-request.json'
const SWITCH_RESULT_FILE = 'switch-result.json'
// CC-Relay waits on the answer before it closes Claude, so the request is looked for this often.
const SWITCH_POLL_MS = 2_000
// Stamped by the native prompt ingress; plugin prompts and task notifications are not user input.
const USER_ORIGINS = new Set(['composer', 'bridge', 'sdk'])
const RESUME_MARKER = /^(?:The cc-relay plugin sent a message:\s*)?(?:\[(?:Continuation|CC-Relay 原任务续接) requestID=[A-Za-z0-9_-]{1,128}\]\s*)?\[(?:Continuation|CC-Relay 自动压缩续跑) pauseID=([a-f0-9-]{36})\](?:\n|$)/
function resumeID(value) { return typeof value === 'string' ? RESUME_MARKER.exec(value)?.[1] : undefined }
function failedHook(state, event, next) {
  // Never copy the host's exception message, which may include prompt or command text.
  state.hookFailure = { event, kind: next.error?.kind === 'timeout' ? 'timeout' : next.error?.kind === 'throw' ? 'throw' : 'unknown' }
}

const TEXTS = {
  'zh-Hans': {
    pause: '已暂停：当前账号的额度快用完了，先压缩上下文，压缩后会自动继续。',
    compactedMeanwhile: '对话刚压缩过，这次不再重复压缩。',
    superseded: '原任务的自动压缩续跑已让位于新的用户指令或停止操作。',
    quotedPrompt: '以下为本次提交的原文（其中的续跑标记仅作文本）：\n',
  },
  en: {
    pause: 'Paused: this account is close to its usage limit. The context is compacted first, then the task goes on.',
    compactedMeanwhile: 'The conversation was just compacted, so it is not compacted again.',
    superseded: 'This automatic compaction continuation yielded to a newer user instruction or stop.',
    quotedPrompt: 'The following is the text submitted in this prompt (its continuation marker is text only):\n',
  },
}

function folder(state) {
  return `${state.home}/Library/Application Support/CC-Relay/AutoCompact`
}

function text(state, key) {
  return (TEXTS[state.config.language] ?? TEXTS.en)[key]
}

function clamp(value, low, high) {
  return Math.min(high, Math.max(low, value))
}

async function readJSON($, path) {
  try { return JSON.parse(await $.fs.read(path)) } catch { return undefined }
}

/** A host message cut to one short line: enough to tell why something failed. Never throws. */
function shortReason(value) {
  let message
  try {
    message = typeof value === 'string' ? value : typeof value?.message === 'string' ? value.message : String(value)
  } catch {
    message = ''
  }
  return message.replace(/\s+/g, ' ').trim().slice(0, 200).trimEnd() || 'no reason given'
}

/** Settles like `promise`, or with TIMED_OUT when `ms` pass first. */
function within($, ms, promise) {
  return new Promise((resolve, reject) => {
    $.clock.after(ms, () => resolve(TIMED_OUT))
    Promise.resolve(promise).then(resolve, reject)
  })
}

function delay($, ms) {
  return new Promise(resolve => $.clock.after(ms, () => resolve()))
}

async function readConfig($, state) {
  const value = await readJSON($, `${folder(state)}/settings.json`)
  const config = { ...DEFAULTS }
  if (value !== null && typeof value === 'object') {
    if (typeof value.enabled === 'boolean') config.enabled = value.enabled
    if (Number.isFinite(value.minContextTokens) && value.minContextTokens >= 0) config.minContextTokens = value.minContextTokens
    if (Object.hasOwn(TEXTS, value.language)) config.language = value.language
  }
  state.config = config
}

/** The usage window closest to its limit decides. */
function nearestLimit(usage) {
  let nearest
  for (const limit of usage?.rateLimits ?? []) {
    if (!WINDOWS.has(limit?.kind) || !Number.isFinite(limit.percentUsed)) continue
    if (nearest === undefined || limit.percentUsed > nearest.used) {
      nearest = { kind: limit.kind, used: limit.percentUsed, resetsAt: limit.resetsAt ?? null }
    }
  }
  return nearest
}

/**
 * Both lines leave room for the compaction itself plus the largest quick rise of the last half
 * hour, so the last step before the limit cannot overshoot it, and never sit later than the
 * user's lines. The early line acts after a reply; the hard line stops a long task between two steps.
 */
function linesFor(calibration, tokens, stepMax) {
  const cost = Number.isFinite(calibration?.per100k) ? calibration.per100k * tokens / 100_000 : ASSUMED_COST
  const need = cost + stepMax
  return {
    early: Math.min(EARLY_LINE, 100 - clamp(3 * need, 8, 25)),
    hard: Math.min(HARD_LINE, 100 - clamp(1.5 * need, 4, 15)),
  }
}

function markKey(state, limit) {
  return `window:${state.sessionID}:${limit.kind}:${limit.resetsAt ?? 'unknown'}`
}

/** Remembers how far usage rose between two close readings, for the last half hour. */
function observe(state, limit, now) {
  const last = state.lastLimit
  const sameWindow = last !== undefined && limit !== undefined && last.kind === limit.kind && last.resetsAt === limit.resetsAt
  // An unchanged figure keeps the time it first appeared: it may not refresh while the conversation
  // sits idle, and a rise that piled up meanwhile is not one quick step.
  if (sameWindow && limit.used === last.used) return
  if (sameWindow && limit.used > last.used && now - state.lastLimitAt <= STEP_GAP_MS) {
    state.steps.push({ at: now, size: Math.min(20, limit.used - last.used) })
  }
  state.lastLimit = limit
  state.lastLimitAt = now
}

/** The largest rise of the last half hour; older ones no longer count. */
function recentStep(state, now) {
  state.steps = state.steps.filter(step => now - step.at <= STEP_MEMORY_MS)
  return state.steps.reduce((largest, step) => Math.max(largest, step.size), 0)
}

/** What a compaction would act on now, or undefined when this session should be left alone. */
async function plan($, state, usage, now, ownAttempt = false) {
  // Never a second /compact in a conversation whose last one has not ended, and none while the
  // conversation is being compacted by anyone: the person's /compact, or the engine's own.
  if (!state.enabled || !state.config.enabled || state.command !== undefined || (state.compacting && !ownAttempt)
    || state.compactions > 0) return undefined
  const tokens = usage?.context?.tokens
  if (!Number.isFinite(tokens) || tokens < state.config.minContextTokens) return undefined
  const limit = nearestLimit(usage)
  if (limit === undefined || limit.used >= LAST_START) return undefined
  if (limit.resetsAt !== null && Date.parse(limit.resetsAt) <= now) return undefined
  if (state.lastActivityAt === undefined || now - state.lastActivityAt > RECENT_MS) return undefined
  const mark = await $.store.get(markKey(state, limit))
  if (mark?.done === true || (mark?.attempts ?? 0) >= ATTEMPTS) return undefined
  state.lines = withTest(state, linesFor(await $.store.get('calibration'), tokens, recentStep(state, now)), now)
  return { tokens, limit, lines: state.lines, test: testing(state, now) ? state.test.id : undefined }
}

/**
 * A one-time test asked for by hand: `test-request.json` in CC-Relay's folder names one
 * conversation and an expiry (`{ id, sessionID, until }`). Until then that conversation's early
 * line is 0 and nothing else changes, so the normal flow compacts it after its next reply.
 */
async function readTest($, state) {
  const request = await readJSON($, `${folder(state)}/${TEST_FILE}`)
  const mine = request?.sessionID === state.sessionID && Number.isFinite(request?.id) && Number.isFinite(request?.until)
  state.test = mine ? { id: request.id, until: request.until } : undefined
}

function testing(state, now) {
  return state.test !== undefined && now < state.test.until
}

function withTest(state, lines, now) {
  return testing(state, now) ? { ...lines, early: 0 } : lines
}

async function heartbeat($, state) {
  const now = await $.clock.now()
  const usage = await $.session.usage().catch(() => undefined)
  const limit = nearestLimit(usage)
  // Shown as they stand now, so a rise that has aged out shows the lines back where they belong.
  const tokens = usage?.context?.tokens
  if (Number.isFinite(tokens)) {
    state.lines = withTest(state, linesFor(await $.store.get('calibration'), tokens, recentStep(state, now)), now)
  }
  await $.fs.write(`${folder(state)}/sessions/${state.sessionID}.json`, JSON.stringify({
    version: VERSION, sessionID: state.sessionID, updatedAt: now, enabled: state.config.enabled, switchRequests: true,
    state: state.pausing ? 'paused' : compactingHere(state) ? 'compacting' : 'watching', busy: state.busy,
    contextTokens: usage?.context?.tokens ?? null, contextWindow: usage?.context?.window ?? null,
    window: limit?.kind ?? null, used: limit?.used ?? null, resetsAt: limit?.resetsAt ?? null,
    lines: state.lines, lastActivityAt: state.lastActivityAt ?? null, hookFailure: state.hookFailure,
  }))
}

/** Other sessions of the same machine compact one at a time, so they do not race for the last quota. */
async function takeLock($, state, now) {
  const path = `${folder(state)}/lock.json`
  const lock = await readJSON($, path)
  if (lock?.sessionID !== state.sessionID && Number.isFinite(lock?.until) && lock.until > now) return false
  await $.fs.write(path, JSON.stringify({ sessionID: state.sessionID, until: now + LOCK_MS }))
  return true
}

/** The owner keeps its lease while its /compact runs; a conversation that is gone lets it lapse. */
async function renewLock($, state, now) {
  const path = `${folder(state)}/lock.json`
  const lock = await readJSON($, path)
  if (lock?.sessionID === state.sessionID) await $.fs.write(path, JSON.stringify({ sessionID: state.sessionID, until: now + LOCK_MS }))
}

async function releaseLock($, state) {
  const path = `${folder(state)}/lock.json`
  const lock = await readJSON($, path)
  if (lock?.sessionID === state.sessionID) await $.fs.write(path, JSON.stringify({ sessionID: state.sessionID, until: 0 }))
}

/** Learns how many percent of the window a compaction of 100 000 tokens takes. */
async function learn($, tokens, before, after) {
  if (tokens < 50_000 || after === undefined || before.kind !== after.kind || before.resetsAt !== after.resetsAt) return
  const cost = after.used - before.used
  if (!(cost >= 0)) return
  const sample = cost / (tokens / 100_000)
  const old = await $.store.get('calibration')
  const per100k = Number.isFinite(old?.per100k) ? old.per100k * 0.7 + sample * 0.3 : sample
  await $.store.set('calibration', { per100k, samples: Math.min(20, (old?.samples ?? 0) + 1) })
}

/**
 * Runs a bare /compact as if the person typed it; the host queues the command until the
 * conversation is idle. Nothing follows the command: Claude Code's own summary already keeps the
 * task, and words after it showed in the conversation as if the person had written them. (The
 * direct `$.session.compact` call was refused every time in Desktop sessions.) The session.compact
 * hook in `register` notes what the compaction did.
 */
async function compactOnce($, state) {
  state.seen = undefined
  let finished
  let failure
  const pending = { startedAt: await $.clock.now() }
  let command
  try {
    command = Promise.resolve($.command.run({ command: 'compact' }))
  } catch (error) {
    command = Promise.reject(error)
  }
  state.command = pending
  command.then(() => commandEnded($, state, pending), () => commandEnded($, state, pending))
  try {
    finished = await within($, COMMAND_TIMEOUT_MS, command)
  } catch (error) {
    failure = shortReason(error)
  }
  const seen = state.seen
  state.seen = undefined
  // What the host did, in fixed words: tells a refused command from a compaction that never came.
  const trace = {
    command: failure !== undefined ? 'rejected' : finished === TIMED_OUT ? 'timed out' : 'resolved',
    hook: seen?.meanwhile === true ? 'compacted meanwhile' : seen?.compacted === true ? 'compacted'
      : seen?.skip !== undefined ? 'skipped' : seen?.error !== undefined ? 'failed' : 'not seen',
  }
  if (seen?.compacted === true) return { outcome: 'compacted', tokensAfter: seen.tokensAfter, trace }
  if (seen?.skip !== undefined) return { outcome: 'skipped', error: seen.skip, trace }
  if (finished === TIMED_OUT) {
    return { outcome: 'failed', stuck: true, trace,
      error: `the /compact command had not finished after ${COMMAND_TIMEOUT_MS / 60_000} minutes` }
  }
  return { outcome: 'failed', error: seen?.error ?? failure ?? 'the /compact command finished without compacting', trace }
}

/** A /compact has ended, perhaps after its attempt gave up waiting: the lease goes back. */
async function commandEnded($, state, pending) {
  if (state.command !== pending) return
  state.command = undefined
  // An attempt still in progress releases the lease and reports itself.
  if (state.compacting) return
  await releaseLock($, state).catch(() => {})
  await heartbeat($, state).catch(() => {})
}

/** The target as it stands now, or undefined when the conversation no longer qualifies. */
async function stillDue($, state, reason) {
  await readConfig($, state)
  const now = await $.clock.now()
  const target = await plan($, state, await $.session.usage(), now, true)
  return target !== undefined && target.limit.used >= target.lines[reason === 'hard' ? 'hard' : 'early'] ? target : undefined
}

function currentPause(state, pause) {
  return pause !== undefined && state.pause === pause && pause.epoch === state.userEpoch
}

function takeOver(state) {
  state.userEpoch += 1
  if (state.pause === undefined) return
  state.pause = undefined
  state.pausing = false
  state.retrying = false
}

async function cancelAutomaticTurn($, state, turnId) {
  state.blockedTurns.add(turnId)
  state.ownAborts.add(turnId)
  try { await $.turn.abort({ turnId }) }
  catch { state.ownAborts.delete(turnId) /* Its tools stay blocked when host cancellation fails. */ }
}

async function attempt($, state, reason, target, tries, pause) {
  if (reason === 'hard' && !currentPause(state, pause)) return
  if (state.compacting || state.switching || state.compactions > 0) {
    // This conversation is compacting already, the person's /compact included; a paused task
    // waits for that, then goes on. An early retry gives way, and a later reply tries again.
    if (reason === 'hard') $.clock.after(RETRY_MS, () => { void attempt($, state, reason, target, tries, pause).catch(() => {}) })
    else state.retrying = false
    return
  }
  state.compacting = true
  state.retrying = false
  let startedAt = 0
  let outcome = 'failed'
  let error
  let stuck = false
  let tokensAfter
  let trace
  let after
  try {
    startedAt = await $.clock.now()
    // Waiting and retries take time: compact only what still qualifies right now.
    const fresh = await stillDue($, state, reason)
    if (reason === 'hard' && !currentPause(state, pause)) return
    if (fresh === undefined) {
      const mark = await $.store.get(markKey(state, target.limit))
      // Compacted since the task was paused, by the person or the engine: it finds that done.
      const meanwhile = reason === 'hard' && state.compactedAt > (state.pausedAt ?? Infinity)
      outcome = mark?.done === true || meanwhile ? 'already' : 'skipped'
      error = 'the conversation no longer meets the compaction conditions'
    } else if (reason === 'early' && state.busy) {
      // A turn began while this waited: its /compact would wait behind the whole turn, and the
      // turn's hard line would stay blind meanwhile. The next reply tries again.
      outcome = 'deferred'
    } else if (!(await takeLock($, state, startedAt))) {
      target = fresh
      outcome = 'waiting'
      error = 'another conversation on this Mac was compacting'
    } else {
      target = fresh
      try {
        if (reason === 'hard' && !currentPause(state, pause)) return
        const key = markKey(state, target.limit)
        const mark = await $.store.get(key)
        if (reason === 'hard' && !currentPause(state, pause)) return
        const attempts = (mark?.attempts ?? 0) + 1
        if (mark?.done === true) {
          // An earlier attempt of this window ended already, for example the early one a paused
          // task waited behind.
          outcome = 'already'
        } else {
          // Counted before the call, so a crash cannot turn into an endless series of summaries.
          await $.store.set(key, { attempts, done: false })
          if (reason === 'hard' && !currentPause(state, pause)) return
          const done = await compactOnce($, state)
          outcome = done.outcome
          error = done.error
          stuck = done.stuck === true
          trace = done.trace
          after = await $.session.usage().catch(() => undefined)
          tokensAfter = done.tokensAfter ?? after?.context?.tokens
          // A conversation that shrank to less than half was compacted, whatever was reported.
          if (outcome === 'failed' && Number.isFinite(after?.context?.tokens) && after.context.tokens < target.tokens / 2) {
            outcome = 'compacted'
            error = undefined
            stuck = false
          }
          // Done either way: a declined compaction is not tried again this window, nor told as one.
          if (outcome !== 'failed') await $.store.set(key, { attempts, done: true, compacted: outcome === 'compacted' })
          // A command that never finished may still be queued: nothing goes behind it this window.
          else if (stuck) await $.store.set(key, { attempts: Math.max(attempts, ATTEMPTS), done: false })
        }
      } finally {
        // A /compact still running keeps the lease until it ends (commandEnded, holdLease).
        if (state.command === undefined) await releaseLock($, state).catch(() => {})
      }
    }
  } catch (problem) {
    outcome = 'failed'
    error = shortReason(problem)
  } finally {
    state.compacting = false
  }
  // An already running /compact may finish normally after the person takes over. Keep its
  // measured cost and quota-window mark, but neither resume nor report a failed old pause.
  if (reason === 'hard' && !currentPause(state, pause)) {
    if (outcome === 'compacted') await learn($, target.tokens, target.limit, nearestLimit(after)).catch(() => {})
    await heartbeat($, state).catch(() => {})
    return
  }
  // A paused task waits for its compaction; an early one tries again after a later reply instead.
  const waits = tries.waits + (outcome === 'waiting' ? 1 : 0)
  const failures = tries.failures + (outcome === 'failed' ? 1 : 0)
  const retry = (outcome === 'waiting' && waits <= WAITS) ||
    (outcome === 'failed' && reason === 'hard' && !stuck && failures <= FAILURES)
  if (retry) {
    state.retrying = true
    $.clock.after(outcome === 'waiting' ? RETRY_MS : FAILURE_RETRY_MS,
      () => { void attempt($, state, reason, target, { waits, failures }, pause).catch(() => {}) })
    return
  }
  if (outcome === 'already' || outcome === 'deferred') {
    const notResumed = outcome === 'already' && reason === 'hard' ? await resume($, state, pause) : null
    if (reason === 'hard' && !currentPause(state, pause)) return
    // Nothing happened that was not reported already, unless the paused task could not go on.
    const notGoingOn = notResumed ?? (reason === 'hard' ? pause?.notResumed : undefined) ?? null
    if (notGoingOn !== null) {
      await record($, state, { reason, target, status: 'skipped', error: `the task could not be resumed: ${notGoingOn}`,
        startedAt, resumed: false }).catch(() => {})
    } else if (outcome === 'already' && reason === 'hard') pause.reported = { target, startedAt, resumed: true }
    await heartbeat($, state).catch(() => {})
    if (reason === 'hard' && state.pause === pause) state.pause = undefined
    return
  }
  await finish($, state, { reason, target, outcome, error, tokensAfter, trace, after, startedAt, pause }).catch(() => {})
  if (reason === 'hard' && state.pause === pause) { state.pausing = false; state.pause = undefined }
}

/**
 * Lets a task paused at the hard line go on. Compaction details stay in the result.
 * Null once the prompt went out, else the host's reason.
 */
async function resume($, state, pause) {
  if (!currentPause(state, pause)) return undefined
  state.pausing = false
  try {
    // The host can queue this behind a running turn. Keep its exact identity after submission,
    // so a later user instruction can still revoke it before that automatic turn executes.
    state.issuedPauses.set(pause.id, pause)
    const result = await $.prompt.submit({ text: `[Continuation pauseID=${pause.id}]\n${CONTINUATION_TEXT}` })
    if (!result || result.drop !== undefined || typeof result.text !== 'string') {
      return shortReason(result?.drop ?? 'the continuation prompt was not accepted')
    }
    return null
  } catch (problem) {
    return shortReason(problem)
  }
}

async function finish($, state, { reason, target, outcome, error, tokensAfter, trace, after, startedAt, pause }) {
  // The task was stopped for this, so it goes on whether or not the compaction worked, and first:
  // nothing that could fail on the way may keep it stopped.
  const notResumed = reason === 'hard' ? await resume($, state, pause) : null
  const limitAfter = nearestLimit(after)
  if (outcome === 'compacted') await learn($, target.tokens, target.limit, limitAfter).catch(() => {})
  if (reason === 'hard' && !currentPause(state, pause)) return
  // A task that could not go on comes first: that is what the person has to act on.
  const reasons = []
  const notGoingOn = notResumed ?? pause?.notResumed ?? null
  if (notGoingOn !== null) reasons.push(`the task could not be resumed: ${notGoingOn}`)
  if (outcome !== 'compacted' && error) reasons.push(error)
  const resumed = reason === 'hard' && notGoingOn === null
  // A guard that stops the continuing turn after this record reports the task again.
  if (resumed) pause.reported = { target, startedAt, resumed }
  await record($, state, {
    reason, target, status: outcome === 'waiting' ? 'failed' : outcome, error: reasons.length > 0 ? reasons.join('; ') : null,
    limitAfter, tokensAfter, trace, startedAt, resumed,
  })
  await heartbeat($, state)
}

/**
 * One compaction in `results/`, for CC-Relay's log and panel. `target` is what was compacted: its
 * tokens and lines, and the usage window that decided, which one before a switch may lack.
 */
async function record($, state, { reason, target, status, error, limitAfter, tokensAfter, trace, startedAt, resumed }) {
  const finishedAt = await $.clock.now()
  await $.fs.write(`${folder(state)}/results/${finishedAt}-${state.sessionID}.json`, JSON.stringify({
    version: VERSION, sessionID: state.sessionID, reason, status,
    window: target.limit?.kind ?? null, usedBefore: target.limit?.used ?? null, usedAfter: limitAfter?.used ?? null,
    tokensBefore: target.tokens, tokensAfter: tokensAfter ?? null, lines: target.lines,
    error: error ?? null, trace: trace ?? null, test: target.test ?? null,
    startedAt, finishedAt, resumed,
  }))
}

/** After a reply, or on the timer while idle: compact once usage passes the early line. */
async function considerEarly($, state) {
  if (!state.enabled || state.busy || state.pausing || state.compacting || state.retrying) return
  const now = await $.clock.now()
  const usage = await $.session.usage()
  observe(state, nearestLimit(usage), now)
  const target = await plan($, state, usage, now)
  if (target !== undefined && target.limit.used >= target.lines.early) await attempt($, state, 'early', target, FIRST_TRY)
}

/** Renews the lease while this conversation's /compact runs, for up to HOLD_MS. */
async function holdLease($, state) {
  const pending = state.command
  if (pending === undefined) return
  const now = await $.clock.now()
  if (now - pending.startedAt < HOLD_MS) {
    await renewLock($, state, now)
    return
  }
  // Half an hour without an end: count it lost, so nobody waits on it for ever.
  state.command = undefined
  if (!state.compacting) await releaseLock($, state)
}

/**
 * CC-Relay is about to move this conversation to another account: `switch-request.json` names it,
 * with an id and the time after which no compaction may begin for it (`{ id, sessionID, until }`).
 * It is compacted now, on the account it is leaving, whatever its usage and whether or not it was
 * compacted this window, so the next account need not read all of it again. `switch-result.json`
 * says first that the compaction has begun, so CC-Relay waits for its end, then how it went.
 */
async function checkSwitch($, state) {
  if (!state.enabled || state.switchChecking) return
  state.switchChecking = true
  try {
    const request = await readJSON($, `${folder(state)}/${SWITCH_FILE}`)
    if (request?.sessionID !== state.sessionID || !Number.isFinite(request?.id) || !Number.isFinite(request?.until)) return
    if (request.id === state.lastSwitch || await $.clock.now() >= request.until) return
    state.lastSwitch = request.id
    const startedAt = await $.clock.now()
    const tokensBefore = (await $.session.usage().catch(() => undefined))?.context?.tokens
    // CC-Relay waits on the answer: whatever fails on the way is answered, never left unsaid.
    const answer = await compactForSwitch($, state, request, tokensBefore)
      .catch(problem => ({ status: 'failed', error: shortReason(problem) }))
    await $.fs.write(`${folder(state)}/${SWITCH_RESULT_FILE}`, JSON.stringify({
      version: VERSION, id: request.id, sessionID: state.sessionID, status: answer.status,
      tokensBefore: tokensBefore ?? null, tokensAfter: answer.tokensAfter ?? null,
      error: answer.status === 'compacted' ? null : answer.error ?? null, startedAt, finishedAt: await $.clock.now(),
    }))
    await heartbeat($, state).catch(() => {})
  } finally {
    state.switchChecking = false
  }
}

/** CC-Relay takes its request back once the switch goes on without waiting any longer. */
async function stillAsked($, state, request) {
  return (await readJSON($, `${folder(state)}/${SWITCH_FILE}`))?.id === request.id
}

/**
 * Tells CC-Relay that this conversation is compacting for its request: it waits for the end then,
 * past the time it waits for a start, rather than close Claude under a /compact.
 */
async function begun($, state, request) {
  if (request.begun) return
  await $.fs.write(`${folder(state)}/${SWITCH_RESULT_FILE}`, JSON.stringify({
    version: VERSION, id: request.id, sessionID: state.sessionID, status: 'compacting', startedAt: await $.clock.now(),
  }))
  request.begun = true
}

/**
 * Where the conversation and its account stand for a compaction before a switch: the answer when
 * none should begin now, or else its context size and the nearest limit.
 */
async function standing($, state, tokensBefore) {
  await readConfig($, state)
  const now = await $.clock.now()
  const usage = await $.session.usage().catch(() => undefined)
  const tokens = usage?.context?.tokens
  if (Number.isFinite(tokensBefore) && Number.isFinite(tokens) && tokens < tokensBefore / 2) {
    return { answer: { status: 'compacted', tokensAfter: tokens } }
  }
  // Compacted here, by this plugin or the person, with no response since: the host gives no
  // context size until the next one, and the switch's work is done. A task paused for that
  // compaction may have begun its turn again already.
  if (usage !== undefined && !Number.isFinite(tokens) && state.compactedAt > 0) {
    return { answer: { status: 'compacted', tokensAfter: state.compactedTokens } }
  }
  const limit = nearestLimit(usage)
  const skipped = !state.config.enabled ? 'automatic compaction is off'
    : state.busy ? 'a turn is running'
      : !Number.isFinite(tokens) || tokens < state.config.minContextTokens ? 'the conversation is short'
        : state.lastActivityAt === undefined || now - state.lastActivityAt > RECENT_MS ? 'the conversation was not used within the hour'
          : limit !== undefined && limit.used >= LAST_START ? 'the account is at its limit'
            : undefined
  return skipped === undefined ? { tokens, limit } : { answer: { status: 'skipped', error: skipped } }
}

/** Compacted, skipped (nothing to do, or not now) or failed, with the reason when not compacted. */
async function compactForSwitch($, state, request, tokensBefore) {
  // A compaction already under way here, the early line's or the person's own, does the switch's
  // work: it is waited for rather than cut short, for as long as CC-Relay keeps the request.
  if (compactingHere(state)) {
    await begun($, state, request)
    while (compactingHere(state)) {
      await delay($, RETRY_MS)
      if (!(await stillAsked($, state, request))) return { status: 'skipped', error: 'the switch went on without it' }
    }
  }
  state.switching = true
  try {
    const now = await $.clock.now()
    let { answer, tokens, limit } = await standing($, state, tokensBefore)
    if (answer !== undefined) return answer
    // Nothing begins past `until`: CC-Relay stops waiting for a start soon after. Once this
    // request's compaction has begun, CC-Relay waits for its end instead.
    let waited = false
    while (!(await takeLock($, state, await $.clock.now()))) {
      waited = true
      if (!request.begun && await $.clock.now() + RETRY_MS >= request.until) {
        return { status: 'failed', error: 'another conversation on this Mac was compacting' }
      }
      await delay($, RETRY_MS)
      if (!(await stillAsked($, state, request))) return { status: 'skipped', error: 'the switch went on without it' }
    }
    state.compacting = true
    let done
    try {
      // Taken back meanwhile, the switch goes on and closes Claude: nothing begins under it.
      if (!(await stillAsked($, state, request))) return { status: 'skipped', error: 'the switch went on without it' }
      // Nor past its time, where a sleep during the wait can carry it: CC-Relay waits for no start then.
      if (!request.begun && await $.clock.now() >= request.until) {
        return { status: 'failed', error: 'another conversation on this Mac was compacting' }
      }
      // The wait can be long: the account may have run out, or a turn begun, since it was looked at.
      if (waited) {
        ({ answer, tokens, limit } = await standing($, state, tokensBefore))
        if (answer !== undefined) return answer
      }
      await begun($, state, request)
      done = await compactOnce($, state)
    } catch (problem) {
      done = { outcome: 'failed', error: shortReason(problem) }
    } finally {
      state.compacting = false
      // A /compact still running keeps the lease until it ends (commandEnded, holdLease).
      if (state.command === undefined) await releaseLock($, state).catch(() => {})
    }
    const after = await $.session.usage().catch(() => undefined)
    // A conversation that shrank to less than half was compacted, whatever was reported.
    const outcome = done.outcome === 'failed' && after?.context?.tokens < tokens / 2 ? 'compacted' : done.outcome
    const tokensAfter = done.tokensAfter ?? after?.context?.tokens
    const limitAfter = nearestLimit(after)
    // What it cost and its record matter less than the answer, which goes out without them.
    if (outcome === 'compacted' && limit !== undefined) await learn($, tokens, limit, limitAfter).catch(() => {})
    // The usual record of a compaction, for CC-Relay's log and panel.
    await record($, state, {
      reason: 'switch', target: { tokens, limit, lines: state.lines }, status: outcome,
      error: outcome === 'compacted' ? null : done.error, limitAfter, tokensAfter, trace: done.trace,
      startedAt: now, resumed: false,
    }).catch(() => {})
    return { status: outcome, tokensAfter, error: done.error }
  } finally {
    state.switching = false
  }
}

async function tick($, state) {
  try {
    await readConfig($, state)
    await readTest($, state)
    await heartbeat($, state)
    await holdLease($, state)
    await considerEarly($, state)
  } catch { }
}

/** A step of the conversation's own turn is under way, with nothing else stopping or compacting it. */
function mayPause(state) {
  return state.enabled && state.busy && !state.pausing && !state.compacting && !state.switching && state.turnId !== undefined
}

/** This conversation is being compacted, whoever asked, or a paused task waits for that. */
function compactingHere(state) {
  return state.compacting || state.command !== undefined || state.pausing || state.compactions > 0
}

export function register(on) {
  const state = {
    enabled: false, home: undefined, sessionID: undefined, config: { ...DEFAULTS },
    busy: false, turnId: undefined, lastActivityAt: undefined, pausing: false, compacting: false,
    retrying: false, ticking: false, lastLimit: undefined, lastLimitAt: 0, steps: [], lines: linesFor(undefined, 0, 0),
    seen: undefined, test: undefined, command: undefined, switchChecking: false, switching: false, lastSwitch: undefined,
    compactions: 0, compactedAt: 0, compactedTokens: undefined, pausedAt: undefined,
    userEpoch: 0, pause: undefined, ownAborts: new Set(),
    issuedPauses: new Map(), automaticTurns: new Map(), blockedTurns: new Set(), mainAutomaticPause: undefined, latestTurnId: undefined,
  }

  on('session.start', async ($, event, next) => {
    const result = await next(event)
    try {
      if (event.isInteractive || await $.env.get('CLAUDE_CODE_ENTRYPOINT') !== 'claude-desktop') return result
      const home = await $.env.get('HOME')
      const sessionID = await $.session.id()
      if (typeof home !== 'string' || !home.startsWith('/') || !/^[A-Za-z0-9-]{1,64}$/.test(sessionID)) return result
      state.home = home
      state.sessionID = sessionID
      state.enabled = true
      await readConfig($, state)
      await readTest($, state)
      await heartbeat($, state)
      // A session that starts again keeps its one timer.
      if (!state.ticking) {
        state.ticking = true
        $.clock.every(TICK_MS, () => { void tick($, state) })
        $.clock.every(SWITCH_POLL_MS, () => { void checkSwitch($, state).catch(() => {}) })
      }
    } catch {
      state.enabled = false
    }
    return result
  })

  on('prompt.submit', async ($, event, next) => {
    // Revoke before awaiting delivery, including queued prompts and slash commands. Neither
    // this plugin's own continuation nor /compact is stamped as one of these user origins.
    const human = USER_ORIGINS.has(event.origin?.kind)
    const id = resumeID(event.text)
    const ownPrompt = event.origin?.kind === 'plugin' && event.origin.name === 'cc-relay'
    // turn.start has no origin. Preserve a quoted issued marker as text, with an explicit
    // preface before entering the queue; even two identical queued strings then cannot trade
    // identities. Ordinary prompts and markers this runtime never issued pass unchanged.
    const delivered = id && !ownPrompt && state.issuedPauses.has(id) ? { ...event, text: text(state, 'quotedPrompt') + event.text } : event
    const running = human && state.automaticTurns.has(state.turnId) ? state.turnId : undefined
    if (human) takeOver(state)
    // An empty turn after some other accepted prompt is not an implicit continuation of ours.
    if (!ownPrompt || !state.issuedPauses.has(id)) state.mainAutomaticPause = undefined
    const result = await next(delivered)
    if (running && result && !result.drop && state.turnId === running) await cancelAutomaticTurn($, state, running)
    return result
  }).catch(($, event, next) => {
    failedHook(state, 'prompt.submit', next)
    if (next.called) return next(event)
    return { drop: 'CC-Relay could not verify this prompt. It was not queued; retry after checking the compaction status.' }
  })

  on('turn.start', async ($, event, next) => {
    if (event.agentId === undefined) {
      state.busy = true
      state.turnId = event.turnId
      state.latestTurnId = event.turnId
      state.lastActivityAt = await $.clock.now().catch(() => state.lastActivityAt)
    }
    const result = await next(event)
    if (event.agentId === undefined) {
      const id = resumeID(event.text)
      const pause = id ? state.issuedPauses.get(id)
        : event.text === '' ? state.mainAutomaticPause : undefined
      state.mainAutomaticPause = pause
      if (pause) {
        state.automaticTurns.set(event.turnId, pause)
        if (pause.epoch !== state.userEpoch) await cancelAutomaticTurn($, state, event.turnId)
      }
    }
    return result
  }).catch(async ($, event, next) => {
    failedHook(state, 'turn.start', next)
    const id = resumeID(event.text)
    const pause = event.agentId === undefined
      ? (id ? state.issuedPauses.get(id) : event.text === '' ? state.mainAutomaticPause : undefined) : undefined
    // The task does not go on after all. Unless the person took over, it is reported as left
    // paused: by its compaction's record, or again when that already said it went on.
    const leftPaused = pause && pause.epoch === state.userEpoch
    if (leftPaused) pause.notResumed ??= 'the guard of its continuing turn failed'
    if (event.agentId === undefined) {
      state.busy = true
      state.turnId = event.turnId
      state.latestTurnId = event.turnId
      state.mainAutomaticPause = pause
    }
    if (pause) {
      state.automaticTurns.set(event.turnId, pause)
      state.blockedTurns.add(event.turnId)
    }
    const result = await next(event)
    if (pause) await cancelAutomaticTurn($, state, event.turnId)
    const reported = pause?.reported
    if (leftPaused && reported?.resumed) {
      reported.resumed = false
      await record($, state, { reason: 'hard', target: reported.target, status: 'skipped',
        error: `the task could not be resumed: ${pause.notResumed}`, startedAt: reported.startedAt, resumed: false }).catch(() => {})
    }
    return result
  })

  on('turn.complete', async ($, event, next) => {
    const result = await next(event)
    if (event.agentId === undefined) {
      const ownAbort = state.ownAborts.delete(event.turnId)
      if (event.isAborted && !ownAbort && (state.latestTurnId === event.turnId || state.pause?.turnId === event.turnId)) takeOver(state)
      if (state.turnId === event.turnId) {
        state.busy = false
        if (!state.blockedTurns.has(event.turnId)) state.turnId = undefined
      }
      state.lastActivityAt = await $.clock.now().catch(() => state.lastActivityAt)
      // Fresh numbers for CC-Relay after every reply, not only on the timer.
      if (state.enabled) $.clock.after(500, () => { void considerEarly($, state).then(() => heartbeat($, state)).catch(() => {}) })
    }
    return result
  })

  on('turn.abort', async ($, event, next) => {
    if (event.agentId === undefined) {
      // next.origin is the host-stamped caller, not the loop or any user-supplied text.
      if (next.origin?.plugin !== 'cc-relay') takeOver(state)
    }
    const result = await next(event)
    if (event.agentId === undefined && state.turnId === event.turnId) {
      state.busy = false
      // Keep revoked model-tool ownership until another turn actually starts, even after the
      // host acknowledges cancellation; an already dispatched old tool may still arrive late.
      if (!state.blockedTurns.has(event.turnId)) state.turnId = undefined
    }
    return result
  })

  // Between two steps of a long task the tools of the last step have finished; stopping the turn
  // here interrupts nothing. Only past the hard line, so ordinary work is never touched.
  on('tool.call', async ($, event, next) => {
    // Only the model loop's tools belong to its turn. A separate plugin's direct tool call
    // has the same agent axis but its own host-stamped origin, and is not this continuation.
    const automatic = event.agentId === undefined && next.origin?.plugin === 'engine' ? state.automaticTurns.get(state.turnId) : undefined
    if (automatic && (automatic.epoch !== state.userEpoch || state.blockedTurns.has(state.turnId))) {
      return { deny: text(state, 'superseded') }
    }
    if (!mayPause(state)) return next(event)
    const epoch = state.userEpoch
    let target
    let now
    try {
      now = await $.clock.now()
      // The conversation's own tool call (a subagent's carries `agentId`) follows its model request,
      // so its cache is warm however long the turn has run.
      if (event?.agentId === undefined) state.lastActivityAt = now
      const usage = await $.session.usage()
      observe(state, nearestLimit(usage), now)
      target = await plan($, state, usage, now)
    } catch {
      return next(event)
    }
    if (target === undefined || target.limit.used < target.lines.hard) return next(event)
    // The switch may have been turned off since the last half-minute check: nothing is stopped
    // before it is read again. Another tool call of the same step may have stopped the task while
    // this one read, and one stop is enough.
    await readConfig($, state)
    if (!state.config.enabled || !mayPause(state) || epoch !== state.userEpoch) return next(event)
    state.pausing = true
    state.pausedAt = now
    const pause = { id: crypto.randomUUID(), epoch, turnId: state.turnId }
    state.pause = pause
    state.ownAborts.add(pause.turnId)
    try {
      await $.turn.abort({ turnId: pause.turnId })
    } catch {
      state.ownAborts.delete(pause.turnId)
      if (!currentPause(state, pause)) return { deny: text(state, 'superseded') }
      state.pausing = false; state.pause = undefined
      return next(event)
    }
    if (!currentPause(state, pause)) return { deny: text(state, 'superseded') }
    state.busy = false
    state.turnId = undefined
    $.clock.after(RETRY_MS, () => { void attempt($, state, 'hard', target, FIRST_TRY, pause).catch(() => {}) })
    return { deny: text(state, 'pause') }
  }).catch(($, event, next) => {
    failedHook(state, 'tool.call', next)
    if (next.called) return next(event)
    // A failed pause must not later submit a continuation from a half-finished guard.
    if (state.pausing) takeOver(state)
    return { deny: 'The compaction continuation guard failed; this tool was not run.' }
  })

  // Counts every compaction of the conversation itself while it runs, so that none is asked for on
  // top of it, and notes what the one this plugin asked for did. Each, the person's and the
  // engine's included, passes through unchanged; a `precompute` dispatch installs nothing.
  on('session.compact', async ($, event, next) => {
    if (event?.trigger === 'precompute' || event?.agentId !== undefined) return next(event)
    const mine = state.compacting
    // Compacted by someone else since this plugin's /compact was queued: that did its work, so it is
    // not needed any more and counts as done.
    if (mine && state.command !== undefined && state.compactedAt > state.command.startedAt) {
      state.seen = { compacted: true, meanwhile: true, tokensAfter: state.compactedTokens }
      return { skip: text(state, 'compactedMeanwhile') }
    }
    state.compactions += 1
    let result
    try {
      result = await next(event)
    } catch (error) {
      if (mine) state.seen = { error: shortReason(error) }
      throw error
    } finally {
      state.compactions -= 1
    }
    if (Array.isArray(result?.messages)) {
      state.compactedAt = await $.clock.now().catch(() => state.compactedAt)
      state.compactedTokens = Number.isFinite(result.tokensAfter) ? result.tokensAfter : undefined
    }
    if (!mine) return result
    if (Array.isArray(result?.messages)) {
      state.seen = { compacted: true, tokensAfter: Number.isFinite(result.tokensAfter) ? result.tokensAfter : undefined }
    } else if (result?.skip !== undefined) {
      state.seen = { skip: shortReason(result.skip) }
    }
    return result
  })
}
