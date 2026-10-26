import { createHash } from 'node:crypto'
import { stripTypeScriptTypes } from 'node:module'
import {
  IsolatedExecutionContractError, prepareIsolatedExecution,
} from './isolated-execution-contract.mjs'

const encoder = new TextEncoder()
const MAX_BODY_BYTES = 64 * 1024
const PREFIX = 'async function __dsh_program__() {\n'
const SUFFIX = '\n}'
const NATIVE_PRELUDE_LINES = 1 // PtcScriptEngine passes "'use strict';\n" before the body.
const AsyncFunction = (async () => {}).constructor
const RUN_FIELDS = ['kind', 'runId', 'sessionId', 'program', 'args', 'deadlineMillis']

function invalid(message) {
  throw new IsolatedExecutionContractError('ANDROID_PTC_TYPESCRIPT_INVALID', message)
}

function hash(text) {
  return createHash('sha256').update(text, 'utf8').digest('hex')
}

function lineLengths(text) {
  return text.split('\n').map(line => line.length)
}

function sameLineLayout(left, right) {
  const a = lineLengths(left)
  const b = lineLengths(right)
  return a.length === b.length && a.every((length, index) => length === b[index])
}

/**
 * Compile one original DSH erasable TypeScript async-function body into the
 * JavaScript body accepted by the Android V8 entry. Compilation never runs
 * user code or authorizes a run. Native admission and its policy remain separate.
 *
 * The original Node provider wraps the body before calling Node's type
 * stripper. This uses the same wrapper and rejects any output whose physical
 * line/UTF-16-column layout changed, so the body can be correlated with the
 * recorded source. Native error statuses currently contain no locations.
 */
export function compileIsolatedTypeScriptBody(source) {
  if (typeof source !== 'string' || source.trim().length === 0
    || encoder.encode(source).length > MAX_BODY_BYTES
    || /[\uD800-\uDBFF](?![\uDC00-\uDFFF])|(?<![\uD800-\uDBFF])[\uDC00-\uDFFF]/u.test(source)) {
    invalid('Invalid or oversized TypeScript function body')
  }

  let stripped
  try {
    stripped = stripTypeScriptTypes(PREFIX + source + SUFFIX)
  } catch {
    invalid('TypeScript function body has invalid or non-erasable syntax')
  }
  if (!stripped.startsWith(PREFIX) || !stripped.endsWith(SUFFIX)) {
    invalid('TypeScript erasure changed the function boundary')
  }
  const javaScript = stripped.slice(PREFIX.length, -SUFFIX.length)
  if (!sameLineLayout(source, javaScript)
    || encoder.encode(javaScript).length > MAX_BODY_BYTES) {
    invalid('TypeScript erasure changed source locations or exceeded the guest limit')
  }
  // The stripper parses a wrapped function, but the native guest compiles the
  // body as a separate AsyncFunction argument. Check that exact grammar here;
  // never interpolate model source into a host-evaluated expression.
  try {
    new AsyncFunction('input', 'host', `'use strict';\n${javaScript}`)
  } catch {
    invalid('TypeScript function body is not a valid async function body')
  }

  return Object.freeze({
    language: 'typescript-function-body',
    javaScript,
    sourceSha256: hash(source),
    javaScriptSha256: hash(javaScript),
    sourceLines: lineLengths(source).length,
    nativePreludeLines: NATIVE_PRELUDE_LINES,
  })
}

/** Map a location in the body string passed to native AsyncFunction back to
 * the original TypeScript body. This does not interpret V8 stack-frame offsets.
 */
export function originalTypeScriptLocation(compiled, nativeBodyLine, utf16Column) {
  if (!compiled || compiled.language !== 'typescript-function-body'
    || !Number.isSafeInteger(compiled.sourceLines) || compiled.sourceLines < 1
    || compiled.nativePreludeLines !== NATIVE_PRELUDE_LINES
    || !Number.isSafeInteger(nativeBodyLine) || !Number.isSafeInteger(utf16Column)
    || nativeBodyLine <= NATIVE_PRELUDE_LINES
    || nativeBodyLine > compiled.sourceLines + NATIVE_PRELUDE_LINES
    || utf16Column < 1) return null
  return Object.freeze({ line: nativeBodyLine - NATIVE_PRELUDE_LINES, utf16Column })
}

/**
 * Prepare a trusted, App-owned TypeScript script request for native admission.
 * The returned execution contains only the JavaScript guest body; the source
 * and both hashes stay alongside it for the owner's durable audit record.
 * This helper never admits or executes the run and does not open model PTC.
 */
export function prepareIsolatedTypeScriptRun(request, scope, parentScope) {
  if (request === null || typeof request !== 'object' || Array.isArray(request)
    || ![Object.prototype, null].includes(Object.getPrototypeOf(request))) {
    invalid('Invalid TypeScript execution request')
  }
  const own = Object.create(null)
  for (const key of Reflect.ownKeys(request)) {
    const descriptor = Object.getOwnPropertyDescriptor(request, key)
    if (typeof key !== 'string' || !RUN_FIELDS.includes(key)
      || !descriptor || !Object.hasOwn(descriptor, 'value')) {
      invalid('Invalid TypeScript execution request fields')
    }
    own[key] = descriptor.value
  }
  if (own.kind !== 'script' || !['runId', 'sessionId', 'program', 'deadlineMillis']
    .every(key => Object.hasOwn(own, key))) {
    invalid('Invalid TypeScript script identity or program')
  }
  const compiled = compileIsolatedTypeScriptBody(own.program)
  const execution = prepareIsolatedExecution({ ...own, program: compiled.javaScript }, scope, parentScope)
  return Object.freeze({ source: own.program, compiled, execution })
}
