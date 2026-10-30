import assert from 'node:assert/strict'
import test from 'node:test'
import { readFileSync } from 'node:fs'
import { register } from '../hooks/index.js'
import { PLUGIN_VERSION } from '../hooks/version.js'

// Claude Code refuses the whole hooks module when one event is hooked twice without a matcher.
// The fixture hosts load each module on its own, so the plugin's entry module is checked here.
test('the plugin hooks each event at most once without a matcher', () => {
  const unmatched = new Map()
  register((event, matcher) => {
    if (typeof matcher === 'function') unmatched.set(event, (unmatched.get(event) ?? 0) + 1)
    return { catch() { return this } }
  }, {})
  assert.deepEqual([...unmatched].filter(([, count]) => count > 1).map(([event]) => event), [])
  assert.equal(unmatched.get('prompt.submit'), 1)
})

// Both modules report the version they loaded with; it is the one the package states.
test('the version the modules report is the package version', () => {
  const metadata = JSON.parse(readFileSync(new URL('../.claude-plugin/plugin.json', import.meta.url), 'utf8'))
  assert.equal(PLUGIN_VERSION, metadata.version)
})
