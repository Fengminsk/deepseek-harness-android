import { IsolatedExecutionContractError } from './isolated-execution-contract.mjs'

const AsyncFunction = (async () => {}).constructor
const IDENTIFIER = /^[A-Za-z][A-Za-z0-9_]*$/
const RESERVED = new Set(['__proto__', 'constructor', 'prototype', 'then'])

// A fixed, App-authored prelude. Tool names are passed as JSON input data,
// never interpolated into executable source. The native V8 host remains the
// only way out of the guest; the callback port enforces the reviewed list.
const SDK_PRELUDE = 'const tools=(()=>{const bound=Object.create(null);let next=0;for(const name of input.toolNames){Object.defineProperty(bound,name,{value:async args=>{const reply=await host.callAsync({callId:++next,name,arguments:args===undefined?{}:args});if(reply.error){const failure=new Error(reply.error.message);failure.code=reply.error.code;throw failure}return reply.value},enumerable:true})}return Object.freeze(bound)})();\n'

/** Build the original `await tools.name(args)` shape for reviewed names only. */
export function prepareModelPtcGuestSdk(program, toolNames) {
  if (typeof program !== 'string' || !Array.isArray(toolNames)
    || toolNames.length > 32 || toolNames.some(name => typeof name !== 'string'
      || !IDENTIFIER.test(name) || RESERVED.has(name))
    || new Set(toolNames).size !== toolNames.length) {
    throw new IsolatedExecutionContractError('ANDROID_TOOL_HOST_INVALID',
      'A reviewed JavaScript tool name list and compiled body are required')
  }
  const guestProgram = SDK_PRELUDE + program
  try { new AsyncFunction('input', 'host', `'use strict';\n${guestProgram}`) }
  catch {
    throw new IsolatedExecutionContractError('ANDROID_PTC_TYPESCRIPT_INVALID',
      'Model body conflicts with the App-owned tools binding')
  }
  return Object.freeze({ program: guestProgram,
    args: Object.freeze({ toolNames: Object.freeze([...toolNames]) }) })
}
