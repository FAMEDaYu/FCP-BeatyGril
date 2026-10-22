#!/usr/bin/env python3
"""Package the installed product with local PKG Forge, then sign/notarize its migration update."""
import argparse, datetime, hashlib, json, os, pathlib, plistlib, shutil, subprocess, sys
from installer_identity import inject_migration
from product_identity import PRODUCT, ROOT, delivery_locks, validate_app

def run(args, log=None, env=None):
    result = subprocess.run(args, cwd=ROOT, text=True, capture_output=True, env=env)
    if log:
        pathlib.Path(log).write_text(result.stdout + result.stderr)
    result.check_returncode()
    return result.stdout

version = PRODUCT['version']
work = ROOT / 'build' / ('package-' + version)
release = ROOT / 'releases' / version
proof = ROOT / 'docs/verification' / ('v' + version)
package_name = PRODUCT['name'] + '-' + version + '.pkg'
final = release / package_name
keychain = '/Users/dayu/Library/Keychains/login.keychain-db'
installer_identity = 'Developer ID Installer: zhong luo (B3W25FX5H5)'
cli = '/Applications/PKG工坊.app/Contents/MacOS/PKG工坊'
source_template = pathlib.Path('/Users/dayu/Movies/Motion Templates.localized/Effects.localized/大鱼磨皮瘦脸')
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--verify-existing', action='store_true', help='Resume verification of the already Accepted, stapled final package without rebuilding or resubmitting it.')
args = parser.parse_args()

with delivery_locks():
    if not args.verify_existing:
        if work.exists() or final.exists():
            raise SystemExit('Packaging work or final package already exists; inspect before retrying')
        work.mkdir(parents=True)
        release.mkdir(parents=True, exist_ok=True)
        proof.mkdir(parents=True, exist_ok=True)
        formal = pathlib.Path(PRODUCT['installationPath'])
        info = validate_app(formal, PRODUCT['bundleIdentifier'])
        assert info['CFBundleShortVersionString'] == version and info['CFBundleVersion'] == PRODUCT['build']
        assert installer_identity in run(['security', 'find-identity', '-v', '-p', 'basic', keychain])
        template = work / 'input/大鱼磨皮瘦脸'
        manifest = []
        for source in sorted(source_template.rglob('*')):
            if source.is_file() and source.name != '.DS_Store':
                target = template / source.relative_to(source_template)
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(source, target)
                if source.stat().st_flags & 2:
                    run(['chflags', 'uchg', str(target)])
                manifest.append({'file': str(source.relative_to(source_template)), 'sha256': hashlib.sha256(source.read_bytes()).hexdigest(), 'locked': bool(source.stat().st_flags & 2)})
        assert len(manifest) == 4 and len(list(template.rglob('*.moef'))) == 1
        base = work / 'base' / package_name
        base.parent.mkdir()
        print('PKG Forge: generating signed/notarized base installer from the formal APP and installed Motion category.', flush=True)
        run([cli, 'inspect', str(formal), str(template)], proof / 'pkgforge-inspect.txt')
        run([cli, 'package', '--name', PRODUCT['name'], '--version', version, '--identifier-prefix', 'com.dayu.fcppackage', '--signing-identity', installer_identity, '--notary-profile', 'codex-dayu-notary-B3W25FX5H5', '--keychain', keychain, '--output', str(base), str(formal), str(template)], proof / 'pkgforge.txt')
        run(['pkgutil', '--check-signature', str(base)])
        run(['xcrun', 'stapler', 'validate', str(base)])
        expanded = work / 'expanded'
        run(['pkgutil', '--expand', str(base), str(expanded)])
        script = expanded / 'Payload.pkg/Scripts/postinstall'
        script.write_text(inject_migration(script.read_text()))
        run(['/bin/zsh', '-n', str(script)])
        # PKG Forge owns the payload/template/update scripts. Only the product's
        # identity migration is added, then the complete result is signed afresh.
        unsigned = work / 'migration-unsigned.pkg'
        run(['pkgutil', '--flatten', str(expanded), str(unsigned)])
        run(['productsign', '--sign', installer_identity, '--keychain', keychain, '--timestamp', str(unsigned), str(final)], proof / 'pkg-signing.txt')
        print('Submitting the final migration installer to Apple notarization.', flush=True)
        result = json.loads(run(['xcrun', 'notarytool', 'submit', str(final), '--keychain-profile', 'codex-dayu-notary-B3W25FX5H5', '--keychain', keychain, '--wait', '--output-format', 'json']))
        (proof / 'pkg-notarization.json').write_text(json.dumps(result, indent=2) + '\n')
        if result.get('status') != 'Accepted':
            raise RuntimeError('Final migration package notarization was not Accepted')
        run(['xcrun', 'stapler', 'staple', str(final)], proof / 'pkg-staple.txt')
        run(['xcrun', 'stapler', 'validate', str(final)])
        run(['pkgutil', '--check-signature', str(final)], proof / 'pkg-signature.txt')
        run(['spctl', '-a', '-vv', '-t', 'install', str(final)], proof / 'pkg-gatekeeper.txt')
    else:
        if not work.exists() or not final.exists():
            raise RuntimeError('No prepared package to verify')
        formal = pathlib.Path(PRODUCT['installationPath'])
        info = validate_app(formal, PRODUCT['bundleIdentifier'])
        assert info['CFBundleShortVersionString'] == version and info['CFBundleVersion'] == PRODUCT['build']
        result = json.loads((proof / 'pkg-notarization.json').read_text())
        assert result['status'] == 'Accepted'
        run(['xcrun', 'stapler', 'validate', str(final)])
        run(['pkgutil', '--check-signature', str(final)])
        run(['spctl', '-a', '-vv', '-t', 'install', str(final)])
        template = work / 'input/大鱼磨皮瘦脸'
        manifest = [{'file': str(p.relative_to(template)), 'sha256': hashlib.sha256(p.read_bytes()).hexdigest(), 'locked': bool(p.stat().st_flags & 2)} for p in sorted(template.rglob('*')) if p.is_file()]
        assert len(manifest) == 4
    full = work / 'full'
    try:
        run(['pkgutil', '--expand-full', str(final), str(full)])
        run([sys.executable, 'scripts/verify-release-package.py', '--version', version, '--build', PRODUCT['build'], '--expanded', str(full), '--fixture', 'build/pkg-isolation-' + version], proof / 'pkg-verification-output.txt')
        env = dict(os.environ, FCP_BEAUTYGIRL_POSTINSTALL=str(full / 'Payload.pkg/Scripts/postinstall'))
        run([sys.executable, 'tests/installer_identity_tests.py'], proof / 'installer-tests.txt', env=env)
    finally:
        if full.exists():
            run(['chflags', '-R', 'nouchg', str(full)])
            shutil.rmtree(full)
    receipt = {'status': 'verified', 'version': version, 'build': PRODUCT['build'], 'package': str(final.relative_to(ROOT)), 'bytes': final.stat().st_size, 'sha256': hashlib.sha256(final.read_bytes()).hexdigest(), 'sourceApp': str(formal), 'sourceCommit': json.loads((ROOT / 'build/delivery/delivery-receipt.json').read_text())['source']['commit'], 'motionSource': str(source_template), 'motionFiles': manifest, 'packager': cli, 'productMigration': 'PKG Forge base plus identity-checked backup/rollback block; final package freshly signed, notarized and stapled', 'notarization': result, 'realInstallerExecuted': False}
    (proof / 'pkg-delivery.json').write_text(json.dumps(receipt, ensure_ascii=False, indent=2) + '\n')
    run(['chflags', '-R', 'nouchg', str(work)])
    shutil.rmtree(work)
    print(json.dumps(receipt, ensure_ascii=False), flush=True)
