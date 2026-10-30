import assert from 'node:assert/strict'
import test from 'node:test'
import { register } from '../hooks/low-quota-compactor.js'
import { PLUGIN_VERSION } from '../hooks/version.js'

const start = Date.parse('2026-10-25T00:00:00Z')
const HOME = '/home/test'
const DIR = `${HOME}/Library/Application Support/CC-Relay/AutoCompact`

function assertContinuationPrompt(text) {
  const [marker, ...body] = text.split('\n')
  assert.match(marker, /^\[Continuation pauseID=[a-f0-9-]{36}\]$/)
  assert.equal(body.join('\n'), 'Please continue the unfinished work from where it was interrupted, following the original instructions and scope of authorization.')
}

/**
 * A fake `$` with a manual clock: `advance` runs due timers in order. `compaction` is how the host
 * answers /compact: 'ok', 'skip' (a hook vetoes it), 'error' (it fails inside with `failure`),
 * 'reject' (the command is refused with `failure`), 'silent' (it ends without compacting),
 * 'shrink' (it compacts without the hook seeing it), 'hang' (it never ends) or 'later' (it ends
 * when the test calls `finishCommand`). `submitFailure` makes `$.prompt.submit` throw with that
 * message, `storeFailure` makes `$.store.set` throw for that key, and `writeFailure` makes
 * `$.fs.write` throw for every path that contains it.
 */
function harness({ tokens = 300_000, used = 50, entrypoint = 'claude-desktop', config = { enabled: true, language: 'zh-Hans' } } = {}) {
  const files = new Map()
  if (config !== undefined) files.set(`${DIR}/settings.json`, JSON.stringify(config))
  const store = new Map()
  const handlers = new Map()
  const timers = []
  let now = start
  const meter = { tokens, used, kind: 'five_hour', resetsAt: new Date(start + 3 * 3_600_000).toISOString(), compactCost: 1 }
  const calls = { commands: [], directCompactions: [], untouched: [], aborts: [], submits: [] }
  const h = { compaction: 'ok', failure: 'Unknown command\n  /compact' }
  const $ = {
    env: { get: async name => name === 'HOME' ? HOME : name === 'CLAUDE_CODE_ENTRYPOINT' ? entrypoint : undefined },
    fs: {
      read: async path => {
        if (!files.has(path)) throw new Error('missing')
        return files.get(path)
      },
      write: async (path, text) => {
        if (h.writeFailure !== undefined && path.includes(h.writeFailure)) throw new Error('the disk is full')
        files.set(path, text)
      },
    },
    session: {
      id: async () => 'session-a',
      usage: async () => ({
        context: { tokens: meter.tokens, window: 1_000_000 },
        rateLimits: [{ kind: meter.kind, percentUsed: meter.used, resetsAt: meter.resetsAt }],
      }),
      // Refused in Desktop sessions, so the plugin must not depend on it.
      compact: async input => {
        calls.directCompactions.push(input)
        throw new Error('refused')
      },
    },
    command: {
      // Like the host, /compact raises session.compact through the hooks, the plugin's included.
      run: async input => {
        calls.commands.push(input)
        if (h.compaction === 'reject') throw new Error(h.failure)
        if (h.compaction === 'hang') return new Promise(() => {})
        if (h.compaction === 'later') return new Promise(resolve => { h.finishCommand = () => resolve({ text: 'Compacted.' }) })
        if (h.compaction === 'silent') return { text: 'Nothing to compact.' }
        if (h.compaction === 'shrink') {
          meter.tokens = 70_000
          return { text: 'Compacted.' }
        }
        let answer
        try {
          const result = await handlers.get('session.compact')($, { trigger: 'manual' }, async () => {
            if (h.compaction === 'error') throw new Error(h.failure)
            if (h.compaction === 'skip') {
              answer = { skip: 'a PreCompact hook\nblocked it' }
            } else {
              answer = { messages: [], tokensBefore: meter.tokens, tokensAfter: 70_000 }
              meter.tokens = 70_000
              meter.used += meter.compactCost
            }
            return answer
          })
          calls.untouched.push(result === answer)
          return { text: 'Compacted.' }
        } catch (error) {
          return { text: `Error compacting conversation: ${error.message}` }
        }
      },
    },
    turn: { abort: async input => {
      calls.aborts.push(input)
      const next = Object.assign(async () => {
        if (h.abortFailure) throw h.abortFailure
      }, { origin: { plugin: 'cc-relay', tier: 'user' } })
      await handlers.get('turn.abort')($, input, next)
    } },
    prompt: {
      submit: async input => {
        calls.submits.push(input)
        const event = { ...input, origin: { kind: 'plugin', name: 'cc-relay' }, wait: false }
        const next = async () => {
          if (h.submitFailure !== undefined) throw new Error(h.submitFailure)
          return Object.hasOwn(h, 'submitResult') ? h.submitResult : { text: input.text }
        }
        return handlers.get('prompt.submit')?.($, event, next) ?? next()
      },
    },
    clock: {
      now: async () => now,
      every: (ms, fn) => { timers.push({ at: now + ms, ms, fn, repeat: true }); return { cancel() {} } },
      after: (ms, fn) => { timers.push({ at: now + ms, ms, fn, repeat: false }); return { cancel() {} } },
    },
    store: {
      get: async key => store.get(key),
      set: async (key, value) => {
        if (key === h.storeFailure) throw new Error('the store is unavailable')
        store.set(key, value)
      },
    },
  }
  register((event, matcherOrHandler, maybeHandler) => { handlers.set(event, maybeHandler ?? matcherOrHandler); return { catch() {} } })

  async function settle() {
    for (let i = 0; i < 30; i += 1) await new Promise(resolve => setImmediate(resolve))
  }
  async function advance(ms) {
    const until = now + ms
    for (;;) {
      await settle()
      timers.sort((a, b) => a.at - b.at)
      const next = timers[0]
      if (next === undefined || next.at > until) break
      timers.shift()
      now = next.at
      if (next.repeat) timers.push({ ...next, at: now + next.ms })
      next.fn()
    }
    now = until
    await settle()
  }
  /** The Mac sleeps: time passes with no timer firing, then they all run late. */
  function asleep(ms) {
    now += ms
    for (const timer of timers) timer.at += ms
  }
  return Object.assign(h, {
    files, store, meter, calls, advance, asleep,
    start: (isInteractive = false) => handlers.get('session.start')($, { isInteractive, cwd: '/w', surface: null },
      async () => ({ cwd: '/w' })),
    turnStart: (turnId = 'turn-1', fields = {}) => handlers.get('turn.start')($, { turnId, ...fields }, async () => ({})),
    turnComplete: (turnId = 'turn-1', fields = {}) => handlers.get('turn.complete')($, { turnId, ...fields }, async () => ({})),
    prompt: (text = 'Replace the old task', fields = {}) => {
      const event = { text, origin: { kind: 'composer' }, wait: false, ...fields }
      return handlers.get('prompt.submit')?.($, event, async value => value) ?? Promise.resolve(event)
    },
    abort: (turnId = 't', origin = { plugin: 'engine', tier: 'core' }) => handlers.get('turn.abort')($, { turnId },
      Object.assign(async () => undefined, { origin })),
    toolCall: (fields = {}, origin = { plugin: 'engine', tier: 'core' }) => handlers.get('tool.call')($, { tool: 'Bash', args: {}, ...fields },
      Object.assign(async () => ({ result: 'ran' }), { origin })),
    compactHook: (event, next) => handlers.get('session.compact')($, event, next),
    status: () => JSON.parse(files.get(`${DIR}/sessions/session-a.json`)),
    results: () => [...files.keys()].filter(key => key.startsWith(`${DIR}/results/`)).sort()
      .map(key => JSON.parse(files.get(key))),
    switchAnswer: () => files.has(`${DIR}/switch-result.json`) ? JSON.parse(files.get(`${DIR}/switch-result.json`)) : undefined,
  })
}

async function replied(h, turnId = 'turn-1') {
  await h.turnStart(turnId)
  await h.turnComplete(turnId)
  await h.advance(1_000)
}

/** CC-Relay is about to switch accounts and asks for this conversation to be compacted first. */
function askBeforeSwitch(h, id, { sessionID = 'session-a', until = start + 3 * 60_000 } = {}) {
  h.files.set(`${DIR}/switch-request.json`, JSON.stringify({ id, sessionID, until }))
}

/** A long task that reaches the hard line at its next tool call. */
async function pausedAtHardLine(h) {
  await h.start()
  await h.turnStart('t')
  h.meter.used = 95
  return h.toolCall()
}

for (const kind of ['composer', 'bridge', 'sdk']) test(`a new ${kind} instruction cancels the old hard-line pause before its retry`, async () => {
  const h = harness()
  await pausedAtHardLine(h)
  await h.prompt('Do the new task instead', { origin: { kind }, wait: true, turnId: 't' })
  // Even a replacement turn completed before the old timer fires does not revive the pause.
  await h.turnStart('replacement')
  await h.turnComplete('replacement')
  h.meter.used = 50
  await h.advance(5_000)
  assert.equal(h.calls.commands.length, 0)
  assert.equal(h.calls.submits.length, 0)
  assert.equal(h.results().length, 0, 'taking over is not a failed hard-line continuation')
})

test('a new instruction cancels hard-line retries waiting for another conversation lock', async () => {
  const h = harness()
  h.files.set(`${DIR}/lock.json`, JSON.stringify({ sessionID: 'session-b', until: start + 20_000 }))
  await pausedAtHardLine(h)
  await h.advance(5_000)
  await h.prompt('Stop the old task')
  await h.advance(20_000)
  assert.equal(h.calls.commands.length, 0)
  assert.equal(h.calls.submits.length, 0)
  assert.equal(h.results().length, 0)
})

for (const takeover of ['new instruction', 'user abort', 'aborted completion']) test(`${takeover} during /compact prevents old task continuation`, async () => {
  const h = harness()
  h.compaction = 'later'
  await pausedAtHardLine(h)
  await h.turnComplete('t', { isAborted: true, reason: 'aborted' })
  await h.advance(3_000)
  assert.equal(h.calls.commands.length, 1, 'the plugin\'s own abort completion keeps its pause valid')
  if (takeover === 'new instruction') await h.prompt('/clear', { origin: { kind: 'composer' } })
  else if (takeover === 'user abort') await h.abort('compact-turn')
  else await h.turnComplete('t', { isAborted: true, reason: 'aborted' })
  h.meter.tokens = 70_000
  h.finishCommand()
  await h.advance(12_000)
  assert.equal(h.calls.submits.length, 0)
  assert.equal(h.calls.commands.length, 1)
  assert.equal(h.results().length, 0, 'the superseded hard pause must not produce a false paused-task warning')
  assert.equal([...h.store.values()].filter(value => value?.done === true && value.compacted === true).length, 1,
    'actual completed compaction still marks this quota window as compacted')
  assert.equal(h.store.get('calibration')?.samples, 1)
})

test('user abort also cancels the delay after a failed hard-line compaction', async () => {
  const h = harness()
  h.compaction = 'reject'
  await pausedAtHardLine(h)
  await h.advance(3_000)
  await h.abort('t')
  await h.advance(20_000)
  assert.equal(h.calls.commands.length, 1)
  assert.equal(h.calls.submits.length, 0)
})

test('native compactor aborts and non-user prompts do not cancel ordinary hard-line continuation', async () => {
  const h = harness()
  await pausedAtHardLine(h)
  await h.turnComplete('t', { isAborted: true, reason: 'aborted' })
  for (const origin of [{ kind: 'plugin', name: 'cc-relay' }, { kind: 'task-notification' }, { kind: 'auto-continuation' }]) {
    await h.prompt('A native notification or compaction continuation', { origin })
  }
  await h.advance(3_000)
  assert.equal(h.calls.commands.length, 1)
  assert.equal(h.calls.submits.length, 1)
  assert.equal(h.results()[0].resumed, true)
})

test('a cancelled pause timer cannot consume or clear the replacement task pause', async () => {
  const h = harness()
  await pausedAtHardLine(h)
  await h.prompt('Do the new task instead')
  await h.turnStart('replacement')
  assert.match((await h.toolCall()).deny, /额度快用完/)
  await h.advance(3_000)
  assert.equal(h.calls.commands.length, 1)
  assert.equal(h.calls.submits.length, 1)
  assert.equal(h.results()[0].resumed, true)
})

test('the old plugin abort completion cannot make a replacement running turn look idle', async () => {
  const h = harness()
  await pausedAtHardLine(h)
  await h.prompt('Do the new task instead')
  await h.turnStart('replacement')
  await h.turnComplete('t', { isAborted: true, reason: 'aborted' })
  await h.advance(31_000)
  assert.equal(h.calls.commands.length, 0)
  assert.equal(h.calls.submits.length, 0)
  assert.equal(h.status().busy, true)
})

for (const takeover of ['user prompt', 'user stop']) for (const nativeMarker of ['', 'Continuation', 'CC-Relay 原任务续接']) for (const pauseMarker of ['Continuation', 'CC-Relay 自动压缩续跑']) {
  test(`a queued compactor continuation yields to ${takeover}, native marker ${nativeMarker}, pause marker ${pauseMarker}`, async () => {
    const h = harness()
    await pausedAtHardLine(h)
    await h.advance(3_000)
    const queued = h.calls.submits[0].text.replace('[Continuation pauseID=', `[${pauseMarker} pauseID=`)
    if (takeover === 'user prompt') await h.prompt('My new task')
    else await h.abort('t')
    // Failed cancellation is deliberate: the old turn's tools must remain blocked anyway.
    h.abortFailure = new Error('host could not abort the queued turn')
    const framed = 'The cc-relay plugin sent a message:\n'
      + (nativeMarker ? `[${nativeMarker} requestID=req-1]\n` : '') + queued
    await h.turnStart('stale-queued-continuation', { text: framed })
    assert.equal(h.calls.aborts.at(-1).turnId, 'stale-queued-continuation')
    assert.ok((await h.toolCall()).deny)
    await h.turnStart('new-user-turn', { text: 'My new task' })
    assert.deepEqual(await h.toolCall(), { result: 'ran' }, 'the new user turn keeps its tools')
  })
}

for (const nativeMarker of ['', 'Continuation', 'CC-Relay 原任务续接']) for (const pauseMarker of ['Continuation', 'CC-Relay 自动压缩续跑']) test(`a valid queued continuation keeps its tools, native marker ${nativeMarker}, pause marker ${pauseMarker}`, async () => {
  const h = harness()
  await pausedAtHardLine(h)
  await h.turnComplete('t', { isAborted: true, reason: 'aborted' })
  await h.advance(3_000)
  const framed = 'The cc-relay plugin sent a message:\n'
    + (nativeMarker ? `[${nativeMarker} requestID=req-1]\n` : '')
    + h.calls.submits[0].text.replace('[Continuation pauseID=', `[${pauseMarker} pauseID=`)
  await h.turnStart('valid-continuation', { text: framed })
  assert.equal(h.calls.aborts.length, 1, 'only the original compaction pause aborted a turn')
  assert.deepEqual(await h.toolCall(), { result: 'ran' })
})

for (const origin of [{ kind: 'composer' }, { kind: 'plugin', name: 'other-plugin' }]) {
  test(`a ${origin.kind} prompt quoting an issued marker is not cancelled as an automatic continuation`, async () => {
    const h = harness()
    await pausedAtHardLine(h)
    await h.advance(3_000)
    const text = h.calls.submits[0].text
    const submitted = await h.prompt(text, { origin })
    assert.ok(submitted.text.endsWith(text), 'the submitted original text is preserved')
    assert.deepEqual(submitted.origin, origin, 'the native origin remains unchanged')
    await h.turnStart('foreign-turn', { text: submitted.text })
    assert.equal(h.calls.aborts.length, 1)
    assert.deepEqual(await h.toolCall(), { result: 'ran' })
    // The quotation cannot exempt the original queued automatic prompt with the same ID.
    if (origin.kind !== 'composer') await h.prompt('A newer user instruction')
    h.abortFailure = new Error('host abort unavailable')
    await h.turnStart('original-queued-continuation', { text: 'The cc-relay plugin sent a message:\n' + text })
    assert.equal(h.calls.aborts.at(-1).turnId, 'original-queued-continuation')
    assert.ok((await h.toolCall()).deny)
  })
}

test('a newer user instruction cancels only the running automatic continuation even if its abort fails', async () => {
  const h = harness()
  await pausedAtHardLine(h)
  await h.advance(3_000)
  await h.turnStart('automatic-continuation', { text: h.calls.submits[0].text })
  h.abortFailure = new Error('host abort unavailable')
  await h.prompt('Please do the replacement task', { turnId: 'automatic-continuation' })
  assert.equal(h.calls.aborts.at(-1).turnId, 'automatic-continuation')
  assert.ok((await h.toolCall()).deny)
  await h.turnStart('replacement', { text: 'Please do the replacement task' })
  assert.deepEqual(await h.toolCall(), { result: 'ran' })
})

test('an acknowledged abort and its completion still reject late old tools until a new turn starts', async () => {
  const h = harness()
  await pausedAtHardLine(h)
  await h.advance(3_000)
  await h.prompt('Do the new task instead')
  await h.turnStart('stale-queued-continuation', { text: h.calls.submits[0].text })
  assert.equal(h.calls.aborts.at(-1).turnId, 'stale-queued-continuation')
  assert.ok((await h.toolCall()).deny)
  await h.turnComplete('stale-queued-continuation', { isAborted: true, reason: 'aborted' })
  assert.ok((await h.toolCall()).deny)
  assert.deepEqual(await h.toolCall({}, { plugin: 'other-plugin', tier: 'user' }), { result: 'ran' },
    'a direct call from a separate plugin is not a tool of the cancelled model turn')
  await h.turnStart('new-user-turn', { text: 'Do the new task instead' })
  assert.deepEqual(await h.toolCall(), { result: 'ran' })
})

test('another plugin empty prompt does not inherit the previous automatic continuation identity', async () => {
  const h = harness()
  await pausedAtHardLine(h)
  await h.advance(3_000)
  await h.turnStart('automatic-continuation', { text: h.calls.submits[0].text })
  await h.turnComplete('automatic-continuation')
  await h.prompt('', { origin: { kind: 'plugin', name: 'other-plugin' } })
  await h.turnStart('other-plugin', { text: '' })
  await h.prompt('New user input', { turnId: 'other-plugin' })
  assert.equal(h.calls.aborts.length, 1, 'no unrelated plugin turn is cancelled')
  assert.deepEqual(await h.toolCall(), { result: 'ran' })
})

for (const oldFirst of [false, true]) test(`a full user quotation and the identical old queued text keep separate provenance, old first ${oldFirst}`, async () => {
  const h = harness()
  await pausedAtHardLine(h)
  await h.advance(3_000)
  // A continuation framed by the host, with the continuation's own mark before the resume.
  const framed = 'The cc-relay plugin sent a message:\n[Continuation requestID=req-1]\n' + h.calls.submits[0].text
  const submitted = await h.prompt(framed)
  assert.ok(submitted.text.endsWith(framed))
  const original = async () => {
    await h.turnStart('old-queued', { text: framed })
    assert.equal(h.calls.aborts.at(-1).turnId, 'old-queued')
    assert.ok((await h.toolCall()).deny)
  }
  const quotation = async () => {
    const count = h.calls.aborts.length
    await h.turnStart('user-quotation', { text: submitted.text })
    assert.equal(h.calls.aborts.length, count)
    assert.deepEqual(await h.toolCall(), { result: 'ran' })
  }
  if (oldFirst) { await original(); await quotation() }
  else { await quotation(); await original() }
})

test('a late aborted completion of an older unrelated turn does not revoke a replacement pause', async () => {
  const h = harness()
  await h.start()
  await h.turnStart('old-user-turn')
  await h.prompt('Replacement task')
  await h.turnStart('replacement')
  h.meter.used = 95
  await h.toolCall()
  await h.turnComplete('old-user-turn', { isAborted: true, reason: 'aborted' })
  await h.advance(3_000)
  assert.equal(h.calls.commands.length, 1)
  assert.equal(h.calls.submits.length, 1)
  assert.equal(h.results()[0].resumed, true)
})

test('repeated marker quotations preserve the original text and ordinary user prompts pass unchanged', async () => {
  const h = harness()
  await pausedAtHardLine(h)
  await h.advance(3_000)
  const original = h.calls.submits[0].text
  for (let index = 0; index < 2; index++) {
    const submitted = await h.prompt(original)
    assert.ok(submitted.text.endsWith(original))
    const count = h.calls.aborts.length
    await h.turnStart(`quotation-${index}`, { text: submitted.text })
    assert.equal(h.calls.aborts.length, count)
    assert.deepEqual(await h.toolCall(), { result: 'ran' })
  }
  for (const plain of ['Continue my current task', '/compact', 'Here is a quoted marker: ' + original,
    '[Continuation pauseID=00000000-0000-0000-0000-000000000000]\nNever issued here',
    '[CC-Relay 自动压缩续跑 pauseID=00000000-0000-0000-0000-000000000000]\nNever issued here']) {
    const submitted = await h.prompt(plain)
    assert.equal(submitted.text, plain)
    assert.deepEqual(submitted.origin, { kind: 'composer' })
  }
})

test('does nothing outside a Claude Desktop Code session', async () => {
  const terminal = harness({ entrypoint: 'cli' })
  await terminal.start()
  const interactive = harness()
  await interactive.start(true)
  for (const h of [terminal, interactive]) {
    h.meter.used = 95
    await replied(h)
    assert.equal(h.files.has(`${DIR}/sessions/session-a.json`), false)
    assert.equal(h.calls.commands.length, 0)
  }
})

test('reports this conversation in numbers only, every half minute', async () => {
  const h = harness()
  await h.start()
  const status = h.status()
  assert.deepEqual(Object.keys(status).sort(), ['busy', 'contextTokens', 'contextWindow', 'enabled', 'lastActivityAt',
    'lines', 'resetsAt', 'sessionID', 'state', 'switchRequests', 'updatedAt', 'used', 'version', 'window'])
  assert.equal(status.version, PLUGIN_VERSION)
  // CC-Relay asks only a plugin that says it answers requests before a switch.
  assert.equal(status.switchRequests, true)
  assert.equal(status.contextTokens, 300_000)
  assert.equal(status.used, 50)
  assert.deepEqual(status.lines, { early: 88, hard: 92 })
  await h.advance(30_000)
  assert.equal(h.status().updatedAt, start + 30_000)
})

test('compacts through /compact after the reply that crosses the early line, once per window', async () => {
  const h = harness()
  await h.start()
  await h.turnStart()
  // 87 % used is still above the early line of 12 % left.
  h.meter.used = 87
  await h.turnComplete()
  await h.advance(1_000)
  assert.equal(h.calls.commands.length, 0)
  await h.turnStart()
  h.meter.used = 88
  await h.turnComplete()
  await h.advance(1_000)
  assert.equal(h.calls.commands.length, 1)
  // A bare /compact: words after it would show in the conversation as the person's own.
  assert.deepEqual(h.calls.commands[0], { command: 'compact' })
  assert.deepEqual(h.calls.directCompactions, [])
  // The plugin's own hook hands the engine's answer on untouched.
  assert.deepEqual(h.calls.untouched, [true])
  const [result] = h.results()
  assert.equal(result.reason, 'early')
  assert.equal(result.status, 'compacted')
  assert.equal(result.tokensBefore, 300_000)
  assert.equal(result.tokensAfter, 70_000)
  assert.equal(result.error, null)
  assert.deepEqual(result.trace, { command: 'resolved', hook: 'compacted' })
  assert.equal(result.resumed, false)
  assert.equal(h.calls.submits.length, 0)
  // Long again in the same window: no second summary.
  h.meter.tokens = 400_000
  await replied(h, 'turn-2')
  assert.equal(h.calls.commands.length, 1)
})

test('leaves short, below-the-line and long-idle conversations alone', async () => {
  const short = harness({ tokens: 50_000, used: 90 })
  await short.start()
  await replied(short)
  const below = harness({ used: 80 })
  await below.start()
  await replied(below)
  const idle = harness()
  await idle.start()
  await replied(idle)
  await idle.advance(61 * 60_000)
  idle.meter.used = 90
  await idle.advance(30_000)
  for (const h of [short, below, idle]) assert.equal(h.calls.commands.length, 0)
})

test('a recent but idle conversation is compacted when usage crosses the line elsewhere', async () => {
  const h = harness()
  await h.start()
  await replied(h)
  h.meter.used = 89
  await h.advance(30_000)
  assert.equal(h.calls.commands.length, 1)
})

for (const language of ['zh-Hans', 'en']) test(`stops a long task between two steps, compacts, then continues in English with ${language} settings`, async () => {
  const h = harness({ config: { enabled: true, language } })
  await h.start()
  await h.turnStart('long-turn')
  h.meter.used = 84
  assert.deepEqual(await h.toolCall(), { result: 'ran' })
  // Busy, so the early line waits for the reply; the hard line does not.
  await h.advance(30_000)
  assert.equal(h.calls.commands.length, 0)
  h.meter.used = 94
  const answer = await h.toolCall()
  assert.match(answer.deny, /额度快用完|usage limit/)
  assert.deepEqual(h.calls.aborts, [{ turnId: 'long-turn' }])
  await h.advance(2_000)
  assert.equal(h.calls.commands.length, 1)
  assert.equal(h.calls.submits.length, 1)
  assertContinuationPrompt(h.calls.submits[0].text)
  const [result] = h.results()
  assert.equal(result.reason, 'hard')
  assert.equal(result.status, 'compacted')
  assert.equal(result.resumed, true)
  assert.equal(h.status().state, 'watching')
})

test('a task that has run for over an hour in one turn still stops at the hard line', async () => {
  const h = harness()
  await h.start()
  await h.turnStart('long-turn')
  // A step a minute for 61 minutes: the turn began over an hour ago, its last request did not.
  for (let minute = 1; minute <= 61; minute += 1) {
    await h.advance(60_000)
    assert.deepEqual(await h.toolCall(), { result: 'ran' })
  }
  h.meter.used = 95
  assert.match((await h.toolCall()).deny, /额度快用完/)
  await h.advance(2_000)
  assert.equal(h.calls.commands.length, 1)
  assertContinuationPrompt(h.calls.submits[0].text)
})

test('a subagent\'s tool calls do not keep the conversation recent; its own do', async () => {
  const h = harness()
  await h.start()
  await h.turnStart('long-turn')
  // The conversation waits on a subagent for over an hour, so its own cache may be gone.
  for (let minute = 1; minute <= 61; minute += 1) {
    await h.advance(60_000)
    await h.toolCall({ agentId: 'agent-1' })
  }
  h.meter.used = 95
  assert.deepEqual(await h.toolCall({ agentId: 'agent-1' }), { result: 'ran' })
  assert.equal(h.calls.aborts.length, 0)
  assert.match((await h.toolCall()).deny, /额度快用完/)
})

test('a paused task goes on even when what its compaction cost cannot be kept', async () => {
  const h = harness()
  h.storeFailure = 'calibration'
  assert.match((await pausedAtHardLine(h)).deny, /额度快用完/)
  await h.advance(5_000)
  assert.equal(h.calls.commands.length, 1)
  assert.equal(h.calls.submits.length, 1)
  assertContinuationPrompt(h.calls.submits[0].text)
  const [result] = h.results()
  assert.equal(result.status, 'compacted')
  assert.equal(result.resumed, true)
  assert.equal(h.status().state, 'watching')
})

test('a paused task that cannot be told to go on says so in its result', async () => {
  const h = harness()
  h.submitFailure = 'Prompt queue is full'
  await pausedAtHardLine(h)
  await h.advance(5_000)
  assert.equal(h.calls.submits.length, 1)
  const [result] = h.results()
  assert.equal(result.status, 'compacted')
  assert.equal(result.resumed, false)
  assert.equal(result.error, 'the task could not be resumed: Prompt queue is full')
  assert.equal(h.status().state, 'watching')
})

test('a dropped or malformed continuation is reported as still paused, without retrying it', async () => {
  for (const result of [{ drop: 'A prompt hook blocked continuation' }, undefined, {}, { text: 'rewritten', drop: 'blocked' }]) {
    const h = harness()
    h.submitResult = result
    await pausedAtHardLine(h)
    await h.advance(5_000)
    assert.equal(h.calls.aborts.length, 1)
    assert.equal(h.calls.submits.length, 1)
    assert.equal(h.results()[0].resumed, false)
    assert.match(h.results()[0].error, /^the task could not be resumed:/)
    assert.equal(h.results()[0].status, 'compacted')
  }
})

test('a task paused behind an early compaction that cannot be told to go on says so', async () => {
  const h = harness()
  h.files.set(`${DIR}/lock.json`, JSON.stringify({ sessionID: 'session-b', until: start + 20_000 }))
  await h.start()
  await h.turnStart('turn-1')
  h.meter.used = 88
  await h.turnComplete('turn-1')
  await h.advance(1_000)
  await h.turnStart('long-turn')
  h.meter.used = 95
  assert.match((await h.toolCall()).deny, /额度快用完/)
  h.submitFailure = 'Prompt queue is full'
  await h.advance(30_000)
  // Compacted once, by the early line; the paused task found it done and could not go on.
  assert.equal(h.calls.commands.length, 1)
  assert.deepEqual(h.results().map(result => [result.reason, result.status, result.resumed]),
    [['early', 'compacted', false], ['hard', 'skipped', false]])
  assert.equal(h.results()[1].error, 'the task could not be resumed: Prompt queue is full')
})

test('a switch turned off since the last check stops nothing at the hard line', async () => {
  const h = harness()
  await h.start()
  await h.turnStart('t')
  h.meter.used = 95
  // Turned off in CC-Relay a moment ago; the half-minute check has not read it yet.
  h.files.set(`${DIR}/settings.json`, JSON.stringify({ enabled: false, language: 'zh-Hans' }))
  assert.deepEqual(await h.toolCall(), { result: 'ran' })
  assert.deepEqual(h.calls.aborts, [])
  await h.advance(5_000)
  assert.equal(h.calls.commands.length, 0)
  assert.equal(h.calls.submits.length, 0)
})

test('two tool calls of one step at the hard line stop the task once', async () => {
  const h = harness()
  await h.start()
  await h.turnStart('t')
  h.meter.used = 95
  const answers = await Promise.all([h.toolCall(), h.toolCall()])
  assert.equal(h.calls.aborts.length, 1)
  assert.equal(answers.filter(answer => answer.deny !== undefined).length, 1)
  await h.advance(60_000)
  assert.equal(h.calls.commands.length, 1)
  assert.equal(h.calls.submits.length, 1)
  assert.deepEqual(h.results().map(result => [result.reason, result.status, result.resumed]), [['hard', 'compacted', true]])
})

for (const language of ['zh-Hans', 'en']) test(`a failed compaction tries three times, records its failure and continues in English with ${language} settings`, async () => {
  const h = harness({ config: { enabled: true, language } })
  h.compaction = 'reject'
  await pausedAtHardLine(h)
  await h.advance(60_000)
  assert.equal(h.calls.commands.length, 3)
  assert.equal(h.calls.submits.length, 1)
  assertContinuationPrompt(h.calls.submits[0].text)
  const [result] = h.results()
  assert.equal(result.status, 'failed')
  // The host's reason, on one line.
  assert.equal(result.error, 'Unknown command /compact')
  assert.equal(result.resumed, true)
  assert.equal(h.status().state, 'watching')
})

test('a /compact that never ends is given up after 15 minutes; the task goes on and nothing queues behind it', async () => {
  const h = harness()
  h.compaction = 'hang'
  await pausedAtHardLine(h)
  await h.advance(10 * 60_000)
  assert.equal(h.status().state, 'paused')
  assert.equal(h.calls.submits.length, 0)
  await h.advance(6 * 60_000)
  assert.equal(h.calls.commands.length, 1)
  assert.equal(h.calls.submits.length, 1)
  assertContinuationPrompt(h.calls.submits[0].text)
  assert.equal(h.results()[0].error, 'the /compact command had not finished after 15 minutes')
  assert.deepEqual(h.results()[0].trace, { command: 'timed out', hook: 'not seen' })
  await replied(h, 'turn-2')
  assert.equal(h.calls.commands.length, 1)
})

test('a vetoed compaction is done for the window, with its reason, and a failed early one stops after three tries', async () => {
  const vetoed = harness({ used: 90 })
  vetoed.compaction = 'skip'
  await vetoed.start()
  await replied(vetoed)
  await replied(vetoed, 'turn-2')
  assert.equal(vetoed.calls.commands.length, 1)
  assert.equal(vetoed.results()[0].status, 'skipped')
  assert.equal(vetoed.results()[0].error, 'a PreCompact hook blocked it')
  assert.deepEqual(vetoed.results()[0].trace, { command: 'resolved', hook: 'skipped' })

  const failing = harness({ used: 90 })
  failing.compaction = 'reject'
  await failing.start()
  for (const turn of ['a', 'b', 'c', 'd']) await replied(failing, turn)
  assert.equal(failing.calls.commands.length, 3)
  assert.equal(failing.results().length, 3)
})

test('a compaction that fails inside /compact keeps the host reason, cut to one short line', async () => {
  const h = harness({ used: 90 })
  h.compaction = 'error'
  h.failure = 'API Error: ' + 'overloaded\n'.repeat(30)
  await h.start()
  await replied(h)
  const [result] = h.results()
  assert.equal(result.status, 'failed')
  assert.equal(result.error.length, 200)
  assert.match(result.error, /^API Error: overloaded overloaded/)
  assert.deepEqual(result.trace, { command: 'resolved', hook: 'failed' })
  assert.equal(result.tokensAfter, 300_000)
})

test('a /compact that ends without compacting is a failure, unless the conversation shrank', async () => {
  const silent = harness({ used: 90 })
  silent.compaction = 'silent'
  await silent.start()
  await replied(silent)
  assert.equal(silent.results()[0].status, 'failed')
  assert.equal(silent.results()[0].error, 'the /compact command finished without compacting')
  assert.deepEqual(silent.results()[0].trace, { command: 'resolved', hook: 'not seen' })

  const shrank = harness({ used: 90 })
  shrank.compaction = 'shrink'
  await shrank.start()
  await replied(shrank)
  const [result] = shrank.results()
  assert.equal(result.status, 'compacted')
  assert.equal(result.error, null)
  assert.equal(result.tokensAfter, 70_000)
})

test('passes every compaction it did not ask for through unchanged, failures included', async () => {
  const h = harness()
  await h.start()
  const answer = { messages: [{ role: 'user', text: 'summary', toolUses: [] }], tokensAfter: 1 }
  assert.equal(await h.compactHook({ trigger: 'manual' }, async () => answer), answer)
  const refusal = new Error('refused')
  await assert.rejects(h.compactHook({ trigger: 'auto' }, async () => { throw refusal }), error => error === refusal)
})

test('no /compact is asked for while the conversation is being compacted by someone else', async () => {
  const h = harness({ used: 90 })
  await h.start()
  let finish
  const running = h.compactHook({ trigger: 'manual' }, () => new Promise(resolve => { finish = resolve }))
  await replied(h)
  await h.advance(60_000)
  assert.equal(h.calls.commands.length, 0)
  finish({ messages: [], tokensAfter: 40_000 })
  await running
  // Once it has ended, a conversation still past the line is compacted as usual.
  await replied(h, 'turn-2')
  assert.equal(h.calls.commands.length, 1)
})

test('a /compact queued here gives way to a compaction that ran before it, which counts as done', async () => {
  const h = harness({ used: 90 })
  h.compaction = 'later'
  await h.start()
  await replied(h)
  assert.equal(h.calls.commands.length, 1)
  await h.advance(5_000)
  // The person's own /compact runs first, then the one this plugin queued.
  await h.compactHook({ trigger: 'manual' }, async () => ({ messages: [], tokensAfter: 40_000 }))
  const queued = await h.compactHook({ trigger: 'manual' }, async () => { throw new Error('compacted twice') })
  assert.match(queued.skip, /刚压缩过/)
  h.finishCommand()
  await h.advance(1_000)
  const last = h.results().at(-1)
  assert.equal(last.status, 'compacted')
  assert.equal(last.tokensAfter, 40_000)
  assert.equal(last.error, null)
  assert.equal(last.trace.hook, 'compacted meanwhile')
})

test('a task paused at the hard line continues after the person compacted without compacting twice', async () => {
  // The person's /compact, typed during the turn, runs before the one this plugin queued.
  const first = harness({ used: 50 })
  first.compaction = 'later'
  assert.match((await pausedAtHardLine(first)).deny, /额度快用完/)
  await first.advance(2_500)
  assert.equal(first.calls.commands.length, 1)
  await first.compactHook({ trigger: 'manual' }, async () => ({ messages: [], tokensAfter: 40_000 }))
  await first.compactHook({ trigger: 'manual' }, async () => { throw new Error('compacted twice') })
  first.finishCommand()
  await first.advance(1_000)
  assert.equal(first.calls.submits.length, 1)
  assertContinuationPrompt(first.calls.submits[0].text)
  assert.equal(first.results().at(-1).status, 'compacted')
  // The person's /compact is still running when the paused task's turn comes: it waits for that.
  const running = harness({ used: 50 })
  assert.match((await pausedAtHardLine(running)).deny, /额度快用完/)
  let finish
  const compaction = running.compactHook({ trigger: 'manual' }, () => new Promise(resolve => { finish = resolve }))
  await running.advance(6_000)
  assert.equal(running.calls.commands.length, 0)
  assert.equal(running.calls.submits.length, 0)
  // As the host reports it: no context size right after a compaction, until the next response.
  running.meter.tokens = undefined
  finish({ messages: [], tokensAfter: 40_000 })
  await compaction
  await running.advance(2_500)
  assert.equal(running.calls.commands.length, 0)
  assert.equal(running.calls.submits.length, 1)
  assertContinuationPrompt(running.calls.submits[0].text)
})

test('a request before a switch waits for the person\'s own compaction instead of queueing another', async () => {
  const h = harness({ used: 30 })
  await h.start()
  await replied(h)
  let finish
  const running = h.compactHook({ trigger: 'manual' }, () => new Promise(resolve => { finish = resolve }))
  askBeforeSwitch(h, 21)
  await h.advance(6_000)
  assert.equal(h.calls.commands.length, 0)
  assert.equal(h.switchAnswer().status, 'compacting')
  // As the host reports it: no context size right after a compaction, until the next response.
  h.meter.tokens = undefined
  finish({ messages: [], tokensAfter: 40_000 })
  await running
  await h.advance(4_000)
  assert.equal(h.switchAnswer().status, 'compacted')
  assert.equal(h.switchAnswer().tokensAfter, 40_000)
  assert.equal(h.calls.commands.length, 0)
})

test('a request right after a compaction answers compacted, though the host has no context size yet', async () => {
  const h = harness({ used: 30 })
  await h.start()
  await replied(h)
  await h.compactHook({ trigger: 'manual' }, async () => ({ messages: [], tokensAfter: 40_000 }))
  h.meter.tokens = undefined
  askBeforeSwitch(h, 22)
  await h.advance(4_000)
  assert.equal(h.switchAnswer().status, 'compacted')
  assert.equal(h.calls.commands.length, 0)
  // A conversation with no size and no compaction behind it is still short.
  const fresh = harness({ used: 30 })
  await fresh.start()
  await replied(fresh)
  fresh.meter.tokens = undefined
  askBeforeSwitch(fresh, 23)
  await fresh.advance(4_000)
  assert.equal(fresh.switchAnswer().status, 'skipped')
  assert.equal(fresh.switchAnswer().error, 'the conversation is short')
})

test('a request that waited for a task paused at the hard line answers compacted, though the task went on already', async () => {
  const h = harness({ used: 50 })
  h.compaction = 'later'
  assert.match((await pausedAtHardLine(h)).deny, /额度快用完/)
  askBeforeSwitch(h, 24, { until: start + 10 * 60_000 })
  await h.advance(2_500)
  assert.equal(h.calls.commands.length, 1)
  assert.equal(h.switchAnswer().status, 'compacting')
  // The paused task's /compact runs; as the host reports it, no context size until the next response.
  await h.compactHook({ trigger: 'manual' }, async () => ({ messages: [], tokensAfter: 40_000 }))
  h.meter.tokens = undefined
  h.finishCommand()
  await h.advance(10)
  assertContinuationPrompt(h.calls.submits[0].text)
  // The task goes on at once: its turn has begun when the request looks again.
  await h.turnStart('resumed')
  await h.advance(4_000)
  assert.equal(h.switchAnswer().status, 'compacted')
  assert.equal(h.switchAnswer().tokensAfter, 40_000)
  assert.equal(h.calls.commands.length, 1)
})

test('nothing happens when switched off in CC-Relay or at 99 percent', async () => {
  const off = harness({ used: 90, config: { enabled: false } })
  await off.start()
  await replied(off)
  assert.equal(off.status().enabled, false)
  const full = harness({ used: 99 })
  await full.start()
  await full.turnStart()
  await full.toolCall()
  await full.turnComplete()
  await full.advance(1_000)
  for (const h of [off, full]) assert.equal(h.calls.commands.length, 0)
  assert.deepEqual(full.calls.aborts, [])
})

test('waits while another conversation is compacting', async () => {
  const h = harness()
  h.files.set(`${DIR}/lock.json`, JSON.stringify({ sessionID: 'session-b', until: start + 10_000 }))
  await h.start()
  await h.turnStart()
  h.meter.used = 90
  await h.turnComplete()
  await h.advance(1_000)
  assert.equal(h.calls.commands.length, 0)
  await h.advance(12_000)
  assert.equal(h.calls.commands.length, 1)
  assert.equal(JSON.parse(h.files.get(`${DIR}/lock.json`)).until, 0)
})

test('a task paused behind a waiting early compaction is compacted once and goes on', async () => {
  const h = harness()
  h.files.set(`${DIR}/lock.json`, JSON.stringify({ sessionID: 'session-b', until: start + 20_000 }))
  await h.start()
  await h.turnStart('turn-1')
  h.meter.used = 88
  await h.turnComplete('turn-1')
  await h.advance(1_000)
  // The early compaction waits for the other conversation; meanwhile a long task reaches the hard line.
  await h.turnStart('long-turn')
  h.meter.used = 95
  assert.match((await h.toolCall()).deny, /额度快用完/)
  await h.advance(30_000)
  assert.equal(h.calls.commands.length, 1)
  assert.equal(h.calls.submits.length, 1)
  assertContinuationPrompt(h.calls.submits[0].text)
  assert.equal(h.status().state, 'watching')
})

test('an early compaction that waited gives way to a turn begun meanwhile, and its hard line still stops it', async () => {
  const h = harness()
  h.files.set(`${DIR}/lock.json`, JSON.stringify({ sessionID: 'session-b', until: start + 20_000 }))
  await h.start()
  await h.turnStart('turn-1')
  h.meter.used = 88
  await h.turnComplete('turn-1')
  await h.advance(1_000)
  // The person starts the next task while the early compaction waits for the other conversation.
  await h.turnStart('turn-2')
  await h.advance(30_000)
  // Nothing queued behind the running task.
  assert.equal(h.calls.commands.length, 0)
  assert.equal(h.status().state, 'watching')
  h.meter.used = 95
  assert.match((await h.toolCall()).deny, /额度快用完/)
  await h.advance(2_000)
  assert.equal(h.calls.commands.length, 1)
  assert.equal(h.results()[0].reason, 'hard')
  assertContinuationPrompt(h.calls.submits[0].text)
})

test('a task paused behind a declined compaction is told the context was not compacted', async () => {
  const h = harness()
  h.files.set(`${DIR}/lock.json`, JSON.stringify({ sessionID: 'session-b', until: start + 2_000 }))
  await h.start()
  await h.turnStart('turn-1')
  h.meter.used = 88
  await h.turnComplete('turn-1')
  await h.advance(1_000)
  // A long task reaches the hard line while the early compaction waits; then a hook declines it.
  await h.turnStart('long-turn')
  h.meter.used = 95
  assert.match((await h.toolCall()).deny, /额度快用完/)
  h.compaction = 'skip'
  await h.advance(30_000)
  assert.equal(h.calls.commands.length, 1)
  assert.deepEqual(h.results().map(result => [result.reason, result.status]), [['early', 'skipped']])
  assert.equal(h.meter.tokens, 300_000)
  assert.equal(h.calls.submits.length, 1)
  assertContinuationPrompt(h.calls.submits[0].text)
})

test('the lines never move later than 12 and 8 percent left, only earlier when compaction is costly', async () => {
  const cheap = harness({ used: 89 })
  await cheap.start()
  await replied(cheap)
  assert.equal(cheap.store.get('calibration').per100k, 1 / 3)
  cheap.meter.resetsAt = new Date(start + 8 * 3_600_000).toISOString()
  cheap.meter.used = 10
  cheap.meter.tokens = 300_000
  await replied(cheap, 'turn-2')
  assert.deepEqual(cheap.status().lines, { early: 88, hard: 92 })

  const costly = harness({ used: 89 })
  costly.meter.compactCost = 6
  await costly.start()
  await replied(costly)
  assert.equal(costly.store.get('calibration').per100k, 2)
  costly.meter.resetsAt = new Date(start + 8 * 3_600_000).toISOString()
  costly.meter.used = 10
  costly.meter.tokens = 300_000
  await replied(costly, 'turn-2')
  // 300 000 tokens now take 6 percent: both lines move earlier to leave room for it.
  assert.deepEqual(costly.status().lines, { early: 82, hard: 91 })
})

test('a fast rise moves the lines earlier for half an hour, then they come back', async () => {
  const h = harness({ used: 60 })
  await h.start()
  await replied(h)
  await h.advance(30_000)
  // Six percent within half a minute: the next step may be as large, so both lines move earlier.
  h.meter.used = 66
  await h.advance(60_000)
  assert.deepEqual(h.status().lines, { early: 75, hard: 85 })
  assert.equal(h.calls.commands.length, 0)
  await h.advance(31 * 60_000)
  assert.deepEqual(h.status().lines, { early: 88, hard: 92 })
})

test('a rise across a long gap, such as the Mac asleep, leaves the lines alone', async () => {
  const h = harness({ used: 60 })
  h.meter.resetsAt = new Date(start + 6 * 3_600_000).toISOString()
  await h.start()
  await replied(h)
  await h.advance(30_000)
  h.asleep(3 * 3_600_000)
  h.meter.used = 85
  await h.advance(60_000)
  assert.deepEqual(h.status().lines, { early: 88, hard: 92 })
})

test('a rise that piled up while the conversation sat idle is not taken for a quick step', async () => {
  const h = harness({ used: 60 })
  await h.start()
  await replied(h)
  // Twenty minutes of half-minute checks see the same figure; the next reply brings it up to date.
  await h.advance(20 * 60_000)
  h.meter.used = 70
  await replied(h, 'turn-2')
  assert.deepEqual(h.status().lines, { early: 88, hard: 92 })
})

test('a queued compaction checks again before it starts and leaves a conversation that no longer qualifies', async () => {
  // The switch goes off while it waits for another conversation.
  const off = harness({ used: 90 })
  off.files.set(`${DIR}/lock.json`, JSON.stringify({ sessionID: 'session-b', until: start + 10_000 }))
  await off.start()
  await replied(off)
  off.files.set(`${DIR}/settings.json`, JSON.stringify({ enabled: false, language: 'zh-Hans' }))
  await off.advance(12_000)
  // A new window starts while it waits.
  const reset = harness({ used: 90 })
  reset.files.set(`${DIR}/lock.json`, JSON.stringify({ sessionID: 'session-b', until: start + 10_000 }))
  await reset.start()
  await replied(reset)
  reset.meter.resetsAt = new Date(start + 5 * 3_600_000).toISOString()
  reset.meter.used = 3
  await reset.advance(12_000)
  for (const h of [off, reset]) {
    assert.equal(h.calls.commands.length, 0)
    const [result] = h.results()
    assert.equal(result.status, 'skipped')
    assert.equal(result.error, 'the conversation no longer meets the compaction conditions')
  }
})

test('a paused task whose compaction no longer qualifies goes on without one', async () => {
  const h = harness()
  h.files.set(`${DIR}/lock.json`, JSON.stringify({ sessionID: 'session-b', until: start + 10_000 }))
  await pausedAtHardLine(h)
  h.files.set(`${DIR}/settings.json`, JSON.stringify({ enabled: false, language: 'zh-Hans' }))
  await h.advance(12_000)
  assert.equal(h.calls.commands.length, 0)
  assert.equal(h.calls.submits.length, 1)
  assertContinuationPrompt(h.calls.submits[0].text)
  assert.equal(h.results()[0].status, 'skipped')
  assert.equal(h.status().state, 'watching')
})

test('a /compact still running after the timeout keeps the lease, and gives it back when it ends', async () => {
  const h = harness({ used: 90 })
  h.compaction = 'later'
  await h.start()
  await replied(h)
  assert.equal(h.calls.commands.length, 1)
  const lease = () => JSON.parse(h.files.get(`${DIR}/lock.json`))
  await h.advance(16 * 60_000)
  assert.equal(h.results()[0].error, 'the /compact command had not finished after 15 minutes')
  // Still running: the lease is renewed, so other conversations keep waiting.
  assert.equal(lease().sessionID, 'session-a')
  assert.ok(lease().until > start + 16 * 60_000)
  assert.equal(h.status().state, 'compacting')
  h.finishCommand()
  await h.advance(1_000)
  assert.equal(lease().until, 0)
  assert.equal(h.status().state, 'watching')
})

test('no second /compact in a conversation while its last one is still running', async () => {
  const h = harness({ used: 90 })
  h.compaction = 'later'
  await h.start()
  await replied(h)
  await h.advance(16 * 60_000)
  // A new window, past the line again: the first /compact has not ended, so nothing new starts.
  h.meter.resetsAt = new Date(start + 8 * 3_600_000).toISOString()
  await replied(h, 'turn-2')
  assert.equal(h.calls.commands.length, 1)
  h.finishCommand()
  await h.advance(1_000)
  await replied(h, 'turn-3')
  assert.equal(h.calls.commands.length, 2)
})

test('a /compact unfinished after half an hour stops holding the others back', async () => {
  const h = harness({ used: 90 })
  h.compaction = 'hang'
  await h.start()
  await replied(h)
  await h.advance(31 * 60_000)
  assert.equal(JSON.parse(h.files.get(`${DIR}/lock.json`)).until, 0)
  h.meter.resetsAt = new Date(start + 8 * 3_600_000).toISOString()
  await replied(h, 'turn-2')
  assert.equal(h.calls.commands.length, 2)
})

test('a test request lowers only the named conversation\'s early line to 0, and the normal flow compacts it after the reply', async () => {
  const h = harness({ used: 30 })
  await h.start()
  await h.turnStart('t')
  h.files.set(`${DIR}/test-request.json`, JSON.stringify({ id: 7, sessionID: 'session-a', until: start + 10 * 60_000 }))
  await h.advance(30_000)
  // Busy: the early line waits for the reply, as always.
  assert.equal(h.calls.commands.length, 0)
  assert.deepEqual(h.status().lines, { early: 0, hard: 92 })
  await h.turnComplete('t')
  await h.advance(1_000)
  assert.equal(h.calls.commands.length, 1)
  const [result] = h.results()
  assert.equal(result.reason, 'early')
  assert.equal(result.test, 7)
  assert.equal(result.status, 'compacted')
  assert.deepEqual(result.lines, { early: 0, hard: 92 })
  // Once per window, as always.
  await replied(h, 'turn-2')
  await h.advance(60_000)
  assert.equal(h.calls.commands.length, 1)
})

test('a test request leaves other conversations, expired requests, the switch and the size minimum as they are', async () => {
  const cases = [
    { request: { id: 1, sessionID: 'session-b', until: start + 600_000 } },
    { request: { id: 2, sessionID: 'session-a', until: start } },
    { request: { id: 3, sessionID: 'session-a', until: start + 600_000 }, config: { enabled: false } },
    { request: { id: 4, sessionID: 'session-a', until: start + 600_000 }, tokens: 50_000 },
  ]
  for (const { request, config, tokens } of cases) {
    const h = harness({ used: 30, tokens, config: config ?? { enabled: true, language: 'zh-Hans' } })
    h.files.set(`${DIR}/test-request.json`, JSON.stringify(request))
    await h.start()
    await replied(h)
    await h.advance(30_000)
    assert.equal(h.calls.commands.length, 0, `request ${request.id}`)
  }
})

test('the early line comes back when the test request expires', async () => {
  const h = harness({ used: 30 })
  h.files.set(`${DIR}/test-request.json`, JSON.stringify({ id: 5, sessionID: 'session-a', until: start + 60_000 }))
  // No turn yet, so the conversation is not recent and the normal flow compacts nothing.
  await h.start()
  assert.deepEqual(h.status().lines, { early: 0, hard: 92 })
  await h.advance(90_000)
  assert.deepEqual(h.status().lines, { early: 88, hard: 92 })
  assert.equal(h.calls.commands.length, 0)
})

test('a request before a switch compacts the named conversation at once, whatever its usage, and answers it', async () => {
  const h = harness({ used: 30 })
  await h.start()
  await replied(h)
  askBeforeSwitch(h, 11)
  await h.advance(2_000)
  assert.equal(h.calls.commands.length, 1)
  assert.deepEqual(h.calls.commands[0], { command: 'compact' })
  const answer = h.switchAnswer()
  assert.equal(answer.id, 11)
  assert.equal(answer.sessionID, 'session-a')
  assert.equal(answer.status, 'compacted')
  assert.equal(answer.tokensBefore, 300_000)
  assert.equal(answer.tokensAfter, 70_000)
  assert.equal(answer.error, null)
  // Logged and shown like any compaction, as one made before a switch.
  const [result] = h.results()
  assert.equal(result.reason, 'switch')
  assert.equal(result.status, 'compacted')
  assert.equal(JSON.parse(h.files.get(`${DIR}/lock.json`)).until, 0)
  // Answered once, even when the conversation is long again.
  h.meter.tokens = 400_000
  await h.advance(10_000)
  assert.equal(h.calls.commands.length, 1)
})

test('a compaction before a switch is recorded in the fields of every other, with or without a usage window', async () => {
  for (const kind of ['five_hour', 'opus_weekly']) {
    const h = harness({ used: 30 })
    h.meter.kind = kind
    await h.start()
    await replied(h)
    askBeforeSwitch(h, 15)
    await h.advance(2_000)
    const [result] = h.results()
    const windowed = kind === 'five_hour'
    assert.deepEqual(Object.keys(result).sort(), ['error', 'finishedAt', 'lines', 'reason', 'resumed', 'sessionID',
      'startedAt', 'status', 'test', 'tokensAfter', 'tokensBefore', 'trace', 'usedAfter', 'usedBefore', 'version',
      'window'], kind)
    assert.equal(result.reason, 'switch', kind)
    assert.equal(result.status, 'compacted', kind)
    assert.equal(result.window, windowed ? 'five_hour' : null, kind)
    assert.equal(result.usedBefore, windowed ? 30 : null, kind)
    assert.equal(result.usedAfter, windowed ? 31 : null, kind)
    assert.equal(result.tokensBefore, 300_000, kind)
    assert.equal(result.tokensAfter, 70_000, kind)
    assert.equal(result.error, null, kind)
    assert.deepEqual(result.trace, { command: 'resolved', hook: 'compacted' }, kind)
    assert.equal(result.test, null, kind)
    assert.equal(result.resumed, false, kind)
  }
})

test('a request before a switch is answered even when keeping its cost or its record fails', async () => {
  // CC-Relay waits on the answer: nothing after the compaction may keep it from going out.
  for (const failing of ['cost', 'record']) {
    const h = harness({ used: 30 })
    if (failing === 'cost') h.storeFailure = 'calibration'
    else h.writeFailure = '/results/'
    await h.start()
    await replied(h)
    askBeforeSwitch(h, 12)
    await h.advance(2_000)
    assert.equal(h.calls.commands.length, 1, failing)
    const answer = h.switchAnswer()
    assert.equal(answer?.status, 'compacted', failing)
    assert.equal(answer?.tokensAfter, 70_000, failing)
  }
})

test('a request before a switch that fails on the way is answered as failed, with why', async () => {
  const h = harness({ used: 30 })
  h.writeFailure = '/lock.json'
  await h.start()
  await replied(h)
  askBeforeSwitch(h, 13)
  await h.advance(2_000)
  assert.equal(h.calls.commands.length, 0)
  const answer = h.switchAnswer()
  assert.equal(answer?.status, 'failed')
  assert.equal(answer?.error, 'the disk is full')
})

test('a request before a switch says when its compaction begins, so the switch waits for it to end', async () => {
  const h = harness({ used: 30 })
  h.compaction = 'later'
  await h.start()
  await replied(h)
  askBeforeSwitch(h, 14)
  await h.advance(2_000)
  assert.equal(h.calls.commands.length, 1)
  const begun = h.switchAnswer()
  assert.equal(begun?.id, 14)
  assert.equal(begun?.status, 'compacting')
  // Still under way well past the time the switch waits for a start.
  await h.advance(5 * 60_000)
  assert.equal(h.switchAnswer().status, 'compacting')
  h.meter.tokens = 70_000
  h.finishCommand()
  await h.advance(4_000)
  assert.equal(h.switchAnswer().status, 'compacted')
  assert.equal(h.switchAnswer().tokensAfter, 70_000)
})

test('a request before a switch is for its own conversation only, and not after it expires', async () => {
  const cases = [
    { sessionID: 'session-b', until: start + 3 * 60_000 },
    { sessionID: 'session-a', until: start },
  ]
  for (const request of cases) {
    const h = harness({ used: 30 })
    await h.start()
    await replied(h)
    askBeforeSwitch(h, 21, request)
    await h.advance(10_000)
    assert.equal(h.calls.commands.length, 0, request.sessionID)
    assert.equal(h.switchAnswer(), undefined, request.sessionID)
  }
})

test('a request before a switch that cannot be met now is answered at once, with why', async () => {
  const cases = [
    { name: 'short', options: { tokens: 50_000 }, error: 'the conversation is short' },
    { name: 'off', options: { config: { enabled: false } }, error: 'automatic compaction is off' },
    { name: 'at the limit', options: { used: 99 }, error: 'the account is at its limit' },
    { name: 'not used within the hour', options: {}, idle: true, error: 'the conversation was not used within the hour' },
    { name: 'busy', options: {}, busy: true, error: 'a turn is running' },
  ]
  for (const { name, options, idle, busy, error } of cases) {
    const h = harness({ used: 30, ...options })
    await h.start()
    if (busy) await h.turnStart('t')
    else if (!idle) await replied(h)
    askBeforeSwitch(h, 31)
    await h.advance(2_000)
    assert.equal(h.calls.commands.length, 0, name)
    const answer = h.switchAnswer()
    assert.equal(answer.status, 'skipped', name)
    assert.equal(answer.error, error, name)
    assert.deepEqual(h.results(), [], name)
  }
})

test('a request before a switch waits for another conversation\'s compaction, and the early line keeps out meanwhile', async () => {
  const h = harness({ used: 30 })
  h.files.set(`${DIR}/lock.json`, JSON.stringify({ sessionID: 'session-b', until: start + 40_000 }))
  await h.start()
  await replied(h)
  askBeforeSwitch(h, 41)
  await h.advance(2_000)
  assert.equal(h.calls.commands.length, 0)
  // Past the early line while it waits: the half-minute check leaves it to the switch.
  h.meter.used = 95
  await h.advance(30_000)
  assert.equal(h.calls.commands.length, 0)
  await h.advance(10_000)
  assert.equal(h.calls.commands.length, 1)
  assert.equal(h.switchAnswer().status, 'compacted')
  assert.deepEqual(h.results().map(result => result.reason), ['switch'])
  await h.advance(60_000)
  assert.equal(h.calls.commands.length, 1)
})

test('a request before a switch gives up waiting for the lease when it expires', async () => {
  const h = harness({ used: 30 })
  h.files.set(`${DIR}/lock.json`, JSON.stringify({ sessionID: 'session-b', until: start + 10 * 60_000 }))
  await h.start()
  await replied(h)
  askBeforeSwitch(h, 51, { until: start + 30_000 })
  await h.advance(40_000)
  assert.equal(h.calls.commands.length, 0)
  const answer = h.switchAnswer()
  assert.equal(answer.status, 'failed')
  assert.equal(answer.error, 'another conversation on this Mac was compacting')
})

test('a request before a switch that waited for the lease through a sleep begins nothing past its time', async () => {
  const h = harness({ used: 30 })
  h.files.set(`${DIR}/lock.json`, JSON.stringify({ sessionID: 'session-b', until: start + 60_000 }))
  await h.start()
  await replied(h)
  askBeforeSwitch(h, 61, { until: start + 170_000 })
  await h.advance(5_000)
  assert.equal(h.calls.commands.length, 0)
  // The Mac sleeps while it waits: on waking, the lease and the time CC-Relay waits for a start are both over.
  h.asleep(240_000)
  await h.advance(10_000)
  assert.equal(h.calls.commands.length, 0)
  const answer = h.switchAnswer()
  assert.equal(answer.status, 'failed')
  assert.equal(answer.error, 'another conversation on this Mac was compacting')
})

test('a request before a switch that waited for the lease looks again before it compacts', async () => {
  const h = harness({ used: 30 })
  h.files.set(`${DIR}/lock.json`, JSON.stringify({ sessionID: 'session-b', until: start + 20_000 }))
  await h.start()
  await replied(h)
  askBeforeSwitch(h, 121)
  await h.advance(2_000)
  // The account runs out while it waits.
  h.meter.used = 100
  await h.advance(30_000)
  assert.equal(h.calls.commands.length, 0)
  const answer = h.switchAnswer()
  assert.equal(answer.status, 'skipped')
  assert.equal(answer.error, 'the account is at its limit')
  assert.equal(JSON.parse(h.files.get(`${DIR}/lock.json`)).until, 0)
})

test('an early attempt waiting for the lease gives way to a switch that asks meanwhile, then tries again', async () => {
  const h = harness({ used: 90 })
  h.files.set(`${DIR}/lock.json`, JSON.stringify({ sessionID: 'session-b', until: start + 25_000 }))
  h.compaction = 'reject'
  await h.start()
  await replied(h)
  assert.equal(h.calls.commands.length, 0)
  askBeforeSwitch(h, 91)
  await h.advance(34_000)
  // The switch's /compact went first. It failed and the conversation is still past the early
  // line, so the half-minute check tried again.
  assert.equal(h.switchAnswer().status, 'failed')
  assert.deepEqual(h.results().map(result => [result.reason, result.status]), [['switch', 'failed'], ['early', 'failed']])
})

test('while a switch waits on its compaction, the hard line leaves a turn begun meanwhile alone', async () => {
  const h = harness({ used: 30 })
  h.files.set(`${DIR}/lock.json`, JSON.stringify({ sessionID: 'session-b', until: start + 40_000 }))
  await h.start()
  await replied(h)
  askBeforeSwitch(h, 101)
  await h.advance(2_000)
  h.meter.used = 95
  await h.turnStart('turn-2')
  const call = await h.toolCall()
  assert.deepEqual(call, { result: 'ran' })
  assert.deepEqual(h.calls.aborts, [])
  await h.turnComplete('turn-2')
  await h.advance(60_000)
  assert.equal(h.switchAnswer().status, 'compacted')
  assert.equal(h.calls.commands.length, 1)
})

test('a compaction of its own still running when a switch asks keeps the switch waiting past the request\'s start time', async () => {
  // It has begun: the switch is told so and waits for it, rather than closing Claude under it.
  const h = harness({ used: 90 })
  h.compaction = 'later'
  await h.start()
  await replied(h)
  assert.equal(h.calls.commands.length, 1)
  askBeforeSwitch(h, 111, { until: start + 30_000 })
  await h.advance(40_000)
  assert.equal(h.switchAnswer().status, 'compacting')
  h.meter.tokens = 70_000
  h.finishCommand()
  await h.advance(4_000)
  assert.equal(h.switchAnswer().status, 'compacted')
  assert.equal(h.calls.commands.length, 1)
})

test('a request taken back while it waits is let go without compacting', async () => {
  for (const waitingFor of ['another conversation', 'its own compaction']) {
    const h = harness({ used: waitingFor === 'another conversation' ? 30 : 90 })
    if (waitingFor === 'another conversation') {
      h.files.set(`${DIR}/lock.json`, JSON.stringify({ sessionID: 'session-b', until: start + 40_000 }))
    } else {
      h.compaction = 'later'
    }
    await h.start()
    await replied(h)
    const before = h.calls.commands.length
    askBeforeSwitch(h, 81)
    await h.advance(2_000)
    // The user skipped: CC-Relay took the request back and went on with the switch.
    h.files.delete(`${DIR}/switch-request.json`)
    await h.advance(60_000)
    assert.equal(h.calls.commands.length, before, waitingFor)
    const answer = h.switchAnswer()
    assert.equal(answer.status, 'skipped', waitingFor)
    assert.equal(answer.error, 'the switch went on without it', waitingFor)
    assert.equal(h.results().some(result => result.reason === 'switch'), false, waitingFor)
  }
})

test('a request before a switch compacts again a conversation already compacted this window', async () => {
  const h = harness({ used: 90 })
  await h.start()
  await replied(h)
  assert.equal(h.calls.commands.length, 1)
  h.meter.tokens = 400_000
  await replied(h, 'turn-2')
  assert.equal(h.calls.commands.length, 1)
  askBeforeSwitch(h, 61)
  await h.advance(2_000)
  assert.equal(h.calls.commands.length, 2)
  assert.equal(h.switchAnswer().status, 'compacted')
  assert.equal(h.switchAnswer().tokensBefore, 400_000)
})

test('a compaction already running when a switch asks is waited for, not started twice', async () => {
  const h = harness({ used: 90 })
  h.compaction = 'later'
  await h.start()
  await replied(h)
  assert.equal(h.calls.commands.length, 1)
  askBeforeSwitch(h, 71)
  await h.advance(4_000)
  assert.equal(h.switchAnswer().status, 'compacting')
  // The early line's /compact ends, and the conversation is small now.
  h.meter.tokens = 70_000
  h.finishCommand()
  await h.advance(4_000)
  assert.equal(h.calls.commands.length, 1)
  const answer = h.switchAnswer()
  assert.equal(answer.status, 'compacted')
  assert.equal(answer.tokensBefore, 300_000)
  assert.equal(answer.tokensAfter, 70_000)
  assert.deepEqual(h.results().map(result => result.reason), ['early'])
})

test('UI messages default to English and the continuation stays concise', async () => {
  const h = harness({ config: { enabled: true } })
  h.compaction = 'reject'
  const paused = await pausedAtHardLine(h)
  assert.match(paused.deny, /^Paused: this account/)
  await h.advance(60_000)
  assertContinuationPrompt(h.calls.submits[0].text)
})
