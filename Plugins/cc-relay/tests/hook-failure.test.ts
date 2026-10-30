import { expect, mock, test } from 'claude-code/testing'

const home = '/tmp/cc-relay-caught-hook-host'
const root = `${home}/Library/Application Support/CC-Relay`
const sessionID = 'caught-hook-session'
const instant = Date.parse('2026-10-30T00:00:00Z')

// The real engine may skip a failing lower test hook instead of throwing in this plugin's own
// frame. This test proves downstream failure does not replay an operation and later manual work
// still succeeds; it does not claim to inject a failure into CC-Relay's handler. Node dispatcher
// tests separately exercise that handler's failure paths. All host operations here are mocks.
for (const event of ['prompt.submit', 'turn.start', 'tool.call'] as const) test(`a downstream ${event} failure is not replayed and later manual work proceeds`, async ($, on) => {
  const clock = mock.clock(on, { now: instant })
  mock.env(on, { HOME: home, CLAUDE_CODE_ENTRYPOINT: 'claude-desktop' })
  mock.store(on)
  const files = new Map<string, string>([[`${home}/.claude/sessions/12345.json`, JSON.stringify({
    pid: 12345, sessionId: sessionID, procStart: 'fixture-birth', pidDomain: 'darwin', entrypoint: 'claude-desktop',
  })]])
  let attempts = 0, completed = 0, refusing = true
  on('session.start', (_$, input) => ({ cwd: input.cwd }))
  on('session.id', () => ({ value: sessionID }))
  on('session.usage', () => ({ value: { context: { tokens: 1000, window: 1000000 }, rateLimits: [] } }))
  on('settings.read', () => ({ value: {} }))
  on('ui.toast', () => ({ value: undefined }))
  on('agent.list', () => ({ value: [] }))
  on('session.messages', () => ({ value: [] }))
  on('tool.list', () => ({ value: [] }))
  on('process.run', (_$, input) => ({ value: { exitCode: 0, stderr: '', stdout: input.argv[1] === 'artifact-input'
    ? JSON.stringify({ version: 1, sessionID, branchComplete: true, artifacts: [] }) : '12345' } }))
  on('fs.read', (_$, input) => {
    const value = files.get(input.path)
    return { value: value ?? 'null' }
  })
  on('fs.exists', (_$, input) => ({ value: files.has(input.path) }))
  on('fs.write', (_$, input) => { files.set(input.path, input.text); return { value: undefined } })
  on('prompt.submit', (_$, input) => {
    if (event === 'prompt.submit') { attempts++; if (refusing) throw new Error('private prompt data is not a diagnostic'); completed++ }
    return { text: input.text }
  })
  on('turn.start', (_$, input) => {
    if (event === 'turn.start') { attempts++; if (refusing) throw new Error('fixture lower turn handler failed'); completed++ }
    return { turnId: input.turnId }
  })
  on('tool.call', () => {
    if (event === 'tool.call') { attempts++; if (refusing) throw new Error('private command data is not a diagnostic'); completed++ }
    return { result: 'fixture operation completed' }
  })
  await $.session.start({ cwd: home, surface: null, isInteractive: false })
  try {
    if (event === 'prompt.submit') await $.prompt.submit({ text: 'fixture manual prompt' })
    if (event === 'turn.start') await $.turn.start({ turnId: 'fixture-manual', text: 'fixture manual prompt' })
    if (event === 'tool.call') await $.tool.call({ tool: 'Read', file_path: '/fixture-only' })
  } catch { /* The fixture has no engine implementation below the deliberately failing handler. */ }
  expect(attempts).toBe(1)
  expect(completed).toBe(0)
  await clock.advance(30000); await clock.settle()
  const nativePath = [...files.keys()].find(path => path.includes('/NativeRecovery/runtimes/'))!
  const native = JSON.parse(files.get(nativePath)!)
  const compact = JSON.parse(files.get(`${root}/AutoCompact/sessions/${sessionID}.json`)!)
  expect(JSON.stringify(native).includes('private')).toBe(false)
  expect(JSON.stringify(compact).includes('private')).toBe(false)
  refusing = false
  if (event === 'prompt.submit') expect((await $.prompt.submit({ text: 'a later manual prompt' })).text).toBe('a later manual prompt')
  if (event === 'turn.start') expect((await $.turn.start({ turnId: 'later-manual', text: 'a later manual prompt' })).turnId).toBe('later-manual')
  if (event === 'tool.call') expect((await $.tool.call({ tool: 'Read', file_path: '/fixture-only' })).result).toBe('fixture operation completed')
  expect(attempts).toBe(2)
  expect(completed).toBe(1)
})
