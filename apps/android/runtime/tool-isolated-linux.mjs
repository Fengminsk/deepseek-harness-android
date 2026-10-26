import { defineTool } from '@deepseek-ai/dsh-tools'

const TEXT_LIMIT = 64 * 1024
const TEXT_COMMANDS = new Set(['sha256', 'count_bytes', 'count_lines', 'sort_lines', 'filter_literal'])
const NO_INPUT_COMMANDS = new Set(['kernel', 'identity'])
const encoder = new TextEncoder()

/** Keep model arguments narrower than the internal native command carrier. */
export function prepareIsolatedLinuxToolRequest(args) {
  if (!args || typeof args !== 'object' || Array.isArray(args)
    || ![Object.prototype, null].includes(Object.getPrototypeOf(args))) {
    throw new TypeError('Invalid Android Linux command arguments')
  }
  const keys = Reflect.ownKeys(args)
  if (keys.some(key => !['command', 'input', 'literal'].includes(key)
    || !Object.hasOwn(Object.getOwnPropertyDescriptor(args, key), 'value'))) {
    throw new TypeError('Unsupported Android Linux command argument')
  }
  const command = args.command
  if (!NO_INPUT_COMMANDS.has(command) && !TEXT_COMMANDS.has(command)) {
    throw new TypeError('Unsupported Android Linux command')
  }
  if (NO_INPUT_COMMANDS.has(command)) {
    if (args.input !== undefined || args.literal !== undefined) {
      throw new TypeError(`${command} takes no input or literal`)
    }
    return { command }
  }
  if (typeof args.input !== 'string') throw new TypeError(`${command} requires text input`)
  const stdin = encoder.encode(args.input)
  if (stdin.byteLength > TEXT_LIMIT || stdin.includes(0)) {
    throw new TypeError('Android Linux command input exceeds its text limits')
  }
  if (command === 'filter_literal') {
    if (typeof args.literal !== 'string' || args.literal.length === 0
      || encoder.encode(args.literal).byteLength > 128
      || [...args.literal].some(character => character.codePointAt(0) < 0x20
        || character.codePointAt(0) === 0x7f)) {
      throw new TypeError('filter_literal requires a bounded literal')
    }
    return { command, stdin, argument: args.literal }
  }
  if (args.literal !== undefined) throw new TypeError(`${command} takes no literal`)
  return { command, stdin }
}

/** Present only verified completed output; aborted or uncertain runs have no result body. */
export function projectIsolatedLinuxToolResult(receipt) {
  if (receipt.kind !== 'COMPLETED') {
    return { status: receipt.kind.toLowerCase(), command: receipt.command }
  }
  return {
    status: 'completed', command: receipt.command, output: receipt.output,
    exitCode: receipt.exitCode,
  }
}

/** Register a bounded utility tool. It cannot invoke a shell or open an App path. */
export function registerIsolatedLinuxTool(ctx, carrier) {
  ctx.effect(() => ctx.tools.register(defineTool({
    name: 'android_linux',
    description: 'Run one fixed Linux utility in an Android isolated UID: kernel, identity, sha256, count_bytes, count_lines, sort_lines, or filter_literal. Input is text supplied in this call. No shell, filesystem path, package installation, or network access is available.',
    parameters: {
      command: { type: 'string', required: true },
      input: { type: 'string' },
      literal: { type: 'string' },
    },
    output: {
      schema: { type: 'json' },
      render: (_args, result) => [{ type: 'text', text: JSON.stringify(result) }],
    },
    async execute(args, execution) {
      if (!execution.agent) throw new Error('Android Linux commands require an Agent session')
      const request = prepareIsolatedLinuxToolRequest(args)
      const receipt = await carrier.execute(request, execution.signal)
      return projectIsolatedLinuxToolResult(receipt)
    },
  })))
}
