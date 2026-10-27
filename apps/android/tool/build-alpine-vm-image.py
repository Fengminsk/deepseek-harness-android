"""Build a verified ext2 guest from a pinned official Alpine minirootfs on Windows.

No archive links are created on the host. mke2fs creates an empty filesystem;
this module writes bounded file data, inodes, bitmaps and directory entries. This is an
offline artifact builder, never a mount tool or an Android runtime entry point.
"""
import argparse
import hashlib
import json
import math
import mmap
import os
from pathlib import Path, PurePosixPath
import shutil
import stat
import struct
import subprocess
import tarfile
import tempfile

REPOSITORY = Path(__file__).resolve().parents[3]
CACHE = REPOSITORY / '.cache/android/tinyemu-probe'
ALPINE_SHA256 = '50043f35362c3b7507a94814f2373948485e6d577a39f61833f2c37c0760458a'
ALPINE_NAME = 'alpine-minirootfs-3.22.7-riscv64.tar.gz'
ALPINE_URL = 'https://dl-cdn.alpinelinux.org/alpine/v3.22/releases/riscv64/' + ALPINE_NAME
INITTAB = b'''::sysinit:/bin/mount -t proc proc /proc
::sysinit:/bin/mount -t sysfs sysfs /sys
::sysinit:/bin/mkdir -p /workspace
::sysinit:/bin/echo DSH_LINUX_READY
hvc0::respawn:/bin/sh -l
::shutdown:/bin/sync
'''


def digest(data):
    return hashlib.sha256(data).hexdigest()


def member_path(raw):
    if raw.startswith('/') or '\\' in raw or '\0' in raw or ':' in raw:
        raise ValueError('Unsafe archive path')
    parts = raw.split('/')
    if '..' in parts:
        raise ValueError('Archive path traversal')
    name = '/'.join(p for p in parts if p and p != '.')
    for part in name.split('/'):
        if part.endswith((' ', '.')) or part.upper().split('.')[0] in {
            'CON', 'PRN', 'AUX', 'NUL', *('COM%d' % n for n in range(1, 10)),
            *('LPT%d' % n for n in range(1, 10)),
        }:
            raise ValueError('Unsafe host staging name')
    return name


def read_archive(archive, expected_sha256):
    """Parse, hash and validate without extracting or following any link."""
    if digest(Path(archive).read_bytes()) != expected_sha256:
        raise ValueError('Pinned Alpine archive SHA256 differs')
    entries, folded = {}, set()
    with tarfile.open(archive, 'r:gz') as source:
        for item in source:
            name = member_path(item.name)
            if name in entries or name.casefold() in folded:
                raise ValueError('Duplicate or host-case-colliding archive path')
            folded.add(name.casefold())
            if item.isdir():
                kind, data = 'directory', b''
            elif item.isreg():
                if item.size > 64 * 1024 * 1024:
                    raise ValueError('Oversized input file')
                kind, data = 'file', source.extractfile(item).read()
                if len(data) != item.size:
                    raise ValueError('Truncated archive file')
            elif item.issym():
                kind, data = 'symlink', item.linkname.encode('utf-8')
                if not data or b'\0' in data or len(data) > 4095:
                    raise ValueError('Invalid guest symlink')
            else:
                raise ValueError('Unsupported archive node (including hardlink)')
            if not name and kind != 'directory':
                raise ValueError('Archive root must be a directory')
            if not 0 <= item.uid <= 0xFFFFFFFF or not 0 <= item.gid <= 0xFFFFFFFF:
                raise ValueError('Invalid ownership')
            entries[name] = dict(kind=kind, data=data, mode=item.mode & 0o7777,
                                 uid=item.uid, gid=item.gid, mtime=int(item.mtime))
    for name in entries:
        for parent in PurePosixPath(name).parents:
            key = '' if str(parent) == '.' else str(parent)
            if key in entries and entries[key]['kind'] != 'directory':
                raise ValueError('Archive node is nested under a non-directory')
    return entries


class Ext2Image:
    """Small bounded ext2 reader/editor for our mke2fs output, without host mounts."""
    def __init__(self, data):
        self.data = data
        if self.u16(1080) != 0xEF53:
            raise ValueError('Not ext2')
        self.block_size = 1024 << self.u32(1048)
        self.block_count = self.u32(1028)
        self.inodes_per_group = self.u32(1064)
        self.inode_size = self.u16(1112)
        self.blocks_per_group = self.u32(1056)
        if self.block_size != 4096 or self.inode_size != 256:
            raise ValueError('Unexpected filesystem geometry')
        if self.u32(1120) != 2 or self.u32(1116) != 0 or self.u32(1124) & ~3:
            raise ValueError('Unsupported ext2 features')
        if self.block_count * self.block_size != len(data):
            raise ValueError('Truncated image')
        self.descriptors = self.block_size

    def u16(self, offset):
        return struct.unpack_from('<H', self.data, offset)[0]

    def u32(self, offset):
        return struct.unpack_from('<I', self.data, offset)[0]

    def p16(self, offset, value):
        struct.pack_into('<H', self.data, offset, value)

    def p32(self, offset, value):
        struct.pack_into('<I', self.data, offset, value)

    def inode(self, number):
        if number < 1 or number > self.u32(1024):
            raise ValueError('Invalid inode')
        group, index = divmod(number - 1, self.inodes_per_group)
        table = self.u32(self.descriptors + group * 32 + 8)
        offset = self.block(table) + index * self.inode_size
        if offset + self.inode_size > len(self.data):
            raise ValueError('Inode outside image')
        return offset

    def block(self, number):
        if not 0 < number < self.block_count:
            raise ValueError('Block outside image')
        return number * self.block_size

    def size(self, inode):
        size = self.u32(inode + 4)
        if stat.S_ISREG(self.u16(inode)):
            size |= self.u32(inode + 108) << 32
        if size > 128 * 1024 * 1024:
            raise ValueError('Oversized inode')
        return size

    def data_blocks(self, inode):
        remaining = math.ceil(self.size(inode) / self.block_size)
        pointers = struct.unpack_from('<15I', self.data, inode + 40)
        def indirect(pointer, depth):
            if depth == 0:
                yield pointer
            elif pointer == 0:
                yield from (0 for _ in range((self.block_size // 4) ** depth))
            else:
                values = struct.unpack_from('<%dI' % (self.block_size // 4), self.data, self.block(pointer))
                for value in values:
                    yield from indirect(value, depth - 1)
        for pointer, depth in [*((p, 0) for p in pointers[:12]), (pointers[12], 1),
                               (pointers[13], 2), (pointers[14], 3)]:
            if remaining <= 0:
                break
            for block in indirect(pointer, depth):
                if remaining <= 0:
                    return
                yield block
                remaining -= 1

    def read(self, inode):
        size = self.size(inode)
        if stat.S_ISLNK(self.u16(inode)) and self.u32(inode + 28) == 0:
            if size > 60:
                raise ValueError('Invalid fast symlink')
            return bytes(self.data[inode + 40:inode + 40 + size])
        result = bytearray()
        for number in self.data_blocks(inode):
            if number:
                start = self.block(number)
                result.extend(self.data[start:start + self.block_size])
            else:
                result.extend(bytes(self.block_size))
        if len(result) < size:
            raise ValueError('Incomplete file block chain')
        return bytes(result[:size])

    def paths(self):
        found, directories = {'': (2, None)}, set()
        def walk(prefix, number):
            if number in directories:
                raise ValueError('Directory cycle or alias')
            directories.add(number)
            inode = self.inode(number)
            if not stat.S_ISDIR(self.u16(inode)):
                raise ValueError('Expected directory inode')
            for block in self.data_blocks(inode):
                start, relative = self.block(block), 0
                while relative < self.block_size:
                    at = start + relative
                    child, length, name_length = self.u32(at), self.u16(at + 4), self.data[at + 6]
                    if length < 8 or length % 4 or relative + length > self.block_size or name_length > length - 8:
                        raise ValueError('Invalid directory entry')
                    name = bytes(self.data[at + 8:at + 8 + name_length]).decode('utf-8')
                    relative += length
                    if not child or name in ('.', '..'):
                        continue
                    if '/' in name or not name:
                        raise ValueError('Invalid directory name')
                    path = f'{prefix}/{name}' if prefix else name
                    if path in found:
                        raise ValueError('Duplicate filesystem path')
                    found[path] = (child, at + 7)
                    if stat.S_ISDIR(self.u16(self.inode(child))):
                        walk(path, child)
        walk('', 2)
        return found

    def apply_metadata(self, entries):
        paths = self.paths()
        for name, entry in entries.items():
            number, dir_type = paths[name]
            inode = self.inode(number)
            kind = entry['kind']
            mode = {'directory': stat.S_IFDIR, 'file': stat.S_IFREG, 'symlink': stat.S_IFLNK}[kind]
            self.p16(inode, mode | entry['mode'])
            self.p16(inode + 2, entry['uid'] & 0xFFFF)
            self.p16(inode + 120, entry['uid'] >> 16)
            self.p16(inode + 24, entry['gid'] & 0xFFFF)
            self.p16(inode + 122, entry['gid'] >> 16)
            for offset in (8, 12, 16):
                self.p32(inode + offset, entry['mtime'] & 0xFFFFFFFF)
            if dir_type is not None:
                self.data[dir_type] = {'directory': 2, 'file': 1, 'symlink': 7}[kind]
            # For a slow symlink, the original data blocks and i_blocks must stay.
            if kind == 'symlink':
                self.p32(inode + 108, 0)
        return self.verify(entries)

    def verify(self, entries):
        paths = self.paths()
        hashes = []
        for name, entry in entries.items():
            number, dir_type = paths[name]
            inode = self.inode(number)
            mode = {'directory': stat.S_IFDIR, 'file': stat.S_IFREG, 'symlink': stat.S_IFLNK}[entry['kind']]
            uid = self.u16(inode + 2) | self.u16(inode + 120) << 16
            gid = self.u16(inode + 24) | self.u16(inode + 122) << 16
            if self.u16(inode) != mode | entry['mode'] or uid != entry['uid'] or gid != entry['gid']:
                raise ValueError('Guest inode metadata differs: ' + name)
            if dir_type is not None and self.data[dir_type] != {'directory': 2, 'file': 1, 'symlink': 7}[entry['kind']]:
                raise ValueError('Guest directory type differs: ' + name)
            if entry['kind'] != 'directory' and self.read(inode) != entry['data']:
                raise ValueError('Guest file/link content differs: ' + name)
            hashes.append(dict(path=name, kind=entry['kind'], mode=oct(entry['mode']), uid=uid, gid=gid,
                               sha256=digest(entry['data']) if entry['kind'] != 'directory' else None))
        extras = set(paths) - set(entries) - {'lost+found'}
        if extras:
            raise ValueError('Unexpected guest paths: ' + repr(extras))
        self.verify_allocation()
        return hashes

    def verify_allocation(self):
        """Check superblock/group free counters against allocation bitmaps."""
        if self.block_count != self.blocks_per_group:
            raise ValueError('Builder requires a single ext2 block group')
        group = self.descriptors
        block_bitmap = self.block(self.u32(group))
        inode_bitmap = self.block(self.u32(group + 4))
        def free_bits(offset, count):
            return sum(not (self.data[offset + index // 8] & (1 << (index % 8))) for index in range(count))
        free_blocks = free_bits(block_bitmap, self.block_count)
        free_inodes = free_bits(inode_bitmap, self.u32(1024))
        if free_blocks != self.u32(1036) or free_blocks != self.u16(group + 12):
            raise ValueError('Block allocation counters differ')
        if free_inodes != self.u32(1040) or free_inodes != self.u16(group + 14):
            raise ValueError('Inode allocation counters differ')

    def populate(self, entries):
        """Populate only a new one-group filesystem; no host symlink extraction."""
        self.verify_allocation()
        paths = self.paths()
        if set(paths) != {'', 'lost+found'} or 'lost+found' in entries:
            raise ValueError('Expected a fresh mke2fs image')
        group = self.descriptors
        block_bitmap = self.block(self.u32(group))
        inode_bitmap = self.block(self.u32(group + 4))
        next_block, next_inode = 1, 11
        def allocate(bitmap, count, first, counter_super, counter_group):
            for index in range(first, count):
                byte, mask = bitmap + index // 8, 1 << (index % 8)
                if not self.data[byte] & mask:
                    self.data[byte] |= mask
                    self.p32(counter_super, self.u32(counter_super) - 1)
                    self.p16(counter_group, self.u16(counter_group) - 1)
                    return index
            raise ValueError('Guest filesystem is full')
        def alloc_block():
            nonlocal next_block
            value = allocate(block_bitmap, self.block_count, next_block, 1036, group + 12)
            next_block = value + 1
            at = self.block(value)
            self.data[at:at + self.block_size] = bytes(self.block_size)
            return value
        def alloc_inode():
            nonlocal next_inode
            value = allocate(inode_bitmap, self.u32(1024), next_inode, 1040, group + 14)
            next_inode = value + 1
            return value + 1
        numbers = {'': 2, 'lost+found': paths['lost+found'][0]}
        for name in sorted(entries):
            if name:
                numbers[name] = alloc_inode()
                if entries[name]['kind'] == 'directory':
                    self.p16(group + 16, self.u16(group + 16) + 1)
        children = {name: [] for name, entry in entries.items() if entry['kind'] == 'directory'}
        children[''].append(('lost+found', numbers['lost+found'], 2))
        for name, entry in entries.items():
            if name:
                parent = str(PurePosixPath(name).parent)
                parent = '' if parent == '.' else parent
                if parent not in children:
                    raise ValueError('Missing archive parent directory: ' + name)
                children[parent].append((PurePosixPath(name).name, numbers[name],
                                         {'directory': 2, 'file': 1, 'symlink': 7}[entry['kind']]))
        old_root_blocks = list(self.data_blocks(self.inode(2)))
        for block in old_root_blocks:
            byte, mask = block_bitmap + block // 8, 1 << (block % 8)
            self.data[byte] &= ~mask
            self.p32(1036, self.u32(1036) + 1)
            self.p16(group + 12, self.u16(group + 12) + 1)
        next_block = 1
        def directory_data(name):
            parent = str(PurePosixPath(name).parent)
            parent = '' if parent == '.' else parent
            rows = [('.', numbers[name], 2), ('..', numbers[parent], 2)] + sorted(children[name])
            blocks, current, previous = [], bytearray(self.block_size), None
            position = 0
            for title, number, kind in rows:
                encoded = title.encode('utf-8')
                if len(encoded) > 255:
                    raise ValueError('Directory name exceeds ext2 limit')
                length = (8 + len(encoded) + 3) & ~3
                if position + length > self.block_size:
                    struct.pack_into('<H', current, previous + 4, self.block_size - previous)
                    blocks.append(current)
                    current, position = bytearray(self.block_size), 0
                struct.pack_into('<IHBB', current, position, number, length, len(encoded), kind)
                current[position + 8:position + 8 + len(encoded)] = encoded
                previous, position = position, position + length
            struct.pack_into('<H', current, previous + 4, self.block_size - previous)
            blocks.append(current)
            return b''.join(blocks)
        for name in sorted(entries):
            entry, inode = entries[name], self.inode(numbers[name])
            self.data[inode:inode + self.inode_size] = bytes(self.inode_size)
            kind = entry['kind']
            content = directory_data(name) if kind == 'directory' else entry['data']
            blocks = []
            for at in range(0, len(content), self.block_size):
                block = alloc_block()
                blocks.append(block)
                chunk = content[at:at + self.block_size]
                offset = self.block(block)
                self.data[offset:offset + len(chunk)] = chunk
            allocated = len(blocks)
            pointers = blocks[:12]
            remaining = blocks[12:]
            def pointer_tree(values, depth):
                nonlocal allocated
                block = alloc_block()
                allocated += 1
                if depth == 1:
                    values_to_write = values
                else:
                    stride = (self.block_size // 4) ** (depth - 1)
                    values_to_write = [pointer_tree(values[at:at + stride], depth - 1)
                                       for at in range(0, len(values), stride)]
                struct.pack_into('<%dI' % len(values_to_write), self.data, self.block(block), *values_to_write)
                return block
            pointers.extend([0] * (12 - len(pointers)))
            for depth in (1, 2, 3):
                capacity = (self.block_size // 4) ** depth
                chunk, remaining = remaining[:capacity], remaining[capacity:]
                pointers.append(pointer_tree(chunk, depth) if chunk else 0)
            if remaining:
                raise ValueError('File exceeds ext2 pointer capacity')
            struct.pack_into('<15I', self.data, inode + 40, *pointers)
            self.p32(inode + 4, len(content))
            self.p32(inode + 28, allocated * (self.block_size // 512))
            self.p16(inode + 26, 2 + sum(row[2] == 2 for row in children[name]) if kind == 'directory' else 1)
            self.p16(inode, {'directory': stat.S_IFDIR, 'file': stat.S_IFREG, 'symlink': stat.S_IFLNK}[kind])
        return self.apply_metadata(entries)


def populate_staging(entries, staging):
    for name, entry in sorted(entries.items(), key=lambda pair: (pair[0].count('/'), pair[0])):
        target = staging / name
        if entry['kind'] == 'directory':
            target.mkdir(exist_ok=True)
        else:
            target.parent.mkdir(parents=True, exist_ok=True)
            with target.open('xb') as output:
                output.write(entry['data'])


def build(archive, output, mke2fs):
    archive, output = Path(archive).resolve(), Path(output).resolve()
    if not output.is_relative_to(CACHE.resolve()) or output.suffix != '.ext2' or output.exists():
        raise ValueError('Output must be a new .ext2 file under the dedicated VM cache')
    entries = read_archive(archive, ALPINE_SHA256)
    entries['etc/inittab'] = dict(kind='file', data=INITTAB, mode=0o644, uid=0, gid=0, mtime=0)
    entries['workspace'] = dict(kind='directory', data=b'', mode=0o700, uid=0, gid=0, mtime=0)
    output.parent.mkdir(parents=True, exist_ok=True)
    temporary = output.with_name(output.name + '.building')
    if temporary.exists():
        raise ValueError('Build temporary path already exists')
    try:
        command = [str(mke2fs), '-F', '-t', 'ext2', '-b', '4096', '-I', '256', '-m', '0',
                   '-N', '8192', '-O', 'none,filetype,sparse_super,large_file',
                   '-E', 'lazy_itable_init=0', '-U', '46f7b395-c1b2-4c27-a9c5-24101ff00a01',
                   temporary.as_posix(), '32768']
        process = subprocess.run(command, capture_output=True, text=True, encoding='utf-8', errors='replace')
        if process.returncode:
            raise RuntimeError('mke2fs failed: ' + process.stdout + process.stderr)
        with temporary.open('r+b') as handle, mmap.mmap(handle.fileno(), 0) as data:
            verified = Ext2Image(data).populate(entries)
            data.flush()
        # Reopen the image so verification is independent of a buffered patch.
        with temporary.open('rb') as handle, mmap.mmap(handle.fileno(), 0, access=mmap.ACCESS_READ) as data:
            Ext2Image(data).verify(entries)
            image_hash = digest(data)
        if output.exists():
            raise ValueError('Output appeared during build')
        temporary.rename(output)
        manifest = dict(schema=1, image=str(output), imageSha256=image_hash, imageBytes=output.stat().st_size,
                        source=dict(url=ALPINE_URL, sha256=ALPINE_SHA256),
                        builderSha256=digest(Path(__file__).read_bytes()),
                        mke2fsSha256=digest(Path(mke2fs).read_bytes()), command=command,
                        commandLine='console=hvc0 root=/dev/vda rw',
                        modifications=['/etc/inittab: hvc0 BusyBox shell, no OpenRC', '/workspace: private working directory'],
                        verified=verified, verifiedCount=len(verified))
        output.with_suffix('.manifest.json').write_text(json.dumps(manifest, indent=2) + '\n', encoding='utf-8')
        return manifest
    finally:
        pass  # Failed artifacts stay under the dedicated cache for diagnosis.


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--archive', type=Path, default=CACHE / ALPINE_NAME)
    parser.add_argument('--output', type=Path, default=CACHE / 'alpine-3.22.7-riscv64-verified.ext2')
    parser.add_argument('--mke2fs', type=Path, default=Path('D:/Programs/adb/mke2fs.exe'))
    args = parser.parse_args()
    result = build(args.archive, args.output, args.mke2fs)
    print(json.dumps({key: result[key] for key in ('image', 'imageSha256', 'imageBytes', 'verifiedCount')}))
