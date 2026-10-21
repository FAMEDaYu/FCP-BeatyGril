#!/usr/bin/env python3
"""Verify an expanded release payload and run template-only update/rollback in isolation."""
from pathlib import Path
import hashlib,json,os,plistlib,shutil,subprocess,sys
root=Path(__file__).resolve().parent.parent
expanded=root/'build/pkg-expanded/Payload.pkg';payload=expanded/'Payload'
formal=Path('/Library/Plug-Ins/FxPlug/beatygril.app');packed=payload/'Library/Plug-Ins/FxPlug/beatygril.app'
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
def files(p):
 return {str(x.relative_to(p)):('symlink:'+os.readlink(x) if x.is_symlink() else sha(x)) for x in p.rglob('*') if x.is_file() or x.is_symlink()}
assert files(formal)==files(packed),'APP differs from signed installed product'
subprocess.run(['codesign','--verify','--deep','--strict',str(packed)],check=True)
subprocess.run(['xcrun','stapler','validate',str(packed)],check=True,capture_output=True)
source=root/'Templates/大鱼人像美化';template=next(payload.rglob('大鱼人像美化.moef')).parent
runtime=['大鱼人像美化.moef','Drop Zone.tiff','large.png','small.png']
assert sorted(x.name for x in template.iterdir())==sorted(runtime)
assert all(sha(source/n)==sha(template/n) for n in runtime)
post=(expanded/'Scripts/postinstall').read_text();pre=(expanded/'Scripts/preinstall').read_text()
for p in [expanded/'Scripts/postinstall',expanded/'Scripts/preinstall']:
 subprocess.run(['/bin/zsh','-n',str(p)],check=True)
locks=[l for l in post.splitlines() if l.startswith('/usr/bin/chflags uchg "${FINAL_TARGET}')]
assert len(locks)==2 and any('/large.png' in l for l in locks) and any('/small.png' in l for l in locks)
assert 'Template Backups' in post and 'restore_original_locks' in post
# Keep the exact generated functions and template body. Only identity lookup,
# chown and external FxPlug registration are replaced to confine execution.
base=root/'build/pkg-isolation';base.mkdir(exist_ok=False)
volume=base/'volume';home=base/'user';home.mkdir()
start=post.index('CURRENT_ACTIVE=0')
isolated='#!/bin/zsh\nset -eu\nTARGET_VOLUME="'+str(volume)+'"\nCONSOLE_USER="'+os.getlogin()+'"\nCONSOLE_UID="'+str(os.getuid())+'"\nCONSOLE_GROUP="staff"\nUSER_HOME="'+str(home)+'"\n'+post[start:]
isolated=isolated[:isolated.index('fx_verify_app "${TARGET_VOLUME%/}/Library/Plug-Ins/FxPlug/beatygril.app"')]+'exit 0\n'
isolated=isolated.replace('/usr/sbin/chown -R','/usr/bin/true')
new_copy=next(l for l in isolated.splitlines() if l.startswith('/usr/bin/ditto "${TARGET_VOLUME%/}'))
def refill():
 target=volume/template.parent.relative_to(payload)
 if target.exists():
  subprocess.run(['chflags','-R','nouchg',str(target)],check=True);shutil.rmtree(target)
 target.parent.mkdir(parents=True,exist_ok=True);shutil.copytree(template.parent,target,symlinks=True)
def run_script(name,text,success):
 p=base/name;p.write_text(text)
 proc=subprocess.run(['/bin/zsh',str(p)],text=True,capture_output=True)
 (base/(name+'.output')).write_text(proc.stdout+proc.stderr)
 assert (proc.returncode==0)==success,(name,proc.returncode,proc.stderr)
 return proc.returncode
final=home/'Movies/Motion Templates.localized/Effects.localized/大鱼磨皮瘦脸/大鱼人像美化'
refill();run_script('fresh-install.zsh',isolated,True)
assert all(sha(final/n)==sha(source/n) for n in runtime)
assert all((final/n).stat().st_flags & 2 for n in ['large.png','small.png'])
# Locked old images are overwritten, then protected again.
subprocess.run(['chflags','nouchg',str(final/'large.png')],check=True)
(final/'large.png').write_bytes(b'old locked thumbnail');subprocess.run(['chflags','uchg',str(final/'large.png')],check=True)
refill();run_script('update-locked.zsh',isolated,True)
assert all(sha(final/n)==sha(source/n) for n in runtime)
assert all((final/n).stat().st_flags & 2 for n in ['large.png','small.png'])
# Simulate a failed payload copy after corrupting one new file; the actual EXIT
# trap must restore the previous bytes and previous immutable flags.
original=files(final);refill()
failing=isolated.replace(new_copy,'/bin/echo partial > "${FINAL_TARGET}/大鱼人像美化/large.png"\n/usr/bin/false',1)
run_script('failed-copy-rollback.zsh',failing,False)
assert files(final)==original
assert all((final/n).stat().st_flags & 2 for n in ['large.png','small.png'])
backups=list((home/'Library/Application Support/PKGForge/Template Backups').rglob('.locked-paths'))
assert backups and all('/Movies/' not in str(x) for x in backups)
package=root/'releases/1.2.0/大鱼人像美化-1.2.0.pkg'
report={'package':str(package.relative_to(root)),'bytes':package.stat().st_size,'sha256':sha(package),'version':'1.2.0','build':'14','app_files_compared':len(files(formal)),'app_byte_and_symlink_equality':True,'template_files':{n:sha(template/n) for n in runtime},'locked_relative_paths':['大鱼人像美化/large.png','大鱼人像美化/small.png'],'script_sha256':{'preinstall':sha(expanded/'Scripts/preinstall'),'postinstall':sha(expanded/'Scripts/postinstall')},'isolated_script_tests':['fresh install','replace old locked thumbnail','partial copy failure restores old bytes and locks'],'isolation_changes':['Console identity/home redirected to task fixture','chown replaced with true','FxPlug verification skipped; formal app signature and discovery verified separately'],'real_installer_execution':False,'app_and_template_installed':'APP installed through signed delivery workflow; user thumbnail directory updated separately, not by running this PKG','fonts':'No editable third-party font dependency; promotional lettering baked into PNG. No optional font ZIP needed.'}
(root/'docs/verification/v1.2.0/pkg-verification.json').write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n');print(json.dumps(report,ensure_ascii=False,indent=2))
# This fixture belongs solely to this verifier; remove its locks before cleanup.
subprocess.run(['chflags','-R','nouchg',str(base)],check=True);shutil.rmtree(base)
