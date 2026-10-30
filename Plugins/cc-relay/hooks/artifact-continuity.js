// A watch and permission to answer its comments are separate native capabilities.
// Both switch handoff and ordinary reopen use the same bounded, receipt-checked recovery.
const ARTIFACT_URL = /^https:\/\/claude\.ai\/(?:code\/)?artifact\/[A-Za-z0-9-]+\/?$/
export const artifactKey = url => typeof url === 'string' && ARTIFACT_URL.test(url) ? url.replace('/code/artifact/', '/artifact/').replace(/\/$/, '') : undefined
const failed = result => !result || !!(result.deny || result.isError || result.result?.is_error)
const detail = result => String(result?.deny ?? result?.text ?? result?.result?.resume_replies?.reason ?? result?.result?.watch?.reason ?? 'The native host did not confirm recovery.').slice(0, 400)
const WATCH_STOPPED = new Set(['recorded_stop', 'stop_latched'])
const BLOCKED = new Set(['held_by_live_session', 'held_by_background_agent', 'holder_unknown', 'not_editor', 'record_incomplete'])

export function artifactRecovery(artifacts) {
  const armed = artifacts.filter(item => item.state === 'armed'), seen = new Set(), items = []
  let invalid = armed.length > 32
  for (const original of armed.slice(0, 32)) {
    const id = artifactKey(original.url)
    if (!id) { invalid = true; continue }
    if (seen.has(id)) {
      if (original.replies === true) items.find(item => item.key === id).replies = true
      continue
    }
    seen.add(id); items.push({ url: original.url, key: id, replies: original.replies === true, status: 'pending' })
  }
  return { items, error: invalid ? 'Some original artifact references need inspection before they can be restored.' : undefined,
    waiting: false, done: items.length === 0, lastCheck: undefined, checks: 0 }
}

export async function advanceArtifacts($, recovery, { current, record }) {
  if (recovery.done || !await current()) return
  const now = await $.clock.now()
  if (recovery.lastCheck !== undefined && now - recovery.lastCheck < 10_000) return
  recovery.lastCheck = now; recovery.checks += 1
  const pending = () => recovery.items.filter(item => ['pending', 'connecting'].includes(item.status))
  const block = async (item, message, outcome = 'notRestored') => {
    item.status = 'blocked'; item.error = message; recovery.error ??= message
    await record(outcome, { taskID: item.taskID })
  }
  const inventory = async () => {
    if (!await current()) return undefined
    const result = await $.tool.call({ tool: 'ArtifactComments', action: 'watch' }).catch(error => ({ deny: String(error) }))
    if (!await current()) return undefined
    if (failed(result) || !Array.isArray(result.result?.watches)) {
      for (const item of pending()) await block(item, 'The original artifact subscriptions could not be inspected.', 'watchInventoryUnavailable')
      return undefined
    }
    return result.result
  }
  const inspect = async listing => {
    for (const item of pending()) {
      const watch = listing.watches.find(value => artifactKey(value.url) === item.key)
      const arm = listing.arms?.find(value => artifactKey(value.url) === item.key)
      item.taskID = watch?.task_id ?? item.taskID
      if (watch?.rail === 'live_stopped' || watch?.stop_kind || WATCH_STOPPED.has(arm?.reason) ||
        (item.replies && (['stopped', 'paused', 'disarmed'].includes(watch?.auto_reply) || arm?.reason === 'auto_replies_disabled'))) {
        item.status = 'stopped'; await record('stoppedWatchSkipped', { taskID: item.taskID }); continue
      }
      if (item.replies && (BLOCKED.has(arm?.reason) || ['yielded', 'declined', 'denied', 'cannot_edit'].includes(watch?.auto_reply))) {
        await block(item, `Artifact recovery was refused by the native host: ${arm?.reason ?? watch.auto_reply}.`); continue
      }
      item.connected = watch?.connected === true || watch?.rail === 'durable_wake'
      item.connecting = watch?.connecting === true || ['arming', 'backing_off'].includes(arm?.state) || arm?.reason === 'arm_in_flight'
      item.autoReply = watch?.auto_reply
      // A durable watch needs a real comment wake subscription, not just an arbitrary event.
      item.repliesReady = item.replies && item.connected && !item.connecting && (watch?.auto_reply === 'armed' ||
        (watch?.rail === 'durable_wake' && watch.events?.includes('comment')))
      if (!item.replies && item.connected && watch?.auto_reply !== 'none') {
        await block(item, `The native watch does not confirm watch-only mode (auto_reply: ${watch?.auto_reply ?? 'unknown'}). Its existing state was left unchanged.`, 'watchOnlyUnconfirmed')
        continue
      }
      // The native host can report a connected socket before its handshake is ready.
      if (item.connecting) {
        item.status = 'connecting'
      } else if (item.connected && (!item.replies || item.repliesReady)) {
        item.status = 'restored'
        await record(item.replies ? 'repliesRestored' : 'watchConnected', { taskID: item.taskID })
      }
      if (watch?.last_error && !item.connecting && item.status !== 'restored') await block(item, String(watch.last_error).slice(0, 400))
    }
  }
  let listing = await inventory()
  if (listing) {
    await inspect(listing)
    let changed = false
    for (const item of pending()) {
      const reattachReplies = item.connected && item.replies && !item.repliesReady
      if (item.connecting || item.watchAttempted || (item.connected && !reattachReplies)) continue
      if (!item.replies) {
        // The native watch action may arm replies from prior consent; replies:false is not
        // an opt-out on this host. Do not create a responder and then try to undo it.
        await block(item, 'The native host has no guaranteed watch-only creation option. Reopen the original watch in watch-only mode before checking it again.', 'watchOnlyUnavailable')
        continue
      }
      if (!await current()) return
      // Record intent before the native call: a lost reply must not cause another registration.
      item.watchAttempted = true
      if (await record(reattachReplies ? 'repliesReattachAttempting' : 'watchAttempting', { taskID: item.taskID }) === false) return
      if (!await current()) return
      const result = await $.tool.call({ tool: 'ArtifactComments', action: 'watch', url: item.url, on: true }).catch(error => ({ deny: String(error) }))
      if (!await current()) return
      const receipt = result?.result?.watch
      if (failed(result) || !(receipt?.watching === true || receipt?.connecting === true)) {
        await block(item, detail(result), 'blocked'); continue
      }
      item.taskID = receipt.task_id; changed = true
      if (item.replies) {
        item.replyFailure = receipt.can_edit === false ? 'This account cannot edit the original artifact.'
          : receipt.replies_declined === true ? 'Automatic comment replies were not approved in this session.'
            : receipt.user_turn === false ? 'The native host requires a user-started turn to arm automatic replies.'
              : receipt.named_by_user === false ? 'The native host requires the artifact link in the user request.'
                : receipt.auto_reply === 'none' ? 'The native watch connected without arming automatic replies; check its current session consent and context.' : undefined
      }
      await record(receipt.connecting ? 'connecting' : reattachReplies ? 'repliesReattachAccepted' : 'watchAccepted', { taskID: item.taskID })
    }
    if (changed && pending().length) { listing = await inventory(); if (listing) await inspect(listing) }
    // Re-watch uses the host's ordinary permission/consent and editor checks. resume_replies
    // only reverses a recorded stop; it cannot arm a watch whose auto_reply is simply "none".
    // A receipt is still not proof: only inventory above can mark a subscription restored.
    for (const item of pending()) if (item.replyFailure && !item.connecting) await block(item, item.replyFailure, 'repliesBlocked')
  }

  if (!await current()) return
  if (recovery.checks >= 6) for (const item of pending()) {
    await block(item, item.replies ? 'The native host did not confirm the connection and automatic replies after six checks.' :
      'The artifact connection was not confirmed after six checks.')
  }
  recovery.waiting = pending().length > 0
  recovery.done = !recovery.waiting
}
