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


def sha256(data):
    return hashlib.sha256(data).hexdigest()


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
        for filename in ['alpine-packages.lock.json', 'alpine-sources.lock.json', 'tinyemu-source-lock.mjs',
                         'build-tinyemu.mjs', 'patch-tinyemu.mjs', 'collect-alpine-vm-packages.py',
                         'collect-alpine-vm-sources.py', 'build-alpine-vm-input.py', 'package-linux-vm-sources.py']:
            add('android/tool/' + filename, Path(__file__).with_name(filename))
        for filename in ['linux_vm_engine.c', 'linux_vm_files.c', 'linux_vm.cmake']:
            add('android/cpp/' + filename, ROOT / 'apps/android/android/app/src/main/cpp' / filename)
        notice = ['DSH Linux guest corresponding sources', '',
                  'TinyEMU: MIT. Boot firmware: BSD-3-Clause. Linux: GPL-2.0 with syscall exception.',
                  'Full original sources and their license notices are included in the upstream archives.',
                  'Alpine APKBUILD files, fixed source inputs and packaging scripts are included by exact aports revision.',
                  'alpine-sources.lock.json indexes original license members and SHA256/SHA512 checksums.',
                  'The old TinyEMU demonstration root filesystem is not included or covered by this bundle.',
                  'Android embedding sources are a build-time snapshot; regenerate this archive for the release being shipped.', '',
                  'Alpine source origins and declared package licenses:']
        notice.extend(recipe['origin'] + ': ' + (recipe['license'] or 'See source notices') for recipe in sources['recipes'])
        add('NOTICE.txt', content=('\n'.join(notice) + '\n').encode())
    checksum = hashlib.file_digest(temporary.open('rb'), 'sha256').hexdigest()
    if output.exists() and hashlib.file_digest(output.open('rb'), 'sha256').hexdigest() != checksum:
        # Rebuilds are explicit, but prior artifacts remain recoverable by digest.
        old_hash = hashlib.file_digest(output.open('rb'), 'sha256').hexdigest()
        previous = output.with_name('linux-vm-corresponding-source-' + old_hash + '.tar')
        if previous.exists():
            raise ValueError('Prior source snapshot already exists; inspect before rebuilding')
        output.rename(previous)
    temporary.replace(output)
    manifest = dict(schema=1, artifact=output.name, bytes=output.stat().st_size, sha256=checksum, members=records)
    output.with_suffix('.manifest.json').write_text(json.dumps(manifest, indent=2) + '\n', encoding='utf-8')
    return {key: manifest[key] for key in ('artifact', 'bytes', 'sha256')}


if __name__ == '__main__':
    print(json.dumps(package()))
