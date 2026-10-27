import assert from 'node:assert/strict'
import { createHash, randomUUID } from 'node:crypto'
import { workflowModelScenario } from './workflow-model-fixture.mjs'
import { WORKFLOW_DEVICE_CHECKS, WORKFLOW_UNVERIFIED_CHECKS } from './workflow-checks.mjs'

function errorCauses(error, depth = 0, seen = new Set()) {
  const detail = { name: String(error?.name ?? 'Error').slice(0, 80),
    message: String(error?.message ?? error).slice(0, 512) }
  if (typeof error?.code === 'string') detail.code = error.code.slice(0, 80)
  if (depth === 2 || seen.has(error)) return detail
  seen.add(error)
  const causes = [...(error?.cause === undefined ? [] : [error.cause]),
    ...(Array.isArray(error?.errors) ? error.errors.slice(0, 3) : [])]
  if (causes.length) detail.causes = causes.slice(0, 3).map(value => errorCauses(value, depth + 1, seen))
  return detail
}

/** Keep one callback/preset owner alive across the selected acceptance suites.
 * @param {object} options - Real host services, native transport and acceptance callback routing.
 * @returns {Promise<object>} Owner, acknowledged observations and a disposer that joins background work.
 */
export async function createWorkflowAcceptance({ ctx, transport, agent, nativeModule, callbackRouting }) {
  const { NativeWorkflowGuestCallbacks } = await nativeModule('native-workflow-guest-callbacks.mjs')
  const { createNativeWorkflowPrivateOwner } = await nativeModule('native-workflow-private-owner.mjs')
  const { registerAndroidWorkflowTool } = await nativeModule('tool-native-workflow.mjs')
  const progress = [], receipts = new Map(), releases = new Set(), admissions = new Map()
  const callbackFailures = [], callbackClosures = [], callbackStarts = [], nativeFailures = []
  const callbackObservers = new Set()
  const observe = (rows, value) => { if (rows.length === 128) rows.shift(); rows.push(value) }
  // Observe actual responses. Never synthesize a native result, retirement or callback acknowledgement.
  const observedTransport = { async request(method, params, ...options) {
    let result
    try { result = await transport.request(method, params, ...options) }
    catch (error) {
      observe(nativeFailures, { runId: params.runId, method, error: errorCauses(error) })
      throw error
    }
    if (method === 'native.workflow.admit') admissions.set(params.runId, structuredClone(params))
    if (method === 'native.workflow.settle') receipts.set(params.runId, structuredClone(result))
    if (method === 'native.workflow.release' && result === true) releases.add(params.runId)
    return result
  } }
  const callbacks = new NativeWorkflowGuestCallbacks(observedTransport)
  const unbind = callbackRouting.bind('workflow', {
    async call(params) {
      observe(callbackStarts, { runId: params.runId, action: params.action })
      for (const listener of callbackObservers) listener(params)
      try {
        const result = await callbacks.call(params)
        if (result.denied?.code === 'MODEL_ROUTE_DENIED') {
          observe(callbackFailures, { runId: params.runId, action: params.action,
            code: result.denied.code, message: 'Workflow child cannot widen its parent model route' })
        }
        if (params.action === 'WORKFLOW_PROGRESS') {
          assert.ok(progress.length < 4096, 'Acceptance progress observation is bounded')
          progress.push({ runId: params.runId, events: structuredClone(params.value) })
        }
        return result
      } catch (error) {
        observe(callbackFailures, { runId: params.runId, action: params.action,
          message: String(error).slice(0, 512), error: errorCauses(error) })
        throw error
      }
    },
    async close(params) {
      try {
        const result = await callbacks.close(params)
        observe(callbackClosures, { runId: params.runId, closed: result?.closed === true })
        return result
      } catch (error) {
        observe(callbackClosures, { runId: params.runId, closed: false,
          message: String(error).slice(0, 512), error: errorCauses(error) })
        throw error
      }
    },
  })
  const owner = createNativeWorkflowPrivateOwner(ctx, callbacks, observedTransport)
  try {
    assert.equal(registerAndroidWorkflowTool(ctx, { owner }), false)
    assert.equal(ctx.tools.get('workflow', agent), undefined)
    assert.equal(registerAndroidWorkflowTool(ctx, { owner, available: () => true }), true)
    return { owner, progress, receipts, releases, admissions, callbackStarts, callbackFailures, callbackClosures, nativeFailures,
      observeCallbackStarts(listener) { callbackObservers.add(listener); return () => callbackObservers.delete(listener) },
      inspectNative: (runId, signal) => transport.request('native.workflow.inspect', { runId }, signal),
      async dispose() { try { await owner.dispose() } finally { unbind() } } }
  } catch (error) {
    try { await owner.dispose() } finally { unbind() }
    throw error
  }
}

function bounded(promise, milliseconds, message) {
  let timer
  return Promise.race([promise, new Promise((_, reject) => {
    timer = setTimeout(() => reject(new Error(message)), milliseconds)
  })]).finally(() => clearTimeout(timer))
}

/** Execute named real-native checks; stop after failure and retain unexecuted checks as unverified.
 * @param {object} options - Original ToolRuntime, parent Agent, scripted model and native workflow owner.
 * @returns {Promise<object>} Named observations and explicit lifecycle gaps, never synthetic native receipts.
 */
export async function runWorkflowAcceptance({ ctx, agent, adapter, workflow }) {
  const checks = [], children = new Map(), activeCalls = new Set()
  const suiteAbort = new AbortController()
  const unregister = ctx.on('subagent/start', info => {
    const child = ctx.agents.get(info.id)
    assert.ok(child, 'Subagent event must identify an actual live Agent')
    children.set(info.id, child)
  })
  const execute = (name, args, signal) => {
    const promise = ctx.tools.execute({ name, arguments: args, callId: `workflow-acceptance-${randomUUID()}`,
      agent, signal: AbortSignal.any([suiteAbort.signal, signal ?? AbortSignal.timeout(120_000)]) })
    activeCalls.add(promise)
    promise.finally(() => activeCalls.delete(promise)).catch(() => {})
    return promise
  }
  const success = result => { assert.equal(result.isError, false, JSON.stringify(result)); return result.value }
  const events = () => agent.session.snapshotEvents()
  const starts = () => events().filter(event => event.type === 'tool-workflow/run-start')

  async function evidence(runId, state, expectedChildren) {
    assert.equal(await ctx.sessions.flush(agent.session), true)
    const observed = await workflow.owner.inspectRun({ sessionId: agent.session.id, runId })
    assert.equal(observed.state, state)
    assert.equal(observed.requiresReview, false)
    const native = await workflow.inspectNative(runId)
    assert.equal(native.state, ({ completed: 'COMPLETED', failed: 'FAILED', cancelled: 'CANCELLED' })[state])
    const receipt = workflow.receipts.get(runId)
    assert.equal(receipt?.state, native.state)
    assert.equal(receipt.sessionId, agent.session.id)
    assert.equal(receipt.requiresReview, false)
    assert.equal(workflow.releases.has(runId), true, 'Native release must be acknowledged after retirement')
    if (state !== 'completed') assert.equal(receipt.outputJson, null, 'Failure must not publish a successful output')
    assert.equal(native.children.length, expectedChildren)
    const childEvidence = []
    for (const entry of native.children) {
      assert.equal(entry.state, 'RETIRED', 'Every native reservation must retire, including rejected activation')
      assert.equal(ctx.agents.get(entry.childId), undefined)
      const child = children.get(entry.childId)
      if (!child) { childEvidence.push({ childId: entry.childId, activation: 'not-published', retired: true }); continue }
      assert.notEqual(child.session.id, agent.session.id)
      const reader = await ctx.sessionPersistence.open(child.session.id, 'read')
      let saved
      try { ({ events: saved } = await reader.read(0, 10000)) } finally { await reader.close() }
      assert.ok(saved.length > 0 && saved.length < 10000, 'A retired child needs a bounded durable Session')
      childEvidence.push({ childId: entry.childId, childSessionId: child.session.id, retired: true,
        eventCount: saved.length, logSha256: createHash('sha256').update(JSON.stringify(saved)).digest('hex') })
    }
    const runEvents = events().filter(event => event.data?.runId === runId)
    assert.equal(runEvents.filter(event => event.type === 'tool-workflow/run-start').length, 1)
    const ends = runEvents.filter(event => event.type === 'tool-workflow/run-end')
    assert.equal(ends.length, 1, 'Exactly one durable terminal outcome is required')
    assert.equal(ends[0].data.stopReason, state === 'failed' ? 'error' : state)
    const members = runEvents.filter(event => event.type === 'tool-workflow/agent-start')
    for (const member of members) {
      assert.equal(runEvents.filter(event => event.type === 'tool-workflow/agent-end'
        && event.data.seq === member.data.seq).length, 1)
    }
    return { runId, state, nativeState: native.state, released: true, terminalCount: ends.length,
      startedMembers: members.length, children: childEvidence }
  }

  async function runScript(script, { args, background = false, signal, expected = 'completed', children: count = 0 } = {}) {
    const startCount = starts().length
    const result = await execute('workflow', { script, ...(args === undefined ? {} : { args }),
      ...(background ? { run_in_background: true } : {}),
      meta: { name: `fixture-${randomUUID()}`, description: 'Bounded workflow acceptance fixture' } }, signal)
    if (background) return success(result)
    assert.equal(starts().length, startCount + 1, 'The original tool must admit exactly one native run')
    const runId = starts().at(-1).data.runId
    if (expected === 'completed') assert.equal(success(result).runId, runId)
    else assert.equal(result.isError, true, 'A native failure must remain a ToolRuntime failure')
    return { result, value: result.value?.result, evidence: await evidence(runId, expected, count) }
  }

  async function modelScenario(options, body) {
    const scenario = workflowModelScenario(options)
    adapter.scriptedStream = scenario.stream
    try {
      const value = await body(scenario)
      assert.equal(scenario.active, 0, 'A settled workflow cannot retain an active model stream')
      return value
    } catch (error) {
      error.modelObservation = { active: scenario.active, prompts: scenario.prompts.slice(0, 128),
        aborted: scenario.aborted.slice(0, 128), finished: scenario.finished.slice(0, 128) }
      throw error
    } finally { adapter.scriptedStream = null }
  }

  const cases = [
    async () => {
      const run = await runScript('return args.a + args.b', { args: { a: 19, b: 23 } })
      assert.equal(run.value, 42)
      return run.evidence
    },
    async () => {
      const before = adapter.calls
      const run = await runScript("return await agent('analyze supplied fixture')", { children: 1 })
      assert.equal(run.value, 'device child answer')
      assert.equal(adapter.calls - before, 1)
      assert.ok(run.evidence.children[0].childSessionId)
      return run.evidence
    },
    () => modelScenario({ barrier: true }, async model => {
      const run = await runScript(`phase('Parallel'); log('parallel-start');
        const concurrent = await parallel([() => agent('workflow-fixture:first', {label:'First'}),
          () => agent('workflow-fixture:second', {label:'Second'}), () => { throw new Error('ordinary thunk') }]);
        phase('Pipeline'); log('pipeline-start');
        const sequential = await pipeline(args.items, item => item.toLowerCase(),
          (value, original, index) => agent('workflow-fixture:' + value, {label:original,phase:'Item-'+index}),
          (answer, original, index) => ({answer, original, index}));
        return {concurrent, sequential};`, { args: { items: ['THIRD', 'FOURTH'] }, children: 4 })
      assert.deepEqual(run.value, { concurrent: ['answer:first', 'answer:second', null], sequential: [
        { answer: 'answer:third', original: 'THIRD', index: 0 }, { answer: 'answer:fourth', original: 'FOURTH', index: 1 }] })
      assert.equal(model.maxActive, 2)
      assert.equal(model.prompts.length, 4)
      const progress = workflow.progress.filter(row => row.runId === run.evidence.runId).flatMap(row => row.events)
      assert.deepEqual(progress.filter(row => row.type === 'phase').map(row => row.title), ['Parallel', 'Pipeline'])
      assert.deepEqual(progress.filter(row => row.type === 'log').map(row => row.message), ['parallel-start', 'pipeline-start'])
      assert.deepEqual(progress.filter(row => row.type === 'agent-start').map(row => row.info.phase),
        ['Parallel', 'Parallel', 'Item-0', 'Item-1'])
      return { ...run.evidence, maxConcurrentModels: model.maxActive, acknowledgedProgress: progress }
    }),
    () => modelScenario({}, async () => {
      const schema = { type: 'object', properties: { label: { type: 'string' }, nested: { type: 'object' },
        list: { type: 'array', items: {} } }, required: ['label', 'nested', 'list'], additionalProperties: false }
      const run = await runScript(`const child=await agent('workflow-fixture:structured', {schema:args.schema});
        const shared={nullable:null,unicode:'中文',list:[true,0,2.5]};
        return {child, shared:[shared,shared], args:args.input};`,
      { args: { schema, input: { name: 'roundtrip', values: [null, false, 123] } }, children: 1 })
      const shared = { nullable: null, unicode: '中文', list: [true, 0, 2.5] }
      assert.deepEqual(run.value, { child: { label: 'verified', nested: { count: 3, unicode: '中文' }, list: [true, null, 2] },
        shared: [shared, shared], args: { name: 'roundtrip', values: [null, false, 123] } })
      const reader = await ctx.sessionPersistence.open(run.evidence.children[0].childSessionId, 'read')
      let saved
      try { ({ events: saved } = await reader.read(0, 10000)) } finally { await reader.close() }
      const calls = saved.filter(event => event.type === 'tool/call' && event.data.name === 'structured_output')
      assert.equal(calls.length, 1)
      assert.ok(saved.some(event => event.type === 'tool/result' && event.data.message.isError === false
        && event.data.message.source.callId === calls[0].data.callId))
      return run.evidence
    }),
    async () => {
      const runs = []
      for (const script of ['const value={}; value.self=value; return value;', 'return -0;', 'return {missing:undefined};']) {
        runs.push((await runScript(script, { expected: 'failed' })).evidence)
      }
      return { runs, invalidResults: ['cycle', 'negative-zero', 'undefined-member'] }
    },
    () => modelScenario({}, async model => {
      const cap = await runScript(`for(let n=0;n<8;n++) await agent('workflow-fixture:limit-'+n);
        try { await agent('workflow-fixture:ninth') } catch {} return 'must-not-publish';`,
      { expected: 'failed', children: 8 })
      assert.equal(model.prompts.length, 8)
      assert.equal(model.prompts.includes('ninth'), false)
      const items = await runScript("try { await parallel(Array(33).fill(() => 1)) } catch {} return 'must-not-publish';",
        { expected: 'failed' })
      return { runs: [cap.evidence, items.evidence], admittedChildren: 8, ninthChildStarted: false }
    }),
    () => modelScenario({}, async model => {
      const run = await runScript(`return await parallel([() => agent('workflow-fixture:failure'),
        () => agent('workflow-fixture:survivor')]);`, { children: 2 })
      assert.deepEqual(run.value, [null, 'answer:survivor'])
      assert.ok(model.failed.length > 0)
      const outcomes = events().filter(row => row.type === 'tool-workflow/agent-end'
        && row.data.runId === run.evidence.runId).map(row => row.data.outcome).sort()
      assert.deepEqual(outcomes, ['completed', 'failed'])
      return { ...run.evidence, childOutcomes: outcomes }
    }),
    () => modelScenario({}, async () => {
      const run = await runScript(`return await parallel([() => agent('workflow-fixture:hold-infrastructure'),
        () => agent('workflow-fixture:denied', {provider:'not-the-parent-provider'})]);`,
      { expected: 'failed', children: 2 })
      assert.ok(run.evidence.children.some(child => child.childSessionId), 'At least one real child must activate')
      assert.ok(workflow.callbackFailures.some(row => row.runId === run.evidence.runId
        && row.action === 'WORKFLOW_START_CHILD' && /model route/.test(row.message)))
      return { ...run.evidence, deniedActivation: true }
    }),
    () => modelScenario({}, async model => {
      const controller = new AbortController()
      const pending = runScript("return await agent('workflow-fixture:hold-foreground')",
        { signal: controller.signal, expected: 'cancelled', children: 1 })
      try {
        await bounded(Promise.race([model.entered, pending.then(() => {
          throw new Error('Foreground run finished before its held model entered')
        })]), 15_000, 'Foreground child never entered its model')
        controller.abort(new Error('Acceptance foreground cancellation'))
        const run = await pending
        assert.deepEqual(model.aborted, ['hold-foreground'])
        return run.evidence
      } finally { controller.abort(); await pending.catch(() => {}) }
    }),
    () => modelScenario({}, async () => {
      const run = await runScript("phase('Background'); log('background-start'); return await agent('workflow-fixture:background')",
        { background: true })
      assert.equal(run.kind, 'background')
      const settled = await ctx.jobs.wait(run.jobId, 30_000, agent.id)
      assert.equal(settled.status, 'completed')
      const output = success(await execute('job_output', { job_id: run.jobId }))
      assert.match(JSON.stringify(output), /answer:background/)
      return { ...await evidence(run.runId, 'completed', 1), jobId: run.jobId }
    }),
    () => modelScenario({}, async model => {
      const run = await runScript("return await agent('workflow-fixture:hold-background')", { background: true })
      assert.equal(run.kind, 'background')
      await bounded(model.entered, 15_000, 'Background child never entered its model')
      success(await execute('job_kill', { job_id: run.jobId }))
      const settled = await ctx.jobs.wait(run.jobId, 15_000, agent.id)
      assert.equal(settled.status, 'killed')
      assert.deepEqual(model.aborted, ['hold-background'])
      return { ...await evidence(run.runId, 'cancelled', 1), jobId: run.jobId }
    }),
  ]
  assert.equal(cases.length, WORKFLOW_DEVICE_CHECKS.length)
  try {
    for (const [index, check] of cases.entries()) {
      const before = starts().length
      try { checks.push({ name: WORKFLOW_DEVICE_CHECKS[index], status: 'passed', evidence: await check() }) }
      catch (error) {
        suiteAbort.abort(error)
        await Promise.allSettled(activeCalls)
        // Diagnostic reads are bounded independently of the already cancelled run.
        // They cannot change the pass condition or infer retirement from an RPC error.
        const observedRuns = await Promise.all(starts().slice(before).slice(0, 8).map(async event => {
          const runId = event.data.runId, receipt = workflow.receipts.get(runId)
          let nativeInspection
          try {
            const native = await bounded(workflow.inspectNative(runId, AbortSignal.timeout(3000)), 3000,
              'Native workflow failure inspection timed out')
            nativeInspection = { state: native.state, children: native.children.slice(0, 128).map(child => ({
              childId: child.childId, state: child.state, liveAgent: ctx.agents.get(child.childId) !== undefined,
              activated: children.has(child.childId),
            })) }
          } catch (failure) { nativeInspection = { unavailable: String(failure).slice(0, 512) } }
          const runEvents = events().filter(row => row.data?.runId === runId)
          return { runId, nativeReceipt: receipt ? { state: receipt.state, requiresReview: receipt.requiresReview } : null,
            releaseAcknowledged: workflow.releases.has(runId), nativeInspection,
            callbackFailures: workflow.callbackFailures.filter(row => row.runId === runId),
            callbackClosures: workflow.callbackClosures.filter(row => row.runId === runId),
            sessionTerminal: runEvents.filter(row => row.type === 'tool-workflow/run-end')
              .slice(0, 2).map(row => ({ stopReason: row.data.stopReason })),
            memberEnds: runEvents.filter(row => row.type === 'tool-workflow/agent-end').slice(0, 128)
              .map(row => ({ seq: row.data.seq, childId: row.data.childId, outcome: row.data.outcome })),
          }
        }))
        checks.push({ name: WORKFLOW_DEVICE_CHECKS[index], status: 'failed', observedRuns,
          ...(error.modelObservation ? { modelObservation: error.modelObservation } : {}),
          error: String(error?.stack ?? error).slice(0, 4000) })
        for (const name of WORKFLOW_DEVICE_CHECKS.slice(index + 1)) checks.push({ name, status: 'unverified' })
        break
      }
    }
    return { suite: 'workflow', passed: checks.filter(row => row.status === 'passed').length,
      failed: checks.filter(row => row.status === 'failed').length, checks,
      unverified: [...WORKFLOW_UNVERIFIED_CHECKS] }
  } finally { adapter.mode = 'answer'; adapter.entered = null; adapter.scriptedStream = null; unregister() }
}
