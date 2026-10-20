import assert from 'node:assert/strict'
import { createServer } from 'node:http'
import { once } from 'node:events'

const textEvents = text => [
  { type: 'content_block_start', index: 0, content_block: { type: 'text', text: '' } },
  { type: 'content_block_delta', index: 0, delta: { type: 'text_delta', text } },
  { type: 'content_block_stop', index: 0 },
]

/** Local Messages endpoint; a held second response proves Web shutdown leaves the turn alive. */
export async function startSmokeModel() {
  const held = Promise.withResolvers(), release = Promise.withResolvers()
  const failure = Promise.withResolvers()
  let calls = 0
  const server = createServer((request, response) => {
    void (async () => {
      const body = JSON.parse(Buffer.concat(await Array.fromAsync(request)).toString('utf8'))
      const agent = body.tools?.some(tool => tool.name === 'android_files')
      let events = textEvents('smoke title'), stop = 'end_turn'
      if (agent) {
        calls++
        if (calls === 1) {
          events = [
            { type: 'content_block_start', index: 0,
              content_block: { type: 'tool_use', id: 'smoke-tool', name: 'android_files', input: {} } },
            { type: 'content_block_delta', index: 0, delta: { type: 'input_json_delta',
              partial_json: JSON.stringify({ action: 'read', root: 'smoke-root', path: 'test.txt' }) } },
            { type: 'content_block_stop', index: 0 },
          ]
          stop = 'tool_use'
        } else {
          assert.match(JSON.stringify(body.messages), /authorized fixture text/)
          held.resolve()
          await release.promise
          events = textEvents('smoke completed')
        }
      }
      response.writeHead(200, { 'content-type': 'text/event-stream' })
      for (const event of [
        { type: 'message_start', message: { id: `smoke-${calls}`, model: body.model, usage: { input_tokens: 3, output_tokens: 0 } } },
        ...events,
        { type: 'message_delta', delta: { stop_reason: stop }, usage: { output_tokens: 1 } },
        { type: 'message_stop' },
      ]) response.write(`data: ${JSON.stringify(event)}\n\n`)
      response.end()
    })().catch(error => { response.destroy(); failure.reject(error) })
  })
  server.listen(0, '127.0.0.1')
  await once(server, 'listening')
  return {
    url: `http://127.0.0.1:${server.address().port}`,
    waiting: Promise.race([held.promise, failure.promise]),
    release: () => release.resolve(),
    calls: () => calls,
    async close() { release.resolve(); server.closeAllConnections(); await new Promise(resolve => server.close(resolve)) },
  }
}
