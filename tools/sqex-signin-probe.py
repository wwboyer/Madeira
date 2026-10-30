#!/usr/bin/env python3
"""Run Madeira's Square Enix sign-in from a Mac, against the real servers.

Compiles app/Madeira/SquareEnixSignIn.swift with a small driver and signs in
once with the installation given (any FFXIV program in it, or its folder):
login and gate status, the boot check, the login page, the credentials and the
session registration (docs/SQUARE_ENIX_SIGNIN.md, steps 1 to 6). It prints the
sign-in's own log lines, which hold no secrets, and the launch arguments with
the session ID masked. The game is not started.

The password and one-time password are read without echo and reach the driver
on its standard input, never in its arguments or environment. A refused
sign-in is never retried: repeated wrong passwords can lock the account.

  python3 tools/sqex-signin-probe.py --game "<.../FINAL FANTASY XIV - A Realm Reborn>" --license mac --region 2

To ask the patch servers about another version without touching the game's
files, --boot-version, --game-version and --ex-version N=VERSION (N=- leaves
expansion N out) build a temporary installation: links to the real boot
programs, so the boot hash stays right, and version files with the versions
given. An older boot version stops at the boot check, which then reports its
patch list. --save-reply FILE records session registration's reply (status,
headers and body; the session ID header's value is replaced, and the URL, which
holds the SID, is not recorded): for an outdated game it is the patch list.
"""
from pathlib import Path
import argparse
import getpass
import re
import shutil
import subprocess
import sys
import tempfile

parser = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
parser.add_argument('--game', required=True, help='the game folder (holding boot/ and game/) or one of its programs')
parser.add_argument('--license', choices=['mac', 'windows'], required=True)
parser.add_argument('--region', type=int, required=True, help='rgn of the login page')
parser.add_argument('--language', default='en', help='lng of the login page (default en)')
parser.add_argument('--frontier-language', default='en-us', help='lang of the gate status (default en-us)')
parser.add_argument('--free-trial', action='store_true')
parser.add_argument('--install-id', help='the Windows User-Agent id (default: a new one per run)')
parser.add_argument('--patch-user-agent', help="override the license's patch User-Agent")
parser.add_argument('--boot-version', help='report this boot version instead of the installed one')
parser.add_argument('--game-version', help='report this game version instead of the installed one')
parser.add_argument('--ex-version', action='append', default=[], metavar='N=VERSION',
                    help="report this version for expansion N (N=- leaves it out); repeatable")
parser.add_argument('--save-reply', help="write session registration's reply to this file")
args = parser.parse_args()

if args.install_id:
    raw = bytes.fromhex(args.install_id) if re.fullmatch(r'[0-9a-f]{10}', args.install_id) else b''
    if len(raw) != 5 or sum(raw) % 256:
        sys.exit('--install-id: ten lowercase hex digits whose five bytes add up to a multiple of 256')

VERSION = re.compile(r'\d{4}\.\d{2}\.\d{2}\.\d{4}\.\d{4}')
expansions_override = {}
for item in args.ex_version:
    number, _, version = item.partition('=')
    if not number.isdigit() or int(number) < 1 or not (version == '-' or VERSION.fullmatch(version)):
        sys.exit(f'--ex-version {item}: expected N=YYYY.MM.DD.NNNN.NNNN or N=-')
    expansions_override[int(number)] = version
for name in ('boot_version', 'game_version'):
    value = getattr(args, name)
    if value and not VERSION.fullmatch(value):
        sys.exit(f'--{name.replace("_", "-")}: expected YYYY.MM.DD.NNNN.NNNN')

root = Path(__file__).resolve().parents[1]
game = Path(args.game).expanduser()
program = game if game.suffix.lower() == '.exe' else game / 'game/ffxiv_dx11.exe'


def overridden_install(real_program, base):
    """A temporary installation reporting the versions asked for; its boot programs link to the real ones."""
    real = real_program.resolve().parents[1]
    fake = base / 'install'
    (fake / 'boot').mkdir(parents=True)
    for entry in (real / 'boot').iterdir():
        if entry.is_file() and entry.suffix.lower() == '.exe':
            (fake / 'boot' / entry.name).symlink_to(entry)
    (fake / 'boot/ffxivboot.ver').write_text(args.boot_version or (real / 'boot/ffxivboot.ver').read_text().strip())
    (fake / 'game/sqpack').mkdir(parents=True)
    (fake / 'game/ffxiv_dx11.exe').symlink_to(real / 'game/ffxiv_dx11.exe')
    (fake / 'game/ffxivgame.ver').write_text(args.game_version or (real / 'game/ffxivgame.ver').read_text().strip())
    versions = {}
    for entry in (real / 'game/sqpack').iterdir():
        match = re.fullmatch(r'ex(\d+)', entry.name)
        if match and (entry / f'{entry.name}.ver').is_file():
            versions[int(match.group(1))] = (entry / f'{entry.name}.ver').read_text().strip()
    versions.update(expansions_override)
    for number, version in sorted(versions.items()):
        if version != '-':
            (fake / f'game/sqpack/ex{number}').mkdir()
            (fake / f'game/sqpack/ex{number}/ex{number}.ver').write_text(version)
    print('reporting boot', (fake / 'boot/ffxivboot.ver').read_text(), 'game', (fake / 'game/ffxivgame.ver').read_text(),
          'ex', {n: v for n, v in sorted(versions.items()) if v != '-'})
    return fake / 'game/ffxiv_dx11.exe'

driver = r'''
import Foundation

func argument(_ name: String) -> String? {
    let arguments = CommandLine.arguments
    guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}

guard let install = FFXIVInstall(program: URL(fileURLWithPath: argument("--program")!)) else {
    print("Not an FFXIV installation (no boot/ffxivboot.ver and game/ffxivgame.ver beside the program).")
    exit(2)
}
var options = SquareEnixSignInOptions(license: SquareEnixLicense(rawValue: argument("--license")!)!,
                                      region: Int(argument("--region")!)!,
                                      installID: argument("--install-id") ?? SquareEnixSignInOptions.newInstallID())
options.language = argument("--language")!
options.frontierLanguage = argument("--frontier-language")!
options.freeTrial = argument("--free-trial") == "1"
options.patchUserAgent = argument("--patch-user-agent")

let id = readLine(strippingNewline: true) ?? ""
let password = readLine(strippingNewline: true) ?? ""
let oneTime = readLine(strippingNewline: true) ?? ""
let credentials = SquareEnixCredentials(id: id, password: password, oneTimePassword: oneTime)

/// Passes every request to the real transport and, with --save-reply, writes session
/// registration's reply to a file: status, headers (the session ID's value replaced) and body.
/// The request URL, which holds the SID, is not written.
final class RecordingTransport: SquareEnixTransport {
    let inner = SquareEnixURLSessionTransport()
    let path = argument("--save-reply")

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (body, reply) = try await inner.send(request)
        guard request.url?.host == "patch-gamever.ffxiv.com" else { return (body, reply) }
        var text = "HTTP \(reply.statusCode)\n"
        for (key, value) in reply.allHeaderFields.sorted(by: { "\($0.key)" < "\($1.key)" }) {
            let name = "\(key)"
            let shown = name.lowercased() == "x-patch-unique-id" ? "<session ID, \("\(value)".count) characters>" : "\(value)"
            text += "\(name): \(shown)\n"
        }
        let targets = SquareEnixProtocol.patchTargets(body)
        print("session registration reply: HTTP \(reply.statusCode), \(body.count) body bytes" +
              (targets.isEmpty ? "" : ", patches to \(targets.joined(separator: ", "))"))
        if let path {
            var file = Data((text + "\n").utf8)
            file.append(body)
            try file.write(to: URL(fileURLWithPath: path), options: .atomic)
            print("saved to \(path)")
        }
        return (body, reply)
    }
}

let done = DispatchSemaphore(value: 0)
var status: Int32 = 0
Task {
    do {
        let launch = try await SquareEnixSignIn(transport: RecordingTransport(), log: { print($0) }).signIn(
            install: install, options: options, credentials: credentials, progress: { print("step: \($0.rawValue)") })
        print("RESULT: signed in; would start \(launch.program.path)")
        for argument in launch.arguments {
            print("  " + (argument.hasPrefix("DEV.TestSID=") ? "DEV.TestSID=<session ID, \(argument.count - 12) characters>" : argument))
        }
    } catch {
        print("RESULT: \(error)")
        print("  message: \(error.localizedDescription)")
        status = 1
    }
    done.signal()
}
done.wait()
exit(status)
'''

compiler = shutil.which('swiftc')
if not compiler:
    sys.exit('swiftc is needed (Xcode or the Swift toolchain).')
with tempfile.TemporaryDirectory(prefix='sqex-probe-') as directory:
    temporary = Path(directory)
    (temporary / 'main.swift').write_text(driver)
    binary = temporary / 'sqex-probe'
    subprocess.run([compiler, '-O', str(root / 'app/Madeira/SquareEnixSignIn.swift'), str(temporary / 'main.swift'),
                    '-o', str(binary)], check=True)
    if args.boot_version or args.game_version or expansions_override:
        program = overridden_install(program, temporary)

    sqexid = input('Square Enix ID: ')
    password = getpass.getpass('Password: ')
    one_time = getpass.getpass('One-time password (Enter for none): ')
    command = [str(binary), '--program', str(program), '--license', args.license, '--region', str(args.region),
               '--language', args.language, '--frontier-language', args.frontier_language,
               '--free-trial', '1' if args.free_trial else '0']
    if args.install_id:
        command += ['--install-id', args.install_id]
    if args.patch_user_agent:
        command += ['--patch-user-agent', args.patch_user_agent]
    if args.save_reply:
        command += ['--save-reply', str(Path(args.save_reply).expanduser().resolve())]
    result = subprocess.run(command, input=f'{sqexid}\n{password}\n{one_time}\n', text=True)
    sys.exit(result.returncode)
