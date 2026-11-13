"""Update gates use only temporary bundles and injected process responses."""
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest

SPEC = importlib.util.spec_from_file_location('app_update', Path(__file__).resolve().parents[1] / 'scripts/app-update.py')
update = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(update)


class AppUpdateTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.workspace = self.root / 'workspace'
        self.stable = self.root / 'build/Switchboard.app'
        self.stage = self.root / 'build/.stage-synthetic/Switchboard.app'
        self.fixture(self.stable, b'old signed bytes')
        self.fixture(self.stage, b'new signed bytes')
        self.report = {'modern': 'notRegistered', 'legacy': {'kind': 'absent'},
                       'identity': {'bundlePath': str(self.stable), 'stableBundlePath': str(self.stable),
                                    'identifier': update.IDENTIFIER}}
        self.calls = []
        self.swaps = 0
        self.running = False

    def fixture(self, path, executable):
        binary = path / 'Contents/MacOS/Switchboard'
        binary.parent.mkdir(parents=True)
        binary.write_bytes(executable)
        binary.chmod(0o700)
        info = {'CFBundleIdentifier': update.IDENTIFIER, 'CFBundleExecutable': 'Switchboard',
                'CFBundlePackageType': 'APPL', 'ProjectsAppRoot': str(self.root),
                'ProjectsWorkspaceRoot': str(self.workspace), 'SwitchboardLoginAPIVersion': update.API_VERSION}
        with (path / 'Contents/Info.plist').open('wb') as file:
            plistlib.dump(info, file)

    def runner(self, args):
        self.calls.append(args)
        if args[0] == '/usr/bin/codesign':
            return ''  # Signature acceptance injected for synthetic byte fixtures.
        if args[0] == '/bin/ps':
            return str(self.stable / 'Contents/MacOS/Switchboard') if self.running else ''
        self.assertEqual(args, [str(self.stable / 'Contents/MacOS/Switchboard'), '--login', 'status'])
        return json.dumps(self.report)

    def swap(self, first, second):
        self.swaps += 1
        update.atomic_swap(first, second)  # Real atomic exchange, temporary folders only.

    def publish(self, runner=None):
        return update.publish(self.stage, self.stable, self.root, self.workspace, runner or self.runner, self.swap)

    def test_authorized_stopped_update_exchanges_inodes_and_preserves_old_bundle(self):
        inode = self.stable.stat().st_ino
        backup = self.publish()
        self.assertNotEqual(inode, self.stable.stat().st_ino)
        self.assertEqual(inode, backup.stat().st_ino)
        self.assertEqual((backup / 'Contents/MacOS/Switchboard').read_bytes(), b'old signed bytes')
        self.assertEqual((self.stable / 'Contents/MacOS/Switchboard').read_bytes(), b'new signed bytes')
        self.assertEqual(self.swaps, 1)
        self.assertFalse(any('register' in arg or 'unregister' in arg for args in self.calls for arg in args))

    def test_enabled_pending_unknown_and_notfound_never_mutate_stable_bundle(self):
        original = update.fingerprint(self.stable)
        for state in ('enabled', 'requiresApproval', 'unknown', 'notFound', None):
            with self.subTest(state=state):
                self.report['modern'] = state
                with self.assertRaises(ValueError):
                    self.publish()
                self.assertEqual(update.fingerprint(self.stable), original)
                self.assertEqual(self.swaps, 0)

    def test_running_app_is_never_killed_or_replaced(self):
        self.running = True
        with self.assertRaisesRegex(ValueError, 'running'):
            self.publish()
        self.assertEqual(self.swaps, 0)
        self.assertFalse(any('kill' in arg for args in self.calls for arg in args))

    def test_staging_diagnostic_is_not_installed_state(self):
        self.report['identity']['bundlePath'] = str(self.stage)
        with self.assertRaisesRegex(ValueError, 'stable installed'):
            self.publish()
        self.assertEqual(self.swaps, 0)

    def test_errors_and_legacy_entries_refuse_updates(self):
        for extra in ({'error': 'Denied'}, {'legacy': {'kind': 'recognized'}}, {'identity': {}}):
            report = {**self.report, **extra}
            with self.assertRaises(ValueError):
                update.require_update_allowed(report, self.stable)

    def test_signature_or_metadata_failure_prevents_swap(self):
        def rejected(args):
            raise subprocess.CalledProcessError(1, args)
        with self.assertRaises(subprocess.CalledProcessError):
            self.publish(rejected)
        info = self.stage / 'Contents/Info.plist'
        data = plistlib.loads(info.read_bytes())
        data['CFBundleIdentifier'] = 'unexpected'
        info.write_bytes(plistlib.dumps(data))
        with self.assertRaisesRegex(ValueError, 'metadata'):
            self.publish()
        self.assertEqual(self.swaps, 0)

    def test_registration_or_code_change_at_swap_boundary_refuses(self):
        reads = 0
        def changed(args):
            nonlocal reads
            if args[-2:] == ['--login', 'status']:
                reads += 1
                if reads == 2:
                    self.report['modern'] = 'enabled'
            return self.runner(args)
        with self.assertRaises(ValueError):
            self.publish(changed)
        self.assertEqual(self.swaps, 0)

    def test_failed_readback_restores_the_whole_old_bundle(self):
        original = update.fingerprint(self.stable)
        def after_swap(args):
            if self.swaps == 1:
                raise subprocess.CalledProcessError(1, args)
            return self.runner(args)
        with self.assertRaises(subprocess.CalledProcessError):
            self.publish(after_swap)
        self.assertEqual(self.swaps, 2)
        self.assertEqual(update.fingerprint(self.stable), original)

    def test_legacy_or_missing_stable_binary_never_receives_unknown_cli_flags(self):
        with (self.stable / 'Contents/Info.plist').open('wb') as file:
            plistlib.dump({'CFBundleIdentifier': update.IDENTIFIER}, file)
        with self.assertRaisesRegex(ValueError, 'identity-verified'):
            self.publish()
        self.assertTrue(all('--login' not in args for args in self.calls))

    def test_shell_builder_writes_only_to_stage_before_gate(self):
        source = (Path(__file__).resolve().parents[1] / 'switchboard.sh').read_text()
        resource = self.root / 'Resources/Info.plist'
        resource.parent.mkdir()
        shutil.copyfile(Path(__file__).resolve().parents[1] / 'Resources/Info.plist', resource)
        helper = self.root / 'scripts/app-update.py'
        helper.parent.mkdir()
        helper.write_text("import sys\nfrom pathlib import Path\np=Path(sys.argv[sys.argv.index('--stage')+1])\nassert '.stage-' in str(p)\nprint(sys.argv[1])\nsys.exit(0 if sys.argv[1]=='verify' else 31)\n")
        harness = self.root / 'build-fixture.sh'
        functions = source.split('case "${1:-open}"')[0]
        stubs = r'''
APP_ROOT="$FIXTURE_ROOT"
APP="$APP_ROOT/build/Switchboard.app"
require_macos() { return 0; }
workspace_root() { printf '%s\n' "$FIXTURE_ROOT/workspace"; }
xcrun() {
  while [[ $# -gt 0 && "$1" != "-o" ]]; do shift; done
  shift
  printf 'synthetic compiled bytes' > "$1"
  chmod +x "$1"
}
codesign() { [[ "$*" == *".stage-"* ]]; }
build_app
'''
        harness.write_text(functions + stubs)
        original = update.fingerprint(self.stable)
        result = subprocess.run(['/bin/bash', str(harness)], env={**os.environ, 'FIXTURE_ROOT': str(self.root)}, capture_output=True, text=True)
        self.assertEqual(result.returncode, 31, result.stderr)
        self.assertEqual(update.fingerprint(self.stable), original)
        self.assertEqual(len(list((self.root / 'build').glob('.stage-*/Switchboard.app/Contents/MacOS/Switchboard'))), 2)  # existing fixture plus new stage

    @unittest.skipUnless(sys.platform == 'darwin' and shutil.which('codesign'), 'macOS codesign required')
    def test_real_staged_signature_verification_and_metadata_readback(self):
        # Only a fresh temporary app is signed; no installed bundle is read/changed.
        binary = self.stage / 'Contents/MacOS/Switchboard'
        shutil.copyfile('/usr/bin/true', binary)
        binary.chmod(0o700)
        subprocess.run(['/usr/bin/codesign', '--force', '--sign', '-', str(self.stage)], check=True, capture_output=True)
        update.verify_bundle(self.stage, self.root, self.workspace)
        with (self.stage / 'Contents/Info.plist').open('ab') as file:
            file.write(b'\n<!-- changed after signing -->')
        with self.assertRaises(subprocess.CalledProcessError):
            update.verify_bundle(self.stage, self.root, self.workspace)


if __name__ == '__main__':
    unittest.main()
