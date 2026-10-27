import assert from 'node:assert/strict'
import { createHash, randomUUID } from 'node:crypto'
import { mkdir, writeFile, unlink, readFile } from 'node:fs/promises'
import { join } from 'node:path'
import * as FsTools from '@deepseek-ai/dsh-tool-fs'
import * as SearchTools from '@deepseek-ai/dsh-tool-fs-search'
import * as ListAgents from '@deepseek-ai/dsh-tool-subagent-control/list-agents'
import Web from '@deepseek-ai/dsh-web'
import * as WebFetch from '@deepseek-ai/dsh-web-fetch-http'
import * as WebTools from '@deepseek-ai/dsh-tool-web'
import { resolveDshHome } from '@deepseek-ai/dsh-home-paths'
import { createUserMessage } from '@deepseek-ai/dsh-llm'
import { NativeIsolatedToolCallbacks } from '../../runtime/native-isolated-tool-callbacks.mjs'
import { IsolatedToolCallJournal } from '../../runtime/isolated-tool-call-journal.mjs'
import { createNativeIsolatedExecutionBridge } from '../../runtime/native-isolated-execution-bridge.mjs'
import { createAppOwnedReadOnlyPtcOwner } from '../../runtime/model-ptc-readonly-owner.mjs'
import { registerAndroidReadOnlyPtcTool } from '../../runtime/tool-readonly-ptc.mjs'
import { registerModelFileReadGuard } from '../../runtime/model-file-read-guard.mjs'
import { registerAndroidFilesTool } from '../../runtime/tool-android-files.mjs'
import { registerAndroidAttachmentsTool } from '../../runtime/tool-android-attachments.mjs'
import AndroidAttachmentStore from '../../runtime/android-attachment-store.mjs'

// A stored, single-file ZIP containing only "readonly archive device fixture\n".
const archiveFixture = 'UEsDBBQAAAAAAChsW12obBxMIAAAACAAAAAOAAAAYWNjZXB0YW5jZS50eHRyZWFkb25seSBhcmNoaXZlIGRldmljZSBmaXh0dXJlClBLAQIUABQAAAAAAChsW12obBxMIAAAACAAAAAOAAAAAAAAAAAAAAAAAAAAAABhY2NlcHRhbmNlLnR4dFBLBQYAAAAAAQABADwAAABMAAAAAAA='

/** Runs only in the isolated acceptance profile/home, using the production native RPC transport. */
export async function runPtcAcceptance({ ctx, transport, agent, workspace }) {
  assert.equal(typeof workspace, 'string')
  assert.equal(ctx.agents.get(agent.id), agent)
  await mkdir(workspace, { recursive: true })
  const fileName = `ptc-acceptance-${randomUUID()}.txt`
  const file = join(workspace, fileName)
  await writeFile(file, 'readonly-ptc-device\n42\n', { flag: 'wx' })
  const checks = [], receipts = []
  const measuredTransport = { async request(method, params, signal) {
    const result = await transport.request(method, params, signal)
    if (method === 'native.isolated.settle') receipts.push(result)
    return result
  } }
  const callbacks = new NativeIsolatedToolCallbacks(measuredTransport,
    new IsolatedToolCallJournal(join(resolveDshHome(), 'ptc-device-journal')))
  ctx.provide('nativeIsolatedToolCallbacks', callbacks)
  const owner = createAppOwnedReadOnlyPtcOwner({ bridge: createNativeIsolatedExecutionBridge(measuredTransport),
    callbacks, runtime: ctx.tools, services: { agents: ctx.agents, subagents: ctx.subagents } })
  const check = async (name, action) => {
    const started = Date.now()
    try { checks.push({ name, status: 'passed', ...(await action()), elapsedMs: Date.now() - started }) }
    catch (error) { checks.push({ name, status: 'failed', error: String(error?.message ?? error).slice(0, 1000), elapsedMs: Date.now() - started }) }
  }
  const invoke = (code, signal = new AbortController().signal) => ctx.tools.execute({ name: 'android_ptc',
    callId: `ptc-device-${randomUUID()}`, arguments: { code, description: 'Read-only PTC device acceptance' }, agent, signal })
  try {
    registerModelFileReadGuard(ctx, workspace)
    if (!ctx.tools.get('read', agent)) await ctx.plugin(FsTools, { readImage: false, write: false, edit: false })
    if (!ctx.tools.get('glob', agent)) await ctx.plugin(SearchTools, { sampleOverCapGlobResults: false })
    if (!ctx.tools.get('list_agents', agent)) await ctx.plugin(ListAgents)
    if (!ctx.tools.get('android_files', agent)) registerAndroidFilesTool(ctx, transport, {
      run() { throw new Error('SAF search is outside this acceptance profile') },
    })
    if (!ctx.get('attachments')) await ctx.plugin(AndroidAttachmentStore, { dshHome: resolveDshHome() })
    if (!ctx.tools.get('android_attachments', agent)) registerAndroidAttachmentsTool(ctx, workspace)
    registerAndroidReadOnlyPtcTool(ctx, { owner, available: () => true })
    await check('first-party-list-read-glob-roots-and-guard', async () => {
      const before = agent.session.seq
      const code = `const a=await tools.list_agents({scope:'children'});const r=await tools.read({file_path:${JSON.stringify(fileName)}});const g=await tools.glob({pattern:${JSON.stringify(fileName)}});const roots=await tools.android_files({action:'roots'});let refused=false;try{await tools.read({file_path:'../outside-acceptance.txt'})}catch(e){refused=e.code==='ANDROID_TOOL_DISPATCH_FAILED'}return {line:r.lines[0].text,files:g.paths,children:a,roots:Array.isArray(roots)?roots.length:(roots.items??roots.roots??[]).length,refused,process:typeof process,fetch:typeof fetch}`
      const result = await invoke(code)
      assert.equal(result.isError, false, JSON.stringify(result.error))
      const value = result.value.result
      assert.equal(value.line, 'readonly-ptc-device')
      assert.deepEqual([...value.files], [fileName])
      assert.equal(value.refused, true)
      assert.equal(value.process, 'undefined'); assert.equal(value.fetch, 'undefined')
      const events = agent.session.snapshotEvents(before).filter(event => event.type === 'tool/ptc-dispatch')
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
      return { state: receipts.at(-1).state, manifestSha256: fixture.manifestSha256 }
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
    checks.push({ name: 'saf-revocation-and-search', status: 'unverified', detail: 'SAF grant revocation and document search require their separate provider lifecycle acceptance.' })
    return { kind: 'production-node-native-readonly-ptc', checks,
      passed: checks.filter(value => value.status === 'passed').length,
      failed: checks.filter(value => value.status === 'failed').length }
  } finally {
    await owner.close()
    await callbacks.dispose()
    await unlink(file)
  }
}
