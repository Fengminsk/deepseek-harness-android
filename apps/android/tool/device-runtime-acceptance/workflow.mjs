import assert from 'node:assert/strict'

/** Keep one callback/preset owner alive across the selected acceptance suites. */
export async function createWorkflowAcceptance({ ctx, transport, agent, nativeModule, callbackRouting }) {
  const { NativeWorkflowGuestCallbacks } = await nativeModule('native-workflow-guest-callbacks.mjs')
  const { createNativeWorkflowPrivateOwner } = await nativeModule('native-workflow-private-owner.mjs')
  const { registerAndroidWorkflowTool } = await nativeModule('tool-native-workflow.mjs')
  const callbacks = new NativeWorkflowGuestCallbacks(transport)
  const unbind = callbackRouting.bind('workflow', callbacks)
  const owner = createNativeWorkflowPrivateOwner(ctx, callbacks, transport)
  try {
    assert.equal(registerAndroidWorkflowTool(ctx, { owner }), false)
    assert.equal(ctx.tools.get('workflow', agent), undefined)
    assert.equal(registerAndroidWorkflowTool(ctx, { owner, available: () => true }), true)
    return { owner, async dispose() {
      try { await owner.dispose() } finally { unbind() }
    } }
  } catch (error) {
    try { await owner.dispose() } finally { unbind() }
    throw error
  }
}

export async function runWorkflowAcceptance({ ctx, agent, adapter, workflow }) {
  const { owner } = workflow
  const details = []
  const execute = (name, args, callId) => ctx.tools.execute({ name, arguments: args, callId,
    agent, signal: AbortSignal.timeout(120_000) })
  function success(result) { assert.equal(result.isError, false, JSON.stringify(result)); return result.value }
  try {
    const compute = success(await execute('workflow', { script: 'return args.a + args.b',
      args: { a: 19, b: 23 }, meta: { name: 'device-compute', description: 'Compute a supplied sum' } }, 'acceptance-compute'))
    assert.equal(compute.result, 42)
    assert.equal((await owner.inspectRun({ sessionId: agent.id, runId: compute.runId })).state, 'completed')
    details.push({ case: 'real-tool-runtime-native-compute', runId: compute.runId })
    const child = success(await execute('workflow', { script: "return await agent('analyze supplied fixture')",
      meta: { name: 'device-child', description: 'Invoke one confined fixture model child' } }, 'acceptance-child'))
    assert.equal(child.result, 'device child answer')
    assert.equal(adapter.calls, 1)
    assert.equal((await owner.inspectRun({ sessionId: agent.id, runId: child.runId })).state, 'completed')
    details.push({ case: 'real-confined-child-and-durable-session', runId: child.runId })
    adapter.mode = 'hold'
    let entered
    const childEntered = new Promise(resolve => { entered = resolve })
    adapter.entered = entered
    const background = success(await execute('workflow', { script: "return await agent('hold until cancelled')",
      run_in_background: true, meta: { name: 'device-cancel', description: 'Cancel a live confined child' } }, 'acceptance-background'))
    assert.equal(background.kind, 'background')
    await Promise.race([childEntered, new Promise((_, reject) => {
      const timer = setTimeout(() => reject(new Error('Confined child never entered its model')), 15_000)
      timer.unref()
    })])
    success(await execute('job_kill', { job_id: background.jobId }, 'acceptance-kill'))
    const settled = await ctx.jobs.wait(background.jobId, 15_000, agent.id)
    assert.equal(settled.status, 'killed')
    assert.equal((await owner.inspectRun({ sessionId: agent.id, runId: background.runId })).state, 'cancelled')
    const events = agent.session.snapshotEvents()
    for (const run of [compute, child, background]) {
      assert.equal(events.filter(event => event.type === 'tool-workflow/run-start' && event.data.runId === run.runId).length, 1)
      assert.equal(events.filter(event => event.type === 'tool-workflow/run-end' && event.data.runId === run.runId).length, 1)
    }
    details.push({ case: 'real-background-job-kill-and-child-retirement', runId: background.runId, jobId: background.jobId })
    return { suite: 'workflow', passed: 3, details }
  } finally { adapter.mode = 'answer'; adapter.entered = null }
}
