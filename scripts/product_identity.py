"""Shared product identity and reversible, identity-checked legacy APP migration."""
import contextlib, json, os, pathlib, plistlib, shutil, subprocess

ROOT = pathlib.Path(__file__).resolve().parent.parent
PRODUCT = json.loads((ROOT / 'product.json').read_text())

def validate_app(path, bundle_id, team=PRODUCT['teamIdentifier']):
    path = pathlib.Path(path)
    info = plistlib.loads((path / 'Contents/Info.plist').read_bytes())
    if info.get('CFBundleIdentifier') != bundle_id:
        raise RuntimeError('APP identity mismatch: ' + str(path))
    subprocess.run(['codesign', '--verify', '--all-architectures', '--deep', '--strict', str(path)], check=True, capture_output=True)
    signature = subprocess.run(['codesign', '-dvvv', str(path)], check=True, text=True, capture_output=True).stderr
    if ('TeamIdentifier=' + team) not in signature:
        raise RuntimeError('APP signing team mismatch: ' + str(path))
    plugins = list((path / 'Contents/PlugIns').glob('*.pluginkit'))
    if not any(PRODUCT['filterUUID'] in [p.get('uuid') for p in plistlib.loads((plugin / 'Contents/Info.plist').read_bytes()).get('ProPlugPlugInList', [])] for plugin in plugins):
        raise RuntimeError('APP does not contain this product filter UUID: ' + str(path))
    return info

@contextlib.contextmanager
def delivery_locks(product=PRODUCT):
    """Hold both old and new identity locks throughout an identity migration."""
    base = pathlib.Path('/Users/dayu/.codex/app-delivery-locks')
    base.mkdir(parents=True, exist_ok=True)
    held = []
    try:
        for bundle_id in sorted({product['bundleIdentifier']} | {p['bundleIdentifier'] for p in product.get('legacyProducts', [])}):
            lock = base / (bundle_id + '.lock')
            lock.mkdir()
            held.append(lock)
            (lock / 'owner.json').write_text(json.dumps({'pid': os.getpid(), 'cwd': str(ROOT), 'bundle_id': bundle_id, 'product': product['name']}))
        yield
    finally:
        for lock in reversed(held):
            (lock / 'owner.json').unlink(missing_ok=True)
            lock.rmdir()

class LegacyMigration:
    def __init__(self, backup_root, *, product=PRODUCT, volume=pathlib.Path('/'), verifier=validate_app):
        self.product, self.backup_root, self.verifier = product, pathlib.Path(backup_root), verifier
        self.volume, self.moved = pathlib.Path(volume), []

    def candidates(self):
        result = []
        for legacy in self.product.get('legacyProducts', []):
            source = self.volume / pathlib.Path(legacy['installationPath']).relative_to('/')
            if source.exists():
                self.verifier(source, legacy['bundleIdentifier'])
                backup = self.backup_root / ('legacy-' + legacy['name'] + '.app')
                if backup.exists():
                    raise RuntimeError('Legacy recovery copy already exists: ' + str(backup))
                result.append((legacy, source, backup))
        return result

    def relocate(self, unregister):
        # Validate every candidate before moving any of them.
        for legacy, source, backup in self.candidates():
            self.verifier(source, legacy['bundleIdentifier'])
            unregister(source / 'Contents/PlugIns' / legacy['pluginName'])
            backup.parent.mkdir(parents=True, exist_ok=True)
            shutil.move(str(source), str(backup))
            self.moved.append((legacy, source, backup))

    def rollback(self, register):
        for legacy, source, backup in reversed(self.moved):
            if source.exists():
                raise RuntimeError('Refusing to overwrite a new APP during rollback: ' + str(source))
            self.verifier(backup, legacy['bundleIdentifier'])
            shutil.move(str(backup), str(source))
            register(source / 'Contents/PlugIns' / legacy['pluginName'])
        self.moved.clear()

    def cleanup(self):
        removed = []
        for legacy, source, backup in self.moved:
            self.verifier(backup, legacy['bundleIdentifier'])
            shutil.rmtree(backup)
            removed.append(str(backup))
        self.moved.clear()
        return removed
