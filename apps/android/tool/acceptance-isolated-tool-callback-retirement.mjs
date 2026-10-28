/** Run the actual callback bridge with JVM threads and SDK JSON; Binder delivery is a test-only shim. */
import { execFileSync } from 'node:child_process'
import { existsSync, mkdtempSync, mkdirSync, readFileSync, readdirSync, writeFileSync } from 'node:fs'
import { homedir } from 'node:os'
import { delimiter, dirname, join, resolve } from 'node:path'

const root = resolve(import.meta.dirname, '../../..')
const baseline = process.argv.slice(2).includes('--baseline')
if (process.argv.slice(2).some(value => value !== '--baseline')) throw new Error('Unknown argument')
const output = mkdtempSync(join(root, `.cache/android/tool-callback-${baseline ? 'baseline' : 'host'}-`))
const gradle = process.env.GRADLE_USER_HOME ?? join(homedir(), '.gradle')
const sdk = process.env.ANDROID_HOME ?? process.env.ANDROID_SDK_ROOT
  ?? readFileSync(join(root, 'apps/android/android/local.properties'), 'utf8').match(/^sdk\.dir=(.+)$/m)?.[1].trim().replaceAll('\\\\', '\\')
if (!sdk) throw new Error('Android SDK sources are required')
function artifact(group, name, version) {
  const directory = join(gradle, 'caches/modules-2/files-2.1', group, name, version)
  for (const hash of readdirSync(directory)) {
    const file = join(directory, hash, `${name}-${version}.jar`)
    if (existsSync(file)) return file
  }
  throw new Error(`Cached compiler dependency missing: ${name}/${version}`)
}
const compiler = [artifact('org.jetbrains.kotlin', 'kotlin-compiler-embeddable', '2.2.21'),
  artifact('org.jetbrains.kotlin', 'kotlin-stdlib', '2.2.21'),
  artifact('org.jetbrains.kotlin', 'kotlin-script-runtime', '2.2.21'),
  artifact('org.jetbrains.kotlin', 'kotlin-reflect', '1.6.10'),
  artifact('org.jetbrains.kotlin', 'kotlin-daemon-embeddable', '2.2.21'),
  artifact('org.jetbrains.kotlinx', 'kotlinx-coroutines-core-jvm', '1.8.0'),
  artifact('org.jetbrains', 'annotations', '13.0')].join(delimiter)
const support = {
  'android/annotation/SystemApi.java': 'package android.annotation; public @interface SystemApi { Client client(); enum Client { MODULE_LIBRARIES } }',
  'android/compat/annotation/UnsupportedAppUsage.java': 'package android.compat.annotation; public @interface UnsupportedAppUsage {}',
  'libcore/util/NonNull.java': 'package libcore.util; @java.lang.annotation.Target(java.lang.annotation.ElementType.TYPE_USE) public @interface NonNull {}',
  'libcore/util/Nullable.java': 'package libcore.util; @java.lang.annotation.Target(java.lang.annotation.ElementType.TYPE_USE) public @interface Nullable {}',
  'android/os/Process.java': 'package android.os; public final class Process { public static int myUid(){return 1000;} }',
  'android/os/Bundle.java': `package android.os;
    public final class Bundle {
      private final java.util.Map<String,Object> data = new java.util.HashMap<>();
      public void putInt(String key,int value){data.put(key,value);}
      public void putString(String key,String value){data.put(key,value);}
      public int getInt(String key,int fallback){Object value=data.get(key);return value instanceof Integer?(Integer)value:fallback;}
      public String getString(String key){return (String)data.get(key);}
      public java.util.Set<String> keySet(){return data.keySet();}
    }`,
  'android/os/Message.java': `package android.os;
    public final class Message {
      public int sendingUid; public int what; private Bundle data;
      public static Message obtain(Object ignored,int what){Message value=new Message();value.what=what;return value;}
      public Bundle getData(){return data;} public void setData(Bundle data){this.data=data;}
    }`,
  'android/os/Messenger.java': `package android.os;
    public final class Messenger {
      private final java.util.function.Consumer<Message> receive;
      public Messenger(java.util.function.Consumer<Message> receive){this.receive=receive;}
      public void send(Message message){receive.accept(message);}
    }`,
}
const json = join(sdk, 'sources/android-36/org/json')
const java = readdirSync(json).filter(name => name.endsWith('.java')).map(name => join(json, name))
for (const [name, source] of Object.entries(support)) {
  const target = join(output, name)
  mkdirSync(dirname(target), { recursive: true }); writeFileSync(target, source); java.push(target)
}
const main = join(root, 'apps/android/android/app/src/main')
java.push(...['AndroidJava28', 'PtcScriptEngine', 'IsolatedScriptWire', 'IsolatedScriptRetirement', 'IsolatedScriptReceipt'].map(name =>
  join(main, `java/com/minnnng/dsh_android/${name}.java`)))
execFileSync('javac', ['--release', '17', '-encoding', 'UTF-8', '-d', output, ...java],
  { stdio: 'inherit', windowsHide: true, timeout: 60000 })
const sources = ['IsolatedScriptCallbacks', 'IsolatedToolRequest', 'IsolatedToolCallbackRetirement', 'IsolatedScriptToolBridge']
  .map(name => join(main, `kotlin/com/minnnng/dsh_android/${name}.kt`))
if (baseline) {
  const prior = execFileSync('git', ['show', 'HEAD:apps/android/android/app/src/main/kotlin/com/minnnng/dsh_android/IsolatedScriptToolBridge.kt'],
    { cwd: root, encoding: 'utf8', windowsHide: true, timeout: 10000 })
  const file = join(output, 'IsolatedScriptToolBridge.kt'); writeFileSync(file, prior); sources[sources.length - 1] = file
}
execFileSync('java', ['-cp', compiler, 'org.jetbrains.kotlin.cli.jvm.K2JVMCompiler',
  '-no-stdlib', '-no-reflect', '-jvm-target', '17', '-classpath', [output, compiler].join(delimiter), '-d', output,
  ...sources, join(import.meta.dirname, 'isolated-tool-callback-host/IsolatedScriptHostBridge.kt'),
  join(import.meta.dirname, 'isolated-tool-callback-host/IsolatedScriptToolBridgeTest.kt')],
{ stdio: 'inherit', windowsHide: true, timeout: 60000 })
execFileSync('java', ['-cp', [output, compiler].join(delimiter), 'com.minnnng.dsh_android.IsolatedScriptToolBridgeTestKt'],
  { stdio: 'inherit', windowsHide: true, timeout: 45000 })
if (!baseline) {
  const sdkOutput = join(output, 'sdk-types'); mkdirSync(sdkOutput)
  execFileSync('javac', ['--release', '17', '-encoding', 'UTF-8', '-d', sdkOutput,
    ...java.filter(file => !Object.keys(support).filter(name => name.startsWith('android/os/')).some(name => file === join(output, name)))],
  { stdio: 'inherit', windowsHide: true, timeout: 60000 })
  execFileSync('java', ['-cp', compiler, 'org.jetbrains.kotlin.cli.jvm.K2JVMCompiler',
    '-no-stdlib', '-no-reflect', '-jvm-target', '17', '-classpath', [sdkOutput, compiler, join(sdk, 'platforms/android-36/android.jar')].join(delimiter),
    '-d', sdkOutput, ...sources, join(import.meta.dirname, 'isolated-tool-callback-host/IsolatedScriptHostBridge.kt')],
  { stdio: 'inherit', windowsHide: true, timeout: 60000 })
  process.stdout.write('Actual Android SDK callback types compiled without message shims.\n')
}
process.stdout.write(`Callback bridge host evidence: ${output}\n`)
