import { Socket } from 'node:net'
import { PassThrough } from 'node:stream'
import { StringDecoder } from 'node:string_decoder'
import { JsonRpcLineTransport } from '@deepseek-ai/dsh-sdk-protocol'

/** Own the Android IPC socket independently of stdout/stderr diagnostic output. */
export function createRuntimeTransport() {
  const descriptor = process.env.DSH_ANDROID_IPC_FD
  if (descriptor === undefined) {
    if (process.platform === 'android') throw new Error('Android IPC descriptor is missing.')
    const transport = new JsonRpcLineTransport(process.stdin, process.stdout)
    return { transport, close: () => transport.close() }
  }
  if (!/^[1-9][0-9]*$/.test(descriptor) || !Number.isSafeInteger(Number(descriptor))
    || Number(descriptor) < 3 || Number(descriptor) > 0x7fffffff) {
    throw new Error('Android IPC descriptor must be an integer from 3 through 2147483647.')
  }
  return createSocketTransport(new Socket({ fd: Number(descriptor), readable: true, writable: true }))
}

/** Own a dedicated socket and admit complete native protocol frames before SDK dispatch. */
export function createSocketTransport(socket) {
  const input = new PassThrough()
  const transport = new JsonRpcLineTransport(input, socket)
  const decoder = new StringDecoder('utf8')
  let buffered = '', closed = false
  const fail = message => { closed = true; socket.destroy(new Error(message)) }
  // The generic SDK permits malformed lines. This private native channel must
  // instead fail visibly; never print the frame, which can contain credentials.
  socket.on('data', chunk => {
    if (closed) return
    buffered += decoder.write(chunk)
    for (;;) {
      const newline = buffered.indexOf('\n')
      if (newline < 0) return
      const line = buffered.slice(0, newline).trim()
      buffered = buffered.slice(newline + 1)
      let frame
      try { frame = JSON.parse(line) } catch {
        fail('Android IPC received a malformed JSON frame.')
        return
      }
      if (!frame || typeof frame !== 'object' || Array.isArray(frame)) {
        fail('Android IPC received a non-object frame.')
        return
      }
      input.write(`${line}\n`)
    }
  })
  socket.on('end', () => {
    if ((buffered + decoder.end()).trim()) fail('Android IPC ended with an incomplete frame.')
    else input.end()
  })
  socket.on('error', error => {
    console.error(`Pocket Harness IPC failed: ${error.message}`)
    transport.close()
  })
  socket.on('close', () => { transport.close(); input.destroy() })
  return {
    transport,
    close() {
      if (closed) return
      closed = true
      transport.close()
      input.destroy()
      socket.destroy()
    },
  }
}
