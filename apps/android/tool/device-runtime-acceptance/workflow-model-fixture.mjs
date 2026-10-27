import assert from 'node:assert/strict'
import { LlmAdapter } from '@deepseek-ai/dsh-llm'

/** Encode fixture text as the ordinary model stream protocol.
 * @param {string} text - Model answer.
 * @param {string} reason - Finish reason kind.
 * @returns {object[]} Complete text block and terminal chunk.
 */
export function textChunks(text, reason = 'stop') {
  return [{ type: 'block-start', index: 0, blockType: 'text' },
    { type: 'text-delta', index: 0, text },
    { type: 'block-end', index: 0, block: { type: 'text', text } },
    { type: 'finish', reason: { kind: reason } }]
}

function abortable(promise, signal) {
  return new Promise((resolve, reject) => {
    const abort = () => reject(signal.reason ?? new Error('Fixture model cancelled'))
    if (signal.aborted) { abort(); return }
    signal.addEventListener('abort', abort, { once: true })
    promise.then(resolve, reject).finally(() => signal.removeEventListener('abort', abort)).catch(() => {})
  })
}

/** Script only the model stream. Agent activation, tools, cancellation and persistence remain real. */
export class FixtureAdapter extends LlmAdapter {
  mode = 'answer'
  calls = 0
  entered = null
  scriptedStream = null
  async resolveModel(provider, model) { return { provider, id: model, name: model } }
  async *stream(options) {
    this.calls++
    if (this.scriptedStream) { yield* this.scriptedStream(options); return }
    assert.equal((options.tools ?? []).length, 0, 'Confined child received unexpected tools')
    this.entered?.()
    if (this.mode === 'hold') { await abortable(new Promise(() => {}), options.signal); return }
    yield* textChunks('device child answer')
  }
}

/** A two-arrival barrier observes overlap without sleeps or a fabricated child/native result.
 * @param {object} options - Whether to require overlapping model requests.
 * @returns {object} Scripted stream and actual model entry, completion and cancellation observations.
 */
export function workflowModelScenario({ barrier = false } = {}) {
  const entered = Promise.withResolvers()
  const overlap = Promise.withResolvers()
  const state = { prompts: [], active: 0, maxActive: 0, aborted: [], failed: [], finished: [], entered: entered.promise }
  state.stream = async function* (options) {
    const matches = [...JSON.stringify(options.messages).matchAll(/workflow-fixture:([a-z0-9-]+)/g)]
    assert.ok(matches.length > 0, 'Child did not receive a fixture prompt')
    const key = matches.at(-1)[1]
    const names = (options.tools ?? []).map(tool => tool.name)
    assert.deepEqual(names, key === 'structured' ? ['structured_output'] : [])
    state.prompts.push(key)
    state.active++
    state.maxActive = Math.max(state.maxActive, state.active)
    entered.resolve(key)
    if (barrier && state.active === 2) overlap.resolve()
    try {
      if (barrier) await abortable(overlap.promise, options.signal)
      if (key.startsWith('hold')) await abortable(new Promise(() => {}), options.signal)
      if (key === 'failure') {
        state.failed.push(key)
        throw new Error('Intentional fixture model failure')
      }
      if (key === 'structured') {
        const args = JSON.stringify({ label: 'verified', nested: { count: 3, unicode: '中文' }, list: [true, null, 2] })
        yield { type: 'block-start', index: 0, blockType: 'tool-call' }
        yield { type: 'tool-call-delta', index: 0, id: 'workflow-structured-result', name: 'structured_output', argumentsDelta: args }
        yield { type: 'block-end', index: 0, block: { type: 'tool-call', id: 'workflow-structured-result',
          name: 'structured_output', arguments: args } }
        yield { type: 'finish', reason: { kind: 'tool-calls' } }
      } else yield* textChunks(`answer:${key}`)
      state.finished.push(key)
    } catch (error) {
      if (options.signal.aborted) state.aborted.push(key)
      throw error
    } finally { state.active-- }
  }
  return state
}
