"""Collect corresponding Alpine recipes, source inputs and licenses without executing recipes.

Exact aports revisions come from the SHA-pinned minirootfs and the signature-
verified package manifest. Every declared source input must match the recipe's
SHA512. Missing inputs remain explicit failures in the output manifest.
"""
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import re
import tarfile
from concurrent.futures import ThreadPoolExecutor

SPEC = importlib.util.spec_from_file_location('apk_collector', Path(__file__).with_name('collect-alpine-vm-packages.py'))
APK = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(APK)
CACHE = APK.CACHE
SOURCE_LOCK = Path(__file__).with_name('alpine-sources.lock.json')


def recipe_for(record):
    origin, revision = record['origin'], record['sourceRevision']
    if not re.fullmatch(r'[a-zA-Z0-9+_.-]+', origin) or not re.fullmatch(r'[a-f0-9]{40}', revision):
        raise ValueError('Invalid source identity')
    directory = CACHE / 'corresponding-source' / f'{origin}-{revision}'
    base = f'https://raw.githubusercontent.com/alpinelinux/aports/{revision}/main/{origin}/'
    data = APK.fetch(base + 'APKBUILD', directory / 'APKBUILD')
    pinned = None
    if SOURCE_LOCK.exists():
        pinned = next((entry for entry in json.loads(SOURCE_LOCK.read_text())['recipes']
                       if entry['origin'] == origin and entry['revision'] == revision), None)
        if not pinned or APK.sha256(data) != pinned['recipeSha256']:
            raise ValueError('Pinned source recipe differs: ' + origin)
    recipe = data.decode()
    inputs = re.findall(r'^([a-f0-9]{128})\s+([^\s]+)\s*$', recipe, re.M)
    if not inputs and origin != 'alpine-base':
        raise ValueError('Recipe has no supported SHA512 source declaration: ' + origin)
    packaging = set()
    for match in re.finditer(r'^(?:install|triggers)="([^"]*)"', recipe, re.M):
        for word in match[1].split():
            name = word.split('=', 1)[0].replace('${pkgname}', origin).replace('$pkgname', origin)
            if not re.fullmatch(r'[A-Za-z0-9+_.-]+', name):
                raise ValueError('Packaging script requires explicit recipe handling: ' + name)
            packaging.add(name)
    ancillary = []
    for name in sorted(packaging):
        content = APK.fetch(base + name, directory / name)
        if pinned:
            expected = next((entry for entry in pinned['packagingScripts'] if entry['name'] == name), None)
            if not expected or expected['sha256'] != APK.sha256(content):
                raise ValueError('Pinned packaging script differs: ' + name)
        ancillary.append(dict(name=name, url=base + name, sha256=APK.sha256(content), bytes=len(content)))
    return dict(origin=origin, revision=revision, directory=str(directory), url=base + 'APKBUILD',
                recipeSha256=APK.sha256(data), license=record.get('license'), generatedByRecipe=not inputs,
                inputs=[dict(name=name, sha512=sha) for sha, name in inputs], packagingScripts=ancillary, base=base)


def source_input(job):
    recipe, item = job
    name = item['name']
    if '/' in name or '\\' in name or name in ('.', '..'):
        raise ValueError('Unexpected source filename')
    output = Path(recipe['directory']) / name
    archive = name.endswith(('.tar.gz', '.tar.xz', '.tar.bz2', '.tgz', '.zip', '.tar.zst', '.tar.lz'))
    urls = [f'https://distfiles.alpinelinux.org/distfiles/v3.22/{name}', recipe['base'] + name] if archive else [recipe['base'] + name, f'https://distfiles.alpinelinux.org/distfiles/v3.22/{name}']
    errors = []
    for url in urls:
        try:
            data = APK.fetch(url, output, timeout=900 if archive else 120, resume=archive)
            if hashlib.sha512(data).hexdigest() != item['sha512']:
                raise ValueError('Source checksum differs: ' + name)
            return dict(**item, origin=recipe['origin'], revision=recipe['revision'], url=url,
                        path=str(output), bytes=len(data), sha256=APK.sha256(data))
        except Exception as error:
            errors.append(str(error))
    return dict(**item, origin=recipe['origin'], revision=recipe['revision'], error=errors)


def collect_licenses(sources):
    notices = []
    for source in sources:
        if 'error' in source:
            continue
        path = Path(source['path'])
        try:
            with tarfile.open(path, 'r:*') as archive:
                selected = [m for m in archive if m.isreg() and m.size <= 1024 * 1024
                            and re.fullmatch(r'(?:COPYING|LICENSE|LICENCE|COPYRIGHT|NOTICE)(?:[.-].*)?', Path(m.name).name, re.I)]
                for entry in selected[:100]:
                    content = archive.extractfile(entry).read()
                    notices.append(dict(origin=source['origin'], sourceSha256=source['sha256'],
                                        member=entry.name, sha256=APK.sha256(content), bytes=len(content)))
        except tarfile.ReadError:
            pass  # Plain patch/config inputs do not contain an archive license.
    return notices


def main():
    _, installed, _ = APK.signed_index()
    packages = json.loads(Path(__file__).with_name('alpine-packages.lock.json').read_text(encoding='utf-8'))['artifacts']
    records = [dict(origin=p.get('o', p['P']), sourceRevision=p['c'], license=p.get('L')) for p in installed] + packages
    unique = {(p['origin'], p['sourceRevision']): p for p in records}
    recipes, errors = [], []
    with ThreadPoolExecutor(max_workers=4) as pool:
        futures = [(record, pool.submit(recipe_for, record)) for record in unique.values()]
        for record, future in futures:
            try:
                recipe = future.result()
                recipes.append(recipe)
                print('Recipe ' + recipe['origin'] + ' (' + str(len(recipe['inputs'])) + ' inputs)', flush=True)
            except Exception as error:
                errors.append(dict(origin=record['origin'], error=str(error)))
        sources = list(pool.map(source_input, [(recipe, item) for recipe in recipes for item in recipe['inputs']]))
    result = dict(schema=1, recipes=recipes, sources=sources, errors=errors, licenseMembers=collect_licenses(sources))
    output = CACHE / 'alpine-corresponding-source.json'
    output.write_text(json.dumps(result, indent=2) + '\n', encoding='utf-8')
    failures = len(errors) + sum('error' in source for source in sources)
    print(json.dumps(dict(manifest=str(output), recipes=len(recipes), sources=len(sources), failures=failures)))
    if failures:
        raise SystemExit(1)


if __name__ == '__main__':
    main()
