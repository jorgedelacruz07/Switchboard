"""Verify staged app code and gate atomic replacement. Never change login state."""
import argparse
import ctypes
import hashlib
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys

IDENTIFIER = 'com.jorgedelacruz.projects-menu'
API_VERSION = 2


def run(arguments):
    return subprocess.run(arguments, text=True, capture_output=True, timeout=20, check=True).stdout


def verify_bundle(bundle, app_root, workspace, runner=run):
    if bundle.is_symlink() or not bundle.is_dir():
        raise ValueError('Expected a complete real app directory; symlink refused')
    for path in bundle.rglob('*'):
        if path.is_symlink():
            raise ValueError('Unexpected bundle-internal symlink; preserve for review')
    runner(['/usr/bin/codesign', '--verify', '--deep', '--strict', str(bundle)])
    with (bundle / 'Contents/Info.plist').open('rb') as file:
        info = plistlib.load(file)
    expected = {'CFBundleIdentifier': IDENTIFIER, 'CFBundleExecutable': 'Switchboard',
                'CFBundlePackageType': 'APPL', 'ProjectsAppRoot': str(app_root),
                'ProjectsWorkspaceRoot': str(workspace), 'SwitchboardLoginAPIVersion': API_VERSION}
    if any(info.get(key) != value for key, value in expected.items()):
        raise ValueError('Signed bundle metadata readback mismatch')
    if not os.access(bundle / 'Contents/MacOS/Switchboard', os.X_OK):
        raise ValueError('Missing executable')


def fingerprint(bundle):
    digest = hashlib.sha256()
    for path in sorted(bundle.rglob('*')):
        if path.is_file():
            digest.update(str(path.relative_to(bundle)).encode())
            digest.update(path.read_bytes())
    return digest.hexdigest()


def installed_status(stable, runner=run):
    # Verify stable signature/capability before calling its read-only CLI. An old
    # app could interpret unknown flags as GUI startup, so never invoke one.
    if stable.is_symlink() or not stable.is_dir():
        raise ValueError('Stable installed app unavailable; unknown login state. Use stage-only and reviewed bootstrap')
    runner(['/usr/bin/codesign', '--verify', '--deep', '--strict', str(stable)])
    with (stable / 'Contents/Info.plist').open('rb') as file:
        info = plistlib.load(file)
    if info.get('SwitchboardLoginAPIVersion') != API_VERSION or info.get('CFBundleIdentifier') != IDENTIFIER:
        raise ValueError('Stable app cannot provide identity-verified status; controlled migration required')
    return json.loads(runner([str(stable / 'Contents/MacOS/Switchboard'), '--login', 'status']))


def require_update_allowed(report, stable):
    identity = report.get('identity') or {}
    if (identity.get('bundlePath') != str(stable.resolve())
            or identity.get('stableBundlePath') != str(stable.resolve())
            or identity.get('identifier') != IDENTIFIER):
        raise ValueError('Status is not from the stable installed bundle')
    if (report.get('error') or report.get('modern') != 'notRegistered'
            or (report.get('legacy') or {}).get('kind') != 'absent'):
        raise ValueError('Ordinary update refused: modern login must be confirmed notRegistered, legacy absent, no errors')


def require_stopped(runner=run):
    # Conservative: refuse any running app with this executable, without killing it.
    commands = runner(['/bin/ps', '-axo', 'comm=']).splitlines()
    if any(Path(command.strip()).name == 'Switchboard' for command in commands):
        raise ValueError('Switchboard is running; quit it explicitly before replacement')


def atomic_swap(first, second):
    if sys.platform != 'darwin':
        raise ValueError('Atomic bundle exchange requires macOS')
    libc = ctypes.CDLL('/usr/lib/libSystem.B.dylib', use_errno=True)
    swap = libc.renamex_np
    swap.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint]
    swap.restype = ctypes.c_int
    if swap(os.fsencode(first), os.fsencode(second), 0x00000002) != 0:  # RENAME_SWAP
        raise OSError(ctypes.get_errno(), 'Atomic bundle exchange failed')


def publish(stage, stable, app_root, workspace, runner=run, swap=atomic_swap):
    if stage.resolve() == stable.resolve() or stage.parent.parent.resolve() != stable.parent.resolve():
        raise ValueError('Stage must be an isolated sibling staging directory on the stable volume')
    verify_bundle(stage, app_root, workspace, runner)
    candidate = fingerprint(stage)
    require_update_allowed(installed_status(stable, runner), stable)
    require_stopped(runner)
    previous = fingerprint(stable)
    # Re-read authorization and running state at the swap boundary. No updater
    # API registers/unregisters or retries denial on the operator's behalf.
    require_update_allowed(installed_status(stable, runner), stable)
    require_stopped(runner)
    if fingerprint(stage) != candidate or fingerprint(stable) != previous:
        raise ValueError('Bundle changed during verification; update refused')
    if stage.stat().st_dev != stable.stat().st_dev:
        raise ValueError('Atomic exchange requires the same volume')
    swap(stage, stable)
    try:
        verify_bundle(stable, app_root, workspace, runner)
        if fingerprint(stable) != candidate:
            raise ValueError('Published bundle readback mismatch')
    except Exception:
        swap(stage, stable)  # Restore complete old bundle; never rewrite signed bytes.
        raise
    return stage  # Previous complete signed bundle retained for reviewed rollback.


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['verify', 'publish'])
    parser.add_argument('--stage', required=True, type=Path)
    parser.add_argument('--stable', required=True, type=Path)
    parser.add_argument('--app-root', required=True, type=Path)
    parser.add_argument('--workspace', required=True, type=Path)
    args = parser.parse_args()
    try:
        if args.action == 'verify':
            verify_bundle(args.stage, args.app_root, args.workspace)
            print(f'Verified staged signature and metadata: {args.stage}')
        else:
            lock = args.stable.parent / '.switchboard-update.lock'
            with lock.open('x') as file:
                try:
                    backup = publish(args.stage, args.stable, args.app_root, args.workspace)
                    print(f'Atomic replacement complete; previous signed bundle preserved at: {backup}')
                finally:
                    lock.unlink()
    except Exception as error:
        print(f'Update refused: {error}. Staged bundle retained for review.', file=sys.stderr)
        sys.exit(1)
