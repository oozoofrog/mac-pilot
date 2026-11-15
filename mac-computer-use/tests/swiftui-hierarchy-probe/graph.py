"""Probe adapter for the canonical host parser. No runtime authority."""
import importlib.util
import json
from pathlib import Path
import sys

PARSER = Path(__file__).resolve().parents[2] / 'skills/mac-computer-use/scripts/view-capture/swiftui_graph.py'
spec = importlib.util.spec_from_file_location('swiftui_graph', PARSER)
module = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = module
spec.loader.exec_module(module)
classify = module.classify
observe = module.observe
Limits = module.Limits


def assess(channel, action, filename):
    def receipt(phase):
        path = channel / (action + '-' + phase + '.json')
        return read_json(path) if path.exists() else None
    path = channel / filename
    # No receipt in historical data is absence of proof, never observed nil.
    try:
        began, returned = receipt('began'), receipt('returned')
        if began is not None:
            reservation = read_json(channel / 'reservation.json')
            if began.get('action') != action or any(began.get(k) != reservation.get(k) for k in ('operationID', 'requestDigest')):
                return {'status': 'malformed', 'reason': 'stage not bound to reservation/action'}
        raw = None
        if path.exists():
            with path.open('rb') as source: raw = source.read(Limits().wire_bytes + 1)
        return observe(raw, began, returned)
    except (ValueError, OSError):
        return {'status': 'malformed', 'reason': 'unreadable stage evidence'}


def read_json(path):
    with path.open('rb') as source: raw = source.read(65537)
    if len(raw) > 65536: raise ValueError('receipt byte budget')
    return json.loads(raw, object_pairs_hook=module._pairs)


def receipts(channel):
    result = {}
    for action in ('typed', 'direct', 'A', 'B'):
        result[action] = {}
        for phase in ('began', 'returned'):
            path = channel / (action + '-' + phase + '.json')
            try: result[action][phase] = read_json(path) if path.exists() else None
            except (ValueError, OSError): result[action][phase] = {'unavailable': 'invalid receipt'}
    return result
