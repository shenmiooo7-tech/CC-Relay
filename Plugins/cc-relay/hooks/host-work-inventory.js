// The host's own list of a conversation's background tasks at a turn's end, beside the plugin's
// live tracking: it also shows commands the plugin never saw start. Only identities and states are
// kept; command lines and descriptions stay with the host.
const LIMIT = 128
const TERMINAL = new Set(['completed', 'failed', 'stopped', 'cancelled', 'canceled', 'killed', 'expired', 'timeout'])
export const isHostTerminal = status => TERMINAL.has(status)
const field = (value, limit) => typeof value === 'string' && value.length > 0 && value.length <= limit && !/[\u0000-\u001f\u007f]/.test(value)

// The tasks a Stop or SubagentStop lists as still running. Without a list it tells nothing new.
export function hostTasks(event, ended) {
  if (!Array.isArray(event.background_tasks)) return undefined
  const tasks = [], ids = new Set()
  for (const row of event.background_tasks.slice(0, LIMIT)) {
    if (!row || typeof row !== 'object' || !field(row.id, 256) || !field(row.type, 96) || !field(row.status, 64)) continue
    if (ids.has(row.id) || ended?.has(row.id) || TERMINAL.has(row.status)) continue
    ids.add(row.id)
    tasks.push({ id: row.id, type: row.type, status: row.status })
  }
  return tasks
}

// A task reported finished, or stopped through TaskStop, leaves the list, and a later list that
// still names it does not bring it back.
export function retireHostTask(state, id) {
  const ended = state.hostEndedTasks ??= new Set()
  ended.delete(id); ended.add(id)
  if (ended.size > 256) ended.delete(ended.values().next().value)
  const inventory = state.hostWorkInventory
  if (inventory) state.hostWorkInventory = { backgroundTasks: inventory.backgroundTasks.filter(task => task.id !== id) }
}
