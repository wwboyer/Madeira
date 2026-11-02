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
| Game patch list (sign-in step 6, outdated game) | confirmed: format, hashes and the full fresh-install list (2026-10-31) |
| Game patch download | confirmed: public, same host; one SHA-1 per 50,000,000-byte block, from the list |
| ZiPatch container, FHDR, APLY | confirmed |
| SQPK F (file) operations | confirmed: a boot patch rebuilt the installed boot files exactly |
| SQPK A and H (dat and index files) | confirmed: reapplying ex1's newest patch to its patched dats changed nothing |
| SQPK D | confirmed, with a correction to xiv.dev: the empty-block header holds count − 1 |
| SQPK E | not seen in a patch yet; the applier refuses it |
| Whole chain (history patches to current) | confirmed: ex1 rebuilt from nothing is byte-identical to an installed copy |
| Fresh install | confirmed: 204 patches, 152.15 GB to download, 130.30 GB installed |

## Patch lists

- **Boot:** step 2's `200` reply is a `multipart/mixed` list. Each patch is
  one tab-separated line: size in bytes, three unknown fields, the target
  version, and the download URL. One patch can span many versions: a 2015
  boot version got a single patch straight to the current version.
- **Game:** a current game gets `204` with the session ID (iPhone,
  2026-10-31). When the game is outdated, step 6 replies `200` with a
  `multipart/mixed` list, **and with an `X-Patch-Unique-Id`**, so the header
  alone does not mean the game may start. See "Game patch lists" below.

### Game patch lists

Recorded with `tools/sqex-signin-probe.py --save-reply` on 2026-10-31,
reporting game version `2012.01.01.0000.0000` (the fresh-install state).

- **Headers:** `X-Latest-Version` echoes the version reported, not the newest
  one. `Content-Location` is `ffxivpatch/4e9a232b/vercheck.dat`.
- **One section for all repositories:** a single multipart part,
  `Content-Location: ffxivpatch/4e9a232b/metainfo/2012.01.01.0000.0000.http`,
  holds every repository's patches: base game first, then ex1 to ex5. Its
  `X-Patch-Length` (80,770,799,852) is the base game's total only.
- **Expansions:** listed only for the expansion folders reported. With no
  `sqpack/exN/exN.ver` at all, only the base game came back (108 patches).
  With all five reported at `2012.01.01.0000.0000`, all six repositories came
  back in the one reply (204 patches).

Each patch is one line of nine tab-separated fields:

| # | Example | Meaning |
|---|---|---|
| 1 | `20502177` | patch size in bytes |
| 2 | `69117345196` | the repository's installed size after this patch |
| 3 | `75` | the repository's file count after this patch |
| 4 | `11` | **unknown**: 11 for the base game, 4 for each expansion (2 for ex5's first patch); possibly a folder count |
| 5 | `2026.10.16.0000.0000` | the version after this patch; for a part of a split patch other than the last, the part's name (`H2024.05.31.0000.0000a`) |
| 6 | `sha1` | hash type |
| 7 | `50000000` | hash block size |
| 8 | `3bb5…,86a6…` | one hash per block, comma-separated: exactly ceil(size / block size) of them for all 204 patches |
| 9 | `http://patch-dl.ffxiv.com/game/…` | download URL |

Fields 2 and 3 were checked against the installed game at the newest
versions. They count every file of the repository under `game/sqpack/{ffxiv |
exN}` and `game/movie/{ffxiv | exN}` (the base game also counts the files
directly in `game/`), but not the 20-byte `.ver` and `.bck` files. All six
matched exactly. Field 2 is what a disk-space check needs.

### The fresh-install chain

| Repository | Patches | Starts with | Ends at | Download | Installed |
|---|---|---|---|---|---|
| Base game | 108 | `H2024.05.31.0000.0000a` to `ah` (34 parts) | `2026.10.16.0000.0000` | 80.77 GB | 69.12 GB |
| ex1 | 13 | `H2024.05.31.0000.0000a` to `e` | `2026.08.20.0000.0000` | 9.21 GB | 7.35 GB |
| ex2 | 13 | `H2024.05.31.0000.0000a` to `f` | `2026.07.06.0000.0000` | 11.54 GB | 9.84 GB |
| ex3 | 18 | `H2024.05.31.0000.0000a` to `h` | `2026.10.16.0000.0000` | 13.51 GB | 11.76 GB |
| ex4 | 18 | `H2024.05.31.0000.0000a` to `j` | `2026.10.16.0000.0000` | 16.85 GB | 15.43 GB |
| ex5 | 34 | `D2024.05.20.0000.0000`, then `D2024.05.25.0000.0000` to `.0004.0000` | `2026.10.16.0000.0000` | 20.26 GB | 16.81 GB |
| **Total** | **204** | | | **152.15 GB** | **130.30 GB** |

- **History patches** (`H`) rebuild a repository from nothing up to
  `2024.05.31.0000.0000`. ex5 has none; its first patch (387 MB, 2 files)
  is a `D` patch.
- **Splits:** no part is over 1.5 GB (at most 30 hashes). `H` parts take a
  letter suffix (`a` to `z`, then `aa`, `ab`, …). Split `D` patches step the
  third version group instead (`2024.10.25.0000.0000`, `.0001.0000`, …), and
  each part's field 5 is its own name.
- **Version files:** each repository also has a `.bck` file beside its
  `.ver` (`ffxivgame.bck`, `exN.bck`), holding the same version.
- **Disk:** applying each patch and deleting it before the next needs at
  least the installed size plus 1.5 GB (an estimate: it assumes no patch
  grows the files beyond their final size along the way).

## Downloads

Patch URLs have these forms:

- boot: `http://patch-dl.ffxiv.com/boot/{repository}/{D|H}{version}.patch`
- base game: `http://patch-dl.ffxiv.com/game/{repository}/{D|H}{version}.patch`
- expansion N: `http://patch-dl.ffxiv.com/game/ex{N}/{repository}/{D|H}{version}.patch`

The game forms were confirmed with `HEAD` and `GET` on 2026-10-30 for the
newest patch of the base game, ex1 and ex5. They apply to all of them:

- **Public:** no User-Agent or session needed, game patches included.
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

## Fresh install (official Mac app)

Square Enix's Mac app (1.1.11, `com.square-enix.finalfantasyxiv`) is a
CrossOver wrapper. It has no native installer: its bottle template ships a
starting installation, and the Windows boot programs inside Wine download
the rest. The template's
`drive_c/Program Files (x86)/SquareEnix/FINAL FANTASY XIV - A Realm Reborn` holds:

- **`boot/`**: version `2018.12.14.0000.0001` (`ffxivboot.ver` and
  `ffxivboot.bck` both hold it), the boot programs including the 32-bit ones
  the current boot patch deletes, CEF, and a 390 MB `cache_ffxiv_dx11.exe.bin`.
- **`game/`**: only `ffxivgame.ver` = `2012.01.01.0000.0000` and the four
  opening movies (`movie/ffxiv/00000.bk2` to `00003.bk2`, 1.38 GB). There is
  no `sqpack/` and no `ffxiv_dx11.exe`.

The boot check for `2018.12.14.0000.0001` lists one patch,
`D2026.08.18.0000.0001`, the boot patch whose F operations rebuild the
current boot folder exactly (see the confirmation log). So the boot side of a
fresh install is known.

So a fresh install is a game folder that reports `2012.01.01.0000.0000`.
Everything else, the executable included, comes from patches. Whether
expansions are requested in the same session registration or a later one is
**unknown**. In the one observed install (2026-10-29) the base game finished
before ex1, and ex1 to ex5 then finished in order, 5 to 10 minutes apart.

### The launcher's download records

The launcher keeps one record per repository in
`%LOCALAPPDATA%\Temp\SquareEnix\FINAL FANTASY XIV Online\downloads\ffxivpatch\{repository}\patch\{patch}.patch.info`.
After the install only the record of each repository's last patch remained,
and the `.patch` files themselves were gone. Each record is 5,200 bytes,
little-endian:

| Offset | Size | Value seen | Meaning |
|---|---|---|---|
| 0x00 | 8 | 1 | format version (assumed) |
| 0x08 | 8 | 5200 | record size |
| 0x10 | 8 | 50,000,000 | hash block size (inferred) |
| 0x18 | 8 | 1 | number of blocks |
| 0x20 | 8 | the patch's size | patch size |
| 0x28 | 8 | 0 | unknown |
| 0x30 | 8 | 1 | blocks done (assumed) |
| 0x38 | 8 | Unix time | when the download finished (matches the file times) |
| 0x50 | 20 × 256 | | SHA-1 of each block; unused slots zero |

The SHA-1s of the base game's and ex1's newest patches, downloaded again on
2026-10-30, match their records. Both are under 50,000,000 bytes, so each
hash covers the whole file. That the 50,000,000 field is a block size, with
one hash per block for larger patches, is inferred from the layout; no
multi-block record has been seen. The launcher must take these hashes from the
patch list; how a list gives them is **unknown** until step 6's reply is
recorded.

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

- **`FHDR`** comes first. The applier doesn't use it: nothing in it changes
  what is written, and the chunks' CRC32s, the blocks' SHA-1s and the size
  check already cover integrity. What is known (compared on 2026-11-01 with
  what five game patches actually contain):
  - **Size and version:** the boot patch's payload was 20 bytes with version
    byte `2` at offset 2; game patches' are 244 bytes with version `3`.
  - **Name** (offset 4): `HIST` or `DIFF`, but it doesn't say which kind of
    patch the file is: the boot `D` patch and the base game's update patches
    `D2024.06.13.0000.0001` and `D2025.09.09.0000.0001` say `HIST`, and an
    ex1 history part says `DIFF`.
  - **Repository ID** (offset 0x20, 4 bytes): the ID in the patch's URL
    (`4e9a232b` for the base game, `6b936f08` for ex1), as xiv.dev says.
  - **Command counts, in some files** (big-endian 4-byte words): 0x28 `A`,
    0x2c `D`, 0x30 `E`, 0x34 `H`, 0x38 `F`. Base game
    `D2026.04.10.0000.0000` has 13,615 / 157 / 0 / 26 / 44 there against
    13,614 / 157 / 0 / 26 / 44 commands actually in it (the `A` count off by
    one); ex1 `D2026.08.20.0000.0000` has 2 `A` and 4 `H`, and base game
    `D2026.10.16.0000.0000` 35 `F`, all exact. The `E` count was 0 in every
    header that holds counts, matching `E` never having been seen.
  - **Leftover memory, in others:** in `D2024.06.13` and `D2025.09.09`
    (the two named `HIST`) the count area holds values like 913,958,193 next
    to 32,758 (`0x7FF6`), which look like halves of 64-bit Windows user-mode
    pointers, not counts. So the counts can't be relied on; as a sanity
    check they would only fit the files where they make sense.
  - The remaining fields (from 0x40 on: several large values, small ones
    like 1, 12 or 1,369,856) are unknown.
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
- `R`, not in xiv.dev: the first command of each ex1 history part's first
  file, with an empty path and the repository's expansion ID (1). It
  presumably resets the repository before the rebuild, but what it removes
  is unconfirmed, so the applier accepts it only while the repository has no
  files in `sqpack/` and `movie/` (always true in a fresh install) and stops
  otherwise.
- `D` deletes the file. The boot patch deletes the 32-bit
  `ffxivlauncher.exe`, `ffxivupdater.exe` and `ffxivconfig.exe`, which is
  why only four boot-hash files remain.

Each block has a 16-byte little-endian header: header size (16), unused,
compressed size and decompressed size. The data follows the header. A
compressed size of `32000` means the data is stored raw; otherwise it is raw
deflate. Each block, header included, is padded to a multiple of 128 bytes:
`(data length + 0x8F) & ~0x7F`.

### Dat and index commands (A, D, E, H)

These name their target with three bytes, then a file reference of 8 bytes:
main ID (2), sub ID (2), file number (4). The expansion is the sub ID's high
byte, so the file is `sqpack/{ffxiv | exN}/{main:02x}{sub:04x}.win32.dat{file}`,
or `.win32.index` (number 0) / `.win32.index{file}` for an index. Offsets and
counts are in 128-byte blocks.

- **`A`** (add): after the target, block offset, block count and delete
  count (4 bytes each). Its data (block count × 128 bytes) is written at the
  offset, followed by delete count × 128 zero bytes.
- **`H`** (header): the three bytes are the file kind (`D` dat or `I`
  index), the header kind (`V` version, `D` data, `I` index) and a pad byte.
  1,024 bytes follow the target. A `V` header is written at offset 0, the
  others at 1,024. The `V` payload starts with `SqPack`.
- **`D`** (delete): block offset and block count (4 bytes each). It writes
  count × 128 zero bytes at the offset, the first 20 of them an empty-block
  header, little-endian: 128, 0, 0, **count − 1**, 0. xiv.dev gives the count
  itself; the ex1 rebuild showed count − 1 in all 1,306 such blocks it
  compared.
- **`E`** (expand), from xiv.dev only: the same fields as `D`, allowed to
  extend the file. Not seen in any patch so far, and since xiv.dev's `D`
  header was wrong, the applier refuses `E` until one is seen.

  A `D` may start exactly at the end of its file and so append empty blocks,
  against xiv.dev's "fails at the end of the file": the base game's
  `D2024.06.13.0000.0001` does it three times, each right after its own `A`
  commands grew the file to that point (found when an install stopped there,
  2026-10-31). A `D` that would start beyond the end, leaving a gap, has not
  been seen and is refused.

The ex1 patch `D2026.08.20.0000.0000` has two `A` commands (one into each of
`030100.win32.dat0` and `dat1`) and four `H` (version and data header of
each). Reapplying it to clones of the already-patched files wrote the same
bytes that were there, which a wrong offset, path or field would not.

## Madeira's design (agreed 2026-10-31)

Built on 2026-10-31 (`FFXIVPatcher.swift`, `FFXIVLibrary.swift`). A full fresh
install on an iPhone, to an external drive, ended byte-identical to the
official Mac app's install and played (2026-11-01; see the confirmation log).

- **Library section:** "FINAL FANTASY XIV" (`app/Madeira/FFXIVLibrary.swift`,
  built 2026-10-31), shown like the Epic Games section and switched by
  `MADEIRA_FFXIV` (default on). With no FFXIV entry, an install card; with
  some, an "Install a new copy…" link under them. The install sheet picks
  the place (this device or a connected external drive), shows its free
  space and the approximate sizes, and the section shows the progress.
  Installed: the game's card, opening Game
  details, which offers **Update** when sign-in reports pending patches.
  Recognized FFXIV entries (`docs/SQUARE_ENIX_SIGNIN.md`) move here from
  "Other games" and are adopted, not duplicated.
- **Install path:** on this device, `drive_c/Program Files (x86)/SquareEnix/FINAL FANTASY XIV - A Realm Reborn`,
  the official one, so the existing recognition and the probe keep working.
  On an external drive (`docs/EXTERNAL_STORAGE.md`),
  `drive_c/External/<drive>/SquareEnix/FINAL FANTASY XIV - A Realm Reborn`:
  the entry keeps that drive_c path for Wine, and installs and updates
  write through `ExternalDrives.nativeURL`, which refuses a drive that is
  disconnected, no longer the registered one, or read-only. Free space is
  the volume's "important usage" figure, or its plain available capacity
  where a drive doesn't report that.
- **Account:** the existing per-entry Keychain sign-in. The installer makes
  the entry and the folder first, then runs the sign-in sheet to fetch the
  list. Done (2026-10-31): sign-in's "update needed" error now carries a
  `SquareEnixUpdate`, the stage (boot or game) and the parsed list
  (`SquareEnixProtocol.patchList`), in place of the bare target version. A
  line that looks like a patch but doesn't parse, whose hashes don't cover
  its size, or whose URL isn't `http://patch-dl.ffxiv.com/…` rejects the
  whole list.
- **Expansions:** all five are always reported (`exN.ver` written at
  `2012.01.01.0000.0000`), as the official launcher installed them; there is
  no choice (dropped 2026-10-31). Whether the server leaves out expansions an
  account doesn't own is **unknown**: the only account tried owns them all.
- **Fresh install, with no Square Enix files in Madeira:**
  1. write `boot/ffxivboot.ver` = `2012.01.01.0000.0000`; the boot check then
     lists `D2013.06.18.0000.0000` and `D2026.08.18.0000.0001` (2026-10-31),
     which produce the boot programs the boot hash needs;
  2. write `game/ffxivgame.ver` and each `game/sqpack/exN/exN.ver` =
     `2012.01.01.0000.0000`;
  3. sign in; session registration returns the full list;
  4. per patch, in list order: check free space against field 2, download
     (resuming with ranges), check each 50,000,000-byte block's SHA-1, apply,
     delete, and write the version file when field 5 is a version.
  An update is steps 3 and 4 on an existing install.
- **Size check:** after each patch that completes a version, the runner
  measures the repository as field 2 counts it and logs the two figures
  (`[ffxiv-patch] size check`). It doesn't stop the run, because an existing
  install may hold files no patch made. Each part of a split `D` patch
  (`2024.10.25.0000.0000` to `.0003.0000`) carries the size after the set's
  last part, so a patch is compared only when the next patch of its
  repository reports a different size (a plain patch followed by one that
  leaves the size unchanged is skipped too; the last of such a run is
  checked); on an iPhone install (external
  APFS drive, 2026-10-31) every such comparison through `2025.07.18` matched
  to the byte.
- **Timings:** each `[ffxiv-patch] applied` line gives the bytes downloaded
  in that run, the time spent waiting on the network and writing them to
  the drive, the read-back for the SHA-1 check, and applying, each with its
  rate, to tell a slow drive from a slow network.
- **Speed:** on an iPhone installing to an external APFS drive, applying
  was the bottleneck at 5 to 21 MB/s, against 26 to 67 MB/s for the network
  and 68 to 109 MB/s for writing a download (2026-10-31). Applying is many
  small writes: base game `D2025.09.09.0000.0001` makes 13,693 (median
  16,000 bytes) for 898 MB. The applier therefore buffers a write and joins
  the next one to it when it starts exactly where the buffer ends (up to
  8 MiB), writing it out before anything else; that patch then needs 2,115
  writes. Bytes and order are unchanged (ex1 still rebuilds byte for byte).
  That changed little on the device: the patches' edits are separate
  regions, not out of order (sorting them by offset leaves the counts
  unchanged), and the iPhone's drive was a small spinning disk doing about 80
  random operations a second (`D2026.04.10.0000.0000`: ~7,700 writes and
  ~14,800 partial-page reads in 284 s). Three measures followed:
  - **Spinning-disk detection:** iOS can't say whether a drive spins, so
    before the first patch that edits an existing data file, the runner
    times 32 uncached (`F_NOCACHE`) random 4 KiB reads in the install's
    largest file (at least 256 MiB). A median over 2.5 ms means a spinning
    disk (5 to 15 ms per read); the Mac's SSD measured 0.14 ms. The result
    is logged (`[ffxiv-patch] drive: …`).
  - **Gap filling, on spinning disks only:** a write starting at most
    256 KiB after the buffered one joins it, with the bytes between read
    from the file and written back unchanged; they are current, since
    every earlier write to them has gone out. Estimated a third fewer
    random operations for that patch (279 MB more read and written).
  - **Download-ahead, a switch in the Update section, off by default:**
    patches download to this device's Caches folder, and the next one
    downloads while the current one is checked and applied, so a slow drive
    doesn't hold up the network (and a staged patch is read back from fast
    storage). Only while the device has room for that patch plus 1 GiB;
    otherwise it downloads to the install's work folder in turn. For a game
    on an external drive it writes every patch to the device's flash once
    more (for a game on the device, patches land on it either way), hence
    the switch. A partial download in either folder is resumed. The switch's
    caption recommends it for a game on an external drive and gives what it
    needs on the device (two of the list's largest patches plus 1 GiB) and,
    for a drive, the extra wear, with a warning when the device has less
    room. A model of a whole fresh install to a fast drive behind a USB 2
    port (48 MB/s) put it at about 1.1 hours with download-ahead and several
    times that without; more download connections would save under a
    tenth, the drive's connection being the limit.
  - **Memory:** FileHandle's reads return autoreleased buffers, and the
    runner's loops rarely suspend, so a run held on to everything it read: a
    fresh ex1 run peaked at a 3.97 GB footprint on the Mac (3.69 GB without
    download-ahead), and an iPhone run ended without a crash report, the way
    iOS ends an app over its memory limit. Each chunk, SHA-1 read and
    download write now has its own autorelease pool: 794 MB peak, same speed,
    still byte-identical.
  - **A bad download is fetched again once:** a patch that fails its size or
    SHA-1 check is deleted and downloaded again from the start, and only a
    second failure stops the run. On the iPhone, a patch whose
    download-ahead had been cut off when the app was stopped failed its
    check when resumed (2026-10-31); a corrupted leftover in the Mac tests
    is now caught, fetched again and applied, ending byte-identical.
- **Applier:** `app/Madeira/FFXIVPatcher.swift` (done 2026-10-31), new
  Swift code from this document. `ZiPatchApplier` streams a patch chunk by
  chunk, checks every chunk's CRC32, keeps paths inside the folder, and
  refuses any command not confirmed here (`E` included). `FFXIVPatchRunner`
  runs a `[SquareEnixPatch]`: a free-space check against field 2, a download
  in 64 MiB range requests (the unit of resuming), the size and per-block
  SHA-1 checks, applying, deleting, the `.ver`/`.bck` files, and a journal
  of applied patches (`.madeira-patches/applied.txt` in the install folder)
  so an interrupted run continues (tested by killing a run mid-download).
  A run interrupted while applying a history patch's first part meets its
  own partial files at `R`. `FFXIVLibrary` then starts that repository over,
  once, but only when the journal holds none of its patches and its version
  file is missing or still `2012.01.01.0000.0000`: then every file there is
  the interrupted part's. In any other case the reset is refused. `R` ignores
  `.ver` and `.bck` files, which a fresh install writes before any patch. `ZiPatchApplier.maxChunk` (256 MiB) is a sanity
  limit, not a measured one: only ex1's chunks and one base-game patch have
  been through it, and the base game's 34 history parts are untested.
- **Downloads:** the background-download helper Steam and Epic share, paused
  during a game session; an App Transport Security exception for
  `patch-dl.ffxiv.com`.
- **Order of work:** update first, then fresh install. With no outdated
  install at hand, the chain is first proven on the Mac by rebuilding one
  expansion from `2012.01.01.0000.0000` and comparing it with an installed
  copy; a copy stopped partway serves as an outdated install for testing
  Update.

## Tools

- **`tools/zipatch-inspect.py survey <patch>`** checks every chunk's CRC32
  and lists the chunks, SQPK commands and file operations.
- **`tools/zipatch-inspect.py apply-sqpk <patch> <game>`** applies the `A`,
  `D`, `E` and `H` commands to `<game>/sqpack` (use copies or APFS clones,
  `cp -c`) and reports whether each one changed data.
- **`tools/zipatch-inspect.py apply-files <patch> <out> [<reference>]`**
  applies only the F operations, then compares each written file with the
  reference folder.
- **`tools/sqex-signin-probe.py`**:
  - `--boot-version`, `--game-version` and `--ex-version N=…` report other
    versions through a temporary install with links to the real boot
    programs, so the real game files are untouched.
  - `--save-reply` saves step 6's reply with the session ID redacted.

## Open questions

- Field 4 of a game patch list line.
- Whether the official launcher reports `2012.01.01.0000.0000` for missing
  expansions in its first registration, or registers again after the base
  game. Both give a usable list.
- Whether `D` and `E` behave as xiv.dev describes. No patch seen so far
  uses them; the fresh-install chain may.
- `H` commands for index files (none seen yet).
- The remaining `FHDR` fields, and the `T` command.

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
  - Square Enix's official Mac app (1.1.11): its bottle template's starting
    installation, and the download records its launcher left after a fresh
    install on 2026-10-29
  - the newest game patches of the base game (`D2026.10.16.0000.0000`) and
    ex1 (`D2026.08.20.0000.0000`), downloaded and surveyed
  - session registration's reply for game version `2012.01.01.0000.0000`,
    with and without expansions, recorded by the probe (session ID redacted)

## Confirmation log (2026-10-30)

| Piece | Method | Finding |
|---|---|---|
| Downloads | `HEAD`/`GET` of the boot patch | public, resumable, size matches; HTTPS host mismatch |
| Container | `zipatch-inspect.py survey` | 54 chunks, all CRC32s valid, ends exactly at `EOF_`; FHDR 20 bytes, version 2, `HIST` |
| F operations | `zipatch-inspect.py apply-files` against the installed boot folder | 16 of 16 files byte-identical; the 3 deleted files are absent there too |
| Game downloads | `HEAD` of the newest base game, ex1 and ex5 patches; `GET` of base game and ex1 | public with no User-Agent, resumable, sizes match the launcher's records; SHA-1s match the records |
| Game patch chunks | `zipatch-inspect.py survey` of base game `D2026.10.16.0000.0000` and ex1 `D2026.08.20.0000.0000` | all CRC32s valid; FHDR 244 bytes, version 3, `DIFF`; base game: 35 F `A` (`ffxiv_dx11.exe`, `XInputXIV3.dll`, `XInputXIV9.dll`); ex1: SQPK `A` ×2, `H` ×4 |
| Fresh install | the official Mac app's bottle template | `game/` holds only `ffxivgame.ver` (`2012.01.01.0000.0000`) and the opening movies; boot `2018.12.14.0000.0001` |
| Boot for a fresh install | boot check for `2018.12.14.0000.0001` (no sign-in needed) | one patch, `D2026.08.18.0000.0001` (20,820,391 bytes) |
| SQPK A and H | `zipatch-inspect.py apply-sqpk` of ex1 `D2026.08.20.0000.0000` on APFS clones of ex1 at that version | 2 `A` and 4 `H` wrote identical bytes; both dats still byte-identical to the install |
| Game patch lists | `sqex-signin-probe.py --game-version 2012.01.01.0000.0000 --save-reply`, once with no expansions and once with ex1–5 at `2012.01.01.0000.0000` (2026-10-31) | 108 base-game patches; 204 across all six repositories; `X-Patch-Unique-Id` present; hash counts = ceil(size / 50,000,000) for every line |
| List fields 2 and 3 | compared with the installed game at the newest versions | installed bytes and file count of each repository (sqpack + movie, without `.ver`/`.bck`), exact for all six |
| Whole chain | `zipatch-inspect.py chain` of all 13 ex1 patches from nothing (2026-10-31), every block's SHA-1 checked | after fixing the `D` header count: `sqpack/ex1` (with `.ver`/`.bck`) and `movie/ex1` byte-identical to the installed copy; 9.2 GB in about 3 minutes |
| Swift applier and runner | `FFXIVPatcher.swift` in a Mac test driver (2026-10-31): fresh ex1 (13 patches, `-Onone`) and an update from the `2026.04.10.0000.0001` snapshot (3 patches) | both byte-identical to the installed ex1; fresh in 211 s with downloads; a corrupted chunk, a wrong hash and escaping paths are refused |
| Boot bootstrap | the runner on the boot list for `2012.01.01.0000.0000` (`D2013.06.18.0000.0000`, then `D2026.08.18.0000.0001`) into an empty install (2026-10-31) | all 18 files written, `ffxivboot.ver`/`.bck` included, identical to the official app's boot folder (whose shader cache is a link, not a patch file) |
| Resume | the runner killed 45 s into a fresh ex1 run (part `a` applied, part `b` 738 MB downloaded), then run again | it skipped `a`, continued `b` from its byte offset, and ended byte-identical; a stray file in an empty ex1 made `R` stop the run with nothing changed |
| Free-space check | 2 GiB written while reading the volume's free space through one URL and through fresh ones | the reused URL kept reporting the old figure (cached resource values), so the runner reads through a fresh URL each time |
| Base history and `D` at the end | all 34 base history parts streamed and simulated, then `D2024.06.13.0000.0001` replayed over sparse files of those sizes (2026-10-31) | the history build totals exactly field 2 (54,523,146,100 bytes); three of that patch's `D` start exactly at their file's end, and applying them as appends completes the patch |
| Gap filling and download-ahead | the runner with gaps forced to 256 KiB and download-ahead to a staging folder: fresh ex1, a run killed 45 s in and resumed, the snapshot update (2026-10-31) | all byte-identical to the installed ex1; the killed run resumed part `b` from 402 MB in the staging folder |
| Whole fresh install on an iPhone | Madeira installed the game from nothing onto an external APFS spinning disk (all 204 patches plus the boot patches), then the drive was compared with the official Mac app's install at the same versions, SHA-256 per file (2026-11-01) | all 256 files present on both byte-identical (129.0 GB), and the four opening movies (links into the app's own bottle on the Mac) identical too; the only other differences are the Mac app's shader cache link `boot/cache_ffxiv_dx11.exe.bin`, which no patch makes, and Finder's `.DS_Store` files; the game played |
