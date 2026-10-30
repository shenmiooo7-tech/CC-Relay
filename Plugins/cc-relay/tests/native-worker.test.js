import assert from 'node:assert/strict'
import test from 'node:test'
import { spawn, spawnSync, execFileSync, fork } from 'node:child_process'
import { mkdtempSync, mkdirSync, readFileSync, writeFileSync, existsSync, rmSync, realpathSync, symlinkSync, unlinkSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { fileURLToPath } from 'node:url'
import { join, resolve, dirname } from 'node:path'
import http from 'node:http'
import { createHash } from 'node:crypto'
import { quote, workerCommand } from '../hooks/native-command.js'

const WORKER = process.env.CC_RELAY_NATIVE_WORKER ?? fileURLToPath(new URL('../../../.build/out/Products/Debug/CompanionNativeWorker', import.meta.url))
const delay = ms => new Promise(resolve => setTimeout(resolve, ms))
async function until(fn, timeout = 10000) { const end = Date.now() + timeout; while (Date.now() < end) { const value = fn(); if (value) return value; await delay(25) } throw new Error('isolated native worker did not reach the expected state') }
function json(path) { try { return JSON.parse(readFileSync(path, 'utf8')) } catch { return undefined } }
function processIdentity(pid) {
  const code = `import ctypes,json,struct,sys
p=int(sys.argv[1]); lib=ctypes.CDLL('/usr/lib/libproc.dylib'); b=ctypes.create_string_buffer(136); path=ctypes.create_string_buffer(4096)
if lib.proc_pidinfo(p,3,0,b,136)!=136 or struct.unpack_from('=I',b.raw,4)[0]==5 or lib.proc_pidpath(p,path,4096)<=0: sys.exit(1)
seconds,micros=struct.unpack_from('=QQ',b.raw,120)
print(json.dumps({'pid':p,'ppid':struct.unpack_from('=I',b.raw,16)[0],'start':seconds*1000000+micros,'executable':path.value.decode()}))`
  const result = spawnSync('/usr/bin/python3', ['-c', code, String(pid)], { encoding: 'utf8', timeout: 5000 })
  return result.status === 0 ? JSON.parse(result.stdout) : undefined
}

test('artifact startup bridge reads persisted native intent beyond the hook read limit without changing a transcript', () => {
  const home = mkdtempSync(join(tmpdir(), 'cc-relay-artifact-bridge-'))
  try {
    const config = join(home, 'custom-cli'), projects = join(config, 'projects'), directory = join(projects, 'original')
    mkdirSync(directory, { recursive: true })
    const sessionID = 'artifact-session', file = join(directory, sessionID + '.jsonl')
    const rows = [
      { sessionId: sessionID, uuid: 'user-1', parentUuid: null, type: 'user', message: { content: 'Original task' } },
      { sessionId: sessionID, uuid: 'assistant-1', parentUuid: 'user-1', type: 'assistant',
        message: { content: [{ type: 'text', text: 'DO_NOT_EXPORT_' + 'x'.repeat(4_200_000) }], stop_reason: 'end_turn' } },
      { sessionId: sessionID, type: 'artifact-comment-monitor', v: 1,
        artifacts: { 'original-artifact': { state: 'armed', writtenAtMs: 2 }, 'stopped-artifact': { state: 'stopped', writtenAtMs: 3 } } },
    ]
    writeFileSync(file, rows.map(row => JSON.stringify(row)).join('\n') + '\n')
    const before = createHash('sha256').update(readFileSync(file)).digest('hex')
    const call = id => spawnSync(WORKER, ['artifact-input', id], { encoding: 'utf8', env: { ...process.env, HOME: home, CLAUDE_CONFIG_DIR: config } })
    const result = call(sessionID)
    assert.equal(result.status, 0, result.stderr)
    const input = JSON.parse(result.stdout)
    assert.equal(input.sessionID, sessionID); assert.equal(input.branchComplete, true)
    assert.equal(input.artifacts.length, 1)
    assert.equal(input.artifacts[0].url, 'https://claude.ai/code/artifact/original-artifact')
    assert.equal(input.artifacts[0].replies, true)
    assert.ok(result.stdout.length < 1000)
    assert.equal(createHash('sha256').update(readFileSync(file)).digest('hex'), before)
    const fresh = call('foreign-session')
    assert.equal(fresh.status, 0)
    assert.deepEqual(JSON.parse(fresh.stdout).artifacts, [], 'a fresh session without a transcript has no original watches')
    assert.equal(call('../artifact-session').status, 125)
    mkdirSync(join(projects, 'duplicate'))
    writeFileSync(join(projects, 'duplicate', sessionID + '.jsonl'), readFileSync(file))
    assert.equal(call(sessionID).status, 125, 'an ambiguous original transcript cannot authorize recovery')
  } finally { rmSync(home, { recursive: true, force: true }) }
})

test('artifact reply intent survives an unwired watch receipt in the real startup worker', () => {
  const home = mkdtempSync(join(tmpdir(), 'cc-relay-artifact-intent-'))
  try {
    const config = join(home, '.claude'), sessionId = 'original-session', url = 'https://claude.ai/code/artifact/original-artifact'
    const file = join(config, 'projects/original', sessionId + '.jsonl')
    mkdirSync(dirname(file), { recursive: true })
    const timestamp = '2026-10-27T01:00:00.000Z'
    const rows = [
      { type: 'user', uuid: 'root', parentUuid: null, message: { content: 'Original artifact task' } },
      { type: 'artifact-comment-monitor', v: 1, artifacts: { 'original-artifact': { state: 'armed', writtenAtMs: 1 } } },
    ]
    let parent = 'root'
    const appendWatch = (id, on, auto_reply) => {
      rows.push({ type: 'assistant', uuid: id, parentUuid: parent, message: { content: [
        { type: 'tool_use', id, name: 'ArtifactComments', input: { action: 'watch', url, on } },
      ], stop_reason: 'tool_use' } })
      parent = id + '-result'
      rows.push({ type: 'user', uuid: parent, parentUuid: id, toolUseResult: { watch: { url, watching: on, auto_reply } },
        message: { content: [{ type: 'tool_result', tool_use_id: id, content: 'native receipt' }] } })
    }
    const readIntent = () => {
      writeFileSync(file, rows.map(row => JSON.stringify({ sessionId, timestamp, ...row })).join('\n') + '\n')
      const result = spawnSync(WORKER, ['artifact-input', sessionId], { encoding: 'utf8', env: { ...process.env, HOME: home, CLAUDE_CONFIG_DIR: config } })
      assert.equal(result.status, 0, result.stderr)
      return JSON.parse(result.stdout).artifacts
    }
    assert.equal(readIntent()[0].replies, true)
    appendWatch('watch', true, 'none')
    assert.equal(readIntent()[0].replies, true, 'a runtime without wiring cannot erase the prior reply intent')
    appendWatch('stop', false, 'stopped')
    assert.deepEqual(readIntent(), [])
    appendWatch('watch-only', true, 'none')
    assert.equal(readIntent()[0].replies, false, 'the explicit stop still clears old reply intent')
    appendWatch('approved-rewatch', true, 'armed')
    assert.equal(readIntent()[0].replies, true)
  } finally { rmSync(home, { recursive: true, force: true }) }
})

function fixture() {
  assert.ok(existsSync(WORKER), 'Build CompanionNativeWorker with scripts/test.sh before running its process regressions')
  const home = mkdtempSync(join(tmpdir(), 'cc-relay-worker-')), root = join(home, 'Library/Application Support/CC-Relay/NativeRecovery')
  const control = join(root, 'commands/cmd-fixture'), env = { ...process.env, HOME: home, CC_RELAY_TEST: '1' }
  function call(...args) { return spawnSync(WORKER, args, { env, cwd: home, encoding: 'utf8', timeout: 5000 }) }
  const prepared = call('prepare', control); assert.equal(prepared.status, 0)
  const job = JSON.parse(prepared.stdout).directory
  const owner = JSON.parse(call('owner', job).stdout)
  function spec(command, overrides = {}) {
    writeFileSync(join(job, 'spec.json'), JSON.stringify({ version: 1, jobID: 'cmd-fixture', sessionID: 'session-fixture', kind: 'bash', command,
      ownerPID: process.pid, procStart: execFileSync('/bin/ps', ['-p', String(process.pid), '-o', 'lstart='], { encoding: 'utf8', env: { ...process.env, TZ: 'UTC' } }).trim(), ...overrides }), { mode: 0o600 })
  }
  function launch(...args) { const child = spawn(WORKER, args, { env, cwd: home, stdio: ['ignore', 'pipe', 'pipe'] }); child.stdout.on('data', () => {}); child.stderr.on('data', () => {}); return child }
  async function cleanup() {
    call('stop', job)
    await until(() => { const s = json(join(job, 'state.json')); return !s || !['running', 'starting'].includes(s.status) })
    rmSync(dirname(job), { recursive: true, force: true }); rmSync(home, { recursive: true, force: true })
  }
  function permit(record, requestID = 'req-fixture') {
    mkdirSync(join(root, 'requests'), { recursive: true, mode: 0o700 })
    writeFileSync(join(root, 'active.json'), JSON.stringify({ version: 1, operationID: 'op-fixture', ready: true }))
    writeFileSync(join(root, 'requests/session-fixture.json'), JSON.stringify({ version: 1, requiredCapability: 'native-recovery-v6', operationID: 'op-fixture', requestID, sessionID: 'session-fixture', phase: 'armed', pid: process.pid, instanceID: 'target-fixture', expiresAt: Date.now() + 600000 }))
    writeFileSync(join(job, 'handoff.json'), JSON.stringify({ version: 1, jobID: 'cmd-fixture', sessionID: 'session-fixture', operationID: 'op-fixture', sourcePID: record.owner.pid, sourceStartedAt: record.owner.start,
      expiresAt: Date.now() + 60000, targetPID: process.pid, targetStartedAt: owner.start, targetInstanceID: 'target-fixture', requestID }))
  }
  return { home, root, job, env, owner, call, spec, launch, cleanup, permit, state: () => json(join(job, 'state.json')) }
}

test('a real command survives source process-group exit and reattaches with the same child PID and one startup effect', { timeout: 20000 }, async () => {
  const f = fixture(); let source, attached
  try {
    const config = join(f.home, 'source.json')
    writeFileSync(config, JSON.stringify({ worker: WORKER, job: f.job, command: 'printf "START\\n" >> effects; i=0; while [ "$i" -lt 60 ]; do i=$((i+1)); printf "%s\\n" "$i" >> progress; printf "tick:%s\\n" "$i"; sleep 0.05; done; printf "DONE\\n" >> effects' }), { mode: 0o600 })
    source = spawn(process.execPath, ['--input-type=module', '-e', `
      import fs from 'node:fs'; import {spawn,execFileSync} from 'node:child_process';
      const c=JSON.parse(fs.readFileSync(process.argv[1],'utf8'));
      fs.writeFileSync(c.job+'/spec.json',JSON.stringify({version:1,jobID:'cmd-fixture',sessionID:'session-fixture',kind:'bash',command:c.command,ownerPID:process.pid,procStart:execFileSync('/bin/ps',['-p',String(process.pid),'-o','lstart='],{encoding:'utf8',env:{...process.env,TZ:'UTC'}}).trim()}),{mode:0o600});
      spawn(c.worker,['run',c.job],{stdio:'ignore'}); setInterval(()=>{},1000);
    `, config], { env: f.env, cwd: f.home, detached: true, stdio: 'ignore' })
    const initial = await until(() => { const s = f.state(); return s?.child && s.status === 'running' ? s : undefined })
    await until(() => existsSync(join(f.home, 'progress')) && readFileSync(join(f.home, 'progress'), 'utf8').split('\n').length > 4)
    f.permit(initial)
    // This group belongs only to the fixture source and its native output client.
    process.kill(-source.pid, 'SIGTERM')
    await until(() => source.exitCode !== null || source.signalCode !== null)
    const before = readFileSync(join(f.home, 'progress'), 'utf8').length
    await until(() => readFileSync(join(f.home, 'progress'), 'utf8').length > before)
    assert.equal(f.state().child.pid, initial.child.pid)
    assert.equal(f.state().worker.pid, initial.worker.pid)
    attached = f.launch('attach', f.job, 'req-fixture')
    const finished = await until(() => { const s = f.state(); return s?.status === 'completed' ? s : undefined })
    await until(() => attached.exitCode !== null)
    assert.equal(attached.exitCode, 0)
    assert.equal(finished.child.pid, initial.child.pid)
    assert.equal(finished.owner.pid, process.pid)
    assert.equal(readFileSync(join(f.home, 'effects'), 'utf8'), 'START\nDONE\n')
    assert.equal(readFileSync(join(f.home, 'progress'), 'utf8').trim().split('\n').length, 60)
  } finally { if (source && source.exitCode === null && source.signalCode === null) source.kill(); if (attached?.exitCode === null) attached.kill(); await f.cleanup() }
})

test('an adoption published under the ownership lock is noticed promptly after unlock without another file event', { timeout: 15000 }, async () => {
  const f = fixture(); let source, writer
  try {
    f.spec('printf "START\\n" >> effects; sleep 10')
    source = f.launch('run', f.job)
    const initial = await until(() => { const s = f.state(); return s?.child && s.status === 'running' ? s : undefined })
    f.permit(initial)
    const adoption = { version: 1, requestID: 'req-fixture', operationID: 'op-fixture', instanceID: 'target-fixture', owner: f.owner, client: f.owner }
    writer = spawn('/usr/bin/python3', ['-c',
      'import fcntl,sys,time,pathlib\nf=open(sys.argv[1],"a")\nfcntl.flock(f,fcntl.LOCK_EX)\npathlib.Path(sys.argv[2]).write_text(sys.argv[3])\ntime.sleep(0.5)\nfcntl.flock(f,fcntl.LOCK_UN)',
      join(f.job, 'ownership.lock'), join(f.job, 'adoptions/req-fixture.json'), JSON.stringify(adoption)], { stdio: 'ignore' })
    await until(() => writer.exitCode !== null)
    assert.equal(writer.exitCode, 0)
    await until(() => f.state()?.client?.pid === process.pid, 2000)
    assert.equal(f.state().child.pid, initial.child.pid)
    assert.equal(readFileSync(join(f.home, 'effects'), 'utf8'), 'START\n')
  } finally { if (writer?.exitCode === null) writer.kill(); if (source?.exitCode === null) source.kill(); await f.cleanup() }
})

test('the detached command keeps the calling shell\'s functions and aliases, and their file is removed once read', { timeout: 20000 }, async () => {
  for (const shell of ['/bin/zsh', '/bin/bash']) {
    const f = fixture(); let caller
    try {
      f.spec('greet_fn; greet_alias')
      const define = shell.endsWith('zsh') ? 'greet_fn() { print fn-ok >> effects }\nalias greet_alias="print alias-ok >> effects"\n'
        : 'greet_fn() { echo fn-ok >> effects; }\nalias greet_alias="echo alias-ok >> effects"\n'
      caller = spawn(shell, ['-c', `${define}${workerCommand(WORKER, f.job, f.job, 'greet_fn; greet_alias')}`],
        { env: f.env, cwd: f.home, stdio: ['ignore', 'pipe', 'pipe'] })
      caller.stdout.on('data', () => {}); caller.stderr.on('data', () => {})
      await until(() => f.state()?.status === 'completed')
      await until(() => caller.exitCode !== null)
      assert.equal(readFileSync(join(f.home, 'effects'), 'utf8'), 'fn-ok\nalias-ok\n', shell)
      assert.ok(!existsSync(join(f.job, 'shell-state.zsh')) && !existsSync(join(f.job, 'shell-state.bash')), 'definitions do not stay on disk')
    } finally { if (caller?.exitCode === null) caller.kill(); await f.cleanup() }
  }
})

test('duplicate real clients do not execute an already started command twice and explicit stop reaches its real process', { timeout: 15000 }, async () => {
  const f = fixture(); let a, b
  try {
    f.spec('printf "START\\n" >> effects; sleep 20')
    a = f.launch('run', f.job)
    b = f.launch('run', f.job)
    const initial = await until(() => f.state()?.child ? f.state() : undefined)
    await delay(200)
    assert.equal(f.state().child.pid, initial.child.pid)
    assert.equal(readFileSync(join(f.home, 'effects'), 'utf8'), 'START\n')
    assert.equal(f.call('stop', f.job).status, 0)
    await until(() => f.state()?.status === 'stopped')
    await until(() => a.exitCode !== null && b.exitCode !== null)
    assert.notEqual(a.exitCode, 0)
    assert.equal(readFileSync(join(f.home, 'effects'), 'utf8'), 'START\n')
  } finally { if (a?.exitCode === null) a.kill(); if (b?.exitCode === null) b.kill(); await f.cleanup() }
})

test('native output client exit needs a real handoff or a matching live source preparation to preserve its command', { timeout: 15000 }, async () => {
  for (const mode of ['none', 'handoff', 'preparing', 'wrong-source', 'wrong-birth', 'expired-preparation']) {
    const f = fixture(); let client
    try {
      f.spec('printf "ONCE\\n" >> effects; while :; do sleep 0.1; done')
      client = f.launch('run', f.job)
      const initial = await until(() => f.state()?.child ? f.state() : undefined)
      assert.equal(initial.owner.pid, process.pid)
      // Child identity is published before its shell executes the first instruction. This case
      // tests stopping an already-started command, not cancelling it before its startup effect.
      await until(() => existsSync(join(f.home, 'effects')))
      if (mode === 'handoff') f.permit(initial)
      else if (mode !== 'none') writeFileSync(join(f.root, 'active.json'), JSON.stringify({ version: 1, operationID: 'next-switch', ready: false,
        createdAt: mode === 'expired-preparation' ? Date.now() - 301000 : Date.now(), sourceProcesses: [{ pid: mode === 'wrong-source' ? process.pid + 100000 : process.pid,
          startedAt: initial.owner.start + (mode === 'wrong-birth' ? 1 : 0) }] }))
      client.kill('SIGTERM'); await until(() => client.signalCode !== null)
      if (['handoff', 'preparing'].includes(mode)) {
        await delay(250)
        assert.equal(f.state().status, 'running'); assert.equal(f.state().child.pid, initial.child.pid)
      } else await until(() => f.state().status === 'stopped')
      assert.equal(readFileSync(join(f.home, 'effects'), 'utf8'), 'ONCE\n')
    } finally { if (client?.exitCode === null && client?.signalCode === null) client.kill('SIGTERM'); await f.cleanup() }
  }
})

test('losing a mutable worker state file cannot run an already executed original command again', { timeout: 10000 }, async () => {
  const f = fixture()
  try {
    f.spec('printf "ONCE\\n" >> effects')
    assert.equal(f.call('run', f.job).status, 0)
    assert.equal(readFileSync(join(f.home, 'effects'), 'utf8'), 'ONCE\n')
    unlinkSync(join(f.job, 'state.json'))
    assert.equal(f.call('run', f.job).status, 125)
    assert.equal(readFileSync(join(f.home, 'effects'), 'utf8'), 'ONCE\n')
  } finally { await f.cleanup() }
})

test('a real TaskStop also ends an owned grandchild that ignores TERM after its shell leader exits', { timeout: 15000 }, async () => {
  const f = fixture(); let original
  try {
    const nested = 'import os,signal,time\nsignal.signal(signal.SIGTERM,signal.SIG_IGN)\nopen("grandchild.pid","w").write(str(os.getpid()))\nwhile True:\n open("grandchild-effects","a").write("tick\\n")\n time.sleep(0.05)'
    const parent = `import subprocess,sys\np=subprocess.Popen([sys.executable,'-c',${JSON.stringify(nested)}])\np.wait()`
    f.spec(`${quote('/usr/bin/python3')} -c ${quote(parent)}`)
    const client = f.launch('run', f.job)
    await until(() => existsSync(join(f.home, 'grandchild.pid')))
    original = processIdentity(Number(readFileSync(join(f.home, 'grandchild.pid'), 'utf8')))
    assert.ok(original)
    assert.equal(execFileSync('/bin/ps', ['-o', 'pgid=', '-p', String(original.pid)], { encoding: 'utf8' }).trim(), String(f.state().child.pid))
    const stopped = f.call('stop', f.job)
    const group = execFileSync('/bin/ps', ['-axo', 'pid=,ppid=,pgid=,stat=,comm='], { encoding: 'utf8' }).split('\n')
      .filter(row => row.trim().split(/\s+/)[2] === String(f.state().child.pid))
    assert.equal(stopped.status, 0, JSON.stringify({ stderr: stopped.stderr, state: f.state(), ownedGroup: group }))
    assert.equal(processIdentity(original.pid), undefined, 'an output client/root exit is not proof that the owned command group stopped')
    await until(() => client.exitCode !== null)
  } finally {
    if (original) {
      const live = processIdentity(original.pid)
      if (live?.start === original.start && live.executable === original.executable) { process.kill(original.pid, 'SIGKILL'); await until(() => !processIdentity(original.pid)) }
    }
    await f.cleanup()
  }
})

test('wrong or revoked target authorization cannot attach to a real executing command', { timeout: 15000 }, async () => {
  const f = fixture(); let client
  try {
    f.spec('sleep 20'); client = f.launch('run', f.job)
    const record = await until(() => f.state()?.child ? f.state() : undefined)
    f.permit(record)
    assert.equal(f.call('attach', f.job, 'wrong-request').status, 125)
    mkdirSync(join(f.root, 'results'), { mode: 0o700 })
    writeFileSync(join(f.root, 'results/req-fixture.json'), JSON.stringify({ revoked: true }))
    assert.equal(f.call('attach', f.job, 'req-fixture').status, 125)
    writeFileSync(join(f.root, 'results/req-fixture.json'), JSON.stringify({ revoked: true, padding: 'x'.repeat(1200000) }))
    assert.equal(f.call('attach', f.job, 'req-fixture').status, 125, 'a large revoked receipt must not be treated as absent')
    writeFileSync(join(f.root, 'results/req-fixture.json'), '{partial receipt')
    assert.equal(f.call('attach', f.job, 'req-fixture').status, 125, 'a malformed receipt must fail closed')
    writeFileSync(join(f.root, 'results/req-fixture.json'), JSON.stringify({ revoked: false }))
    const ticket = json(join(f.root, 'requests/session-fixture.json'))
    writeFileSync(join(f.root, 'requests/session-fixture.json'), JSON.stringify({ ...ticket, requiredCapability: 'native-recovery-v4' }))
    assert.equal(f.call('attach', f.job, 'req-fixture').status, 125, 'an older coordinator protocol must not authorize adoption')
    writeFileSync(join(f.root, 'requests/session-fixture.json'), JSON.stringify({ ...ticket, padding: 'x'.repeat(1200000) }))
    // Terminate this fixture client after the ownership handoff; the original command still runs once.
    const large = f.launch('attach', f.job, 'req-fixture')
    await delay(200)
    assert.equal(large.exitCode, null, 'a supported large request must not reject the real attach')
    large.kill('SIGTERM'); await until(() => large.signalCode !== null)
    assert.equal(f.state().child.pid, record.child.pid)
  } finally { if (client?.exitCode === null) client.kill(); await f.cleanup() }
})

test('short commands preserve their real output, working directory, environment and nonzero exit status', { timeout: 10000 }, async () => {
  const f = fixture()
  try {
    f.spec('pwd; printf "%s" "$WORKER_FIXTURE_VALUE"; printf "fixture-error" >&2; exit 7')
    const r = spawnSync(WORKER, ['run', f.job], { env: { ...f.env, WORKER_FIXTURE_VALUE: 'inherited-value' }, cwd: f.home, encoding: 'utf8', timeout: 8000 })
    assert.equal(r.status, 7)
    assert.ok(r.stdout.includes('inherited-value')); assert.ok(r.stdout.includes(f.home) || r.stdout.includes(realpathSync(f.home)))
    assert.equal(r.stderr, 'fixture-error')
    assert.equal(f.state().status, 'failed')
  } finally { await f.cleanup() }
})

test('the original native zsh remains identifiable and executes its own syntax instead of silently falling back to bash', { timeout: 10000 }, async () => {
  const f = fixture()
  try {
    f.spec("print -r -- 'zsh-original-syntax'; exit 7")
    const r = spawnSync('/bin/zsh', ['-c', `${quote(WORKER)} run ${quote(f.job)}; cc_relay_native_status=$?; exit "$cc_relay_native_status"`],
      { env: f.env, cwd: f.home, encoding: 'utf8', timeout: 8000 })
    assert.equal(r.status, 7)
    assert.equal(r.stdout, 'zsh-original-syntax\n')
    assert.equal(json(join(f.job, 'launch.json')).shell, '/bin/zsh')
    assert.equal(f.state().exitCode, 7)
  } finally { await f.cleanup() }
})

test('the actual plugin restores a compacted WebSocket from large disk history across two switches while keeping the original command', { timeout: 30000 }, async () => {
  const f = fixture(), sockets = new Set(); let source, target, third, jobDir, connections = 0
  const server = http.createServer()
  server.on('upgrade', (req, socket) => {
    connections++; sockets.add(socket); socket.on('close', () => sockets.delete(socket))
    const accept = createHash('sha1').update(req.headers['sec-websocket-key'] + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11').digest('base64')
    socket.write(`HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: ${accept}\r\nSec-WebSocket-Protocol: fixture\r\n\r\n`)
    setTimeout(() => { if (!socket.destroyed) { const text = Buffer.from('actual-isolated-event'); socket.write(Buffer.concat([Buffer.from([0x81, text.length]), text])) } }, 150)
  })
  function host(config) {
    const child = fork(fileURLToPath(new URL('./fixtures/native-host.mjs', import.meta.url)), [config], { env: f.env, cwd: f.home, detached: true, silent: true, execArgv: [] })
    const messages = []; let stderr = ''
    child.on('message', item => messages.push(item)); child.stderr.on('data', b => { stderr += b }); child.stdout.resume()
    const take = async type => until(() => {
      const error = messages.find(m => m.type === 'error'); if (error) throw new Error(error.message)
      const i = messages.findIndex(m => m.type === type); if (i >= 0) return messages.splice(i, 1)[0]
      if (child.exitCode !== null) throw new Error(`fixture host exited ${child.exitCode}: ${stderr}`)
    })
    return { child, take, get stderr() { return stderr }, async request(action, extra = {}) { child.send({ action, ...extra }); return take(action === 'source' ? 'source' : 'poll') } }
  }
  try {
    await new Promise(resolve => server.listen(0, '127.0.0.1', resolve))
    const pluginRoot = join(f.home, 'plugin'), history = join(f.home, 'history.json'), config = join(f.home, 'host.json')
    mkdirSync(join(pluginRoot, 'bin'), { recursive: true, mode: 0o700 }); symlinkSync(WORKER, join(pluginRoot, 'bin/CompanionNativeWorker'))
    writeFileSync(config, JSON.stringify({ home: f.home, pluginRoot, history }))
    source = host(config); await source.take('ready')
    const original = 'printf "START\\n" >> workflow-effects; i=0; while [ "$i" -lt 140 ]; do i=$((i+1)); printf "%s\\n" "$i" >> workflow-progress; sleep 0.05; done; printf "DONE\\n" >> workflow-effects'
    const initial = await source.request('source', { tools: [
      { tool: 'Bash', command: original, run_in_background: true },
      { tool: 'Monitor', ws: { url: `ws://127.0.0.1:${server.address().port}/fixture`, protocols: ['fixture'] }, description: 'local fixture', timeout_ms: 20000 },
    ] })
    const command = initial.runtime.activeTasks.find(t => t.kind === 'bash'), monitor = initial.runtime.activeTasks.find(t => t.kind === 'monitor')
    assert.ok(command.jobID); assert.ok(monitor.deadlineAt)
    const originalMonitor = json(history).flatMap(row => row.toolUses).find(use => use.tool === 'Monitor')
    const transcript = join(f.home, '.claude/projects/fixture/session-fixture.jsonl')
    mkdirSync(dirname(transcript), { recursive: true, mode: 0o700 })
    const rows = [
      { type: 'user', uuid: 'user', parentUuid: null, message: { content: 'Keep watching' } },
      { type: 'assistant', uuid: 'call', parentUuid: 'user', message: { content: [{ type: 'tool_use', id: monitor.toolUseID, name: 'Monitor', input: originalMonitor.input }] } },
      { type: 'user', uuid: 'result', parentUuid: 'call', toolUseResult: originalMonitor.result,
        message: { content: [{ type: 'tool_result', tool_use_id: monitor.toolUseID, content: 'registered' }] } },
      { type: 'api-request-blob', payload: 'x'.repeat(4200000) },
      { type: 'system', subtype: 'compact_boundary', uuid: 'boundary', parentUuid: null, logicalParentUuid: 'result' },
      { type: 'user', uuid: 'summary', parentUuid: 'boundary', isCompactSummary: true, message: { content: 'Keep watching' } },
    ].map(row => ({ ...row, sessionId: 'session-fixture' }))
    const fullHistory = rows.map(row => JSON.stringify(row)).join('\n') + '\n'
    writeFileSync(transcript, fullHistory, { mode: 0o600 })
    writeFileSync(history, JSON.stringify([{ role: 'user', text: 'Compacted summary only', toolUses: [] }]))
    const work = { version: 1, desktopSessionID: 'local_session-fixture', cliSessionID: 'session-fixture', cwd: f.home,
      capturedAt: Date.now(), sourceProfile: 'source', sourceAccountID: 'source', transcriptPath: transcript,
      transcriptSize: Buffer.byteLength(fullHistory), headUUID: 'summary', headSource: 'desktopRecord', branchComplete: true,
      warnings: [], latestAssistantInterrupted: false, needsContinuation: true, tasks: [], artifacts: [] }
    jobDir = json(join(f.root, 'commands', command.jobID, 'location.json')).directory
    const first = await until(() => { const s = json(join(jobDir, 'state.json')); return s?.child ? s : undefined })
    await until(() => connections === 1 && existsSync(join(f.home, 'workflow-progress')))
    const permit = { version: 1, jobID: command.jobID, sessionID: 'session-fixture', operationID: 'op-workflow', sourcePID: first.owner.pid, sourceStartedAt: first.owner.start, expiresAt: Date.now() + 60000 }
    writeFileSync(join(jobDir, 'handoff.json'), JSON.stringify(permit))
    process.kill(-source.child.pid, 'SIGTERM'); await until(() => source.child.signalCode !== null)
    const progress = readFileSync(join(f.home, 'workflow-progress'), 'utf8').length
    await until(() => readFileSync(join(f.home, 'workflow-progress'), 'utf8').length > progress)
    target = host(config); const ready = await target.take('ready')
    Object.assign(permit, { targetPID: ready.runtime.pid, targetStartedAt: ready.owner.start, targetInstanceID: ready.runtime.instanceID, requestID: 'req-workflow' })
    writeFileSync(join(jobDir, 'handoff.json'), JSON.stringify(permit))
    mkdirSync(join(f.root, 'requests'), { recursive: true, mode: 0o700 })
    writeFileSync(join(f.root, 'active.json'), JSON.stringify({ version: 1, ready: true, createdAt: Date.now(), operationID: 'op-workflow', targetProfile: 'target', targetAccountID: 'target' }))
    writeFileSync(join(f.root, 'requests/session-fixture.json'), JSON.stringify({ version: 1, requiredCapability: 'native-recovery-v6', operationID: 'op-workflow', requestID: 'req-workflow', sessionID: 'session-fixture', desktopSessionID: 'local_session-fixture',
      targetProfile: 'target', targetAccountID: 'target', phase: 'armed', pid: ready.runtime.pid, procStart: ready.runtime.procStart, instanceID: ready.runtime.instanceID, armedAt: Date.now(), expiresAt: Date.now() + 600000,
      createdAt: Date.now(), runtimeNotBefore: Date.now(), runtimeStartedAt: ready.owner.start,
      sourceUserStopped: false, sourceWasBusy: true, sourceActiveTasks: initial.runtime.activeTasks, work }))
    const dispatched = await target.request('poll')
    assert.ok(dispatched.calls.some(call => call.tool === 'Bash' && call.command.includes(' attach ')))
    assert.ok(!dispatched.calls.some(call => call.tool === 'Bash' && call.command === original))
    assert.ok(dispatched.calls.some(call => call.tool === 'Monitor' && call.ws?.url.endsWith('/fixture')), target.stderr)
    assert.equal(dispatched.prompts, 1)
    await until(() => connections === 2)
    await delay(250); const intermediate = await target.request('poll')
    const receipt = json(join(f.root, 'results/req-workflow.json'))
    assert.equal(receipt.tasks.find(t => t.kind === 'bash').executionVerified, true)
    assert.equal(receipt.tasks.find(t => t.kind === 'monitor').eventObserved, true)
    const foreign = f.call('monitor-input', join(f.root, 'requests/session-fixture.json'), 'req-workflow', monitor.id)
    assert.equal(foreign.status, 125, 'a sibling process cannot read a request bound to the target runtime')
    assert.equal(foreign.stdout, '')
    assert.equal(json(join(jobDir, 'state.json')).child.pid, first.child.pid)
    const adopted = await until(() => { const s = json(join(jobDir, 'state.json')); return s.owner.pid === ready.runtime.pid ? s : undefined })
    const nextPermit = { ...permit, operationID: 'op-workflow-next', sourcePID: adopted.owner.pid, sourceStartedAt: adopted.owner.start,
      targetPID: undefined, targetStartedAt: undefined, targetInstanceID: undefined, requestID: undefined }
    writeFileSync(join(jobDir, 'handoff.json'), JSON.stringify(nextPermit))
    process.kill(-target.child.pid, 'SIGTERM'); await until(() => target.child.signalCode !== null)
    third = host(config); const finalReady = await third.take('ready')
    Object.assign(nextPermit, { targetPID: finalReady.runtime.pid, targetStartedAt: finalReady.owner.start,
      targetInstanceID: finalReady.runtime.instanceID, requestID: 'req-workflow-next' })
    writeFileSync(join(jobDir, 'handoff.json'), JSON.stringify(nextPermit))
    writeFileSync(join(f.root, 'active.json'), JSON.stringify({ version: 1, ready: true, createdAt: Date.now(), operationID: 'op-workflow-next', targetProfile: 'third', targetAccountID: 'third' }))
    const nextRequest = json(join(f.root, 'requests/session-fixture.json'))
    Object.assign(nextRequest, { operationID: 'op-workflow-next', requestID: 'req-workflow-next', targetProfile: 'third', targetAccountID: 'third',
      pid: finalReady.runtime.pid, procStart: finalReady.runtime.procStart, instanceID: finalReady.runtime.instanceID,
      runtimeStartedAt: finalReady.owner.start, armedAt: Date.now(), sourceActiveTasks: intermediate.runtime.activeTasks })
    writeFileSync(join(f.root, 'requests/session-fixture.json'), JSON.stringify(nextRequest))
    const finalDispatch = await third.request('poll')
    assert.equal(finalDispatch.prompts, 1)
    assert.ok(finalDispatch.calls.some(call => call.tool === 'Bash' && call.command.includes(' attach ')))
    await until(() => connections === 3)
    // Adoption is asynchronous; verify the actual owner before polling its execution receipt.
    await until(() => json(join(jobDir, 'state.json'))?.owner.pid === finalReady.runtime.pid)
    await delay(250); await third.request('poll')
    const finalReceipt = json(join(f.root, 'results/req-workflow-next.json'))
    assert.equal(finalReceipt.tasks.find(t => t.kind === 'bash').executionVerified, true)
    assert.equal(finalReceipt.tasks.find(t => t.kind === 'monitor').eventObserved, true)
    assert.equal(json(join(jobDir, 'state.json')).child.pid, first.child.pid)
    await until(() => json(join(jobDir, 'state.json'))?.status === 'completed')
    assert.equal(readFileSync(join(f.home, 'workflow-effects'), 'utf8'), 'START\nDONE\n')
    assert.equal(readFileSync(join(f.home, 'workflow-progress'), 'utf8').trim().split('\n').length, 140)
  } finally {
    if (jobDir) { spawnSync(WORKER, ['stop', jobDir], { env: f.env }); await until(() => !['running', 'starting'].includes(json(join(jobDir, 'state.json'))?.status)).catch(() => {}) }
    for (const h of [source, target, third]) if (h?.child.exitCode === null && h?.child.signalCode === null) h.child.kill('SIGTERM')
    for (const socket of sockets) socket.destroy()
    server.close(); if (jobDir) rmSync(dirname(jobDir), { recursive: true, force: true }); await f.cleanup()
  }
})

function isolatedOwner(f, command, kind = 'bash') {
  const config = join(f.home, 'owned-source.json')
  writeFileSync(config, JSON.stringify({ worker: WORKER, job: f.job, command, kind }))
  return spawn(process.execPath, ['--input-type=module', '-e', `
    import fs from 'node:fs';import {spawn,execFileSync} from 'node:child_process';
    const c=JSON.parse(fs.readFileSync(process.argv[1],'utf8'));
    fs.writeFileSync(c.job+'/spec.json',JSON.stringify({version:1,jobID:'cmd-fixture',sessionID:'session-fixture',kind:c.kind,command:c.command,deadlineAt:c.kind==='monitor'?Date.now()+30000:undefined,ownerPID:process.pid,procStart:execFileSync('/bin/ps',['-p',String(process.pid),'-o','lstart='],{encoding:'utf8',env:{...process.env,TZ:'UTC'}}).trim()}),{mode:0o600});
    spawn(c.worker,['run',c.job],{stdio:'ignore'});setInterval(()=>{},1000);
  `, config], { env: f.env, cwd: f.home, detached: true, stdio: 'ignore' })
}

test('a failed competing Monitor consumer cannot adopt the original command owner', { timeout: 10000 }, async () => {
  const f = fixture(); let source
  try {
    source = isolatedOwner(f, 'while :; do printf "event\\n"; sleep 0.1; done', 'monitor')
    const initial = await until(() => f.state()?.child ? f.state() : undefined)
    await until(() => existsSync(join(f.job, 'cursor.json')))
    f.permit(initial)
    assert.equal(f.call('attach', f.job, 'req-fixture').status, 125)
    await delay(250)
    assert.equal(f.state().owner.pid, initial.owner.pid, 'a rejected consumer must not change execution ownership')
  } finally { if (source?.exitCode === null && source?.signalCode === null) source.kill('SIGTERM'); await f.cleanup() }
})

test('a late older adoption cannot overwrite the current request owner while the actual worker is suspended', { timeout: 15000 }, async () => {
  const f = fixture(); let source, client, initial, suspended = false
  function signalWorker(signal) {
    const live = processIdentity(initial.worker.pid)
    assert.ok(live && Math.abs(live.start / 1000 - initial.worker.start) < 0.01 && live.executable === initial.worker.executable)
    process.kill(initial.worker.pid, signal)
  }
  try {
    source = isolatedOwner(f, 'sleep 20')
    initial = await until(() => f.state()?.child ? f.state() : undefined)
    f.permit(initial)
    signalWorker('SIGSTOP'); suspended = true
    client = f.launch('attach', f.job, 'req-fixture')
    await until(() => existsSync(join(f.job, 'adoptions/req-fixture.json')))
    // An older caller may finish an in-flight write after the newer one. Its own request
    // record must not replace the current request, including an old-format global record.
    writeFileSync(join(f.job, 'adoption.json'), JSON.stringify(initial.owner))
    writeFileSync(join(f.job, 'adoptions/req-stale.json'), JSON.stringify({ version: 1, requestID: 'req-stale', operationID: 'op-stale', instanceID: 'old-instance', owner: initial.owner }))
    signalWorker('SIGCONT'); suspended = false
    await until(() => f.state().owner.pid === process.pid)
    assert.equal(f.state().child.pid, initial.child.pid)
  } finally {
    if (suspended) signalWorker('SIGCONT')
    if (source?.exitCode === null && source?.signalCode === null) source.kill('SIGTERM')
    if (client?.exitCode === null) client.kill('SIGTERM')
    await f.cleanup()
  }
})

test('a source exit without a switch permit ends its actual command instead of leaving an unmanaged orphan', { timeout: 10000 }, async () => {
  const f = fixture(); let owner
  try {
    owner = isolatedOwner(f, 'sleep 20')
    await until(() => f.state()?.child)
    process.kill(-owner.pid, 'SIGTERM')
    const killed = Date.now()
    await until(() => f.state()?.status === 'stopped', 6000).catch(error => {
      throw new Error(`${error.message} ${Date.now() - killed} ms after the exit: ${JSON.stringify(f.state())}`)
    })
    const view = f.call('inspect', f.job)
    assert.equal(view.status, 0); assert.equal(JSON.parse(view.stdout).status, 'stopped')
  } finally { if (owner?.exitCode === null && owner?.signalCode === null) owner.kill(); await f.cleanup() }
})

// Processes of a process group that are alive, zombies left out.
function members(group) {
  const listed = spawnSync('/bin/ps', ['-g', String(group), '-o', 'pid=,stat='], { encoding: 'utf8' }).stdout
  return listed.split('\n').map(line => line.trim().split(/\s+/)).filter(([pid, stat]) => pid && !stat?.startsWith('Z')).map(([pid]) => Number(pid))
}

test('a stop ends everything the command started, also the processes it was still starting', { timeout: 30000 }, async () => {
  // Each stop lands while the command keeps starting processes: none of its group may outlive it.
  for (const wait of [0, 20, 60, 120]) {
    const f = fixture(); let owner, group
    try {
      owner = isolatedOwner(f, 'i=0; while [ "$i" -lt 60 ]; do sleep 30 & i=$((i+1)); done; wait')
      group = (await until(() => f.state()?.child)).pid
      await delay(wait)
      process.kill(-owner.pid, 'SIGTERM')
      await until(() => f.state()?.status === 'stopped', 6000).catch(error => {
        throw new Error(`${error.message} (stop after ${wait} ms): ${JSON.stringify(f.state())}`)
      })
      assert.deepEqual(members(group), [], `the stop after ${wait} ms left part of the command running`)
    } finally {
      if (group) try { process.kill(-group, 'SIGKILL') } catch {}
      if (owner?.exitCode === null && owner?.signalCode === null) owner.kill(); await f.cleanup()
    }
  }
})

test('a command Monitor backfills only bytes after its persisted source cursor when reconnecting', { timeout: 10000 }, async () => {
  const f = fixture(); let owner, client
  try {
    owner = isolatedOwner(f, 'printf "before\\n"; while [ ! -f resume-monitor ]; do sleep 0.02; done; printf "after\\n"', 'monitor')
    const initial = await until(() => f.state()?.child ? f.state() : undefined)
    await until(() => json(join(f.job, 'cursor.json'))?.stdout === 7)
    f.permit(initial); process.kill(-owner.pid, 'SIGTERM')
    await until(() => owner.signalCode !== null)
    writeFileSync(join(f.home, 'resume-monitor'), 'resume')
    await until(() => f.state()?.status === 'completed')
    let output = ''
    client = f.launch('attach', f.job, 'req-fixture'); client.stdout.on('data', b => { output += b })
    await until(() => client.exitCode !== null)
    assert.equal(client.exitCode, 0)
    assert.equal(output, 'after\n')
    assert.equal(json(join(f.job, 'cursor.json')).stdout, 13)
  } finally { if (owner?.exitCode === null && owner?.signalCode === null) owner.kill(); if (client?.exitCode === null) client.kill(); await f.cleanup() }
})

test('worker health inspection does not trust an old running file as proof of a live execution controller', { timeout: 10000 }, async () => {
  const f = fixture(); let client
  try {
    f.spec('sleep 20'); client = f.launch('run', f.job)
    const value = await until(() => f.state()?.child ? f.state() : undefined)
    writeFileSync(join(f.job, 'state.json'), JSON.stringify({ ...value, worker: { ...value.worker, pid: 2147483647 } }))
    const r = f.call('inspect', f.job)
    assert.equal(r.status, 0); assert.equal(JSON.parse(r.stdout).status, 'attention')
    writeFileSync(join(f.job, 'state.json'), JSON.stringify(value))
  } finally { if (client?.exitCode === null) client.kill(); await f.cleanup() }
})

test('detaching a real command preserves the native shell sandbox and keeps execution writes in its private temporary directory', { timeout: 10000 }, async () => {
  const f = fixture()
  try {
    const quote = value => `'${value.replaceAll("'", "'\\''")}'`
    const permitted = join(f.job, 'permitted'), forbidden = join(f.home, 'forbidden')
    f.spec(`printf allowed > ${quote(permitted)}; printf forbidden > ${quote(forbidden)}`)
    const physical = f.job.replace(/^\/tmp\//, '/private/tmp/')
    const profile = `(version 1)(allow default)(deny file-write*)(allow file-write* (subpath "${f.job}") (subpath "${physical}"))`
    const r = spawnSync('/usr/bin/sandbox-exec', ['-p', profile, WORKER, 'run', f.job], { env: f.env, cwd: f.home, encoding: 'utf8', timeout: 8000 })
    assert.equal(readFileSync(permitted, 'utf8'), 'allowed')
    assert.equal(existsSync(forbidden), false)
    assert.notEqual(r.status, 0)
    assert.equal(f.state().status, 'failed')
  } finally { await f.cleanup() }
})
