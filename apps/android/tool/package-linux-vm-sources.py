"""Package verified guest/interpreter corresponding sources as a separate release artifact.

This bundles actual sources, patches, configs and notices. The old demo rootfs is
excluded. Android embedding files are a snapshot; rerun after final source edits.
"""
import hashlib
import io
import json
from pathlib import Path
import subprocess
import tarfile

ROOT = Path(__file__).resolve().parents[3]
CACHE = ROOT / '.cache/android/tinyemu-probe'

# Preserve repository-relative layout so the included builders keep their
# relative imports and their repository-root calculation after extraction.
PROJECT_INPUTS = (
    *(f'apps/android/tool/{name}' for name in (
        'alpine-packages.lock.json', 'alpine-sources.lock.json', 'tinyemu-source-lock.mjs',
        'build-tinyemu.mjs', 'patch-tinyemu.mjs', 'build-tinyemu-host.mjs',
        'verify-tinyemu-host.mjs', 'stage-linux-vm-fixture.mjs', 'stage-alpine-vm-candidate.py',
        'collect-alpine-vm-packages.py', 'collect-alpine-vm-sources.py',
        'build-alpine-vm-image.py', 'build-alpine-vm-input.py', 'alpine-vm-smoke.sh',
        'package-linux-vm-sources.py', 'test_linux_vm_candidate.py', 'tinyemu-build.md', 'tinyemu-build.zh.md',
        'linux-vm-release.py', 'test_linux_vm_release.py', 'verify-apk.ps1', 'verify-apk.test.ps1', 'runtime-lock.json',
        'linux-vm-runtime.md', 'linux-vm-runtime.zh.md',
        'linux-vm-recovery.md', 'linux-vm-recovery.zh.md', 'acceptance-linux-vm-recovery.mjs',
        'acceptance-linux-vm-network.mjs', 'linux-vm-network.md', 'linux-vm-network.zh.md',
        'linux-vm-host/LinuxVmNetworkHost.java', 'linux-vm-host/dsh-fetch.py',
        'linux-vm-host/LinuxVmHost.java', 'linux-vm-host/include/sys/select.h',
        'linux-vm-host/build-alpine.sh', 'linux-vm-host/probe-alpine.sh',
        'linux-vm-host/README.md', 'linux-vm-host/README.zh.md',
    )),
    *(f'apps/android/android/app/src/main/cpp/{name}' for name in (
        'CMakeLists.txt', 'linux_vm_engine.c', 'linux_vm_files.c', 'linux_vm.cmake',
    )),
    *(f'apps/android/android/app/src/main/java/com/minnnng/dsh_android/{name}.java' for name in (
        'LinuxVmConsole', 'LinuxVmBlockStore', 'LinuxVmRecoveryStore',
        'LinuxVmHttpsMailbox', 'LocalHttpConnectTunnel', 'IsolatedNetworkBroker',
        'IsolatedNetworkJournal', 'IsolatedExecutionPolicyOwner', 'AndroidJava28',
        'IsolatedCapabilityBroker', 'IsolatedScriptWire', 'IsolatedWorkerInput',
        'IsolatedWorkerTextEdit', 'IsolatedWorkerTextSearch', 'IsolatedWorkerWriteback', 'PtcScriptEngine',
    )),
    *(f'apps/android/android/app/src/main/kotlin/com/minnnng/dsh_android/{name}.kt' for name in (
        'IsolatedLinuxVmService', 'LinuxVmEngine', 'LinuxVmRunner', 'LinuxVmManager',
        'LinuxVmImageStore', 'LinuxVmFileInput', 'LinuxVmFileOutput', 'LinuxVmFilePublisher',
    )),
    'apps/android/android/app/build.gradle.kts',
    'apps/android/android/app/linux-vm-rules.pro',
    'apps/android/android/app/src/test/java/com/minnnng/dsh_android/LinuxVmNetworkHostTest.java',
    'apps/android/android/app/src/test/java/com/minnnng/dsh_android/LinuxVmRecoveryStoreTest.java',
    'apps/android/runtime/native-linux-vm.mjs',
    'apps/android/runtime/native-linux-vm-inspection.mjs',
    'apps/android/runtime/tool-linux-vm.mjs',
)


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def file_sha256(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def locked_members(root):
    script = "import {tinyEmuSourceLock,tinyEmuBootSourceLock} from './apps/android/tool/tinyemu-source-lock.mjs'; console.log(JSON.stringify({tinyEmuSourceLock,tinyEmuBootSourceLock}))"
    locks = json.loads(subprocess.check_output(['node', '--input-type=module', '-e', script], cwd=root, text=True))
    sources = json.loads((root / 'apps/android/tool/alpine-sources.lock.json').read_text(encoding='utf-8'))
    if sources['errors'] or any('error' in item for item in sources['sources']):
        raise ValueError('Corresponding source closure is incomplete')
    tiny = locks['tinyEmuSourceLock']
    result = {'tinyemu/tinyemu-' + tiny['version'] + '.tar.gz': tiny['sha256']}
    for name, component in locks['tinyEmuBootSourceLock'].items():
        revision = component['url'].split('/')[-1]
        stem = 'riscv-pk-' if name == 'bios' else 'riscv-linux-'
        result['boot/' + stem + revision + '.tar.gz'] = component['sha256']
        result['boot/' + name + '-LICENSE.txt'] = component['licenseSha256']
        for key in ('patch', 'config'):
            if key in component:
                result['boot/' + component[key]] = component[key + 'Sha256']
    for recipe in sources['recipes']:
        stem = 'alpine/' + recipe['origin'] + '-' + recipe['revision'] + '/'
        result[stem + 'APKBUILD'] = recipe['recipeSha256']
        for item in recipe['packagingScripts']:
            result[stem + item['name']] = item['sha256']
    for item in sources['sources']:
        stem = 'alpine/' + item['origin'] + '-' + item['revision'] + '/'
        result[stem + item['name']] = item['sha256']
    return result


def verify_bundle(archive_path, manifest_path, root=ROOT):
    """Check every archived byte and require the current Linux build inputs."""
    archive_path, manifest_path = Path(archive_path), Path(manifest_path)
    record = json.loads(manifest_path.read_text(encoding='utf-8'))
    if record.get('schema') != 2 or record.get('artifact') != archive_path.name:
        raise ValueError('Regenerate a version 2 corresponding-source bundle')
    if archive_path.stat().st_size != record.get('bytes') or file_sha256(archive_path) != record.get('sha256'):
        raise ValueError('Corresponding-source archive identity differs')
    expected = {item['name']: item for item in record['members']}
    if len(expected) != len(record['members']):
        raise ValueError('Duplicate corresponding-source inventory member')
    locked = locked_members(root)
    if set(expected) != set(locked) | {'project/' + path for path in PROJECT_INPUTS} | {'NOTICE.txt'}:
        raise ValueError('Corresponding-source inventory does not match the locked source closure')
    for name, digest in locked.items():
        if expected[name]['sha256'] != digest:
            raise ValueError('Corresponding-source locked member differs: ' + name)
    for path in PROJECT_INPUTS:
        item = expected.get('project/' + path)
        if item is None or item['sha256'] != file_sha256(root / path):
            raise ValueError('Corresponding-source build input is missing or stale: ' + path)
    seen = set()
    with tarfile.open(archive_path, 'r:') as archive:
        for entry in archive:
            if not entry.isfile() or entry.name not in expected or entry.name in seen:
                raise ValueError('Unexpected corresponding-source member: ' + entry.name)
            seen.add(entry.name)
            item = expected[entry.name]
            with archive.extractfile(entry) as stream:
                actual = hashlib.file_digest(stream, 'sha256').hexdigest()
            if entry.size != item['bytes'] or actual != item['sha256']:
                raise ValueError('Corresponding-source member differs: ' + entry.name)
    if seen != set(expected):
        raise ValueError('Corresponding-source archive is missing inventoried members')
    return record


def package():
    script = "import {tinyEmuSourceLock,tinyEmuBootSourceLock} from './apps/android/tool/tinyemu-source-lock.mjs'; console.log(JSON.stringify({tinyEmuSourceLock,tinyEmuBootSourceLock}))"
    locks = json.loads(subprocess.check_output(['node', '--input-type=module', '-e', script], cwd=ROOT, text=True))
    source_lock = Path(__file__).with_name('alpine-sources.lock.json')
    sources = json.loads(source_lock.read_text())
    if sources['errors'] or any('error' in item for item in sources['sources']):
        raise ValueError('Corresponding source closure is incomplete')
    records, names = [], set()
    output = CACHE / 'linux-vm-corresponding-source.tar'
    temporary = output.with_suffix('.tar.building')
    if temporary.exists():
        raise ValueError('Previous source bundle build is present')
    with tarfile.open(temporary, 'w', format=tarfile.PAX_FORMAT) as archive:
        def add(name, path=None, expected=None, content=None):
            if name in names:
                raise ValueError('Duplicate source bundle member: ' + name)
            names.add(name)
            data = Path(path).read_bytes() if content is None else content
            actual = sha256(data)
            if expected and actual != expected:
                raise ValueError('Pinned source input differs: ' + name)
            entry = tarfile.TarInfo(name)
            entry.size, entry.mode, entry.mtime = len(data), 0o644, 0
            archive.addfile(entry, io.BytesIO(data))
            records.append(dict(name=name, bytes=len(data), sha256=actual))
        tiny = locks['tinyEmuSourceLock']
        add('tinyemu/tinyemu-' + tiny['version'] + '.tar.gz', ROOT / '.cache/android/tinyemu-api/tinyemu.tar.gz', tiny['sha256'])
        for name, component in locks['tinyEmuBootSourceLock'].items():
            revision = component['url'].split('/')[-1]
            stem = 'riscv-pk-' if name == 'bios' else 'riscv-linux-'
            add('boot/' + stem + revision + '.tar.gz', CACHE / 'sources' / (stem + revision + '.tar.gz'), component['sha256'])
            add('boot/' + name + '-LICENSE.txt', CACHE / 'sources' / (stem + revision + '.tar.gz.LICENSE'), component['licenseSha256'])
            for key in ('patch', 'config'):
                if key in component:
                    add('boot/' + component[key], CACHE / 'diskimage-linux-riscv-2018-09-23/patches' / component[key], component[key + 'Sha256'])
        for recipe in sources['recipes']:
            stem = recipe['origin'] + '-' + recipe['revision']
            directory = CACHE / 'corresponding-source' / stem
            add('alpine/' + stem + '/APKBUILD', directory / 'APKBUILD', recipe['recipeSha256'])
            for item in recipe['packagingScripts']:
                add('alpine/' + stem + '/' + item['name'], directory / item['name'], item['sha256'])
        for item in sources['sources']:
            stem = item['origin'] + '-' + item['revision']
            add('alpine/' + stem + '/' + item['name'], CACHE / 'corresponding-source' / stem / item['name'], item['sha256'])
        for path in PROJECT_INPUTS:
            add('project/' + path, ROOT / path)
        notice = ['DSH Linux guest corresponding sources', '',
                  'TinyEMU: MIT. Boot firmware: BSD-3-Clause. Linux: GPL-2.0 with syscall exception.',
                  'Full original sources and their license notices are included in the upstream archives.',
                  'Alpine APKBUILD files, fixed source inputs and packaging scripts are included by exact aports revision.',
                  'alpine-sources.lock.json indexes original license members and SHA256/SHA512 checksums.',
                  'The old TinyEMU demonstration root filesystem is not included or covered by this bundle.',
                  'Android embedding sources and host/guest builders are a build-time snapshot under project/.',
                  'Regenerate this archive for the release being shipped. This is not the complete Android App source tree.', '',
                  'Alpine source origins and declared package licenses:']
        notice.extend(recipe['origin'] + ': ' + (recipe['license'] or 'See source notices') for recipe in sources['recipes'])
        add('NOTICE.txt', content=('\n'.join(notice) + '\n').encode())
    checksum = file_sha256(temporary)
    if output.exists() and file_sha256(output) != checksum:
        # Rebuilds are explicit, but prior artifacts remain recoverable by digest.
        old_hash = file_sha256(output)
        previous = output.with_name('linux-vm-corresponding-source-' + old_hash + '.tar')
        if previous.exists():
            raise ValueError('Prior source snapshot already exists; inspect before rebuilding')
        previous_manifest = previous.with_suffix('.manifest.json')
        current_manifest = output.with_suffix('.manifest.json')
        if current_manifest.exists():
            with previous_manifest.open('xb') as stream:
                stream.write(current_manifest.read_bytes())
        output.rename(previous)
    temporary.replace(output)
    manifest = dict(schema=2, artifact=output.name, bytes=output.stat().st_size, sha256=checksum, members=records)
    output.with_suffix('.manifest.json').write_text(json.dumps(manifest, indent=2) + '\n', encoding='utf-8')
    verify_bundle(output, output.with_suffix('.manifest.json'))
    return {key: manifest[key] for key in ('artifact', 'bytes', 'sha256')}


if __name__ == '__main__':
    print(json.dumps(package()))
