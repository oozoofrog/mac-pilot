#!/usr/bin/env python3
"""Build source-only Plugin zip assets from committed package files."""
from __future__ import annotations
import argparse
import hashlib
import json
import subprocess
import zipfile
from pathlib import Path
from validate_distribution import ROOT, NAMES, distributable, validate


def package(root: Path, output: Path):
    validate(root)
    if subprocess.check_output(['git','status','--porcelain','--untracked-files=normal'],cwd=root).strip():
        raise RuntimeError('Commit the reviewed source before packaging a release.')
    output.mkdir(parents=True,exist_ok=True)
    commit = subprocess.check_output(['git','rev-parse','HEAD'],cwd=root,text=True).strip()
    manifest = {'version':(root/'VERSION').read_text().strip(),'commit':commit,'packages':[]}
    records = subprocess.check_output(['git','ls-files','--stage','-z'],cwd=root).split(b'\0')
    for name in NAMES:
        version = json.loads((root/name/'.codex-plugin/plugin.json').read_text())['version']
        target = output/f'{name}-{version}.zip'
        with zipfile.ZipFile(target,'w',zipfile.ZIP_DEFLATED) as archive:
            for raw in filter(None,records):
                meta,rawpath = raw.split(b'\t',1); path = rawpath.decode(); mode = meta.split()[0].decode()
                if not path.startswith(name+'/'): continue
                if mode not in ('100644','100755') or not distributable(path): raise RuntimeError('Unsafe release input: '+path)
                entry = zipfile.ZipInfo(path, date_time=(2026,11,8,0,0,0)); entry.create_system = 3
                entry.external_attr = (int(mode,8) << 16); entry.compress_type = zipfile.ZIP_DEFLATED
                archive.writestr(entry,(root/path).read_bytes())
        digest = hashlib.sha256(target.read_bytes()).hexdigest()
        manifest['packages'].append({'name':name,'version':version,'file':target.name,'sha256':digest})
    (output/'SHA256SUMS').write_text(''.join(p['sha256']+'  '+p['file']+'\n' for p in manifest['packages']))
    (output/'release.json').write_text(json.dumps(manifest,indent=2)+'\n')
    print(json.dumps(manifest,indent=2)); return manifest


if __name__ == '__main__':
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--output',type=Path,default=Path('dist'))
    args=parser.parse_args();package(ROOT,args.output.resolve())
