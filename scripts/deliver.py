#!/usr/bin/env python3
"""Release, notarize and install the unique FxPlug app under its delivery lock.
The final prompt keeps the lock held while native-host validation is performed.
"""
import argparse, datetime, json, os, pathlib, plistlib, shutil, subprocess, sys, time
root=pathlib.Path(__file__).resolve().parent.parent
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--wait-for-hosts',action='store_true',help='After notarization, retain the delivery lock and wait for Motion/FCP to exit naturally before installing; never control or quit either host.')
parser.add_argument('--user-tests',action='store_true',help='After non-UI installed-app verification, record native effect QA as pending user testing and clean known generated copies without the interactive validation prompt.')
args=parser.parse_args()
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
receipt_path=logs/'delivery-receipt.json'
receipt={'status':'preparing','bundleIdentifier':bundle_id,'installationPath':str(installed),
         'options':{'waitForHosts':args.wait_for_hosts,'userTests':args.user_tests},
         'nativeEffectQA':{'status':'pending_user' if args.user_tests else 'pending_operator','performedByScript':False}}
def run(args, log=None):
    if log:
        with open(log,'w') as output:subprocess.run(args,cwd=root,stdout=output,stderr=subprocess.STDOUT,check=True)
        return ''
    return subprocess.run(args,cwd=root,text=True,capture_output=True,check=True).stdout
def save_receipt(status,**fields):
    receipt.update(fields);receipt['status']=status
    receipt['updatedAt']=datetime.datetime.now(datetime.timezone.utc).isoformat()
    receipt_path.write_text(json.dumps(receipt,ensure_ascii=False,indent=2)+'\n')
def running_hosts():
    # Read process state only. Match executable suffixes so renamed installation
    # roots do not accidentally allow replacing a live host's plug-in connection.
    suffixes=('/Motion.app/Contents/MacOS/Motion','/Final Cut Pro.app/Contents/MacOS/Final Cut Pro')
    found=[]
    for line in run(['ps','-axo','pid=,comm=']).splitlines():
        columns=line.strip().split(None,1)
        if len(columns)==2 and columns[1].endswith(suffixes):found.append({'pid':int(columns[0]),'executable':columns[1]})
    return found
def await_host_exit():
    active=running_hosts()
    if active and not args.wait_for_hosts:
        raise RuntimeError('Close Motion and Final Cut Pro before installing; installed app retained')
    if active:
        save_receipt('waiting_for_host_exit',runningHosts=active)
        print('HOST_EXIT_REQUIRED: Motion/Final Cut Pro must exit naturally before installation. The delivery lock remains held; no host/UI action will be taken.',flush=True)
        while active:
            time.sleep(3)
            active=running_hosts()
        print('HOSTS_EXITED: continuing with installation under the same delivery lock.',flush=True)
    save_receipt('ready_to_install',runningHosts=[])
def require_product(path):
    info=plistlib.loads((path/'Contents/Info.plist').read_bytes())
    if info.get('CFBundleIdentifier')!=bundle_id:raise RuntimeError('Generated/installed app identity mismatch: '+str(path))
    return info
def cleanup_known_products():
    removed=[]
    if previous.exists():
        require_product(previous);shutil.rmtree(previous);removed.append(str(previous))
    if staging.exists():
        if app.exists():require_product(app)
        shutil.rmtree(staging);removed.append(str(staging))
    if archive.exists():archive.unlink();removed.append(str(archive))
    return removed
try:
    receipt['source']={'commit':run(['git','rev-parse','HEAD']).strip(),
                       'trackedWorktreeChanges':run(['git','status','--porcelain','--untracked-files=no']).splitlines()}
    save_receipt('building')
    identities=run(['security','find-identity','-v','-p','codesigning',keychain])
    if identity not in identities:raise RuntimeError('Valid Developer ID Application identity is unavailable')
    print('Building universal Release…',flush=True)
    run(['xcodebuild','-project','beatygril/beatygril.xcodeproj','-scheme','Wrapper Application','-configuration','Release','-derivedDataPath',str(staging),'-destination','generic/platform=macOS','build'],logs/'build.log')
    plugin=app/'Contents/PlugIns/beatygril XPC Service.pluginkit'
    # Xcode can register a fresh build. Remove this known generated path before
    # lengthy signing/notarization while a user may still be testing the old app.
    run(['pluginkit','-r',str(plugin)])
    for framework in sorted((plugin/'Contents/Frameworks').glob('*.framework')):
        run(['codesign','--force','--timestamp','--options','runtime','--sign',identity,str(framework)])
    run(['codesign','--force','--timestamp','--options','runtime','--sign',identity,str(plugin)])
    run(['codesign','--force','--timestamp','--options','runtime','--entitlements',str(root/'beatygril/beatygril/Wrapper Application/SandboxEntitlements.entitlements'),'--sign',identity,str(app)])
    run(['codesign','--verify','--deep','--strict',str(app)])
    info=require_product(app)
    receipt['version']=info.get('CFBundleShortVersionString');receipt['build']=info.get('CFBundleVersion')
    receipt['stagingSignature']=subprocess.run(['codesign','-dvvv',str(app)],capture_output=True,text=True,check=True).stderr
    run(['ditto','-c','-k','--keepParent',str(app),str(archive)])
    print('Submitting signed app to Apple notarization…',flush=True)
    response=run(['xcrun','notarytool','submit',str(archive),'--keychain-profile','codex-dayu-notary-B3W25FX5H5','--keychain',keychain,'--wait','--output-format','json'])
    (logs/'notarization.json').write_text(response)
    result=json.loads(response)
    receipt['notarization']=result
    if result.get('status')!='Accepted':
        if result.get('id'):
            (logs/'notarization-details.json').write_text(run(['xcrun','notarytool','log',result['id'],'--keychain-profile','codex-dayu-notary-B3W25FX5H5','--keychain',keychain]))
        raise RuntimeError('Apple did not accept notarization; original installed app retained')
    run(['xcrun','stapler','staple',str(app)])
    run(['xcrun','stapler','validate',str(app)])
    # Keep a prepared build out of host discovery while the user still has the
    # old installed version open. This removes only this known staging path.
    run(['pluginkit','-r',str(plugin)])
    save_receipt('prepared',signingVerified=True,stapleValidated=True,stagingPluginUnregistered=True)
    # A live host retains its old XPC/OSC connection. Replacing the bundle while
    # that connection exists can deadlock host shutdown or select stale code.
    await_host_exit()
    if installed.exists():
        require_product(installed)
        if previous.exists():raise RuntimeError('Previous recovery app already exists')
    # Recheck immediately before touching the installed bundle. Waiting mode does
    # not grant permission for a hot replacement if a host was opened again.
    await_host_exit()
    save_receipt('installing')
    if installed.exists():
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
        # Xcode may register its build product. Only the installed plugin should
        # be discoverable while native host validation is in progress.
        run(['pluginkit','-r',str(plugin)])
        installed_plugin=installed/'Contents/PlugIns/beatygril XPC Service.pluginkit'
        plugin_info=plistlib.loads((installed_plugin/'Contents/Info.plist').read_bytes())
        discovered=run(['pluginkit','-m','-A','-D','-v','-i',plugin_info['CFBundleIdentifier']])
        if str(installed_plugin) not in discovered:raise RuntimeError('PluginKit did not report the formal installed plug-in path')
        (logs/'installed-discovery.txt').write_text(discovered)
        save_receipt('installed',installedSignature=signature,installedSignatureVerified=True,
                     installedStapleValidated=True,gatekeeperAccepted=True,
                     pluginDiscovery={'bundleIdentifier':plugin_info['CFBundleIdentifier'],'formalPath':str(installed_plugin),'output':discovered})
    except Exception:
        if installed.exists():shutil.rmtree(installed)
        if previous.exists():shutil.move(str(previous),str(installed))
        raise
    print(json.dumps({'status':'installed','path':str(installed),'notarization':result}),flush=True)
    if args.user_tests:
        print('USER_TESTS_PENDING: installed identity, ticket, Gatekeeper and formal-path discovery verified. Native effect QA is left to the user; no host/UI operation was performed.',flush=True)
    else:
        input('HOST_VALIDATION_PENDING: press Return only after host verification and duplicate inventory.\n')
        receipt['nativeEffectQA']={'status':'operator_confirmed','performedByScript':False}
    # Only this task’s known generated product copies are removed.
    removed=cleanup_known_products()
    save_receipt('installed_user_qa_pending' if args.user_tests else 'complete',removedGeneratedPaths=removed)
    print('Delivery staging and notarization archive cleaned.',flush=True)
except BaseException as error:
    save_receipt('failed',failure={'type':type(error).__name__,'message':str(error)})
    raise
finally:
    (lock/'owner.json').unlink();lock.rmdir()
