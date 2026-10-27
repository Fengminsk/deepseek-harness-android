"""Prepare a pinned Alpine acceptance build and audit the resulting APK bytes."""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import shutil
import struct
import zipfile

ROOT = Path(__file__).resolve().parents[3]
spec = importlib.util.spec_from_file_location('linux_candidate', Path(__file__).with_name('stage-alpine-vm-candidate.py'))
candidate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(candidate)
sha256 = candidate.sha256
NATIVE_ENTRY = 'lib/arm64-v8a/libpocket_linux_vm.so'
SOURCE_MANIFEST = 'linux-vm-corresponding-source.manifest.json'


def load_candidate(directory, expected_sha256, root=ROOT):
    directory = Path(directory)
    allowed = (root / '.cache/android/linux-vm-candidates').resolve()
    if (not directory.is_absolute() or directory.is_symlink()
            or directory.resolve(strict=True).parent != allowed or not directory.name.startswith('alpine-')):
        raise ValueError('Use an absolute Alpine candidate directory directly inside this repository cache')
    directory = directory.resolve(strict=True)
    identity = directory / 'candidate.json'
    if sha256(identity) != expected_sha256:
        raise ValueError('Candidate record changed after build selection')
    record = candidate.verify_candidate(directory, root)
    # Recheck the actual successful guest runs, not just copied success flags.
    candidate.validate_report(directory / 'evidence/host-report.json', root)
    if sha256(identity) != expected_sha256:
        raise ValueError('Candidate record changed during verification')
    return directory, record


def asset_map(directory, record):
    result = {item['path'].removeprefix('assets/'): directory / item['path']
              for item in record['files'] if item['path'].startswith('assets/')}
    result['linux-vm/candidate.json'] = directory / 'candidate.json'
    result['linux-vm/corresponding-source.manifest.json'] = directory / SOURCE_MANIFEST
    return result


def asset_identities(directory, record, expected_sha256):
    result = {item['path'].removeprefix('assets/'): dict(bytes=item['bytes'], sha256=item['sha256'])
              for item in record['files'] if item['path'].startswith('assets/')}
    source = next(item for item in record['files'] if item['path'] == SOURCE_MANIFEST)
    result['linux-vm/corresponding-source.manifest.json'] = dict(bytes=source['bytes'], sha256=source['sha256'])
    result['linux-vm/candidate.json'] = dict(bytes=(directory / 'candidate.json').stat().st_size,
                                           sha256=expected_sha256)
    return result


def prepare(directory, expected_sha256, root=ROOT):
    directory, record = load_candidate(directory, expected_sha256, root)
    target = root / '.cache/android/linux-vm-release-assets' / directory.name / expected_sha256 / 'assets'
    files = asset_map(directory, record)
    identities = asset_identities(directory, record, expected_sha256)
    # Keep old generations. An interrupted copy is a failed generation, never a
    # silently repaired build input; select a freshly staged candidate to retry.
    if not target.exists():
        target.mkdir(parents=True, exist_ok=False)
        for name, source in files.items():
            output = target / name
            output.parent.mkdir(parents=True, exist_ok=True)
            with source.open('rb') as incoming, output.open('xb') as outgoing:
                shutil.copyfileobj(incoming, outgoing)
    members = list(target.rglob('*'))
    if (any(path.is_symlink() for path in members)
            or {path.relative_to(target).as_posix() for path in members if path.is_file()} != set(files)):
        raise ValueError('Prepared asset inventory differs; stage a fresh candidate')
    for name, identity in identities.items():
        candidate.checked_file(target / name, identity)
    # Catch a concurrent replacement of the candidate record or assets.
    candidate.verify_candidate(directory, root)
    if sha256(directory / 'candidate.json') != expected_sha256:
        raise ValueError('Candidate record changed during preparation')
    return dict(format='linux-vm-release-assets-v1', assets=str(target), files=sorted(files),
                candidateSha256=expected_sha256, androidDeviceVerified=False, productionEnabled=False)


def native_identity(path):
    path = Path(path)
    with path.open('rb') as stream:
        header = stream.read(64)
    if (len(header) != 64 or header[:7] != b'\x7fELF\x02\x01\x01'
            or struct.unpack_from('<HH', header, 16) != (3, 183)):
        raise ValueError('The packaged Linux provider must be an ELF64 AArch64 shared library')
    return dict(bytes=path.stat().st_size, sha256=sha256(path))


def check_zip_member(archive, name, identity):
    info = archive.getinfo(name)
    if info.file_size != identity['bytes']:
        raise ValueError('APK member size differs: ' + name)
    with archive.open(info) as stream:
        digest = hashlib.file_digest(stream, 'sha256').hexdigest()
    if digest != identity['sha256']:
        raise ValueError('APK member checksum differs: ' + name)
    return dict(path=name, **identity)


def verify_apk(apk, directory, expected_sha256, native, root=ROOT):
    directory, record = load_candidate(directory, expected_sha256, root)
    identities = asset_identities(directory, record, expected_sha256)
    with zipfile.ZipFile(apk) as archive:
        names = archive.namelist()
        if len(set(names)) != len(names):
            raise ValueError('APK contains duplicate ZIP entries')
        expected = {'assets/' + name for name in identities} | {NATIVE_ENTRY}
        actual = {name for name in names if name.startswith('assets/linux-vm/') and not name.endswith('/')
                  or name.endswith('/libpocket_linux_vm.so')}
        if actual != expected:
            raise ValueError('APK Linux assets or native ABI inventory differs')
        audited = [check_zip_member(archive, 'assets/' + name, identity) for name, identity in identities.items()]
        native_record = check_zip_member(archive, NATIVE_ENTRY, native_identity(native))
    return dict(format='linux-vm-release-apk-v1', success=True,
                apk=dict(path=str(Path(apk).resolve()), bytes=Path(apk).stat().st_size, sha256=sha256(apk)),
                candidateSha256=expected_sha256, diskSha256=record['systemImage']['sha256'],
                correspondingSourceSha256=record['correspondingSourceSha256'],
                assets=audited, native=native_record, androidDeviceVerified=False, productionEnabled=False,
                networkAvailable=False)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['prepare', 'verify-apk'])
    parser.add_argument('--candidate', required=True, type=Path)
    parser.add_argument('--candidate-sha256', required=True)
    parser.add_argument('--apk', type=Path)
    parser.add_argument('--native-library', type=Path)
    parser.add_argument('--report', type=Path)
    args = parser.parse_args()
    if args.action == 'prepare':
        if args.apk or args.native_library:
            parser.error('prepare does not accept APK or native library arguments')
        result = prepare(args.candidate, args.candidate_sha256)
    else:
        if not args.apk or not args.native_library:
            parser.error('verify-apk requires --apk and --native-library')
        result = verify_apk(args.apk, args.candidate, args.candidate_sha256, args.native_library)
    output = json.dumps(result, indent=2) + '\n'
    if args.report:
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text(output, encoding='utf-8')
    print(output, end='')
