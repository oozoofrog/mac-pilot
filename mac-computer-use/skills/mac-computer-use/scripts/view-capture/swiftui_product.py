"""Normalize resident graph bytes. No target execution or cross-capture authority."""
import base64
from dataclasses import replace
import importlib.util
from pathlib import Path
import sys
_spec = importlib.util.spec_from_file_location('mac_cu_swiftui_graph', Path(__file__).with_name('swiftui_graph.py'))
_graph = importlib.util.module_from_spec(_spec)
sys.modules[_spec.name] = _graph
_spec.loader.exec_module(_graph)
classify, Limits = _graph.classify, _graph.Limits


def validate_scope(scope, device):
    fields = {'deviceID', 'bootIdentity', 'displayID', 'presentation', 'generation', 'runtime'}
    if not isinstance(scope, dict) or set(scope) != fields:
        raise ValueError('Invalid inspection scope fields')
    if any(type(scope[k]) is not str or not 0 < len(scope[k].encode()) <= 1024 for k in fields - {'generation'}):
        raise ValueError('Invalid inspection scope identity')
    if scope['deviceID'] != device or type(scope['generation']) is not int or not 0 <= scope['generation'] < 2**64:
        raise ValueError('Inspection scope device/generation mismatch')
    return scope


def normalize(payload, expected_scope):
    validate_scope(expected_scope, payload['target']['deviceID'])
    if payload.get('inspectionScope') != expected_scope:
        raise ValueError('SwiftUI inspection scope mismatch')
    hosts = payload.get('swiftUIRaw')
    if not isinstance(hosts, list) or len(hosts) > 64:
        raise ValueError('Invalid SwiftUI host list')
    registry = {n['id']: n for n in payload['editableNodes']}
    seen = set(); result = []; remaining = Limits(); total_bytes = 0
    for host in hosts:
        token = host.get('hostingNodeID'); node = registry.get(token)
        if node is None or token in seen or host.get('captureID') != payload['captureID'] or host.get('sceneID') != node.get('sceneID'):
            raise ValueError('SwiftUI capture/registry/scene join mismatch')
        seen.add(token)
        state = host.get('graphStatus'); raw = host.get('graphBase64')
        if state == 'returned':
            if type(raw) is not str or host.get('graphCallBegan') is not True:
                raise ValueError('Missing SwiftUI call/bytes')
            interval = host.get('graphInterval')
            if not isinstance(interval, list) or len(interval) != 2 or not all(type(x) in (int, float) for x in interval) or not 0 <= interval[0] <= interval[1]:
                raise ValueError('Invalid SwiftUI call interval')
            decoded = base64.b64decode(raw, validate=True); total_bytes += len(decoded)
            report = classify(decoded, limits=replace(remaining, wire_bytes=max(0, 4*1024*1024-(total_bytes-len(decoded)))))
        elif state in ('nil', 'notCalled', 'error', 'overbudget') and raw is None:
            if state == 'nil' and (host.get('graphCallBegan') is not True or 'graphInterval' not in host):
                raise ValueError('Nil graph lacks completed call receipt')
            report = {'status': state, 'reason': host.get('reason', state)}
        else: raise ValueError('Contradictory SwiftUI graph outcome')
        state = report['status']; nodes = report.get('nodes', [])
        if nodes:
            remaining = replace(remaining, nodes=remaining.nodes-len(nodes), attributes=remaining.attributes-report['attributeCount'],
                                json_values=remaining.json_values-report['serializedValueCount'])
        prefix = 'swiftui:' + payload['captureID'] + ':' + token + ':'
        normalized = [dict(id=prefix+str(n['index']), parentID=None if n['parentIndex'] is None else prefix+str(n['parentIndex']),
                           childOrdinal=n['childOrdinal'], properties=n['properties']) for n in nodes]
        rendering = host.get('rendering')
        if not isinstance(rendering, dict) or rendering.get('status') not in ('available', 'unavailable', 'error', 'overbudget'):
            raise ValueError('Invalid SwiftUI rendering')
        if rendering['status'] == 'available' and (rendering.get('drawHierarchyReturned') is not True or not isinstance(rendering.get('data'), str)):
            raise ValueError('Contradictory SwiftUI composite')
        result.append(dict(hostingNodeID=token, sceneID=host['sceneID'],
            status={'rootArray':'available', 'emptyArray':'empty', 'overbudget':'overbudget', 'nil':'unavailable', 'notCalled':'unavailable'}.get(state, 'error'),
            reason=('SwiftUI recording preparation required' if state in ('emptyArray', 'nil') else report.get('reason')),
            graphStatus=state, nodes=normalized, rendering={**rendering, 'representation':'hostingSubtreeComposite', 'assetID':None}))
    return dict(schemaVersion=1, captureID=payload['captureID'], inspectionScope=expected_scope, hosts=result)
