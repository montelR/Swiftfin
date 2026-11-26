import hashlib,json,plistlib,re,subprocess,sys
from pathlib import Path
key,packages,archive,out,expected,minimum=sys.argv[1:]
packages,archive,out,expected=map(Path,(packages,archive,out,expected))
def run(*args):return subprocess.check_output(args,text=True)
def save(name,text): (out/name).write_text(text)
pins={p['identity']:p['state']['revision'] for p in json.loads((out/'Package.resolved').read_text())['pins']}
required=json.loads(expected.read_text())[key]
actual={}
for d in json.loads((packages/'workspace-state.json').read_text())['object']['dependencies']:
    rev=d['state'].get('checkoutState',{}).get('revision')
    if not rev:continue
    name=d['packageRef']['identity'].lower()
    p=packages/'checkouts'/d['subpath']
    head=run('git','-C',str(p),'rev-parse','HEAD').strip()
    assert pins[name]==rev==head,name
    assert not run('git','-C',str(p),'status','--porcelain','--untracked-files=no').strip(),name
    actual[name]=head
assert all(actual.get(k)==v for k,v in required.items()),set(required)-set(actual)
save('checkout-revisions.json',json.dumps(actual,indent=2)+'\n')
apps=list((archive/'Products/Applications').glob('*.app'));assert len(apps)==1,apps
app=apps[0];info=plistlib.loads((app/'Info.plist').read_bytes())
exe=app/info['CFBundleExecutable']
arch=run('xcrun','lipo','-archs',str(exe)).strip()
headers=run('xcrun','vtool','-show-build',str(exe))
deps=run('xcrun','otool','-L',str(exe))
load=run('xcrun','otool','-l',str(exe))
save('macho-build.txt',headers);save('dylibs.txt',deps);save('load-commands.txt',load)
save('Info.plist.json',json.dumps(info,default=str,indent=2))
assert arch=='arm64',arch
assert re.search(r'\bplatform\s+'+('IOS' if key=='ios' else 'TVOS')+r'\b',headers,re.I),headers
assert re.search(r'\bminos\s+'+re.escape(minimum)+r'(?:\.0)?\s',headers),headers
sdk='27.1' if key=='ios' else '27.0'
assert re.search(r'\bsdk\s+'+re.escape(sdk)+r'(?:\.0)?\s',headers),headers
assert info['MinimumOSVersion']==minimum,info.get('MinimumOSVersion')
assert info['DTSDKName']==('iphoneos' if key=='ios' else 'appletvos')+sdk,info.get('DTSDKName')
assert (app/'PrivacyInfo.xcprivacy').is_file()
assert (app/'Assets.car').is_file()
assert (app/'Frameworks/Libmpv.framework/Libmpv').is_file()
if key=='ios':assert (app/'Frameworks/GoogleCast.framework/GoogleCast').is_file()
for ref in re.findall(r'^\s+(@rpath/\S+)',deps,re.M):
    path=ref.removeprefix('@rpath/')
    assert (app/'Frameworks'/path).exists() or (app/path).exists(),ref
for f in app.rglob('*.car'):
    save('assetutil-'+str(f.relative_to(app)).replace('/','_')+'.json',run('xcrun','assetutil','--info',str(f)))
# Apple's assetutil inventory is preserved in full; no invented rendition names.
catalog=json.loads((out/'assetutil-Assets.car.json').read_text())
assert len(catalog)>1
names=sorted({str(x[k]) for x in catalog if isinstance(x,dict) for k in ('Name','RenditionName') if k in x})
save('asset-names.json',json.dumps(names,indent=2))
save('bundle-inventory.json',json.dumps({str(p.relative_to(app)):{'size':p.stat().st_size,'sha256':hashlib.file_digest(p.open('rb'),'sha256').hexdigest()} for p in sorted(app.rglob('*')) if p.is_file()},indent=2))
save('archive-summary.json',json.dumps({'scheme':key,'architecture':arch,'sdk':sdk,'minimum':minimum,'pins':len(actual),'required_pins':len(required),'asset_entries':len(catalog),'asset_names':len(names),'bundle_id':info['CFBundleIdentifier'],'executable_sha256':hashlib.file_digest(exe.open('rb'),'sha256').hexdigest(),'localizations':sorted(p.name for p in app.glob('*.lproj'))},indent=2))
print('PASS archive architecture, platform, SDK, minimum, dependency revisions, resource inventory and framework references')
