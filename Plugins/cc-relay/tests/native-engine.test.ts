import { describe, expect, mock, test } from 'claude-code/testing'

const home = '/tmp/native-recovery-engine'
const root = `${home}/Library/Application Support/CC-Relay/NativeRecovery`
const instant = Date.parse('2026-10-27T03:00:00Z')
const sessionID = 'native-engine-session'

for (const mode of ['reopen', 'switch']) for (const replies of [false, true]) for (const outcome of ['success', 'timeout']) test(`the hooks engine waits for ${mode} ${replies ? 'reply' : 'pure-watch'} handshake ${outcome}`, async ($, on) => {
  const clock = mock.clock(on, { now: instant })
  mock.env(on, { HOME: home, CLAUDE_CODE_ENTRYPOINT: 'claude-desktop' })
  const artifactURL = 'https://claude.ai/code/artifact/original-artifact'
  const artifacts = [{ url: artifactURL, state: 'armed', replies }]
  const files = new Map<string, string>([[`${home}/.claude/sessions/12345.json`, JSON.stringify({
    pid: 12345, sessionId: sessionID, procStart: 'process-birth', pidDomain: 'darwin', entrypoint: 'claude-desktop',
  })]])
  const calls: any[] = [], watches: any[] = []
  if (!replies) watches.push({ url: artifactURL, connected: true, connecting: true, auto_reply: 'none', task_id: 'artifact-watch' })
  let prompts = 0, notices = 0
  on('session.start', (_$, event) => ({ cwd: event.cwd }))
  on('session.id', () => ({ value: sessionID }))
  on('session.usage', () => ({ value: { context: { tokens: 1000, window: 1000000 }, rateLimits: [] } }))
  on('store.get', () => ({ value: undefined }))
  on('store.set', () => ({ value: undefined }))
  on('settings.read', () => ({ value: {} }))
  on('ui.toast', () => { notices++; return { value: undefined } })
  on('process.run', (_$, event) => ({ value: { exitCode: 0, stderr: '', stdout: event.argv[1] === 'artifact-input'
    ? JSON.stringify({ version: 1, sessionID, branchComplete: true, artifacts }) : '12345' } }))
  on('fs.read', (_$, event) => { const value = files.get(event.path); if (value === undefined) throw new Error('missing'); return { value } })
  on('fs.exists', (_$, event) => ({ value: files.has(event.path) || event.path.endsWith('/bin/CompanionNativeWorker') }))
  on('fs.write', (_$, event) => { files.set(event.path, event.text); return { value: undefined } })
  on('agent.list', () => ({ value: [] }))
  on('session.messages', () => ({ value: [] }))
  on('tool.list', () => ({ value: [{ name: 'ArtifactComments', description: 'native comment watch', mcp: false }] }))
  on('tool.check', () => ({ decision: 'allow' }))
  on('tool.call', (_$, event) => {
    calls.push(event)
    if (!event.url) return { result: { watches: watches.map(watch => ({ ...watch })) } }
    if (event.replies) {
      return { result: { resume_replies: { url: artifactURL, resumed: false, outcome: 'skipped', reason: 'not_stopped' } } }
    }
    // Flow-only fixture; installed-host tests execute the actual permission, wiring and
    // handshake policies which produce this connected:true + connecting:true inventory.
    watches.push({ url: artifactURL, connected: true, connecting: true, auto_reply: 'armed', task_id: 'artifact-watch' })
    return { result: { watch: { url: artifactURL, watching: true, auto_reply: 'armed', task_id: 'artifact-watch' } } }
  })
  on('prompt.submit', (_$, event) => { prompts++; return { text: event.text } })
  await $.session.start({ cwd: '/tmp', surface: null, isInteractive: false })
  if (mode === 'switch') {
    const runtime = JSON.parse(files.get([...files.keys()].find(path => path.includes('/runtimes/'))!)!)
    files.set(`${root}/active.json`, JSON.stringify({ version: 1, ready: true, operationID: 'artifact-op', targetProfile: '/target', targetAccountID: 'target-account' }))
    files.set(`${root}/requests/${sessionID}.json`, JSON.stringify({
      version: 1, requiredCapability: 'native-recovery-v6', operationID: 'artifact-op', requestID: 'artifact-request', sessionID,
      phase: 'armed', targetProfile: '/target', targetAccountID: 'target-account', expiresAt: instant + 600000,
      armedAt: instant, sourceWasBusy: false, instanceID: runtime.instanceID, pid: runtime.pid, procStart: runtime.procStart,
      work: { version: 1, cliSessionID: sessionID, branchComplete: true, needsContinuation: false, tasks: [], artifacts },
    }))
  }
  await clock.advance(12500); await clock.settle()
  expect(calls.filter(call => call.url && call.on === true).length).toBe(replies ? 1 : 0)
  expect(calls.filter(call => call.replies === true).length).toBe(0)
  expect(prompts).toBe(0)
  const path = mode === 'switch' ? `${root}/results/artifact-request.json` : [...files.keys()].find(path => path.includes('/artifacts/'))!
  const receipt = () => JSON.parse(files.get(path)!)
  const restored = () => receipt().evidence.some((item: any) => ['watchConnected', 'repliesRestored'].includes(item.outcome))
  expect(receipt().status).toBe('waiting'); expect(restored()).toBe(false)
  expect(notices).toBe(0)
  if (mode === 'reopen') expect(receipt().artifacts[0].repliesReady).toBe(false)
  if (outcome === 'success') {
    watches[0].connecting = false
    await clock.advance(15000); await clock.settle()
    expect(receipt().status).toBe(mode === 'switch' ? 'inspected' : 'restored')
    expect(restored()).toBe(true); expect(receipt().error).toBeUndefined()
    expect(notices).toBe(0)
  } else {
    await clock.advance(60000); await clock.settle()
    expect(receipt().status).toBe('needsAttention'); expect(restored()).toBe(false)
    expect(receipt().error).toContain('after six checks')
    expect(notices).toBe(mode === 'reopen' ? 1 : 0)
  }
  const completedCalls = calls.length, completedNotices = notices
  await clock.advance(60000); await clock.settle()
  expect(calls.length).toBe(completedCalls); expect(notices).toBe(completedNotices)
  expect(calls.filter(call => call.url).length).toBe(replies ? 1 : 0)
  expect(prompts).toBe(0); expect(watches.length).toBe(1)
  expect(watches[0].auto_reply).toBe(replies ? 'armed' : 'none')
})

describe('native continuation alongside the quota compactor', () => {
  test('claims once, resumes the original agent, queues the original conversation and observes actual tools', async ($, on) => {
    const clock = mock.clock(on, { now: instant })
    mock.env(on, { HOME: home, CLAUDE_CODE_ENTRYPOINT: 'claude-desktop' })
    const files = new Map<string, string>([[`${home}/.claude/sessions/12345.json`, JSON.stringify({
      pid: 12345, sessionId: sessionID, procStart: 'process-birth', pidDomain: 'darwin', entrypoint: 'claude-desktop',
    })]])
    const calls: any[] = [], prompts: string[] = []
    on('session.start', ($, event) => ({ cwd: event.cwd }))
    on('session.id', () => ({ value: sessionID }))
    on('session.usage', () => ({ value: { context: { tokens: 1000, window: 1000000 }, rateLimits: [] } }))
    on('store.get', () => ({ value: undefined }))
    on('store.set', () => ({ value: undefined }))
    on('process.run', () => ({ value: { exitCode: 0, stdout: '12345', stderr: '' } }))
    on('fs.read', ($, event) => { const value = files.get(event.path); if (value === undefined) throw new Error('missing'); return { value } })
    on('fs.exists', ($, event) => ({ value: files.has(event.path) }))
    on('fs.write', ($, event) => { files.set(event.path, event.text); return { value: undefined } })
    on('tool.list', () => ({ value: [{ name: 'SendMessage', description: 'native send', mcp: false }] }))
    // The new runtime may have no live roster row, while its same-session native history exists.
    on('agent.list', () => ({ value: [] }))
    on('session.messages', ($, event) => ({ value: event.agentId ? [{ role: 'user', text: 'original agent task', toolUses: [] }] : [] }))
    on('tool.check', () => ({ decision: 'allow' }))
    on('tool.call', ($, event) => { calls.push(event); return { result: event.tool === 'Monitor' ? { taskId: 'monitor-1', timeoutMs: 5000 } : { success: true } } })
    on('prompt.submit', ($, event) => { prompts.push(event.text); return { text: event.text } })
    on('turn.start', ($, event) => ({ turnId: event.turnId }))
    on('turn.complete', () => ({ text: 'continued' }))
    await $.session.start({ cwd: '/tmp', surface: null, isInteractive: false })
    const path = [...files.keys()].find(key => key.includes('/runtimes/'))!
    const runtime = JSON.parse(files.get(path)!)
    files.set(`${root}/active.json`, JSON.stringify({ version: 1, ready: true, operationID: 'op-1', targetProfile: '/target', targetAccountID: 'target-account' }))
    files.set(`${root}/requests/${sessionID}.json`, JSON.stringify({
      version: 1, requiredCapability: 'native-recovery-v6', operationID: 'op-1', requestID: 'request-1', sessionID,
      phase: 'armed', targetProfile: '/target', targetAccountID: 'target-account',
      expiresAt: instant + 600000, armedAt: instant, sourceWasBusy: true,
      instanceID: runtime.instanceID, pid: runtime.pid, procStart: runtime.procStart,
      work: { version: 1, cliSessionID: sessionID, branchComplete: true, needsContinuation: true,
        transcriptPath: '/source/original.jsonl', tasks: [{ id: 'agent-1', toolUseID: 'call-1', kind: 'agent',
          state: 'backgroundRegistered', agentType: 'general-purpose', sourceLine: 3 }], artifacts: [], warnings: [] },
    }))
    await clock.advance(2500); await clock.settle()
    expect(calls.filter(event => event.tool === 'SendMessage').length).toBe(1)
    expect(calls[0].to).toBe('agent-1')
    expect(prompts.length).toBe(1)
    expect(JSON.parse(files.get(`${root}/results/request-1.json`)!).status).toBe('queued')
    await clock.advance(5000); await clock.settle()
    expect(prompts.length).toBe(1)
    // The turn carries the prompt under the frame the host gives a plugin's message.
    await $.turn.start({ turnId: 'resume-turn', text: `The cc-relay plugin sent a message:\n${prompts[0]}` })
    expect(JSON.parse(files.get(`${root}/results/request-1.json`)!).status).toBe('queued')
    await $.tool.call({ tool: 'Monitor', description: 'original watch', timeout_ms: 5000, command: 'read-only fixture' })
    expect(JSON.parse(files.get(`${root}/results/request-1.json`)!).status).toBe('executing')
    await $.turn.complete({ turnId: 'resume-turn', answer: 'continued' })
    expect(JSON.parse(files.get(`${root}/results/request-1.json`)!).status).toBe('turnFinished')
    expect([...files.keys()].some(key => key.includes('/AutoCompact/sessions/'))).toBe(true)
  })

  test('an old runtime ticket has no effect and an accepted-runtime prompt drop is not retried', async ($, on) => {
    const clock = mock.clock(on, { now: instant })
    mock.env(on, { HOME: home, CLAUDE_CODE_ENTRYPOINT: 'claude-desktop' })
    const files = new Map<string, string>([[`${home}/.claude/sessions/12345.json`, JSON.stringify({
      pid: 12345, sessionId: sessionID, procStart: 'process-birth', pidDomain: 'darwin', entrypoint: 'claude-desktop',
    })]])
    let prompts = 0, toolCalls = 0
    on('session.start', ($, event) => ({ cwd: event.cwd }))
    on('session.id', () => ({ value: sessionID }))
    on('session.usage', () => ({ value: { context: { tokens: 1000, window: 1000000 }, rateLimits: [] } }))
    on('store.get', () => ({ value: undefined }))
    on('store.set', () => ({ value: undefined }))
    on('process.run', () => ({ value: { exitCode: 0, stdout: '12345', stderr: '' } }))
    on('fs.read', ($, event) => { const value = files.get(event.path); if (value === undefined) throw new Error('missing'); return { value } })
    on('fs.exists', ($, event) => ({ value: files.has(event.path) }))
    on('fs.write', ($, event) => { files.set(event.path, event.text); return { value: undefined } })
    on('tool.list', () => ({ value: [] }))
    on('agent.list', () => ({ value: [] }))
    on('session.messages', () => ({ value: [] }))
    on('tool.call', () => { toolCalls += 1; return { result: 'must not run' } })
    on('prompt.submit', () => { prompts += 1; return { drop: 'stopped by user' } })
    await $.session.start({ cwd: '/tmp', surface: null, isInteractive: false })
    const path = [...files.keys()].find(key => key.includes('/runtimes/'))!
    const runtime = JSON.parse(files.get(path)!)
    files.set(`${root}/active.json`, JSON.stringify({ version: 1, ready: true, operationID: 'op-1', targetProfile: '/target', targetAccountID: 'target-account' }))
    const request = { version: 1, requiredCapability: 'native-recovery-v6', operationID: 'op-1', requestID: 'request-1', sessionID, phase: 'armed',
      targetProfile: '/target', targetAccountID: 'target-account', expiresAt: instant + 600000, armedAt: instant,
      sourceWasBusy: true, instanceID: 'old-runtime', pid: runtime.pid, procStart: runtime.procStart,
      work: { version: 1, cliSessionID: sessionID, branchComplete: true, needsContinuation: true, tasks: [], artifacts: [] },
    }
    files.set(`${root}/requests/${sessionID}.json`, JSON.stringify(request))
    await clock.advance(2500); await clock.settle(); expect(prompts).toBe(0)
    request.instanceID = runtime.instanceID
    files.set(`${root}/requests/${sessionID}.json`, JSON.stringify(request))
    await clock.advance(2500); await clock.settle()
    expect(prompts).toBe(1); expect(toolCalls).toBe(0)
    expect(JSON.parse(files.get(`${root}/results/request-1.json`)!).status).toBe('needsAttention')
    await clock.advance(5000); await clock.settle(); expect(prompts).toBe(1)
  })
  test('a failed host cancellation cannot release stale tools, while a later user turn still works', async ($, on) => {
    const clock = mock.clock(on, { now: instant })
    mock.env(on, { HOME: home, CLAUDE_CODE_ENTRYPOINT: 'claude-desktop' })
    const files = new Map<string, string>([[`${home}/.claude/sessions/12345.json`, JSON.stringify({
      pid: 12345, sessionId: sessionID, procStart: 'process-birth', pidDomain: 'darwin', entrypoint: 'claude-desktop',
    })]])
    const prompts: string[] = [], calls: any[] = []
    on('session.start', ($, event) => ({ cwd: event.cwd }))
    on('session.id', () => ({ value: sessionID }))
    on('session.usage', () => ({ value: { context: { tokens: 1000, window: 1000000 }, rateLimits: [] } }))
    on('store.get', () => ({ value: undefined }))
    on('store.set', () => ({ value: undefined }))
    on('process.run', () => ({ value: { exitCode: 0, stdout: '12345', stderr: '' } }))
    on('fs.read', ($, event) => { const value = files.get(event.path); if (value === undefined) throw new Error('missing'); return { value } })
    on('fs.exists', ($, event) => ({ value: files.has(event.path) }))
    on('fs.write', ($, event) => { files.set(event.path, event.text); return { value: undefined } })
    on('tool.list', () => ({ value: [{ name: 'Bash', description: 'fixture', mcp: false }] }))
    on('agent.list', () => ({ value: [] }))
    on('session.messages', () => ({ value: [] }))
    on('tool.check', () => ({ decision: 'allow' }))
    on('tool.call', ($, event) => { calls.push(event); return { result: 'fixture executed' } })
    on('prompt.submit', ($, event) => { prompts.push(event.text); return { text: event.text } })
    on('turn.start', ($, event) => ({ turnId: event.turnId }))
    on('turn.complete', () => ({ text: 'ended' }))
    on('turn.abort', () => { throw new Error('injected cancellation failure') })
    await $.session.start({ cwd: '/tmp', surface: null, isInteractive: false })
    const runtime = JSON.parse(files.get([...files.keys()].find(key => key.includes('/runtimes/'))!)!)
    files.set(`${root}/active.json`, JSON.stringify({ version: 1, ready: true, operationID: 'op-1', targetProfile: '/target', targetAccountID: 'target-account' }))
    files.set(`${root}/requests/${sessionID}.json`, JSON.stringify({
      version: 1, requiredCapability: 'native-recovery-v6', operationID: 'op-1', requestID: 'request-1', sessionID, phase: 'armed',
      targetProfile: '/target', targetAccountID: 'target-account', expiresAt: instant + 600000, armedAt: instant,
      sourceWasBusy: true, instanceID: runtime.instanceID, pid: runtime.pid, procStart: runtime.procStart,
      work: { version: 1, cliSessionID: sessionID, branchComplete: true, needsContinuation: true, tasks: [], artifacts: [] },
    }))
    await clock.advance(2500); await clock.settle()
    expect(prompts.length).toBe(1)
    files.set(`${root}/active.json`, JSON.stringify({ version: 1, ready: true, operationID: 'new-operation' }))
    await $.turn.start({ turnId: 'revoked-turn', text: prompts[0] })
    const blocked = await $.tool.call({ tool: 'Bash', command: 'never executed' })
    expect(typeof blocked.deny).toBe('string')
    expect(calls.length).toBe(0)
    expect(JSON.parse(files.get(`${root}/results/request-1.json`)!).status).toBe('needsAttention')
    await $.turn.complete({ turnId: 'revoked-turn', answer: 'ended' })
    await $.turn.start({ turnId: 'new-user-turn', text: 'A new authorized task' })
    await $.tool.call({ tool: 'Bash', command: 'isolated host fixture' })
    expect(calls.length).toBe(1)
  })
})

// These calls go through the real hooks engine; all host tools and storage are isolated mocks.
async function nativeFixture(engine: any, on: any, childFirst = false, sendDelay = 0, options: any = {}) {
  const clock = mock.clock(on, { now: instant })
  mock.env(on, { HOME: home, CLAUDE_CODE_ENTRYPOINT: 'claude-desktop' })
  const files = new Map<string, string>([[`${home}/.claude/sessions/12345.json`, JSON.stringify({
    pid: 12345, sessionId: sessionID, procStart: 'process-birth', pidDomain: 'darwin', entrypoint: 'claude-desktop',
  })]])
  const calls: any[] = [], prompts: string[] = []
  on('session.start', (_$: any, event: any) => ({ cwd: event.cwd }))
  on('session.measure', (_$: any, event: any) => ({ changed: event.changed }))
  on('session.id', () => ({ value: sessionID }))
  on('session.usage', () => ({ value: { context: { tokens: 1000, window: 1000000 }, rateLimits: options.rateLimits ?? [] } }))
  on('store.get', () => ({ value: undefined }))
  on('store.set', () => ({ value: undefined }))
  on('process.run', (_$: any, event: any) => ({ value: { exitCode: 0,
    stdout: event.argv[1] === 'prepare' ? JSON.stringify({ directory: event.argv[2] })
      : event.argv[1] === 'inspect' ? files.get(`${event.argv[2]}/state.json`) ?? '' : '12345', stderr: '' } }))
  on('fs.read', (_$: any, event: any) => { const value = files.get(event.path); if (value === undefined) throw new Error('missing'); return { value } })
  on('fs.exists', (_$: any, event: any) => ({ value: files.has(event.path) || (options.worker === true && event.path.endsWith('/bin/CompanionNativeWorker')) }))
  on('settings.read', () => ({ value: {} }))
  on('fs.write', (_$: any, event: any) => { files.set(event.path, event.text); return { value: undefined } })
  on('tool.list', () => ({ value: ['SendMessage', 'Monitor', 'Bash'].map(name => ({ name, description: 'fixture native tool', mcp: false })) }))
  on('agent.list', () => ({ value: [] }))
  on('session.messages', (_$: any, event: any) => ({ value: event.agentId ? options.agentHistory ?? [{ role: 'user', text: 'original agent task', toolUses: [] }] : options.history ?? [] }))
  on('tool.check', () => ({ decision: 'allow' }))
  on('tool.call', async (_$: any, event: any) => {
    calls.push(event)
    if (event.tool === 'SendMessage' && sendDelay) await clock.sleep(sendDelay)
    if (event.tool === 'SendMessage' && childFirst) {
      await engine.turn.start({ turnId: 'early-child', agentId: 'agent-1', text: event.message })
      await engine.tool.call({ tool: 'Bash', agentId: 'agent-1', command: 'isolated fixture' })
    }
    if (event.tool === 'TaskStop') return { result: { message: 'Stopped', task_id: event.task_id, task_type: 'agent' } }
    if (event.tool === 'Monitor') return { result: { taskId: 'old-ws', timeoutMs: 600000, persistent: false } }
    if (event.tool === 'Bash') return { result: { stdout: 'continued', stderr: '', interrupted: false, ...(event.run_in_background ? { backgroundTaskId: 'worker-client' } : {}) } }
    return { result: { success: true } }
  })
  on('prompt.submit', (_$: any, event: any) => { prompts.push(event.text); return { text: event.text } })
  on('turn.start', (_$: any, event: any) => ({ turnId: event.turnId }))
  on('turn.complete', () => ({ text: 'ended' }))
  on('turn.abort', () => { throw new Error('injected host cancellation failure') })
  await engine.session.start({ cwd: '/tmp', surface: null, isInteractive: false })
  const reportPath = [...files.keys()].find(key => key.includes('/runtimes/'))!
  const runtime = JSON.parse(files.get(reportPath)!)
  function arm() {
    files.set(`${root}/active.json`, JSON.stringify({ version: 1, ready: true, operationID: 'op-1', targetProfile: '/target', targetAccountID: 'target-account' }))
    files.set(`${root}/requests/${sessionID}.json`, JSON.stringify({
      version: 1, requiredCapability: 'native-recovery-v6', operationID: 'op-1', requestID: 'request-1', sessionID, phase: 'armed',
      targetProfile: '/target', targetAccountID: 'target-account', expiresAt: instant + 600000, armedAt: instant,
      sourceWasBusy: true, instanceID: runtime.instanceID, pid: runtime.pid, procStart: runtime.procStart,
      work: { version: 1, cliSessionID: sessionID, branchComplete: true, needsContinuation: true, tasks: [
        { id: 'agent-1', toolUseID: 'use-1', kind: 'agent', state: 'backgroundRegistered', agentType: 'general-purpose', sourceLine: 3 },
      ], artifacts: [] },
    }))
  }
  return { clock, files, calls, prompts, arm, report: () => JSON.parse(files.get(reportPath)!),
    result: () => JSON.parse(files.get(`${root}/results/request-1.json`)!) }
}

for (const revokedBy of ['TaskStop', 'user instruction', 'generation']) {
  test(`a late original child cannot execute after ${revokedBy}, while a later manual child can`, async ($, on) => {
    const f = await nativeFixture($, on)
    f.arm(); await f.clock.advance(2500); await f.clock.settle()
    const message = f.calls.find(event => event.tool === 'SendMessage').message
    if (revokedBy === 'TaskStop') await $.tool.call({ tool: 'TaskStop', task_id: 'agent-1' })
    if (revokedBy === 'user instruction') await $.prompt.submit({ text: 'new authorized work', origin: { kind: 'composer' } })
    if (revokedBy === 'generation') {
      f.files.delete(`${root}/active.json`)
      await f.clock.advance(2500); await f.clock.settle()
    }
    await $.turn.start({ turnId: 'late-child', agentId: 'agent-1', text: message })
    const blocked = await $.tool.call({ tool: 'Bash', agentId: 'agent-1', command: 'must never execute' })
    expect(typeof blocked.deny).toBe('string')
    expect(f.calls.filter(event => event.tool === 'Bash').length).toBe(0)
    await $.turn.start({ turnId: 'manual-child', agentId: 'agent-1', text: 'new manual task' })
    await $.tool.call({ tool: 'Bash', agentId: 'agent-1', command: 'isolated manual fixture' })
    expect(f.calls.filter(event => event.tool === 'Bash').length).toBe(1)
  })
}

test('the real host preserves child execution when the main continuation queues afterward', async ($, on) => {
  const f = await nativeFixture($, on, true)
  f.arm(); await f.clock.advance(2500); await f.clock.settle()
  expect(f.prompts.length).toBe(1)
  expect(f.result().status).toBe('executing')
  expect(f.result().evidence.some((event: any) => event.outcome === 'parentPromptQueued')).toBe(true)
})

test('the real hooks host reports exhaustion immediately and removes it after reset', async ($, on) => {
  const limits = [{ kind: 'five_hour', percentUsed: 99, resetsAt: new Date(instant + 3600000).toISOString() }]
  const f = await nativeFixture($, on, false, 0, { rateLimits: limits })
  expect(f.report().quotaBlock).toBeUndefined()
  limits[0].percentUsed = 100
  await $.session.measure({ context: { tokens: 1000, window: 1000000 }, rateLimits: limits, changed: ['rateLimits'] })
  expect(f.report().quotaBlock.reason).toBe('quota')
  expect(f.report().quotaBlock.until).toBe(instant + 3600000)
  limits[0].resetsAt = new Date(instant).toISOString()
  await f.clock.advance(5000); await f.clock.settle()
  expect(f.report().quotaBlock).toBeUndefined()
})

test('a WebSocket Monitor remains in the real host report after a later user question ends', async ($, on) => {
  const f = await nativeFixture($, on)
  await $.turn.start({ turnId: 'original', text: 'observe work' })
  await $.tool.call({ tool: 'Monitor', description: 'original watch', timeout_ms: 600000, ws: { url: 'wss://example.invalid/fixture' } })
  await $.turn.complete({ turnId: 'original', answer: 'watching' })
  await $.prompt.submit({ text: 'another question', origin: { kind: 'composer' } })
  await $.turn.start({ turnId: 'later', text: 'another question' })
  await $.turn.complete({ turnId: 'later', answer: 'answered' })
  await f.clock.advance(2500); await f.clock.settle()
  expect(f.report().busy).toBe(true)
  expect(f.report().activeTasks.some((task: any) => task.id === 'old-ws' && task.kind === 'monitor')).toBe(true)
  await $.tool.call({ tool: 'TaskStop', task_id: 'old-ws' })
  await f.clock.advance(2500); await f.clock.settle()
  expect(f.report().activeTasks.length).toBe(0)
})

test('blank native follow-on and missing child start events cannot bypass revocation in the real host', async ($, on) => {
  const f = await nativeFixture($, on)
  f.arm(); await f.clock.advance(2500); await f.clock.settle()
  await $.prompt.submit({ text: 'superseding user instruction', origin: { kind: 'composer' } })
  const withoutStart = await $.tool.call({ tool: 'Bash', agentId: 'agent-1', command: 'must never execute' })
  expect(typeof withoutStart.deny).toBe('string')
  await $.turn.start({ turnId: 'blank-child-follow-on', agentId: 'agent-1', text: '' })
  const blankStart = await $.tool.call({ tool: 'Bash', agentId: 'agent-1', command: 'must never execute' })
  expect(typeof blankStart.deny).toBe('string')
  expect(f.calls.filter(event => event.tool === 'Bash').length).toBe(0)
})


test('real host heartbeat timers remain independent while a continuation tool waits', async ($, on) => {
  const f = await nativeFixture($, on, false, 60000)
  f.arm(); await f.clock.advance(2500); await f.clock.settle()
  expect(f.result().status).toBe('claimed')
  await f.clock.advance(20000); await f.clock.settle()
  expect(f.report().reportedAt).toBeGreaterThanOrEqual(f.clock.now() - 5000)
  expect(f.prompts.length).toBe(0)
  await f.clock.advance(45000); await f.clock.settle()
  expect(f.prompts.length).toBe(1)
})


test('the real hooks host directly restores the original WebSocket monitor before its main continuation', async ($, on) => {
  const ws = { url: 'wss://example.invalid/fixture' }
  const history = [{ role: 'assistant', text: '', toolUses: [{ tool: 'Monitor', tool_use_id: 'original-watch', input: { ws, description: 'original watch', timeout_ms: 30000 }, result: { taskId: 'old-watch', timeoutMs: 30000 } }] }]
  const f = await nativeFixture($, on, false, 0, { history })
  f.arm()
  const file = `${root}/requests/${sessionID}.json`, request = JSON.parse(f.files.get(file)!)
  request.sourceActiveTasks = [{ id: 'old-watch', toolUseID: 'original-watch', kind: 'monitor', deadlineAt: instant + 30000 }]
  f.files.set(file, JSON.stringify(request))
  await f.clock.advance(2500); await f.clock.settle()
  const watch = f.calls.find(event => event.tool === 'Monitor')
  expect(watch.ws).toEqual(ws)
  expect(watch.timeout_ms).toBe(28000)
  expect(f.result().tasks[0].newTaskID).toBe('old-ws')
  expect(f.result().tasks[0].eventObserved).toBe(false)
})

test('the real hooks host wraps a new background command through the ordinary Bash tool and retains its worker identity', async ($, on) => {
  const f = await nativeFixture($, on, false, 0, { worker: true })
  await $.tool.call({ tool: 'Bash', command: 'printf isolated-business-fixture', run_in_background: true })
  const executed = f.calls.find(event => event.tool === 'Bash')
  const [body, comment] = executed.command.split(' # ')
  expect(body).toContain('CompanionNativeWorker')
  expect(body).toContain(' run ')
  expect(body.includes('printf isolated-business-fixture')).toBe(false)
  expect(comment).toBe('printf isolated-business-fixture')
  const task = f.report().activeTasks.find((item: any) => item.id === 'worker-client')
  expect(task.jobID.startsWith('cmd-')).toBe(true)
  expect(JSON.parse(f.files.get(`${root}/commands/${task.jobID}/spec.json`)!).command).toBe('printf isolated-business-fixture')
})

test('the real hooks host attaches a surviving command directly without wrapping that attachment in a second worker', async ($, on) => {
  const f = await nativeFixture($, on, false, 0, { worker: true }); f.arm()
  const requestPath = `${root}/requests/${sessionID}.json`, request = JSON.parse(f.files.get(requestPath)!)
  request.sourceActiveTasks = [{ id: 'source-client', kind: 'bash', jobID: 'cmd-original' }]; request.work.tasks = []
  f.files.set(requestPath, JSON.stringify(request))
  const directory = `${root}/commands/cmd-original`
  f.files.set(`${directory}/spec.json`, JSON.stringify({ version: 1, jobID: 'cmd-original', sessionID, kind: 'bash', command: 'one-original-side-effect' }))
  f.files.set(`${directory}/state.json`, JSON.stringify({ version: 1, executionProtocol: 3, jobID: 'cmd-original', sessionID, status: 'running', owner: { pid: 12345 }, worker: { pid: 400 }, child: { pid: 500 } }))
  f.files.set(`${directory}/handoff.json`, JSON.stringify({ version: 1, requestID: 'request-1', operationID: 'op-1', targetPID: 12345, targetInstanceID: f.report().instanceID, expiresAt: instant + 30000 }))
  await f.clock.advance(2500); await f.clock.settle()
  const attached = f.calls.find(event => event.tool === 'Bash')
  expect(attached.command).toContain(' attach ')
  expect(attached.command.includes(' run ')).toBe(false)
  await f.clock.advance(2500); await f.clock.settle()
  expect(f.report().activeTasks.find((task: any) => task.id === 'worker-client').jobID).toBe('cmd-original')
  expect([...f.files.keys()].filter(path => path.endsWith('/spec.json')).length).toBe(1)
})

test('the real hooks host refuses to run an already completed recovered command again', async ($, on) => {
  const f = await nativeFixture($, on, false, 0, { worker: true }); f.arm()
  const requestPath = `${root}/requests/${sessionID}.json`, request = JSON.parse(f.files.get(requestPath)!)
  request.sourceActiveTasks = [{ id: 'source-client', kind: 'bash', jobID: 'cmd-completed' }]; request.work.tasks = []
  f.files.set(requestPath, JSON.stringify(request))
  const directory = `${root}/commands/cmd-completed`
  f.files.set(`${directory}/spec.json`, JSON.stringify({ version: 1, jobID: 'cmd-completed', sessionID, kind: 'bash', command: 'one-business-effect' }))
  f.files.set(`${directory}/state.json`, JSON.stringify({ version: 1, executionProtocol: 3, jobID: 'cmd-completed', sessionID, status: 'completed', owner: { pid: 999 }, exitCode: 0 }))
  f.files.set(`${directory}/handoff.json`, JSON.stringify({ version: 1, requestID: 'request-1', operationID: 'op-1', targetPID: 12345, targetInstanceID: f.report().instanceID, expiresAt: instant + 30000 }))
  await f.clock.advance(2500); await f.clock.settle()
  expect(f.result().tasks[0].status).toBe('completed')
  await $.turn.start({ turnId: 'after-original-completion', text: f.prompts[0] })
  const result = await $.tool.call({ tool: 'Bash', command: 'one-business-effect', run_in_background: true })
  expect(typeof result.deny).toBe('string')
  expect(f.calls.filter(event => event.tool === 'Bash').length).toBe(1)
})

test('a native runtime health refusal blocks an already queued main continuation in the real host', async ($, on) => {
  const f = await nativeFixture($, on); f.arm()
  await f.clock.advance(2500); await f.clock.settle()
  await $.turn.start({ turnId: 'queued-main', text: f.prompts[0] })
  const file = `${root}/requests/${sessionID}.json`, request = JSON.parse(f.files.get(file)!)
  request.runtimeError = 'Bound account identity no longer verified.'
  f.files.set(file, JSON.stringify(request))
  const result = await $.tool.call({ tool: 'Bash', command: 'must not run after the refusal' })
  expect(typeof result.deny).toBe('string')
  expect(f.calls.filter(event => event.tool === 'Bash').length).toBe(0)
})

test('the real hooks host sends restored child Monitor events back to the original Agent and stops its new native client', async ($, on) => {
  const ws = { url: 'wss://example.invalid/child-fixture' }
  const agentHistory = [{ role: 'assistant', text: '', toolUses: [{ tool: 'Monitor', tool_use_id: 'child-watch', input: { ws, description: 'original child watch', timeout_ms: 30000 }, result: { taskId: 'source-child-watch', timeoutMs: 30000 } }] }]
  const f = await nativeFixture($, on, false, 0, { agentHistory })
  f.arm()
  const file = `${root}/requests/${sessionID}.json`, request = JSON.parse(f.files.get(file)!)
  request.sourceActiveTasks = [{ id: 'source-child-watch', toolUseID: 'child-watch', agentID: 'agent-1', kind: 'monitor', deadlineAt: instant + 30000 }]
  f.files.set(file, JSON.stringify(request))
  await f.clock.advance(2500); await f.clock.settle()
  expect(f.calls.filter(event => event.tool === 'SendMessage').length).toBe(1)
  await $.turn.start({ turnId: 'bound-main', text: f.prompts[0] })
  await $.prompt.submit({ origin: { kind: 'task-notification' }, text: '<task-notification><task-id>old-ws</task-id><status>running</status><event>actual fixture event</event></task-notification>' })
  const forwarded = f.calls.find(event => event.summary === '传递原监听的新事件')
  expect(forwarded.to).toBe('agent-1')
  expect(forwarded.message).toContain('actual fixture event')
  expect(f.result().evidence.some((item: any) => item.outcome === 'monitorEventForwarded')).toBe(true)
  await $.tool.call({ tool: 'TaskStop', task_id: 'agent-1' })
  expect(f.calls.some(event => event.tool === 'TaskStop' && event.task_id === 'old-ws')).toBe(true)
})
