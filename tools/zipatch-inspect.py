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
  apply <file.patch> <game-dir>
      Apply every chunk in file order (F, A, D, E, H, ADIR, DELD); anything
      not described in docs/FFXIV_PATCHING.md stops the run.
  chain <saved-reply> <base|exN> <game-dir> [<stop-after-version>]
      For one repository of a reply saved by sqex-signin-probe.py
      --save-reply: download each patch (resuming), check its size and every
      block's SHA-1, apply it, delete it and write the version file. A run
      starts after the version already in the version file.

A research tool for checking the format against real files, not Madeira's
patcher. Big-endian unless noted.
"""
import collections
import hashlib
import os
import re
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


def dat_command(command, body):
    """(path, offset, bytes to write) of an SQPK A, D, E or H command."""
    if command == 'A':
        offset, count, delete = struct.unpack_from('>III', body, 0x0B)
        fill = bytes(body[0x17:0x17 + count * BLOCK])
        return sqpack_path(body, 3, 'D'), offset * BLOCK, fill + bytes(delete * BLOCK)
    if command in 'DE':
        offset, count = struct.unpack_from('>II', body, 0x0B)
        # The empty-block header holds count - 1 (confirmed for D against ex1, 2026-10-31).
        empty = struct.pack('<IIIII', BLOCK, 0, 0, count - 1, 0).ljust(count * BLOCK, b'\0')
        return sqpack_path(body, 3, 'D'), offset * BLOCK, empty
    file_kind, header_kind = chr(body[0]), chr(body[1])
    if file_kind not in 'DI' or header_kind not in 'VDI':
        raise SystemExit(f'H with unknown kinds {file_kind!r} {header_kind!r}')
    return sqpack_path(body, 3, file_kind), 0 if header_kind == 'V' else 1024, bytes(body[11:11 + 1024])


def dat_commands(data):
    """(command, path, offset, bytes to write) for each SQPK A, D, E and H command, in order."""
    for name, payload, _ in chunks(data):
        if name == 'SQPK' and chr(payload[4]) in 'ADEH':
            yield (chr(payload[4]),) + dat_command(chr(payload[4]), payload[5:])


def write_at(target, offset, fill, extend=True):
    """Write fill at offset, creating the file (and its folders) when it doesn't exist."""
    os.makedirs(os.path.dirname(target), exist_ok=True)
    exists = os.path.exists(target)
    if not extend and (not exists or offset + len(fill) > os.path.getsize(target)):
        raise SystemExit(f'write past the end of {target}')
    with open(target, 'r+b' if exists else 'w+b') as f:
        f.seek(offset)
        f.write(fill)


def apply_patch(path, game):
    """Apply every chunk of a patch to <game>, in file order. Anything this
    document hasn't confirmed or described stops the run rather than being guessed."""
    import mmap
    counts = collections.Counter()
    with open(path, 'rb') as f, mmap.mmap(f.fileno(), 0, access=mmap.ACCESS_READ) as data:
        for name, payload, crc_ok in chunks(data):
            if name is None or name == 'EOF_':
                break
            if not crc_ok:
                raise SystemExit(f'{path}: CRC32 mismatch in a {name} chunk')
            if name in ('FHDR', 'APLY'):
                pass
            elif name in ('ADIR', 'DELD'):
                length, = struct.unpack_from('>I', payload, 0)
                folder = os.path.join(game, *bytes(payload[4:4 + length]).split(b'\0')[0].decode().replace('\\', '/').split('/'))
                if name == 'ADIR':
                    os.makedirs(folder, exist_ok=True)
                elif os.path.isdir(folder) and not os.listdir(folder):
                    os.rmdir(folder)
            elif name == 'SQPK':
                command, body = chr(payload[4]), payload[5:]
                if command == 'F' and chr(body[0]) == 'R':
                    # First in a history patch, with an empty path and the expansion ID.
                    # What it removes is unconfirmed, so it is only accepted where it
                    # can't matter: a repository with no files yet.
                    expansion, = struct.unpack_from('>H', body, 0x17)
                    folder = 'ffxiv' if expansion == 0 else f'ex{expansion}'
                    present = [os.path.join(top, name) for part in ('sqpack', 'movie')
                               for top, _, names in os.walk(os.path.join(game, part, folder)) for name in names]
                    if present:
                        raise SystemExit(f'F R (reset?) for {folder}, which has {len(present)} files; unconfirmed, not applied')
                    command += 'R'
                elif command == 'F':
                    operation, offset, fpath, _, blocks = file_op(body)
                    target = os.path.join(game, *fpath.replace('\\', '/').split('/'))
                    if operation == 'A':
                        os.makedirs(os.path.dirname(target), exist_ok=True)
                        with open(target, 'r+b' if offset and os.path.exists(target) else 'wb') as out:
                            out.seek(offset)
                            for block in file_blocks(bytes(blocks)):
                                out.write(block)
                    elif operation == 'D':
                        if os.path.exists(target):
                            os.remove(target)
                    else:
                        raise SystemExit(f'unknown file operation {operation!r} for {fpath}')
                    command += operation
                elif command == 'E':
                    raise SystemExit('SQPK E (expand) is not confirmed yet; not applied')
                elif command in 'ADH':
                    fpath, offset, fill = dat_command(command, body)
                    write_at(os.path.join(game, 'sqpack', *fpath.split('/')), offset, fill, extend=command != 'D')
                elif command not in 'XTI':
                    raise SystemExit(f'unknown SQPK command {command!r}')
                counts[command] += 1
            else:
                raise SystemExit(f'unknown chunk {name!r}')
            counts[name] += 1
    return counts


VERSION = re.compile(r'\d{4}\.\d{2}\.\d{2}\.\d{4}\.\d{4}')


def patch_list(reply, repository):
    """The lines of a saved session-registration reply for one repository ('base' or 'exN')."""
    lines = []
    for line in open(reply, encoding='utf-8'):
        fields = line.rstrip('\r\n').split('\t')
        if len(fields) != 9:
            continue
        match = re.search(r'/game/(?:(ex\d+)/)?[0-9a-f]{8}/', fields[8])
        if match and (match.group(1) or 'base') == repository:
            lines.append(dict(size=int(fields[0]), version=fields[4], block=int(fields[6]),
                              hashes=fields[7].split(','), url=fields[8]))
    return lines


def download(entry, work):
    """Download one patch (resuming a partial file) and check its size and block hashes."""
    import urllib.request
    target = os.path.join(work, entry['url'].rsplit('/', 1)[1])
    have = os.path.getsize(target) if os.path.exists(target) else 0
    if have < entry['size']:
        request = urllib.request.Request(entry['url'], headers={'Range': f'bytes={have}-'} if have else {})
        with urllib.request.urlopen(request, timeout=60) as reply, open(target, 'ab' if have else 'wb') as out:
            if have and reply.status != 206:
                raise SystemExit(f'{entry["url"]}: no range support (HTTP {reply.status})')
            while chunk := reply.read(1 << 20):
                out.write(chunk)
    if os.path.getsize(target) != entry['size']:
        raise SystemExit(f'{target}: {os.path.getsize(target)} bytes, the list says {entry["size"]}')
    with open(target, 'rb') as f:
        for index, expected in enumerate(entry['hashes']):
            if hashlib.sha1(f.read(entry['block'])).hexdigest() != expected:
                os.remove(target)
                raise SystemExit(f'{target}: block {index} SHA-1 mismatch (file removed)')
        if f.read(1):
            raise SystemExit(f'{target}: longer than its {len(entry["hashes"])} blocks')
    return target


def chain(reply, repository, game, stop_after=None, work=None):
    """Download, check, apply and delete one repository's patches in list order,
    writing its version file after each patch that names a version."""
    import time
    ver = (os.path.join(game, 'ffxivgame.ver') if repository == 'base'
           else os.path.join(game, 'sqpack', repository, f'{repository}.ver'))
    entries = patch_list(reply, repository)
    if not entries:
        raise SystemExit(f'no {repository} patches in {reply}')
    current = open(ver).read().strip() if os.path.exists(ver) else None
    versions = [e['version'] for e in entries]
    start = versions.index(current) + 1 if current in versions else 0
    work = work or os.path.join(game, '.patches')
    os.makedirs(work, exist_ok=True)
    print(f'{repository}: {len(entries)} patches, at {current or "nothing"}, starting with #{start + 1}', flush=True)
    for number, entry in enumerate(entries[start:], start + 1):
        began = time.time()
        patch = download(entry, work)
        got = time.time()
        counts = apply_patch(patch, game)
        os.remove(patch)
        if VERSION.fullmatch(entry['version']):
            os.makedirs(os.path.dirname(ver), exist_ok=True)
            for name in (ver, ver[:-4] + '.bck'):   # the .bck file holds the same version
                with open(name, 'w') as f:
                    f.write(entry['version'])
        sqpk = {k: v for k, v in counts.items() if len(k) <= 2}
        print(f'  #{number} {entry["url"].rsplit("/", 1)[1]} ({entry["size"]:,} bytes): downloaded in '
              f'{got - began:.0f} s, applied in {time.time() - got:.0f} s; {sqpk}', flush=True)
        if stop_after and entry['version'] == stop_after:
            print(f'stopped after {stop_after}')
            return
    print(f'{repository} now at {open(ver).read().strip()}')



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
    elif len(sys.argv) == 4 and sys.argv[1] == 'apply':
        print(dict(apply_patch(*sys.argv[2:4])))
    elif len(sys.argv) in (5, 6) and sys.argv[1] == 'chain':
        chain(*sys.argv[2:6])
    else:
        raise SystemExit(__doc__)
