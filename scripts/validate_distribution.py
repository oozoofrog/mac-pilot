#!/usr/bin/env python3
"""Validate the two canonical Plugin packages and their marketplace contracts."""
from __future__ import annotations
import json
import re
import subprocess
from pathlib import Path
from urllib.parse import unquote, urlsplit

ROOT = Path(__file__).resolve().parents[1]
NAMES = ('mac-computer-use', 'simulator-pilot')
REPOSITORY = 'https://github.com/oozoofrog/mac-pilot'
EXCLUDED = {'__pycache__', 'browser-profile', 'always-allow.txt', '.DS_Store'}


def distributable(path: str) -> bool:
    p = Path(path)
    return (p.parts[0] in NAMES and not any(part in EXCLUDED for part in p.parts)
            and not path.startswith('mac-computer-use/docs/development/')
            and not path.endswith(('.pyc', '.pyo', '.new'))
            and path not in ('mac-computer-use/skills/mac-computer-use/scripts/mac-cu',
                             'mac-computer-use/skills/mac-computer-use/scripts/focus-overlay'))


def local_targets(markdown: str):
    lines = []; fence = None
    for line in markdown.splitlines():
        marker = re.match(r'^\s{0,3}(`{3,}|~{3,})', line)
        if marker:
            value = marker[1]
            if fence is None: fence = value
            elif value[0] == fence[0] and len(value) >= len(fence): fence = None
            continue
        if fence is None: lines.append(line)
    text = re.sub(r'(`+).*?\1', '', '\n'.join(lines))
    destinations = re.findall(r'!?\[[^\]\n]*\]\(\s*(<[^>\n]+>|[^\s)]+)', text)
    destinations += re.findall(r'(?m)^\s{0,3}\[[^\]\n]+\]:\s*(<[^>\n]+>|\S+)', text)
    for destination in destinations:
        url = urlsplit(destination.strip('<>'))
        if not url.scheme and not url.netloc and url.path: yield unquote(url.path)


def validate(root: Path = ROOT):
    catalog = json.loads((root/'.agents/plugins/marketplace.json').read_text())
    claude = json.loads((root/'.claude-plugin/marketplace.json').read_text())
    assert catalog['name'] == claude['name'] == 'mac-pilot'
    assert [p['name'] for p in catalog['plugins']] == list(NAMES)
    assert [p['name'] for p in claude['plugins']] == list(NAMES)
    readme = (root/'README.md').read_text()
    for entry, ce in zip(catalog['plugins'], claude['plugins']):
        name = entry['name']; package = root/name
        assert entry['source'] == {'source': 'local', 'path': './'+name}
        assert ce['source'] == './'+name
        manifest = json.loads((package/'.codex-plugin/plugin.json').read_text())
        legacy = json.loads((package/'.claude-plugin/plugin.json').read_text())
        for key in ('name','version','description'): assert manifest[key] == legacy[key], (name,key)
        assert manifest['repository'] == REPOSITORY
        assert manifest['version'] == ce['version']
        assert manifest['description'] == ce['description'] == manifest['interface']['longDescription']
        skill = package/'skills'/name
        content = (skill/'SKILL.md').read_text()
        assert content.split('description: ',1)[1].split('\n',1)[0] == manifest['description']
        assert manifest['description'] in readme
        metadata = dict(line.strip().split(': ',1) for line in (skill/'agents/openai.yaml').read_text().splitlines() if line.startswith('  '))
        for field, target in [('display_name','displayName'),('short_description','shortDescription')]:
            assert json.loads(metadata[field]) == manifest['interface'][target]
        assert json.loads(metadata['default_prompt']) in manifest['interface']['defaultPrompt']
        assert '$'+name in json.loads(metadata['default_prompt'])
        for path in ('.claude-plugin/plugin.json','skills/'+name+'/SKILL.md'): assert (package/path).is_file()
    files = subprocess.check_output(['git','ls-files','-co','--exclude-standard','-z'],cwd=root).split(b'\0')
    documents = []
    for raw in filter(None,files):
        path = root/raw.decode()
        if path.is_symlink(): raise AssertionError('Symlink is not distributable: '+str(path))
        if path.is_file() and path.suffix == '.md': documents.append(path)
    for document in documents:
        for target in local_targets(document.read_text()):
            assert (document.parent/target).exists(), ('Broken local link',document.relative_to(root),target)
    tracked = subprocess.check_output(['git','ls-files','-z'],cwd=root).split(b'\0')
    for raw in filter(None,tracked):
        path = raw.decode()
        if Path(path).parts[0] in NAMES: assert distributable(path), 'User/runtime data in Git: '+path
    assert re.fullmatch(r'\d+\.\d+\.\d+', (root/'VERSION').read_text().strip())
    print('PASS canonical packages, both marketplaces, manifests, trigger/UI metadata, local links and source-only delivery')


if __name__ == '__main__': validate()
