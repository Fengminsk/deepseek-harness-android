"""Collect a pinned signed Alpine RV64 package closure for offline guest installation.

This build helper downloads official artifacts, verifies the APK index signature
with keys from the pinned minirootfs, then verifies each APK's index checksum and
data hash. It never runs package scripts on the host or grants guest networking.
"""
import base64
import hashlib
import io
import json
from pathlib import Path
import re
import subprocess
import tarfile
import zlib
from concurrent.futures import ThreadPoolExecutor
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import padding

ROOT = Path(__file__).resolve().parents[3]
CACHE = ROOT / '.cache/android/tinyemu-probe'
INDEX_SHA256 = '64e046acf0a38d027c351301bfd1670fda7b951f5c234a3739018d3d7780eed9'
ROOTFS_SHA256 = '50043f35362c3b7507a94814f2373948485e6d577a39f61833f2c37c0760458a'
BASE = 'https://dl-cdn.alpinelinux.org/alpine/v3.22/main/riscv64/'
TARGETS = ['e2fsprogs', 'python3', 'git', 'curl', 'ca-certificates']


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def fetch(url, output, timeout=120, resume=False):
    if not output.exists():
        output.parent.mkdir(parents=True, exist_ok=True)
        temporary = output.with_suffix(output.suffix + '.download')
        options = ['--continue-at', '-'] if resume and temporary.exists() else []
        subprocess.run(['curl.exe', '--fail', '--silent', '--show-error', '--location', '--max-time', str(timeout),
                        '--retry', '1', '--proxy', 'http://127.0.0.1:7897', *options, url, '--output', str(temporary)], check=True)
        temporary.replace(output)
    return output.read_bytes()


def gzip_members(data):
    parts = []
    while data:
        decompressor = zlib.decompressobj(31)
        decoded = decompressor.decompress(data)
        if not decompressor.eof:
            raise ValueError('Truncated gzip member')
        remaining = decompressor.unused_data
        parts.append((data[:len(data) - len(remaining)], decoded))
        data = remaining
    return parts


def tar_files(data):
    with tarfile.open(fileobj=io.BytesIO(data), mode='r:') as archive:
        return {m.name: archive.extractfile(m).read() for m in archive if m.isreg()}


def records(text):
    return [dict(line.split(':', 1) for line in block.splitlines() if len(line) > 1 and line[1] == ':')
            for block in text.strip().split('\n\n')]


def signed_index():
    rootfs = (CACHE / 'alpine-minirootfs-3.22.7-riscv64.tar.gz').read_bytes()
    if sha256(rootfs) != ROOTFS_SHA256:
        raise ValueError('Minirootfs differs')
    with tarfile.open(fileobj=io.BytesIO(rootfs), mode='r:gz') as archive:
        installed = records(archive.extractfile('./lib/apk/db/installed').read().decode())
        keys = {m.name.removeprefix('./etc/apk/keys/'): archive.extractfile(m).read()
                for m in archive if m.isreg() and m.name.startswith('./etc/apk/keys/')}
    data = fetch(BASE + 'APKINDEX.tar.gz', CACHE / 'apkindex-main.tar.gz')
    if sha256(data) != INDEX_SHA256:
        raise ValueError('Pinned package index differs; review the new index before updating the lock')
    parts = gzip_members(data)
    if len(parts) != 2:
        raise ValueError('Expected signed APK v2 index')
    signatures = tar_files(parts[0][1])
    if len(signatures) != 1:
        raise ValueError('Unexpected signature count')
    name, signature = next(iter(signatures.items()))
    if not name.startswith('.SIGN.RSA.'):
        raise ValueError('Unsupported index signature algorithm')
    keyname = name.removeprefix('.SIGN.RSA.')
    key = serialization.load_pem_public_key(keys[keyname])
    key.verify(signature, parts[1][0], padding.PKCS1v15(), hashes.SHA1())
    packages = records(tar_files(parts[1][1])['APKINDEX'].decode())
    return packages, installed, dict(url=BASE + 'APKINDEX.tar.gz', sha256=INDEX_SHA256,
                                      signature=name, keySha256=sha256(keys[keyname]), verified=True)


def dep_parts(value):
    match = re.fullmatch(r'([^<>=~]+)(>=|<=|=|~|>|<)?(.*)', value)
    if not match:
        raise ValueError('Unsupported dependency: ' + value)
    return match.groups()


def satisfies(actual, operator, required):
    if not operator:
        return True
    if operator == '=':
        return actual == required
    # The pinned closure uses only release versions and >= constraints.
    if operator == '>=' and re.fullmatch(r'[0-9.]+(?:-r[0-9]+)?', actual + '') and re.fullmatch(r'[0-9.]+(?:-r[0-9]+)?', required):
        return tuple(map(int, re.findall(r'\d+', actual))) >= tuple(map(int, re.findall(r'\d+', required)))
    raise ValueError('Dependency needs an apk solver: ' + repr((actual, operator, required)))


def closure(packages, installed, targets):
    byname = {p['P']: p for p in packages}
    providers = {}
    for package in packages:
        for provided in package.get('p', '').split():
            name, _, version = dep_parts(provided)
            providers.setdefault(name, []).append((package, version))
    # APK stores this file dependency implicitly. In this pinned Alpine release,
    # busybox-binsh owns /bin/sh; the original rootfs contains that exact package.
    providers['/bin/sh'] = [(byname['busybox-binsh'], byname['busybox-binsh']['V'])]
    selected = {}
    pending = list(targets)
    while pending:
        dependency = pending.pop()
        if dependency.startswith('!'):
            raise ValueError('Unexpected conflicting dependency')
        name, operator, required = dep_parts(dependency)
        candidates = [(byname[name], byname[name]['V'])] if name in byname else providers.get(name, [])
        valid = [(p, v) for p, v in candidates if satisfies(v, operator, required)]
        if len(valid) != 1:
            raise ValueError('Ambiguous or missing dependency: ' + dependency + ' ' + repr([p['P'] for p, _ in valid]))
        package = valid[0][0]
        if package['A'] not in ('riscv64', 'noarch'):
            raise ValueError('Wrong package architecture')
        if package['P'] not in selected:
            selected[package['P']] = package
            pending.extend(package.get('D', '').split())
    installed_byname = {p['P']: p for p in installed}
    return sorted(selected.values(), key=lambda p: p['P']), installed_byname


def collect_package(package):
    name = package['P'] + '-' + package['V'] + '.apk'
    path = CACHE / 'packages' / name
    data = fetch(BASE + name, path)
    if len(data) != int(package['S']):
        raise ValueError('APK size differs: ' + name)
    parts = gzip_members(data)
    if len(parts) != 3:
        raise ValueError('Expected signed APK v2 package: ' + name)
    expected = 'Q1' + base64.b64encode(hashlib.sha1(parts[1][0]).digest()).decode()
    if package['C'] != expected:
        raise ValueError('APK signed-index control checksum differs: ' + name)
    control = tar_files(parts[1][1])
    fields = dict(line.split(' = ', 1) for line in control['.PKGINFO'].decode().splitlines() if ' = ' in line)
    if fields.get('datahash') != sha256(parts[2][0]):
        raise ValueError('APK payload hash differs: ' + name)
    if fields.get('pkgname') != package['P'] or fields.get('pkgver') != package['V']:
        raise ValueError('APK identity differs: ' + name)
    return dict(name=package['P'], version=package['V'], architecture=package['A'], url=BASE + name,
                path=str(path), sha256=sha256(data), apkChecksum=package['C'], installedBytes=int(package['I']),
                license=package['L'], origin=package.get('o', package['P']), sourceRevision=package['c'],
                dependencies=package.get('D', '').split(), payloadSha256=fields['datahash'])


def main():
    packages, installed, index = signed_index()
    selected, installed_byname = closure(packages, installed, TARGETS)
    with ThreadPoolExecutor(max_workers=4) as pool:
        artifacts = list(pool.map(collect_package, selected))
    tool_closures = {target: [p['P'] for p in closure(packages, installed, [target])[0]] for target in TARGETS}
    for artifact in artifacts:
        old = installed_byname.get(artifact['name'])
        artifact['alreadyInMinirootfs'] = bool(old and old['V'] == artifact['version'])
    result = dict(schema=1, architecture='riscv64', index=index, requested=TARGETS, closures=tool_closures,
                  artifacts=artifacts, totalInstalledBytes=sum(a['installedBytes'] for a in artifacts))
    path = CACHE / 'alpine-packages.json'
    path.write_text(json.dumps(result, indent=2) + '\n', encoding='utf-8')
    print(json.dumps(dict(manifest=str(path), packages=len(artifacts), installedBytes=result['totalInstalledBytes'], closures=tool_closures)))


if __name__ == '__main__':
    main()
