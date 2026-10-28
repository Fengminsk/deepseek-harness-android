/** Compile the production Kotlin reader against explicit host API doubles, not an Android emulator. */
import { execFileSync } from 'node:child_process'
import { mkdtempSync, mkdirSync, readFileSync, readdirSync, writeFileSync } from 'node:fs'
import { delimiter, dirname, join, resolve } from 'node:path'

const configuration = JSON.parse(readFileSync(process.argv[2], 'utf8'))
if (typeof configuration.compilerCp !== 'string') throw new Error('Pass a Kotlin compiler configuration JSON')
const repository = resolve(import.meta.dirname, '../../..')
const output = mkdtempSync(join(repository, '.cache/android/document-provider-open-'))
const sdk = (process.env.ANDROID_HOME ?? readFileSync(join(repository, 'apps/android/android/local.properties'), 'utf8')
  .match(/^sdk\.dir=(.+)$/m)?.[1].trim().replaceAll('\\\\', '\\'))
if (!sdk) throw new Error('Android SDK sources are required for the host JSON implementation')
const sources = {
  'android/compat/annotation/UnsupportedAppUsage.java': 'package android.compat.annotation; public @interface UnsupportedAppUsage { int maxTargetSdk() default 0; long trackingBug() default 0; }',
  'android/annotation/SystemApi.java': 'package android.annotation; public @interface SystemApi { enum Client { MODULE_LIBRARIES } Client client(); }',
  'libcore/util/NonNull.java': 'package libcore.util; @java.lang.annotation.Target({java.lang.annotation.ElementType.TYPE_USE,java.lang.annotation.ElementType.PARAMETER,java.lang.annotation.ElementType.METHOD}) public @interface NonNull {}',
  'libcore/util/Nullable.java': 'package libcore.util; @java.lang.annotation.Target({java.lang.annotation.ElementType.TYPE_USE,java.lang.annotation.ElementType.PARAMETER,java.lang.annotation.ElementType.METHOD}) public @interface Nullable {}',

  'android/net/Uri.java': `package android.net; public final class Uri {
    private final String value; private Uri(String value) { this.value=value; }
    public static Uri parse(String value) { return new Uri(value); }
    public String getScheme() { return value.substring(0,value.indexOf(':')); }
  }`,
  'android/os/RemoteException.java': `package android.os; public class RemoteException extends Exception {}`,
  'android/os/CancellationSignal.java': `package android.os; public final class CancellationSignal {
    private boolean cancelled; private Runnable listener;
    public synchronized void throwIfCanceled() { if(cancelled) throw new java.util.concurrent.CancellationException(); }
    public void cancel() { Runnable action; synchronized(this) { cancelled=true; action=listener; } if(action!=null) action.run(); }
    public void setOnCancelListener(Runnable value) { boolean now; synchronized(this) { listener=value; now=cancelled; } if(now&&value!=null)value.run(); }
  }`,
  'android/content/res/AssetFileDescriptor.java': `package android.content.res;
    public abstract class AssetFileDescriptor implements java.io.Closeable {
      public abstract java.io.InputStream createInputStream() throws java.io.IOException;
    }`,
  'android/content/ContentProviderClient.java': `package android.content;
    public abstract class ContentProviderClient implements AutoCloseable {
      public abstract android.content.res.AssetFileDescriptor openAssetFile(android.net.Uri uri,String mode,
        android.os.CancellationSignal signal) throws android.os.RemoteException,java.io.IOException;
      public abstract void close();
    }`,
  'android/content/ContentResolver.java': `package android.content;
    public abstract class ContentResolver {
      public static final String SCHEME_CONTENT="content";
      public abstract ContentProviderClient acquireUnstableContentProviderClient(android.net.Uri uri);
    }`,
}
const files = []
for (const [name, source] of Object.entries(sources)) {
  const file = join(output, name); mkdirSync(dirname(file), { recursive: true }); writeFileSync(file, source); files.push(file)
}
files.push(...readdirSync(join(sdk, 'sources/android-36/org/json')).filter(name => name.endsWith('.java'))
  .map(name => join(sdk, 'sources/android-36/org/json', name)))
const main = join(repository, 'apps/android/android/app/src/main')
execFileSync('javac', ['--release', '17', '-encoding', 'UTF-8', '-d', output, ...files,
  join(main, 'java/com/minnnng/dsh_android/DocumentSearchJob.java'),
  join(main, 'java/com/minnnng/dsh_android/DocumentBinaryReadAccess.java'),
  join(main, 'java/com/minnnng/dsh_android/DocumentRevision.java'),
  join(main, 'java/com/minnnng/dsh_android/DocumentSnapshotStore.java')], { stdio: 'inherit', windowsHide: true, timeout: 60_000 })
execFileSync('java', ['-cp', configuration.compilerCp, 'org.jetbrains.kotlin.cli.jvm.K2JVMCompiler',
  '-no-stdlib', '-no-reflect', '-jvm-target', '17', '-classpath', [output, configuration.compilerCp].join(delimiter),
  '-d', output, join(main, 'kotlin/com/minnnng/dsh_android/DocumentProviderRead.kt'),
  join(main, 'kotlin/com/minnnng/dsh_android/DocumentTextReads.kt'),
  join(import.meta.dirname, 'document-provider-host/DocumentTextReadsTest.kt'),
  join(import.meta.dirname, 'document-provider-host/DocumentProviderReadTest.kt')],
{ stdio: 'inherit', windowsHide: true, timeout: 60_000 })
execFileSync('java', ['-cp', [output, configuration.compilerCp].join(delimiter),
  'com.minnnng.dsh_android.DocumentProviderReadTestKt'], { stdio: 'inherit', windowsHide: true, timeout: 30_000 })
execFileSync('java', ['-cp', [output, configuration.compilerCp].join(delimiter),
  'com.minnnng.dsh_android.DocumentTextReadsTestKt'], { stdio: 'inherit', windowsHide: true, timeout: 40_000 })
process.stdout.write(`Production reader host checks passed with explicit Android API doubles: ${output}\n`)
