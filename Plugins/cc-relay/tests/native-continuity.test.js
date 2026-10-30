import assert from 'node:assert/strict'
import test from 'node:test'
import { spawnSync } from 'node:child_process'
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, readdirSync, chmodSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { register } from '../hooks/native-continuity.js'
import { encodeResult } from '../hooks/native-command.js'
import { PLUGIN_VERSION } from '../hooks/version.js'

const HOME = '/tmp/native-continuity-tests'
const ROOT = `${HOME}/Library/Application Support/CC-Relay/NativeRecovery`
const SESSION = 'native-session'
const NOW = 1793000000000
const CONTINUATION = '[Continuation requestID=req-1]\nPlease continue the unfinished work from where it was interrupted, following the original instructions and scope of authorization.'
const AGENT = { id: 'agent-1', toolUseID: 'use-1', kind: 'agent', state: 'backgroundRegistered', agentType: 'general-purpose', sourceLine: 4 }
const URL = 'https://claude.ai/code/artifact/1234-abcd'
const WORKER = process.env.CC_RELAY_NATIVE_WORKER ?? fileURLToPath(new globalThis.URL('../../../.build/out/Products/Debug/CompanionNativeWorker', import.meta.url))

function harness({ files = new Map(), registry = {}, agents = [], histories = {}, tasks = [], artifacts = [], branchComplete = true, pid = 12345, worker = false, settings = {}, rateLimits = [], processes = '' } = {}) {
  const handlers = [], timers = [], calls = [], prompts = [], aborts = [], helperCalls = [], checks = [], psCalls = []
  let now = NOW, failWrite, promptResult, abortFailure, messageRows = [], ownReport, clockFailure = false, permission = 'allow', helperFailure = false, monitorResolution, artifactInput
  const toasts = [], liveWatches = []
  if (worker) files.set('/plugin/bin/CompanionNativeWorker', 'fixture-binary')
  const registration = { pid, sessionId: SESSION, procStart: 'Mon Oct 26 18:41:42 2026', pidDomain: 'darwin', entrypoint: 'claude-desktop', ...registry }
  files.set(`${HOME}/.claude/sessions/${pid}.json`, JSON.stringify(registration))
  let toolResponse = event => event.tool === 'ArtifactComments' && !event.url
    ? { result: { watches: liveWatches } } : event.tool === 'ArtifactComments'
      ? (() => {
        if (event.replies) {
          return { result: { resume_replies: { url: event.url, resumed: false, outcome: 'skipped', reason: 'not_stopped' } } }
        }
        const watch = liveWatches.find(item => item.url === event.url)
        if (watch) watch.auto_reply = 'armed'
        else liveWatches.push({ url: event.url, connected: true, auto_reply: 'armed', task_id: 'watch-1' })
        return { result: { watch: { url: event.url, watching: true, auto_reply: 'armed', task_id: 'watch-1' } } }
      })() : { result: { success: true } }
  register((name, matcher, handler) => {
    if (typeof matcher === 'function') [handler, matcher] = [matcher, undefined]
    const entry = { name, matcher, handler }; handlers.push(entry)
    return { catch(fn) { entry.caught = fn } }
  })
  const $ = {
    ui: { toast: message => { toasts.push(message) } },
    plugin: { root: '/plugin' }, settings: { read: async () => settings },
    env: { get: async key => key === 'HOME' ? HOME : key === 'CLAUDE_CODE_ENTRYPOINT' ? 'claude-desktop' : undefined },
    clock: { now: async () => { if (clockFailure) throw new Error('host clock unavailable'); return now }, every: (ms, fn) => { timers.push(fn) }, after: (ms, fn) => { timers.push(fn) } },
    process: { run: async argv => {
      if (argv[0] === '/plugin/bin/CompanionNativeWorker') {
        helperCalls.push(argv)
        if (argv[1] === 'artifact-input') {
          if (typeof artifactInput === 'function') return artifactInput(argv)
          return artifactInput ?? { exitCode: 0, stdout: JSON.stringify({ version: 1, sessionID: SESSION, branchComplete: true, artifacts: [] }) }
        }
        if (argv[1] === 'monitor-input') return typeof monitorResolution === 'function' ? monitorResolution(argv) : monitorResolution ?? { exitCode: 125, stdout: '', stderr: 'unverified history' }
        return { exitCode: helperFailure ? 1 : 0, stdout: argv[1] === 'inspect' ? files.get(`${argv[2]}/state.json`) ?? '' : argv[1] === 'prepare' ? JSON.stringify({ directory: argv[2] }) : '', stderr: '' }
      }
      if (argv[0] === '/usr/bin/env') {
        psCalls.push(argv)
        assert.deepEqual(argv, ['/usr/bin/env', 'TZ=UTC', 'LC_ALL=C', '/bin/ps', '-x', '-o', 'pid=,ppid=,lstart='])
        return { exitCode: 0, stdout: processes, stderr: '' }
      }
      assert.deepEqual(argv, ['/bin/sh', '-c', 'printf %s "$PPID"'])
      return { exitCode: 0, stdout: String(pid), stderr: '' }
    } },
    fs: {
      read: async path => { if (!files.has(path)) throw new Error('missing'); return files.get(path) },
      exists: async path => files.has(path),
      list: async path => [...new Set([...files.keys()].filter(key => key.startsWith(`${path}/`))
        .map(key => key.slice(path.length + 1).split('/')[0]))].map(name => ({ name, kind: files.has(`${path}/${name}`) ? 'file' : 'dir' })),
      write: async (path, value) => { if (failWrite && path.includes(failWrite)) throw new Error('disk full'); files.set(path, value); if (path.includes('/runtimes/')) ownReport = JSON.parse(value) },
    },
    session: { id: async () => SESSION, usage: async () => ({ rateLimits }), messages: async args => args?.agentId ? histories[args.agentId] ?? { deny: 'missing agent' } : messageRows },
    agent: { list: async () => agents },
    tool: { check: async input => { checks.push(input); return { decision: permission } }, list: async () => ['SendMessage', 'ArtifactComments', 'Monitor', 'Bash'].map(name => ({ name })), call: async event => { calls.push(event); return toolResponse(event) } },
    prompt: { submit: async event => { prompts.push(event.text); return promptResult ?? { text: event.text } } },
    turn: { abort: async event => { aborts.push(event.turnId); if (abortFailure) throw abortFailure } },
  }
  async function fire(name, event = {}, next = async value => value) {
    if (!next.origin) next.origin = { plugin: 'engine', tier: 'core' }
    const entry = handlers.find(h => h.name === name && (!h.matcher || Object.entries(h.matcher).every(([k,v]) => v instanceof RegExp ? v.test(event[k]) : v === event[k])))
    return entry ? entry.handler($, event, next) : next(event)
  }
  async function boot() { await fire('session.start', { cwd: '/tmp', surface: null, isInteractive: false }) }
  async function tick() { for (const fn of timers) await fn() }
  function report() { return ownReport }
  function arm(overrides = {}) {
    const runtime = report()
    const request = { version: 1, requiredCapability: 'native-recovery-v6', operationID: 'op-1', requestID: 'req-1', sessionID: SESSION, desktopSessionID: 'desktop-1',
      targetProfile: '/target', targetAccountID: 'account-target', createdAt: NOW, expiresAt: NOW + 3600000,
      phase: 'armed', instanceID: runtime?.instanceID, pid: runtime?.pid, procStart: runtime?.procStart, armedAt: NOW,
      sourceWasBusy: true, work: { version: 1, cliSessionID: SESSION, desktopSessionID: 'desktop-1', branchComplete,
        transcriptPath: '/source/session.jsonl', headUUID: 'head-1', headSource: 'selected', warnings: [],
        latestUser: { uuid: 'u1', sourceLine: 2 }, tasks, artifacts, needsContinuation: true }, ...overrides }
    files.set(`${ROOT}/active.json`, JSON.stringify({ version: 1, ready: true, operationID: 'op-1', targetProfile: '/target', targetAccountID: 'account-target' }))
    files.set(`${ROOT}/requests/${SESSION}.json`, JSON.stringify(request))
    return request
  }
  function result() { const value = files.get(`${ROOT}/results/req-1.json`); return value ? JSON.parse(value) : undefined }
  return { files, calls, prompts, aborts, agents, histories, tasks, artifacts, boot, tick, fire, report, arm, result,
    helperCalls, checks, psCalls, toasts, liveWatches, setArtifactInput: value => { artifactInput = value },
    artifactResult: () => { const value = files.get(`${ROOT}/artifacts/${SESSION}/${report()?.instanceID}.json`); return value ? JSON.parse(value) : undefined },
    setPermission: value => { permission = value }, setHelperFailure: value => { helperFailure = value },
    setMonitorResolution: value => { monitorResolution = value },
    heartbeat: async () => timers[0](), recoverTick: async () => timers[1](),
    setWriteFailure: value => { failWrite = value }, setPrompt: value => { promptResult = value },
    setAbortFailure: value => { abortFailure = value },
    setClockFailure: value => { clockFailure = value },
    setMessages: value => { messageRows = value }, setResponse: value => { toolResponse = value }, advance: ms => { now += ms },
  }
}

test('runtime report is bound to the actual parent and the matching Desktop registry', async () => {
  const h = harness(); await h.boot()
  assert.equal(h.report().pid, 12345)
  assert.equal(h.report().sessionID, SESSION)
  assert.ok(h.report().capabilities.includes('native-recovery-v6'))
  assert.equal(h.report().pluginVersion, PLUGIN_VERSION)
  assert.match(h.report().instanceID, /^[a-f0-9-]{36}$/)
  for (const registry of [{ pid: 99 }, { sessionId: 'foreign' }, { pidDomain: 'linux' }, { entrypoint: 'sdk-cli' }]) {
    const bad = harness({ registry }); await bad.boot(); assert.equal(bad.report(), undefined)
  }
})

test('automatic switching reports exhausted subscription windows, never estimates or expired windows', async () => {
  const limits = [{ kind: 'five_hour', percentUsed: 99.9, resetsAt: new Date(NOW + 3600000).toISOString() }]
  const h = harness({ rateLimits: limits }); await h.boot()
  assert.equal(h.report().quotaBlock, undefined)
  limits[0].percentUsed = 100
  await h.fire('session.measure', { context: {}, rateLimits: limits, changed: ['rateLimits'] })
  assert.equal(h.report().quotaBlock.reason, 'quota')
  assert.equal(h.report().quotaBlock.until, NOW + 3600000)
  limits[0].resetsAt = new Date(NOW).toISOString()
  await h.heartbeat(); assert.equal(h.report().quotaBlock, undefined)
  limits[0] = { kind: 'unknown_limit', percentUsed: 100 }
  await h.heartbeat(); assert.equal(h.report().quotaBlock, undefined)
})

test('only the host rate_limit failure of this session requests an automatic handoff', async () => {
  const h = harness(); await h.boot()
  for (const error of ['overloaded', 'authentication_failed', 'server_error', 'unknown']) {
    await h.fire('classic.StopFailure', { error, session_id: SESSION, error_details: 'rate_limit 429' })
    assert.equal(h.report().quotaBlock, undefined)
  }
  await h.fire('classic.StopFailure', { error: 'rate_limit', session_id: 'other-session' })
  assert.equal(h.report().quotaBlock, undefined)
  await h.fire('classic.StopFailure', { error: 'rate_limit', session_id: SESSION })
  assert.equal(h.report().quotaBlock.reason, 'rateLimit')
  await h.fire('turn.complete', { turnId: 'limited', isAborted: false, reason: 'error' })
  assert.equal(h.report().userStopped, false)
  assert.equal(h.report().quotaBlock.reason, 'rateLimit')
  assert.equal(h.prompts.length, 0, 'the source plugin reports; it never retries model work on the exhausted account')
  await h.fire('turn.complete', { turnId: 'succeeded', isAborted: false, reason: 'answer' })
  assert.equal(h.report().quotaBlock, undefined)
})

test('an account the service stopped is reported, whatever else is known, until a reply gets through', async () => {
  for (const error of ['account_on_hold', 'oauth_org_not_allowed']) {
    const h = harness(); await h.boot()
    await h.fire('classic.StopFailure', { error: 'rate_limit', session_id: SESSION })
    await h.fire('classic.StopFailure', { error, session_id: 'other-session' })
    assert.equal(h.report().quotaBlock.reason, 'rateLimit', 'another conversation\'s word says nothing here')
    await h.fire('classic.StopFailure', { error, session_id: SESSION })
    assert.equal(h.report().quotaBlock.reason, 'accountRestricted', 'a limit signal still standing gives way')
    assert.equal(h.report().quotaBlock.until, NOW + 86_400_000)
    await h.fire('classic.StopFailure', { error: 'rate_limit', session_id: SESSION })
    assert.equal(h.report().quotaBlock.reason, 'accountRestricted', 'so does a later one')
    await h.fire('turn.complete', { turnId: 'failed', isAborted: false, reason: 'error' })
    assert.equal(h.report().quotaBlock.reason, 'accountRestricted', 'a failed turn proves nothing')
    assert.equal(h.prompts.length, 0)
    await h.fire('turn.complete', { turnId: 'succeeded', isAborted: false, reason: 'answer' })
    assert.equal(h.report().quotaBlock, undefined, 'a reply that gets through ends it')
  }
  // A person stopping the reply does not lift it, and nothing holds work back for good.
  const h = harness(); await h.boot()
  await h.fire('classic.StopFailure', { error: 'account_on_hold', session_id: SESSION })
  await h.fire('turn.abort', { turnId: 'stopped' })
  assert.equal(h.report().userStopped, true)
  assert.equal(h.report().quotaBlock.reason, 'accountRestricted')
  h.advance(86_400_000); await h.heartbeat()
  assert.equal(h.report().quotaBlock, undefined)
})

test('a user stop or expiry withdraws the automatic handoff signal', async () => {
  const h = harness(); await h.boot()
  await h.fire('classic.StopFailure', { error: 'rate_limit', session_id: SESSION })
  await h.fire('turn.abort', { turnId: 'limited' })
  assert.equal(h.report().userStopped, true)
  assert.equal(h.report().quotaBlock, undefined)
  await h.fire('classic.StopFailure', { error: 'rate_limit', session_id: SESSION })
  assert.equal(h.report().quotaBlock, undefined)
  const expired = harness(); await expired.boot()
  await expired.fire('classic.StopFailure', { error: 'rate_limit', session_id: SESSION })
  expired.advance(600001); await expired.heartbeat()
  assert.equal(expired.report().quotaBlock, undefined)
})

test('old instances, mismatched identities, stale operations and expired tickets never claim', async () => {
  for (const override of [{ requiredCapability: undefined }, { requiredCapability: 'native-recovery-v4' }, { instanceID: 'old' }, { pid: 99 }, { procStart: 'old' }, { operationID: 'old' }, { phase: 'prepared' }, { expiresAt: NOW - 1 }]) {
    const h = harness(); await h.boot(); h.arm(override); await h.tick()
    assert.equal(h.result(), undefined); assert.equal(h.prompts.length, 0); assert.equal(h.calls.length, 0)
  }
})

test('a durable claim comes before side effects and prevents duplicate requests', async () => {
  const h = harness(); await h.boot(); h.arm(); await h.tick(); await h.tick()
  assert.equal(h.prompts.length, 1); assert.equal(h.result().status, 'queued')
  assert.equal(h.prompts[0], CONTINUATION)
  const fresh = harness({ files: h.files }); await fresh.boot(); fresh.arm(); await fresh.tick()
  assert.equal(fresh.prompts.length, 0, 'even a rearmed new instance cannot reuse the existing request claim')
})

test('failed and malformed claims never cause recovery effects or an implicit retry', async () => {
  const h = harness(); await h.boot(); h.arm(); h.setWriteFailure('/results/'); await h.tick()
  h.setWriteFailure(undefined); await h.tick()
  assert.equal(h.prompts.length, 0); assert.equal(h.calls.length, 0)
  const bad = harness(); await bad.boot(); bad.arm(); bad.files.set(`${ROOT}/results/req-1.json`, '{partial'); await bad.tick()
  assert.equal(bad.prompts.length, 0)
})

test('a switch-interrupted native agent uses its exact ID and saved history, never a replacement Agent', async () => {
  for (const status of ['pending', 'idle', 'killed', 'failed']) {
    const h = harness({ tasks: [AGENT], agents: [{ id: 'agent-1', type: 'general-purpose', status }], histories: { 'agent-1': [{ role: 'user', text: 'original task', toolUses: [] }] } })
    await h.boot(); h.arm(); await h.tick(); await h.tick()
    assert.equal(h.calls.filter(c => c.tool === 'SendMessage').length, 1)
    assert.equal(h.calls[0].to, 'agent-1'); assert.equal(h.result().status, 'queued')
    assert.ok(!h.calls.some(c => ['Agent', 'Bash', 'Monitor', 'Artifact'].includes(c.tool)))
    assert.equal(h.prompts[0], CONTINUATION)
    assert.deepEqual(JSON.parse(h.files.get(`${ROOT}/requests/${SESSION}.json`)).work.tasks, [AGENT])
  }
})

test('completed, explicitly stopped, unknown and incomplete-branch agents are left for inspection', async () => {
  for (const variant of [
    { tasks: [{ ...AGENT, state: 'stopped' }], status: 'killed' },
    { tasks: [{ ...AGENT, state: 'unknown' }], status: 'killed' },
    { tasks: [AGENT], status: 'completed' },
    { tasks: [AGENT], status: 'killed', branchComplete: false },
    { tasks: [AGENT], status: 'killed', stopped: true },
  ]) {
    const h = harness({ ...variant, agents: [{ id: 'agent-1', type: 'general-purpose', status: variant.status }], histories: { 'agent-1': [{ role: 'user', text: 'history', toolUses: [] }] } })
    if (variant.stopped) h.setMessages([{ toolUses: [{ tool: 'TaskStop', input: { task_id: 'agent-1' }, result: { message: 'stopped' } }] }])
    await h.boot(); h.arm(); await h.tick()
    assert.equal(h.calls.filter(c => c.tool === 'SendMessage').length, 0)
  }
})

test('a new agent failure after arming is not retried automatically', async () => {
  const h = harness({ tasks: [AGENT], agents: [{ id: 'agent-1', type: 'general-purpose', status: 'failed' }], histories: { 'agent-1': [{ toolUses: [] }] } })
  await h.boot(); h.arm()
  await h.fire('tool.call', { tool: 'Read', tool_use_id: 'new-failure', agentId: 'agent-1' }, async () => ({ isError: true, text: 'new failure' }))
  await h.tick(); assert.equal(h.calls.length, 0)
})

test('artifact recovery inspects first and restores only prior armed URLs without publishing', async () => {
  const h = harness({ artifacts: [{ url: URL, state: 'armed', replies: true }, { url: `${URL}-stopped`, state: 'stopped' }] })
  await h.boot(); h.arm(); await h.tick()
  assert.deepEqual(h.calls.map(c => [c.tool, c.action, c.url, c.on]), [
    ['ArtifactComments', 'watch', undefined, undefined], ['ArtifactComments', 'watch', URL, true],
    ['ArtifactComments', 'watch', undefined, undefined],
  ])
  assert.ok(h.result().evidence.some(e => e.outcome === 'watchAccepted'))
  for (const watch of [{ url: URL, connected: true, auto_reply: 'armed' }, { url: URL, connecting: true }, { url: URL, rail: 'live_stopped', stop_kind: 'user' }]) {
    const h2 = harness({ artifacts: [{ url: URL, state: 'armed', replies: true }] }); h2.setResponse(() => ({ result: { watches: [watch] } }))
    await h2.boot(); h2.arm(); await h2.tick(); assert.equal(h2.calls.length, 1)
  }
})

test('watch denial and a connecting result remain evidence, not a restored claim', async () => {
  for (const response of [{ deny: 'not shared with this account' }, { result: { watch: { watching: false, connecting: true } } }]) {
    const h = harness({ artifacts: [{ url: URL, state: 'armed', replies: true }] })
    h.setResponse(event => event.url ? response : { result: { watches: [] } })
    await h.boot(); h.arm(); await h.tick()
    assert.ok(h.result().evidence.some(e => ['blocked', 'connecting'].includes(e.outcome)))
    assert.ok(!h.result().evidence.some(e => e.outcome === 'watchAccepted'))
  }
})

test('ordinary reopen restores original artifact replies with no switch ticket or model prompt', async () => {
  const h = harness({ worker: true })
  h.setArtifactInput({ exitCode: 0, stdout: JSON.stringify({ version: 1, sessionID: SESSION, branchComplete: true,
    artifacts: [{ url: URL, state: 'armed', replies: true }] }) })
  await h.boot(); await h.tick(); assert.equal(h.calls.length, 0, 'native startup gets time to restore itself')
  h.advance(10_000); await h.tick()
  assert.equal(h.artifactResult().status, 'restored')
  assert.equal(h.artifactResult().artifacts[0].repliesReady, true)
  assert.equal(h.calls.filter(call => call.replies === true).length, 0)
  assert.equal(h.prompts.length, 0); assert.equal(h.result(), undefined)
  await h.tick(); h.advance(10_000); await h.tick()
  assert.equal(h.calls.filter(call => call.url).length, 1, 'no duplicate native watch or reply restoration')
})

test('an idle artifact handoff restores prior automatic replies without submitting continuation text', async () => {
  const artifacts = [{ url: URL, state: 'armed', replies: true }]
  const h = harness({ artifacts, worker: true }); await h.boot()
  const request = h.arm({ sourceWasBusy: false })
  request.work.needsContinuation = false; h.files.set(`${ROOT}/requests/${SESSION}.json`, JSON.stringify(request))
  h.advance(10_000); await h.tick()
  assert.equal(h.result().status, 'inspected')
  assert.ok(h.result().evidence.some(item => item.outcome === 'repliesRestored'))
  assert.equal(h.prompts.length, 0)
  assert.equal(h.helperCalls.filter(call => call[1] === 'artifact-input').length, 0, 'the handoff takes precedence over startup recovery')
})

test('pure-watch reopen and idle or busy handoff report attention without creating or enabling replies', async () => {
  for (const mode of ['reopen', 'idle', 'busy']) {
    const artifacts = [{ url: URL, state: 'armed', replies: false }], h = harness({ artifacts, worker: true })
    h.setArtifactInput({ exitCode: 0, stdout: JSON.stringify({ version: 1, sessionID: SESSION, branchComplete: true, artifacts }) })
    await h.boot()
    if (mode !== 'reopen') {
      const request = h.arm({ sourceWasBusy: mode === 'busy' }); request.work.needsContinuation = mode === 'busy'
      h.files.set(`${ROOT}/requests/${SESSION}.json`, JSON.stringify(request))
    }
    h.advance(10_000); await h.tick()
    const result = mode === 'reopen' ? h.artifactResult() : h.result()
    assert.equal(result.status, 'needsAttention'); assert.match(result.error, /watch-only/)
    assert.equal(h.calls.filter(call => call.url).length, 0); assert.equal(h.liveWatches.length, 0)
    assert.equal(h.prompts.length, mode === 'busy' ? 1 : 0)
    if (mode === 'busy') {
      await h.fire('turn.start', { turnId: 'resume', text: h.prompts[0] })
      const response = await h.fire('tool.call', { tool: 'ArtifactComments', tool_use_id: 'watch-only-repeat', action: 'watch', url: URL },
        async () => { assert.fail('the model continuation must not bypass the pure-watch recovery decision') })
      assert.match(response.deny, /already handled/)
    }
    h.advance(60_000); await h.tick()
    assert.equal(h.calls.filter(call => call.url).length, 0)
  }
})

test('a main continuation cannot repeat an already handled artifact watch or refused reply resume', async () => {
  for (const denied of [false, true]) {
    const h = harness({ artifacts: [{ url: URL, state: 'armed', replies: true }] })
    if (denied) h.setResponse(input => input.url ? { deny: 'cannot edit' } : { result: { watches: [] } })
    await h.boot(); h.arm(); await h.tick()
    assert.ok(h.result().evidence.some(item => item.tool === 'ArtifactComments' && item.outcome === (denied ? 'blocked' : 'repliesRestored')))
    assert.equal(h.prompts[0], CONTINUATION)
    await h.fire('turn.start', { turnId: 'resume', text: h.prompts[0] })
    let effects = 0
    for (const tool of ['ArtifactComments', 'Artifact']) {
      const result = await h.fire('tool.call', { tool, tool_use_id: 'repeat', action: 'watch', url: URL, replies: true }, async () => { effects++; return { result: {} } })
      assert.match(result.deny, /already handled/)
    }
    assert.equal(effects, 0)
    const inventory = await h.fire('tool.call', { tool: 'ArtifactComments', tool_use_id: 'inspect', action: 'watch' }, async () => ({ result: { watches: [] } }))
    assert.ok(inventory.result)
    await h.fire('prompt.submit', { text: 'Resume this watch now', origin: { kind: 'composer' } })
    await h.fire('turn.start', { turnId: 'manual', text: 'Resume this watch now' })
    await h.fire('tool.call', { tool: 'ArtifactComments', tool_use_id: 'manual-watch', action: 'watch', url: URL, replies: true }, async () => { effects++; return { result: {} } })
    assert.equal(effects, 1, 'a later explicit human request still goes through the ordinary native tool')
  }
})

test('reopen needs a verified original session and complete branch; published links do not authorize a watch', async () => {
  for (const override of [{ sessionID: 'foreign' }, { branchComplete: false }, { artifacts: [{ url: URL }] },
    { artifacts: [{ url: URL, state: 'stopped', replies: false }] }]) {
    const h = harness({ worker: true })
    h.setArtifactInput({ exitCode: 0, stdout: JSON.stringify({ version: 1, sessionID: SESSION, branchComplete: true,
      artifacts: [{ url: URL, state: 'armed', replies: true }], ...override }) })
    await h.boot(); h.advance(10_000); await h.tick()
    assert.equal(h.calls.length, 0); assert.equal(h.prompts.length, 0)
    if (override.branchComplete === false) {
      assert.equal(h.artifactResult().status, 'needsAttention'); assert.equal(h.toasts.length, 1)
    }
  }
})

test('native permission refusal on reopened replies is visible, final, and never republished', async () => {
  const h = harness({ worker: true })
  h.setArtifactInput({ exitCode: 0, stdout: JSON.stringify({ version: 1, sessionID: SESSION, branchComplete: true,
    artifacts: [{ url: URL, state: 'armed', replies: true }] }) })
  h.setResponse(input => input.url ? { deny: 'This account cannot edit the original artifact.' } : { result: { watches: [] } })
  await h.boot(); h.advance(10_000); await h.tick()
  assert.equal(h.artifactResult().status, 'needsAttention')
  assert.match(h.artifactResult().error, /cannot edit/)
  assert.equal(h.toasts.length, 1); assert.equal(h.prompts.length, 0)
  h.advance(60_000); await h.tick()
  assert.equal(h.calls.filter(call => call.url).length, 1); assert.equal(h.toasts.length, 1)
})

test('ordinary reopen retries a failed intent read and clears its temporary error on success', async () => {
  for (const throws of [false, true]) {
    const h = harness({ worker: true })
    h.setArtifactInput(() => { if (throws) throw new Error('temporary read failure'); return { exitCode: 125, stdout: '', stderr: 'unreadable transcript' } })
    await h.boot(); h.advance(10_000); await h.tick()
    assert.equal(h.artifactResult().status, 'waiting'); assert.equal(h.artifactResult().readAttempts, 1)
    assert.equal(h.toasts.length, 0); assert.equal(h.calls.length, 0)
    h.setArtifactInput({ exitCode: 0, stdout: JSON.stringify({ version: 1, sessionID: SESSION, branchComplete: true,
      artifacts: [{ url: URL, state: 'armed', replies: true }] }) })
    h.advance(10_000); await h.tick()
    assert.equal(h.artifactResult().status, 'restored'); assert.equal(h.artifactResult().readAttempts, 2)
    assert.equal(h.artifactResult().error, undefined); assert.equal(h.toasts.length, 0)
    h.advance(60_000); await h.tick()
    assert.equal(h.helperCalls.filter(call => call[1] === 'artifact-input').length, 2)
  }
})

test('real worker directory EACCES reaches startup retry, recovery and a single exhausted error',
  { skip: process.geteuid?.() === 0 ? 'POSIX read permissions do not constrain root' : false }, async t => {
  for (const recoverAfterFirst of [true, false]) {
    const home = mkdtempSync(join(tmpdir(), 'cc-relay-artifact-permission-'))
    const config = join(home, 'custom-cli'), projects = join(config, 'projects'), bucket = join(projects, 'original')
    mkdirSync(bucket, { recursive: true })
    try {
      const file = join(bucket, SESSION + '.jsonl')
      const rows = [
        { sessionId: SESSION, type: 'user', uuid: 'root', parentUuid: null, message: { content: 'Original artifact task' } },
        { sessionId: SESSION, type: 'artifact-comment-monitor', v: 1,
          artifacts: { '1234-abcd': { state: 'armed', writtenAtMs: 2 } } },
      ]
      const original = rows.map(row => JSON.stringify(row)).join('\n') + '\n'
      writeFileSync(file, original)
      chmodSync(projects, 0o111)
      assert.equal(readFileSync(file, 'utf8'), original, 'the known transcript remains readable')
      assert.throws(() => readdirSync(projects), { code: 'EACCES' }, 'directory enumeration actually fails in the OS')
      const h = harness({ worker: true })
      h.setArtifactInput(argv => {
        const result = spawnSync(WORKER, argv.slice(1), { encoding: 'utf8', timeout: 5000,
          env: { ...process.env, HOME: home, CLAUDE_CONFIG_DIR: config } })
        if (result.error) throw result.error
        return { exitCode: result.status, stdout: result.stdout, stderr: result.stderr }
      })
      await h.boot(); h.advance(10_000); await h.tick()
      assert.equal(h.artifactResult().status, 'waiting'); assert.equal(h.artifactResult().readAttempts, 1)
      assert.match(h.artifactResult().error, /permission denied/)
      assert.equal(h.toasts.length, 0); assert.equal(h.calls.length, 0)
      if (recoverAfterFirst) {
        chmodSync(projects, 0o700)
        h.advance(10_000); await h.tick()
        assert.equal(h.artifactResult().status, 'restored'); assert.equal(h.artifactResult().readAttempts, 2)
        assert.equal(h.artifactResult().error, undefined); assert.equal(h.toasts.length, 0)
        assert.equal(h.calls.filter(call => call.url).length, 1)
      } else {
        for (let n = 0; n < 2; n++) { h.advance(10_000); await h.tick() }
        assert.equal(h.artifactResult().status, 'needsAttention'); assert.equal(h.artifactResult().readAttempts, 3)
        assert.match(h.artifactResult().error, /permission denied/)
        assert.equal(h.toasts.length, 1); assert.match(h.toasts[0], /permission denied/)
        assert.equal(h.calls.length, 0)
      }
      h.advance(60_000); await h.tick()
      assert.equal(h.helperCalls.filter(call => call[1] === 'artifact-input').length, recoverAfterFirst ? 2 : 3)
      assert.equal(h.toasts.length, recoverAfterFirst ? 0 : 1); assert.equal(h.prompts.length, 0)
      assert.equal(readFileSync(file, 'utf8'), original)
    } finally {
      chmodSync(projects, 0o700)
      rmSync(home, { recursive: true, force: true })
    }
  }
  t.diagnostic('Ran the compiled CompanionNativeWorker under actual OS EACCES and after permission restoration; startup retries and toast handling used the plugin entry point.')
})

test('three intent read failures or invalid records end with one visible attention receipt', async () => {
  for (const input of [{ exitCode: 125, stdout: '', stderr: 'unreadable transcript' },
    { exitCode: 0, stdout: '{partial' },
    { exitCode: 0, stdout: JSON.stringify({ version: 1, sessionID: 'foreign', artifacts: [] }) }]) {
    const h = harness({ worker: true }); h.setArtifactInput(input); await h.boot()
    for (let n = 0; n < 3; n++) { h.advance(10_000); await h.tick() }
    assert.equal(h.artifactResult().status, 'needsAttention'); assert.equal(h.artifactResult().readAttempts, 3)
    assert.ok(h.artifactResult().error); assert.equal(h.toasts.length, 1); assert.equal(h.calls.length, 0)
    h.advance(60_000); await h.tick()
    assert.equal(h.helperCalls.filter(call => call[1] === 'artifact-input').length, 3)
    assert.equal(h.toasts.length, 1)
  }
})

test('a new conversation without a transcript stays quiet; a later empty result clears an earlier read failure', async () => {
  const h = harness({ worker: true }); await h.boot(); h.advance(10_000); await h.tick()
  assert.equal(h.artifactResult(), undefined); assert.equal(h.toasts.length, 0)
  const retry = harness({ worker: true })
  retry.setArtifactInput({ exitCode: 125, stdout: '', stderr: 'temporary failure' })
  await retry.boot(); retry.advance(10_000); await retry.tick()
  retry.setArtifactInput({ exitCode: 0, stdout: JSON.stringify({ version: 1, sessionID: SESSION, branchComplete: true, artifacts: [] }) })
  retry.advance(10_000); await retry.tick()
  assert.equal(retry.artifactResult().status, 'inspected'); assert.equal(retry.artifactResult().error, undefined)
  assert.equal(retry.calls.length, 0); assert.equal(retry.toasts.length, 0)
})

test('a user stop while intent reading waits ends the retry without another worker call', async () => {
  const h = harness({ worker: true })
  h.setArtifactInput({ exitCode: 125, stdout: '', stderr: 'temporary failure' })
  await h.boot(); h.advance(10_000); await h.tick()
  await h.fire('turn.abort', { turnId: 'manual-stop' })
  h.advance(10_000); await h.tick()
  assert.equal(h.artifactResult().status, 'yielded'); assert.equal(h.toasts.length, 0)
  assert.equal(h.helperCalls.filter(call => call[1] === 'artifact-input').length, 1)
})

test('startup waits for a normal human turn to finish, while Stop prevents recovery', async () => {
  for (const stop of [false, true]) {
    const h = harness({ worker: true })
    h.setArtifactInput({ exitCode: 0, stdout: JSON.stringify({ version: 1, sessionID: SESSION, branchComplete: true,
      artifacts: [{ url: URL, state: 'armed', replies: true }] }) })
    await h.boot()
    if (stop) await h.fire('turn.abort', { turnId: 'original' })
    else {
      await h.fire('prompt.submit', { text: 'new task', origin: { kind: 'composer' } })
      await h.fire('turn.start', { turnId: 'manual', text: 'new task' })
    }
    h.advance(10_000); await h.tick()
    assert.equal(h.calls.length, 0); assert.equal(h.artifactResult(), undefined)
    if (!stop) {
      await h.fire('turn.complete', { turnId: 'manual', reason: 'answer', isAborted: false })
      await h.tick(); assert.equal(h.artifactResult().status, 'restored')
    }
  }
})

test('a new instruction during startup recovery yields before any further artifact action', async () => {
  const h = harness({ worker: true })
  h.setArtifactInput({ exitCode: 0, stdout: JSON.stringify({ version: 1, sessionID: SESSION, branchComplete: true,
    artifacts: [{ url: URL, state: 'armed', replies: true }] }) })
  h.setResponse(async input => {
    if (!input.url) return { result: { watches: [] } }
    await h.fire('prompt.submit', { text: 'new task', origin: { kind: 'composer' } })
    return { result: { watch: { url: URL, watching: true } } }
  })
  await h.boot(); h.advance(10_000); await h.tick()
  assert.equal(h.artifactResult().status, 'yielded')
  assert.equal(h.calls.filter(call => call.url).length, 1)
  h.advance(60_000); await h.tick()
  assert.equal(h.calls.filter(call => call.url).length, 1)
})

test('prompt drop is final for that ticket, and queued does not mean execution', async () => {
  const h = harness(); await h.boot(); h.arm(); h.setPrompt({ drop: 'user stopped' }); await h.tick(); await h.tick()
  assert.equal(h.prompts.length, 1); assert.equal(h.result().status, 'needsAttention')
})

test('only a marker-bound turn and real tool results advance execution evidence', async () => {
  const h = harness(); await h.boot(); h.arm(); await h.tick()
  await h.fire('turn.start', { turnId: 'unrelated', text: 'unrelated user message' })
  await h.fire('tool.call', { tool: 'Read', tool_use_id: 'unrelated' }, async () => ({ result: 'ok' }))
  assert.equal(h.result().status, 'queued')
  await h.fire('turn.complete', { turnId: 'unrelated', answer: 'done' })
  await h.fire('turn.start', { turnId: 'continuation', text: h.prompts[0] })
  assert.equal(h.result().status, 'queued')
  await h.fire('tool.call', { tool: 'Monitor', tool_use_id: 'monitor-1' }, async () => ({ result: { taskId: 'native-monitor', timeoutMs: 5000 } }))
  assert.equal(h.result().status, 'executing')
  assert.ok(h.result().evidence.some(e => e.outcome === 'monitorRegistered' && e.taskID === 'native-monitor'))
  await h.fire('turn.complete', { turnId: 'continuation', answer: 'continued' })
  assert.equal(h.result().status, 'turnFinished')
  await h.fire('turn.start', { turnId: 'later', text: 'something else' })
  await h.fire('tool.call', { tool: 'Read', tool_use_id: 'later' }, async () => ({ result: 'ok' }))
  assert.ok(!h.result().evidence.some(e => e.toolUseID === 'later'))
})

test('a step that worked still counts after later failures fill the evidence', async () => {
  const h = harness(); await h.boot(); h.arm(); await h.tick()
  await h.fire('turn.start', { turnId: 'continuation', text: h.prompts[0] })
  await h.fire('tool.call', { tool: 'Read', tool_use_id: 'read-ok' }, async () => ({ result: 'ok' }))
  for (let index = 0; index < 96; index += 1) {
    await h.fire('tool.call', { tool: 'Read', tool_use_id: `read-${index}` }, async () => ({ isError: true, text: 'no such file' }))
  }
  await h.fire('turn.complete', { turnId: 'continuation', answer: 'done' })
  const { status, evidence } = h.result()
  assert.equal(status, 'turnFinished')
  assert.ok(evidence.length <= 96)
  assert.ok(evidence.some(item => item.outcome === 'toolResultReturned'))
})

test('user stop and operation change prevent further restoration', async () => {
  const h = harness(); await h.boot(); h.arm()
  await h.fire('turn.abort', { turnId: 'user-stop' }); await h.tick()
  assert.equal(h.prompts.length, 0); assert.equal(h.report().userStopped, true)
  assert.equal(h.result().status, 'yielded')
  await h.fire('prompt.submit', { text: 'new topic', origin: { kind: 'sdk' } }); await h.tick()
  assert.equal(h.prompts.length, 0)
  const h2 = harness(); await h2.boot(); h2.arm(); await h2.tick()
  h2.files.set(`${ROOT}/active.json`, JSON.stringify({ version: 1, operationID: 'later' }))
  await h2.fire('turn.start', { turnId: 'stale', text: h2.prompts[0] })
  await h2.fire('tool.call', { tool: 'Bash', tool_use_id: 'stale' }, async () => ({ result: { stdout: 'ok' } }))
  assert.equal(h2.result().status, 'needsAttention')
  assert.deepEqual(h2.aborts, ['stale'])
})

test('launch must be ready, and a source user stop is preserved across the switch', async () => {
  const h = harness(); await h.boot(); h.arm()
  const active = JSON.parse(h.files.get(`${ROOT}/active.json`)); active.ready = false
  h.files.set(`${ROOT}/active.json`, JSON.stringify(active)); await h.tick()
  assert.equal(h.result(), undefined); assert.equal(h.prompts.length, 0)
  h.arm({ sourceUserStopped: true }); await h.tick()
  assert.equal(h.result().status, 'yielded'); assert.equal(h.prompts.length, 0)
})

test('resumed agent tools are evidence only inside its marker-bound native turn', async () => {
  const h = harness({ tasks: [AGENT], agents: [{ id: 'agent-1', type: 'general-purpose', status: 'killed' }], histories: { 'agent-1': [{ role: 'user', text: 'history', toolUses: [] }] } })
  await h.boot(); h.arm(); await h.tick()
  await h.fire('turn.start', { agentId: 'agent-1', turnId: 'agent-resume', text: h.calls[0].message })
  await h.fire('tool.call', { agentId: 'agent-1', tool: 'Read', tool_use_id: 'agent-read' }, async () => ({ result: 'file contents' }))
  assert.equal(h.result().status, 'executing')
  await h.fire('turn.complete', { agentId: 'agent-1', turnId: 'agent-resume', answer: 'done' })
  await h.fire('turn.start', { agentId: 'agent-1', turnId: 'unrelated-agent', text: 'another task' })
  await h.fire('tool.call', { agentId: 'agent-1', tool: 'Read', tool_use_id: 'unrelated-agent-read' }, async () => ({ result: 'file contents' }))
  assert.ok(h.result().evidence.some(e => e.toolUseID === 'agent-read'))
  assert.ok(!h.result().evidence.some(e => e.toolUseID === 'unrelated-agent-read'))
})

test('the continuation is recognised under the frame the host puts around a plugin or coordinator message', async () => {
  const h = harness(); await h.boot(); h.arm(); await h.tick()
  await h.fire('turn.start', { turnId: 'framed', text: `The cc-relay plugin sent a message:\n${h.prompts[0]}` })
  assert.ok(h.result().evidence.some(item => item.outcome === 'continuationTurnStarted'))
  await h.fire('prompt.submit', { text: 'a newer instruction', origin: { kind: 'composer' } })
  let reachedHost = false
  const blocked = await h.fire('tool.call', { tool: 'Bash', tool_use_id: 'old-step' }, async () => { reachedHost = true; return { result: {} } })
  assert.equal(reachedHost, false); assert.ok(blocked.deny)
  assert.equal(h.result().status, 'yielded')
  const done = harness(); await done.boot(); done.arm(); await done.tick()
  await done.fire('turn.start', { turnId: 'framed', text: `The cc-relay plugin sent a message:\n${done.prompts[0]}` })
  await done.fire('tool.call', { tool: 'Read', tool_use_id: 'checked' }, async () => ({ result: 'read' }))
  await done.fire('turn.complete', { turnId: 'framed', answer: 'done' })
  assert.equal(done.result().status, 'turnFinished')
  const agent = harness({ tasks: [AGENT], agents: [{ id: 'agent-1', type: 'general-purpose', status: 'killed' }], histories: { 'agent-1': [{ role: 'user', text: 'history', toolUses: [] }] } })
  await agent.boot(); agent.arm(); await agent.tick()
  await agent.fire('turn.start', { agentId: 'agent-1', turnId: 'agent-framed', text: `The coordinator sent a message while you were working: ${agent.calls[0].message}` })
  assert.ok(agent.result().evidence.some(item => item.outcome === 'agentTurnStarted'))
})

test('the previous marker still binds a known request and yields to a newer user instruction', async () => {
  const h = harness(); await h.boot(); h.arm(); await h.tick()
  const legacy = h.prompts[0].replace('[Continuation ', '[CC-Relay 原任务续接 ')
  await h.fire('turn.start', { turnId: 'legacy', text: `The cc-relay plugin sent a message:\n${legacy}` })
  assert.ok(h.result().evidence.some(item => item.outcome === 'continuationTurnStarted'))
  await h.fire('prompt.submit', { text: 'A new task', origin: { kind: 'composer' } })
  const result = await h.fire('tool.call', { tool: 'Bash' }, async () => { assert.fail('the superseded legacy turn must not execute') })
  assert.ok(result.deny)
  assert.equal(h.result().status, 'yielded')
})

test('the marker quoted inside a person\'s own words starts no automatic turn', async () => {
  const h = harness(); await h.boot(); h.arm(); await h.tick()
  for (const text of [`Why did I get this: ${h.prompts[0]}`, `这条是什么意思：${h.prompts[0]}`]) {
    await h.fire('turn.start', { turnId: `quoted-${text.length}`, text })
    assert.ok(!h.result().evidence.some(item => item.outcome === 'continuationTurnStarted'))
  }
  assert.deepEqual(h.aborts, [])
})

test('a quota-compactor pause is not a user stop; a genuine user stop still wins', async () => {
  const h = harness(); await h.boot(); h.arm(); await h.tick()
  const compactor = Object.assign(async value => value, { origin: { plugin: 'cc-relay', tier: 'user' } })
  await h.fire('turn.start', { turnId: 'continue', text: h.prompts[0] })
  await h.fire('turn.abort', { turnId: 'continue' }, compactor)
  await h.fire('turn.complete', { turnId: 'continue', isAborted: true })
  assert.equal(h.report().userStopped, false)
  await h.fire('turn.abort', { turnId: 'user-stop' })
  await h.fire('turn.complete', { turnId: 'user-stop', isAborted: true })
  assert.equal(h.report().userStopped, true)
  assert.equal(h.result().status, 'yielded')
})

test('only native task notifications for a newly registered continuation Monitor prove an event', async () => {
  const h = harness(); await h.boot(); h.arm(); await h.tick()
  await h.fire('turn.start', { turnId: 'resume', text: h.prompts[0] })
  await h.fire('tool.call', { tool: 'Monitor', tool_use_id: 'new-watch' }, async () => ({ result: { taskId: 'monitor-new', timeoutMs: 5000 } }))
  const events = () => h.result().evidence.filter(e => e.outcome === 'monitorEventObserved')
  assert.equal(events().length, 0, 'registration alone is not an event')
  await h.fire('prompt.submit', { text: '<task-id>monitor-new</task-id>', origin: { kind: 'plugin' } })
  await h.fire('prompt.submit', { text: '<task-id>monitor-old</task-id>', origin: { kind: 'task-notification' } })
  await h.fire('prompt.submit', { text: '<task-id>monitor-new-extra</task-id>', origin: { kind: 'task-notification' } })
  assert.equal(events().length, 0)
  await h.fire('prompt.submit', { text: '<task-notification><task-id>monitor-new</task-id><output>changed</output></task-notification>', origin: { kind: 'task-notification' } })
  assert.equal(events().length, 1)
  assert.equal(events()[0].taskID, 'monitor-new')
})

test('an absent live agent with readable original history is resumed by its original ID', async () => {
  const h = harness({ tasks: [AGENT], agents: [], histories: { 'agent-1': [{ role: 'user', text: 'unfinished original task', toolUses: [] }] } })
  await h.boot(); h.arm(); await h.tick()
  assert.equal(h.calls.filter(c => c.tool === 'SendMessage').length, 1)
  assert.equal(h.calls[0].to, 'agent-1')
  assert.equal(h.prompts[0], CONTINUATION)
  assert.ok(h.result().evidence.some(item => item.tool === 'SendMessage' && item.agentID === 'agent-1' && item.outcome === 'returnedAwaitingAgentProgress'))
  const missing = harness({ tasks: [AGENT] }); await missing.boot(); missing.arm(); await missing.tick()
  assert.equal(missing.calls.length, 0)
  assert.ok(missing.result().evidence.some(e => e.outcome === 'historyUnavailable'))
})

test('host completion notices prevent resuming an absent agent, while typed or output-forged notices do not', async () => {
  const completed = '<task-notification><task-id>agent-1</task-id><tool-use-id>use-1</tool-use-id><status>completed</status><summary>done</summary></task-notification>'
  for (const kind of ['task-notification', 'composer', 'plugin']) {
    const h = harness({ tasks: [AGENT], histories: { 'agent-1': [{ role: 'assistant', text: 'history', toolUses: [] }] } })
    await h.boot()
    h.setMessages([{ role: 'user', text: completed, toolUses: [] }])
    await h.fire('prompt.submit', { text: completed, origin: { kind } })
    h.arm(); await h.tick()
    assert.equal(h.calls.filter(c => c.tool === 'SendMessage').length, kind === 'plugin' ? 1 : 0)
  }
  const h = harness({ tasks: [AGENT], histories: { 'agent-1': [{ toolUses: [] }] } })
  await h.boot()
  await h.fire('prompt.submit', { origin: { kind: 'task-notification' }, text: `<task-notification><task-id>other-task</task-id><status>completed</status><output>${completed}</output></task-notification>` })
  h.arm(); await h.tick(); assert.equal(h.calls.filter(c => c.tool === 'SendMessage').length, 1)
})

test('historical completed tasks cannot consume the native-agent recovery limit', async () => {
  const completed = Array.from({ length: 80 }, (_, i) => ({ ...AGENT, id: `completed-${i}`, toolUseID: `old-${i}`, state: 'completed', sourceLine: 1 }))
  const h = harness({ tasks: [...completed, AGENT], histories: { 'agent-1': [{ role: 'user', text: 'unfinished', toolUses: [] }] } })
  await h.boot(); h.arm(); await h.tick()
  assert.equal(h.calls.filter(c => c.tool === 'SendMessage').length, 1)
  assert.equal(h.calls[0].to, 'agent-1')
  assert.equal(h.prompts[0], CONTINUATION)
  assert.deepEqual(JSON.parse(h.files.get(`${ROOT}/requests/${SESSION}.json`)).work.tasks, [...completed, AGENT])
})

test('a short continuation leaves the full task inventory and uninspected overflow in local records', async () => {
  const tasks = Array.from({ length: 70 }, (_, i) => ({ ...AGENT, id: `agent-${i}`, toolUseID: `use-${i}` }))
  const h = harness({ tasks }); await h.boot(); h.arm(); await h.tick()
  assert.equal(h.calls.length, 0, 'missing histories do not cause replacement agents')
  assert.ok(h.result().evidence.some(e => e.outcome === 'remainingNeedInspection'))
  assert.equal(h.prompts[0], CONTINUATION)
  assert.deepEqual(JSON.parse(h.files.get(`${ROOT}/requests/${SESSION}.json`)).work.tasks, tasks)
})

test('runtime busy includes live native agents without changing the main-turn recovery mutex', async () => {
  for (const status of ['pending', 'running', 'waiting', 'completed', 'killed', 'failed', 'idle']) {
    const h = harness({ agents: [{ id: 'live-agent', status, type: 'general-purpose' }] })
    await h.boot()
    assert.equal(h.report().busy, ['pending', 'running', 'waiting'].includes(status))
    h.arm(); await h.tick()
    assert.equal(h.prompts.length, 1, 'an idle main loop can accept its continuation while an agent is busy')
  }
})

test('a newer user instruction before arming or claiming prevents late old continuation', async () => {
  for (const beforeArm of [false, true]) {
    const h = harness(); await h.boot()
    if (!beforeArm) h.arm()
    await h.fire('prompt.submit', { text: 'new task', origin: { kind: 'composer' } })
    await h.fire('turn.start', { turnId: 'new-user', text: 'new task' })
    if (beforeArm) h.arm()
    await h.tick(); assert.equal(h.prompts.length, 0)
    await h.fire('turn.complete', { turnId: 'new-user', answer: 'done' }); await h.tick()
    assert.equal(h.prompts.length, 0)
    assert.equal(h.result().status, 'yielded')
  }
})

test('a queued old marker is aborted on its own start without aborting the new user turn', async () => {
  const h = harness(); await h.boot(); h.arm(); await h.tick()
  await h.fire('prompt.submit', { text: 'new task', origin: { kind: 'sdk' } })
  await h.fire('turn.start', { turnId: 'new-user', text: 'new task' })
  assert.deepEqual(h.aborts, [])
  await h.fire('turn.complete', { turnId: 'new-user', answer: 'done' })
  await h.fire('turn.start', { turnId: 'stale-automatic', text: h.prompts[0] })
  assert.deepEqual(h.aborts, ['stale-automatic'])
  assert.equal(h.result().status, 'yielded')
})

test('an explicit agent stop during history inspection wins over the old snapshot', async () => {
  let release
  const history = new Promise(resolve => { release = resolve })
  const h = harness({ tasks: [AGENT], agents: [{ id: 'agent-1', status: 'idle' }], histories: { 'agent-1': history } })
  await h.boot(); h.arm(); const pending = h.tick(); await new Promise(setImmediate)
  await h.fire('tool.call', { tool: 'TaskStop', task_id: 'agent-1', tool_use_id: 'stop-now' },
    async () => ({ result: { task_id: 'agent-1', message: 'stopped' } }))
  release([{ role: 'user', text: 'original work', toolUses: [] }]); await pending
  assert.equal(h.calls.filter(call => call.tool === 'SendMessage').length, 0)
  assert.equal(h.prompts[0], CONTINUATION)
})

test('a new user instruction during agent history inspection blocks every remaining recovery effect', async () => {
  let release
  const history = new Promise(resolve => { release = resolve })
  const h = harness({ tasks: [AGENT], histories: { 'agent-1': history }, artifacts: [{ url: URL, state: 'armed' }] })
  await h.boot(); h.arm(); const pending = h.tick(); await new Promise(setImmediate)
  await h.fire('prompt.submit', { text: 'new task', origin: { kind: 'bridge' } })
  release([{ role: 'user', text: 'history', toolUses: [] }]); await pending
  assert.equal(h.calls.length, 0); assert.equal(h.prompts.length, 0)
  assert.equal(h.result().status, 'yielded')
})

test('artifact-only failures require attention and connecting remains waiting', async () => {
  for (const [response, expected] of [
    [{ deny: 'not accessible' }, 'needsAttention'],
    [{ result: { watch: { watching: false, connecting: true } } }, 'waiting'],
  ]) {
    const h = harness({ artifacts: [{ url: URL, state: 'armed', replies: true }] }); await h.boot()
    const request = h.arm({ sourceWasBusy: false }); request.work.needsContinuation = false
    h.files.set(`${ROOT}/requests/${SESSION}.json`, JSON.stringify(request))
    h.setResponse(event => event.url ? response : { result: { watches: [] } })
    await h.tick(); assert.equal(h.result().status, expected); assert.equal(h.prompts.length, 0)
  }
  const badInventory = harness({ artifacts: [{ url: URL, state: 'armed' }] }); await badInventory.boot()
  const request = badInventory.arm({ sourceWasBusy: false }); request.work.needsContinuation = false
  badInventory.files.set(`${ROOT}/requests/${SESSION}.json`, JSON.stringify(request))
  badInventory.setResponse(() => ({ deny: 'not accessible' })); await badInventory.tick()
  assert.equal(badInventory.result().status, 'needsAttention')
})

test('attention is not erased by a later ordinary tool success or turn completion', async () => {
  const h = harness({ tasks: [AGENT], agents: [{ id: 'agent-1', type: 'general-purpose', status: 'killed' }], histories: { 'agent-1': [{ role: 'user', text: 'history', toolUses: [] }] } })
  await h.boot(); h.arm()
  h.setResponse(event => event.tool === 'SendMessage' ? { deny: 'agent unavailable' } : { result: { watches: [] } })
  await h.tick(); assert.equal(h.result().status, 'needsAttention')
  await h.fire('turn.start', { turnId: 'resume', text: h.prompts[0] })
  await h.fire('tool.call', { tool: 'Read', tool_use_id: 'ordinary-success' }, async () => ({ result: 'read' }))
  await h.fire('turn.complete', { turnId: 'resume', answer: 'done' })
  assert.equal(h.result().status, 'needsAttention')
})

test('a failing step of the continuation is part of the work, not a problem with it', async () => {
  const h = harness(); await h.boot(); h.arm(); await h.tick()
  await h.fire('turn.start', { turnId: 'resume', text: h.prompts[0] })
  await h.fire('tool.call', { tool: 'Bash', tool_use_id: 'failing-tests' }, async () => ({ isError: true, text: 'tests failed' }))
  await h.fire('tool.call', { tool: 'Read', tool_use_id: 'ordinary-success' }, async () => ({ result: 'read' }))
  await h.fire('turn.complete', { turnId: 'resume', answer: 'done' })
  assert.equal(h.result().status, 'turnFinished')
  assert.ok(h.result().evidence.some(item => item.toolUseID === 'failing-tests' && item.outcome === 'blockedOrFailed'))
})

test('a finished continuation keeps its receipt when the person writes or stops afterwards', async () => {
  const h = harness(); await h.boot(); h.arm(); await h.tick()
  await h.fire('turn.start', { turnId: 'resume', text: h.prompts[0] })
  await h.fire('tool.call', { tool: 'Read', tool_use_id: 'checked' }, async () => ({ result: 'read' }))
  await h.fire('turn.complete', { turnId: 'resume', answer: 'done' })
  await h.fire('prompt.submit', { text: 'a next question', origin: { kind: 'composer' } })
  await h.fire('turn.start', { turnId: 'next', text: 'a next question' })
  await h.fire('turn.abort', { turnId: 'next' })
  await h.fire('turn.complete', { turnId: 'next', isAborted: true })
  assert.equal(h.result().status, 'turnFinished')
  assert.equal(h.result().revoked, true)
  assert.deepEqual(h.aborts, [])
})

test('a resumed agent blocked after the person took over leaves a finished continuation as it was', async () => {
  const h = harness({ tasks: [AGENT], agents: [{ id: 'agent-1', type: 'general-purpose', status: 'killed' }], histories: { 'agent-1': [{ role: 'user', text: 'history', toolUses: [] }] } })
  await h.boot(); h.arm(); await h.tick()
  const send = h.calls.find(call => call.tool === 'SendMessage')
  await h.fire('turn.start', { agentId: 'agent-1', turnId: 'agent-turn', text: `The coordinator sent a message while you were working: ${send.message}` })
  await h.fire('turn.start', { turnId: 'resume', text: h.prompts[0] })
  await h.fire('tool.call', { tool: 'Read', tool_use_id: 'checked' }, async () => ({ result: 'read' }))
  await h.fire('turn.complete', { turnId: 'resume', answer: 'done' })
  await h.fire('prompt.submit', { text: 'a next question', origin: { kind: 'composer' } })
  assert.equal(h.result().revoked, true)
  const blocked = await h.fire('tool.call', { tool: 'Bash', agentId: 'agent-1', tool_use_id: 'agent-step' }, async () => ({ result: {} }))
  assert.ok(blocked.deny)
  assert.equal(h.result().status, 'turnFinished')
  assert.doesNotMatch(h.result().error ?? '', /superseded|revoked/)
})

test('a comment watch still connecting is not waited for once the person takes over', async () => {
  for (const busy of [true, false]) {
    const h = harness({ artifacts: [{ url: URL, state: 'armed', replies: true }] }); await h.boot()
    const request = h.arm({ sourceWasBusy: busy }); request.work.needsContinuation = busy
    h.files.set(`${ROOT}/requests/${SESSION}.json`, JSON.stringify(request))
    h.setResponse(event => event.url ? { result: { watch: { connecting: true } } } : { result: { watches: [] } })
    await h.tick()
    if (busy) {
      await h.fire('turn.start', { turnId: 'resume', text: h.prompts[0] })
      await h.fire('tool.call', { tool: 'Read', tool_use_id: 'checked' }, async () => ({ result: 'read' }))
      await h.fire('turn.complete', { turnId: 'resume', answer: 'done' })
    }
    assert.equal(h.result().status, 'waiting', `busy ${busy}`)
    await h.fire('prompt.submit', { text: 'a next question', origin: { kind: 'composer' } })
    assert.equal(h.result().status, busy ? 'turnFinished' : 'inspected', `busy ${busy}`)
    const calls = h.calls.length
    h.advance(10_000); await h.tick()
    assert.equal(h.calls.length, calls, `busy ${busy}`)
  }
})

test('the stale turn of an agent the continuation stopped on purpose leaves the receipt as it was', async () => {
  const h = harness({ tasks: [AGENT], agents: [{ id: 'agent-1', type: 'general-purpose', status: 'killed' }], histories: { 'agent-1': [{ role: 'user', text: 'history', toolUses: [] }] } })
  await h.boot(); h.arm(); await h.tick()
  const send = h.calls.find(call => call.tool === 'SendMessage')
  await h.fire('turn.start', { turnId: 'resume', text: h.prompts[0] })
  await h.fire('tool.call', { tool: 'TaskStop', task_id: 'agent-1', tool_use_id: 'stop-agent' }, async () => ({ result: { task_id: 'agent-1' } }))
  const before = h.result().status
  assert.notEqual(before, 'needsAttention')
  await h.fire('turn.start', { agentId: 'agent-1', turnId: 'agent-turn', text: `The coordinator sent a message while you were working: ${send.message}` })
  assert.deepEqual(h.aborts, ['agent-turn'])
  assert.equal(h.result().status, before)
})

test('whatever the person sends over the continuation turn stops it, and their words run in a turn of their own', async () => {
  // Enter, a prompt queued to wait its turn (ctrl+x enter) and a command alike.
  for (const sent of [{ text: 'also update the README', wait: false }, { text: 'also update the README', wait: true },
    { text: '/context', wait: false, command: { name: 'context', args: '' } }]) {
    const label = JSON.stringify(sent)
    const h = harness(); await h.boot(); h.arm(); await h.tick()
    await h.fire('turn.start', { turnId: 'resume', text: `The cc-relay plugin sent a message:\n${h.prompts[0]}` })
    await h.fire('tool.call', { tool: 'Read', tool_use_id: 'checked' }, async () => ({ result: 'read' }))
    await h.fire('prompt.submit', { ...sent, origin: { kind: 'composer' }, turnId: 'resume' })
    assert.deepEqual(h.aborts, ['resume'], label)
    assert.equal(h.result().status, 'yielded')
    // Its tools stay blocked, should the stop not land.
    assert.ok((await h.fire('tool.call', { tool: 'Bash', tool_use_id: 'old-step' }, async () => ({ result: {} }))).deny)
    await h.fire('turn.complete', { turnId: 'resume', isAborted: true, answer: '' })
    await h.fire('turn.start', { turnId: 'mine', text: sent.text })
    let reached = false
    await h.fire('tool.call', { tool: 'Edit', tool_use_id: 'for-the-person' }, async () => { reached = true; return { result: {} } })
    assert.equal(reached, true, label)
    // The stop was this plugin's, not the person's: a later switch does not take it for one.
    assert.equal(h.report().userStopped, false, label)
  }
})

const HOST_RESUME = 'The app was quit while you were working. Please continue from where you left off.'

test('a native wakeup during target launch is held without claiming work before launch confirmation', async () => {
  const h = harness(); await h.boot(); h.arm({ phase: 'prepared' })
  const path = `${ROOT}/active.json`
  const operation = JSON.parse(h.files.get(path))
  h.files.set(path, JSON.stringify({ ...operation, ready: false, launchPrepared: true }))
  assert.ok((await h.fire('prompt.submit', { text: HOST_RESUME, origin: { kind: 'sdk' } })).drop)
  await h.tick()
  assert.equal(h.result(), undefined)
  assert.deepEqual(h.prompts, [])
  h.arm(); await h.tick(); await h.tick()
  assert.equal(h.prompts.length, 1)
  assert.match(h.prompts[0], /requestID=req-1/)
})

test('Claude\'s own continue after the switch\'s quit gives way to the continuation, which runs once', async () => {
  const h = harness(); await h.boot()
  // Reopened in the target before CC-Relay armed the request for this runtime.
  h.arm({ phase: 'prepared' })
  assert.ok((await h.fire('prompt.submit', { text: HOST_RESUME, origin: { kind: 'sdk' } })).drop)
  h.arm(); await h.tick(); await h.tick()
  assert.equal(h.prompts.length, 1)
  assert.match(h.prompts[0], /requestID=req-1/)
  assert.equal(h.result().status, 'queued')
  h.advance(120_001); await h.tick()
  assert.equal(h.prompts.length, 1)
})

test('an idle handoff consumes its native wakeup without starting a model turn', async () => {
  const idle = harness(); await idle.boot()
  const request = idle.arm({ phase: 'prepared', sourceWasBusy: false }); request.work.needsContinuation = false
  idle.files.set(`${ROOT}/requests/${SESSION}.json`, JSON.stringify(request))
  assert.ok((await idle.fire('prompt.submit', { text: HOST_RESUME, origin: { kind: 'sdk' } })).drop)
  idle.files.set(`${ROOT}/requests/${SESSION}.json`, JSON.stringify({ ...request, phase: 'armed' }))
  await idle.tick(); await idle.tick()
  assert.equal(idle.result().status, 'inspected')
  assert.deepEqual(idle.prompts, [])
  // Desktop can send the wakeup after the plugin has already inspected the idle handoff.
  assert.ok((await idle.fire('prompt.submit', { text: HOST_RESUME, origin: { kind: 'sdk' } })).drop)
  idle.advance(120_001); await idle.tick()
  assert.deepEqual(idle.prompts, [])
})

test('a conversation CC-Relay reopened for its comment watch alone drops Desktop\'s continue once', async () => {
  const note = `${ROOT}/watch-reopen/${SESSION}.json`
  const valid = { version: 1, sessionID: SESSION, until: NOW + 86_400_000 }
  const h = harness({ files: new Map([[note, JSON.stringify(valid)]]) })
  await h.boot()
  assert.equal(JSON.parse(h.files.get(note)).used, true, 'the start consumes the note')
  assert.ok(h.report().capabilities.includes('watch-reopen-v1'))
  assert.ok((await h.fire('prompt.submit', { text: HOST_RESUME, origin: { kind: 'sdk' } })).drop)
  // Only the continue that follows the start: a later one goes through.
  assert.equal((await h.fire('prompt.submit', { text: HOST_RESUME, origin: { kind: 'sdk' } })).text, HOST_RESUME)
  assert.deepEqual(h.prompts, [])
  // A used, expired or foreign note changes nothing, and neither does one that comes too late.
  for (const value of [{ used: true }, { until: NOW - 1 }, { sessionID: 'another-session' }]) {
    const other = harness({ files: new Map([[note, JSON.stringify({ ...valid, ...value })]]) })
    await other.boot()
    assert.equal((await other.fire('prompt.submit', { text: HOST_RESUME, origin: { kind: 'sdk' } })).text, HOST_RESUME)
  }
  const slow = harness({ files: new Map([[note, JSON.stringify(valid)]]) })
  await slow.boot(); slow.advance(120_001)
  assert.equal((await slow.fire('prompt.submit', { text: HOST_RESUME, origin: { kind: 'sdk' } })).text, HOST_RESUME)
})

const PAGE = 'https://claude.ai/artifact/1234-abcd', OTHER = 'https://claude.ai/code/artifact/5678-efgh'
function keptWatch(h, account, fields = {}) {
  h.files.set(`${ROOT}/left-watches/${account}.json`, JSON.stringify([{ desktopSessionID: 'desktop-1', sessionID: SESSION,
    title: 'Review the page', leftAt: NOW - 60_000, pages: [PAGE], ...fields }]))
}

test('a watch kept for the account that published its page is left to it, and the work goes on without it', async () => {
  const artifacts = [{ url: URL, state: 'armed', replies: true }]
  const h = harness({ artifacts, worker: true })
  h.setArtifactInput({ exitCode: 0, stdout: JSON.stringify({ version: 1, sessionID: SESSION, branchComplete: true, artifacts }) })
  await h.boot()
  keptWatch(h, 'Claude_source')
  h.arm()
  h.advance(10_000); await h.tick()
  // This account cannot open the page: nothing is asked of the host, and nothing needs the person.
  assert.equal(h.calls.filter(call => call.tool === 'ArtifactComments').length, 0)
  assert.notEqual(h.result().status, 'needsAttention')
  assert.ok(h.result().evidence.some(item => item.outcome === 'watchesStayed'))
  assert.equal(h.prompts.length, 1)
  assert.equal(h.prompts[0], CONTINUATION)
  await h.fire('turn.start', { turnId: 'resume', text: h.prompts[0] })
  const response = await h.fire('tool.call', { tool: 'ArtifactComments', tool_use_id: 'rewatch', action: 'watch', url: URL },
    async () => { assert.fail('the continuation must not watch a page another account published') })
  assert.match(response.deny, /stays with the account that published/)
  // Nor does the start's own recovery try it once the switch is over.
  await h.fire('turn.complete', { turnId: 'resume', reason: 'answer', isAborted: false })
  h.files.delete(`${ROOT}/active.json`)
  h.advance(10_000); await h.tick()
  assert.equal(h.calls.filter(call => call.tool === 'ArtifactComments').length, 0)
  assert.deepEqual(h.toasts, [])
})

test('only another account\'s recent record holds a watch back, and only for the pages it names', async () => {
  const artifacts = [{ url: URL, state: 'armed', replies: true }, { url: OTHER, state: 'armed', replies: true }]
  const h = harness({ artifacts, worker: true }); await h.boot()
  // The account this switch opens restores its own pages; a record over a week old holds nothing.
  keptWatch(h, 'Claude_target', { pages: [PAGE, 'https://claude.ai/artifact/5678-efgh'] })
  keptWatch(h, 'Claude_old', { pages: ['https://claude.ai/artifact/5678-efgh'], leftAt: NOW - 8 * 86_400_000 })
  keptWatch(h, 'Claude_source')
  h.arm({ targetProfile: 'Claude_target' })
  h.files.set(`${ROOT}/active.json`, JSON.stringify({ version: 1, ready: true, operationID: 'op-1', targetProfile: 'Claude_target', targetAccountID: 'account-target' }))
  h.advance(10_000); await h.tick()
  assert.equal(h.calls.filter(call => call.url === URL).length, 0)
  assert.equal(h.calls.filter(call => call.url === OTHER).length, 1)
  assert.ok(h.result().evidence.some(item => item.outcome === 'repliesRestored'))
  assert.equal(h.prompts[0], CONTINUATION)
})

test('reopening a conversation leaves a watch kept for the account that published its page', async () => {
  for (const pages of [[PAGE], undefined]) {
    const artifacts = [{ url: URL, state: 'armed', replies: true }, { url: OTHER, state: 'armed', replies: true }]
    const h = harness({ artifacts, worker: true })
    h.setArtifactInput({ exitCode: 0, stdout: JSON.stringify({ version: 1, sessionID: SESSION, branchComplete: true, artifacts }) })
    await h.boot()
    keptWatch(h, 'Claude_source', { pages })
    h.advance(10_000); await h.tick()
    assert.equal(h.calls.filter(call => call.url === URL).length, 0)
    // An older record, without pages, holds every watch of its conversation.
    assert.equal(h.calls.filter(call => call.url === OTHER).length, pages ? 1 : 0)
    assert.deepEqual(h.toasts, [])
  }
})

test('reopened in the account its watch was kept for, a conversation picks that watch up again', async () => {
  const artifacts = [{ url: URL, state: 'armed', replies: true }, { url: OTHER, state: 'armed', replies: true }]
  // This runtime runs under a helper of the Claude that CC-Relay lists as open on Claude_a.
  const processes = '12345   400 Fri Oct 30 13:20:00 2026  \n  400   500 Fri Oct 30 13:18:05 2026\n  500     1 Fri Oct  2 13:18:03 2026\n'
  const listed = { pid: 500, procStart: 'Fri Oct 2 13:18:03 2026', account: 'Claude_a' }
  for (const [open, own] of [[[listed], true], [[{ ...listed, procStart: 'Fri Oct 2 13:18:04 2026' }], false],
    [[{ ...listed, pid: 600 }], false], [undefined, false]]) {
    const h = harness({ artifacts, worker: true, processes })
    h.setArtifactInput({ exitCode: 0, stdout: JSON.stringify({ version: 1, sessionID: SESSION, branchComplete: true, artifacts }) })
    await h.boot()
    // Claude_a has opened since, so its record only tells whose page it is; Claude_b still waits.
    keptWatch(h, 'Claude_a', { opened: true })
    keptWatch(h, 'Claude_b', { pages: [OTHER] })
    if (open) h.files.set(`${ROOT}/open-accounts.json`, JSON.stringify(open))
    h.advance(10_000); await h.tick()
    // A Claude listed with another start is another process under a reused PID; not listed at
    // all, the account stays unknown and every kept watch stays where it is.
    assert.equal(h.calls.filter(call => call.url === URL).length, own ? 1 : 0, JSON.stringify(open))
    assert.equal(h.calls.filter(call => call.url === OTHER).length, 0)
    assert.equal(h.psCalls.length, open ? 1 : 0)
    assert.deepEqual(h.toasts, [])
  }
  // A conversation with nothing kept for it does not look for its account.
  const h = harness({ artifacts, worker: true, processes })
  h.setArtifactInput({ exitCode: 0, stdout: JSON.stringify({ version: 1, sessionID: SESSION, branchComplete: true, artifacts }) })
  await h.boot()
  h.files.set(`${ROOT}/open-accounts.json`, JSON.stringify([listed]))
  h.advance(10_000); await h.tick()
  assert.equal(h.calls.filter(call => call.url === URL || call.url === OTHER).length, 2)
  assert.deepEqual(h.psCalls, [])
})

test('a conversation CC-Relay started for its watch picks up the watch kept for the account it started it in', async () => {
  const artifacts = [{ url: URL, state: 'armed', replies: true }, { url: OTHER, state: 'armed', replies: true }]
  const note = `${ROOT}/watch-reopen/${SESSION}.json`
  const h = harness({ artifacts, worker: true,
    files: new Map([[note, JSON.stringify({ version: 1, sessionID: SESSION, until: NOW + 86_400_000, account: 'Claude_a' })]]) })
  h.setArtifactInput({ exitCode: 0, stdout: JSON.stringify({ version: 1, sessionID: SESSION, branchComplete: true, artifacts }) })
  await h.boot()
  keptWatch(h, 'Claude_a', { opened: true })
  keptWatch(h, 'Claude_b', { pages: [OTHER] })
  h.advance(10_000); await h.tick()
  assert.equal(h.calls.filter(call => call.url === URL).length, 1)
  assert.equal(h.calls.filter(call => call.url === OTHER).length, 0)
  assert.deepEqual(h.psCalls, [], 'the note names the account')
})

const OWN_PROCESSES = '12345   400 Fri Oct 30 13:20:00 2026  \n  400   500 Fri Oct 30 13:18:05 2026\n  500     1 Fri Oct  2 13:18:03 2026\n'
const OWN_CLAUDE = { pid: 500, procStart: 'Fri Oct 2 13:18:03 2026', account: 'Claude_a' }

test('a kept watch that may be this account\'s own waits for the account to be known', async () => {
  const artifacts = [{ url: URL, state: 'armed', replies: true }, { url: OTHER, state: 'armed', replies: true }]
  const h = harness({ artifacts, worker: true, processes: OWN_PROCESSES })
  h.setArtifactInput({ exitCode: 0, stdout: JSON.stringify({ version: 1, sessionID: SESSION, branchComplete: true, artifacts }) })
  await h.boot()
  keptWatch(h, 'Claude_a', { opened: true })
  h.advance(10_000); await h.tick()
  // The rest goes on; the kept one is left alone for now.
  assert.equal(h.calls.filter(call => call.url === OTHER).length, 1)
  assert.equal(h.calls.filter(call => call.url === URL).length, 0)
  // CC-Relay lists this Claude at its next look: the watch is this account's own after all.
  h.files.set(`${ROOT}/open-accounts.json`, JSON.stringify([OWN_CLAUDE]))
  for (let looks = 0; looks < 3; looks++) { h.advance(30_000); await h.tick() }
  assert.equal(h.calls.filter(call => call.url === URL).length, 1)
  assert.equal(h.calls.filter(call => call.url === OTHER).length, 1)
  assert.equal(h.helperCalls.filter(call => call.includes('artifact-input')).length, 1, 'the history is read once')
  assert.deepEqual(h.toasts, [])
})

test('a kept watch stops waiting once its account is known to be another, or after six minutes', async () => {
  const artifacts = [{ url: URL, state: 'armed', replies: true }]
  const input = { exitCode: 0, stdout: JSON.stringify({ version: 1, sessionID: SESSION, branchComplete: true, artifacts }) }
  const known = harness({ artifacts, worker: true, processes: OWN_PROCESSES })
  known.setArtifactInput(input)
  await known.boot()
  keptWatch(known, 'Claude_b')
  known.files.set(`${ROOT}/open-accounts.json`, JSON.stringify([OWN_CLAUDE]))
  known.advance(10_000); await known.tick()
  for (let looks = 0; looks < 3; looks++) { known.advance(30_000); await known.tick() }
  assert.equal(known.psCalls.length, 1)
  assert.equal(known.calls.filter(call => call.url === URL).length, 0)

  const never = harness({ artifacts, worker: true, processes: OWN_PROCESSES })
  never.setArtifactInput(input)
  await never.boot()
  keptWatch(never, 'Claude_a', { opened: true })
  never.advance(10_000); await never.tick()
  for (let looks = 0; looks < 14; looks++) { never.advance(30_000); await never.tick() }
  never.files.set(`${ROOT}/open-accounts.json`, JSON.stringify([OWN_CLAUDE]))
  for (let looks = 0; looks < 3; looks++) { never.advance(30_000); await never.tick() }
  assert.equal(never.calls.filter(call => call.url === URL).length, 0)
  assert.deepEqual(never.toasts, [])
})

test('a note left for another account stays for that account', async () => {
  const note = `${ROOT}/watch-reopen/${SESSION}.json`
  const value = { version: 1, sessionID: SESSION, until: NOW + 86_400_000, account: 'Claude_b' }
  const h = harness({ processes: OWN_PROCESSES, files: new Map([[note, JSON.stringify(value)],
    [`${ROOT}/open-accounts.json`, JSON.stringify([OWN_CLAUDE])]]) })
  await h.boot()
  assert.equal(JSON.parse(h.files.get(note)).used, undefined, 'this account leaves it unused')
  assert.equal((await h.fire('prompt.submit', { text: HOST_RESUME, origin: { kind: 'sdk' } })).text, HOST_RESUME)
  // The account it names takes it up; with the account not known yet, the note stands for it.
  for (const open of [[{ ...OWN_CLAUDE, account: 'Claude_b' }], undefined]) {
    const files = new Map([[note, JSON.stringify(value)]])
    if (open) files.set(`${ROOT}/open-accounts.json`, JSON.stringify(open))
    const own = harness({ processes: OWN_PROCESSES, files })
    await own.boot()
    assert.equal(JSON.parse(own.files.get(note)).used, true)
    assert.ok((await own.fire('prompt.submit', { text: HOST_RESUME, origin: { kind: 'sdk' } })).drop)
  }
})

test('Claude\'s own continue goes out after all when no continuation claims the handoff', async () => {
  // Nothing claims it within the wait; a claim that comes later gives way.
  const late = harness(); await late.boot(); late.arm({ phase: 'prepared' })
  assert.ok((await late.fire('prompt.submit', { text: HOST_RESUME, origin: { kind: 'sdk' } })).drop)
  await late.tick()
  assert.equal(late.prompts.length, 0)
  late.advance(120_001); await late.tick()
  assert.deepEqual(late.prompts, [HOST_RESUME])
  late.arm(); await late.tick()
  assert.equal(late.result().status, 'yielded')
  assert.equal(late.prompts.length, 1)
  // The switch was called off.
  const off = harness(); await off.boot(); off.arm({ phase: 'prepared' })
  assert.ok((await off.fire('prompt.submit', { text: HOST_RESUME, origin: { kind: 'sdk' } })).drop)
  off.files.delete(`${ROOT}/active.json`); await off.tick()
  assert.deepEqual(off.prompts, [HOST_RESUME])
})

test('Claude\'s own continue is not the person\'s words, which still take over', async () => {
  // With no switch on its way it goes through, and a continuation armed after it still runs.
  const h = harness(); await h.boot()
  assert.equal((await h.fire('prompt.submit', { text: HOST_RESUME, origin: { kind: 'sdk' } })).text, HOST_RESUME)
  h.arm(); await h.tick()
  assert.equal(h.result().status, 'queued')
  assert.match(h.prompts[0], /requestID=req-1/)
  // The person writing while it is held: their words go, and nothing else does.
  const person = harness(); await person.boot(); person.arm({ phase: 'prepared' })
  assert.ok((await person.fire('prompt.submit', { text: HOST_RESUME, origin: { kind: 'sdk' } })).drop)
  assert.equal((await person.fire('prompt.submit', { text: 'do this instead', origin: { kind: 'sdk' } })).text, 'do this instead')
  person.arm(); await person.tick()
  assert.equal(person.result().status, 'yielded')
  person.advance(120_001); await person.tick()
  assert.equal(person.prompts.length, 0)
})

test('Claude\'s continue after a quit still counts reworded; with anything more in it, it is the person\'s', async () => {
  for (const text of [
    'the app was closed while you were working.\n\nContinue where you left off',
    'Claude was restarted while you were working — please resume from where you left off!',
    'Please continue from where you left off. The App Was Quit While You Were Working.',
  ]) {
    const h = harness(); await h.boot(); h.arm({ phase: 'prepared' })
    assert.ok((await h.fire('prompt.submit', { text, origin: { kind: 'sdk' } })).drop, text)
    h.arm(); await h.tick(); await h.tick()
    assert.equal(h.prompts.length, 1, text)
    assert.match(h.prompts[0], /requestID=req-1/)
  }
  for (const text of [
    'The app was quit while you were working. Please continue from where you left off, but skip the tests.',
    'Do not continue where you left off; the app was quit while you were working.',
    'Please continue from where you left off.',
  ]) {
    const h = harness(); await h.boot(); h.arm({ phase: 'prepared' })
    assert.equal((await h.fire('prompt.submit', { text, origin: { kind: 'sdk' } })).text, text)
    h.arm(); await h.tick()
    assert.equal(h.result().status, 'yielded', text)
    assert.equal(h.prompts.length, 0, text)
  }
})

test('connecting artifact watches are verified read-only and eventually resolve or need attention', async () => {
  for (const connects of [true, false]) {
    const h = harness({ artifacts: [{ url: URL, state: 'armed', replies: true }] }); await h.boot()
    const request = h.arm({ sourceWasBusy: false }); request.work.needsContinuation = false
    h.files.set(`${ROOT}/requests/${SESSION}.json`, JSON.stringify(request))
    h.setResponse(event => event.url ? { result: { watch: { connecting: true } } } : { result: { watches: [] } })
    await h.tick(); assert.equal(h.result().status, 'waiting')
    h.setResponse(() => ({ result: { watches: [{ url: URL, connected: connects, connecting: !connects, auto_reply: 'armed', task_id: 'watch-1' }] } }))
    for (let i = 0; i < 6; i += 1) { h.advance(10_000); await h.tick() }
    assert.equal(h.result().status, connects ? 'inspected' : 'needsAttention')
    assert.equal(h.calls.filter(call => call.on === true).length, 1)
    assert.equal(h.prompts.length, 0)
    if (connects) assert.ok(h.result().evidence.some(item => item.outcome === 'repliesRestored'))
  }
})

test('historical agent candidates are not automatically revived and attempted IDs are not sent twice', async () => {
  const old = { ...AGENT, sourceLine: 1 }
  const h = harness({ tasks: [old], histories: { 'agent-1': [{ toolUses: [] }] } })
  await h.boot(); h.arm(); await h.tick()
  assert.equal(h.calls.filter(call => call.tool === 'SendMessage').length, 0)
  assert.equal(h.prompts[0], CONTINUATION)
  const fresh = harness({ tasks: [AGENT], histories: { 'agent-1': [{ toolUses: [] }] } })
  await fresh.boot(); fresh.arm(); await fresh.tick()
  assert.equal(fresh.prompts[0], CONTINUATION)
  assert.ok(fresh.result().evidence.some(item => item.agentID === 'agent-1' && item.outcome === 'returnedAwaitingAgentProgress'))
  await fresh.fire('turn.start', { turnId: 'resume', text: fresh.prompts[0] })
  let duplicateReachedHost = false
  const result = await fresh.fire('tool.call', { tool: 'SendMessage', to: 'agent-1', message: fresh.calls[0].message }, async () => {
    duplicateReachedHost = true; return { result: { success: true } }
  })
  assert.equal(duplicateReachedHost, false); assert.ok(result.deny)
})

test('a stale turn cannot execute tools when cancellation or receipt persistence fails', async () => {
  for (const failPersistence of [false, true]) {
    const h = harness(); await h.boot(); h.arm(); await h.tick()
    await h.fire('prompt.submit', { text: 'Stop old work; do the new task', origin: { kind: 'composer' } })
    h.setAbortFailure(new Error('injected host cancellation failure'))
    if (failPersistence) h.setWriteFailure('/results/')
    await h.fire('turn.start', { turnId: 'stale', text: h.prompts[0] })
    let reachedHost = 0
    const result = await h.fire('tool.call', { tool: 'Bash', tool_use_id: 'old-write' }, async () => {
      reachedHost++; return { result: { stdout: 'must not execute' } }
    })
    assert.equal(reachedHost, 0)
    assert.ok(result.deny)
    assert.deepEqual(h.aborts, ['stale'])
    if (!failPersistence) assert.equal(h.result().status, 'yielded')
    // Revocation belongs to the old turn, not the user's next work.
    await h.fire('turn.complete', { turnId: 'stale' })
    await h.fire('turn.start', { turnId: 'new-user', text: 'The authorized new task' })
    await h.fire('tool.call', { tool: 'Read', tool_use_id: 'new-read' }, async () => {
      reachedHost++; return { result: 'allowed' }
    })
    assert.equal(reachedHost, 1)
  }
})

test('generation replacement revokes old turn tools even after in-memory recovery is cleared', async () => {
  const h = harness(); await h.boot(); h.arm(); await h.tick()
  h.files.set(`${ROOT}/active.json`, JSON.stringify({ version: 1, ready: true, operationID: 'new-generation' }))
  await h.tick()
  h.setAbortFailure(new Error('cannot cancel'))
  await h.fire('turn.start', { turnId: 'old-generation', text: h.prompts[0] })
  let ran = false
  const result = await h.fire('tool.call', { tool: 'Monitor' }, async () => { ran = true; return { result: { taskId: 'must-not-start' } } })
  assert.equal(ran, false)
  assert.ok(result.deny)
})

test('a new instruction revokes subsequent tools of an already running automatic turn', async () => {
  const h = harness(); await h.boot(); h.arm(); await h.tick()
  await h.fire('turn.start', { turnId: 'automatic', text: h.prompts[0] })
  await h.fire('prompt.submit', { text: 'Stop the previous task', origin: { kind: 'bridge' } })
  let ran = false
  const result = await h.fire('tool.call', { tool: 'Bash' }, async () => { ran = true; return { result: 'wrong work' } })
  assert.equal(ran, false)
  assert.ok(result.deny)
})

test('trusted compactor resumes retain the original request across repeated pauses', async () => {
  const h = harness(); await h.boot(); h.arm(); await h.tick()
  let text = h.prompts[0]
  for (let pause = 0; pause < 2; pause++) {
    const turnId = `before-compaction-${pause}`
    await h.fire('turn.start', { turnId, text })
    const compactor = Object.assign(async event => event, { origin: { plugin: 'cc-relay', tier: 'user' } })
    await h.fire('turn.abort', { turnId }, compactor)
    await h.fire('turn.complete', { turnId, isAborted: true })
    const unrelated = await h.fire('prompt.submit', { text: 'Continue the same words', origin: { kind: 'plugin', name: 'another-plugin' } })
    assert.equal(unrelated.text, 'Continue the same words')
    const resumed = await h.fire('prompt.submit', { text: 'Continue after compaction', origin: { kind: 'plugin', name: 'cc-relay' } })
    assert.ok(resumed.text.startsWith('[Continuation requestID=req-1]'))
    text = resumed.text
  }
  await h.fire('turn.start', { turnId: 'after-compaction', text })
  await h.fire('tool.call', { tool: 'Read', tool_use_id: 'verified-after-compaction' }, async () => ({ result: 'work checked' }))
  await h.fire('turn.complete', { turnId: 'after-compaction' })
  assert.equal(h.report().userStopped, false)
  assert.equal(h.result().status, 'turnFinished')
  assert.equal(h.result().turnID, 'after-compaction')
  assert.ok(h.result().evidence.some(item => item.toolUseID === 'verified-after-compaction'))
})

test('a superseded compactor resume stays marked and its stale tools remain blocked', async () => {
  const h = harness(); await h.boot(); h.arm(); await h.tick()
  await h.fire('turn.start', { turnId: 'paused', text: h.prompts[0] })
  const compactor = Object.assign(async event => event, { origin: { plugin: 'cc-relay', tier: 'user' } })
  await h.fire('turn.abort', { turnId: 'paused' }, compactor)
  await h.fire('turn.complete', { turnId: 'paused', isAborted: true })
  await h.fire('prompt.submit', { text: 'New instructions win', origin: { kind: 'composer' } })
  const resumed = await h.fire('prompt.submit', { text: 'Continue after compaction', origin: { kind: 'plugin', name: 'cc-relay' } })
  assert.match(resumed.text, /^\[Continuation requestID=req-1\]/)
  h.setAbortFailure(new Error('host unavailable'))
  await h.fire('turn.start', { turnId: 'stale-compactor-resume', text: resumed.text })
  let ran = false
  const result = await h.fire('tool.call', { tool: 'Bash' }, async () => { ran = true; return { result: 'must not execute' } })
  assert.equal(ran, false)
  assert.ok(result.deny)
})

test('compactor wording without a matching pause is never granted a recovery marker', async () => {
  const h = harness(); await h.boot(); h.arm(); await h.tick()
  const result = await h.fire('prompt.submit', { text: 'Continue after compaction', origin: { kind: 'plugin', name: 'cc-relay' } })
  assert.equal(result.text, 'Continue after compaction')
})

test('Monitor events require their own task envelope and cannot borrow IDs from task output', async () => {
  const h = harness(); await h.boot(); h.arm(); await h.tick()
  await h.fire('turn.start', { turnId: 'resume', text: h.prompts[0] })
  await h.fire('tool.call', { tool: 'Monitor', tool_use_id: 'new-monitor' }, async () => ({ result: { taskId: 'monitor-new' } }))
  const falseEvidence = [
    '<task-notification><task-id>foreign</task-id><status>completed</status><summary>The log mentions monitor-new</summary></task-notification>',
    '<task-notification><task-id>foreign</task-id><output><task-id>monitor-new</task-id><event>changed</event></output></task-notification>',
    '<task-notification><task-id>foreign</task-id><task-id>monitor-new</task-id><event>changed</event></task-notification>',
    '<task-id>monitor-new</task-id><output>no native envelope</output>',
    '<task-notification><task-id>monitor-new-extra</task-id><event>changed</event></task-notification>',
  ]
  for (const text of falseEvidence) await h.fire('prompt.submit', { text, origin: { kind: 'task-notification' } })
  const events = () => h.result().evidence.filter(item => item.outcome === 'monitorEventObserved')
  assert.equal(events().length, 0)
  const text = '<task-notification><task-id>monitor-new</task-id><event>changed</event><output>new data</output></task-notification>'
  await h.fire('prompt.submit', { text, origin: { kind: 'plugin', name: 'untrusted-plugin' } })
  assert.equal(events().length, 0)
  await h.fire('prompt.submit', { text, origin: { kind: 'task-notification' } })
  await h.fire('prompt.submit', { text, origin: { kind: 'task-notification' } })
  assert.equal(events().length, 1)
  assert.equal(events()[0].taskID, 'monitor-new')
})

test('a stopped ArtifactComments snapshot never enables its watch in the new account', async () => {
  const artifacts = [{ id: 'artifact-1', url: URL, state: 'stopped' }]
  const h = harness({ artifacts }); await h.boot()
  h.arm({ sourceWasBusy: false, work: { version: 1, cliSessionID: SESSION, branchComplete: true,
    needsContinuation: false, tasks: [], artifacts } })
  await h.tick()
  assert.equal(h.calls.length, 0)
  assert.equal(h.prompts.length, 0)
  assert.equal(h.result().status, 'inspected')
})

test('failure and explicit stop are terminal even when a late Monitor data notification arrives afterward', async () => {
  for (const stop of ['failure', 'TaskStop']) {
    const h = harness(); await h.boot(); h.arm(); await h.tick()
    await h.fire('turn.start', { turnId: 'resume', text: h.prompts[0] })
    await h.fire('tool.call', { tool: 'Monitor', tool_use_id: 'new-monitor' }, async () => ({ result: { taskId: 'monitor-new' } }))
    if (stop === 'failure') await h.fire('prompt.submit', { origin: { kind: 'task-notification' }, text: '<task-notification><task-id>monitor-new</task-id><status>failed</status><summary>Watch exited</summary></task-notification>' })
    else await h.fire('tool.call', { tool: 'TaskStop', task_id: 'monitor-new' }, async () => ({ result: { task_id: 'monitor-new' } }))
    await h.fire('prompt.submit', { origin: { kind: 'task-notification' }, text: '<task-notification><task-id>monitor-new</task-id><event>late data</event></task-notification>' })
    assert.equal(h.result().evidence.filter(item => item.outcome === 'monitorEventObserved').length, 0, stop)
    await h.heartbeat(); assert.ok(!h.report().activeTasks.some(task => task.id === 'monitor-new'))
  }
})

test('an older live Monitor and background Bash survive later completed user questions in the source inventory', async () => {
  const h = harness(); await h.boot()
  await h.fire('turn.start', { turnId: 'original', text: 'watch original work' })
  await h.fire('tool.call', { tool: 'Monitor', tool_use_id: 'ws-use', description: 'original watch' },
    async () => ({ result: { taskId: 'old-ws', timeoutMs: 600000 } }))
  await h.fire('tool.call', { tool: 'Bash', tool_use_id: 'bash-use', command: 'fixture', run_in_background: true },
    async () => ({ result: { backgroundTaskId: 'old-shell', stdout: '', stderr: '', interrupted: false } }))
  await h.fire('turn.complete', { turnId: 'original', answer: 'registered' })
  await h.fire('prompt.submit', { origin: { kind: 'composer' }, text: 'another question' })
  await h.fire('turn.start', { turnId: 'later', text: 'another question' })
  await h.fire('turn.complete', { turnId: 'later', answer: 'answered' })
  await h.heartbeat()
  assert.equal(h.report().busy, true)
  assert.deepEqual(h.report().activeTasks.map(t => [t.id, t.kind, t.toolUseID]), [['old-ws', 'monitor', 'ws-use'], ['old-shell', 'bash', 'bash-use']])
  await h.fire('tool.call', { tool: 'TaskStop', task_id: 'old-ws' }, async () => ({ deny: 'not stopped' }))
  assert.equal(h.report().activeTasks.length, 2)
  await h.fire('tool.call', { tool: 'TaskStop', task_id: 'old-ws' }, async () => ({ result: { message: 'stopped', task_id: 'old-ws', task_type: 'monitor' } }))
  await h.fire('prompt.submit', { origin: { kind: 'task-notification' }, text: '<task-notification><task-id>old-shell</task-id><status>completed</status><summary>done</summary></task-notification>' })
  await h.heartbeat()
  assert.deepEqual(h.report().activeTasks, [])
  assert.equal(h.report().busy, false)
})

test('a verified active older agent is considered after a later question, while terminal facts still win', async () => {
  for (const stopped of [false, true]) {
    const h = harness({ tasks: [AGENT], histories: { 'agent-1': [{ role: 'user', text: 'original history', toolUses: [] }] } })
    await h.boot()
    const request = h.arm({ sourceActiveTasks: [{ id: 'agent-1', kind: 'agent' }] })
    request.work.latestUser.sourceLine = 100
    h.files.set(`${ROOT}/requests/${SESSION}.json`, JSON.stringify(request))
    if (stopped) h.setMessages([{ toolUses: [{ tool: 'TaskStop', input: { task_id: 'agent-1' }, result: { message: 'stopped' } }] }])
    await h.tick()
    assert.equal(h.calls.filter(c => c.tool === 'SendMessage').length, stopped ? 0 : 1)
    assert.equal(h.prompts[0], CONTINUATION)
    assert.deepEqual(JSON.parse(h.files.get(`${ROOT}/requests/${SESSION}.json`)).sourceActiveTasks, [{ id: 'agent-1', kind: 'agent' }])
  }
})

test('automatic child turns cannot execute after TaskStop, newer instructions or generation replacement, even if cancellation fails', async () => {
  for (const timing of ['already-started', 'late-delivery']) {
    for (const revoke of ['stop', 'instruction', 'generation']) {
      const h = harness({ tasks: [AGENT], histories: { 'agent-1': [{ role: 'user', text: 'history', toolUses: [] }] } })
      await h.boot(); h.arm(); await h.tick()
      const child = { turnId: 'automatic-child', agentId: 'agent-1', text: h.calls.find(c => c.tool === 'SendMessage').message }
      if (timing === 'already-started') await h.fire('turn.start', child)
      if (revoke === 'stop') await h.fire('tool.call', { tool: 'TaskStop', task_id: 'agent-1' },
        async () => ({ result: { message: 'stopped', task_id: 'agent-1', task_type: 'agent' } }))
      if (revoke === 'instruction') await h.fire('prompt.submit', { origin: { kind: 'composer' }, text: 'new authorized work' })
      if (revoke === 'generation') { h.files.delete(`${ROOT}/active.json`); await h.tick() }
      h.setAbortFailure(new Error('host cancellation failed')); h.setWriteFailure('/results/')
      if (timing === 'late-delivery') await h.fire('turn.start', child)
      let executed = 0
      const denied = await h.fire('tool.call', { tool: 'Bash', agentId: 'agent-1', command: 'must never execute' },
        async () => { executed += 1; return { result: { stdout: 'bad', stderr: '', interrupted: false } } })
      assert.equal(executed, 0, `${timing}/${revoke}`); assert.equal(typeof denied.deny, 'string')
      // An unmarked manual turn for the same agent remains usable.
      await h.fire('turn.start', { turnId: 'manual-child', agentId: 'agent-1', text: 'new manual instruction' })
      await h.fire('tool.call', { tool: 'Bash', agentId: 'agent-1', command: 'manual fixture' },
        async () => { executed += 1; return { result: { stdout: 'ok', stderr: '', interrupted: false } } })
      assert.equal(executed, 1)
    }
  }
})

test('early child execution remains executing when the parent continuation is queued later', async () => {
  const h = harness({ tasks: [AGENT], histories: { 'agent-1': [{ role: 'user', text: 'history', toolUses: [] }] } })
  await h.boot(); h.arm()
  h.setResponse(async event => {
    if (event.tool === 'SendMessage') {
      await h.fire('turn.start', { turnId: 'child-first', agentId: 'agent-1', text: event.message })
      await h.fire('tool.call', { tool: 'Bash', agentId: 'agent-1', command: 'fixture' },
        async () => ({ result: { stdout: 'continued', stderr: '', interrupted: false } }))
      assert.equal(h.result().status, 'executing')
    }
    return { result: { success: true } }
  })
  await h.tick()
  assert.equal(h.prompts.length, 1)
  assert.equal(h.result().status, 'executing')
  assert.ok(h.result().evidence.some(e => e.outcome === 'parentPromptQueued'))
})

test('heartbeats continue while a native continuation tool is held at a permission boundary', async () => {
  const h = harness({ tasks: [AGENT], histories: { 'agent-1': [{ role: 'user', text: 'history', toolUses: [] }] } })
  await h.boot(); h.arm()
  let release, entered
  const held = new Promise(resolve => { release = resolve })
  const started = new Promise(resolve => { entered = resolve })
  h.setResponse(async () => { entered(); await held; return { result: { success: true } } })
  const recovering = h.recoverTick(); await started
  try {
    h.advance(20000); await h.heartbeat()
    assert.equal(h.report().reportedAt, NOW + 20000)
    assert.equal(h.prompts.length, 0)
  } finally { release(); await recovering }
  assert.equal(h.prompts.length, 1)
})

test('two concurrent native instances of the same session honor one immutable binding and claim once', async () => {
  const files = new Map()
  const first = harness({ files, pid: 12345 }), second = harness({ files, pid: 23456 })
  await Promise.all([first.boot(), second.boot()])
  first.arm()
  await Promise.all([first.tick(), second.tick()])
  assert.equal(first.prompts.length, 1); assert.equal(second.prompts.length, 0)
  assert.equal(first.result().instanceID, first.report().instanceID)
  assert.notEqual(first.report().instanceID, second.report().instanceID)
  await Promise.all([first.tick(), second.tick()])
  assert.equal(first.prompts.length + second.prompts.length, 1)
})

test('blank native follow-on turns and unobserved child starts retain the issued continuation revocation scope', async () => {
  for (const mode of ['child-no-start', 'child-blank', 'main-blank']) {
    const h = harness({ tasks: [AGENT], histories: { 'agent-1': [{ role: 'user', text: 'history', toolUses: [] }] } })
    await h.boot(); h.arm(); await h.tick()
    if (mode === 'child-blank') {
      await h.fire('turn.start', { turnId: 'child-first', agentId: 'agent-1', text: h.calls[0].message })
      await h.fire('turn.complete', { turnId: 'child-first', agentId: 'agent-1', answer: 'continued' })
    }
    if (mode === 'main-blank') {
      await h.fire('turn.start', { turnId: 'main-first', text: h.prompts[0] })
      await h.fire('turn.complete', { turnId: 'main-first', answer: 'continued' })
    }
    await h.fire('prompt.submit', { origin: { kind: 'composer' }, text: 'new work supersedes automatic work' })
    const agentId = mode === 'main-blank' ? undefined : 'agent-1'
    if (mode !== 'child-no-start') await h.fire('turn.start', { turnId: 'native-follow-on', agentId, text: '' })
    let ran = false
    const blocked = await h.fire('tool.call', { tool: 'Bash', agentId, command: 'never execute' }, async () => { ran = true; return { result: 'bad' } })
    assert.equal(ran, false, mode); assert.equal(typeof blocked.deny, 'string')
    await h.fire('turn.start', { turnId: 'manual-follow-on', agentId, text: 'new explicit work' })
    await h.fire('tool.call', { tool: 'Bash', agentId, command: 'manual fixture' }, async () => { ran = true; return { result: 'ok' } })
    assert.equal(ran, true)
  }
})

test('a host clock failure while reporting revoked access cannot make a gating hook fail open', async () => {
  for (const agentId of [undefined, 'agent-1']) {
    const h = harness({ tasks: [AGENT], histories: { 'agent-1': [{ role: 'user', text: 'history', toolUses: [] }] } })
    await h.boot(); h.arm(); await h.tick()
    await h.fire('turn.start', { turnId: 'automatic', agentId, text: agentId ? h.calls[0].message : h.prompts[0] })
    await h.fire('prompt.submit', { origin: { kind: 'composer' }, text: 'new user instruction' })
    h.setClockFailure(true)
    let executed = false
    const blocked = await h.fire('tool.call', { tool: 'Bash', agentId, command: 'never execute' }, async () => { executed = true; return { result: 'bad' } })
    assert.equal(executed, false)
    assert.equal(typeof blocked.deny, 'string')
  }
})

test('a terminal task notice arriving before a registration result cannot re-add a dead Monitor', async () => {
  for (const status of ['completed', 'failed']) {
    const h = harness(); await h.boot()
    await h.fire('tool.call', { tool: 'Monitor', description: 'short fixture', timeout_ms: 1000, command: 'fixture' }, async () => {
      await h.fire('prompt.submit', { origin: { kind: 'task-notification' }, text: `<task-notification><task-id>short-task</task-id><status>${status}</status><summary>ended</summary></task-notification>` })
      return { result: { taskId: 'short-task', timeoutMs: 1000 } }
    })
    await h.heartbeat()
    assert.equal(h.report().busy, false)
    assert.deepEqual(h.report().activeTasks, [])
  }
})

const ORIGINAL_MONITOR = { id: 'old-monitor', toolUseID: 'old-monitor-use', kind: 'monitor', deadlineAt: NOW + 30000 }
const ORIGINAL_WS = { url: 'wss://example.invalid/isolated-fixture', protocols: ['fixture'] }
function monitorHistory(ws = ORIGINAL_WS) { return [{ toolUses: [{ tool: 'Monitor', tool_use_id: 'old-monitor-use', input: { ws, description: 'original watch', timeout_ms: 30000 }, result: { taskId: 'old-monitor', timeoutMs: 30000 } }] }] }

test('a completed restored command cannot be executed a second time by its automatic continuation', async () => {
  const h = harness({ worker: true }); await h.boot()
  const path = `${ROOT}/commands/cmd-completed`
  h.files.set(`${path}/spec.json`, JSON.stringify({ version: 1, jobID: 'cmd-completed', sessionID: SESSION, kind: 'bash', command: 'one-side-effect' }))
  h.files.set(`${path}/state.json`, JSON.stringify({ version: 1, executionProtocol: 3, jobID: 'cmd-completed', sessionID: SESSION, status: 'completed', owner: { pid: 999 }, exitCode: 0 }))
  h.files.set(`${path}/handoff.json`, JSON.stringify({ version: 1, requestID: 'req-1', operationID: 'op-1', targetPID: 12345, targetInstanceID: h.report().instanceID, expiresAt: NOW + 30000 }))
  h.arm({ sourceActiveTasks: [{ id: 'old-shell', kind: 'bash', jobID: 'cmd-completed' }] })
  h.setResponse(() => ({ result: { backgroundTaskId: 'completed-shell' } })); await h.tick()
  assert.equal(h.result().tasks[0].status, 'completed')
  await h.heartbeat()
  assert.deepEqual(h.report().activeTasks, [], 'a finished output attachment must leave the live inventory')
  assert.equal(h.report().busy, false)
  await h.fire('turn.start', { turnId: 'automatic-after-completion', text: h.prompts[0] })
  let ran = false
  const duplicate = await h.fire('tool.call', { tool: 'Bash', command: 'one-side-effect', run_in_background: true }, async () => { ran = true; return { result: { backgroundTaskId: 'duplicate' } } })
  assert.equal(ran, false)
  assert.equal(typeof duplicate.deny, 'string')
})

test('an older execution worker is recorded as blocked; the conversation continues but never replays its command', async () => {
  const h = harness({ worker: true }); await h.boot()
  const path = `${ROOT}/commands/cmd-legacy`
  h.files.set(`${path}/spec.json`, JSON.stringify({ version: 1, jobID: 'cmd-legacy', sessionID: SESSION, kind: 'bash', command: 'must-not-replay' }))
  h.files.set(`${path}/state.json`, JSON.stringify({ version: 1, jobID: 'cmd-legacy', sessionID: SESSION, status: 'running', owner: { pid: 999 } }))
  h.files.set(`${path}/handoff.json`, JSON.stringify({ version: 1, requestID: 'req-1', operationID: 'op-1', targetPID: 12345, targetInstanceID: h.report().instanceID, expiresAt: NOW + 30000 }))
  h.arm({ sourceActiveTasks: [{ id: 'old-shell', kind: 'bash', jobID: 'cmd-legacy' }] }); await h.tick()
  assert.equal(h.result().tasks[0].status, 'blocked')
  assert.match(h.result().tasks[0].error, /older execution worker/)
  assert.equal(h.result().status, 'needsAttention', 'what could not be restored stays visible')
  assert.equal(h.calls.length, 0); assert.equal(h.prompts.length, 1)
  assert.equal(h.prompts[0], CONTINUATION)
  await h.fire('turn.start', { turnId: 'continuation', text: h.prompts[0] }); let replayed = false
  const refused = await h.fire('tool.call', { tool: 'Bash', command: 'must-not-replay', run_in_background: true }, async () => { replayed = true; return { result: {} } })
  assert.equal(replayed, false); assert.equal(typeof refused.deny, 'string')
})

test('an explicit stop arriving while a restored Monitor registers cannot resurrect the original listener', async () => {
  const h = harness(); await h.boot(); h.setMessages(monitorHistory()); h.arm({ sourceActiveTasks: [ORIGINAL_MONITOR] })
  h.setResponse(async event => {
    if (event.tool === 'Monitor') {
      await h.fire('tool.call', { tool: 'TaskStop', task_id: 'old-monitor' }, async () => ({ result: { task_id: 'old-monitor' } }))
      return { result: { taskId: 'late-after-stop', timeoutMs: 30000 } }
    }
    return { result: { task_id: event.task_id } }
  })
  await h.tick()
  assert.ok(h.calls.some(call => call.tool === 'TaskStop' && call.task_id === 'late-after-stop'))
  assert.equal(h.result().tasks[0].status, 'stopped')
  await h.heartbeat(); assert.ok(!h.report().activeTasks.some(task => task.id === 'late-after-stop'))
})

test('an original worker remains stoppable by its old ID while the target native attachment waits', async () => {
  const h = harness({ worker: true }); await h.boot()
  const path = `${ROOT}/commands/cmd-pending`
  h.files.set(`${path}/spec.json`, JSON.stringify({ version: 1, jobID: 'cmd-pending', sessionID: SESSION, kind: 'bash', command: 'one-effect' }))
  h.files.set(`${path}/state.json`, JSON.stringify({ version: 1, executionProtocol: 3, jobID: 'cmd-pending', sessionID: SESSION, status: 'running', owner: { pid: 999 }, worker: { pid: 400 }, child: { pid: 500 } }))
  h.files.set(`${path}/handoff.json`, JSON.stringify({ version: 1, requestID: 'req-1', operationID: 'op-1', targetPID: 12345, targetInstanceID: h.report().instanceID, expiresAt: NOW + 30000 }))
  h.arm({ sourceActiveTasks: [{ id: 'old-shell', kind: 'bash', jobID: 'cmd-pending' }] })
  h.setResponse(async event => {
    if (event.tool === 'Bash') {
      await h.fire('tool.call', { tool: 'TaskStop', task_id: 'old-shell' }, async () => ({ result: { task_id: 'old-shell' } }))
      return { result: { backgroundTaskId: 'late-client' } }
    }
    return { result: { task_id: event.task_id } }
  })
  await h.tick()
  assert.ok(h.helperCalls.some(argv => argv[1] === 'stop' && argv[2] === path))
  assert.ok(h.calls.some(event => event.tool === 'TaskStop' && event.task_id === 'late-client'))
  assert.equal(h.result().tasks[0].status, 'stopped')
})

test('a source TaskStop before registration returns still ends its just-started original worker', async () => {
  const h = harness({ worker: true }); await h.boot()
  await h.fire('tool.call', { tool: 'Bash', command: 'source-command', run_in_background: true }, async () => {
    await h.fire('tool.call', { tool: 'TaskStop', task_id: 'early-source-id' }, async () => ({ result: { task_id: 'early-source-id' } }))
    return { result: { backgroundTaskId: 'early-source-id' } }
  })
  assert.ok(h.helperCalls.some(argv => argv[1] === 'stop'))
  assert.ok(!h.report().activeTasks.some(task => task.id === 'early-source-id'))
})

test('a trusted runtime health refusal revokes new recovery effects and already queued automatic tools', async () => {
  for (const moment of ['before-claim', 'after-queue']) {
    const h = harness(); await h.boot(); h.arm()
    if (moment === 'after-queue') { await h.tick(); await h.fire('turn.start', { turnId: 'automatic-health', text: h.prompts[0] }) }
    const path = `${ROOT}/requests/${SESSION}.json`, request = JSON.parse(h.files.get(path))
    request.runtimeError = 'The target account or process can no longer be verified.'
    h.files.set(path, JSON.stringify(request))
    let ran = false
    if (moment === 'before-claim') { await h.tick(); assert.equal(h.prompts.length, 0) }
    else {
      const result = await h.fire('tool.call', { tool: 'Bash', command: 'must not execute after revocation' }, async () => { ran = true; return { result: 'bad' } })
      assert.equal(ran, false); assert.equal(typeof result.deny, 'string')
    }
  }
})

test('the original WebSocket Monitor is recreated directly before a main prompt, with its remaining deadline and a real new identity', async () => {
  const h = harness(); await h.boot(); h.setMessages(monitorHistory()); h.arm({ sourceActiveTasks: [ORIGINAL_MONITOR] }); h.advance(10000)
  const before = h.report().reportedAt
  h.setPrompt({ drop: 'injected main prompt refusal' })
  h.setResponse(event => { assert.equal(h.prompts.length, 0, 'recovery must run the native monitor before any main prompt'); return { result: { taskId: 'new-monitor', timeoutMs: event.timeout_ms } } })
  await h.tick()
  assert.equal(h.calls.length, 1); assert.equal(h.calls[0].tool, 'Monitor'); assert.deepEqual(h.calls[0].ws, ORIGINAL_WS)
  assert.equal(h.calls[0].timeout_ms, 20000)
  assert.equal(h.result().tasks[0].newTaskID, 'new-monitor'); assert.equal(h.result().tasks[0].eventObserved, false)
  assert.ok(h.result().tasks[0].registeredAt > before)
  assert.ok(h.report().reportedAt > h.result().tasks[0].registeredAt)
  assert.equal(h.report().activeTasks[0].id, 'new-monitor')
  await h.fire('prompt.submit', { origin: { kind: 'task-notification' }, text: '<task-notification><task-id>new-monitor</task-id><status>running</status><event>actual fixture data</event></task-notification>' })
  assert.equal(h.result().tasks[0].eventObserved, true)
  await h.tick(); assert.equal(h.calls.length, 1, 'a dropped parent prompt cannot cause a second registration')
})

test('a compacted monitor resolves its original parameters through the bound worker and keeps its deadline', async () => {
  for (const agentID of [undefined, 'agent-1']) {
    const h = harness({ worker: true, tasks: agentID ? [AGENT] : [], histories: { 'agent-1': [{ role: 'user', text: 'compacted agent summary' }] } })
    await h.boot(); h.setMessages([{ role: 'user', text: 'compacted summary', toolUses: [] }])
    h.arm({ sourceActiveTasks: [{ ...ORIGINAL_MONITOR, agentID }] })
    h.setMonitorResolution(argv => {
      assert.deepEqual(argv.slice(1), ['monitor-input', `${ROOT}/requests/${SESSION}.json`, 'req-1', 'old-monitor'])
      h.advance(10000)
      return { exitCode: 0, stdout: JSON.stringify({ ws: ORIGINAL_WS, description: 'original watch' }) }
    })
    h.setResponse(event => ({ result: event.tool === 'Monitor' ? { taskId: 'restored-monitor' } : { success: true } }))
    await h.tick()
    const monitor = h.calls.find(call => call.tool === 'Monitor')
    assert.deepEqual(monitor.ws, ORIGINAL_WS); assert.equal(monitor.timeout_ms, 20000)
    assert.equal(h.prompts.length, 1)
    assert.ok(!JSON.stringify(h.result()).includes(ORIGINAL_WS.url), 'raw parameters are not persisted in receipts')
  }
})

test('monitor history fallback cannot bypass failed verification, expiry, ambiguity or a new user stop', async () => {
  for (const variant of ['denied', 'malformed', 'expired', 'ambiguous', 'stopped']) {
    const h = harness({ worker: true }); await h.boot()
    h.setMessages(variant === 'ambiguous' ? [...monitorHistory(), ...monitorHistory()] : [])
    h.arm({ sourceActiveTasks: [ORIGINAL_MONITOR] })
    h.setMonitorResolution(async () => {
      if (variant === 'expired') h.advance(31000)
      if (variant === 'stopped') await h.fire('turn.abort', { turnId: 'user-stop' })
      return { exitCode: variant === 'denied' ? 125 : 0, stdout: variant === 'malformed' ? '{partial' : JSON.stringify({ ws: ORIGINAL_WS }) }
    })
    await h.tick()
    assert.equal(h.calls.filter(call => call.tool === 'Monitor').length, 0, variant)
    // Unverified parameters leave the monitor listed for the conversation to check; only the
    // person's own stop withholds the continuation.
    assert.equal(h.prompts.length, variant === 'stopped' ? 0 : 1, variant)
    if (variant !== 'stopped') assert.equal(h.result().tasks[0].status, variant === 'expired' ? 'expired' : 'interrupted', variant)
    if (variant === 'ambiguous') assert.equal(h.helperCalls.length, 0)
  }
})

test('verified monitor aliases use the new native task and automatic turns reuse the already restored listener', async () => {
  const h = harness(); await h.boot(); h.setMessages(monitorHistory()); h.arm({ sourceActiveTasks: [ORIGINAL_MONITOR] })
  h.setResponse(() => ({ result: { taskId: 'new-monitor', timeoutMs: 30000 } })); await h.tick()
  await h.fire('turn.start', { turnId: 'main-restored', text: h.prompts[0] })
  let registrations = 0
  const reused = await h.fire('tool.call', { tool: 'Monitor', ws: ORIGINAL_WS, description: 'same watch', timeout_ms: 30000 }, async () => { registrations++; return { result: { taskId: 'wrong-duplicate' } } })
  assert.equal(registrations, 0); assert.equal(reused.result.taskId, 'new-monitor')
  let lookedUp
  await h.fire('tool.call', { tool: 'GetTask', taskId: 'old-monitor' }, async event => { lookedUp = event.taskId; return { result: { status: 'working' } } })
  assert.equal(lookedUp, 'new-monitor')
})

test('a recovered native client is covered by its task identity when its new tool-use identity differs from the original', async () => {
  const task = { id: 'second-client', kind: 'monitor', toolUseID: 'source-use', aliases: ['first-client'], deadlineAt: NOW + 10000 }
  const h = harness({ tasks: [{ id: 'second-client', kind: 'monitor', toolUseID: 'native-attach-use', state: 'interrupted', sourceLine: 8 }] })
  await h.boot()
  h.setMessages([{ toolUses: [{ tool: 'Monitor', tool_use_id: 'source-use', input: { ws: { url: 'wss://fixture.invalid/events' } }, result: { taskId: 'first-client' } }] }])
  h.setResponse(async event => event.tool === 'Monitor' ? { result: { taskId: 'third-client' } } : { result: { success: true } })
  h.arm({ sourceActiveTasks: [task] }); await h.tick()
  assert.equal(h.calls.filter(c => c.tool === 'Monitor').length, 1)
  assert.equal(h.result().tasks.filter(task => task.status === 'blocked').length, 0)
  assert.equal(h.prompts.length, 1)
})

test('equal WebSocket parameters do not route an original child Agent to another owners restored Monitor', async () => {
  const h = harness({ tasks: [AGENT], histories: { 'agent-1': monitorHistory() } })
  await h.boot(); h.setMessages(monitorHistory())
  h.arm({ sourceActiveTasks: [ORIGINAL_MONITOR, { ...ORIGINAL_MONITOR, id: 'child-old-monitor', agentID: 'agent-1' }] })
  let registered = 0
  h.setResponse(event => event.tool === 'Monitor' ? { result: { taskId: ++registered === 1 ? 'main-listener' : 'child-listener', timeoutMs: 30000 } } : { result: { success: true } })
  await h.tick()
  const resume = h.calls.find(event => event.tool === 'SendMessage')
  await h.fire('turn.start', { turnId: 'automatic-child', agentId: 'agent-1', text: resume.message })
  const reused = await h.fire('tool.call', { tool: 'Monitor', agentId: 'agent-1', ws: ORIGINAL_WS, timeout_ms: 30000 }, async () => { throw new Error('must reuse its own existing listener') })
  assert.equal(reused.result.taskId, 'child-listener')
})

test('stopped, expired, missing and ambiguous original monitor parameters never cause a new registration', async () => {
  for (const variant of ['stopped', 'expired', 'missing', 'ambiguous']) {
    const h = harness(); await h.boot()
    const rows = variant === 'missing' ? [] : variant === 'ambiguous' ? [...monitorHistory(), ...monitorHistory()] : monitorHistory()
    if (variant === 'stopped') rows.push({ toolUses: [{ tool: 'TaskStop', input: { task_id: 'old-monitor' }, result: { task_id: 'old-monitor' } }] })
    h.setMessages(rows); h.arm({ sourceActiveTasks: [{ ...ORIGINAL_MONITOR, ...(variant === 'expired' ? { deadlineAt: NOW - 1 } : {}) }] }); await h.tick()
    assert.equal(h.calls.filter(c => c.tool === 'Monitor').length, 0, variant)
    assert.equal(h.result().tasks[0].status, { stopped: 'stopped', expired: 'expired', missing: 'interrupted', ambiguous: 'interrupted' }[variant])
  }
})

test('a newly registered native monitor is stopped if its authorization changes during the call', async () => {
  const h = harness(); await h.boot(); h.setMessages(monitorHistory()); h.arm({ sourceActiveTasks: [ORIGINAL_MONITOR] })
  h.setResponse(event => {
    if (event.tool === 'Monitor') { h.files.delete(`${ROOT}/active.json`); return { result: { taskId: 'late-monitor', timeoutMs: 30000 } } }
    return { result: { task_id: event.task_id, message: 'stopped', task_type: 'monitor' } }
  })
  await h.tick()
  assert.deepEqual(h.calls.map(c => c.tool), ['Monitor', 'TaskStop']); assert.equal(h.calls[1].task_id, 'late-monitor'); assert.equal(h.prompts.length, 0)
})

test('a permission delay cannot extend the original Monitor deadline or start an already expired watch', async () => {
  for (const wait of [10000, 40000]) {
    const h = harness(); await h.boot(); h.setMessages(monitorHistory()); h.arm({ sourceActiveTasks: [ORIGINAL_MONITOR] })
    h.setResponse(event => {
      if (event.tool === 'Monitor') { h.advance(wait); return { result: { taskId: 'delayed-monitor', timeoutMs: event.timeout_ms } } }
      return { result: { task_id: event.task_id } }
    })
    await h.tick()
    if (wait === 10000) { h.advance(20001); await h.tick() }
    assert.ok(h.calls.some(call => call.tool === 'TaskStop' && call.task_id === 'delayed-monitor'))
    assert.equal(h.result().tasks[0].status, 'expired')
  }
})

test('a background command allowed outright runs in a protected worker and is decided by its original alone', async () => {
  const h = harness({ worker: true }); await h.boot()
  let delivered
  await h.fire('tool.call', { tool: 'Bash', command: 'printf original-side-effect', run_in_background: true, tool_use_id: 'bash-use' }, async event => { delivered = event; return { result: { backgroundTaskId: 'source-shell', stdout: '', stderr: '', interrupted: false } } })
  const [body, comment] = delivered.command.split(' # ')
  assert.match(body, /CompanionNativeWorker.* run /); assert.ok(!body.includes('printf original-side-effect'))
  assert.equal(comment, 'printf original-side-effect', 'the task list still names what runs')
  assert.match(body, /typeset -f; alias -L/, 'the shell hands its functions and aliases to the worker')
  assert.equal(h.checks[0].input.command, 'printf original-side-effect')
  const job = h.report().activeTasks.find(t => t.id === 'source-shell')
  assert.match(job.jobID, /^cmd-/)
  assert.equal(JSON.parse(h.files.get(`${ROOT}/commands/${job.jobID}/spec.json`)).command, 'printf original-side-effect')
  const check = next => h.fire('tool.check', { tool: 'Bash', input: { command: delivered.command } }, next)
  assert.equal((await check(async () => ({ decision: 'ask' }))).decision, 'allow', 'no dialog asks about the wrapper text')
  assert.equal((await check(async () => ({ decision: 'deny', reason: 'policy' }))).decision, 'deny', 'a refusal of the wrapper stands')
  h.setPermission('ask')
  assert.equal((await check(async () => ({ decision: 'allow' }))).decision, 'deny', 'an original that now asks is not started unseen')
  await h.fire('tool.call', { tool: 'TaskStop', task_id: 'source-shell' }, async () => ({ result: { task_id: 'source-shell', message: 'stopped', task_type: 'shell' } }))
  assert.equal(h.helperCalls.at(-1)[1], 'stop')
})

test('a worker installed after the runtime loaded protects the next background command', async () => {
  const h = harness(); await h.boot()
  const run = async command => { let delivered
    await h.fire('tool.call', { tool: 'Bash', command, run_in_background: true }, async event => { delivered = event; return { result: { backgroundTaskId: `shell-${command.length}`, stdout: '', stderr: '', interrupted: false } } })
    return delivered.command }
  assert.equal(await run('before install'), 'before install', 'without a worker the command runs natively')
  h.files.set('/plugin/bin/CompanionNativeWorker', 'fixture-binary')
  assert.match((await run('after the install')).split(' # ')[0], /CompanionNativeWorker.* run /)
})

test('a command that would ask or is refused, and any PreToolUse policy, leave the native command untouched', async () => {
  for (const [permission, settings] of [['ask', {}], ['deny', {}], ['allow', { hooks: { PreToolUse: [{ matcher: 'Edit' }] } }]]) {
    const h = harness({ worker: true, settings }); await h.boot(); h.setPermission(permission)
    let delivered
    await h.fire('tool.call', { tool: 'Bash', command: 'original as typed', run_in_background: true }, async event => { delivered = event; return { result: { backgroundTaskId: 'native-shell', stdout: '', stderr: '', interrupted: false } } })
    assert.equal(delivered.command, 'original as typed', `${permission}: the dialog, classifier and policy see the original`)
    assert.equal(h.helperCalls.length, 0)
    const verdict = await h.fire('tool.check', { tool: 'Bash', input: { command: delivered.command } }, async () => ({ decision: permission }))
    assert.equal(verdict.decision, permission, 'the native verdict about the original stands')
  }
})

test('a surviving Bash job is attached directly and verified by its actual worker state, never by replaying its old command', async () => {
  const h = harness({ worker: true }); await h.boot()
  const job = 'cmd-old', path = `${ROOT}/commands/${job}`
  const task = { id: 'source-shell', toolUseID: 'source-use', kind: 'bash', jobID: job }
  const record = { version: 1, executionProtocol: 3, jobID: job, sessionID: SESSION, status: 'running', owner: { pid: 999 }, worker: { pid: 400 }, child: { pid: 500 } }
  h.files.set(`${path}/spec.json`, JSON.stringify({ version: 1, jobID: job, sessionID: SESSION, kind: 'bash', command: 'original-side-effect' }))
  h.files.set(`${path}/state.json`, JSON.stringify(record))
  h.files.set(`${path}/handoff.json`, JSON.stringify({ version: 1, requestID: 'req-1', operationID: 'op-1', targetPID: 12345, targetInstanceID: h.report().instanceID, expiresAt: NOW + 30000 }))
  h.arm({ sourceActiveTasks: [task] })
  h.setResponse(event => { record.owner.pid = 12345; h.files.set(`${path}/state.json`, JSON.stringify(record)); return { result: { backgroundTaskId: 'target-shell', stdout: '', stderr: '', interrupted: false } } })
  await h.tick()
  assert.equal(h.calls[0].tool, 'Bash'); assert.match(h.calls[0].command, / attach /); assert.ok(!h.calls[0].command.split(' # ')[0].includes('original-side-effect'))
  assert.equal(h.result().tasks[0].executionVerified, true); assert.equal(h.result().tasks[0].childPID, 500)
  await h.heartbeat()
  assert.deepEqual(h.report().activeTasks.find(task => task.id === 'target-shell').aliases, ['source-shell'])
  await h.fire('turn.start', { turnId: 'automatic-next', text: h.prompts[0] }); let rerun = false
  const blocked = await h.fire('tool.call', { tool: 'Bash', command: 'original-side-effect' }, async () => { rerun = true; return { result: {} } })
  assert.equal(rerun, false); assert.equal(typeof blocked.deny, 'string')
  h.setHelperFailure(true)
  const failedStop = await h.fire('tool.call', { tool: 'TaskStop', task_id: 'source-shell' }, async () => ({ result: { task_id: 'target-shell', message: 'stopped', task_type: 'shell' } }))
  assert.equal(failedStop.isError, true, 'stopping an output client alone is not proof that the command stopped')
})

test('a reattached command that fails or is stopped later ends as its own result, not as a failed continuation', async () => {
  for (const end of ['failed', 'stopped']) {
    const h = harness({ worker: true }); await h.boot()
    const job = 'cmd-old', path = `${ROOT}/commands/${job}`
    const record = { version: 1, executionProtocol: 3, jobID: job, sessionID: SESSION, status: 'running', owner: { pid: 999 }, worker: { pid: 400 }, child: { pid: 500 } }
    h.files.set(`${path}/spec.json`, JSON.stringify({ version: 1, jobID: job, sessionID: SESSION, kind: 'bash', command: 'run the tests' }))
    h.files.set(`${path}/state.json`, JSON.stringify(record))
    h.files.set(`${path}/handoff.json`, JSON.stringify({ version: 1, requestID: 'req-1', operationID: 'op-1', targetPID: 12345, targetInstanceID: h.report().instanceID, expiresAt: NOW + 30000 }))
    h.arm({ sourceActiveTasks: [{ id: 'source-shell', toolUseID: 'source-use', kind: 'bash', jobID: job }] })
    h.setResponse(() => { record.owner.pid = 12345; h.files.set(`${path}/state.json`, JSON.stringify(record)); return { result: { backgroundTaskId: 'target-shell', stdout: '', stderr: '', interrupted: false } } })
    await h.tick()
    await h.fire('turn.start', { turnId: 'resume', text: h.prompts[0] })
    await h.fire('turn.complete', { turnId: 'resume', answer: 'it keeps running' })
    h.files.set(`${path}/state.json`, JSON.stringify({ ...record, status: end, exitCode: end === 'failed' ? 1 : undefined }))
    await h.tick()
    assert.equal(h.result().tasks[0].status, end, end)
    assert.equal(h.result().status, 'turnFinished', end)
  }
})

test('a surviving command whose original now asks is stopped, not attached behind a dialog nobody may answer', async () => {
  const h = harness({ worker: true }); await h.boot()
  const job = 'cmd-asks', path = `${ROOT}/commands/${job}`
  h.files.set(`${path}/spec.json`, JSON.stringify({ version: 1, jobID: job, sessionID: SESSION, kind: 'bash', command: 'needs approval now' }))
  h.files.set(`${path}/state.json`, JSON.stringify({ version: 1, executionProtocol: 3, jobID: job, sessionID: SESSION, status: 'running', owner: { pid: 999 }, worker: { pid: 400 }, child: { pid: 500 } }))
  h.files.set(`${path}/handoff.json`, JSON.stringify({ version: 1, requestID: 'req-1', operationID: 'op-1', targetPID: 12345, targetInstanceID: h.report().instanceID, expiresAt: NOW + 30000 }))
  h.arm({ sourceActiveTasks: [{ id: 'source-shell', toolUseID: 'source-use', kind: 'bash', jobID: job }] })
  h.setPermission('ask'); await h.tick()
  assert.ok(!h.calls.some(call => call.tool === 'Bash'), 'no attach waits on a dialog')
  assert.deepEqual(h.helperCalls.filter(call => call[1] === 'stop').map(call => call[2]), [path])
  assert.equal(h.result().tasks[0].status, 'blocked')
  assert.match(h.result().tasks[0].error, /stopped instead of being reattached/)
})

test('a carried live command can reconnect its original unfinished owner after a later user turn without reviving unrelated agents', async () => {
  const h = harness({ worker: true, tasks: [{ ...AGENT, sourceLine: 1 }, { ...AGENT, id: 'unrelated-agent', sourceLine: 1 }],
    histories: { 'agent-1': [{ toolUses: [] }], 'unrelated-agent': [{ toolUses: [] }] } })
  await h.boot()
  const path = `${ROOT}/commands/cmd-old`, record = { version: 1, executionProtocol: 3, jobID: 'cmd-old', sessionID: SESSION, status: 'running', owner: { pid: 999 }, worker: { pid: 400 }, child: { pid: 500 } }
  h.files.set(`${path}/spec.json`, JSON.stringify({ version: 1, jobID: 'cmd-old', sessionID: SESSION, kind: 'bash', command: 'one original effect' }))
  h.files.set(`${path}/state.json`, JSON.stringify(record))
  h.files.set(`${path}/handoff.json`, JSON.stringify({ version: 1, requestID: 'req-1', operationID: 'op-1', targetPID: 12345, targetInstanceID: h.report().instanceID, expiresAt: NOW + 30000 }))
  h.arm({ sourceActiveTasks: [{ id: 'old-shell', kind: 'bash', jobID: 'cmd-old', agentID: 'agent-1' }] })
  h.setResponse(event => {
    if (event.tool === 'Bash') { record.owner.pid = 12345; h.files.set(`${path}/state.json`, JSON.stringify(record)); return { result: { backgroundTaskId: 'new-shell' } } }
    return { result: { success: true } }
  })
  await h.tick()
  assert.deepEqual(h.calls.filter(call => call.tool === 'SendMessage').map(call => call.to), ['agent-1'])
})

test('unprotected work that stopped with the switch is recorded as interrupted, not replayed', async () => {
  const h = harness({ tasks: [{ id: 'foreground-use', toolUseID: 'foreground-use', kind: 'bash', state: 'interrupted', sourceLine: 4 }] })
  await h.boot(); h.arm({ sourceActiveTasks: [{ id: 'approval-shell', toolUseID: 'approval-use', kind: 'bash' }] }); await h.tick()
  assert.equal(h.calls.length, 0, 'nothing is started again by the plugin')
  assert.deepEqual(h.result().tasks.map(task => task.status), ['interrupted', 'interrupted'])
  assert.notEqual(h.result().status, 'needsAttention', 'an unprotected command stopping is expected, not a failure')
  assert.equal(h.prompts.length, 1)
  assert.equal(h.prompts[0], CONTINUATION)
  assert.deepEqual(h.result().tasks.map(task => task.sourceTaskID), ['approval-shell', 'foreground-use'])
})

test('an incomplete history branch restores nothing directly, reports it and still lets the conversation check and continue', async () => {
  const h = harness({ branchComplete: false }); await h.boot()
  h.arm({ sourceActiveTasks: [ORIGINAL_MONITOR] }); await h.tick()
  assert.equal(h.result().tasks[0].status, 'blocked')
  assert.equal(h.result().status, 'needsAttention')
  assert.equal(h.calls.length, 0, 'no monitor is recreated from an unverifiable branch')
  assert.equal(h.prompts.length, 1)
  assert.equal(h.prompts[0], CONTINUATION)
  assert.equal(JSON.parse(h.files.get(`${ROOT}/requests/${SESSION}.json`)).work.branchComplete, false)
})

test('early monitor events and failures are correlated when they precede the registration result', async () => {
  for (const status of ['running', 'failed']) {
    const h = harness(); await h.boot(); h.setMessages(monitorHistory()); h.arm({ sourceActiveTasks: [ORIGINAL_MONITOR] })
    h.setResponse(async () => {
      await h.fire('prompt.submit', { origin: { kind: 'task-notification' }, text: `<task-notification><task-id>early-monitor</task-id><status>${status}</status><event>fixture</event></task-notification>` })
      return { result: { taskId: 'early-monitor', timeoutMs: 30000 } }
    })
    await h.tick()
    assert.equal(h.result().tasks[0].status, status === 'running' ? 'listening' : 'failed')
    assert.equal(h.result().tasks[0].eventObserved, status === 'running')
    if (status === 'failed') { assert.equal(h.result().status, 'needsAttention'); assert.ok(!h.report().activeTasks.some(t => t.id === 'early-monitor')) }
  }
})

test('an original child agent receives its early and later monitor data in order after accepting its native continuation', async () => {
  const h = harness({ tasks: [AGENT], histories: { 'agent-1': monitorHistory() } })
  await h.boot(); h.arm({ sourceActiveTasks: [{ ...ORIGINAL_MONITOR, agentID: 'agent-1' }] })
  const notice = value => ({ origin: { kind: 'task-notification' }, text: `<task-notification><task-id>child-monitor</task-id><status>running</status><event>${value}</event></task-notification>` })
  h.setResponse(async event => {
    if (event.tool === 'Monitor') {
      await h.fire('prompt.submit', notice('early-data'))
      return { result: { taskId: 'child-monitor', timeoutMs: 30000 } }
    }
    return { result: { success: true } }
  })
  await h.tick()
  assert.deepEqual(h.calls.map(call => call.tool), ['Monitor', 'SendMessage', 'SendMessage'])
  assert.match(h.calls[1].message, /本次账号切换打断/)
  assert.match(h.calls[2].message, /early-data/)
  await h.fire('turn.start', { turnId: 'main-running', text: h.prompts[0] })
  // Exercise the tool observer too: an event forward has a one-use internal reservation,
  // while the main model cannot resend that same native Agent continuation.
  h.setResponse(event => h.fire('tool.call', event, async () => ({ result: { success: true } })))
  await h.fire('prompt.submit', notice('later-data'))
  assert.match(h.calls[3].message, /later-data/)
  assert.equal(h.result().evidence.filter(e => e.outcome === 'monitorEventForwarded').length, 2)
  const duplicate = await h.fire('tool.call', h.calls[3], async () => { throw new Error('duplicate must not execute') })
  assert.equal(typeof duplicate.deny, 'string')
  await h.fire('tool.call', { tool: 'TaskStop', task_id: 'agent-1' }, async () => ({ result: { task_id: 'agent-1' } }))
  const count = h.calls.length
  await h.fire('prompt.submit', notice('must-not-forward-after-stop'))
  assert.equal(h.calls.length, count)
  assert.ok(h.calls.some(call => call.tool === 'TaskStop' && call.task_id === 'child-monitor'))
})

test('monitor data never bypasses a denied original Agent continuation or a superseding user instruction', async () => {
  for (const variant of ['denied', 'superseded']) {
    const h = harness({ tasks: [AGENT], histories: { 'agent-1': monitorHistory() } })
    await h.boot(); h.arm({ sourceActiveTasks: [{ ...ORIGINAL_MONITOR, agentID: 'agent-1' }] })
    h.setResponse(event => event.tool === 'Monitor' ? { result: { taskId: 'child-monitor', timeoutMs: 30000 } }
      : variant === 'denied' ? { deny: 'original permission refused' } : { result: { success: true } })
    await h.tick()
    if (variant === 'superseded') await h.fire('prompt.submit', { origin: { kind: 'composer' }, text: 'a new instruction' })
    const count = h.calls.length
    await h.fire('prompt.submit', { origin: { kind: 'task-notification' }, text: '<task-notification><task-id>child-monitor</task-id><status>running</status><event>not authorized to revive agent</event></task-notification>' })
    assert.equal(h.calls.length, count, variant)
  }
})

test('stopping an original parent Agent reaches only its own command bodies and native clients', async () => {
  const h = harness({ worker: true }); await h.boot()
  for (const [id, agentId] of [['owned-shell', 'agent-1'], ['other-shell', 'agent-other']]) {
    await h.fire('tool.call', { tool: 'Bash', command: 'fixture', run_in_background: true, agentId },
      async () => ({ result: { backgroundTaskId: id } }))
  }
  const ownedJob = h.report().activeTasks.find(task => task.id === 'owned-shell').jobID
  h.setResponse(event => ({ result: { task_id: event.task_id } }))
  const stopped = await h.fire('tool.call', { tool: 'TaskStop', task_id: 'agent-1' }, async () => ({ result: { task_id: 'agent-1' } }))
  assert.equal(stopped.isError, undefined)
  assert.deepEqual(h.calls, [{ tool: 'TaskStop', task_id: 'owned-shell' }])
  assert.deepEqual(h.helperCalls.filter(call => call[1] === 'stop').map(call => call[2]), [`${ROOT}/commands/${ownedJob}`])
  assert.deepEqual(h.report().activeTasks.map(task => task.id), ['other-shell'])
})

test('a parent stop still stops the real command if its native output client refuses to stop', async () => {
  const h = harness({ worker: true }); await h.boot()
  await h.fire('tool.call', { tool: 'Monitor', command: 'fixture', timeout_ms: 10000, agentId: 'agent-1' },
    async () => ({ result: { taskId: 'owned-monitor' } }))
  h.setResponse(() => ({ deny: 'injected output client failure' }))
  const result = await h.fire('tool.call', { tool: 'TaskStop', task_id: 'agent-1' }, async () => ({ result: { task_id: 'agent-1' } }))
  assert.equal(result.isError, true)
  assert.equal(h.helperCalls.filter(call => call[1] === 'stop').length, 1)
})

test('oversized early child Monitor data produces an explicit attention result instead of silently losing it', async () => {
  const h = harness({ tasks: [AGENT], histories: { 'agent-1': monitorHistory() } })
  await h.boot(); h.arm({ sourceActiveTasks: [{ ...ORIGINAL_MONITOR, agentID: 'agent-1' }] })
  h.setResponse(async event => {
    if (event.tool === 'Monitor') {
      await h.fire('prompt.submit', { origin: { kind: 'task-notification' }, text: `<task-notification><task-id>child-monitor</task-id><status>running</status><event>${'x'.repeat(262144)}</event></task-notification>` })
      return { result: { taskId: 'child-monitor', timeoutMs: 30000 } }
    }
    return { result: { success: true } }
  })
  await h.tick()
  assert.equal(h.result().status, 'needsAttention')
  assert.equal(h.result().tasks[0].status, 'blocked')
  assert.equal(h.calls.filter(call => call.summary === '传递原监听的新事件').length, 0)
})

test('a permission change immediately before wrapper execution is rechecked against the original command', async () => {
  const h = harness({ worker: true }); await h.boot(); let command
  await h.fire('tool.call', { tool: 'Bash', command: 'original policy checked command', run_in_background: true }, async event => { command = event.command; return { result: { backgroundTaskId: 'fixture-shell', stdout: '', stderr: '', interrupted: false } } })
  h.setPermission('deny')
  const decision = await h.fire('tool.check', { tool: 'Bash', input: { command } }, async () => ({ decision: 'allow' }))
  assert.equal(decision.decision, 'deny')
})


test('oversized task receipts stay readable and explicitly report omitted execution details', () => {
  const tasks = Array.from({ length: 20000 }, (_, i) => ({ sourceTaskID: `source-${i}`, jobID: `job-${i}`, status: 'blocked', error: 'x'.repeat(240) }))
  const encoded = encodeResult({ version: 1, status: 'executing', tasks, evidence: [] })
  const value = JSON.parse(encoded.text)
  assert.equal(encoded.truncated, true)
  assert.ok(Buffer.byteLength(encoded.text) < 4194304)
  assert.equal(value.status, 'needsAttention')
  assert.equal(value.omittedNativeTaskResults, 20000 - 64)
})


test('the host task list supplements tracked work without recording commands, descriptions or prompts', async () => {
  const h = harness({ worker: true }); await h.boot()
  assert.equal(h.report().hostWorkInventory, undefined)
  await h.fire('tool.call', { tool: 'Bash', command: 'fixture tracked command', run_in_background: true, tool_use_id: 'tracked-use' },
    async () => ({ result: { backgroundTaskId: 'tracked-shell' } }))
  const tracked = h.report().activeTasks
  assert.equal(typeof tracked[0].jobID, 'string')
  let forwarded = 0
  const event = { session_id: SESSION,
    background_tasks: [{ id: 'external-shell', type: 'shell', status: 'running', command: 'private-command', description: 'private-description' },
      { id: 'future-task', type: 'future native feature', status: 'waiting' }],
    session_crons: [{ id: 'wake-1', recurring: true, prompt: 'private-prompt', schedule: '* * * * *' }] }
  assert.deepEqual(await h.fire('classic.Stop', event, async e => { forwarded++; assert.equal(e, event); return { done: true } }), { done: true })
  assert.equal(forwarded, 1)
  assert.deepEqual(h.report().hostWorkInventory, { backgroundTasks: [
    { id: 'external-shell', type: 'shell', status: 'running' }, { id: 'future-task', type: 'future native feature', status: 'waiting' }] })
  assert.deepEqual(h.report().activeTasks, tracked)
  assert.doesNotMatch(JSON.stringify(h.report()), /private-command|private-description|private-prompt|wake-1|\* \* \* \* \*/)
  await h.fire('classic.Stop', { session_id: SESSION, background_tasks: [] })
  assert.deepEqual(h.report().hostWorkInventory.backgroundTasks, [])
  assert.deepEqual(h.report().activeTasks, tracked, 'an empty host list does not discard tracked command evidence')
})

test('only a shell the host lists makes the conversation busy', async () => {
  const h = harness(); await h.boot()
  // Work that needs the model, a comment watch, or a task of any other kind carries nothing a
  // spent account could go on with.
  for (const type of ['artifact-comment-monitor', 'monitor', 'subagent', 'future-artifact-monitor']) {
    await h.fire('classic.Stop', { session_id: SESSION, background_tasks: [{ id: 'task', type, status: 'running' }] })
    assert.equal(h.report().busy, false, type)
  }
  await h.fire('classic.Stop', { session_id: SESSION, background_tasks: [{ id: 'task', type: 'shell', status: 'running' }] })
  assert.equal(h.report().busy, true)
})

test('SubagentStop lists the parent conversation and never clears user stop intent', async () => {
  const h = harness(); await h.boot()
  const event = { session_id: SESSION, agent_id: 'child-agent', background_tasks: [{ id: 'shell-1', type: 'shell', status: 'running' }] }
  await h.fire('classic.SubagentStop', { ...event, session_id: 'foreign' })
  assert.equal(h.report().hostWorkInventory, undefined)
  await h.fire('turn.abort', { turnId: 'user-stopped-turn' })
  await h.fire('classic.SubagentStop', event)
  assert.equal(h.report().userStopped, true)
  assert.deepEqual(h.report().hostWorkInventory.backgroundTasks, [{ id: 'shell-1', type: 'shell', status: 'running' }])
  assert.equal(h.prompts.length, 0)
  assert.equal(h.calls.length, 0)
})

test('a missing list changes nothing, and malformed, repeated, ended or surplus entries are left out', async () => {
  const h = harness(); await h.boot()
  const kept = [{ id: 'kept', type: 'shell', status: 'running' }]
  await h.fire('classic.Stop', { session_id: SESSION, background_tasks: kept })
  for (const event of [{}, { background_tasks: null }]) {
    await h.fire('classic.Stop', { session_id: SESSION, ...event })
    assert.deepEqual(h.report().hostWorkInventory.backgroundTasks, kept)
  }
  await h.fire('classic.Stop', { session_id: SESSION, background_tasks: [null, { id: 'no-type', status: 'running' },
    { id: 'x'.repeat(257), type: 'shell', status: 'running' }, { id: 'ended', type: 'shell', status: 'completed' },
    { id: 'twice', type: 'shell', status: 'running' }, { id: 'twice', type: 'shell', status: 'waiting' }] })
  assert.deepEqual(h.report().hostWorkInventory.backgroundTasks, [{ id: 'twice', type: 'shell', status: 'running' }])
  await h.fire('classic.Stop', { session_id: SESSION,
    background_tasks: Array.from({ length: 129 }, (_, i) => ({ id: `shell-${i}`, type: 'shell', status: 'running' })) })
  assert.equal(h.report().hostWorkInventory.backgroundTasks.length, 128)
})

test('a task reported finished or stopped leaves the list, and a later list does not bring it back', async () => {
  const h = harness(); await h.boot()
  await h.fire('classic.Stop', { session_id: SESSION, background_tasks: [
    { id: 'ended-shell', type: 'shell', status: 'running' }, { id: 'still-running', type: 'monitor', status: 'running' }] })
  await h.fire('prompt.submit', { origin: { kind: 'task-notification' }, text: '<task-notification><task-id>ended-shell</task-id><status>completed</status></task-notification>' })
  // The next report, at the latest the next heartbeat, leaves it out.
  await h.heartbeat()
  assert.deepEqual(h.report().hostWorkInventory.backgroundTasks.map(task => task.id), ['still-running'])
  await h.fire('classic.Stop', { session_id: SESSION, background_tasks: [{ id: 'ended-shell', type: 'shell', status: 'running' }] })
  assert.deepEqual(h.report().hostWorkInventory.backgroundTasks, [])
  await h.fire('classic.Stop', { session_id: SESSION, background_tasks: [{ id: 'still-running', type: 'monitor', status: 'running' }] })
  await h.fire('tool.call', { tool: 'TaskStop', task_id: 'still-running' }, async () => ({ result: { task_id: 'still-running' } }))
  await h.heartbeat()
  assert.deepEqual(h.report().hostWorkInventory.backgroundTasks, [])
})
