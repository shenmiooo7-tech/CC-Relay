// Native tool names, parameters and permission pipeline stay in use. These clients stream an
// already executing command; account recovery never evaluates its original command again.
const ID = /^[A-Za-z0-9_-]{1,128}$/
export function encodeResult(result) {
  let text = JSON.stringify(result)
  if (new TextEncoder().encode(text).length <= 3900000) return { text, truncated: false }
  const compact = { ...result, status: 'needsAttention', error: 'Native task result details exceeded the supported file size. Inspect the original worker records.',
    tasks: (result.tasks ?? []).slice(-64), omittedNativeTaskResults: Math.max(0, (result.tasks?.length ?? 0) - 64), evidence: (result.evidence ?? []).slice(-32) }
  return { text: JSON.stringify(compact), truncated: true, error: compact.error }
}
export function quote(value) { return `'${String(value).replaceAll("'", "'\\''")}'` }
export function jobPath(state, jobID) { return `${state.home}/Library/Application Support/CC-Relay/NativeRecovery/commands/${jobID}` }
async function json($, path) { try { return JSON.parse(await $.fs.read(path)) } catch { return undefined } }
async function executionPath($, state, jobID) {
  const control = jobPath(state, jobID), location = await json($, `${control}/location.json`)
  if (!location) return control
  if (location.version !== 1 || location.jobID !== jobID || typeof location.directory !== 'string'
    || !/^\/(?:private\/)?tmp\/cc-relay-native-\d+\/[A-Fa-f0-9-]+\/[A-Za-z0-9_-]+$/.test(location.directory)
    || !location.directory.endsWith(`/${jobID}`)) throw new Error('The original execution directory cannot be verified.')
  return location.directory
}
export async function configureCommands($, state) {
  state.workerPath = undefined
  const root = $.plugin.root
  if (typeof root !== 'string' || !root.startsWith('/')) return
  const path = `${root}/bin/CompanionNativeWorker`
  if (await $.fs.exists(path)) state.workerPath = path
}
// A worker installed after this runtime loaded is found the next time one is needed.
export async function worker($, state) {
  if (!state.workerPath) await configureCommands($, state)
  return state.workerPath
}
// One printable line of the original, so the task list still says what runs.
function preview(command) {
  return command.split('\n')[0].replace(/[\u0000-\u001f\u007f]/g, ' ').slice(0, 160)
}
// The native shell writes its functions and aliases, named by shell, where only this job's
// worker reads them: the detached command gets the definitions the Bash tool would have had.
// The status line after the worker keeps that shell alive as the worker's ancestor; a tail
// exec would hide whether the original belongs to zsh, bash or sh.
export function workerCommand(worker, control, physical, original) {
  const state = `${physical}/shell-state`
  return `if [ -n "\${ZSH_VERSION-}" ]; then { typeset -f; alias -L; typeset -p fpath; } >${quote(`${state}.zsh`)} 2>/dev/null; `
    + `elif [ -n "\${BASH_VERSION-}" ]; then { declare -f; alias -p; } >${quote(`${state}.bash`)} 2>/dev/null; fi; `
    + `${quote(worker)} run ${quote(control)}; cc_relay_native_status=$?; exit "$cc_relay_native_status" # ${preview(original)}`
}
export async function wrapCommand($, state, event) {
  if (!state.enabled || !state.sessionID || !state.procStart || !state.pid) return undefined
  if (!(event.tool === 'Bash' && event.run_in_background === true) && !(event.tool === 'Monitor' && typeof event.command === 'string')) return undefined
  if (typeof event.command !== 'string' || event.command.length === 0 || new TextEncoder().encode(event.command).length > 262144 || event.command.includes('\0')) return undefined
  if (!await worker($, state)) return undefined
  // Only a command the person's rules or mode already allow outright is protected. A command
  // that would ask, and every command under a PreToolUse policy, runs exactly as it would
  // without this plugin: the dialog, the classifier and the policy all see the original.
  // Such a command is not kept alive across a switch; the continuation reports it.
  const settings = await $.settings.read()
  if (settings?.hooks?.PreToolUse?.length) return undefined
  const { tool, tool_use_id, agentId, requestMeta, ...input } = event
  const decision = await $.tool.check({ tool, input })
  if (decision?.decision !== 'allow') return undefined
  const jobID = `cmd-${crypto.randomUUID()}`, directory = jobPath(state, jobID)
  const prepared = await $.process.run([state.workerPath, 'prepare', directory])
  if (prepared?.exitCode !== 0) { state.lastError = 'The background command worker could not be prepared.'; return undefined }
  let physical
  try { physical = JSON.parse(prepared.stdout).directory } catch { return undefined }
  if (typeof physical !== 'string' || !physical.startsWith('/') || !physical.endsWith(`/${jobID}`)) return undefined
  const deadlineAt = tool === 'Monitor' ? await $.clock.now() + Math.min(1800000, Math.max(1, Number(event.timeout_ms) || 300000)) : undefined
  const { command: originalCommand, ...options } = input
  const spec = { version: 1, jobID, sessionID: state.sessionID, kind: tool === 'Monitor' ? 'monitor' : 'bash',
    command: originalCommand, options, ownerPID: state.pid, procStart: state.procStart, deadlineAt }
  await $.fs.write(`${physical}/spec.json`, JSON.stringify(spec))
  const command = workerCommand(state.workerPath, directory, physical, originalCommand)
  state.workerChecks.set(command, { tool, input })
  const job = { jobID, kind: spec.kind, toolUseID: tool_use_id, agentID: agentId, deadlineAt }
  state.commandJobs.set(jobID, job)
  return { event: { ...event, command }, job }
}
export async function checkWrappedCommand($, state, event, next) {
  try {
    const original = state.workerChecks.get(event.input?.command)
    if (!original) return next(event)
    // The wrapper was made only because the original was allowed outright. It is decided by
    // the original again; a wrapper verdict can only refuse, never ask about a wrapper text.
    const settings = await $.settings.read()
    if (settings?.hooks?.PreToolUse?.length) return { decision: 'deny', reason: 'A PreToolUse policy appeared before the background command started. Run it again to use that policy.' }
    const current = await $.tool.check(original)
    if (current?.decision !== 'allow') return { decision: 'deny', reason: 'The original command is no longer allowed without asking. Run it again to be asked about it.' }
    const verdict = await next(event)
    return verdict?.decision === 'deny' ? verdict : { decision: 'allow' }
  } catch { return { decision: 'deny', reason: 'The original command policy could not be verified.' } }
}
export function rememberCommand(state, event, result, wrapped) {
  const id = event.tool === 'Monitor' ? result?.result?.taskId : result?.result?.backgroundTaskId
  if (!wrapped?.job || !ID.test(id ?? '')) return
  const job = { ...wrapped.job, id }
  state.commandJobs.set(job.jobID, job)
  state.commandAliases.set(id, job.jobID)
}
export async function stopCommand($, state, id) {
  const jobs = new Set([state.commandAliases.get(id), ...[...state.commandJobs.values()]
    .filter(job => job.agentID === id && job.id).map(job => job.jobID)].filter(jobID => ID.test(jobID ?? '')))
  if (!jobs.size) return
  if (!await worker($, state)) throw new Error('The original command execution worker is unavailable.')
  const stopped = await Promise.all([...jobs].map(jobID => $.process.run([state.workerPath, 'stop', jobPath(state, jobID)])))
  if (stopped.some(result => result?.exitCode !== 0)) throw new Error('The original command did not acknowledge its stop request.')
}
export async function inspectCommand($, state, jobID, sessionID = state.sessionID) {
  if (!ID.test(jobID ?? '') || !await worker($, state)) return undefined
  const result = await $.process.run([state.workerPath, 'inspect', jobPath(state, jobID)])
  if (result?.exitCode !== 0) return undefined
  let value
  try { value = JSON.parse(result.stdout) } catch { return undefined }
  return value?.version === 1 && value.jobID === jobID && value.sessionID === sessionID ? value : undefined
}
export async function commandAttachment($, state, recovery, task) {
  if (!ID.test(task.jobID ?? '') || !await worker($, state)) return { error: 'The original command has no available execution worker.' }
  const control = jobPath(state, task.jobID), directory = await executionPath($, state, task.jobID)
  const [record, spec, permit] = await Promise.all([inspectCommand($, state, task.jobID), json($, `${directory}/spec.json`), json($, `${directory}/handoff.json`)])
  if (spec?.version === 1 && spec.jobID === task.jobID && spec.sessionID === state.sessionID && typeof spec.command === 'string') state.originalCommands.set(task.jobID, spec.command)
  if (!record || spec?.version !== 1 || spec.jobID !== task.jobID || spec.sessionID !== state.sessionID
    || spec.kind !== task.kind || typeof spec.command !== 'string' || new TextEncoder().encode(spec.command).length > 262144
    || !['running', 'starting', 'completed', 'failed'].includes(record.status) || await $.fs.exists(`${directory}/stop.json`)) {
    return { error: 'The original command cannot be verified or was explicitly stopped.' }
  }
  if (record.executionProtocol !== 3) return { error: 'The original command uses an older execution worker and cannot be adopted safely by this version.' }
  if (permit?.version !== 1 || permit.requestID !== recovery.request.requestID || permit.operationID !== recovery.request.operationID
    || permit.targetPID !== state.pid || permit.targetInstanceID !== state.instanceID
    || permit.expiresAt <= await $.clock.now()) return { error: 'The original command has no matching handoff authorization.' }
  const input = { ...(spec.options ?? {}), command: spec.command, ...(task.kind === 'bash' ? { run_in_background: true }
    : { description: spec.options?.description ?? '接回原命令监听', timeout_ms: Math.max(1, Math.floor((task.deadlineAt ?? 0) - await $.clock.now())) }) }
  const decision = await $.tool.check({ tool: task.kind === 'monitor' ? 'Monitor' : 'Bash', input })
  if (decision?.decision !== 'allow') {
    // Nobody may be there to answer a dialog, and an unattached body must not run on unseen.
    await $.process.run([state.workerPath, 'stop', control]).catch(() => undefined)
    return { error: 'The original command is no longer allowed without asking here, so it was stopped instead of being reattached.' }
  }
  const command = `${quote(state.workerPath)} attach ${quote(control)} ${quote(recovery.request.requestID)} # ${preview(spec.command)}`
  state.workerChecks.set(command, { tool: task.kind === 'monitor' ? 'Monitor' : 'Bash', input })
  state.originalCommands.set(task.jobID, spec.command)
  return { command, record, directory }
}
