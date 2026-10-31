"""Refresh hashes for the currently staged release files; no hardware access."""
from pathlib import Path
import hashlib,json,subprocess
ROOT=Path(__file__).resolve().parents[1]
names=subprocess.check_output(['git','ls-files','-z'],cwd=ROOT).decode('utf-8').split('\0')
files={name:hashlib.sha256((ROOT/name).read_bytes()).hexdigest() for name in names
       if name and name!='checksums.json' and (ROOT/name).is_file()}
(ROOT/'checksums.json').write_text(json.dumps({'version':'V047','algorithm':'SHA256',
   'sha256':dict(sorted(files.items()))},ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
print('CHECKSUMS_WRITTEN',len(files))
