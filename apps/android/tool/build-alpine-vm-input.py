"""Assemble deterministic, hash-checked input for guest-side Linux image construction."""
import hashlib
import io
import json
from pathlib import Path
import tarfile

ROOT = Path(__file__).resolve().parents[3]
CACHE = ROOT / '.cache/android/tinyemu-probe'
ROOTFS_SHA256 = '50043f35362c3b7507a94814f2373948485e6d577a39f61833f2c37c0760458a'


def digest(data):
    return hashlib.sha256(data).hexdigest()


def tar_bytes(files):
    buffer = io.BytesIO()
    with tarfile.open(fileobj=buffer, mode='w', format=tarfile.USTAR_FORMAT) as archive:
        for name, data in files:
            entry = tarfile.TarInfo(name)
            entry.size = len(data)
            entry.mode = 0o644
            entry.mtime = entry.uid = entry.gid = 0
            archive.addfile(entry, io.BytesIO(data))
    return buffer.getvalue()


def assemble():
    lock_data = Path(__file__).with_name('alpine-packages.lock.json').read_bytes()
    lock = json.loads(lock_data)
    rootfs = (CACHE / 'alpine-minirootfs-3.22.7-riscv64.tar.gz').read_bytes()
    if digest(rootfs) != ROOTFS_SHA256:
        raise ValueError('Pinned Alpine rootfs differs')
    packages = {}
    for artifact in lock['artifacts']:
        name = artifact['name'] + '-' + artifact['version'] + '.apk'
        data = (CACHE / 'packages' / name).read_bytes()
        if digest(data) != artifact['sha256']:
            raise ValueError('Pinned APK differs: ' + name)
        packages[artifact['name']] = ('packages/' + name, data)
    manifest = ('manifest.json', lock_data)
    tools = tar_bytes([packages[name] for name in sorted(packages)] + [manifest])
    e2fs = tar_bytes([packages[name] for name in sorted(lock['closures']['e2fsprogs'])] + [manifest])
    inputs = [('rootfs.tar.gz', rootfs), ('tools.tar', tools), ('e2fs.tar', e2fs)]
    result = tar_bytes(inputs)
    if len(result) > 64 * 1024 * 1024:
        raise ValueError('Guest build input exceeds 64 MiB')
    output = CACHE / 'alpine-build-input.tar'
    if output.exists():
        if output.read_bytes() != result:
            raise ValueError('Refusing to replace an existing different input artifact')
    else:
        with output.open('xb') as handle:
            handle.write(result)
    record = dict(schema=1, artifact=output.name, bytes=len(result), sha256=digest(result),
                  builderSha256=digest(Path(__file__).read_bytes()), packageLockSha256=digest(lock_data),
                  members=[dict(name=name, bytes=len(data), sha256=digest(data)) for name, data in inputs])
    output.with_suffix('.manifest.json').write_text(json.dumps(record, indent=2) + '\n', encoding='utf-8')
    return record


if __name__ == '__main__':
    print(json.dumps(assemble()))
