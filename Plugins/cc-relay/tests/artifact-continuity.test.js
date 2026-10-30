import assert from 'node:assert/strict'
import test from 'node:test'
import { artifactRecovery, advanceArtifacts } from '../hooks/artifact-continuity.js'

const url = 'https://claude.ai/code/artifact/original-1234'
function host({ watches = [], arms = [], response, replies = true, artifacts = [{ url, state: 'armed', replies }] } = {}) {
  let now = 100_000, allowed = true
  const calls = [], evidence = [], recovery = artifactRecovery(artifacts)
  const $ = { clock: { now: async () => now }, tool: { call: async input => {
    calls.push(input)
    if (!input.url) return { result: { watches, arms } }
    if (response) return response(input)
    if (input.replies) {
      return { result: { resume_replies: { url, resumed: false, outcome: 'skipped', reason: 'not_stopped' } } }
    }
    const watch = watches.find(item => item.url === url)
    if (watch) watch.auto_reply = replies ? 'armed' : 'none'
    else watches.push({ url, connected: true, auto_reply: replies ? 'armed' : 'none' })
    return { result: { watch: { url, watching: true, auto_reply: replies ? 'armed' : 'none' } } }
  } } }
  const step = () => advanceArtifacts($, recovery, { current: async () => allowed,
    record: async (outcome, metadata) => { evidence.push({ outcome, ...metadata }) } })
  return { calls, evidence, watches, recovery, step, advance: () => { now += 10_000 }, stop: () => { allowed = false } }
}

test('restoring an original watch also restores and verifies its automatic replies', async () => {
  const h = host(); await h.step()
  assert.deepEqual(h.calls.filter(call => call.url), [
    { tool: 'ArtifactComments', action: 'watch', url, on: true },
  ])
  assert.equal(h.recovery.items[0].status, 'restored')
  assert.ok(h.evidence.some(item => item.outcome === 'repliesRestored'))
  assert.equal(h.recovery.done, true)
  h.advance(); await h.step()
  assert.equal(h.calls.length, 3, 'a completed recovery performs no further calls')
})

test('native recovery which already rearmed the watch is left alone, including equivalent URL spelling', async () => {
  const h = host({ watches: [{ url: url.replace('/code/', '/'), connected: true, auto_reply: 'armed' }] })
  await h.step(); assert.equal(h.calls.length, 1); assert.equal(h.recovery.items[0].status, 'restored')
})

test('a connected socket or a rewatch receipt alone never proves automatic replies are restored', async () => {
  const h = host({ watches: [{ url, connected: true, auto_reply: 'none' }],
    response: async () => ({ result: { watch: { url, watching: true, auto_reply: 'armed' } } }) })
  await h.step()
  assert.equal(h.recovery.waiting, true)
  assert.ok(!h.evidence.some(item => item.outcome === 'repliesRestored'))
  for (let n = 0; n < 5; n++) { h.advance(); await h.step() }
  assert.equal(h.recovery.items[0].status, 'blocked')
  assert.equal(h.calls.filter(call => call.url).length, 1, 'native rewatch is attempted once, then checked read-only')
})

test('connecting watches get bounded read-only checks and preserve the original URL', async () => {
  for (const connected of [false, true]) for (const replies of [false, true]) {
    const auto_reply = replies ? 'armed' : 'none'
    const watches = [{ url, connected, connecting: true, auto_reply }], h = host({ watches, replies })
    await h.step(); assert.equal(h.recovery.waiting, true)
    assert.equal(h.recovery.items[0].status, 'connecting'); assert.equal(h.recovery.items[0].repliesReady, false)
    assert.ok(!h.evidence.some(item => ['watchConnected', 'repliesRestored'].includes(item.outcome)))
    watches[0] = { url, connected: true, auto_reply }
    h.advance(); await h.step()
    assert.equal(h.recovery.items[0].status, 'restored'); assert.equal(h.calls.filter(call => call.url).length, 0)
  }
})

test('new watch-only subscriptions fail visibly without a native mutation, including legacy unknown intent', async () => {
  for (const replies of [false, undefined]) {
    const h = host({ artifacts: [{ url, state: 'armed', replies }] }); await h.step()
    assert.equal(h.recovery.items[0].status, 'blocked')
    assert.match(h.recovery.error, /no guaranteed watch-only creation option/)
    assert.equal(h.calls.filter(call => call.url).length, 0)
    assert.equal(h.watches.length, 0)
  }
})

test('an unwired connected watch is reattached once through ordinary watch, never resume_replies', async () => {
  const h = host({ watches: [{ url, connected: true, auto_reply: 'none' }] })
  await h.step(); h.advance(); await h.step()
  assert.equal(h.recovery.items[0].status, 'restored')
  assert.deepEqual(h.calls.filter(call => call.url), [{ tool: 'ArtifactComments', action: 'watch', url, on: true }])
})

test('an existing confirmed watch-only subscription is accepted read-only despite reply-only restrictions', async () => {
  for (const reason of ['auto_replies_disabled', 'not_editor', 'held_by_live_session']) {
    const h = host({ replies: false, watches: [{ url, connected: true, auto_reply: 'none' }], arms: [{ url, state: 'failed', reason }] })
    await h.step()
    assert.equal(h.recovery.items[0].status, 'restored', reason)
    assert.equal(h.calls.filter(call => call.url).length, 0)
    assert.ok(h.evidence.some(item => item.outcome === 'watchConnected'))
  }
})

test('a watch-only snapshot cannot claim success for an armed or unknown native reply state', async () => {
  for (const auto_reply of ['armed', undefined, 'stopped', 'paused', 'disarmed', 'declined', 'yielded']) {
    const h = host({ replies: false, watches: [{ url, connected: true, auto_reply }] })
    await h.step(); assert.equal(h.recovery.items[0].status, 'blocked'); assert.equal(h.calls.length, 1)
    assert.match(h.recovery.error, /does not confirm watch-only mode/)
    assert.equal(h.watches[0].auto_reply, auto_reply, 'a pre-existing responder is not changed unilaterally')
  }
})

test('a connecting watch-only subscription waits for confirmed none and never re-registers', async () => {
  for (const auto_reply of ['none', 'armed']) {
    const watches = [{ url, connecting: true }], h = host({ replies: false, watches })
    await h.step(); assert.equal(h.recovery.waiting, true)
    watches[0] = { url, connected: true, auto_reply }
    h.advance(); await h.step()
    assert.equal(h.recovery.items[0].status, auto_reply === 'none' ? 'restored' : 'blocked')
    assert.equal(h.calls.filter(call => call.url).length, 0)
  }
})

test('a native rewatch with no reply wiring reports its actual context failure and is not retried', async () => {
  for (const fields of [{ user_turn: false }, { named_by_user: false }, { can_edit: false }, { replies_declined: true }, {}]) {
    const watches = [{ url, connected: true, auto_reply: 'none' }]
    const h = host({ watches, response: async () => ({ result: { watch: { url, watching: true, auto_reply: 'none', ...fields } } }) })
    await h.step(); h.advance(); await h.step()
    assert.equal(h.recovery.items[0].status, 'blocked'); assert.ok(h.recovery.error)
    assert.equal(h.calls.filter(call => call.url).length, 1)
    assert.ok(!h.evidence.some(item => item.outcome === 'repliesRestored'))
  }
})

test('native user stops and session disarm are preserved without attempting to reverse them', async () => {
  for (const state of [
    { watches: [{ url, rail: 'live_stopped', stop_kind: 'user' }] },
    { watches: [{ url, connected: true, auto_reply: 'stopped' }] },
    { watches: [{ url, connected: true, auto_reply: 'paused' }] },
    { arms: [{ url, reason: 'auto_replies_disabled' }] },
    { arms: [{ url, reason: 'recorded_stop' }] },
    { arms: [{ url, reason: 'stop_latched' }] },
  ]) {
    const h = host(state); await h.step()
    assert.equal(h.recovery.items[0].status, 'stopped'); assert.equal(h.calls.length, 1)
  }
})

test('another live responder, missing edit permission, or declined replies cannot become a second responder', async () => {
  for (const state of [
    { watches: [{ url, connected: true, auto_reply: 'yielded' }] },
    { watches: [{ url, connected: true, auto_reply: 'declined' }] },
    { arms: [{ url, reason: 'held_by_live_session' }] },
    { arms: [{ url, reason: 'held_by_background_agent' }] },
    { arms: [{ url, reason: 'not_editor' }] },
  ]) {
    const h = host(state); await h.step()
    assert.equal(h.recovery.items[0].status, 'blocked'); assert.equal(h.calls.length, 1)
    assert.ok(h.recovery.error)
  }
})

test('permission denial, refused resume and transport failure are final and never publish', async () => {
  for (const response of [async () => ({ deny: 'consent required' }),
    async () => ({ result: { resume_replies: { resumed: false, reason: 'stale_consent' } } }),
    async () => { throw new Error('host unavailable') }]) {
    const h = host({ watches: [{ url, connected: true, auto_reply: 'none' }], response })
    await h.step(); h.advance(); await h.step()
    assert.equal(h.recovery.items[0].status, 'blocked')
    assert.equal(h.calls.filter(call => call.url).length, 1)
    assert.ok(h.calls.every(call => call.tool === 'ArtifactComments' && call.action === 'watch'))
  }
})

test('a user taking over while a native call waits prevents subsequent reply recovery', async () => {
  let h
  h = host({ response: async () => { h.stop(); return { result: { watch: { watching: true } } } } })
  await h.step(); h.advance(); await h.step()
  assert.equal(h.calls.filter(call => call.url).length, 1)
  assert.ok(!h.evidence.some(item => item.outcome === 'repliesRestored'))
})

test('durable watches only satisfy automatic replies with a verified comment event subscription', async () => {
  const valid = host({ watches: [{ url, rail: 'durable_wake', events: ['comment'] }] }); await valid.step()
  assert.equal(valid.recovery.items[0].status, 'restored'); assert.equal(valid.calls.length, 1)
  const other = host({ watches: [{ url, rail: 'durable_wake', events: ['edit'] }], response: async () => ({ deny: 'remote session' }) })
  await other.step(); assert.equal(other.recovery.items[0].status, 'blocked')
})

test('published references, stopped intent and arbitrary links are never restoration targets', async () => {
  const h = host({ artifacts: [{ url }, { url: url + '-stopped', state: 'stopped' }, { url: 'https://example.com/artifact/x', state: 'armed' }] })
  await h.step(); assert.equal(h.calls.length, 0); assert.ok(h.recovery.error)
})
