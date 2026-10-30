import assert from 'node:assert/strict'
import test from 'node:test'
import { register as registerNative } from '../hooks/native-continuity.js'
import { register as registerCompactor } from '../hooks/low-quota-compactor.js'

const HOME = '/tmp/cc-relay-hook-failure-fixture'
const ROOT = `${HOME}/Library/Application Support/CC-Relay/NativeRecovery`
const COMPACT = `${HOME}/Library/Application Support/CC-Relay/AutoCompact`
const NOW = 1793000000000
const SESSION = 'failure-session'

// Models the host's registration-level failure dispatcher, including cached next results. A fault
// is injected at the dispatch boundary, not by invoking a handler's .catch directly. It represents
// a host deadline before next, or result validation after the hook has executed the core operation.
function harness(register) {
  const hooks = [], timers = [], files = new Map(), store = new Map(), calls = [], prompts = [], aborts = []
  let fault, tokens = 300000, used = 50, abortFailure = true, onPrompt
  files.set(`${HOME}/.claude/sessions/12345.json`, JSON.stringify({
    pid: 12345, sessionId: SESSION, procStart: 'fixture-birth', pidDomain: 'darwin', entrypoint: 'claude-desktop',
  }))
  files.set(`${COMPACT}/settings.json`, JSON.stringify({ enabled: true, language: 'en' }))
  register((name, matcher, hook) => {
    if (typeof matcher === 'function') [hook, matcher] = [matcher, undefined]
    const entry = { name, matcher, hook }; hooks.push(entry)
    return { catch(handler) { entry.caught = handler } }
  })
  const $ = {
    plugin: { root: '/plugin' },
    env: { get: async name => name === 'HOME' ? HOME : name === 'CLAUDE_CODE_ENTRYPOINT' ? 'claude-desktop' : undefined },
    fs: { read: async path => { if (!files.has(path)) throw new Error('missing'); return files.get(path) },
      exists: async path => files.has(path), write: async (path, value) => { files.set(path, value) } },
    clock: { now: async () => NOW, every: (ms, fn) => { timers.push({ ms, fn }) }, after: (ms, fn) => { timers.push({ ms, fn, once: true }) } },
    process: { run: async () => ({ exitCode: 0, stdout: '12345', stderr: '' }) },
    settings: { read: async () => ({}) },
    session: { id: async () => SESSION, messages: async () => [], usage: async () => ({
      context: { tokens, window: 1000000 }, rateLimits: [{ kind: 'five_hour', percentUsed: used, resetsAt: new Date(NOW + 3600000).toISOString() }],
    }) },
    agent: { list: async () => [] },
    store: { get: async key => store.get(key), set: async (key, value) => { store.set(key, value) } },
    tool: { list: async () => [], check: async () => ({ decision: 'allow' }), call: async event => { calls.push(event); return { result: 'done' } } },
    prompt: { submit: event => fire('prompt.submit', { ...event, origin: { kind: 'plugin', name: 'cc-relay' } }, async input => { prompts.push(input.text); await onPrompt?.(input.text); return { text: input.text } }) },
    turn: { abort: async input => { aborts.push(input.turnId); if (abortFailure) throw new Error('the fixture refuses cancellation') } },
    command: { run: async () => { tokens = 70000; return { text: 'compacted' } } },
  }
  async function fire(name, event, core = async event => event) {
    const entry = hooks.find(item => item.name === name && (!item.matcher || Object.entries(item.matcher).every(([key, value]) => value instanceof RegExp ? value.test(event[key]) : value === event[key])))
    if (!entry) return core(event)
    let settled
    const next = input => { next.called = true; settled = Promise.resolve().then(() => core(input)); return settled }
    next.called = false; next.origin = { plugin: 'engine', tier: 'core' }
    const injection = fault?.event === name ? fault : undefined
    if (injection) fault = undefined
    try {
      if (injection?.at === 'before') throw new Error('synthetic host deadline before dispatch')
      const result = await entry.hook($, event, next)
      if (injection?.at === 'after') throw new Error('synthetic host result validation failure')
      return result
    } catch (error) {
      if (!entry.caught) { if (next.called) return settled; return core(event) }
      const caught = input => next.called ? settled : next(input)
      caught.called = next.called
      caught.origin = next.origin
      caught.error = { kind: injection?.kind ?? 'throw', message: 'sensitive user text must not be persisted', budget: 1000 }
      return entry.caught($, event, caught)
    }
  }
  async function tick(ms) { for (const timer of [...timers]) if (timer.ms === ms) { if (timer.once) timers.splice(timers.indexOf(timer), 1); await timer.fn() }; await settle() }
  async function settle() { for (let n = 0; n < 12; n++) await new Promise(resolve => setImmediate(resolve)) }
  const nativeReport = () => JSON.parse(files.get([...files.keys()].find(path => path.includes('/runtimes/'))))
  function arm() {
    const runtime = nativeReport()
    files.set(`${ROOT}/active.json`, JSON.stringify({ version: 1, ready: true, operationID: 'operation', targetProfile: '/target', targetAccountID: 'target' }))
    files.set(`${ROOT}/requests/${SESSION}.json`, JSON.stringify({ version: 1, requiredCapability: 'native-recovery-v6', operationID: 'operation', requestID: 'request',
      sessionID: SESSION, phase: 'armed', targetProfile: '/target', targetAccountID: 'target', expiresAt: NOW + 600000, armedAt: NOW,
      sourceWasBusy: true, instanceID: runtime.instanceID, pid: runtime.pid, procStart: runtime.procStart,
      work: { version: 1, cliSessionID: SESSION, branchComplete: true, needsContinuation: true, tasks: [], artifacts: [] } }))
  }
  return { fire, files, calls, prompts, aborts, tick, settle, arm, nativeReport,
    boot: () => fire('session.start', { isInteractive: false, cwd: HOME, surface: null }),
    inject: (event, at, kind) => { fault = { event, at, kind } }, setUsed: value => { used = value }, setAbortFailure: value => { abortFailure = value },
    setOnPrompt: value => { onPrompt = value },
    compactReport: () => JSON.parse(files.get(`${COMPACT}/sessions/${SESSION}.json`)),
  }
}

for (const [module, register] of [['native', registerNative], ['compactor', registerCompactor]]) {
  for (const kind of ['throw', 'timeout']) for (const event of ['prompt.submit', 'tool.call']) {
    test(`${module} ${event}: ${kind} before next refuses only that dispatch and retains a redacted receipt`, async () => {
      const h = harness(register); await h.boot()
      let executions = 0
      const input = event === 'prompt.submit' ? { text: 'a normal user request', origin: { kind: 'composer' } } : { tool: 'Bash', command: 'fixture', tool_use_id: 'use' }
      const core = async event => { executions++; return event.tool ? { result: 'completed' } : { text: event.text } }
      h.inject(event, 'before', kind)
      const refused = await h.fire(event, input, core)
      assert.equal(executions, 0)
      assert.equal(typeof refused[event === 'prompt.submit' ? 'drop' : 'deny'], 'string')
      await h.tick(module === 'native' ? 5000 : 30000)
      const receipt = module === 'native' ? h.nativeReport() : h.compactReport()
      assert.deepEqual(receipt.hookFailure, { event, kind })
      assert.equal(JSON.stringify(receipt).includes('sensitive user text'), false)
      const result = await h.fire(event, input, core)
      assert.equal(result.drop, undefined); assert.equal(result.deny, undefined)
      assert.equal(executions, 1, 'a later ordinary user action is not permanently blocked')
    })
  }
  for (const event of ['prompt.submit', 'tool.call']) {
    test(`${module} ${event}: a failure after next preserves the exact result and executes once`, async () => {
      const h = harness(register); await h.boot()
      let executions = 0
      const input = event === 'prompt.submit' ? { text: 'user request', origin: { kind: 'composer' } } : { tool: 'Bash', command: 'fixture' }
      const result = input.tool ? { result: { stdout: 'already executed' } } : { text: input.text }
      h.inject(event, 'after', 'throw')
      assert.equal(await h.fire(event, input, async () => { executions++; return result }), result)
      assert.equal(executions, 1)
    })
  }
  test(`${module} failed turn guard does not cancel an unrelated user turn`, async () => {
    const h = harness(register); await h.boot()
    let starts = 0
    h.inject('turn.start', 'before', 'timeout')
    await h.fire('turn.start', { turnId: 'user-turn', text: 'a new task' }, async event => { starts++; return { turnId: event.turnId } })
    assert.deepEqual(h.aborts, []); assert.equal(starts, 1)
    assert.deepEqual(await h.fire('tool.call', { tool: 'Bash', command: 'user work' }, async () => ({ result: 'ran' })), { result: 'ran' })
  })
}

for (const at of ['before', 'after']) test(`a ${at}-next native turn guard failure still blocks the issued continuation when abort fails`, async () => {
  const h = harness(registerNative); await h.boot(); h.arm(); await h.tick(2000)
  assert.equal(h.prompts.length, 1)
  let starts = 0, tools = 0
  h.inject('turn.start', at, 'timeout')
  await h.fire('turn.start', { turnId: 'automatic', text: h.prompts[0] }, async event => { starts++; return { turnId: event.turnId } })
  assert.equal(starts, 1); assert.deepEqual(h.aborts, ['automatic'])
  const blocked = await h.fire('tool.call', { tool: 'Bash', command: 'must not execute' }, async () => { tools++; return { result: 'bad' } })
  assert.equal(typeof blocked.deny, 'string'); assert.equal(tools, 0)
  h.inject('turn.start', 'before', 'timeout')
  await h.fire('turn.start', { turnId: 'manual', text: 'new user work' })
  await h.fire('tool.call', { tool: 'Bash', command: 'new user work' }, async () => { tools++; return { result: 'okay' } })
  assert.equal(tools, 1)
})

for (const at of ['before', 'after']) test(`a ${at}-next native turn guard failure reports the continuation it stopped`, async () => {
  const h = harness(registerNative); await h.boot(); h.setAbortFailure(false); h.arm(); await h.tick(2000)
  assert.equal(h.prompts.length, 1)
  h.inject('turn.start', at, 'timeout')
  await h.fire('turn.start', { turnId: 'automatic', text: h.prompts[0] }, async event => ({ turnId: event.turnId }))
  // The host then ends the turn the plugin stopped. Nothing will take the work up again, so the
  // receipt says so at once rather than waiting as queued until the request expires.
  await h.fire('turn.complete', { turnId: 'automatic', reason: 'aborted', isAborted: true })
  for (let i = 0; i < 3; i++) await h.tick(2000)
  const result = JSON.parse(h.files.get(`${ROOT}/results/request.json`))
  assert.equal(result.status, 'needsAttention')
  assert.match(result.error, /guard/)
  assert.equal(h.prompts.length, 1, 'the stopped continuation is not submitted again')
})

for (const at of ['before', 'after']) for (const early of [false, true]) test(`a ${at}-next compactor turn guard failure reports its task as not resumed${early ? ', also before the compaction is recorded' : ''}`, async () => {
  const h = harness(registerCompactor); await h.boot(); h.setAbortFailure(false)
  await h.fire('turn.start', { turnId: 'original', text: 'original user task' })
  h.setUsed(95)
  await h.fire('tool.call', { tool: 'Bash', command: 'fixture' }, async () => ({ result: 'completed' }))
  const start = async text => {
    h.inject('turn.start', at, 'timeout')
    await h.fire('turn.start', { turnId: 'automatic', text }, async event => ({ turnId: event.turnId }))
  }
  if (early) h.setOnPrompt(start)
  await h.tick(2000)
  assert.equal(h.prompts.length, 1)
  if (!early) await start(h.prompts[0])
  await h.settle()
  assert.ok(h.aborts.includes('automatic'))
  // The latest record is what the panel shows: the task did not go on, once.
  const records = [...h.files.keys()].filter(path => path.startsWith(`${COMPACT}/results/`)).sort().map(path => JSON.parse(h.files.get(path)))
  const latest = records.at(-1)
  assert.equal(latest.resumed, false)
  assert.match(latest.error, /could not be resumed: .*guard/)
  assert.equal(records.filter(record => record.resumed === false).length, 1)
})

for (const at of ['before', 'after']) test(`a ${at}-next compactor turn guard failure keeps its issued continuation blocked`, async () => {
  const h = harness(registerCompactor); await h.boot(); h.setAbortFailure(false)
  await h.fire('turn.start', { turnId: 'original', text: 'original user task' })
  h.setUsed(95)
  await h.fire('tool.call', { tool: 'Bash', command: 'fixture' }, async () => ({ result: 'completed' }))
  await h.tick(2000)
  assert.equal(h.prompts.length, 1)
  h.setAbortFailure(true)
  let starts = 0, tools = 0
  h.inject('turn.start', at, 'timeout')
  await h.fire('turn.start', { turnId: 'automatic', text: h.prompts[0] }, async event => { starts++; return { turnId: event.turnId } })
  assert.equal(starts, 1); assert.ok(h.aborts.includes('automatic'))
  const blocked = await h.fire('tool.call', { tool: 'Bash', command: 'must not execute' }, async () => { tools++; return { result: 'bad' } })
  assert.equal(typeof blocked.deny, 'string'); assert.equal(tools, 0)
  h.inject('turn.start', 'before', 'timeout')
  await h.fire('turn.start', { turnId: 'manual', text: 'new user work' })
  await h.fire('tool.call', { tool: 'Bash', command: 'new user work' }, async () => { tools++; return { result: 'okay' } })
  assert.equal(tools, 1)
})
