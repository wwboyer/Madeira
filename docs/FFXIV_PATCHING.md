# FINAL FANTASY XIV patching (research)

What Madeira needs to update an installed FINAL FANTASY XIV, and later to
install it, without Square Enix's launcher. This is research in progress: it
records only what has been confirmed first-hand or taken from the sources in
"Provenance". It builds on the sign-in in `docs/SQUARE_ENIX_SIGNIN.md`, whose
steps 2 and 6 return the patch lists. Mark anything unconfirmed as
**unknown**, and don't fill it in from other launchers' code.

## Status

| Piece | Status |
|---|---|
| Boot patch list (sign-in step 2) | confirmed |
| Boot patch download | confirmed |
| Game patch list (sign-in step 6, outdated game) | **next**: `tools/sqex-signin-probe.py --game-version … --save-reply …` |
| Game patch download | unknown |
| ZiPatch container, FHDR, APLY | confirmed |
| SQPK F (file) operations | confirmed: a boot patch rebuilt the installed boot files exactly |
| SQPK A, D, E, H (dat and index files) | from xiv.dev only; unconfirmed |
| Fresh install | unknown (what the servers offer for a base version) |

## Patch lists

- **Boot:** step 2's `200` reply is a `multipart/mixed` list. Each patch is
  one tab-separated line: size in bytes, three unknown fields, the target
  version, and the download URL. One patch can span many versions: a 2015
  boot version got a single patch straight to the current version.
- **Game:** when the game is outdated, step 6 replies without
  `X-Patch-Unique-Id`. What its body holds is unknown.

## Downloads

Boot patch URLs have the form
`http://patch-dl.ffxiv.com/boot/{repository}/{D|H}{version}.patch`.

- **Public:** no User-Agent or session needed.
- **Resumable:** `Accept-Ranges: bytes` is supported.
- **Size:** matches the list's size field and `X-Patch-Length`.
- **Plain HTTP:** HTTPS fails, because the host's certificate doesn't match it,
  so the app will need an App Transport Security exception for
  `patch-dl.ffxiv.com`.

Repository IDs, from the xiv.zone wiki:

| Repository | ID |
|---|---|
| Boot | `2b5cbc63` |
| Base game | `4e9a232b` |
| Heavensward (ex1) | `6b936f08` |
| Stormblood (ex2) | `f29a3eb2` |
| Shadowbringers (ex3) | `859d0e24` |
| Endwalker (ex4) | `1bf99b87` |
| Dawntrail (ex5) | `6cfeab11` |

## The ZiPatch format

Byte order is big-endian unless a field says otherwise.

- **File names:** `D` (delta) or `H` (history), then a version, `.patch`. A
  letter after the version marks a split file.
- **Signature:** the file starts with `91 5A 49 50 41 54 43 48 0D 0A 1A 0A`.
- **Chunks:** then a sequence of chunks, each one:
  - payload size (4 bytes)
  - a 4-character name
  - the payload
  - a CRC32 of the name and payload
- **End:** the sequence ends with a chunk named `EOF_`.

### Chunks

- **`FHDR`** comes first. In the boot patch observed, its payload was 20
  bytes, with the version byte (`2`) at offset 2 and `HIST` at offset 4, even
  though the file is a `D` patch. Its other fields are unknown.
- **`APLY`** chunks hold three 4-byte fields: option, reserved, value. Two
  follow `FHDR`: option 1 ("ignore missing") and option 2 ("ignore
  mismatch"), both with value `0`, meaning missing or mismatched data is an
  error.
- **`ADIR`** and **`DELD`** create or delete a folder. They aren't present
  in the boot patch.
- **`SQPK`** chunks start with a 4-byte size and a 1-byte command:

| Command | Meaning | Seen in boot patch |
|---|---|---|
| `F` | file operation | 48 |
| `T` | target info | 1 |
| `X` | patch info (unused) | 1 |
| `A`, `D`, `E` | add, delete or expand blocks in a `.dat` file | none |
| `H` | rewrite a `.dat` or `.index` header | none |
| `I` | index add/delete (unused) | none |

### F (file) operations

The header (27 bytes) holds:

| Offset | Size | Field |
|---|---|---|
| 0 | 1 | operation |
| 1 | 2 | (unused) |
| 3 | 8 | file offset |
| 11 | 8 | file size |
| 19 | 4 | path length |
| 23 | 2 | expansion |
| 25 | 2 | (unused) |

The path follows (null-terminated, relative to `boot/` or `game/`), and then
the blocks. Observed operations:

- `A` writes the blocks at the offset. Large files come in several
  chunks at increasing offsets.
- `D` deletes the file. The boot patch deletes the 32-bit
  `ffxivlauncher.exe`, `ffxivupdater.exe` and `ffxivconfig.exe`, which is
  why only four boot-hash files remain.

Each block has a 16-byte little-endian header: header size (16), unused,
compressed size and decompressed size. The data follows the header. A
compressed size of `32000` means the data is stored raw; otherwise it is raw
deflate. Each block, header included, is padded to a multiple of 128 bytes:
`(data length + 0x8F) & ~0x7F`.

## Tools

- **`tools/zipatch-inspect.py survey <patch>`** checks every chunk's CRC32
  and lists the chunks, SQPK commands and file operations.
- **`tools/zipatch-inspect.py apply-files <patch> <out> [<reference>]`**
  applies only the F operations, then compares each written file with the
  reference folder.
- **`tools/sqex-signin-probe.py`**:
  - `--boot-version`, `--game-version` and `--ex-version N=…` report other
    versions through a temporary install with links to the real boot
    programs, so the real game files are untouched.
  - `--save-reply` saves step 6's reply with the session ID redacted.

## Open questions

- What step 6 returns for an outdated game, and whether game patch downloads
  need a session.
- Whether the SQPK `A`, `D`, `E` and `H` commands behave as xiv.dev
  describes. One test without old data: applying the newest game patch to
  copies of already-patched files should change nothing.
- The remaining `FHDR` fields, and the `T` command.
- What the servers offer for a fresh install, and from which base version.

## Provenance

Written for Madeira with AI assistance (Claude) as an independent
implementation. Facts are restated in new wording, and no source's prose or
code is copied.

- **xiv.zone wiki** (CC BY-SA 4.0), "Patching" revision 203: URL patterns and
  repository IDs.
- **xiv.dev** (`github.com/xivdev/docs`, `content/data-files/zipatch/` at
  commit `6b33f21e833e`): the container and SQPK command layout. The
  repository has **no license**, so only facts are used. Its links, including
  XIVLauncher's patcher, were not followed.
- **First-hand:**
  - the boot patch list for an old boot version
  - `D2026.08.18.0000.0001.patch` downloaded and inspected with
    `zipatch-inspect.py`
  - that patch's F operations applied and compared with an installed boot
    folder of the same version

## Confirmation log (2026-10-30)

| Piece | Method | Finding |
|---|---|---|
| Downloads | `HEAD`/`GET` of the boot patch | public, resumable, size matches; HTTPS host mismatch |
| Container | `zipatch-inspect.py survey` | 54 chunks, all CRC32s valid, ends exactly at `EOF_`; FHDR 20 bytes, version 2, `HIST` |
| F operations | `zipatch-inspect.py apply-files` against the installed boot folder | 16 of 16 files byte-identical; the 3 deleted files are absent there too |
