import sys,subprocess,re,json
from pathlib import Path
derived,out=map(Path,sys.argv[1:])
names=('SwiftfinMacrosPlugin','CasePathsMacros','StatefulMacrosMacros')
data={}
for name in names:
 data[name]=[]
 for p in sorted((derived/'Build/Products').rglob(name)):
  if not p.is_file():continue
  r=subprocess.run(['xcrun','vtool','-show-build',str(p)],capture_output=True,text=True)
  data[name].append({'path':str(p),'rc':r.returncode,'metadata':r.stdout,'stderr':r.stderr})
(out/'macro-platform-metadata.json').write_text(json.dumps(data,indent=2)+'\n')
for n,items in data.items():
 assert items and all(x['rc']==0 and re.search(r'\bplatform\s+MACOS\b',x['metadata'],re.I) for x in items), (n,items)
print('PASS: three previously failing macro executables have macOS Mach-O platform metadata')
