"""Run the generated installer migration in isolated volumes, never live paths."""
import os, pathlib, plistlib, shlex, subprocess, sys, tempfile, unittest
ROOT = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / 'scripts'))
from installer_identity import inject_migration, PRODUCT

class InstallerIdentityTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='beautygirl-installer-test.')
        self.root = pathlib.Path(self.tmp.name)
        self.old = self.root / pathlib.Path(PRODUCT['legacyProducts'][0]['installationPath']).relative_to('/')
        self.new = self.root / pathlib.Path(PRODUCT['installationPath']).relative_to('/')
        for app, info in [(self.old, PRODUCT['legacyProducts'][0]), (self.new, PRODUCT)]:
            (app / 'Contents/PlugIns' / info['pluginName'] / 'Contents').mkdir(parents=True)
            (app / 'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier': info['bundleIdentifier']}))
            (app / 'Contents/PlugIns' / info['pluginName'] / 'Contents/Info.plist').write_bytes(plistlib.dumps({'ProPlugPlugInList': [{'uuid': PRODUCT['filterUUID']}]}))
            (app / 'payload-byte').write_bytes(b'original signed payload stand-in')
        self.signer = self.root / 'codesign-fixture'
        self.signer.write_text('#!/bin/zsh\napp="${argv[-1]}"\nif [[ -f "$app/.invalid" ]]; then exit 1; fi\n/bin/echo TeamIdentifier=B3W25FX5H5 >&2\n')
        self.signer.chmod(0o755)

    def tearDown(self):
        self.tmp.cleanup()

    def run_installer(self, fail_registration=False):
        base = '''#!/bin/zsh
set -eu
TARGET_VOLUME=@@VOLUME@@
CONSOLE_UID=501
CONSOLE_USER=fixture
FX_FAILURE=0
fx_verify_app() {
  /bin/echo "$1" >> @@LOG@@
  if [[ "$1" == "$BG_NEW_APP" && @@FAIL@@ == 1 ]]; then return 1; fi
  return 0
}
trap - EXIT
fx_verify_app "${TARGET_VOLUME}/Library/Plug-Ins/FxPlug/FCP-BeautyGirl.app" || FX_FAILURE=1
if (( FX_FAILURE )); then exit 1; fi
exit 0
'''
        base = base.replace('@@VOLUME@@', shlex.quote(str(self.root))).replace('@@LOG@@', shlex.quote(str(self.root / 'registration-calls'))).replace('@@FAIL@@', '1' if fail_registration else '0')
        code = inject_migration(base)
        # Only signature and user-session registration are isolated. Identity
        # parsing, file moves, deletes, traps and rollback run unchanged.
        code = code.replace('/usr/bin/codesign', shlex.quote(str(self.signer)))
        code = code.replace('/bin/launchctl asuser', '/usr/bin/true asuser')
        script = self.root / 'postinstall'
        script.write_text(code)
        subprocess.run(['/bin/zsh', '-n', str(script)], check=True, capture_output=True)
        return subprocess.run(['/bin/zsh', str(script)], text=True, capture_output=True)

    def test_upgrade_keeps_new_and_removes_old_and_recovery_copy(self):
        self.assertEqual(self.run_installer().returncode, 0)
        self.assertTrue(self.new.exists())
        self.assertFalse(self.old.exists())
        self.assertFalse(list((self.root / 'Library/Application Support').rglob('*.app')))

    def test_registration_failure_restores_old_and_removes_new(self):
        original = (self.old / 'payload-byte').read_bytes()
        result = self.run_installer(True)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.new.exists())
        self.assertEqual((self.old / 'payload-byte').read_bytes(), original)
        self.assertIn(str(self.old), (self.root / 'registration-calls').read_text())

    def test_invalid_new_signature_does_not_touch_old(self):
        (self.new / '.invalid').touch()
        self.assertNotEqual(self.run_installer().returncode, 0)
        self.assertTrue(self.old.exists())

    def test_foreign_old_bundle_id_is_preserved(self):
        (self.old / 'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier': 'com.unrelated.product'}))
        self.assertNotEqual(self.run_installer().returncode, 0)
        self.assertTrue(self.old.exists())

    def test_invalid_old_signature_is_preserved(self):
        (self.old / '.invalid').touch()
        self.assertNotEqual(self.run_installer().returncode, 0)
        self.assertTrue(self.old.exists())

    def test_fresh_install_and_repeat_are_idempotent(self):
        import shutil
        shutil.rmtree(self.old)
        self.assertEqual(self.run_installer().returncode, 0)
        self.assertEqual(self.run_installer().returncode, 0)
        self.assertTrue(self.new.exists())

    def test_unrelated_neighbor_is_preserved(self):
        unrelated = self.old.parent / 'OtherProduct.app'
        unrelated.mkdir()
        self.assertEqual(self.run_installer().returncode, 0)
        self.assertTrue(unrelated.exists())

    @unittest.skipUnless(os.environ.get('FCP_BEAUTYGIRL_POSTINSTALL'), 'Final PKG is not built yet')
    def test_final_package_contains_the_tested_migration_block(self):
        actual = pathlib.Path(os.environ['FCP_BEAUTYGIRL_POSTINSTALL']).read_text()
        generated = inject_migration('\ntrap - EXIT\nfx_verify_app candidate\nexit 0\n')
        start = generated.index('# FCP-BeautyGirl identity migration.')
        end = generated.rindex('\nfx_verify_app ')
        self.assertIn(generated[start:end], actual)

if __name__ == '__main__':
    unittest.main()
