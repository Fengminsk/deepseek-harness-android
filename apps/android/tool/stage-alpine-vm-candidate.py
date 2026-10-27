"""Assemble an offline Linux candidate without changing Android build defaults."""
import argparse
import importlib.util
import json
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile

ROOT = Path(__file__).resolve().parents[3]
TOOLS = ROOT / 'apps/android/tool'
spec = importlib.util.spec_from_file_location('linux_vm_sources', TOOLS / 'package-linux-vm-sources.py')
sources = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sources)
sha256 = sources.file_sha256
FILESYSTEM_COMMAND = 'set -e\ne2fsck -fn /dev/vdc\nprintf DSH_ALPINE_FILESYSTEM_OK\n'
CANDIDATE_FILES = {
    'assets/linux-vm/bios.bin', 'assets/linux-vm/kernel.bin', 'assets/linux-vm/disk.bin',
    'assets/linux-vm/manifest.json', 'assets/linux-vm/NOTICE.txt',
    'linux-vm-corresponding-source.tar', 'linux-vm-corresponding-source.manifest.json',
    'evidence/host-report.json', 'evidence/host-build.json',
}


def read_json(path):
    return json.loads(Path(path).read_text(encoding='utf-8'))


def checked_file(path, record):
    path = Path(path)
    if not path.is_file() or path.stat().st_size != record['bytes'] or sha256(path) != record['sha256']:
        raise ValueError('Artifact bytes differ: ' + str(path))
    return path


def cache_file(path, root=ROOT):
    path = Path(path).resolve(strict=True)
    if not path.is_relative_to((root / '.cache/android').resolve()) or not path.is_file():
        raise ValueError('Host evidence must name a file in the Android cache')
    return path


def boot_lock(root=ROOT):
    script = "import {tinyEmuGuestFixtureLock,alpineGuestSourceLock,tinyEmuSourceLock} from './apps/android/tool/tinyemu-source-lock.mjs'; console.log(JSON.stringify({tinyEmuGuestFixtureLock,alpineGuestSourceLock,tinyEmuSourceLock}))"
    return json.loads(subprocess.check_output(['node', '--input-type=module', '-e', script], cwd=root, text=True))


def validate_report(report_path, root=ROOT):
    report_path = cache_file(report_path, root)
    report = read_json(report_path)
    if (report.get('format') != 'linux-vm-host-report-v2' or report.get('suite') != 'alpine'
            or report.get('passed') is not True or report.get('androidDeviceVerified') is not False):
        raise ValueError('A successful current host-only Alpine report is required')
    if report.get('runnerSha256') != sha256(root / 'apps/android/tool/verify-tinyemu-host.mjs'):
        raise ValueError('The Alpine report used a different host runner')
    rows = report['reports']
    if [row['name'] for row in rows] != ['build', 'probe', 'filesystem']:
        raise ValueError('Alpine build, runtime and filesystem checks are all required')
    scripts = [root / 'apps/android/tool/linux-vm-host/build-alpine.sh',
               root / 'apps/android/tool/linux-vm-host/probe-alpine.sh']
    command_hashes = [sha256(path) for path in scripts] + [sources.sha256(FILESYSTEM_COMMAND.encode())]
    for row, command_hash, marker in zip(rows, command_hashes,
                                        ['DSH_ALPINE_IMAGE_BUILT', 'DSH_ALPINE_RUNTIME_OK', 'DSH_ALPINE_FILESYSTEM_OK']):
        if (row.get('nativeStatus') != 0 or row.get('exitCode') != 0 or row.get('imagesWritten') is not True
                or row.get('truncated') is not False or row.get('commandSha256') != command_hash
                or marker not in row.get('output', '')):
            raise ValueError('Alpine host check is incomplete or stale: ' + row['name'])
    image = checked_file(cache_file(report['alpineImage']['artifact'], root), report['alpineImage'])
    if image != (Path(rows[0]['directory']) / 'extra.bin').resolve() or not 0 < image.stat().st_size <= 256 * 1024 * 1024:
        raise ValueError('The candidate must be the exact successfully built system image')
    build_file = cache_file(report['hostBuild']['file'], root)
    if sha256(build_file) != report['hostBuild']['sha256']:
        raise ValueError('Host build record differs')
    build = read_json(build_file)
    if build.get('format') != 'tinyemu-windows-host-v1' or build['librarySha256'] != report['librarySha256']:
        raise ValueError('Host report and interpreter build differ')
    if sha256(cache_file(build['library'], root)) != build['librarySha256']:
        raise ValueError('Host interpreter differs from its tested build')
    engine = root / 'apps/android/android/app/src/main/cpp/linux_vm_engine.c'
    engine_inputs = [item for item in build['inputs'] if item['name'] == 'linux_vm_engine']
    if len(engine_inputs) != 1 or Path(engine_inputs[0]['source']).resolve() != engine.resolve():
        raise ValueError('Host build must include the production native engine')
    for item in build['inputs']:
        path = engine if item['name'] == 'linux_vm_engine' else cache_file(item['source'], root)
        if sha256(path) != item['sha256']:
            raise ValueError('Host native source changed: ' + item['name'])
    expected_java = ['apps/android/android/app/src/main/java/com/minnnng/dsh_android/LinuxVmConsole.java',
                     'apps/android/tool/linux-vm-host/LinuxVmHost.java']
    if [item['source'] for item in build['javaSources']] != expected_java:
        raise ValueError('Host console source inventory differs')
    for item in build['javaSources']:
        if sha256(root / item['source']) != item['sha256']:
            raise ValueError('Host console source changed: ' + item['source'])
    for key, path in [('patchSha256', 'patch-tinyemu.mjs'), ('hostHeaderSha256', 'linux-vm-host/include/sys/select.h')]:
        if build[key] != sha256(root / 'apps/android/tool' / path):
            raise ValueError('Host build input changed: ' + path)
    build_input = report['imageBuildInput']
    checked_file(cache_file(build_input['artifact'], root), build_input)
    if (build_input['packageLockSha256'] != sha256(root / 'apps/android/tool/alpine-packages.lock.json')
            or build_input['builderSha256'] != sha256(root / 'apps/android/tool/build-alpine-vm-input.py')):
        raise ValueError('Alpine input does not match the current package lock and builder')
    locks = boot_lock(root)
    if build['sourceArchiveSha256'] != locks['tinyEmuSourceLock']['sha256']:
        raise ValueError('Interpreter source archive differs from its lock')
    for kind in ['bios', 'kernel']:
        if any(report['imageManifest'][kind][key] != locks['tinyEmuGuestFixtureLock']['files'][kind][key]
               for key in ['bytes', 'sha256']):
            raise ValueError('Host report boot image differs: ' + kind)
    return report, build_file, image, locks


def candidate_file(directory, name):
    path = (directory / name).resolve(strict=True)
    if not path.is_relative_to(directory.resolve()) or not path.is_file():
        raise ValueError('Candidate member must stay inside its directory')
    return path


def verify_candidate(directory, root=ROOT, record=None):
    directory = Path(directory)
    expected_files = CANDIDATE_FILES | ({'candidate.json'} if record is None else set())
    members = list(directory.rglob('*'))
    if (any(path.is_symlink() for path in members)
            or {path.relative_to(directory).as_posix() for path in members if path.is_file()} != expected_files):
        raise ValueError('Candidate directory contains missing, extra or linked files')
    if record is None:
        record = read_json(directory / 'candidate.json')
    if (record.get('format') != 'linux-vm-candidate-v1' or record.get('androidDeviceVerified') is not False
            or record.get('productionEnabled') is not False or record.get('networkAvailable') is not False):
        raise ValueError('Candidate must retain explicit pending-device and disabled-production state')
    names = [item['path'] for item in record['files']]
    if len(set(names)) != len(names) or set(names) != CANDIDATE_FILES:
        raise ValueError('Candidate member inventory differs')
    for item in record['files']:
        checked_file(candidate_file(directory, item['path']), item)
    source_record = sources.verify_bundle(directory / 'linux-vm-corresponding-source.tar',
                                          directory / 'linux-vm-corresponding-source.manifest.json', root)
    manifest = read_json(directory / 'assets/linux-vm/manifest.json')
    if (manifest.get('version') != 1 or manifest.get('machine') != 'riscv64'
            or manifest.get('distribution') != 'alpine-candidate-awaiting-device-acceptance'
            or manifest.get('correspondingSourceSha256') != source_record['sha256']):
        raise ValueError('Candidate image manifest differs')
    report = read_json(directory / 'evidence/host-report.json')
    if (report.get('format') != 'linux-vm-host-report-v2' or report.get('passed') is not True
            or report.get('androidDeviceVerified') is not False or report.get('suite') != 'alpine'
            or report['runnerSha256'] != sha256(root / 'apps/android/tool/verify-tinyemu-host.mjs')
            or report['hostBuild']['sha256'] != sha256(directory / 'evidence/host-build.json')
            or report['alpineImage']['sha256'] != manifest['disk']['sha256']
            or report['alpineImage']['bytes'] != manifest['disk']['bytes']
            or record['correspondingSourceSha256'] != source_record['sha256']
            or record['systemImage'] != manifest['disk']):
        raise ValueError('Candidate evidence and system image differ')
    locks = boot_lock(root)
    for kind in ['bios', 'kernel']:
        if any(manifest[kind][key] != locks['tinyEmuGuestFixtureLock']['files'][kind][key]
               for key in ['bytes', 'sha256']):
            raise ValueError('Candidate boot image differs: ' + kind)
    for kind in ['bios', 'kernel', 'disk']:
        if manifest[kind]['asset'] != 'linux-vm/' + kind + '.bin':
            raise ValueError('Candidate image asset name differs')
        checked_file(candidate_file(directory, 'assets/' + manifest[kind]['asset']), manifest[kind])
    return record


def stage(report_path, source_manifest, root=ROOT):
    report, host_build, image, locks = validate_report(report_path, root)
    source_manifest = Path(source_manifest).resolve(strict=True)
    source_archive = source_manifest.with_suffix('').with_suffix('.tar')
    source_record = sources.verify_bundle(source_archive, source_manifest, root)
    boot_files = {}
    for kind in ['bios', 'kernel']:
        path = root / '.cache/android/linux-vm-assets/linux-vm' / (kind + '.bin')
        boot_files[kind] = checked_file(path, locks['tinyEmuGuestFixtureLock']['files'][kind])
    destination_root = root / '.cache/android/linux-vm-candidates'
    destination_root.mkdir(parents=True, exist_ok=True)
    directory = Path(tempfile.mkdtemp(prefix='alpine-', dir=destination_root))
    files = []

    def add(name, source=None, data=None):
        path = directory / name
        path.parent.mkdir(parents=True, exist_ok=True)
        if source is not None:
            shutil.copyfile(source, path)
        else:
            with path.open('xb') as stream:
                stream.write(data)
        item = dict(path=name, bytes=path.stat().st_size, sha256=sha256(path))
        files.append(item)
        return dict(asset=name.removeprefix('assets/'), bytes=item['bytes'], sha256=item['sha256'])

    manifest = dict(version=1, machine='riscv64', distribution='alpine-candidate-awaiting-device-acceptance',
                    alpineVersion=locks['alpineGuestSourceLock']['version'], correspondingSourceSha256=source_record['sha256'])
    for kind, path in [*boot_files.items(), ('disk', image)]:
        manifest[kind] = add('assets/linux-vm/' + kind + '.bin', path)
    add('assets/linux-vm/manifest.json', data=(json.dumps(manifest, indent=2) + '\n').encode())
    add('linux-vm-corresponding-source.tar', source_archive)
    add('linux-vm-corresponding-source.manifest.json', source_manifest)
    add('evidence/host-report.json', report_path)
    add('evidence/host-build.json', host_build)
    with tarfile.open(source_archive, 'r:') as archive:
        notice = archive.extractfile('NOTICE.txt').read()
    add('assets/linux-vm/NOTICE.txt', data=notice)
    for item in files:
        checked_file(directory / item['path'], item)
    if manifest['disk']['sha256'] != report['alpineImage']['sha256']:
        raise ValueError('Candidate system image changed during copying')
    record = dict(format='linux-vm-candidate-v1', androidDeviceVerified=False, productionEnabled=False,
                  networkAvailable=False, files=files, systemImage=manifest['disk'],
                  correspondingSourceSha256=source_record['sha256'],
                  limits=dict(memoryMiB=128, workspaceMiB=128, commandTimeoutMs=120000))
    verify_candidate(directory, root, record)
    with (directory / 'candidate.json').open('x', encoding='utf-8') as stream:
        stream.write(json.dumps(record, indent=2) + '\n')
    return dict(directory=str(directory), diskSha256=manifest['disk']['sha256'],
                sourceSha256=source_record['sha256'], androidDeviceVerified=False, productionEnabled=False)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--host-report', type=Path)
    parser.add_argument('--source-manifest', type=Path)
    parser.add_argument('--verify', type=Path)
    args = parser.parse_args()
    if args.verify:
        if args.host_report or args.source_manifest:
            parser.error('--verify cannot be combined with staging arguments')
        result = verify_candidate(args.verify)
        print(json.dumps(dict(directory=str(args.verify.resolve()), verifiedFiles=len(result['files']),
                              androidDeviceVerified=False, productionEnabled=False)))
    else:
        if not args.host_report or not args.source_manifest:
            parser.error('Use --host-report PATH --source-manifest PATH, or --verify DIRECTORY')
        print(json.dumps(stage(args.host_report, args.source_manifest)))
