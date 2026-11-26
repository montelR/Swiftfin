import json,subprocess,sys
from pathlib import Path
packages,out,expected=map(Path,sys.argv[1:])
pins={x['identity']:x['state']['revision'] for x in json.loads((out/'Package.resolved').read_text())['pins']}
required=json.loads(expected.read_text())['tvos']
actual={}
for d in json.loads((packages/'workspace-state.json').read_text())['object']['dependencies']:
 rev=d['state'].get('checkoutState',{}).get('revision')
 if not rev: continue
 name=d['packageRef']['identity'].lower()
 p=packages/'checkouts'/d['subpath']
 def git(*args):return subprocess.check_output(['git','-C',str(p),*args],text=True).strip()
 assert pins[name]==rev==git('rev-parse','HEAD'), name
 assert not git('status','--porcelain','--untracked-files=no'),name
 actual[name]=rev
assert all(actual.get(k)==v for k,v in required.items()),set(required)-set(actual)
(out/'simulator-checkout-revisions.json').write_text(json.dumps(actual,indent=2)+'\n')
print(f'PASS: {len(actual)} pinned actual simulator dependency checkouts')
