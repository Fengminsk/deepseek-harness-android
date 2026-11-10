import { AppDocumentReads } from '../../runtime/document-reads.mjs'
import assert from 'node:assert/strict'
import { createHash, randomUUID } from 'node:crypto'
import { mkdir, writeFile, unlink, readFile } from 'node:fs/promises'
import { join } from 'node:path'
import * as FsTools from '@deepseek-ai/dsh-tool-fs'
import * as SearchTools from '@deepseek-ai/dsh-tool-fs-search'
import { registerListAgents } from '../../../../packages/subagent/tool-subagent-control/src/list-agents.ts'
import Web from '@deepseek-ai/dsh-web'
import * as WebFetch from '@deepseek-ai/dsh-web-fetch-http'
import * as WebTools from '@deepseek-ai/dsh-tool-web'
import { resolveDshHome } from '@deepseek-ai/dsh-home-paths'
import { establishAttachmentHome } from '@deepseek-ai/dsh-attachment-local'
import { createUserMessage } from '@deepseek-ai/dsh-llm'
import { setSandboxMode } from '@deepseek-ai/dsh-sandbox-policy'
import { NativeIsolatedToolCallbacks } from '../../runtime/native-isolated-tool-callbacks.mjs'
import { IsolatedToolCallJournal } from '../../runtime/isolated-tool-call-journal.mjs'
import { createNativeIsolatedExecutionBridge } from '../../runtime/native-isolated-execution-bridge.mjs'
import { createAppOwnedPtcOwner } from '../../runtime/model-ptc-reviewed-owner.mjs'
import { registerAndroidPtcTool } from '../../runtime/tool-model-ptc.mjs'
import { registerModelFileReadGuard } from '../../runtime/model-file-read-guard.mjs'
import { registerAndroidFilesTool } from '../../runtime/tool-android-files.mjs'
import { registerAndroidAttachmentsTool } from '../../runtime/tool-android-attachments.mjs'
import AndroidAttachmentStore from '../../runtime/android-attachment-store.mjs'
import { PTC_LINUX_DEVICE_CHECK, PtcLinuxAcceptanceFailure, runPtcLinuxAcceptance } from './ptc-linux.mjs'
import { runApkCodeAcceptance } from './apk-inspection.mjs'
import { PTC_LINUX_CANCEL_CHECK, PTC_LINUX_DEADLINE_CHECK, runPtcLinuxLifecycle, ptcNativeRetirementDiagnostics } from './ptc-linux-lifecycle.mjs'

// A stored, single-file ZIP containing only "readonly archive device fixture\n".
const archiveFixture = 'UEsDBBQAAAAAAChsW12obBxMIAAAACAAAAAOAAAAYWNjZXB0YW5jZS50eHRyZWFkb25seSBhcmNoaXZlIGRldmljZSBmaXh0dXJlClBLAQIUABQAAAAAAChsW12obBxMIAAAACAAAAAOAAAAAAAAAAAAAAAAAAAAAABhY2NlcHRhbmNlLnR4dFBLBQYAAAAAAQABADwAAABMAAAAAAA='

/**
 * Keep direct acceptance tool calls inside a real AgentLoop turn, without a model request.
 * @param {object} ctx - Acceptance services including the live Agent and Session owners.
 * @param {object} agent - Idle acceptance Agent whose log will later seed a child.
 * @param {Function} action - Checks and joined callback retirement owned by this turn.
 * @returns {Promise<object>} The checks' original result after turn closure and durable flush.
 */
export async function inPtcAcceptanceTurn(ctx, agent, action) {
  assert.equal(agent.status, 'idle')
  assert.equal(ctx.sessionProjections.stateOf(agent.session, 'turnBoundary').openTurnStartSeq, null)
  let entered = false, failed = false, failure, result
  const stop = ctx.on('agent/pre-step', async (event, next) => {
    if (event.agent !== agent) return next()
    try {
      const decision = await next()
      assert.equal(decision.kind, 'enter', 'PTC acceptance turn was rejected')
      assert.equal(entered, false, 'PTC acceptance checks must run once')
      entered = true
      result = await action()
      return { ...decision, messages: [] }
    } catch (error) { failed = true; failure = error; throw error }
  })
  try {
    agent.send(createUserMessage({ source: { kind: 'user' },
      content: [{ type: 'text', text: 'Run the local PTC acceptance checks.' }] }), 'next-turn', true)
    await agent.whenIdle()
  } finally { stop() }
  assert.equal(ctx.sessionProjections.stateOf(agent.session, 'turnBoundary').openTurnStartSeq, null)
  assert.equal(await ctx.sessions.flush(agent.session), true, 'PTC acceptance turn did not flush')
  if (failed) throw failure
  assert.equal(entered, true, 'PTC acceptance turn did not start')
  return result
}

/** Runs only in the isolated acceptance profile/home, using the production native RPC transport. */
export function runPtcAcceptance(input) {
  return inPtcAcceptanceTurn(input.ctx, input.agent, () => runPtcChecks(input))
}

async function runPtcChecks({ ctx, transport, agent, workspace, callbackRouting, appWorkspaceRoot, nativeModule }) {
  assert.equal(typeof workspace, 'string')
  assert.equal(ctx.agents.get(agent.id), agent)
  const home = resolveDshHome()
  const privateRoot = await transport.request('native.storage.root', {})
  assert.equal(typeof privateRoot, 'string')
  await establishAttachmentHome(home, privateRoot)
  await mkdir(workspace, { recursive: true })
  const fileName = `ptc-acceptance-${randomUUID()}.txt`
  const file = join(workspace, fileName)
  await writeFile(file, 'readonly-ptc-device\n42\n', { flag: 'wx' })
  const checks = [], receipts = [], ptcRequests = [], callbackClosures = []
  const measuredTransport = { async request(method, params, signal) {
    const row = { method, params: { runId: params.runId, kind: params.kind,
      sessionId: params.sessionId, deadlineMillis: params.deadlineMillis }, startedAtMs: performance.now() }
    ptcRequests.push(row)
    try {
      const result = await transport.request(method, params, signal)
      if (method === 'native.isolated.settle') receipts.push(result)
      row.acknowledged = true
      return result
    } finally { row.completedAtMs = performance.now() }
  } }
  const callbacks = new NativeIsolatedToolCallbacks(measuredTransport,
    new IsolatedToolCallJournal(join(home, 'ptc-device-journal')))
  const closeCallbacks = callbacks.close.bind(callbacks)
  callbacks.close = async value => {
    const row = { runId: value.runId, status: 'pending', closed: false }; callbackClosures.push(row)
    try { const result = await closeCallbacks(value); row.status = 'returned'; row.closed = result.closed === true; return result }
    catch (error) { row.status = 'rejected'; row.errorCode = error?.code; throw error }
  }
  const unbind = callbackRouting.bind('tool', callbacks)
  const owner = createAppOwnedPtcOwner({ bridge: createNativeIsolatedExecutionBridge(measuredTransport),
    callbacks, runtime: ctx.tools, services: { agents: ctx.agents, subagents: ctx.subagents,
      sessions: ctx.sessions, sandboxPolicy: ctx.sandboxPolicy } })
  const originalMode = ctx.sandboxPolicy.resolve({ session: agent.session }).mode
  const check = async (name, action) => {
    const started = Date.now(), initialReceipts = receipts.length, initialRequests = ptcRequests.length
    try { checks.push({ name, status: 'passed', ...(await action()), elapsedMs: Date.now() - started }) }
    catch (error) { checks.push({ name, status: 'failed', error: String(error?.message ?? error).slice(0, 1000),
      diagnostics: { ...(error instanceof PtcLinuxAcceptanceFailure ? error.diagnostics : {}),
        ...ptcNativeRetirementDiagnostics(receipts.length > initialReceipts ? receipts.at(-1) : null,
          ptcRequests.slice(initialRequests), callbackClosures) }, elapsedMs: Date.now() - started }) }
  }
  const reads = new AppDocumentReads(transport, { maxRequests: () => 2, timeoutMs: () => 30000 })
  const invoke = (code, signal = new AbortController().signal) => ctx.tools.execute({ name: 'android_ptc',
    callId: `ptc-device-${randomUUID()}`, arguments: { code, description: 'PTC device acceptance' }, agent, signal })
  try {
    setSandboxMode(agent.session, 'read-only')
    registerModelFileReadGuard(ctx, workspace)
    if (!ctx.tools.get('read', agent)) await ctx.plugin(FsTools, { readImage: false })
    if (!ctx.tools.get('glob', agent)) await ctx.plugin(SearchTools, { sampleOverCapGlobResults: false })
    if (!ctx.tools.get('list_agents', agent)) await ctx.plugin({
    name: 'list-agents-fixture', inject: ['tools', 'subagents', 'agents', 'systemPrompt'],
    apply: scope => { registerListAgents(scope) },
  })
    if (!ctx.tools.get('android_files', agent)) registerAndroidFilesTool(ctx, transport, {
      run() { throw new Error('SAF search is outside this acceptance profile') },
    }, reads)
    if (!ctx.get('attachments')) await ctx.plugin(AndroidAttachmentStore, { dshHome: home })
    if (!ctx.tools.get('android_attachments', agent)) registerAndroidAttachmentsTool(ctx, workspace)
    registerAndroidPtcTool(ctx, { owner, available: () => true })
    await check('first-party-list-read-glob-roots-and-guard', async () => {
      const before = agent.session.seq
      const code = `let step='list_agents';try {
        const a=await tools.list_agents({scope:'children'});
        step='read';const r=await tools.read({file_path:${JSON.stringify(fileName)}});
        step='glob';const g=await tools.glob({pattern:${JSON.stringify(fileName)}});
        step='roots';const roots=await tools.android_files({action:'roots'});
        step='outside-workspace-guard';let refused=false;
        try{await tools.read({file_path:'../outside-acceptance.txt'})}
        catch(e){if(e.code!=='ANDROID_TOOL_DISPATCH_FAILED')throw e;refused=true}
        step='result';return {line:r.lines[0].text,files:g.paths,children:a,
          roots:Array.isArray(roots)?roots.length:(roots.items??roots.roots??[]).length,
          refused,process:typeof process,fetch:typeof fetch};
      }catch(e){return {failure:{step,name:String(e.name),code:String(e.code),message:String(e.message).slice(0,400)}}}`
      const result = await invoke(code)
      const events = agent.session.snapshotEvents(before).filter(event => event.type === 'tool/ptc-dispatch')
      const diagnostics = () => JSON.stringify({ error: result.error, failure: result.value?.result?.failure,
        callbacks: events.map(event => ({ name: event.data.name, isError: event.data.isError,
          error: event.data.error, message: event.data.isError
            ? event.data.content?.find(block => block.type === 'text')?.text?.slice(0, 240) : undefined })),
        state: receipts.at(-1)?.state })
      assert.equal(result.isError, false, diagnostics())
      const value = result.value.result
      assert.equal(value.failure, undefined, diagnostics())
      assert.equal(value.line, 'readonly-ptc-device')
      assert.deepEqual([...value.files], [fileName])
      assert.equal(value.refused, true)
      assert.equal(value.process, 'undefined'); assert.equal(value.fetch, 'undefined')
      assert.deepEqual(events.map(event => event.data.name), ['list_agents', 'read', 'glob', 'android_files', 'read'])
      assert.equal(events.at(-1).data.isError, true)
      const receipt = receipts.at(-1)
      assert.equal(receipt.state, 'COMPLETED'); assert.ok(Number.isInteger(receipt.guestUid))
      assert.notEqual(receipt.guestUid, process.getuid())
      return { callbackCount: events.length, guestUid: receipt.guestUid, appUid: process.getuid(), safRootCount: value.roots }
    })
    await check('authorized-saf-read-through-native-ptc-callback', async () => {
      const root = '2a261d4e242daf0ec165eba9289bb3e1a871f1b5ecbae6e047547f6617d104ed'
      const result = await invoke(`const r=await tools.android_files({action:'read',root:${JSON.stringify(root)},path:'dsh-saf-acceptance.txt'});return {text:r.text,offset:r.offset,nextOffset:r.nextOffset,truncated:r.truncated}`)
      assert.equal(result.isError, false, JSON.stringify(result.error))
      const value = result.value.result
      assert.ok(value.text.startsWith('Pocket Harness SAF acceptance v1'))
      assert.equal(value.offset, 0); assert.equal(value.nextOffset, 33); assert.equal(value.truncated, false)
      const sha256 = createHash('sha256').update(value.text).digest('hex')
      assert.equal(sha256, 'ad313936091d58e1031045fe99bf616595cad2b1024f12f6121ce087fb981cc6')
      return { bytes: value.nextOffset, sha256, state: receipts.at(-1).state }
    })
    await check('current-session-attachment-read-and-archive-through-ptc', async () => {
      const ref = await ctx.get('attachments').saveFile({ name: `ptc-${randomUUID()}.zip`, data: Buffer.from(archiveFixture, 'base64') })
      agent.session.append('user/message', createUserMessage({ content: [{ type: 'file', attachment: ref }],
        source: { kind: 'user' } }), { surfaceOp: 'append' })
      const identity = JSON.stringify({ attachmentId: ref.attachmentId, name: ref.name })
      const result = await invoke(`const id=${identity};const l=await tools.android_attachments({action:'list'});const r=await tools.android_attachments({...id,action:'read',encoding:'hex',limit:4});const z=await tools.android_attachments({...id,action:'inspect_archive'});let refused=false;try{await tools.android_attachments({...id,action:'materialize'})}catch(e){refused=true}return {listed:l.files.some(f=>f.attachmentId===id.attachmentId),hex:r.content,verified:r.verified,entryCount:z.entryCount,names:z.entries.map(e=>e.name),refused}`)
      assert.equal(result.isError, false, JSON.stringify(result.error))
      assert.deepEqual(result.value.result, { listed: true, hex: '504b0304', verified: true,
        entryCount: 1, names: ['acceptance.txt'], refused: true })
      return { state: receipts.at(-1).state, attachmentBytes: ref.bytes, materializationRefused: true }
    })
    await check('workspace-mutations-through-native-ptc-callback', async () => {
      const name = `ptc-write-${randomUUID()}.txt`
      const ref = await ctx.get('attachments').saveFile({ name: `ptc-import-${randomUUID()}.txt`, data: Buffer.from('PTC attachment\n') })
      agent.session.append('user/message', createUserMessage({ content: [{ type: 'file', attachment: ref }],
        source: { kind: 'user' } }), { surfaceOp: 'append' })
      const identity = JSON.stringify({ attachmentId: ref.attachmentId, name: ref.name })
      const before = agent.session.seq
      setSandboxMode(agent.session, 'workspace-write')
      try {
        const result = await invoke(`const p=${JSON.stringify(name)};await tools.write({file_path:p,content:'alpha\\n'});await tools.read({file_path:p});const edited=await tools.edit({file_path:p,old_string:'alpha',new_string:'beta'});const imported=await tools.android_attachments({...${identity},action:'materialize'});const text=await tools.read({file_path:imported.file_path});return {edited,imported,line:text.lines[0].text}`)
        assert.equal(result.isError, false, JSON.stringify(result.error))
        assert.equal(await readFile(join(workspace, name), 'utf8'), 'beta\n')
        assert.equal(await readFile(result.value.result.imported.file_path, 'utf8'), 'PTC attachment\n')
        assert.equal(result.value.result.line, 'PTC attachment')
        assert.equal(result.additionalContexts.filter(value => value.source.kind === 'file-mutation-receipt').length, 3)
        const events = agent.session.snapshotEvents(before).filter(event => event.type === 'tool/ptc-dispatch')
        assert.equal(events[2].data.meta.path, join(workspace, name))
        assert.equal(await ctx.sessions.flush(agent.session), true)
        return { state: receipts.at(-1).state, callbackCount: events.length,
          file: join(workspace, name), imported: result.value.result.imported.file_path }
      } finally { setSandboxMode(agent.session, 'read-only') }
    })
    await check('current-session-apk-through-native-ptc-callback', async () => {
      const fixture = JSON.parse(await readFile(new URL('./apk-fixture.json', import.meta.url), 'utf8'))
      const bytes = Buffer.from(fixture.base64, 'base64')
      assert.equal(createHash('sha256').update(bytes).digest('hex'), fixture.sha256)
      const ref = await ctx.get('attachments').saveFile({ name: `ptc-${randomUUID()}.apk`, data: bytes })
      agent.session.append('user/message', createUserMessage({ content: [{ type: 'file', attachment: ref }],
        source: { kind: 'user' } }), { surfaceOp: 'append' })
      const identity = JSON.stringify({ attachmentId: ref.attachmentId, name: ref.name })
      const before = agent.session.seq
      const result = await invoke(`return await tools.android_attachments({...${identity},action:'inspect_apk',part:'manifest',limit:1})`)
      assert.equal(result.isError, false, JSON.stringify(result.error))
      const value = result.value.result
      assert.equal(value.verified, true)
      assert.equal(value.results[0].sha256, fixture.manifestSha256)
      assert.equal(value.results[0].analysis.package, 'org.example.apkparser')
      assert.equal(value.results[0].analysis.nextComponentOffset, 1)
      assert.equal(value.coverage.apkSignaturesVerified, false)
      const events = agent.session.snapshotEvents(before).filter(event => event.type === 'tool/ptc-dispatch')
      assert.equal(events.length, 1)
      assert.equal(events[0].data.arguments.action, 'inspect_apk')
      assert.equal(events[0].data.content[0].text, JSON.stringify(value))
      const code = await runApkCodeAcceptance({
        async upload(name, data) {
          const ref = await ctx.get('attachments').saveFile({ name: `${randomUUID()}-${name}`, data })
          agent.session.append('user/message', createUserMessage({ content: [{ type: 'file', attachment: ref }],
            source: { kind: 'user' } }), { surfaceOp: 'append' })
          return ref
        },
        async call(args) {
          const outcome = await invoke(`try{return {ok:true,value:await tools.android_attachments(${JSON.stringify(args)})}}catch(e){return {ok:false,message:String(e.message)}}`)
          assert.equal(outcome.isError, false, JSON.stringify(outcome.error))
          const response = outcome.value.result
          if (response.ok !== true) throw new Error(response.message)
          return response.value
        },
      })
      const allEvents = agent.session.snapshotEvents(before).filter(event => event.type === 'tool/ptc-dispatch')
      assert.equal(allEvents.length, 9)
      assert.equal(allEvents.filter(event => event.data.isError === true).length, 2)
      return { state: receipts.at(-1).state, manifestSha256: fixture.manifestSha256, code }
    })
    await check('apk-oversize-callback-can-retry-a-smaller-page', async () => {
      const fixture = JSON.parse(await readFile(new URL('./apk-overflow-fixture.json', import.meta.url), 'utf8'))
      const bytes = Buffer.from(fixture.base64, 'base64')
      assert.equal(createHash('sha256').update(bytes).digest('hex'), fixture.sha256)
      const ref = await ctx.get('attachments').saveFile({ name: `overflow-${randomUUID()}.apk`, data: bytes })
      agent.session.append('user/message', createUserMessage({ content: [{ type: 'file', attachment: ref }],
        source: { kind: 'user' } }), { surfaceOp: 'append' })
      const identity = JSON.stringify({ attachmentId: ref.attachmentId, name: ref.name })
      const before = agent.session.seq
      const result = await invoke(`const args={...${identity},action:'inspect_apk',part:'manifest'};let recovery;try{await tools.android_attachments({...args,limit:100})}catch(e){recovery=e.message}return {recovery,page:await tools.android_attachments({...args,limit:1})}`)
      assert.equal(result.isError, false, JSON.stringify(result.error))
      assert.match(result.value.result.recovery, /APK analysis exceeds.*48 KiB.*smaller limit/u)
      assert.equal(result.value.result.page.results[0].analysis.nextComponentOffset, 1)
      const events = agent.session.snapshotEvents(before).filter(event => event.type === 'tool/ptc-dispatch')
      assert.equal(events.length, 2)
      assert.equal(events[0].data.error.reason, result.value.result.recovery)
      assert.equal(events[1].data.isError, false)
      return { state: receipts.at(-1).state, recovered: true }
    })
    await check('model-cancellation-joins-native-retirement', async () => {
      const controller = new AbortController()
      const before = agent.session.seq
      let enteredNative = false
      const pending = invoke("await tools.list_agents({scope:'children'});while(true) {}", controller.signal)
      const observe = setInterval(() => {
        if (agent.session.snapshotEvents(before).some(event => event.type === 'tool/ptc-dispatch'
          && event.data.name === 'list_agents' && event.data.isError === false)) {
          enteredNative = true
          controller.abort(new Error('acceptance cancel after actual native callback'))
        }
      }, 25)
      const timer = setTimeout(() => controller.abort(new Error('native callback did not start within acceptance budget')), 10000)
      let result
      try { result = await pending } catch (error) { result = { isError: true, error } }
      finally { clearTimeout(timer); clearInterval(observe) }
      assert.equal(enteredNative, true, 'Cancellation must follow an actual guest ToolRuntime callback')
      assert.equal(result.isError, true)
      const receipt = receipts.at(-1)
      assert.equal(receipt.state, 'CANCELLED')
      assert.ok(Number.isInteger(receipt.guestUid))
      return { state: receipt.state, guestUid: receipt.guestUid, enteredNative }
    })
    await check('model-busy-loop-has-independent-cpu-limit', async () => {
      const started = Date.now()
      const result = await invoke('while(true) {}')
      assert.equal(result.isError, true)
      assert.ok(Date.now() - started < 30000)
      const receipt = receipts.at(-1)
      assert.equal(receipt.state, 'TIMED_OUT')
      return { state: receipt.state, guestUid: receipt.guestUid }
    })
    await check('real-public-web-fetch', async () => {
      if (!ctx.get('web')) await ctx.plugin(Web, { fetchProvider: WebFetch.LOCAL_FETCH_PROVIDER_ID })
      await ctx.plugin(WebFetch, { timeoutMs: 15000 })
      if (!ctx.tools.get('web_fetch', agent)) await ctx.plugin(WebTools, { search: false })
      const result = await invoke('const r=await tools.web_fetch({url:"https://example.com/"});return {status:r.statusCode,hasBody:typeof r.body?.content==="string"&&r.body.content.length>0}')
      assert.equal(result.isError, false, JSON.stringify(result.error))
      assert.equal(result.value.result.status, 200); assert.equal(result.value.result.hasBody, true)
      return { state: receipts.at(-1).state }
    })
    await check(PTC_LINUX_DEVICE_CHECK, () => runPtcLinuxAcceptance({ ctx, transport, agent, workspace,
      appWorkspaceRoot, nativeModule, invoke, settlements: receipts }))
    await check(PTC_LINUX_CANCEL_CHECK, () => runPtcLinuxLifecycle({ mode: 'cancel', ctx, transport, agent,
      nativeModule, invoke, settlements: receipts, ptcRequests, callbackClosures }))
    if (checks.at(-1).status === 'passed') {
      await check(PTC_LINUX_DEADLINE_CHECK, () => runPtcLinuxLifecycle({ mode: 'deadline', ctx, transport, agent,
        nativeModule, invoke, settlements: receipts, ptcRequests, callbackClosures }))
    } else checks.push({ name: PTC_LINUX_DEADLINE_CHECK, status: 'unverified', detail: 'Nested cancellation did not settle; stop dependent lifecycle checks.' })
    checks.push({ name: 'saf-revocation-and-search', status: 'unverified', detail: 'SAF grant revocation and document search require their separate provider lifecycle acceptance.' })
    return { kind: 'production-node-native-ptc', checks,
      passed: checks.filter(value => value.status === 'passed').length,
      failed: checks.filter(value => value.status === 'failed').length }
  } finally {
    setSandboxMode(agent.session, originalMode)
    try {
      await reads.close()
      await owner.close()
      await callbacks.dispose()
    } finally { unbind() }
    await unlink(file)
  }
}


