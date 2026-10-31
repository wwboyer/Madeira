#!/usr/bin/env python3
"""Inspect FINAL FANTASY XIV patch files (ZiPatch, docs/FFXIV_PATCHING.md).

  survey <file.patch>
      Walk the chunks, check each CRC32, and list the chunk types, SQPK
      commands and file operations.
  apply-files <file.patch> <out-dir> [<reference-dir>]
      Apply only the SQPK F (file) operations into <out-dir>, then compare
      every written file with <reference-dir>, byte for byte.
  apply-sqpk <file.patch> <game-dir>
      Apply the SQPK A, D, E and H (dat and index) commands to the files
      in <game-dir>/sqpack, in place, and report which commands changed
      data. Run it on copies (APFS clones: cp -c), never the real game.

A research tool for checking the format against real files, not Madeira's
patcher. Big-endian unless noted.
"""
import collections
import hashlib
import os
import struct
import sys
import zlib

SIGNATURE = bytes.fromhex('915A4950415443480D0A1A0A')
UNCOMPRESSED = 32000   # a file block whose compressed size is this is stored raw


def chunks(data):
    """(name, payload, crc_ok) for each chunk, up to and including EOF_."""
    if data[:12] != SIGNATURE:
        raise SystemExit('not a ZiPatch file (signature)')
    pos = 12
    while pos < len(data):
        size, = struct.unpack_from('>I', data, pos)
        name = data[pos + 4:pos + 8]
        payload = data[pos + 8:pos + 8 + size]
        crc, = struct.unpack_from('>I', data, pos + 8 + size)
        yield name.decode('latin-1'), payload, zlib.crc32(name + payload) & 0xffffffff == crc
        pos += 8 + size + 4
        if name == b'EOF_':
            break
    yield None, pos, None


def file_op(body):
    """The operation, offset, path and blocks of an SQPK F command."""
    operation = chr(body[0])
    offset, _size, path_len = struct.unpack_from('>QQI', body, 3)
    expansion, = struct.unpack_from('>H', body, 0x17)
    path = body[0x1B:0x1B + path_len].split(b'\0')[0].decode('utf-8')
    return operation, offset, path, expansion, body[0x1B + path_len:]


def file_blocks(blocks):
    """The decompressed data of each block: a 16-byte header, then raw or deflated data, padded to 128 bytes."""
    pos = 0
    while pos + 16 <= len(blocks):
        header_size, _, compressed, decompressed = struct.unpack_from('<IIII', blocks, pos)
        if header_size != 16:
            return
        raw = compressed == UNCOMPRESSED
        length = decompressed if raw else compressed
        chunk = blocks[pos + 16:pos + 16 + length]
        data = chunk if raw else zlib.decompress(chunk, -15)
        if len(data) != decompressed:
            raise SystemExit(f'block at {pos}: {len(data)} bytes, header says {decompressed}')
        yield data
        pos += (length + 0x8F) & ~0x7F


def survey(path):
    data = open(path, 'rb').read()
    names, sqpk, ops, files = collections.Counter(), collections.Counter(), collections.Counter(), collections.Counter()
    bad_crc, end = 0, 0
    for name, payload, crc_ok in chunks(data):
        if name is None:
            end = payload
            break
        names[name] += 1
        bad_crc += not crc_ok
        if name == 'FHDR':
            print(f'FHDR ({len(payload)} bytes): version byte {payload[2]}, name {payload[4:8].decode("latin-1")}')
        elif name == 'APLY':
            print('APLY (option, reserved, value):', struct.unpack('>III', payload[:12]))
        elif name == 'SQPK':
            sqpk[chr(payload[4])] += 1
            if chr(payload[4]) == 'F':
                operation, _offset, fpath, expansion, _ = file_op(payload[5:])
                ops[operation] += 1
                files[(operation, fpath, expansion)] += 1
    print(f'{len(data)} bytes, chunks end at {end}; CRC32 mismatches: {bad_crc}')
    print('chunks:', dict(names))
    print('SQPK commands:', dict(sqpk))
    print('F operations:', dict(ops))
    for (operation, fpath, expansion), n in sorted(files.items()):
        print(f'  {operation} ex{expansion} x{n} {fpath}')


def apply_files(path, out, reference=None):
    data = open(path, 'rb').read()
    written, deleted, skipped = set(), set(), collections.Counter()
    for name, payload, _ in chunks(data):
        if name != 'SQPK':
            continue
        if chr(payload[4]) != 'F':
            skipped[chr(payload[4])] += 1
            continue
        operation, offset, fpath, _, blocks = file_op(payload[5:])
        target = os.path.join(out, *fpath.split('/'))
        if operation == 'D':
            if os.path.exists(target):
                os.remove(target)
            deleted.add(fpath)
            continue
        if operation != 'A':
            raise SystemExit(f'unknown file operation {operation!r} for {fpath}')
        os.makedirs(os.path.dirname(target), exist_ok=True)
        with open(target, 'r+b' if offset and os.path.exists(target) else 'wb') as f:
            f.seek(offset)
            for block in file_blocks(blocks):
                f.write(block)
        written.add(fpath)
    print(f'wrote {len(written)} files, deleted {len(deleted)}; skipped SQPK commands {dict(skipped)}')
    if not reference:
        return
    same = 0
    for fpath in sorted(written):
        mine, theirs = (os.path.join(base, *fpath.split('/')) for base in (out, reference))
        a = open(mine, 'rb').read()
        b = open(theirs, 'rb').read() if os.path.exists(theirs) else None
        same += a == b
        state = 'same' if a == b else 'MISSING from reference' if b is None else 'DIFFERENT'
        print(f'  {state} {fpath} ({len(a)} bytes, sha1 {hashlib.sha1(a).hexdigest()[:12]})')
    for fpath in sorted(deleted):
        absent = not os.path.exists(os.path.join(reference, *fpath.split('/')))
        print(f'  deleted {fpath}: {"absent from reference too" if absent else "PRESENT in reference"}')
    print(f'{same} of {len(written)} written files identical to the reference')


BLOCK = 128   # dat offsets and counts are in 128-byte blocks


def sqpack_path(body, offset, kind):
    """The sqpack-relative path of the dat ('D') or index ('I') file named at body[offset:offset + 8]."""
    main, sub, number = struct.unpack_from('>HHI', body, offset)
    folder = 'ffxiv' if sub >> 8 == 0 else f'ex{sub >> 8}'
    suffix = f'dat{number}' if kind == 'D' else 'index' + (str(number) if number else '')
    return f'{folder}/{main:02x}{sub:04x}.win32.{suffix}'


def dat_commands(data):
    """(command, path, offset, bytes to write) for each SQPK A, D, E and H command, in order."""
    for name, payload, _ in chunks(data):
        if name != 'SQPK':
            continue
        command, body = chr(payload[4]), payload[5:]
        if command == 'A':
            offset, count, delete = struct.unpack_from('>III', body, 0x0B)
            fill = body[0x17:0x17 + count * BLOCK]
            yield 'A', sqpack_path(body, 3, 'D'), offset * BLOCK, fill + bytes(delete * BLOCK)
        elif command in 'DE':
            offset, count = struct.unpack_from('>II', body, 0x0B)
            empty = struct.pack('<IIIII', BLOCK, 0, 0, count, 0).ljust(count * BLOCK, b'\0')
            yield command, sqpack_path(body, 3, 'D'), offset * BLOCK, empty
        elif command == 'H':
            file_kind, header_kind = chr(body[0]), chr(body[1])
            yield 'H', sqpack_path(body, 3, file_kind), 0 if header_kind == 'V' else 1024, body[11:11 + 1024]


def apply_sqpk(path, game):
    """Apply the dat and index commands to <game>/sqpack and report what changed."""
    data = open(path, 'rb').read()
    changed, counts = collections.Counter(), collections.Counter()
    for command, fpath, offset, fill in dat_commands(data):
        target = os.path.join(game, 'sqpack', *fpath.split('/'))
        size = os.path.getsize(target)
        if command == 'D' and offset + len(fill) > size:
            raise SystemExit(f'D past the end of {fpath} ({offset} + {len(fill)} > {size})')
        with open(target, 'r+b') as f:
            f.seek(offset)
            before = f.read(len(fill))
            f.seek(offset)
            f.write(fill)
        counts[command] += 1
        if before != fill:
            changed[fpath] += 1
            print(f'  {command} {fpath} at {offset}: {len(fill)} bytes, CHANGED'
                  f' ({sum(a != b for a, b in zip(before, fill)) + abs(len(fill) - len(before))} bytes differ)')
        else:
            print(f'  {command} {fpath} at {offset}: {len(fill)} bytes, unchanged')
    print(f'applied {dict(counts)}; commands that changed data: {sum(changed.values())}')


if __name__ == '__main__':
    if len(sys.argv) >= 3 and sys.argv[1] == 'survey':
        survey(sys.argv[2])
    elif len(sys.argv) >= 4 and sys.argv[1] == 'apply-files':
        apply_files(*sys.argv[2:5])
    elif len(sys.argv) == 4 and sys.argv[1] == 'apply-sqpk':
        apply_sqpk(*sys.argv[2:4])
    else:
        raise SystemExit(__doc__)
