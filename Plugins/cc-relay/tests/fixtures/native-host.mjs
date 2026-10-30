// Isolated native API host for process integration. All commands come from the fixture parent;
// no account, installed configuration or user's conversation is opened.
import { register } from '../../hooks/native-continuity.js'
import fs from 'node:fs'
import path from 'node:path'
import { spawn, execFileSync, execFile } from 'node:child_process'
import { promisify } from 'node:util'
const execute = promisify(execFile)
const config = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'))
const root = path.join(config.home, 'Library/Application Support/CC-Relay/NativeRecovery')
const session = 'session-fixture', handlers = [], timers = [], clients = new Map(), calls = []
let sequence = 0, prompts = 0
fs.mkdirSync(path.join(config.home, '.claude/sessions'), { recursive: true, mode: 0o700 })
const procStart = execFileSync('/bin/ps', ['-p', String(process.pid), '-o', 'lstart='], { encoding: 'utf8', env: { ...process.env, TZ: 'UTC' } }).trim()
fs.writeFileSync(path.join(config.home, `.claude/sessions/${process.pid}.json`), JSON.stringify({ pid: process.pid, sessionId: session, procStart, pidDomain: 'darwin', entrypoint: 'claude-desktop' }))
register((name, matcher, handler) => {
  if (typeof matcher === 'function') [handler, matcher] = [matcher, undefined]
  const item = { name, matcher, handler }; handlers.push(item); return { catch(fn) { item.caught = fn } }
})
async function nativeTool(event) {
  calls.push(event)
  if (event.tool === 'Bash') {
    const id = `shell-${process.pid}-${++sequence}`
    const child = spawn('/bin/bash', ['-c', event.command], { cwd: config.home, env: process.env, stdio: 'ignore' })
    clients.set(id, child)
    return { result: { backgroundTaskId: id, backgroundOutputPath: `${root}/${id}.output`, stdout: '', stderr: '', interrupted: false } }
  }
  if (event.tool === 'Monitor' && event.ws) {
    const id = `monitor-${process.pid}-${++sequence}`, socket = new WebSocket(event.ws.url, event.ws.protocols)
    clients.set(id, socket)
    socket.addEventListener('message', async event => {
      await fire('prompt.submit', { origin: { kind: 'task-notification' }, text: `<task-notification><task-id>${id}</task-id><status>running</status><event>${String(event.data)}</event></task-notification>` })
    })
    return { result: { taskId: id, timeoutMs: event.timeout_ms } }
  }
  if (event.tool === 'TaskStop') {
    const child = clients.get(event.task_id)
    if (child?.kill) child.kill('SIGTERM'); else child?.close()
    return { result: { task_id: event.task_id, message: 'stopped fixture client', task_type: 'shell' } }
  }
  throw new Error(`Unexpected fixture native tool: ${event.tool}`)
}
const $ = {
  plugin: { root: config.pluginRoot }, env: { get: async key => key === 'HOME' ? config.home : key === 'CLAUDE_CODE_ENTRYPOINT' ? 'claude-desktop' : undefined },
  settings: { read: async () => ({}) }, clock: { now: async () => Date.now(), every: (_, callback) => { timers.push(callback) } },
  fs: { read: async file => fs.readFileSync(file, 'utf8'), exists: async file => fs.existsSync(file), write: async (file, text) => { fs.mkdirSync(path.dirname(file), { recursive: true, mode: 0o700 }); fs.writeFileSync(file, text, { mode: 0o600 }) } },
  process: { run: async argv => {
    if (argv[0] === '/bin/sh') return { exitCode: 0, stdout: String(process.pid), stderr: '' }
    try { const r = await execute(argv[0], argv.slice(1), { cwd: config.home, env: process.env }); return { exitCode: 0, ...r } }
    catch (r) {
      if (argv[1] === 'monitor-input') console.error(r.stderr)
      return { exitCode: typeof r.code === 'number' ? r.code : 1, stdout: r.stdout ?? '', stderr: r.stderr ?? '' }
    }
  } },
  session: { id: async () => session, usage: async () => ({ rateLimits: [] }), messages: async () => { try { return JSON.parse(fs.readFileSync(config.history, 'utf8')) } catch { return [] } } },
  agent: { list: async () => [] }, tool: { check: async () => ({ decision: 'allow' }), list: async () => ['Bash', 'Monitor', 'TaskStop', 'GetTask'].map(name => ({ name })), call: nativeTool },
  prompt: { submit: async () => { prompts++; return { drop: 'The integration fixture never runs a model continuation.' } } },
  turn: { abort: async () => {} },
}
async function fire(name, event, next = async event => event) {
  next.origin = { plugin: 'engine', tier: 'core' }
  const entry = handlers.find(item => item.name === name && (!item.matcher || Object.entries(item.matcher).every(([key, value]) => value instanceof RegExp ? value.test(event[key]) : value === event[key])))
  return entry ? entry.handler($, event, next) : next(event)
}
function report() { const folder = path.join(root, 'runtimes', session); return JSON.parse(fs.readFileSync(path.join(folder, fs.readdirSync(folder).find(file => JSON.parse(fs.readFileSync(path.join(folder, file))).pid === process.pid)), 'utf8')) }
await fire('session.start', { isInteractive: false, cwd: config.home, surface: null })
const job = path.join(root, 'commands/cmd-fixture')
// owner introspection needs an owned directory, and does not execute a command.
if (!fs.existsSync(job)) await $.process.run([path.join(config.pluginRoot, 'bin/CompanionNativeWorker'), 'prepare', job])
const owner = JSON.parse((await $.process.run([path.join(config.pluginRoot, 'bin/CompanionNativeWorker'), 'owner', job])).stdout)
process.send({ type: 'ready', runtime: report(), owner })
process.on('message', async message => {
  try {
    if (message.action === 'source') {
      const rows = []
      for (const input of message.tools) {
        const tool_use_id = `source-${++sequence}`
        const result = await fire('tool.call', { ...input, tool_use_id }, nativeTool)
        rows.push({ toolUses: [{ tool: input.tool, tool_use_id, input: { ...input, tool: undefined }, result: result.result }] })
      }
      fs.writeFileSync(config.history, JSON.stringify(rows), { mode: 0o600 })
      process.send({ type: 'source', runtime: report(), calls })
    }
    if (message.action === 'poll') {
      for (const callback of timers) await callback()
      process.send({ type: 'poll', calls, prompts, runtime: report() })
    }
    if (message.action === 'quit') {
      for (const child of clients.values()) { if (child.kill) child.kill('SIGTERM'); else child.close() }
      process.exit(0)
    }
  } catch (error) { process.send({ type: 'error', message: String(error.stack ?? error) }) }
})
