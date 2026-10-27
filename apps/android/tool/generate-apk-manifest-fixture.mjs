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
console.log(JSON.stringify({ fixture: fileURLToPath(fixturePath), bytes: bytes.length, sha256: fixture.sha256 }))
