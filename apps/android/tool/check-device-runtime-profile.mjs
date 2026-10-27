import { cp, mkdtemp, mkdir, writeFile } from 'node:fs/promises'
import { resolve, join } from 'node:path'
import { spawn } from 'node:child_process'

const root = resolve(import.meta.dirname, '../../..')
const home = await mkdtemp(join(root, '.cache/android/runtime-profile-smoke-'))
const fixture = join(home, 'fixture')
const workspace = join(home, 'workspace')
await mkdir(workspace)
await cp(join(import.meta.dirname, 'device-runtime-acceptance'), fixture, { recursive: true })
await writeFile(join(fixture, 'configuration.json'), JSON.stringify({ runtime: join(root, '.cache/android/runtime-bundle'),
  workspace, appWorkspaceRoot: home, suite: 'workflow' }))
const child = spawn(process.execPath, [join(fixture, 'bootstrap.mjs')], {
  cwd: workspace, env: { ...process.env, DSH_HOME: home, HOME: home }, stdio: ['pipe', 'pipe', 'pipe'], windowsHide: true,
})
let output = '', diagnostics = ''
const ready = new Promise((resolveReady, reject) => {
  child.stdout.on('data', bytes => {
    output += bytes
    if (output.includes('"method":"native.workflow.admit"')) resolveReady()
    if (output.includes('"method":"acceptance.result"')) reject(new Error(output.slice(-8000)))
  })
  child.stderr.on('data', bytes => { diagnostics += bytes })
  child.on('error', reject)
  child.on('exit', code => reject(new Error(`Profile exited ${code}: ${diagnostics.slice(-8000)} ${output.slice(-8000)}`)))
})
const timer = setTimeout(() => child.kill(), 30_000)
try { await ready; console.log('PASS: the ordinary dsh acceptance profile reached the production native workflow admission request (host startup only).') }
catch (error) { console.error(error.message); console.error(diagnostics.slice(-8000)); process.exitCode = 1 }
finally { clearTimeout(timer); child.kill() }
