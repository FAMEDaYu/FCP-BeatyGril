import importlib.util, json, pathlib, plistlib, subprocess, tempfile, unittest
from unittest.mock import patch

ROOT = pathlib.Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location('product_identity', ROOT / 'scripts/product_identity.py')
identity = importlib.util.module_from_spec(spec)
spec.loader.exec_module(identity)

class IdentityMigrationTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='beautygirl-identity-test.')
        self.volume = pathlib.Path(self.tmp.name)
        self.legacy = identity.PRODUCT['legacyProducts'][0]
        self.old = self.volume / pathlib.Path(self.legacy['installationPath']).relative_to('/')
        (self.old / 'Contents/PlugIns' / self.legacy['pluginName'] / 'Contents').mkdir(parents=True)
        (self.old / 'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier': self.legacy['bundleIdentifier']}))
        (self.old / 'Contents/PlugIns' / self.legacy['pluginName'] / 'Contents/Info.plist').write_bytes(plistlib.dumps({'ProPlugPlugInList': [{'uuid': identity.PRODUCT['filterUUID']}]}))
        self.signature = patch.object(identity.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0, '', 'TeamIdentifier=B3W25FX5H5\n'))
        self.signature.start()
        self.migration = identity.LegacyMigration(self.volume / 'backups', volume=self.volume)

    def tearDown(self):
        self.signature.stop()
        self.tmp.cleanup()

    def test_success_removes_only_validated_old_product(self):
        original = (self.old / 'Contents/Info.plist').read_bytes()
        unrelated = self.old.parent / 'Unrelated.app'
        unrelated.mkdir()
        calls = []
        self.migration.relocate(calls.append)
        self.assertFalse(self.old.exists())
        self.assertEqual(len(calls), 1)
        self.assertEqual((self.migration.moved[0][2] / 'Contents/Info.plist').read_bytes(), original)
        self.assertEqual(len(self.migration.cleanup()), 1)
        self.assertTrue(unrelated.exists())

    def test_failed_new_install_restores_old_bytes_and_registration(self):
        original = (self.old / 'Contents/Info.plist').read_bytes()
        self.migration.relocate(lambda p: None)
        calls = []
        self.migration.rollback(calls.append)
        self.assertEqual((self.old / 'Contents/Info.plist').read_bytes(), original)
        self.assertEqual(calls, [self.old / 'Contents/PlugIns' / self.legacy['pluginName']])

    def test_wrong_bundle_id_is_never_moved(self):
        (self.old / 'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier': 'com.unrelated.product'}))
        with self.assertRaisesRegex(RuntimeError, 'identity mismatch'):
            self.migration.relocate(lambda p: self.fail('Must not deregister another product'))
        self.assertTrue(self.old.exists())

    def test_wrong_filter_uuid_is_never_moved(self):
        (self.old / 'Contents/PlugIns' / self.legacy['pluginName'] / 'Contents/Info.plist').write_bytes(plistlib.dumps({'ProPlugPlugInList': []}))
        with self.assertRaisesRegex(RuntimeError, 'filter UUID'):
            self.migration.relocate(lambda p: self.fail('Must not deregister another filter'))
        self.assertTrue(self.old.exists())

    def test_invalid_signature_keeps_original(self):
        with patch.object(identity.subprocess, 'run', side_effect=subprocess.CalledProcessError(1, 'codesign')):
            with self.assertRaises(subprocess.CalledProcessError):
                self.migration.relocate(lambda p: self.fail('Unverified APP must remain'))
        self.assertTrue(self.old.exists())

    def test_existing_backup_cannot_be_overwritten(self):
        backup = self.volume / 'backups' / ('legacy-' + self.legacy['name'] + '.app')
        backup.mkdir(parents=True)
        with self.assertRaisesRegex(RuntimeError, 'already exists'):
            self.migration.relocate(lambda p: self.fail('Recovery copy must be preserved'))
        self.assertTrue(self.old.exists())

    def test_failed_deregistration_keeps_old_installation(self):
        def unavailable(path):
            raise RuntimeError('registry unavailable')
        with self.assertRaisesRegex(RuntimeError, 'registry unavailable'):
            self.migration.relocate(unavailable)
        self.assertTrue(self.old.exists())

    def test_project_and_legacy_template_share_stable_filter_identity(self):
        p = identity.PRODUCT
        pbx = (ROOT / p['xcodeProject'] / 'project.pbxproj').read_text()
        self.assertEqual(pbx.count('PRODUCT_BUNDLE_IDENTIFIER = ' + p['bundleIdentifier'] + ';'), 2)
        self.assertEqual(pbx.count('PRODUCT_BUNDLE_IDENTIFIER = ' + p['pluginBundleIdentifier'] + ';'), 2)
        self.assertNotIn('beatygril', pbx)
        plugin = plistlib.loads((ROOT / p['sourceDirectory'] / 'Plugin/Info.plist').read_bytes())
        self.assertEqual(plugin['ProPlugPlugInList'][0]['className'], p['pluginClass'])
        self.assertEqual(plugin['ProPlugPlugInList'][0]['uuid'], p['filterUUID'])
        self.assertEqual(plugin['CFBundleShortVersionString'], p['version'])
        self.assertIn('pluginUUID="' + p['filterUUID'] + '"', (ROOT / 'Templates/大鱼人像美化/大鱼人像美化.moef').read_text())

if __name__ == '__main__':
    unittest.main()
