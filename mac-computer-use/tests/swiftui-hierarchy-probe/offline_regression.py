"""Private saved-raw regression. Never modifies the original lifetime artifacts."""
import argparse
import collections
import hashlib
import json
from pathlib import Path
import time
import graph


def run(path):
    raw = path.read_bytes()
    assert hashlib.sha256(raw).hexdigest() == 'ccf7527a1e4f8d4b5fe61c745b80372d7de6ea93e260fd763a8a92dbd3b15b35'
    started = time.monotonic(); report = graph.classify(raw)
    assert report['status'] == 'rootArray', report
    assert report['nodeCount'] == 102 and report['maxDeclarativeDepth'] == 35
    original = json.loads(raw); todo = [(n, None, i) for i,n in reversed(list(enumerate(original)))]; index = 0
    text_nodes = 0; values = collections.Counter()
    while todo:
        n, parent, ordinal = todo.pop(); normalized = report['nodes'][index]
        assert normalized['parentIndex'] == parent and normalized['childOrdinal'] == ordinal
        assert normalized['properties'] == n['properties']
        assert normalized['opaqueFields'] == {k:v for k,v in n.items() if k not in ('properties','children')}
        text_nodes += any(p['id'] == 0 and p['attribute'].get('type') == 'SwiftUI.Text' for p in n['properties'])
        stack = [n['properties']]
        while stack:
            value = stack.pop()
            if isinstance(value, str): values[value] += 1
            elif isinstance(value, dict): stack.extend(value.values())
            elif isinstance(value, list): stack.extend(value)
        todo.extend((child,index,i) for i,child in reversed(list(enumerate(n['children'])))); index += 1
    assert index == report['nodeCount'] and text_nodes == 3
    supplied = ['ALPHA SWIFTUI 731', 'BRAVO DECLARATIVE 482', 'CHARLIE BRANCH 263']
    assert all(values[value] for value in supplied)
    return dict(evidence='NEW HEADLESS PARSER ONLY; original lifetime remains rejected',
                rawPath=str(path), rawSHA256=report['sha256'], bytes=len(raw), nodeCount=index,
                actualTextNodes=text_nodes, suppliedValues={v:values[v] for v in supplied},
                rawOrderAndAllPropertiesEqual=True, elapsedSeconds=time.monotonic()-started,
                costs={k:v for k,v in report.items() if k not in ('nodes','sha256')})


if __name__ == '__main__':
    p = argparse.ArgumentParser(); p.add_argument('raw', type=Path); p.add_argument('output', type=Path)
    args = p.parse_args()
    with args.output.open('x') as f: json.dump(run(args.raw), f, indent=2)
