"""Exact capture identity join and independent UIKit corner oracle; never enables overlays."""
import math
from pathlib import Path
import struct

EXPECTED = {'fixture.root', 'fixture.container', 'fixture.transform', 'fixture.clipped',
            'fixture.hidden', 'fixture.scroll', 'fixture.scrolled'}


def check(result, snapshot, oracle, screenshot):
    assert result['status'] == 'success' and result['detach'] == 'success'
    sent, received = result['clockTransmission'], result['deadlineReceipt']
    assert sent['clock'] == received['clock'] == 'CLOCK_MONOTONIC'
    assert sent['deadlineMonotonic'] == received['deadlineMonotonic']
    assert received['receivedMonotonic'] >= sent['sentMonotonic'] - .001
    assert received['remainingAtReceiptSeconds'] <= sent['remainingAtSendSeconds'] + .001
    assert result['mainThread']['queue'] == 'com.apple.main-thread' and result['mainThread']['isMainThread'] is True
    assert result['connected'] and result['attachRequested']
    assert result['cleanup']['childrenReaped'] and result['cleanup']['recovery']['verified']
    assert result['recovery']['verified']
    for key in ('pid', 'start', 'path', 'deviceID'):
        assert result['cleanup']['recovery']['target'][key] == result['target'][key]
    assert result['verified'] is False and result['overlayEnabled'] is False
    geometry = result['geometry']['nodes']
    found = {}
    ids = set()
    missing = []
    def visit(node):
        assert node['id'] not in ids
        ids.add(node['id'])
        if node['id'] in geometry:
            assert node['geometry'] == geometry[node['id']]
        else:
            missing.append(node['id'])
        identifier = node['accessibilityIdentifier']
        if identifier in EXPECTED:
            assert identifier not in found
            found[identifier] = node
        for child in node.get('children') or []:
            assert child['parentID'] == node['id']
            visit(child)
    for root in snapshot['roots']:
        visit(root)
    assert set(found) == EXPECTED, 'missing fixture IDs: ' + str(EXPECTED - set(found))
    independent = {v['id']: v for v in oracle['views']}
    comparisons = []
    for identifier in sorted(EXPECTED):
        node, expected = found[identifier], independent[identifier]
        actual = geometry[node['id']]
        assert actual['id'] == node['id'] and node['geometry'] == actual
        assert len(actual['corners']) == len(expected['corners']) == 4
        error = max(abs(a - b) for p, q in zip(actual['corners'], expected['corners']) for a, b in zip(p, q))
        assert math.isfinite(error) and error <= .01, (identifier, error)
        assert actual['clipsToBounds'] == expected['clipsToBounds']
        assert node['hidden'] == expected['hidden']
        parent = expected['parentID']
        if parent in EXPECTED:
            assert node['parentID'] == found[parent]['id']
        assert actual['screen']['scale'] == oracle['screenScale']
        assert actual['screen']['orientation'] == oracle['orientation'] == 1
        assert actual['screen']['bounds'] == oracle['screenBounds']
        assert not actual['verified'] and not actual['overlayEnabled'] and not actual['clippingVerified']
        comparisons.append({'fixtureID': identifier, 'objectID': node['id'], 'maxCornerErrorPoints': error})
    raw = Path(screenshot).read_bytes()
    assert raw[:8] == b'\x89PNG\r\n\x1a\n' and raw[12:16] == b'IHDR'
    width, height = struct.unpack('>II', raw[16:24])
    bounds, scale = oracle['screenBounds'], oracle['screenScale']
    assert (width, height) == (round(bounds[2] * scale), round(bounds[3] * scale))
    return {'fixtureViews': comparisons, 'hierarchyNodes': len(ids), 'geometryNodes': len(geometry),
            'missingGeometryIDs': missing, 'pngPixels': [width, height], 'scale': scale,
            'pointToScreenshot': 'portrait fixed point (x,y) -> pixel (x*scale,y*scale), top-left origin',
            'oracleTimestamp': oracle['capturedAt'], 'captureInterval': result['captureIntervalUnixSeconds'],
            'verified': False, 'overlayEnabled': False,
            'unsupported': ['clipped visible polygons', '3D projection', 'moving/atomic screenshot alignment',
                            'LCD viewport/host presentation alignment; no LCD window was opened']}


def diagnose(result, snapshot, oracle, screenshot):
    """Collect every fixture error/stage without relaxing or replacing check()."""
    found = {}
    def visit(node):
        name = node.get('accessibilityIdentifier')
        if name in EXPECTED:
            found.setdefault(name, []).append(node)
        for child in node.get('children') or []:
            visit(child)
    for root in snapshot['roots']:
        visit(root)
    expected = {v['id']: v for v in oracle['views']}
    geometry = result['geometry']['nodes']
    def error(a, b):
        if not isinstance(a, list) or not isinstance(b, list) or len(a) != len(b):
            return None
        try:
            def flat(values):
                return [n for row in values for n in row] if values and isinstance(values[0], list) else values
            left, right = flat(a), flat(b)
            if len(left) != len(right): return None
            return max((abs(float(x)-float(y)) for x, y in zip(left, right)), default=0)
        except (TypeError, ValueError): return None
    rows = []
    for name in sorted(EXPECTED):
        matches = found.get(name, [])
        if len(matches) != 1 or name not in expected:
            rows.append({'fixtureID': name, 'error': 'missing/duplicate fixture or oracle identifier'})
            continue
        node, oracle_node = matches[0], expected[name]
        g = geometry.get(node['id'], {})
        d = g.get('cornerDiagnostics') or {}
        b = g.get('bounds')
        local = None
        if isinstance(b, list) and len(b) == 4:
            x, y, w, h = b
            local = [[x,y],[x+w,y],[x+w,y+h],[x,y+h]]
        getters = d.get('getters') or {}
        getter_values = [getters.get(k) for k in ('minX','minY','maxX','maxY')]
        getter_expected = [b[0],b[1],b[0]+b[2],b[1]+b[3]] if local else None
        helper_expected = ([local[0],[getters.get('maxX'),getters.get('minY')],
                           [getters.get('maxX'),getters.get('maxY')],[getters.get('minX'),getters.get('maxY')]] if local else None)
        parent = oracle_node.get('parentID')
        parent_matches = parent not in EXPECTED or (len(found.get(parent, [])) == 1 and node['parentID'] == found[parent][0]['id'])
        measurements = {'gettersVsFields': error(getter_values, getter_expected),
            'duplicateMakeImmediateVsGetterArguments': error(d.get('duplicateMakeImmediate'), helper_expected),
            'duplicateMakeArrayVsImmediate': error(d.get('duplicateMakeStored'), d.get('duplicateMakeImmediate')),
            'originalArrayVsFields': error(d.get('originalStored'), local),
            'originalArrayVsSplitMakeArray': error(d.get('originalStored'), d.get('duplicateMakeStored')),
            'fieldArrayVsFields': error(d.get('fieldStored'), local),
            'originalScreenVsOracle': error(g.get('corners'), oracle_node['corners']),
            'splitMakeScreenVsOracle': error(d.get('duplicateMakeScreen'), oracle_node['corners']),
            'fieldScreenVsOracle': error(d.get('fieldScreen'), oracle_node['corners']),
            'originalVsFieldWindow': error(d.get('originalWindow'), d.get('fieldWindow')),
            'originalVsFieldScreen': error(d.get('originalScreen'), d.get('fieldScreen'))}
        hints = []
        for key, label in [('gettersVsFields','CGRect getter/readback differs from raw fields'),
                           ('duplicateMakeImmediateVsGetterArguments','CGPointMake local readback differs from recorded arguments'),
                           ('duplicateMakeArrayVsImmediate','array storage/readback differs from immediate locals'),
                           ('originalArrayVsSplitMakeArray','nested original construction differs from split getter/make path')]:
            if measurements[key] is not None and measurements[key] > .01: hints.append(label)
        if measurements['originalArrayVsFields'] is not None and measurements['originalArrayVsFields'] <= .01:
            if measurements['originalScreenVsOracle'] is not None and measurements['originalScreenVsOracle'] > .01:
                hints.append('inputs agree; inspect window/screen conversion stages and timing')
        rows.append({'fixtureID':name,'objectID':node['id'],'sameCaptureExactJoin':node.get('geometry') == g and g.get('id') == node['id'],
            'parentID':node['parentID'],'expectedParentFixtureID':parent,'parentMatched':parent_matches,
            'bounds':b,'oracleCorners':oracle_node['corners'],'originalCorners':g.get('corners'),
            'cornerDeltas':[[a-b for a,b in zip(p,q)] for p,q in zip(g.get('corners',[]),oracle_node['corners'])],
            'diagnostics':d,'measurements':measurements,'causeHints':hints,
            'windowID':g.get('windowID'),'screen':g.get('screen')})
    strict = {'passed':False}
    try:
        check(result, snapshot, oracle, screenshot)
        strict['passed'] = True
    except (AssertionError, KeyError, TypeError, ValueError, OSError) as failure:
        strict['firstFailure'] = repr(failure)
    return {'strictGate':strict,'tolerancePoints':.01,'rows':rows,
            'scalars':(result['geometry'].get('diagnostics') or {}).get('scalars'),
            'diagnosticEnvelope':result['geometry'].get('diagnostics'),
            'captureIntervalUnixSeconds':result.get('captureIntervalUnixSeconds'),'oracleTime':oracle.get('capturedAt'),
            'identityScope':'exact tree/geometry addresses within this capture; oracle has identifiers but no addresses',
            'verified':False,'overlayEnabled':False,
            'limitation':'Diagnostic paths never replace original corners. Differences locate a path, not a vendor/compiler defect. Instrumentation can change code generation.'}
