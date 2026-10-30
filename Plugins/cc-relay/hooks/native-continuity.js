import { configureCommands, worker, wrapCommand, rememberCommand, stopCommand, commandAttachment, inspectCommand, checkWrappedCommand, encodeResult } from './native-command.js'
import { artifactKey, artifactRecovery, advanceArtifacts } from './artifact-continuity.js'
import { hostTasks, isHostTerminal, retireHostTask } from './host-work-inventory.js'
import { PLUGIN_VERSION } from './version.js'
import { CONTINUATION_TEXT } from './continuation-text.js'

// Restore concrete native work first; a main conversation prompt handles the subsequent model work.
const ROOT = 'Library/Application Support/CC-Relay/NativeRecovery'
const SAFE_ID = /^[A-Za-z0-9_-]{1,128}$/
const TICK_MS = 2_000
// Changes are reported as they happen; the period only proves the runtime is still there.
const HEARTBEAT_MS = 5_000
const MAX_EVIDENCE = 96
const USER_ORIGINS = new Set(['composer', 'bridge', 'sdk'])
// Work that stopped with the switch and was never protected is recorded for inspection.
// The conversation can check its history and output before starting it again. It is not a failure.
const UNPROTECTED = 'Not protected (it needed approval or ran under a PreToolUse policy), so it stopped with the switch. Check its output before starting it again.'
const EXECUTION_OUTCOMES = new Set(['toolResultReturned', 'monitorRegistered', 'backgroundRegistered', 'agentResultReturned', 'monitorEventObserved', 'originalCommandExecutionVerified'])
// Receipts nothing moves any more: checked, the continuation's turn over, given way to the
// person, or a problem to look at.
const FINAL = new Set(['inspected', 'turnFinished', 'yielded', 'needsAttention'])
// What Claude Desktop sends, under the person's own origin, to a conversation whose turn its quit
// interrupted: "The app was quit while you were working. Please continue from where you left off."
// A switch's continuation on its way takes its place, so the work goes on once. It is told by what it
// says, so other wording of the same two sentences still counts; anything more in it is the person's.
const QUIT = String.raw`(?:(?:the )?(?:app|application|claude(?: desktop)?) )?(?:was |got |has been |had been )?` +
  String.raw`(?:quit|closed|restarted|relaunched|shut down) while you were (?:working|responding|replying|running)`
const GO_ON = String.raw`(?:please )?(?:continue|resume|pick up|carry on|keep going)(?: (?:from|at))? where you left off`
const HOST_RESUME = new RegExp(`^(?:${QUIT} ${GO_ON}|${GO_ON} ${QUIT})$`)
function hostResume(text) {
  return typeof text === 'string' && text.length <= 400 && HOST_RESUME.test(text.toLowerCase().replace(/[^a-z]+/g, ' ').trim())
}
// How long that prompt is held for a continuation that has not come yet.
const HOST_RESUME_WAIT_MS = 120_000
// How long CC-Relay keeps a comment watch for the account that published its page.
const KEPT_WATCH_MS = 7 * 86_400_000
// How long the word that the service stopped this account stands without a new one.
const ACCOUNT_STOPPED_MS = 86_400_000
// CC-Relay lists an open Claude within five minutes: how often, and how many times, a reopened
// conversation looks for its account before it leaves a kept watch alone for good.
const ACCOUNT_LOOK_MS = 30_000
const ACCOUNT_LOOKS = 12

function folder(state) { return `${state.home}/${ROOT}` }
function reason(error) { return String(error?.message ?? error ?? 'unknown error').replace(/\s+/g, ' ').slice(0, 240) }
function marker(request) { return `[Continuation requestID=${request.requestID}]` }
// The host's failure message can contain a tool argument. Persist only its bounded category.
function failedHook(state, event, next) {
  const kind = next.error?.kind === 'timeout' ? 'timeout' : next.error?.kind === 'throw' ? 'throw' : 'unknown'
  state.hookFailure = { event, kind }
  state.lastError = `The ${event} hook failed (${kind}).`
}
function automaticRequest(state, event) {
  const issued = typeof event.text === 'string' && ISSUED.exec(event.text)
  const known = issued && (event.agentId === undefined ? state.issuedPrompts.has(issued[1])
    : state.issuedAgentPrompts.has(`${issued[1]}:${event.agentId}`))
  return known ? issued[1] : event.text === ''
    ? (event.agentId === undefined ? state.mainAutomaticRequestID : state.automaticAgentRequests.get(event.agentId)) : undefined
}
// The host frames a plugin's prompt ("The <name> plugin sent a message:") and a message delivered to
// an agent ("... sent a message while you were working:") on one line before the text itself.
// Recognise the previous marker format too; the request must still be known to this runtime.
const ISSUED = /^(?:[^\n]{0,160}\bsent a message\b[^\n]{0,80}?:\s*)?\[(?:Continuation|CC-Relay 原任务续接) requestID=([A-Za-z0-9_-]{1,128})\]/
async function readJSON($, path) { try { return JSON.parse(await $.fs.read(path)) } catch { return undefined } }
async function inventoryTime($, state) {
  // Preserve snapshot/registration order even when two host clock reads share a millisecond.
  const now = await $.clock.now()
  state.inventoryTimestamp = Math.max(now, (state.inventoryTimestamp ?? 0) + 0.01)
  return state.inventoryTimestamp
}

async function observeHostWork($, state, event) {
  if (!state.enabled || event.session_id !== state.sessionID) return
  // SubagentStop lists the parent conversation's tasks too.
  const tasks = hostTasks(event, state.hostEndedTasks)
  if (!tasks) return
  state.hostWorkInventory = { backgroundTasks: tasks }
  await heartbeat($, state)
}

async function identify($, state) {
  const sessionID = await $.session.id()
  if (!SAFE_ID.test(sessionID)) return false
  if (!state.pid) {
    const result = await $.process.run(['/bin/sh', '-c', 'printf %s "$PPID"'])
    if (result.exitCode !== 0 || !/^\d+$/.test(result.stdout.trim())) return false
    state.pid = Number(result.stdout.trim())
  }
  if (!Number.isSafeInteger(state.pid) || state.pid < 2) return false
  const configured = await $.env.get('CLAUDE_CONFIG_DIR')
  const configDir = typeof configured === 'string' && configured.startsWith('/') ? configured : `${state.home}/.claude`
  const registry = await readJSON($, `${configDir}/sessions/${state.pid}.json`)
  if (registry?.pid !== state.pid || registry.sessionId !== sessionID || registry.pidDomain !== 'darwin'
    || registry.entrypoint !== 'claude-desktop' || typeof registry.procStart !== 'string' || !registry.procStart.trim()) return false
  state.sessionID = sessionID
  state.procStart = registry.procStart
  return true
}

async function report($, state) {
  if (!state.enabled || !await identify($, state)) return false
  const agents = await $.agent.list()
  if (!Array.isArray(agents)) return false
  const backgroundBusy = agents.some(agent => ['pending', 'running', 'waiting'].includes(agent.status))
  const reportedAt = await inventoryTime($, state)
  const usage = await $.session.usage().catch(() => undefined)
  const exhausted = usage?.rateLimits?.filter(limit => ['five_hour', 'seven_day'].includes(limit.kind)
    && Number.isFinite(limit.percentUsed) && limit.percentUsed >= 100
    && (limit.resetsAt === undefined || Date.parse(limit.resetsAt) > reportedAt))
  if (state.rateLimitFailure?.until <= reportedAt) state.rateLimitFailure = undefined
  if (state.accountStopped?.until <= reportedAt) state.accountStopped = undefined
  const quotaBlock = state.accountStopped ?? (state.userStopped ? undefined : state.rateLimitFailure ?? (exhausted?.length ? {
    reason: 'quota', observedAt: reportedAt,
    until: Math.max(...exhausted.map(limit => Date.parse(limit.resetsAt) || reportedAt + 600_000)),
  } : undefined))
  const activeTasks = [...state.activeTasks.values(), ...agents.filter(agent => ['pending', 'running', 'waiting'].includes(agent.status))
    .map(agent => ({ id: agent.id, kind: 'agent' }))]
  await $.fs.write(`${folder(state)}/runtimes/${state.sessionID}/${state.instanceID}.json`, JSON.stringify({
    version: 1, pluginVersion: PLUGIN_VERSION, sessionID: state.sessionID, instanceID: state.instanceID,
    pid: state.pid, procStart: state.procStart, reportedAt,
    busy: state.busy || backgroundBusy || activeTasks.length > 0 ||
      state.hostWorkInventory?.backgroundTasks.some(task => task.type === 'shell') === true,
    activeTasks, quotaBlock, hostWorkInventory: state.hostWorkInventory, hookFailure: state.hookFailure,
    userStopped: state.userStopped, capabilities: ['native-recovery-v1', 'native-recovery-v2', 'native-recovery-v3', 'native-recovery-v4', 'native-recovery-v6', 'watch-reopen-v1'],
  }))
  return true
}

// The service stopped this account, whatever else says it is spent: CC-Relay leaves the work where
// it is. A reply that gets through ends this, and a person stopping one does not.
async function accountStopped($, state, event, next) {
  const result = await next(event)
  if (!state.enabled || event.session_id !== state.sessionID) return result
  try {
    const now = await $.clock.now()
    state.accountStopped = { reason: 'accountRestricted', observedAt: now, until: now + ACCOUNT_STOPPED_MS }
    await heartbeat($, state)
  } catch (error) { state.lastError = reason(error) }
  return result
}

async function ticket($, state) {
  if (!state.enabled || !state.sessionID) return undefined
  const active = await readJSON($, `${folder(state)}/active.json`)
  const request = await readJSON($, `${folder(state)}/requests/${state.sessionID}.json`)
  const now = await $.clock.now()
  if (active?.version !== 1 || active.ready !== true || request?.version !== 1 || request.phase !== 'armed'
    || request.requiredCapability !== 'native-recovery-v6'
    || request.runtimeError != null
    || !SAFE_ID.test(request.requestID ?? '') || !SAFE_ID.test(request.operationID ?? '')
    || active.operationID !== request.operationID || active.targetProfile !== request.targetProfile
    || active.targetAccountID !== request.targetAccountID || request.sessionID !== state.sessionID
    || request.instanceID !== state.instanceID || request.pid !== state.pid || request.procStart !== state.procStart
    || !Number.isFinite(request.expiresAt) || request.expiresAt <= now
    || !Number.isFinite(request.armedAt) || request.armedAt > now + 5_000
    || request.work?.cliSessionID !== state.sessionID || request.work?.version !== 1) return undefined
  return request
}

// A switch's continuation is on its way to this runtime: the request for this conversation waits to
// be armed here, or is armed here and not claimed yet.
async function switchPending($, state) {
  if (!state.enabled) return false
  const sessionID = state.sessionID ?? await $.session.id()
  if (!SAFE_ID.test(sessionID ?? '')) return false
  const active = await readJSON($, `${folder(state)}/active.json`)
  const request = await readJSON($, `${folder(state)}/requests/${sessionID}.json`)
  if (active?.version !== 1 || (active.ready !== true && active.launchPrepared !== true) || request?.version !== 1
    || request.requiredCapability !== 'native-recovery-v6' || request.runtimeError != null
    || request.sourceUserStopped === true || !SAFE_ID.test(request.requestID ?? '')
    || active.operationID !== request.operationID || request.sessionID !== sessionID
    || !Number.isFinite(request.expiresAt) || request.expiresAt <= await $.clock.now()
    || state.handled.has(request.requestID) || await $.fs.exists(`${folder(state)}/results/${request.requestID}.json`)) return false
  return request.phase === 'prepared' || (request.phase === 'armed' && request.instanceID === state.instanceID)
}

// CC-Relay started this conversation only for its comment watch: Desktop's own continue that
// follows the start asks for no model turn. Its note counts once, for the start it explains.
async function watchReopen($, state) {
  if (!state.enabled) return false
  if (state.watchReopen === undefined) {
    state.watchReopen = null
    const sessionID = state.sessionID ?? await $.session.id()
    if (!SAFE_ID.test(sessionID ?? '')) return false
    const path = `${folder(state)}/watch-reopen/${sessionID}.json`
    const note = await readJSON($, path)
    const now = await $.clock.now()
    if (note?.version !== 1 || note.sessionID !== sessionID || note.used === true
      || !Number.isFinite(note.until) || note.until <= now) return false
    // Left for another account, it waits for that one. A Claude CC-Relay just started is not listed
    // yet: with the account unknown, the note stands for it.
    const own = typeof note.account === 'string' ? await ownAccount($, state) : undefined
    if (own !== undefined && own !== note.account) return false
    await $.fs.write(path, JSON.stringify({ ...note, used: true }))
    state.watchReopen = { until: now + HOST_RESUME_WAIT_MS }
    // The account it was started in, whose own kept watch it picks up again.
    if (typeof note.account === 'string') state.account = note.account
  }
  return state.watchReopen !== null && await $.clock.now() < state.watchReopen.until
}

// Claude's own continue, held for a switch's continuation, goes out after all when that will not
// come: nothing claimed it within the wait, or the continuation ended without a prompt of its own.
async function releaseResume($, state) {
  const held = state.heldResume
  // The continuation took its place, or the person's own words did.
  if (state.recovery?.mainSubmitted || state.userEpoch !== held.epoch
    || (state.recovery && !state.recovery.request.sourceWasBusy && !state.recovery.request.work.needsContinuation)) {
    state.heldResume = undefined; return
  }
  if (!state.recovery && await $.clock.now() < held.until && await switchPending($, state)) return
  state.heldResume = undefined
  const result = await $.prompt.submit({ text: held.text })
  // The conversation goes on from here: a continuation claimed later gives way.
  if (result && !result.drop) state.hostResumed = true
}

// The person stopped the continuation or wrote something newer: it gives way, which is no failure.
function personTookOver(state, recovery) {
  return state.userStopped || recovery.superseded || state.userEpoch !== recovery.userEpoch
}

async function current($, state, recovery) {
  // What the person did is known here already; the ticket is read only while it can matter.
  if (personTookOver(state, recovery)) return false
  const request = await ticket($, state)
  return request?.sourceUserStopped !== true
    && request?.requestID === recovery.request.requestID
    && request.operationID === recovery.request.operationID
}

// The person took over. A continuation still under way gives way to them; one whose turn is over
// keeps its result, and a comment watch it was still confirming is not waited for. The receipt
// says so either way, and the worker then attaches nothing more for it.
async function giveWay($, state, recovery, error) {
  recovery.result.revoked = true
  if (recovery.result.status === 'waiting' && (recovery.mainEnded || !recovery.mainSubmitted)) {
    recovery.waiting = false
    return save($, state, recovery, recovery.mainSubmitted ? 'turnFinished' : 'inspected')
  }
  return FINAL.has(recovery.result.status) ? save($, state, recovery) : save($, state, recovery, 'yielded', error)
}

// A continuation that lost its authorization: given way when the person caused it, otherwise a
// problem to look at.
async function revoked($, state, recovery, error) {
  return personTookOver(state, recovery) ? giveWay($, state, recovery, error) : save($, state, recovery, 'needsAttention', error)
}

async function save($, state, recovery, status, error) {
  if (status === 'needsAttention') recovery.attention = true
  if (status === 'yielded') recovery.yielded = true
  if (status) recovery.result.status = recovery.attention ? 'needsAttention'
    : recovery.yielded ? 'yielded'
      // A final receipt stays final; what its tasks do afterwards is recorded beside it.
      : FINAL.has(recovery.result.status) && ['queued', 'executing'].includes(status) ? recovery.result.status
        : status === 'turnFinished' && recovery.waiting ? 'waiting'
          : status === 'queued' && recovery.result.status === 'executing' ? 'executing'
            : status === 'queued' && recovery.result.evidence.some(item => EXECUTION_OUTCOMES.has(item.outcome)) ? 'executing' : status
  if (error) recovery.result.error = reason(error)
  recovery.result.updatedAt = await $.clock.now()
  try {
    const encoded = encodeResult(recovery.result)
    if (encoded.truncated) { recovery.attention = true; recovery.result.status = 'needsAttention'; recovery.result.error = encoded.error }
    await $.fs.write(`${folder(state)}/results/${recovery.request.requestID}.json`, encoded.text)
    return true
  } catch (failure) { state.lastError = reason(failure); return false }
}

async function evidence($, state, recovery, tool, outcome, fields = {}) {
  const kept = recovery.result.evidence
  kept.push({ tool, outcome, timestamp: await $.clock.now(), ...fields })
  if (kept.length > MAX_EVIDENCE) {
    const dropped = kept.splice(0, kept.length - MAX_EVIDENCE)
    // That a step worked outlives the details: the latest one that did takes the oldest place left.
    const worked = dropped.filter(item => EXECUTION_OUTCOMES.has(item.outcome)).pop()
    if (worked && !kept.some(item => EXECUTION_OUTCOMES.has(item.outcome))) kept.splice(0, 1, worked)
  }
  await save($, state, recovery)
}

function uses(messages) { return Array.isArray(messages) ? messages.flatMap(row => Array.isArray(row.toolUses) ? row.toolUses : []) : [] }
function stoppedIn(messages, id) {
  return uses(messages).some(use => use.tool === 'TaskStop' && !use.isError
    && (use.result !== undefined || use.text !== undefined)
    && [use.input?.task_id, use.input?.shell_id].includes(id))
}
function completedIn(messages, id) {
  return uses(messages).some(use => use.tool === 'Agent' && (use.agentId ?? use.result?.agentId) === id
    && !use.isError && use.result?.status === 'completed')
}
function failure(result) {
  if (!result || result.deny) return result?.deny ?? 'The native tool returned no result.'
  if (result.isError) return result.text ?? 'The native tool returned an error.'
  return undefined
}

function explicitlyStopped(state, task) {
  return [task.id, task.sourceTaskID, task.newTaskID, task.agentID, ...(task.aliases ?? [])]
    .some(id => id && state.explicitStops.has(id))
}

// Only inspect the host notification envelope, never XML-looking text inside a task's output.
function nativeTaskNotice(text) {
  if (typeof text !== 'string') return undefined
  let rest = text.slice(0, 8192).trimStart()
  if (!rest.startsWith('<task-notification>')) return undefined
  rest = rest.slice('<task-notification>'.length).trimStart()
  let id, status
  for (let field = 0; field < 8; field += 1) {
    const match = /^<([a-z-]+)>([^<>]*)<\/\1>\s*/.exec(rest)
    // Everything after the header is task output. IDs nested in it cannot establish ownership.
    if (!match || !['task-id', 'tool-use-id', 'output-file', 'status'].includes(match[1])) {
      return id && /^(?:<(?:summary|result|output|event)>|<\/task-notification>)/.test(rest) ? { id, status } : undefined
    }
    if (match[1] === 'task-id') {
      if (id !== undefined || !SAFE_ID.test(match[2])) return undefined
      id = match[2]
    }
    if (match[1] === 'status') {
      if (status !== undefined) return undefined
      status = match[2]
    }
    rest = rest.slice(match[0].length)
  }
  return undefined
}

async function recoverAgents($, state, recovery, tools, messages) {
  const work = recovery.request.work
  if (!work.branchComplete) return
  if (!tools.has('SendMessage')) {
    if (recovery.result.tasks.some(task => task.kind === 'monitor' && task.agentID)) await save($, state, recovery, 'needsAttention', 'The native tool needed to deliver monitor data to its original agent is unavailable.')
    return
  }
  let agents
  try { agents = await $.agent.list() } catch (error) {
    await evidence($, state, recovery, 'agent.list', 'unavailable'); return
  }
  const seen = new Set()
  const commandOwners = new Set(recovery.result.tasks.filter(task => task.jobID && task.agentID && task.newTaskID
    && !['blocked', 'stopped', 'expired'].includes(task.status)).map(task => task.agentID))
  const windowStart = work.latestUser?.sourceLine ?? 0
  const candidates = (work.tasks ?? []).filter(task => {
    if (task.kind !== 'agent' || seen.has(task.id) || !['backgroundRegistered', 'interrupted'].includes(task.state)
      || task.id === task.toolUseID || !SAFE_ID.test(task.id ?? '')
      || ['Explore', 'Plan', 'teammate'].includes(task.agentType)) return false
    if (Math.max(task.sourceLine ?? 0, task.resultLine ?? 0) < windowStart
      && !recovery.request.sourceActiveTasks?.some(live => live.kind === 'agent' && live.id === task.id)
      && !commandOwners.has(task.id)) return false
    seen.add(task.id)
    return true
  })
  if (candidates.length > 64) await evidence($, state, recovery, 'Agent', 'remainingNeedInspection')
  for (const task of candidates.slice(-64)) {
    if (!await current($, state, recovery)) return
    const agent = agents.find(item => item.id === task.id)
    if (agent?.teammateId || agent?.type === 'teammate') {
      await evidence($, state, recovery, 'Agent', 'inspectInMainConversation', { agentID: task.id }); continue
    }
    if (agent?.status === 'completed' || state.completedAgents.has(task.id) || state.explicitStops.has(task.id)
      || completedIn(messages, task.id) || stoppedIn(messages, task.id)) {
      await evidence($, state, recovery, 'Agent', 'completedOrExplicitlyStopped', { agentID: task.id }); continue
    }
    if (agent?.status === 'running') {
      recovery.acceptedAgents.add(task.id)
      await evidence($, state, recovery, 'Agent', 'alreadyRunning', { agentID: task.id }); continue
    }
    if (agent?.status === 'waiting') {
      await evidence($, state, recovery, 'Agent', 'needsUserInput', { agentID: task.id }); continue
    }
    if ((agent && !['pending', 'idle', 'killed', 'failed'].includes(agent.status))
      || (state.agentFailures.get(task.id) ?? 0) >= recovery.request.armedAt) continue
    let history
    try { history = await $.session.messages({ agentId: task.id }) } catch { history = undefined }
    if (!Array.isArray(history) || history.length === 0 || stoppedIn(history, task.id)) {
      await evidence($, state, recovery, 'Agent', 'historyUnavailable', { agentID: task.id }); continue
    }
    if (!await current($, state, recovery)) return
    // agent.list is a live roster, not an archive. An absent id can still have a resumable native
    // transcript. A real completion notice delivered while that transcript was read wins.
    const freshMessages = await $.session.messages()
    if (!await current($, state, recovery)) return
    if (state.completedAgents.has(task.id) || state.explicitStops.has(task.id) || stoppedIn(freshMessages, task.id)
      || completedIn(freshMessages, task.id) || (state.agentFailures.get(task.id) ?? 0) >= recovery.request.armedAt) continue
    // Persist the attempted id before the call too. A crash or failed write cannot lead to a retry.
    recovery.resumedAgents.add(task.id)
    if (!await evidenceBefore($, state, recovery, 'SendMessage', 'attempting', { agentID: task.id })) return
    if (!await current($, state, recovery) || state.explicitStops.has(task.id) || state.completedAgents.has(task.id)) return
    state.issuedAgentPrompts.add(`${recovery.request.requestID}:${task.id}`)
    state.automaticAgentRequests.set(task.id, recovery.request.requestID)
    const result = await $.tool.call({ tool: 'SendMessage', to: task.id,
      message: `${marker(recovery.request)} 本次账号切换打断了你原有的未完成任务。请使用本 agent 的已保存历史从中断处继续；先核验既有工具结果，避免重复副作用，不另建替代代理。已直接接回的工作请使用新 task ID，不再重启：${JSON.stringify(recovery.result.tasks.filter(item => item.agentID === task.id))}`,
      summary: '接续本次账号切换中断的原子任务',
    })
    const rejected = failure(result) || result.result?.success === false
    await evidence($, state, recovery, 'SendMessage', rejected ? 'blocked' : 'returnedAwaitingAgentProgress', { agentID: task.id })
    if (rejected) await save($, state, recovery, 'needsAttention', 'An original agent could not be continued; inspect its native result before any retry.')
    else { recovery.acceptedAgents.add(task.id); await drainMonitorEvents($, state, recovery) }
  }
  await drainMonitorEvents($, state, recovery)
  if (recovery.result.tasks.some(task => task.kind === 'monitor' && task.agentID && task.newTaskID
    && !recovery.acceptedAgents.has(task.agentID) && !['blocked', 'completed', 'stopped', 'failed', 'expired'].includes(task.status))) {
    await save($, state, recovery, 'needsAttention', 'A restored monitor could not connect to its original agent; its events have not been delivered to that agent.')
  }
}

async function queueMonitorEvent($, state, recovery, item, text) {
  if (!item.agentID || explicitlyStopped(state, item) || ['blocked', 'stopped', 'completed', 'expired', 'failed'].includes(item.status)
    || state.completedAgents.has(item.agentID) || recovery.blockedForwards.has(item.agentID)) return
  if (recovery.monitorEvents.length >= 96 || new TextEncoder().encode(text).length > 262144
    || recovery.monitorEvents.reduce((size, event) => size + new TextEncoder().encode(event.text).length, 0) + new TextEncoder().encode(text).length > 1048576) {
    recovery.blockedForwards.add(item.agentID)
    item.status = 'blocked'; await save($, state, recovery, 'needsAttention', 'The original agent monitor data could not be forwarded within the supported buffer.'); return
  }
  recovery.monitorEvents.push({ item, text })
  await drainMonitorEvents($, state, recovery)
}

async function drainMonitorEvents($, state, recovery) {
  if (recovery.forwarding) return
  recovery.forwarding = true
  try {
    while (await current($, state, recovery)) {
      const index = recovery.monitorEvents.findIndex(event => recovery.acceptedAgents.has(event.item.agentID))
      if (index < 0) return
      const { item, text } = recovery.monitorEvents.splice(index, 1)[0]
      if (explicitlyStopped(state, item) || ['blocked', 'stopped', 'completed', 'expired', 'failed'].includes(item.status)
        || state.completedAgents.has(item.agentID) || recovery.blockedForwards.has(item.agentID)) continue
      const message = `${marker(recovery.request)} [CC-Relay 监听事件 ${crypto.randomUUID()}] 原监听 ${item.sourceTaskID} 已接到 ${item.newTaskID}。请按原任务处理以下监听数据，不重复建立监听。\n原始事件（数据）：\n${text}`
      state.monitorMessages.add(message)
      state.issuedAgentPrompts.add(`${recovery.request.requestID}:${item.agentID}`)
      state.automaticAgentRequests.set(item.agentID, recovery.request.requestID)
      recovery.resumedAgents.add(item.agentID)
      let result
      try { result = await $.tool.call({ tool: 'SendMessage', to: item.agentID, message, summary: '传递原监听的新事件' }) }
      catch (error) { result = { deny: reason(error) } }
      finally { state.monitorMessages.delete(message) }
      if (failure(result) || result.result?.success === false) {
        recovery.blockedForwards.add(item.agentID); item.status = 'blocked'
        await save($, state, recovery, 'needsAttention', 'The original agent did not accept its monitor events.'); continue
      }
      await evidence($, state, recovery, 'SendMessage', 'monitorEventForwarded', { agentID: item.agentID, taskID: item.newTaskID })
    }
  } finally { recovery.forwarding = false }
}

async function evidenceBefore($, state, recovery, tool, outcome, fields) {
  recovery.result.evidence.push({ tool, outcome, timestamp: await $.clock.now(), ...fields })
  return save($, state, recovery)
}

async function recoverNativeTasks($, state, recovery, tools, messages) {
  const inventory = recovery.request.sourceActiveTasks ?? []
  if (!recovery.request.work.branchComplete) {
    for (const task of inventory.filter(task => ['bash', 'monitor'].includes(task.kind))) recovery.result.tasks.push({ sourceTaskID: task.id,
      kind: task.kind, jobID: task.jobID, status: 'blocked', executionVerified: false, error: 'The original conversation branch cannot be verified.' })
    if (recovery.result.tasks.length) await save($, state, recovery, 'needsAttention', 'The original conversation branch cannot be verified. No background task was guessed or replayed.')
    return
  }
  const seen = new Set()
  for (const task of inventory) {
    if (!['bash', 'monitor'].includes(task.kind) || !SAFE_ID.test(task.id ?? '') || seen.has(task.id)) continue
    seen.add(task.id)
    const item = { sourceTaskID: task.id, kind: task.kind, jobID: task.jobID, agentID: task.agentID,
      aliases: task.aliases, deadlineAt: task.deadlineAt, status: 'checking', executionVerified: false, eventObserved: false }
    recovery.result.tasks.push(item)
    try {
      if (!await current($, state, recovery)) return
      if (explicitlyStopped(state, task) || stoppedIn(messages, task.id)) { item.status = 'stopped'; continue }
      const captured = (recovery.request.work.tasks ?? []).find(old => old.id === task.id && old.kind === task.kind)
      if (captured?.state === 'completed') { item.status = 'completedBeforeSwitch'; continue }
      if (task.kind === 'monitor' && Number.isFinite(task.deadlineAt) && task.deadlineAt <= await $.clock.now()) { item.status = 'expired'; state.explicitStops.add(task.id); continue }
      let input
      if (task.jobID) {
        const attached = await commandAttachment($, state, recovery, task)
        if (attached.error) { item.status = 'blocked'; item.error = attached.error; await save($, state, recovery, 'needsAttention', attached.error); continue }
        // A TaskStop may arrive while the native attachment waits for permission/result.
        // Keep its original IDs bound to the real body before entering that wait.
        for (const oldID of [task.id, ...(task.aliases ?? [])]) if (SAFE_ID.test(oldID)) state.commandAliases.set(oldID, task.jobID)
        state.commandJobs.set(task.jobID, { ...task })
        if (task.kind === 'bash') input = { tool: 'Bash', command: attached.command, run_in_background: true, description: '接回原后台命令的执行进程和输出' }
        else {
          const left = Math.floor((task.deadlineAt ?? 0) - await $.clock.now())
          if (left <= 0) { item.status = 'expired'; state.explicitStops.add(task.id); continue }
          input = { tool: 'Monitor', command: attached.command, description: '接回原命令监听的实时输出', timeout_ms: left }
        }
        item.workerPID = attached.record.worker?.pid; item.childPID = attached.record.child?.pid
        item.outputDirectory = attached.directory
      } else if (task.kind === 'monitor') {
        const history = task.agentID ? await $.session.messages({ agentId: task.agentID }) : messages
        const calls = uses(history).filter(use => use.tool === 'Monitor' && use.tool_use_id === task.toolUseID && !use.isError)
        let original = calls.length === 1 ? calls[0].input : undefined
        // A resumed compacted session omits summarized calls; session.messages is also bounded.
        // The worker streams the original file and verifies the selected branch and native ID.
        if (calls.length === 0 && await worker($, state) && await current($, state, recovery)) {
          const resolved = await $.process.run([state.workerPath, 'monitor-input',
            `${folder(state)}/requests/${state.sessionID}.json`, recovery.request.requestID, task.id])
          if (resolved?.exitCode === 0) {
            try { original = JSON.parse(resolved.stdout) } catch { /* unverified input stays blocked */ }
          }
        }
        const left = Math.floor((task.deadlineAt ?? 0) - await $.clock.now())
        if (left <= 0 && task.deadlineAt !== undefined) { item.status = 'expired'; state.explicitStops.add(task.id); continue }
        if (original?.command !== undefined && original?.ws === undefined) { item.status = 'interrupted'; item.error = UNPROTECTED; continue }
        if (!original?.ws || typeof original.ws.url !== 'string' || !/^wss?:\/\//.test(original.ws.url)
          || original.command !== undefined || !Number.isFinite(left) || left <= 0) {
          item.status = 'interrupted'; item.error = 'Its original parameters or remaining time could not be verified, so it was not recreated. Check whether it is still needed.'; continue
        }
        input = { tool: 'Monitor', ws: original.ws, description: original.description, timeout_ms: left }
        state.monitorSignatures.set(task.id, JSON.stringify({ ws: original.ws }))
      } else { item.status = 'interrupted'; item.error = UNPROTECTED; continue }
      if (!tools.has(input.tool)) { item.status = 'blocked'; await save($, state, recovery, 'needsAttention', 'A native recovery tool is unavailable.'); continue }
      item.status = 'attempting'
      // One durable attempt per source task before its real tool call, including permission waits.
      if (!await save($, state, recovery) || !await current($, state, recovery)) return
      const latest = await $.session.messages()
      if (!await current($, state, recovery) || explicitlyStopped(state, task) || stoppedIn(latest, task.id)) { item.status = 'stopped'; continue }
      if (input.tool === 'Monitor') state.registeringMonitors += 1
      let result
      try { result = await $.tool.call(input) }
      finally { if (input.tool === 'Monitor') state.registeringMonitors -= 1 }
      const expired = task.kind === 'monitor' && task.deadlineAt <= await $.clock.now()
      const cancelled = explicitlyStopped(state, task)
      if (!await current($, state, recovery) || expired || cancelled) {
        const id = result?.result?.taskId ?? result?.result?.backgroundTaskId
        if (SAFE_ID.test(id ?? '')) {
          item.newTaskID = id
          const stopped = await $.tool.call({ tool: 'TaskStop', task_id: id })
          if (failure(stopped)) { item.status = 'blocked'; await save($, state, recovery, 'needsAttention', 'A late monitor registration could not be stopped after its deadline or authorization expired.') }
          state.explicitStops.add(id); state.activeTasks.delete(id)
        }
        if (!expired && !cancelled) return
        if (item.status !== 'blocked') item.status = cancelled ? 'stopped' : 'expired'
        state.explicitStops.add(task.id); continue
      }
      if (failure(result)) { item.status = 'blocked'; item.error = reason(failure(result)); await save($, state, recovery, 'needsAttention', item.error); continue }
      const id = result.result?.taskId ?? result.result?.backgroundTaskId
      item.newTaskID = SAFE_ID.test(id ?? '') ? id : undefined
      item.status = task.jobID ? 'awaitingWorker' : 'registered'
      if (!task.jobID && item.newTaskID) item.registeredAt = await inventoryTime($, state)
      item.checkUntil = await $.clock.now() + 15000
      if (item.newTaskID) {
        for (const oldID of [task.id, ...(task.aliases ?? [])]) if (SAFE_ID.test(oldID)) state.taskAliases.set(oldID, item.newTaskID)
        if (!state.completedAgents.has(item.newTaskID) && !state.agentFailures.has(item.newTaskID)) state.activeTasks.set(item.newTaskID,
          { ...task, id: item.newTaskID, registeredAt: item.registeredAt, aliases: [...new Set([task.id, ...(task.aliases ?? [])])] })
        if (task.jobID) {
          state.commandAliases.set(item.newTaskID, task.jobID)
          state.commandJobs.set(task.jobID, { ...task, id: item.newTaskID })
        }
        if (task.kind === 'monitor') recovery.monitorIDs.add(item.newTaskID)
      }
      if (task.kind === 'monitor' && !task.jobID && item.newTaskID) {
        const notice = state.taskNotices.get(item.newTaskID)
        if (notice && notice.at >= recovery.request.armedAt) {
          if (['failed', 'stopped', 'cancelled', 'killed', 'expired', 'timeout', 'completed'].includes(notice.status)) {
            item.status = notice.status
            if (notice.status === 'failed') await save($, state, recovery, 'needsAttention', 'The recreated monitor reported failure before registration settled.')
          } else if (notice.accepted) {
            item.eventObserved = true; item.executionVerified = true; item.status = 'listening'
            recovery.observedMonitors.add(item.newTaskID)
            await evidence($, state, recovery, 'Monitor', 'monitorEventObserved', { taskID: item.newTaskID })
          }
        }
      }
      if (task.kind === 'monitor' && !item.newTaskID) { item.status = 'blocked'; await save($, state, recovery, 'needsAttention', 'The original monitor returned no registration identity.'); continue }
      if (task.kind === 'monitor' && item.agentID) {
        if (state.monitorOverflowIDs.has(item.newTaskID)) {
          item.status = 'blocked'; recovery.blockedForwards.add(item.agentID)
          await save($, state, recovery, 'needsAttention', 'Early monitor data exceeded the supported buffer before its native identity was returned.')
        }
        const early = state.earlyMonitorEvents.filter(event => event.id === item.newTaskID)
        state.earlyMonitorEvents = state.earlyMonitorEvents.filter(event => event.id !== item.newTaskID)
        for (const event of early) await queueMonitorEvent($, state, recovery, item, event.text)
      }
      await report($, state)
      await evidence($, state, recovery, input.tool, task.jobID ? 'commandClientAttached' : 'monitorRegistered', { taskID: item.newTaskID })
    } catch (error) { item.status = 'blocked'; item.error = reason(error); await save($, state, recovery, 'needsAttention', error) }
  }
  state.earlyMonitorEvents = []; state.monitorOverflowIDs.clear()
  const covered = new Set(inventory.map(task => task.toolUseID).filter(Boolean))
  const coveredTasks = new Set(inventory.flatMap(task => [task.id, ...(task.aliases ?? [])]))
  const window = recovery.request.work.latestUser?.sourceLine ?? 0
  const uncovered = (recovery.request.work.tasks ?? []).filter(task => ['bash', 'monitor'].includes(task.kind)
    && ['requested', 'backgroundRegistered', 'interrupted', 'unknown'].includes(task.state)
    && Math.max(task.sourceLine ?? 0, task.resultLine ?? 0) >= window && !covered.has(task.toolUseID) && !coveredTasks.has(task.id))
  for (const task of uncovered) {
    recovery.result.tasks.push({ sourceTaskID: task.id, kind: task.kind, status: 'interrupted', executionVerified: false,
      error: 'It was not in the live task list before the switch; if it was still running, it stopped with the switch. Check its output before starting it again.' })
  }
  await verifyNativeTasks($, state, recovery)
}

async function verifyNativeTasks($, state, recovery) {
  if (!await current($, state, recovery)) return
  for (const item of recovery.result.tasks ?? []) {
    if (item.kind === 'monitor' && !item.jobID && item.newTaskID && item.deadlineAt <= await $.clock.now()
      && !['blocked', 'completed', 'failed', 'stopped', 'expired', 'timeout', 'cancelled', 'killed'].includes(item.status)) {
      const stopped = await $.tool.call({ tool: 'TaskStop', task_id: item.newTaskID })
      item.status = failure(stopped) ? 'blocked' : 'expired'
      state.explicitStops.add(item.newTaskID); state.activeTasks.delete(item.newTaskID)
      await save($, state, recovery, failure(stopped) ? 'needsAttention' : undefined,
        failure(stopped) ? 'The original monitor deadline ended but its native stop could not be confirmed.' : undefined)
    }
    if (!item.jobID || ['blocked', 'stopped', 'expired', 'completed', 'failed'].includes(item.status)) continue
    const record = await inspectCommand($, state, item.jobID)
    if (!await current($, state, recovery)) return
    if (record?.status === 'attention') {
      item.status = 'blocked'; await save($, state, recovery, 'needsAttention', 'The original command lost its execution worker. Its old command will not be replayed.'); continue
    }
    if (record?.status === 'finalizing' || record?.status === 'starting') {
      if (await $.clock.now() > item.checkUntil) { item.status = 'blocked'; await save($, state, recovery, 'needsAttention', 'The original command did not produce a verifiable final state.') }
      continue
    }
    const adopted = record?.owner?.pid === state.pid && (!Number.isFinite(recovery.request.runtimeStartedAt)
      || Math.abs(record.owner.start - recovery.request.runtimeStartedAt) < 0.01)
    if (record && (adopted || ['completed', 'failed'].includes(record.status))) {
      item.workerPID = record.worker?.pid; item.childPID = record.child?.pid
      item.exitCode = record.exitCode
      const before = item.executionVerified
      item.executionVerified = ['running', 'completed', 'failed'].includes(record.status)
      item.status = record.status === 'running' ? 'running' : record.status
      if (['completed', 'failed'].includes(record.status)) {
        for (const [id, task] of state.activeTasks) if (task.jobID === item.jobID) state.activeTasks.delete(id)
      }
      if (!before && item.executionVerified) await evidence($, state, recovery, 'Bash', 'originalCommandExecutionVerified', { taskID: item.newTaskID })
      // However the command ends, by itself, by a stop or at its deadline, that is its own result:
      // the continuation kept it running and attached, which was its part.
      if (['failed', 'stopped', 'expired'].includes(record.status)) await save($, state, recovery)
      else if (item.executionVerified) await save($, state, recovery, 'executing')
    } else if (await $.clock.now() > item.checkUntil) {
      item.status = 'blocked'; await save($, state, recovery, 'needsAttention', 'The original command worker did not confirm this target instance. No command was replayed.')
    }
  }
}

// This conversation's watches kept for the account that published their pages, which no other
// account can open, by that account. CC-Relay starts the conversation for them when it opens it.
async function keptWatches($, state) {
  const kept = new Map(), now = await $.clock.now(), directory = `${folder(state)}/left-watches`
  for (const entry of await $.fs.list(directory).catch(() => [])) {
    if (entry.kind !== 'file' || !entry.name.endsWith('.json')) continue
    const watches = await readJSON($, `${directory}/${entry.name}`)
    for (const watch of Array.isArray(watches) ? watches : []) {
      if (watch?.sessionID !== state.sessionID || !(now - watch.leftAt < KEPT_WATCH_MS)) continue
      const account = entry.name.slice(0, -'.json'.length), pages = kept.get(account) ?? { all: false, keys: new Set() }
      // An older record names no pages: it keeps every watch of the conversation.
      if (!Array.isArray(watch.pages)) pages.all = true
      else for (const page of watch.pages) { const key = artifactKey(page); if (key) pages.keys.add(key) }
      kept.set(account, pages)
    }
  }
  return kept
}

// Whether an armed watch is kept for another account than `own`, the one this runtime is open on,
// which watches its own pages again. With that unknown, every kept watch stays where it is.
function keptElsewhere(kept, own) {
  const elsewhere = [...kept].filter(([account]) => account !== own).map(([, pages]) => pages)
  return item => item.state === 'armed' && elsewhere.some(pages => pages.all || pages.keys.has(artifactKey(item.url)))
}

// The account this runtime's Claude is open on. CC-Relay lists each open Claude by its PID and
// start, as the process list shows them; the one this runtime runs under is among its parents.
async function ownAccount($, state) {
  const open = await readJSON($, `${folder(state)}/open-accounts.json`)
  if (!Array.isArray(open) || !open.length || !state.pid) return undefined
  const listed = await $.process.run(['/usr/bin/env', 'TZ=UTC', 'LC_ALL=C', '/bin/ps', '-x', '-o', 'pid=,ppid=,lstart='])
    .catch(() => undefined)
  if (listed?.exitCode !== 0) return undefined
  const processes = new Map()
  for (const line of String(listed.stdout).split('\n')) {
    const [pid, ppid, ...start] = line.trim().split(/\s+/)
    if (/^\d+$/.test(pid) && /^\d+$/.test(ppid)) processes.set(Number(pid), { ppid: Number(ppid), start: start.join(' ') })
  }
  for (let pid = state.pid, seen = new Set(); processes.has(pid) && !seen.has(pid); pid = processes.get(pid).ppid) {
    seen.add(pid)
    const claude = open.find(item => item?.pid === pid && typeof item.account === 'string'
      && String(item.procStart).trim().split(/\s+/).join(' ') === processes.get(pid).start)
    if (claude) return claude.account
  }
  return undefined
}

async function recoverArtifacts($, state, recovery, tools) {
  if (!(recovery.request.work.artifacts ?? []).some(item => item.state === 'armed')) return
  const elsewhere = keptElsewhere(await keptWatches($, state), recovery.request.targetProfile)
  recovery.keptWatches = [...new Set(recovery.request.work.artifacts.filter(elsewhere).map(item => item.url))]
  if (recovery.keptWatches.length) await evidence($, state, recovery, 'ArtifactComments', 'watchesStayed')
  const artifacts = recovery.request.work.artifacts.filter(item => !elsewhere(item))
  if (!artifacts.some(item => item.state === 'armed')) return
  if (!recovery.request.work.branchComplete || !tools.has('ArtifactComments')) {
    await evidence($, state, recovery, 'ArtifactComments', 'unavailable')
    await save($, state, recovery, 'needsAttention', 'The original artifact subscription cannot be checked in this runtime.'); return
  }
  recovery.artifactRecovery = artifactRecovery(artifacts)
  await advanceSwitchArtifacts($, state, recovery)
}

async function advanceSwitchArtifacts($, state, recovery) {
  const artifacts = recovery.artifactRecovery
  if (!artifacts) return
  await advanceArtifacts($, artifacts, {
    current: () => current($, state, recovery),
    record: (outcome, metadata) => outcome.endsWith('Attempting')
      ? evidenceBefore($, state, recovery, 'ArtifactComments', outcome, metadata)
      : evidence($, state, recovery, 'ArtifactComments', outcome, metadata),
  })
  recovery.waiting = artifacts.waiting
  if (artifacts.error) await save($, state, recovery, 'needsAttention', artifacts.error)
}

async function verifyConnectingWatches($, state, recovery) {
  if (!recovery.waiting || !await current($, state, recovery)) return
  await advanceSwitchArtifacts($, state, recovery)
  if (!recovery.waiting) await save($, state, recovery,
    recovery.mainSubmitted ? recovery.mainEnded ? 'turnFinished' : recovery.boundTurn ? 'executing' : 'queued' : 'inspected')
}

// Startup recovery is intentionally independent of switch tickets. It only reads structured
// native intent, restores the same URLs, and never submits a model prompt or publishes an artifact.
async function saveArtifactStartup($, state, startup, status, error) {
  await $.fs.write(`${folder(state)}/artifacts/${state.sessionID}/${state.instanceID}.json`, JSON.stringify({
    version: 1, sessionID: state.sessionID, instanceID: state.instanceID, pid: state.pid, status,
    updatedAt: await $.clock.now(), artifacts: startup.recovery?.items ?? [], evidence: startup.evidence,
    readAttempts: startup.readAttempts ?? 0, error,
  }))
  if (status === 'needsAttention' && !startup.notified) {
    startup.notified = true
    $.ui.toast(`Artifact 评论续接需要处理：${reason(error ?? 'The native host did not confirm recovery.').slice(0, 180)}`, { timeoutMs: 10_000 })
  }
}

async function recoverReopenedArtifacts($, state) {
  let startup = state.artifactStartup
  if (!startup || await $.clock.now() < startup.after) return
  if (startup.done) {
    // The rest is done. A kept watch that may be this account's own gets another look at the account.
    const now = await $.clock.now()
    if (!startup.undecided?.length || startup.accountLooks >= ACCOUNT_LOOKS || now < startup.nextLook) return
    startup = state.artifactStartup = { after: now, done: false, evidence: [], accountLooks: (startup.accountLooks ?? 0) + 1,
      snapshot: { ...startup.snapshot, artifacts: startup.undecided } }
  }
  // Read the current intent once a normal startup turn is idle. A new instruction arriving
  // during recovery still yields, including while the original transcript is being retried.
  startup.epoch ??= state.userEpoch
  const currentStartup = async () => state.enabled && !state.userStopped && state.userEpoch === startup.epoch &&
    !state.recovery && !await switchPending($, state)
  if (!await currentStartup()) {
    startup.done = true
    if (startup.recovery || startup.readError) await saveArtifactStartup($, state, startup, 'yielded')
    return
  }
  if (!startup.recovery) {
    if (!startup.snapshot) {
      startup.readAttempts = (startup.readAttempts ?? 0) + 1
      try {
        const helper = await worker($, state)
        if (!helper) throw new Error('The artifact recovery worker is unavailable.')
        const input = await $.process.run([helper, 'artifact-input', state.sessionID])
        if (input?.exitCode !== 0) throw new Error(input?.stderr || 'The original artifact intent could not be read.')
        const read = JSON.parse(input.stdout)
        if (read.version !== 1 || read.sessionID !== state.sessionID || !Array.isArray(read.artifacts)) {
          throw new Error('The artifact recovery worker returned an invalid or mismatched session record.')
        }
        startup.snapshot = read
      } catch (error) {
        startup.readError = reason(error)
        startup.evidence.push({ outcome: 'intentReadFailed', error: startup.readError, at: await $.clock.now() })
        const yielded = !await currentStartup()
        startup.done = yielded || startup.readAttempts >= 3
        startup.after = await $.clock.now() + 10_000
        await saveArtifactStartup($, state, startup, yielded ? 'yielded' : startup.done ? 'needsAttention' : 'waiting', startup.readError)
        return
      }
      if (!await currentStartup()) {
        startup.done = true; await saveArtifactStartup($, state, startup, 'yielded'); return
      }
    }
    const snapshot = startup.snapshot
    const kept = await keptWatches($, state)
    if (kept.size) state.account ??= await ownAccount($, state)
    const elsewhere = keptElsewhere(kept, state.account)
    const artifacts = snapshot.artifacts.filter(item => !elsewhere(item))
    // With the account unknown, a kept watch may be this one's own.
    startup.undecided = state.account === undefined ? snapshot.artifacts.filter(elsewhere) : []
    startup.nextLook = await $.clock.now() + ACCOUNT_LOOK_MS
    if (!artifacts.some(item => item.state === 'armed') && !startup.readError) { startup.done = true; return }
    startup.readError = undefined
    startup.recovery = artifactRecovery(artifacts)
    if (artifacts.some(item => item.state === 'armed') && snapshot.branchComplete !== true) {
      startup.recovery.done = true
      startup.recovery.error = 'The original artifact intent could not be resolved on a complete native conversation branch.'
    }
  }
  if (!startup.recovery.done) {
    const tools = await $.tool.list()
    if (!tools.some(item => item.name === 'ArtifactComments')) {
      startup.recovery.done = true; startup.recovery.error = 'ArtifactComments is unavailable in this runtime.'
    } else await advanceArtifacts($, startup.recovery, {
      current: currentStartup,
      record: async (outcome, metadata) => { startup.evidence.push({ outcome, ...metadata, at: await $.clock.now() }) },
    })
  }
  const yielded = !await currentStartup()
  startup.done = yielded || startup.recovery.done
  const status = yielded ? 'yielded' : startup.recovery.error ? 'needsAttention' : !startup.done ? 'waiting'
    : startup.recovery.items.some(item => item.status === 'restored') ? 'restored' : 'inspected'
  await saveArtifactStartup($, state, startup, status, startup.recovery.error)
}

function continuationText(request) {
  return `${marker(request)}\n${CONTINUATION_TEXT}`
}

async function claim($, state, request) {
  const path = `${folder(state)}/results/${request.requestID}.json`
  if (state.handled.has(request.requestID) || await $.fs.exists(path)) return undefined
  state.handled.add(request.requestID)
  state.earlyMonitorEvents = []; state.monitorOverflowIDs.clear()
  const recovery = { request, resumedAgents: new Set(), agentTurns: new Map(), monitorIDs: new Set(),
    acceptedAgents: new Set(), blockedForwards: new Set(), monitorEvents: [], forwarding: false,
    observedMonitors: new Set(), boundTurn: undefined, userEpoch: state.userEpoch,
    superseded: state.userEpoch > 0 || state.hostResumed, attention: false, waiting: false,
    mainSubmitted: false, mainEnded: false, result: {
    version: 1, operationID: request.operationID, requestID: request.requestID, sessionID: state.sessionID, tasks: [],
    instanceID: state.instanceID, pid: state.pid, status: 'claimed', updatedAt: await $.clock.now(), evidence: [],
  } }
  if (!await save($, state, recovery)) return undefined
  const written = await readJSON($, path)
  if (written?.requestID !== request.requestID || written.instanceID !== state.instanceID || written.status !== 'claimed') return undefined
  return recovery
}

async function recover($, state, recovery) {
  try {
    if (recovery.superseded) {
      await giveWay($, state, recovery, 'A newer user instruction superseded this automatic continuation.'); return
    }
    if (recovery.request.sourceUserStopped === true) {
      await giveWay($, state, recovery, 'The source conversation was explicitly stopped before the switch.'); return
    }
    if (!await current($, state, recovery)) {
      await revoked($, state, recovery, 'Continuation was stopped or its switch authorization changed.'); return
    }
    const tools = new Set((await $.tool.list()).map(item => item.name))
    const messages = await $.session.messages()
    await recoverNativeTasks($, state, recovery, tools, messages)
    if (recovery.request.sourceWasBusy || recovery.request.work.needsContinuation) {
      await recoverAgents($, state, recovery, tools, messages)
    }
    await recoverArtifacts($, state, recovery, tools)
    if (!await current($, state, recovery)) return
    // Keep recovery details in the local receipt; the conversation receives a short continuation.
    if (recovery.result.tasks.some(item => item.status === 'blocked')) {
      await save($, state, recovery, 'needsAttention', 'Some original work could not be restored directly; see this recovery receipt.')
    }
    if (!recovery.request.sourceWasBusy && !recovery.request.work.needsContinuation) {
      await save($, state, recovery, recovery.waiting ? 'waiting' : 'inspected'); return
    }
    state.issuedPrompts.add(recovery.request.requestID)
    const result = await $.prompt.submit({ text: continuationText(recovery.request) })
    if (!result || typeof result.text !== 'string' || result.drop) {
      await save($, state, recovery, 'needsAttention', result?.drop ?? 'The continuation prompt was not accepted.'); return
    }
    recovery.mainSubmitted = true
    await evidence($, state, recovery, 'prompt.submit', 'parentPromptQueued')
    if (!recovery.boundTurn) await save($, state, recovery, 'queued')
  } catch (error) { await save($, state, recovery, 'needsAttention', error) }
}

async function tick($, state) {
  if (!state.enabled || state.ticking) return
  state.ticking = true
  try {
    if (!state.sessionID) return
    if (state.heldResume) await releaseResume($, state)
    const request = await ticket($, state)
    if (state.recovery && request?.requestID !== state.recovery.request.requestID) state.recovery = undefined
    if (state.recovery) {
      await verifyNativeTasks($, state, state.recovery)
      if (!state.busy && state.recovery.waiting) await verifyConnectingWatches($, state, state.recovery)
      return
    }
    if (state.busy) return
    if (!request) {
      if (!await switchPending($, state)) await recoverReopenedArtifacts($, state)
      return
    }
    const recovery = await claim($, state, request)
    if (!recovery) return
    state.recovery = recovery
    await recover($, state, recovery)
  } catch (error) { state.lastError = reason(error) } finally { state.ticking = false }
}

async function heartbeat($, state) {
  if (!state.enabled || state.reporting) return
  state.reporting = true
  try { await report($, state) } catch (error) { state.lastError = reason(error) }
  finally { state.reporting = false }
}

async function pause($, state) {
  state.userStopped = true
  try {
    if (state.recovery) await giveWay($, state, state.recovery, 'The user stopped the continuation; it will not be submitted again.')
    await report($, state)
  } catch (error) { state.lastError = reason(error) }
}

export function register(on) {
  const state = { instanceID: crypto.randomUUID(), enabled: false, busy: false, userStopped: false,
    ticking: false, reporting: false, timerStarted: false, pid: undefined, sessionID: undefined,
    handled: new Set(), agentFailures: new Map(), completedAgents: new Set(), explicitStops: new Set(),
    compactorAborts: new Set(), issuedPrompts: new Set(), userEpoch: 0, recovery: undefined,
    automaticTurns: new Map(), agentTurnIDs: new Map(), issuedAgentPrompts: new Set(), activeTasks: new Map(),
    automaticAgentRequests: new Map(), mainAutomaticRequestID: undefined,
    commandJobs: new Map(), commandAliases: new Map(), taskAliases: new Map(), workerChecks: new Map(), originalCommands: new Map(),
    taskNotices: new Map(), monitorSignatures: new Map(), monitorMessages: new Set(), earlyMonitorEvents: [], monitorOverflowIDs: new Set(), registeringMonitors: 0,
    blockedTurns: new Set(), compactorResumeRequestID: undefined, heldResume: undefined, hostResumed: false,
    watchReopen: undefined,
  }
  on('session.start', { isInteractive: false }, async ($, event, next) => {
    const result = await next(event)
    try {
      if (await $.env.get('CLAUDE_CODE_ENTRYPOINT') !== 'claude-desktop') return result
      const home = await $.env.get('HOME')
      if (typeof home !== 'string' || !home.startsWith('/')) return result
      state.home = home; state.enabled = true
      await configureCommands($, state)
      await heartbeat($, state)
      await watchReopen($, state)
      // Let the host's own resume finish first; an already connected, armed watch needs no call.
      state.artifactStartup = { after: await $.clock.now() + 10_000, done: false, evidence: [] }
      if (!state.timerStarted) {
        state.timerStarted = true
        $.clock.every(HEARTBEAT_MS, () => heartbeat($, state))
        $.clock.every(TICK_MS, () => tick($, state))
      }
      await tick($, state)
    } catch (error) { state.lastError = reason(error) }
    return result
  })
  on('session.end', async ($, event, next) => { state.enabled = false; state.recovery = undefined; return next(event) })
  // StopFailure is the host's typed API error, not a message that happens to mention a limit.
  // Do not switch for authentication, overloaded servers, network failures or arbitrary HTTP 429s.
  on('classic.StopFailure', { error: 'rate_limit' }, async ($, event, next) => {
    const result = await next(event)
    if (!state.enabled || state.userStopped || event.session_id !== state.sessionID) return result
    try {
      const now = await $.clock.now()
      state.rateLimitFailure = { reason: 'rateLimit', observedAt: now, until: now + 600_000 }
      await heartbeat($, state)
    } catch (error) { state.lastError = reason(error) }
    return result
  })
  on('classic.StopFailure', { error: 'account_on_hold' }, ($, event, next) => accountStopped($, state, event, next))
  on('classic.StopFailure', { error: 'oauth_org_not_allowed' }, ($, event, next) => accountStopped($, state, event, next))
  on('session.measure', async ($, event, next) => {
    const result = await next(event)
    if (state.enabled) await heartbeat($, state)
    return result
  })
  on('classic.Stop', async ($, event, next) => {
    await observeHostWork($, state, event)
    return next(event)
  })
  on('classic.SubagentStop', async ($, event, next) => {
    await observeHostWork($, state, event)
    return next(event)
  })
  // The compactor hooks every prompt too, and Claude Code takes a second hook of one event from a
  // plugin only under a matcher: this one matches every prompt and runs inside the compactor's.
  on('prompt.submit', { text: /[\s\S]*/ }, async ($, event, next) => {
    // Claude's own continue after a quit is not the person's words. While a switch's continuation is
    // on its way, it is held back for that one.
    const notice = event.origin?.kind === 'task-notification' ? nativeTaskNotice(event.text) : undefined
    const resume = USER_ORIGINS.has(event.origin?.kind) && hostResume(event.text)
    if (resume) {
      try {
        // An idle handoff may warm its CLI solely to restore watches/tasks. If its claim has
        // already finished, the native wakeup still must not turn into an extra model request.
        if (state.recovery && !state.recovery.request.sourceWasBusy && !state.recovery.request.work.needsContinuation
          && await current($, state, state.recovery)) return { drop: 'CC-Relay 已接回空闲会话的监听，无需额外对话。' }
        if (await switchPending($, state)) {
          state.heldResume = { text: event.text, epoch: state.userEpoch, until: await $.clock.now() + HOST_RESUME_WAIT_MS }
          return { drop: 'CC-Relay 的续跑会接着做切换前的工作。' }
        }
        if (await watchReopen($, state)) {
          state.watchReopen = null
          return { drop: 'CC-Relay 重新打开这段会话只为接回评论监听，无需额外对话。' }
        }
      } catch (error) { state.lastError = reason(error) }
    }
    const human = USER_ORIGINS.has(event.origin?.kind) && !resume
    if (human) {
      state.userEpoch += 1
      if (state.recovery) { state.recovery.superseded = true; state.recovery.result.revoked = true }
    }
    let result = await next(event)
    if (event.origin?.kind === 'plugin' && event.origin.name === 'cc-relay'
      && state.compactorResumeRequestID && result && typeof result.text === 'string' && !result.drop) {
      // Provenance and the exact paused turn establish this relationship, not the wording.
      // Keep the marker even if a new instruction/generation superseded it: its own stale
      // turn will then be cancelled and blocked, rather than resuming anonymously.
      const requestID = state.compactorResumeRequestID
      state.compactorResumeRequestID = undefined
      state.issuedPrompts.add(requestID)
      const tag = marker({ requestID })
      if (!result.text.startsWith(tag)) result = { ...result, text: `${tag}\n${result.text}` }
    }
    if (human && result && !result.drop) state.userStopped = false
    const recovery = state.recovery
    try {
      if (human && recovery) {
        // Sent over the continuation's own turn, queued to wait or a command too: that turn stops now,
        // and the person's words run in a turn of their own. Left running, its tools would be blocked.
        const running = recovery.boundTurn !== undefined && recovery.boundTurn === state.mainTurnID ? recovery.boundTurn : undefined
        if (running && result && !result.drop) {
          // Unbound first: this stop is not the compactor's pause, which resumes the same continuation.
          recovery.boundTurn = undefined
          state.blockedTurns.add(running); state.compactorAborts.add(running)
          try { await $.turn.abort({ turnId: running }) } catch (error) { state.lastError = reason(error) }
        }
        await giveWay($, state, recovery, 'A newer user instruction superseded this automatic continuation.')
      }
      if (notice) {
        state.taskNotices.set(notice.id, { status: notice.status, at: await $.clock.now(), accepted: !!result && !result.drop })
        if (state.taskNotices.size > 96) state.taskNotices.delete(state.taskNotices.keys().next().value)
        if (isHostTerminal(notice.status)) {
          state.activeTasks.delete(notice.id); retireHostTask(state, notice.id)
        }
        if (notice?.status === 'completed') state.completedAgents.add(notice.id)
        if (notice?.status === 'failed') state.agentFailures.set(notice.id, await $.clock.now())
        const restored = recovery?.result.tasks?.find(task => task.newTaskID === notice.id && task.kind === 'monitor' && !task.jobID)
        if (restored && ['completed', 'failed', 'stopped', 'cancelled', 'killed', 'expired', 'timeout'].includes(notice.status)) {
          restored.status = notice.status
          if (notice.status === 'failed') await save($, state, recovery, 'needsAttention', 'The recreated monitor reported failure.')
        }
      }
      if (result && !result.drop && notice && !['completed', 'failed', 'stopped', 'cancelled', 'killed', 'expired', 'timeout'].includes(notice.status)
        && !state.explicitStops.has(notice.id) && !state.completedAgents.has(notice.id) && !state.agentFailures.has(notice.id)
        && recovery && await current($, state, recovery)) {
        const restored = recovery.result.tasks?.find(task => task.newTaskID === notice.id && task.kind === 'monitor')
        const text = typeof result.text === 'string' ? result.text : event.text
        if (restored?.agentID) await queueMonitorEvent($, state, recovery, restored, text)
        else if (!restored && state.registeringMonitors > 0) {
          if (state.earlyMonitorEvents.length >= 96 || new TextEncoder().encode(text).length > 262144
            || state.earlyMonitorEvents.reduce((size, event) => size + new TextEncoder().encode(event.text).length, 0) + new TextEncoder().encode(text).length > 1048576) {
            state.monitorOverflowIDs.add(notice.id)
          } else state.earlyMonitorEvents.push({ id: notice.id, text })
        }
        for (const id of recovery.monitorIDs) {
          if (!recovery.observedMonitors.has(id) && notice.id === id) {
            recovery.observedMonitors.add(id)
            const item = recovery.result.tasks?.find(task => task.newTaskID === id)
            if (item) { item.eventObserved = true; item.executionVerified = true; item.status = 'listening' }
            await evidence($, state, recovery, 'Monitor', 'monitorEventObserved', { taskID: id })
            await save($, state, recovery, 'executing')
          }
        }
      }
    } catch (error) { state.lastError = reason(error) }
    return result
  }).catch(($, event, next) => {
    failedHook(state, 'prompt.submit', next)
    // Replaying next in a catch returns its settled result; it never queues a second prompt.
    if (next.called) return next(event)
    return { drop: 'CC-Relay could not verify this prompt. It was not queued; retry after checking the continuation status.' }
  })
  on('tool.check', { tool: /^(Bash|Monitor)$/ }, ($, event, next) => checkWrappedCommand($, state, event, next))
    .catch(($, event, next) => {
      failedHook(state, 'tool.check', next)
      return { decision: 'deny', reason: 'The original command permission guard could not finish.' }
    })
  on('turn.start', { turnId: /.+/ }, async ($, event, next) => {
    const result = await next(event)
    if (!state.enabled) return result
    if (event.agentId === undefined) { state.busy = true; state.mainTurnID = event.turnId }
    else state.agentTurnIDs.set(event.agentId, event.turnId)
    const recovery = state.recovery
    try {
      const requestID = automaticRequest(state, event)
      if (requestID) {
        state.automaticTurns.set(event.turnId, requestID)
        if (event.agentId === undefined) state.mainAutomaticRequestID = requestID
        else state.automaticAgentRequests.set(event.agentId, requestID)
      } else if (event.agentId === undefined) state.mainAutomaticRequestID = undefined
      else state.automaticAgentRequests.delete(event.agentId)
      if (requestID && (!recovery || requestID !== recovery.request.requestID
        || state.explicitStops.has(event.agentId) || !await current($, state, recovery))) {
        // A queued automatic prompt cannot be dequeued through this API. Abort only its own
        // newly starting marker-bound turn, never the user's unrelated turn.
        // Revoke tool access before attempting cancellation. Host cancellation can fail.
        state.blockedTurns.add(event.turnId)
        state.compactorAborts.add(event.turnId)
        // Only this continuation's own turn says something about it: one of an older request, or
        // of an agent stopped on purpose, leaves its receipt as it was.
        const own = recovery && requestID === recovery.request.requestID && !state.explicitStops.has(event.agentId)
        try {
          await $.turn.abort({ turnId: event.turnId })
          if (own) await revoked($, state, recovery, 'A stale queued continuation was cancelled before its tools ran.')
        } catch (error) {
          if (own) await revoked($, state, recovery, `The stale continuation could not be cancelled; its tools remain blocked: ${reason(error)}`)
          else state.lastError = reason(error)
        }
        return result
      }
      if (recovery && await current($, state, recovery)) {
        if (event.agentId === undefined && requestID === recovery.request.requestID) {
          recovery.boundTurn = event.turnId; recovery.result.turnID = event.turnId
          await evidence($, state, recovery, 'turn.start', 'continuationTurnStarted')
        } else if (event.agentId && recovery.resumedAgents.has(event.agentId) && requestID === recovery.request.requestID) {
          recovery.agentTurns.set(event.agentId, event.turnId)
          await evidence($, state, recovery, 'Agent', 'agentTurnStarted', { agentID: event.agentId })
        } else if (event.agentId) {
          recovery.agentTurns.delete(event.agentId)
        }
      }
      await report($, state)
    } catch (error) {
      if (state.automaticTurns.has(event.turnId)) state.blockedTurns.add(event.turnId)
      state.lastError = reason(error)
    }
    return result
  }).catch(async ($, event, next) => {
    failedHook(state, 'turn.start', next)
    const requestID = automaticRequest(state, event)
    if (state.enabled) {
      if (event.agentId === undefined) { state.busy = true; state.mainTurnID = event.turnId; state.mainAutomaticRequestID = requestID }
      else { state.agentTurnIDs.set(event.agentId, event.turnId); if (!requestID) state.automaticAgentRequests.delete(event.agentId) }
    }
    if (requestID) {
      // Bind the failed guard before any await. Even if abort fails, this exact automatic turn
      // cannot execute tools. A person's unrelated turn is never cancelled by this fallback.
      state.automaticTurns.set(event.turnId, requestID)
      state.blockedTurns.add(event.turnId)
      state.compactorAborts.add(event.turnId)
      if (event.agentId === undefined) state.mainTurnID = event.turnId
      else state.agentTurnIDs.set(event.agentId, event.turnId)
    }
    const result = await next(event)
    if (requestID) {
      try { await $.turn.abort({ turnId: event.turnId }) } catch {}
      // Nothing takes the stopped work up again: its receipt says so now, instead of waiting as
      // queued until the request expires.
      const recovery = state.recovery
      if (recovery?.request.requestID === requestID) {
        try { await revoked($, state, recovery, 'The continuation guard failed, so its turn was stopped before it ran anything.') }
        catch (error) { state.lastError = reason(error) }
      }
    }
    return result
  })
  on('tool.call', { tool: /.+/ }, async ($, event, next) => {
    const active = state.recovery
    const turnID = event.agentId === undefined ? state.mainTurnID : state.agentTurnIDs.get(event.agentId)
    // Some native agent continuations omit turn.start for this observer. The exact issued
    // delivery stays scoped until an observed, unmarked manual turn replaces it.
    const requestID = state.automaticTurns.get(turnID) ?? (event.agentId && state.automaticAgentRequests.get(event.agentId))
    if (requestID) {
      let authorized = false
      try { authorized = active && requestID === active.request.requestID
        && !state.explicitStops.has(event.agentId) && !state.blockedTurns.has(turnID) && await current($, state, active) }
      catch (error) { state.lastError = reason(error) }
      if (!authorized) {
        state.blockedTurns.add(turnID)
        try {
          // An older request's turn, or an agent stopped on purpose, leaves the receipt as it was.
          if (active && requestID === active.request.requestID && !state.explicitStops.has(event.agentId)) {
            await revoked($, state, active, 'The automatic continuation was revoked; its tools are blocked.')
          }
        } catch (error) { state.lastError = reason(error) }
        return { deny: 'This automatic continuation is no longer authorized. Its tools remain blocked even if cancelling the turn failed.' }
      }
    }
    if (active?.boundTurn && state.mainTurnID === active.boundTurn && event.agentId === undefined
      && event.tool === 'SendMessage' && active.resumedAgents.has(event.to)
      && typeof event.message === 'string' && event.message.startsWith(marker(active.request))) {
      if (!state.monitorMessages.delete(event.message)) return { deny: 'This original agent already has a native continuation attempt for this switch; inspect its existing result instead of sending the same recovery message again.' }
    }
    if (active && requestID && event.tool === 'Monitor') {
      const signature = event.ws ? JSON.stringify({ ws: event.ws }) : undefined
      const restored = active.result.tasks?.find(item => item.kind === 'monitor' &&
        item.agentID === event.agentId &&
        ((signature && state.monitorSignatures.get(item.sourceTaskID) === signature) || (item.jobID && event.command === state.originalCommands.get(item.jobID))))
      if (restored) {
        if (!restored.newTaskID || state.explicitStops.has(restored.newTaskID) || state.completedAgents.has(restored.newTaskID) || state.agentFailures.has(restored.newTaskID)) return { deny: 'The original monitor is stopped or unavailable and must not be restarted by this old continuation.' }
        return { result: { taskId: restored.newTaskID, timeoutMs: Math.max(1, Math.floor(restored.deadlineAt - await $.clock.now())) } }
      }
    }
    if (active && requestID && ['ArtifactComments', 'Artifact'].includes(event.tool)
      && ['watch', 'resume_replies'].includes(event.action) && event.on !== false) {
      const key = artifactKey(event.url)
      if (key && active.keptWatches?.some(url => artifactKey(url) === key)) {
        return { deny: 'This comment watch stays with the account that published the page; CC-Relay reopens it there. This account cannot open the page: do not watch or republish it here.' }
      }
      const original = active.artifactRecovery?.items.find(item => item.key === artifactKey(event.url))
      if (original && ['restored', 'stopped', 'blocked'].includes(original.status)) {
        return { deny: `This original artifact watch was already handled (${original.status}). Inspect its native inventory and recovery receipt; do not repeat its watch or reply-resume action in this automatic continuation.` }
      }
    }
    if (active && requestID && event.tool === 'Bash') {
      const running = active.result.tasks?.find(item => item.jobID && event.command === state.originalCommands.get(item.jobID))
      if (running) return { deny: `The original command already has a surviving execution worker. Inspect task ${running.newTaskID ?? running.sourceTaskID}; do not execute it again.` }
    }
    // Protection is an addition: when it cannot be prepared, the command runs natively.
    let wrapped
    try { wrapped = await wrapCommand($, state, event) }
    catch (error) { state.lastError = reason(error); wrapped = undefined }
    const originalID = event.task_id ?? event.taskId ?? event.shell_id
    const replacement = state.taskAliases.get(originalID)
    const delivered = replacement && ['TaskStop', 'GetTask', 'TaskOutput'].includes(event.tool)
      ? { ...event, ...(event.tool === 'GetTask' ? { taskId: replacement } : { task_id: replacement }) } : wrapped?.event ?? event
    const result = await next(delivered)
    rememberCommand(state, event, result, wrapped)
    const recovery = state.recovery
    try {
      const registered = event.tool === 'Monitor' ? result?.result?.taskId : result?.result?.backgroundTaskId
      if (wrapped?.job && registered && (state.explicitStops.has(registered) || state.explicitStops.has(event.agentId))) {
        await stopCommand($, state, registered)
      }
      if (event.tool === 'TaskStop' && !failure(result)) {
        const id = result?.result?.task_id ?? event.task_id ?? event.shell_id
        if (SAFE_ID.test(id ?? '')) {
          state.explicitStops.add(id); state.activeTasks.delete(id); retireHostTask(state, id)
          if (originalID) { state.explicitStops.add(originalID); state.activeTasks.delete(originalID); retireHostTask(state, originalID) }
          try {
            let clientFailed = false
            for (const child of [...state.activeTasks.values()].filter(task => task.agentID === id)) {
              const stopped = await $.tool.call({ tool: 'TaskStop', task_id: child.id })
              if (failure(stopped)) { clientFailed = true; continue }
              state.explicitStops.add(child.id); state.activeTasks.delete(child.id); retireHostTask(state, child.id)
            }
            await stopCommand($, state, id)
            if (clientFailed) throw new Error('An original agent monitor client did not acknowledge its stop request.')
            for (const task of recovery?.result.tasks ?? []) if ([task.sourceTaskID, task.newTaskID, task.agentID, ...(task.aliases ?? [])].includes(id)
              || (originalID && [task.sourceTaskID, ...(task.aliases ?? [])].includes(originalID))) task.status = 'stopped'
            if (recovery) await save($, state, recovery)
          }
          catch (error) {
            if (recovery) await save($, state, recovery, 'needsAttention', error)
            return { isError: true, text: 'The native output client stopped, but stopping the original command could not be confirmed.' }
          }
        }
      }
      const value = result?.result
      if (!failure(result)) {
        const id = event.tool === 'Monitor' ? value?.taskId : event.tool === 'Bash' ? value?.backgroundTaskId : undefined
        if (SAFE_ID.test(id ?? '') && !state.explicitStops.has(id) && !state.completedAgents.has(id) && !state.agentFailures.has(id)) state.activeTasks.set(id, { id, kind: event.tool === 'Monitor' ? 'monitor' : 'bash',
          toolUseID: event.tool_use_id, agentID: event.agentId,
          jobID: wrapped?.job?.jobID,
          deadlineAt: wrapped?.job?.deadlineAt ?? (event.tool === 'Monitor' ? await $.clock.now() + (value?.timeoutMs ?? event.timeout_ms ?? 300000) : undefined) })
      }
      if (['Monitor', 'Bash', 'TaskStop'].includes(event.tool)) await heartbeat($, state)
      if (event.agentId && failure(result)) state.agentFailures.set(event.agentId, await $.clock.now())
      const inMainContinuation = event.agentId === undefined && recovery?.boundTurn && state.mainTurnID === recovery.boundTurn
      if (recovery && (inMainContinuation || recovery.agentTurns.has(event.agentId)) && await current($, state, recovery)) {
        if (!failure(result) && event.tool === 'Monitor' && SAFE_ID.test(value?.taskId ?? '')) recovery.monitorIDs.add(value.taskId)
        const outcome = failure(result) ? 'blockedOrFailed' : event.tool === 'Monitor' && value?.taskId ? 'monitorRegistered'
          : event.tool === 'Agent' && value?.agentId ? 'agentResultReturned'
            : event.tool === 'Bash' && value?.backgroundTaskId ? 'backgroundRegistered' : 'toolResultReturned'
        await evidence($, state, recovery, event.tool, outcome, {
          toolUseID: event.tool_use_id, agentID: event.agentId ?? value?.agentId,
          taskID: value?.taskId ?? value?.backgroundTaskId,
        })
        // A failing step, a test run that fails say, is part of the work going on. A continuation
        // whose turn ends without one step that worked is reported by CC-Relay instead.
        await save($, state, recovery, 'executing')
      }
    } catch (error) { state.lastError = reason(error) }
    return result
  }).catch(($, event, next) => {
    failedHook(state, 'tool.call', next)
    return next.called ? next(event) : { deny: 'The native continuation guard failed; this tool was not run.' }
  })
  on('turn.complete', { turnId: /.+/ }, async ($, event, next) => {
    const result = await next(event)
    if (!state.enabled) return result
    const compactor = state.compactorAborts.delete(event.turnId)
    if (event.agentId === undefined) { state.busy = false; state.mainTurnID = undefined }
    if (event.agentId === undefined && event.reason === 'answer') { state.rateLimitFailure = undefined; state.accountStopped = undefined }
    const recovery = state.recovery
    try {
      if (event.agentId === undefined && event.isAborted && !compactor) await pause($, state)
      else if (event.agentId && recovery?.agentTurns.get(event.agentId) === event.turnId && await current($, state, recovery)) {
        recovery.agentTurns.delete(event.agentId)
        await evidence($, state, recovery, 'Agent', event.isAborted ? 'agentTurnInterrupted' : 'agentTurnEnded', { agentID: event.agentId })
      }
      else if (recovery?.boundTurn === event.turnId && await current($, state, recovery)) {
        if (!compactor) recovery.mainEnded = true
        await evidence($, state, recovery, 'turn.complete', compactor ? 'compactionPause' : 'continuationTurnEnded')
        await save($, state, recovery, compactor ? 'executing' : 'turnFinished')
        if (!compactor) recovery.boundTurn = undefined
      }
      await report($, state)
    } catch (error) { state.lastError = reason(error) }
    return result
  })
  on('turn.abort', { turnId: /.+/ }, async ($, event, next) => {
    const compactor = next.origin?.plugin === 'cc-relay'
    if (compactor) {
      state.compactorAborts.add(event.turnId)
      if (event.agentId === undefined && state.recovery?.boundTurn === event.turnId) {
        state.compactorResumeRequestID = state.recovery.request.requestID
      }
    }
    else if (event.agentId === undefined) state.userStopped = true
    const result = await next(event)
    if (!compactor && event.agentId === undefined && state.enabled) await pause($, state)
    return result
  })
}
