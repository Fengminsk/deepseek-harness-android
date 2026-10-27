"""Audit independent SAF test-UID DEX dependencies using only the test APK and Android SDK."""
import argparse
import hashlib
import json
import re
import struct
import zipfile
from pathlib import Path


def fingerprint(path):
    digest = hashlib.sha256()
    with path.open('rb') as stream:
        for data in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(data)
    return {'path': str(path.resolve()), 'bytes': path.stat().st_size, 'sha256': digest.hexdigest()}


def apk_inventory(path):
    definitions, methods, fields, types = {}, set(), set(), set()
    accesses, executable_types, annotations, dex_files, type_accesses = [], set(), set(), [], []
    with zipfile.ZipFile(path) as apk:
        for entry in apk.namelist():
            if not re.fullmatch(r'classes(?:[0-9]+)?\.dex', entry):
                continue
            dex_files.append(entry)
            b = apk.read(entry)
            assert b[:4] == b'dex\n' and b[4:7] in (b'035', b'037', b'038', b'039', b'040')
            assert struct.unpack_from('<I', b, 40)[0] == 0x12345678

            def u(offset): return struct.unpack_from('<I', b, offset)[0]
            def h(offset): return struct.unpack_from('<H', b, offset)[0]
            def leb(pos):
                value, shift = 0, 0
                while True:
                    byte = b[pos]
                    pos += 1
                    value |= (byte & 127) << shift
                    if not byte & 128:
                        return value, pos
                    shift += 7
                    assert shift < 35

            strings = []
            for i in range(u(56)):
                _, pos = leb(u(u(60) + 4 * i))
                strings.append(b[pos:b.index(0, pos)].decode('utf-8', errors='replace'))
            ts = [strings[u(u(68) + 4 * i)] for i in range(u(64))]
            types.update(ts)

            def type_list(pos):
                return tuple(ts[h(pos + 4 + 2 * j)] for j in range(u(pos))) if pos else ()

            ps = ['(' + ''.join(type_list(u(u(76) + 12 * i + 8))) + ')' + ts[u(u(76) + 12 * i + 4)]
                  for i in range(u(72))]
            ms = [(ts[h(u(92) + 8 * i)], strings[u(u(92) + 8 * i + 4)], ps[h(u(92) + 8 * i + 2)])
                  for i in range(u(88))]
            fs = [(ts[h(u(84) + 8 * i)], strings[u(u(84) + 8 * i + 4)], ts[h(u(84) + 8 * i + 2)])
                  for i in range(u(80))]
            methods.update(ms)
            fields.update(fs)

            def annotation_set(pos):
                if not pos:
                    return
                for j in range(u(pos)):
                    item = u(pos + 4 + j * 4)
                    type_index, _ = leb(item + 1)
                    annotations.add(ts[type_index])

            def annotation_directory(pos):
                if not pos:
                    return
                annotation_set(u(pos))
                field_count, method_count, parameter_count = u(pos + 4), u(pos + 8), u(pos + 12)
                cursor = pos + 16
                for _ in range(field_count + method_count):
                    annotation_set(u(cursor + 4))
                    cursor += 8
                for _ in range(parameter_count):
                    refs = u(cursor + 4)
                    for j in range(u(refs)):
                        annotation_set(u(refs + 4 + j * 4))
                    cursor += 8

            widths = {op: 1 for op in range(256)}
            for op in [2, 5, 8, 0x13, 0x15, 0x16, 0x19, 0x1a, 0x1c, 0x1f, 0x20, 0x22, 0x23, 0x29,
                       *range(0x2d, 0x3e), *range(0x44, 0x6e), *range(0x90, 0xb0),
                       *range(0xd0, 0xe3), 0xfe, 0xff]:
                widths[op] = 2
            for op in [3, 6, 9, 0x14, 0x17, 0x1b, 0x24, 0x25, 0x26, 0x2a, 0x2b, 0x2c,
                       *range(0x6e, 0x73), *range(0x74, 0x79), 0xfc, 0xfd]:
                widths[op] = 3
            widths[0x18] = 5
            widths[0xfa] = widths[0xfb] = 4
            unused = {*range(0x3e, 0x44), 0x73, 0x79, 0x7a, *range(0xe3, 0xfa)}

            def inspect_code(pos, caller):
                if not pos:
                    return
                count = u(pos + 12)
                units = struct.unpack_from('<' + str(count) + 'H', b, pos + 16)
                pc = 0
                while pc < count:
                    op = units[pc] & 255
                    if op == 0 and units[pc] != 0:
                        tag = units[pc] >> 8
                        if tag == 1:
                            width = 4 + units[pc + 1] * 2
                        elif tag == 2:
                            width = 2 + units[pc + 1] * 4
                        elif tag == 3:
                            size = units[pc + 2] | (units[pc + 3] << 16)
                            width = 4 + (units[pc + 1] * size + 1) // 2
                        else:
                            raise AssertionError(('Unknown payload', entry, caller, pc, tag))
                    else:
                        assert op not in unused, ('Unused opcode', entry, caller, pc, op)
                        width = widths[op]
                        assert op not in (0xfa, 0xfb, 0xfc, 0xfd, 0xfe, 0xff), ("Unsupported dynamic opcode", entry, caller, pc, op)
                        if 0x6e <= op <= 0x72 or 0x74 <= op <= 0x78 or op in (0xfa, 0xfb):
                            accesses.append((caller, pc, 'methods', ms[units[pc + 1]], op in (0x71, 0x77)))
                        elif 0x52 <= op <= 0x6d:
                            accesses.append((caller, pc, 'fields', fs[units[pc + 1]], op >= 0x60))
                        elif op in (0x1c, 0x1f, 0x20, 0x22, 0x23, 0x24, 0x25):
                            executable_types.add(ts[units[pc + 1]])
                            type_accesses.append((caller, ts[units[pc + 1]]))
                    assert pc + width <= count, ('Instruction exceeds code', entry, caller, pc)
                    pc += width
                tries = h(pos + 6)
                if tries:
                    cursor = pos + 16 + count * 2 + (2 if count & 1 else 0) + tries * 8
                    handlers, cursor = leb(cursor)
                    for _ in range(handlers):
                        raw, start = 0, cursor
                        shift = 0
                        while True:
                            byte = b[cursor]; cursor += 1
                            raw |= (byte & 127) << shift; shift += 7
                            if not byte & 128: break
                            assert shift < 35
                        size = raw - (1 << shift) if byte & 64 else raw
                        for _ in range(abs(size)):
                            index, cursor = leb(cursor)
                            _, cursor = leb(cursor)
                            type_accesses.append((caller, ts[index]))
                        if size <= 0: _, cursor = leb(cursor)

            for i in range(u(96)):
                pos = u(100) + 32 * i
                name, superclass = ts[u(pos)], u(pos + 8)
                parents = ([ts[superclass]] if superclass != 0xffffffff else []) + list(type_list(u(pos + 12)))
                annotation_directory(u(pos + 20))
                data, dm, df = u(pos + 24), {}, {}
                if data:
                    counts = []
                    for _ in range(4):
                        value, data = leb(data)
                        counts.append(value)
                    for group, count in enumerate(counts):
                        index = 0
                        for _ in range(count):
                            delta, data = leb(data)
                            index += delta
                            flags, data = leb(data)
                            if group < 2:
                                df[fs[index][1:]] = flags
                            else:
                                code, data = leb(data)
                                dm[ms[index][1:]] = flags
                                inspect_code(code, ms[index])
                assert name not in definitions, ('Duplicate class', name)
                definitions[name] = {'parents': parents, 'methods': dm, 'fields': df}
    return {'definitions': definitions, 'methods': methods, 'fields': fields, 'types': types,
            'accesses': accesses, 'typeAccesses': type_accesses, 'executableTypes': executable_types, 'annotations': annotations, 'dexFiles': dex_files}


class PlatformClasses:
    def __init__(self, path):
        self.jar = zipfile.ZipFile(path)
        self.loaded = set()

    def definition(self, name):
        try:
            b = self.jar.read(name[1:-1] + '.class')
        except KeyError:
            return None
        self.loaded.add(name)
        pos = 8

        def u2():
            nonlocal pos
            value = struct.unpack_from('>H', b, pos)[0]
            pos += 2
            return value

        def u4():
            nonlocal pos
            value = struct.unpack_from('>I', b, pos)[0]
            pos += 4
            return value

        count = u2()
        cp, index = [None] * count, 1
        while index < count:
            tag = b[pos]
            pos += 1
            if tag == 1:
                length = u2()
                cp[index] = b[pos:pos + length].decode('utf8', errors='replace')
                pos += length
            elif tag in (7, 8, 16, 19, 20):
                cp[index] = u2()
            elif tag in (3, 4):
                pos += 4
            elif tag in (5, 6):
                pos += 8
                index += 1
            elif tag in (9, 10, 11, 12, 17, 18):
                pos += 4
            elif tag == 15:
                pos += 3
            else:
                raise AssertionError(('Unknown constant-pool tag', tag))
            index += 1

        def classname(index): return 'L' + cp[cp[index]] + ';'

        u2()
        u2()
        superclass = u2()
        parents = ([classname(superclass)] if superclass else []) + [classname(u2()) for _ in range(u2())]
        members = []
        for _ in range(2):
            group = {}
            for _ in range(u2()):
                flags, name, descriptor = u2(), cp[u2()], cp[u2()]
                group[(name, descriptor)] = flags
                for _ in range(u2()):
                    u2()
                    length = u4()
                    pos += length
            members.append(group)
        return {'parents': parents, 'fields': members[0], 'methods': members[1]}


ROOTS = ('Lcom/minnnng/dsh_android/PtcSafAcceptanceProvider;',
         'Lcom/minnnng/dsh_android/PtcSafAcceptanceControlService;',
         'Lcom/minnnng/dsh_android/PtcSafBootstrapInstrumentation;')


def linkage(test, platform, roots=ROOTS):
    """Walk complete class dependencies, including initializers and D8/R8 synthetic helpers."""
    definitions = dict(test['definitions'])
    dependencies = {name: set(value['parents']) for name, value in definitions.items()}

    def descriptors(value):
        return re.findall(r'L[^;]+;', value)

    for name, definition in test['definitions'].items():
        for kind in ('fields', 'methods'):
            for _, descriptor in definition[kind]:
                dependencies[name].update(descriptors(descriptor))
    accesses = {}
    for caller, pc, kind, ref, static in test['accesses']:
        dependencies[caller[0]].update(descriptors(ref[0]) + descriptors(ref[2]))
        accesses.setdefault(caller[0], []).append((caller, pc, kind, ref, static))
    for caller, value in test['typeAccesses']:
        dependencies[caller[0]].update(descriptors(value))

    def definition(owner):
        if owner.startswith('['): owner = 'Ljava/lang/Object;'
        if owner not in definitions:
            found = platform.definition(owner)
            if found: definitions[owner] = found
        return definitions.get(owner)

    def resolve(owner, signature, kind, seen=None):
        seen = set() if seen is None else seen
        if owner in seen: return None
        seen.add(owner)
        found = definition(owner)
        if not found: return None
        if signature in found[kind]: return owner, found[kind][signature]
        if signature[0] != '<init>':
            for parent in found['parents']:
                value = resolve(parent, signature, kind, seen)
                if value: return value
        return None

    missing_roots = sorted(name for name in roots if name not in test['definitions'])
    queued, visited, missing, bad_accesses = list(roots), set(), set(), []
    while queued:
        owner = queued.pop()
        if owner in visited: continue
        visited.add(owner)
        if not definition(owner):
            missing.add(owner)
            continue
        if owner not in test['definitions']: continue
        queued.extend(dependencies[owner])
        for caller, pc, kind, ref, static in accesses.get(owner, []):
            found = resolve(ref[0], ref[1:], kind)
            if found is None or bool(found[1] & 8) != static:
                bad_accesses.append({'caller': caller, 'offset': pc, 'kind': kind, 'reference': ref,
                                     'expectedStatic': static, 'resolved': found})
    return {'passed': not (missing_roots or missing or bad_accesses), 'roots': roots,
            'reachableTestClasses': sorted(visited.intersection(test['definitions'])),
            'missingRoots': missing_roots, 'missingTypes': sorted(missing),
            'unresolvedOrWrongStaticAccesses': bad_accesses}


def audit(test_path, platform_path):
    platform = PlatformClasses(platform_path)
    try: result = linkage(apk_inventory(test_path), platform)
    finally: platform.jar.close()
    result.update({'test': fingerprint(test_path), 'androidPlatform': fingerprint(platform_path),
                   'scope': 'independent-test-uid', 'mainAppFallback': False,
                   'limitations': ['Static DEX linkage only; does not certify Binder delivery or Android execution.',
                                   'Reflection, JNI and dynamically loaded classes are not evaluated.',
                                   'SDK stubs cannot prove the installed device framework implementation.',
                                   'Unrecognized dynamic DEX instructions fail the audit.']})
    return result


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--test', type=Path, required=True)
    parser.add_argument('--platform', type=Path, required=True)
    parser.add_argument('--report', type=Path, required=True)
    args = parser.parse_args()
    result = audit(args.test, args.platform)
    result['auditScript'] = fingerprint(Path(__file__))
    with args.report.open('x', encoding='utf8') as stream:
        stream.write(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result, indent=2))
    raise SystemExit(0 if result['passed'] else 1)
