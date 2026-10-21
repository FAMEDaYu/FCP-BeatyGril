#!/usr/bin/env python3
"""Release, notarize and install the unique FxPlug app under its delivery lock.
The final prompt keeps the lock held while native-host validation is performed.
"""
import json, os, pathlib, plistlib, shutil, subprocess, sys, time
root=pathlib.Path(__file__).resolve().parent.parent
bundle_id='com.dayu.beatygril'
lock=pathlib.Path('/Users/dayu/.codex/app-delivery-locks')/(bundle_id+'.lock')
lock.parent.mkdir(parents=True,exist_ok=True)
try:lock.mkdir()
except FileExistsError:raise SystemExit('Delivery lock occupied; inspect owner.json and the owner process')
(lock/'owner.json').write_text(json.dumps({'pid':os.getpid(),'cwd':str(root),'bundle_id':bundle_id}))
staging=pathlib.Path('/tmp/paintfcp-build-20261021')
logs=root/'build'/'delivery';logs.mkdir(parents=True,exist_ok=True)
app=staging/'Build/Products/Release/beatygril.app'
installed=pathlib.Path('/Library/Plug-Ins/FxPlug/beatygril.app')
archive=logs/'notarization.zip'
identity='Developer ID Application: zhong luo (B3W25FX5H5)'
keychain='/Users/dayu/Library/Keychains/login.keychain-db'
previous=logs/'previous-beatygril.app'
def run(args, log=None):
    if log:
        with open(log,'w') as output:subprocess.run(args,cwd=root,stdout=output,stderr=subprocess.STDOUT,check=True)
        return ''
    return subprocess.run(args,cwd=root,text=True,capture_output=True,check=True).stdout
try:
    identities=run(['security','find-identity','-v','-p','codesigning',keychain])
    if identity not in identities:raise RuntimeError('Valid Developer ID Application identity is unavailable')
    print('Building universal Release…',flush=True)
    run(['xcodebuild','-project','beatygril/beatygril.xcodeproj','-scheme','Wrapper Application','-configuration','Release','-derivedDataPath',str(staging),'-destination','generic/platform=macOS','build'],logs/'build.log')
    plugin=app/'Contents/PlugIns/beatygril XPC Service.pluginkit'
    for framework in sorted((plugin/'Contents/Frameworks').glob('*.framework')):
        run(['codesign','--force','--timestamp','--options','runtime','--sign',identity,str(framework)])
    run(['codesign','--force','--timestamp','--options','runtime','--sign',identity,str(plugin)])
    run(['codesign','--force','--timestamp','--options','runtime','--entitlements',str(root/'beatygril/beatygril/Wrapper Application/SandboxEntitlements.entitlements'),'--sign',identity,str(app)])
    run(['codesign','--verify','--deep','--strict',str(app)])
    run(['ditto','-c','-k','--keepParent',str(app),str(archive)])
    print('Submitting signed app to Apple notarization…',flush=True)
    response=run(['xcrun','notarytool','submit',str(archive),'--keychain-profile','codex-dayu-notary-B3W25FX5H5','--keychain',keychain,'--wait','--output-format','json'])
    (logs/'notarization.json').write_text(response)
    result=json.loads(response)
    if result.get('status')!='Accepted':
        if result.get('id'):
            (logs/'notarization-details.json').write_text(run(['xcrun','notarytool','log',result['id'],'--keychain-profile','codex-dayu-notary-B3W25FX5H5','--keychain',keychain]))
        raise RuntimeError('Apple did not accept notarization; original installed app retained')
    run(['xcrun','stapler','staple',str(app)])
    run(['xcrun','stapler','validate',str(app)])
    if installed.exists():
        info=plistlib.loads((installed/'Contents/Info.plist').read_bytes())
        if info.get('CFBundleIdentifier')!=bundle_id:raise RuntimeError('The installation path belongs to another product')
        if previous.exists():raise RuntimeError('Previous recovery app already exists')
        shutil.move(str(installed),str(previous))
    try:
        shutil.copytree(app,installed,symlinks=True)
        run(['codesign','--verify','--deep','--strict',str(installed)])
        run(['xcrun','stapler','validate',str(installed)])
        run(['spctl','--assess','--type','execute','--verbose=2',str(installed)])
        info=plistlib.loads((installed/'Contents/Info.plist').read_bytes())
        signature=subprocess.run(['codesign','-dvvv',str(installed)],capture_output=True,text=True,check=True).stderr
        if info.get('CFBundleIdentifier')!=bundle_id or 'TeamIdentifier=B3W25FX5H5' not in signature:raise RuntimeError('Installed app identity mismatch')
        (logs/'installed-signature.txt').write_text(signature)
        run(['pluginkit','-a',str(installed/'Contents/PlugIns/beatygril XPC Service.pluginkit')])
    except Exception:
        if installed.exists():shutil.rmtree(installed)
        if previous.exists():shutil.move(str(previous),str(installed))
        raise
    print(json.dumps({'status':'installed','path':str(installed),'notarization':result}),flush=True)
    input('HOST_VALIDATION_PENDING: press Return only after host verification and duplicate inventory.\n')
    # Only this task’s known generated product copies are removed.
    if previous.exists():shutil.rmtree(previous)
    if archive.exists():archive.unlink()
    if staging.exists():shutil.rmtree(staging)
    print('Delivery staging and notarization archive cleaned.',flush=True)
finally:
    (lock/'owner.json').unlink();lock.rmdir()
