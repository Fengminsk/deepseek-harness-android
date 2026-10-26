import { execFileSync } from 'node:child_process'
import { mkdtempSync, readFileSync, realpathSync, readdirSync, rmSync } from 'node:fs'
import { basename, dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const project = fileURLToPath(new URL('../', import.meta.url))
const main = join(project, 'android/app/src/main')
const sourceRoot = join(main, 'java/com/minnnng/dsh_android')
const testRoot = join(project, 'android/app/src/test/java/com/minnnng/dsh_android')
const temporaryRoot = realpathSync(join(project, '../../.cache/android'))
const forbidden = [
  [/\b(?:List|Set|Map)\.(?:of|copyOf)\s*\(/, 'collection factory needs API 30+'],
  [/\bPath\.of\s*\(/, 'Path.of needs API 34'],
  [/\.toList\s*\(/, 'Java Stream.toList needs API 34'],
  [/\b(?:Files\.(?:readString|writeString)|String\.repeat)\s*\(/, 'newer Java API'],
]

for (const scope of ['java', 'kotlin']) {
  for (const entry of readdirSync(join(main, scope, 'com/minnnng/dsh_android'), { withFileTypes: true })) {
    if (!entry.isFile() || !entry.name.endsWith(scope === 'java' ? '.java' : '.kt')) continue
    const path = join(main, scope, 'com/minnnng/dsh_android', entry.name)
    const text = readFileSync(path, 'utf8')
    for (const [pattern, reason] of forbidden) {
      if (scope === 'kotlin' && pattern.source === '\\.toList\\s*\\(') continue
      if (pattern.test(text)) throw new Error(`${entry.name}: ${reason}`)
    }
    if (scope === 'java' && /\.isBlank\s*\(/.test(text.replaceAll('AndroidJava28.isBlank(', ''))) {
      throw new Error(`${entry.name}: String.isBlank needs API 33`)
    }
  }
}

const output = mkdtempSync(join(temporaryRoot, 'android-api28-compat-'))
try {
  execFileSync('javac', ['-encoding', 'UTF-8', '-d', output,
    join(sourceRoot, 'AndroidJava28.java'), join(testRoot, 'AndroidJava28Test.java')],
  { stdio: 'inherit', windowsHide: true })
  execFileSync('java', ['-cp', output, 'com.minnnng.dsh_android.AndroidJava28Test'],
  { stdio: 'inherit', windowsHide: true })
} finally {
  const target = realpathSync(output)
  if (dirname(target) !== temporaryRoot || !basename(target).startsWith('android-api28-compat-')) {
    throw new Error('Refusing to remove an unrelated API compatibility test directory')
  }
  rmSync(target, { recursive: true })
}
