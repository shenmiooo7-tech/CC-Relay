import { describe, expect, mock, test } from 'claude-code/testing'

const instant = Date.parse('2026-10-25T12:00:00Z')
const home = '/tmp/cc-relay-plugin-test'
const folder = `${home}/Library/Application Support/CC-Relay/AutoCompact`

describe('low-quota compaction in the hooks engine', () => {
  test('compacts a long Desktop conversation after the reply that crosses the early line', async ($, on) => {
    const clock = mock.clock(on, { now: instant })
    mock.env(on, { HOME: home, CLAUDE_CODE_ENTRYPOINT: 'claude-desktop' })
    const files = new Map<string, string>([[`${folder}/settings.json`, JSON.stringify({ enabled: true, language: 'en' })]])
    const store = new Map<string, unknown>()
    const commands: { command: string, args: string }[] = []
    let compactions = 0
    let tokens = 300000

    // What the engine itself would answer beneath the plugin.
    on('session.start', ($, event) => ({ cwd: event.cwd }))
    on('turn.start', ($, event) => ({ turnId: event.turnId }))
    on('turn.complete', () => ({ text: 'done' }))
    on('session.id', () => ({ value: 'test-session' }))
    on('fs.read', ($, event) => {
      const text = files.get(event.path)
      if (text === undefined) throw new Error('missing')
      return { value: text }
    })
    on('fs.write', ($, event) => {
      files.set(event.path, event.text)
      return { value: undefined }
    })
    on('store.get', ($, event) => ({ value: store.get(event.key) }))
    on('store.set', ($, event) => {
      store.set(event.key, event.value)
      return { value: undefined }
    })
    on('session.usage', () => ({ value: {
      context: { tokens, window: 1000000 },
      rateLimits: [{ kind: 'five_hour', percentUsed: 88, resetsAt: new Date(instant + 3600000).toISOString() }],
    } }))
    // The engine's /compact. A test's hooks may make no calls of their own (host rule: only calls
    // the source scan found), so it shrinks the conversation itself instead of raising session.compact.
    on('command.run', ($, event) => {
      commands.push({ command: event.command, args: event.args })
      compactions += 1
      tokens = 70000
      return { text: 'Compacted' }
    })

    await $.session.start({ surface: null, isInteractive: false, cwd: '/tmp' })
    await $.turn.start({ turnId: 'turn-1' })
    await $.turn.complete({ turnId: 'turn-1', answer: 'done' })
    await clock.advance(1000)
    await clock.settle()
    expect(commands).toEqual([{ command: 'compact', args: '' }])
    expect(compactions).toBe(1)
    const results = [...files.keys()].filter(path => path.startsWith(`${folder}/results/`))
    expect(results.length).toBe(1)
    expect(JSON.parse(files.get(results[0]) ?? '{}').status).toBe('compacted')
  })

  for (const dropped of [false, true]) test(dropped
    ? 'a host-dropped continuation stays paused after hard-line compaction'
    : 'pauses a long task between two steps at the hard line, compacts through /compact, and resumes', async ($, on) => {
    const clock = mock.clock(on, { now: instant })
    mock.env(on, { HOME: home, CLAUDE_CODE_ENTRYPOINT: 'claude-desktop' })
    const files = new Map<string, string>([[`${folder}/settings.json`, JSON.stringify({ enabled: true, language: 'en' })]])
    const store = new Map<string, unknown>()
    const aborted: string[] = []
    const submitted: string[] = []
    const commands: { command: string, args: string }[] = []
    let compactions = 0
    let tokens = 300000
    let used = 80

    on('session.start', ($, event) => ({ cwd: event.cwd }))
    on('turn.start', ($, event) => ({ turnId: event.turnId }))
    on('turn.abort', ($, event) => {
      aborted.push(event.turnId)
      return { value: undefined }
    })
    on('tool.call', () => ({ result: 'ran' }))
    on('prompt.submit', ($, event) => {
      submitted.push(event.text)
      return dropped ? { drop: 'fixture continuation refused' } : { text: event.text }
    })
    on('session.id', () => ({ value: 'test-session' }))
    on('fs.read', ($, event) => {
      const text = files.get(event.path)
      if (text === undefined) throw new Error('missing')
      return { value: text }
    })
    on('fs.write', ($, event) => {
      files.set(event.path, event.text)
      return { value: undefined }
    })
    on('store.get', ($, event) => ({ value: store.get(event.key) }))
    on('store.set', ($, event) => {
      store.set(event.key, event.value)
      return { value: undefined }
    })
    on('session.usage', () => ({ value: {
      context: { tokens, window: 1000000 },
      rateLimits: [{ kind: 'five_hour', percentUsed: used, resetsAt: new Date(instant + 3600000).toISOString() }],
    } }))
    // The engine's /compact. A test's hooks may make no calls of their own (host rule: only calls
    // the source scan found), so it shrinks the conversation itself instead of raising session.compact.
    on('command.run', ($, event) => {
      commands.push({ command: event.command, args: event.args })
      compactions += 1
      tokens = 70000
      return { text: 'Compacted' }
    })

    await $.session.start({ surface: null, isInteractive: false, cwd: '/tmp' })
    await $.turn.start({ turnId: 'long-turn' })
    expect(await $.tool.call({ tool: 'Bash', args: { command: 'make' } })).toEqual({ result: 'ran' })
    used = 95
    await $.tool.call({ tool: 'Bash', args: { command: 'make test' } })
    expect(aborted).toEqual(['long-turn'])
    await clock.advance(2000)
    await clock.settle()
    expect(commands).toEqual([{ command: 'compact', args: '' }])
    expect(compactions).toBe(1)
    expect(submitted.length).toBe(1)
    expect(submitted[0].startsWith('[Continuation pauseID=')).toBe(true)
    expect(submitted[0].split('\n').slice(1).join('\n')).toBe('Please continue the unfinished work from where it was interrupted, following the original instructions and scope of authorization.')
    const resultPath = [...files.keys()].find(path => path.startsWith(`${folder}/results/`))!
    const result = JSON.parse(files.get(resultPath)!)
    expect(result.resumed).toBe(!dropped)
    if (dropped) expect(result.error).toBe('the task could not be resumed: fixture continuation refused')
  })

  test('a person\'s prompt over a task paused at the hard line takes over: that pause neither compacts nor resumes', async ($, on) => {
    const clock = mock.clock(on, { now: instant })
    mock.env(on, { HOME: home, CLAUDE_CODE_ENTRYPOINT: 'claude-desktop' })
    const files = new Map<string, string>([[`${folder}/settings.json`, JSON.stringify({ enabled: true, language: 'en' })]])
    const store = new Map<string, unknown>()
    const aborted: string[] = []
    const submitted: string[] = []
    const commands: string[] = []
    let used = 80

    on('session.start', ($, event) => ({ cwd: event.cwd }))
    on('turn.start', ($, event) => ({ turnId: event.turnId }))
    on('turn.abort', ($, event) => {
      aborted.push(event.turnId)
      return { value: undefined }
    })
    on('tool.call', () => ({ result: 'ran' }))
    on('prompt.submit', ($, event) => {
      submitted.push(event.text)
      return { text: event.text }
    })
    on('session.id', () => ({ value: 'test-session' }))
    on('fs.read', ($, event) => {
      const text = files.get(event.path)
      if (text === undefined) throw new Error('missing')
      return { value: text }
    })
    on('fs.write', ($, event) => {
      files.set(event.path, event.text)
      return { value: undefined }
    })
    on('store.get', ($, event) => ({ value: store.get(event.key) }))
    on('store.set', ($, event) => {
      store.set(event.key, event.value)
      return { value: undefined }
    })
    on('session.usage', () => ({ value: {
      context: { tokens: 300000, window: 1000000 },
      rateLimits: [{ kind: 'five_hour', percentUsed: used, resetsAt: new Date(instant + 3600000).toISOString() }],
    } }))
    on('command.run', ($, event) => {
      commands.push(event.command)
      return { text: 'Compacted' }
    })

    await $.session.start({ surface: null, isInteractive: false, cwd: '/tmp' })
    await $.turn.start({ turnId: 'long-turn' })
    expect(await $.tool.call({ tool: 'Bash', args: { command: 'make' } })).toEqual({ result: 'ran' })
    used = 95
    await $.tool.call({ tool: 'Bash', args: { command: 'make test' } })
    expect(aborted).toEqual(['long-turn'])
    // Through both of the plugin's prompt hooks, nested as Claude Code nests them.
    await $.prompt.submit({ text: 'Do something else', origin: { kind: 'composer' } })
    await clock.advance(2000)
    await clock.settle()
    expect(commands).toEqual([])
    expect(submitted).toEqual(['Do something else'])
  })

  test('passes a compaction it did not ask for through unchanged', async ($, on) => {
    mock.clock(on, { now: instant })
    mock.env(on, { HOME: home, CLAUDE_CODE_ENTRYPOINT: 'claude-desktop' })
    on('session.start', ($, event) => ({ cwd: event.cwd }))
    on('session.id', () => ({ value: 'test-session' }))
    on('fs.read', () => { throw new Error('missing') })
    on('fs.write', () => ({ value: undefined }))
    on('store.get', () => ({ value: undefined }))
    on('session.usage', () => ({ value: { context: { tokens: 300000, window: 1000000 }, rateLimits: [] } }))
    on('session.compact', () => ({ messages: [{ role: 'user', text: 'summary', toolUses: [] }], tokensAfter: 1200 }))

    await $.session.start({ surface: null, isInteractive: false, cwd: '/tmp' })
    const result = await $.session.compact({ instructions: 'keep the plan' })
    expect('messages' in result ? result.messages.length : 0).toBe(1)
    expect('messages' in result ? result.tokensAfter : undefined).toBe(1200)
  })

  test('a test request lets the normal flow compact the named conversation after its next reply', async ($, on) => {
    const clock = mock.clock(on, { now: instant })
    mock.env(on, { HOME: home, CLAUDE_CODE_ENTRYPOINT: 'claude-desktop' })
    const files = new Map<string, string>([
      [`${folder}/settings.json`, JSON.stringify({ enabled: true, language: 'en' })],
      [`${folder}/test-request.json`, JSON.stringify({ id: 1, sessionID: 'test-session', until: instant + 600000 })],
    ])
    const store = new Map<string, unknown>()
    const commands: string[] = []
    let tokens = 300000

    on('session.start', ($, event) => ({ cwd: event.cwd }))
    on('turn.start', ($, event) => ({ turnId: event.turnId }))
    on('turn.complete', () => ({ text: 'done' }))
    on('session.id', () => ({ value: 'test-session' }))
    on('fs.read', ($, event) => {
      const text = files.get(event.path)
      if (text === undefined) throw new Error('missing')
      return { value: text }
    })
    on('fs.write', ($, event) => {
      files.set(event.path, event.text)
      return { value: undefined }
    })
    on('store.get', ($, event) => ({ value: store.get(event.key) }))
    on('store.set', ($, event) => {
      store.set(event.key, event.value)
      return { value: undefined }
    })
    on('session.usage', () => ({ value: {
      context: { tokens, window: 1000000 },
      rateLimits: [{ kind: 'five_hour', percentUsed: 30, resetsAt: new Date(instant + 3600000).toISOString() }],
    } }))
    on('command.run', ($, event) => {
      commands.push(event.command)
      tokens = 70000
      return { text: 'Compacted' }
    })

    await $.session.start({ surface: null, isInteractive: false, cwd: '/tmp' })
    await $.turn.start({ turnId: 'turn-1' })
    await $.turn.complete({ turnId: 'turn-1', answer: 'done' })
    await clock.advance(1000)
    await clock.settle()
    expect(commands).toEqual(['compact'])
    const results = [...files.keys()].filter(path => path.startsWith(`${folder}/results/`))
    expect(results.length).toBe(1)
    const result = JSON.parse(files.get(results[0]) ?? '{}')
    expect(result.reason).toBe('early')
    expect(result.test).toBe(1)
    expect(result.status).toBe('compacted')
  })
})
