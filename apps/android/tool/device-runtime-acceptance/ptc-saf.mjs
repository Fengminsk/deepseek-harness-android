import assert from 'node:assert/strict'
import { randomUUID } from 'node:crypto'
import { join } from 'node:path'
import { resolveDshHome } from '@deepseek-ai/dsh-home-paths'
import { NativeIsolatedToolCallbacks } from '../../runtime/native-isolated-tool-callbacks.mjs'
import { IsolatedToolCallJournal } from '../../runtime/isolated-tool-call-journal.mjs'
import { createNativeIsolatedExecutionBridge } from '../../runtime/native-isolated-execution-bridge.mjs'
import { createAppOwnedPtcOwner } from '../../runtime/model-ptc-reviewed-owner.mjs'
import { registerAndroidPtcTool } from '../../runtime/tool-model-ptc.mjs'
import { registerAndroidFilesTool } from '../../runtime/tool-android-files.mjs'
import { AppDocumentSearch } from '../../runtime/document-search.mjs'
import { inPtcAcceptanceTurn } from './ptc.mjs'

/**
 * Search a synthetic persisted tree through native PTC, revoke it, then refuse read and search.
 * @param {object} input - Live acceptance services and the native carrier's exact test-provider root.
 * @returns {Promise<object>} Callback and native search evidence; no user-granted root is selected.
 */
export function runPtcSafAcceptance(input) {
  return inPtcAcceptanceTurn(input.ctx, input.agent, () => checks(input))
}

async function checks({ ctx, transport, agent, callbackRouting, root, caseId }) {
  assert.match(root, /^[0-9a-f]{64}$/)
  assert.match(caseId, /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/)
  assert.equal(ctx.tools.get('android_files', agent), undefined, 'SAF acceptance needs a fresh profile')
  const receipts = [], calls = []
  const measured = { async request(method, params, signal) {
    calls.push(method)
    const result = await transport.request(method, params, signal)
    if (method === 'native.isolated.settle') receipts.push(result)
    return result
  } }
  const searches = new AppDocumentSearch(measured, { maxRequests: () => 1,
    limits: () => ({ fileBytes: 4096, totalBytes: 8192, maxEntries: 8, maxFiles: 4,
      maxDepth: 4, maxMatches: 8, previewChars: 512, maxDurationMs: 15000 }) })
  registerAndroidFilesTool(ctx, measured, searches)
  const callbacks = new NativeIsolatedToolCallbacks(measured,
    new IsolatedToolCallJournal(join(resolveDshHome(), 'ptc-saf-journal')))
  const unbind = callbackRouting.bind('tool', callbacks)
  const owner = createAppOwnedPtcOwner({ bridge: createNativeIsolatedExecutionBridge(measured), callbacks,
    runtime: ctx.tools, services: { agents: ctx.agents, subagents: ctx.subagents,
      sessions: ctx.sessions, sandboxPolicy: ctx.sandboxPolicy } })
  registerAndroidPtcTool(ctx, { owner, available: () => true })
  const invoke = code => ctx.tools.execute({ name: 'android_ptc', callId: `ptc-saf-${randomUUID()}`,
    arguments: { code, description: 'Controlled SAF acceptance' }, agent, signal: new AbortController().signal })
  try {
    const before = agent.session.seq
    const result = await invoke(`const root=${JSON.stringify(root)};
      const s=await tools.android_files({action:'search',root,path:'',query:'needle',caseSensitive:true});
      const r=await tools.android_files({action:'read',root,path:'alpha.txt'});
      return {matches:s.matches,complete:s.complete,text:r.text};`)
    assert.equal(result.isError, false, JSON.stringify(result.error))
    assert.equal(result.value.result.complete, true)
    assert.equal(result.value.result.matches.length, 1)
    assert.equal(result.value.result.matches[0].path, 'alpha.txt')
    assert.equal(result.value.result.text, `PTC SAF needle ${caseId}\n`)
    assert.equal(calls.filter(value => value === 'native.documents.search.run').length, 1)
    assert.equal(calls.filter(value => value === 'native.documents.search.cancel').length, 1)
    const receipt = receipts.at(-1)
    assert.equal(receipt.state, 'COMPLETED')
    assert.ok(Number.isInteger(receipt.guestUid))
    assert.notEqual(receipt.guestUid, typeof process.getuid === 'function' ? process.getuid() : null)
    const revoked = await transport.request('acceptance.saf.revoke', { root })
    assert.equal(revoked.revoked, true)
    const refusal = await invoke(`const root=${JSON.stringify(root)};const denied=[];
      for(const action of ['search','read']) {try {
        await tools.android_files({action,root,path:action==='read'?'alpha.txt':'',query:'needle'});
        denied.push('incorrect-success');
      }catch(e){denied.push(e.code)}}return denied;`)
    assert.equal(refusal.isError, false, JSON.stringify(refusal.error))
    assert.deepEqual(refusal.value.result, ['ANDROID_TOOL_DISPATCH_FAILED', 'ANDROID_TOOL_DISPATCH_FAILED'])
    assert.equal(calls.filter(value => value === 'native.documents.search.run').length, 1,
      'Revoked root reached the scanner again')
    const events = agent.session.snapshotEvents(before).filter(event => event.type === 'tool/ptc-dispatch')
    assert.deepEqual(events.map(event => event.data.isError), [false, false, true, true])
    return { suite: 'ptc-saf', checks: [{ name: 'saf-revocation-and-search', status: 'passed',
      callbackCount: events.length, guestUid: receipt.guestUid, nativeSearchCount: 1,
      revokedReadDenied: true, revokedSearchDenied: true }] }
  } finally {
    try { await owner.close() }
    finally { try { await callbacks.dispose(); await searches.close() } finally { unbind() } }
  }
}
