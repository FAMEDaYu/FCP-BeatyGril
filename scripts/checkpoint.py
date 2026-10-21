#!/usr/bin/env python3
"""Save only explicitly listed project files, under the shared dayu Git lock."""
import argparse, hashlib, json, os, pathlib, subprocess, time
p=argparse.ArgumentParser();p.add_argument('message');p.add_argument('files',nargs='+');p.add_argument('--tag');a=p.parse_args()
root=pathlib.Path(__file__).resolve().parent.parent
run=lambda *args,**kw:subprocess.run(args,cwd=root,check=True,text=True,**kw)
remote=run('git','remote','get-url','origin',capture_output=True).stdout.strip()
if not remote.startswith('https://dayu.media/git/') or '@' in remote:raise SystemExit('Unexpected project remote')
lock=pathlib.Path('/Users/dayu/.codex/git-backup-locks')/(hashlib.sha256(remote.lower().rstrip('/').encode()).hexdigest()+'.lock')
lock.parent.mkdir(parents=True,exist_ok=True)
for n in range(120):
    try:lock.mkdir();break
    except FileExistsError:
        if n==119:raise SystemExit('Repository lock still held; inspect owner.json')
        time.sleep(.5)
(lock/'owner.json').write_text(json.dumps({'pid':os.getpid(),'cwd':str(root),'remote':remote}))
try:
    run('git','add','--',*a.files)
    run('git','diff','--cached','--check')
    run('git','diff','--cached','--stat')
    changed=subprocess.run(['git','diff','--cached','--quiet'],cwd=root).returncode
    if changed:run('git','commit','-m',a.message)
    branch=run('git','branch','--show-current',capture_output=True).stdout.strip()
    if not branch:raise SystemExit('Detached HEAD: create a durable branch before saving')
    run('git','push','-u','origin',branch)
    sha=run('git','rev-parse','HEAD',capture_output=True).stdout.strip()
    observed=run('git','ls-remote','origin','refs/heads/'+branch,capture_output=True).stdout.split()[0]
    if observed!=sha:raise SystemExit('Remote checkpoint SHA mismatch')
    if a.tag:
        run('git','tag',a.tag)
        run('git','push','origin','refs/tags/'+a.tag)
        observed=run('git','ls-remote','origin','refs/tags/'+a.tag,capture_output=True).stdout.split()[0]
        if observed!=sha:raise SystemExit('Remote tag SHA mismatch')
    print(json.dumps({'branch':branch,'sha':sha,'remote_verified':True,'tag':a.tag}))
finally:
    (lock/'owner.json').unlink();lock.rmdir()
