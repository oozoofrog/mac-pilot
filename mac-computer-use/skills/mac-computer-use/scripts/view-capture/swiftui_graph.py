"""Capture-local, read-only SwiftUI graph decoding. Used by the resident capture normalizer."""
import hashlib
import json
import math
import re
from dataclasses import dataclass


@dataclass(frozen=True)
class Limits:
    wire_bytes: int = 16 * 1024 * 1024
    json_depth: int = 128
    json_values: int = 200000
    container_items: int = 8192
    string_bytes: int = 256 * 1024
    total_string_bytes: int = 8 * 1024 * 1024
    numeric_chars: int = 128
    nodes: int = 4096
    node_depth: int = 64
    children: int = 4096
    properties: int = 64
    attributes: int = 32768
    attribute_depth: int = 64


class Budget(ValueError):
    pass


TOKEN = re.compile(r'\s+|"(?:[^"\\\x00-\x1f]|\\(?:["\\/bfnrt]|u[0-9a-fA-F]{4}))*"|-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?|true|false|null|[{}\[\],:]')


def _wire_scan(raw, limits):
    # Preflight before json.loads allocates containers or descends recursively.
    text = raw.decode('utf-8', errors='strict')
    stack = []; pos = 0; tokens = 0; strings = 0
    while pos < len(text):
        match = TOKEN.match(text, pos)
        if match is None: raise ValueError('invalid JSON token')
        pos = match.end(); token = match[0]
        if token.isspace(): continue
        if token in ',:': continue
        if token in '}]':
            if not stack or stack.pop()[0] != ('{' if token == '}' else '['):
                raise ValueError('unbalanced JSON')
            continue
        tokens += 1
        if tokens > limits.json_values * 2: raise Budget('lexical tokens')
        if stack:
            stack[-1][1] += 1
            cap = limits.container_items * (2 if stack[-1][0] == '{' else 1)
            if stack[-1][1] > cap: raise Budget('container items')
        if token in '{[':
            if len(stack) > limits.json_depth: raise Budget('JSON depth')
            stack.append([token, 0])
        elif token.startswith('"'):
            # Includes object keys; escaping is decoded once for accurate string cost.
            size = len(json.loads(token).encode('utf-8'))
            strings += size
            if size > limits.string_bytes or strings > limits.total_string_bytes: raise Budget('string bytes')
        elif token[0] in '-0123456789' and len(token) > limits.numeric_chars:
            raise Budget('numeric characters')
    if pos != len(text) or stack: raise ValueError('incomplete JSON')
    return text


def _pairs(pairs):
    result = {}
    for key, value in pairs:
        if key in result: raise ValueError('duplicate JSON key')
        result[key] = value
    return result


def _uint(value):
    return type(value) is int and 0 <= value < 2**32


def classify(raw, *, limits=Limits()):
    """Interpret supplied bytes only. None means observed nil; use observe for files."""
    if raw is None: return {'status': 'nil', 'bytes': 0}
    report = {'bytes': len(raw), 'sha256': hashlib.sha256(raw).hexdigest()}
    try:
        if len(raw) > limits.wire_bytes: raise Budget('wire bytes')
        def number(token):
            value = float(token)
            if not math.isfinite(value): raise ValueError('nonfinite number')
            return value
        def constant(token): raise ValueError('nonfinite number: ' + token)
        value = json.loads(_wire_scan(raw, limits), object_pairs_hook=_pairs,
                           parse_float=number, parse_constant=constant)
        pending = [(value, 0)]; count = 0; depth = 0; containers = 0
        while pending:
            item, d = pending.pop(); count += 1; depth = max(depth, d)
            if count > limits.json_values or d > limits.json_depth: raise Budget('JSON values/depth')
            if isinstance(item, (dict, list)):
                containers += 1
                if len(item) > limits.container_items: raise Budget('container items')
                pending.extend((x, d + 1) for x in (item.values() if isinstance(item, dict) else item))
        report.update(serializedValueCount=count, maxJSONDepth=depth, containerCount=containers)
        if isinstance(value, dict): return dict(report, status='errorObject', objectKeys=sorted(value))
        if not isinstance(value, list): raise ValueError('root must be array')
        if not value: return dict(report, status='emptyArray', rootCount=0, nodeCount=0)
        nodes = []; attrs = 0; max_attr_depth = 0; max_node_depth = 0
        todo = [(n, None, i, 0) for i, n in reversed(list(enumerate(value)))]
        while todo:
            node, parent, ordinal, d = todo.pop()
            if len(nodes) >= limits.nodes or d > limits.node_depth: raise Budget('declarative nodes/depth')
            if not isinstance(node, dict) or not isinstance(node.get('properties'), list) or not isinstance(node.get('children'), list):
                raise ValueError('node requires properties/children arrays')
            props, children = node['properties'], node['children']
            if len(props) > limits.properties or len(children) > limits.children: raise Budget('properties/children')
            property_ids = set()
            for prop in props:
                if not isinstance(prop, dict) or not _uint(prop.get('id')) or not isinstance(prop.get('attribute'), dict):
                    raise ValueError('property requires UInt32 id and attribute object')
                if prop['id'] in property_ids: raise ValueError('duplicate property id')
                property_ids.add(prop['id'])
                atodo = [(prop['attribute'], 0)]
                while atodo:
                    attr, ad = atodo.pop(); attrs += 1; max_attr_depth = max(max_attr_depth, ad)
                    if attrs > limits.attributes or ad > limits.attribute_depth: raise Budget('reflected attributes/depth')
                    if not isinstance(attr, dict): raise ValueError('attribute must be object')
                    for field in ('type', 'readableType', 'name'):
                        if field in attr and not isinstance(attr[field], str): raise ValueError('attribute ' + field + ' must be string')
                    if 'flags' in attr and not _uint(attr['flags']): raise ValueError('attribute flags must be UInt32')
                    if 'subattributes' in attr:
                        if not isinstance(attr['subattributes'], list): raise ValueError('subattributes must be array')
                        atodo.extend((a, ad + 1) for a in attr['subattributes'])
            index = len(nodes); max_node_depth = max(max_node_depth, d)
            # Index and ordinal keep paths linear; properties remain exact opaque JSON.
            nodes.append(dict(index=index, parentIndex=parent, childOrdinal=ordinal, depth=d,
                              properties=props, metadataProvenance='completeOpaqueJSON',
                              opaqueFields={k:v for k,v in node.items() if k not in ('properties', 'children')}))
            todo.extend((child, index, i, d + 1) for i, child in reversed(list(enumerate(children))))
        return dict(report, status='rootArray', rootCount=len(value), nodeCount=len(nodes), nodes=nodes,
                    maxDeclarativeDepth=max_node_depth, attributeCount=attrs, maxAttributeDepth=max_attr_depth,
                    identityScope='captureLocal', editableProperties=[])
    except Budget as error:
        return dict(report, status='overbudget', reason=str(error), metadataProvenance='unavailable', graphAccepted=False)
    except (ValueError, UnicodeError, RecursionError, OverflowError) as error:
        return dict(report, status='malformed', reason=str(error), graphAccepted=False)


def observe(raw, began=None, returned=None, *, limits=Limits()):
    """Receipts, not file absence, establish call outcomes. Receipts are capture-scoped."""
    if began is None:
        return {'status': 'notCalled' if raw is None and returned is None else 'malformed',
                'provenance': 'noBeginReceipt' if raw is None and returned is None else 'orphanArtifact'}
    if returned is None: return {'status': 'unavailable', 'provenance': 'beganWithoutReturn'}
    if began.get('phase') != 'began' or returned.get('phase') != 'returned':
        return {'status': 'malformed', 'reason': 'invalid stage receipt'}
    for key in ('operationID', 'requestDigest', 'action'):
        if not began.get(key) or began[key] != returned.get(key):
            return {'status': 'malformed', 'reason': 'receipt identity mismatch'}
    if type(began.get('monotonicNS')) is not int or type(returned.get('monotonicNS')) is not int or returned['monotonicNS'] < began['monotonicNS']:
        return {'status': 'malformed', 'reason': 'receipt interval invalid'}
    if type(began.get('callBegan')) is not bool or returned.get('callBegan') is not began['callBegan']:
        return {'status': 'malformed', 'reason': 'invalid call receipt'}
    outcome = returned.get('outcome')
    if not began['callBegan'] and outcome != 'unsupported':
        return {'status': 'malformed', 'reason': 'uncalled action claims return value'}
    if outcome in ('nil', 'unsupported', 'overbudget', 'unavailable'):
        if raw is not None: return {'status': 'malformed', 'reason': 'receipt contradicts bytes'}
        return {'status': outcome, 'provenance': 'returnReceipt'}
    if outcome != 'bytes' or raw is None or returned.get('bytes') != len(raw):
        return {'status': 'unavailable', 'provenance': 'missingOrContradictoryBytes'}
    return classify(raw, limits=limits)
