import { createHash } from 'node:crypto'
import { execFileSync, spawnSync } from 'node:child_process'
import { mkdir, mkdtemp, readFile, writeFile } from 'node:fs/promises'
import { join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const repository = fileURLToPath(new URL('../../../', import.meta.url))
const fixturePath = new URL('./fixtures/apk-manifest-aapt2.json', import.meta.url)
const argumentsByName = Object.fromEntries(process.argv.slice(2).map(value => {
  const match = /^--(aapt2|android-jar)=(.+)$/u.exec(value)
  if (!match) throw new Error('Use --aapt2=PATH --android-jar=PATH')
  return [match[1], resolve(match[2])]
}))
if (!argumentsByName.aapt2 || !argumentsByName['android-jar']) throw new Error('Both SDK tool paths are required')
const fixture = JSON.parse(await readFile(fixturePath, 'utf8'))
const cache = join(repository, '.cache/android/apk-manifest-aapt2')
await mkdir(cache, { recursive: true })
const directory = await mkdtemp(join(cache, 'golden-'))
const source = join(directory, 'AndroidManifest.xml'), apk = join(directory, 'fixture.apk')
await writeFile(source, fixture.source)
const args = ['link', '-o', apk, '--manifest', source, '-I', argumentsByName['android-jar']]
execFileSync(argumentsByName.aapt2, args, { windowsHide: true, stdio: 'inherit' })
// bsdtar reads this self-generated ZIP only; no user archive is handled by this development script.
const bytes = execFileSync('tar', ['-xOf', apk, 'AndroidManifest.xml'], { windowsHide: true, maxBuffer: 1024 * 1024 })
const version = spawnSync(argumentsByName.aapt2, ['version'], { windowsHide: true, encoding: 'utf8' })
if (version.status !== 0) throw new Error(version.stderr || 'aapt2 version failed')
fixture.generator = `${version.stdout}${version.stderr}`.trim()
fixture.androidJarSha256 = createHash('sha256').update(await readFile(argumentsByName['android-jar'])).digest('hex')
fixture.sha256 = createHash('sha256').update(bytes).digest('hex')
fixture.base64 = bytes.toString('base64')
fixture.xmltree = execFileSync(argumentsByName.aapt2, ['dump', 'xmltree', apk, '--file', 'AndroidManifest.xml'],
  { windowsHide: true, encoding: 'utf8', maxBuffer: 1024 * 1024 }).replaceAll('\r\n', '\n')
await writeFile(fixturePath, JSON.stringify(fixture, null, 2) + '\n')
const packaged = await readFile(apk)
await writeFile(new URL('./device-runtime-acceptance/apk-fixture.json', import.meta.url), JSON.stringify({
  manifestSha256: fixture.sha256,
  sha256: createHash('sha256').update(packaged).digest('hex'),
  base64: packaged.toString('base64'),
}, null, 2) + '\n')
const overflowSource = join(directory, 'overflow.xml'), overflowApk = join(directory, 'overflow.apk')
await writeFile(overflowSource, '<manifest xmlns:android="http://schemas.android.com/apk/res/android" package="org.example.ptcoverflow">'
  + '<application>' + Array.from({ length: 100 }, (_, index) =>
    `<activity android:name=".${'A'.repeat(200)}${index}" android:exported="false"/>`).join('')
  + '</application></manifest>')
execFileSync(argumentsByName.aapt2, ['link', '-o', overflowApk, '--manifest', overflowSource,
  '-I', argumentsByName['android-jar']], { windowsHide: true, stdio: 'inherit' })
const overflowBytes = await readFile(overflowApk)
await writeFile(new URL('./device-runtime-acceptance/apk-overflow-fixture.json', import.meta.url), JSON.stringify({
  sha256: createHash('sha256').update(overflowBytes).digest('hex'),
  base64: overflowBytes.toString('base64'),
}, null, 2) + '\n')
console.log(JSON.stringify({ fixture: fileURLToPath(fixturePath), bytes: bytes.length, sha256: fixture.sha256 }))
