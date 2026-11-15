"""Offline parser regressions; no fixture runtime, devices, or recorded JSON required."""
import json
from dataclasses import replace
import unittest
import graph


def node(children=None, attribute=None):
    return dict(properties=[dict(id=0, attribute={} if attribute is None else attribute)], children=children or [])


def parse(value, **limits):
    return graph.classify(json.dumps(value).encode(), limits=replace(graph.Limits(), **limits))


class GraphTests(unittest.TestCase):
    def test_metadata_and_nodes_have_independent_budgets(self):
        rich = node(attribute={'value': list(range(600))})
        self.assertEqual(parse([rich], nodes=1)['nodeCount'], 1)
        self.assertEqual(parse([rich], json_values=50)['status'], 'overbudget')
        broad = node([node() for _ in range(20)])
        self.assertEqual(parse([broad], nodes=21)['nodeCount'], 21)
        self.assertEqual(parse([broad], nodes=20)['status'], 'overbudget')
        self.assertEqual(parse([broad], children=19)['status'], 'overbudget')

    def test_child_order_values_unknown_fields_and_no_invented_edges(self):
        v = node([node(attribute={'value': 'second'}), node(attribute={'value': 'third'})],
                 {'type': 'TupleView<Text, Shape>', 'value': {'children': [1, 2]}})
        v['future'] = {'type': 'Opaque'}; v['properties'][0]['id'] = 4294967295
        r = parse([v]); self.assertEqual(r['nodeCount'], 3)
        self.assertEqual([n['parentIndex'] for n in r['nodes']], [None, 0, 0])
        self.assertEqual([n['childOrdinal'] for n in r['nodes']], [0, 0, 1])
        self.assertEqual(r['nodes'][0]['properties'], v['properties'])
        self.assertEqual(r['nodes'][0]['opaqueFields']['future'], v['future'])

    def test_malformed_schema(self):
        bad = [None, 7, [None], [{'properties': [], 'children': {}}],
               [node(attribute=[])], [node(attribute={'flags': True})],
               [node(attribute={'type': 1})], [node(attribute={'subattributes': [3]})]]
        for value in bad:
            with self.subTest(value=value): self.assertEqual(parse(value)['status'], 'malformed')
        duplicate = node(); duplicate['properties'] *= 2
        self.assertEqual(parse([duplicate])['status'], 'malformed')
        for id_value in (True, False, -1, 2**32, 1.0, '1'):
            v = node(); v['properties'][0]['id'] = id_value
            self.assertEqual(parse([v])['status'], 'malformed')

    def test_duplicate_nonfinite_invalid_unicode_and_json(self):
        for raw in (b'[{"children":[],"children":[],"properties":[]}]',
                    b'[{"properties":[],"children":[],"x":{"a":1,"a":2}}]',
                    b'[NaN]', b'[Infinity]', b'[1e999]', b'["\\ud800"]', b'[]junk', b'[01]', b'[', b''):
            with self.subTest(raw=raw): self.assertEqual(graph.classify(raw)['status'], 'malformed')

    def test_wire_limits_independent_and_no_partial_metadata(self):
        tests = [([node()], {'wire_bytes': 2}), ([node(attribute={'value': 'abcdef'})], {'string_bytes': 5}),
                 ([node(attribute={'value': ['abc'] * 20})], {'total_string_bytes': 30}),
                 ([node(attribute={'value': 123456})], {'numeric_chars': 5}),
                 ([node(attribute={'value': [0] * 12})], {'container_items': 11}),
                 ([node(attribute={'value': [[[[1]]]]})], {'json_depth': 5}),
                 ([node([node([node()])])], {'node_depth': 1}),
                 ([node(attribute={'subattributes': [{}, {}]})], {'attributes': 2}),
                 ([node(attribute={'subattributes': [{'subattributes': [{}]}]})], {'attribute_depth': 1}),
                 ([dict(properties=[dict(id=0,attribute={})]*3, children=[])], {'properties': 2})]
        for value, limits in tests:
            with self.subTest(limits=limits):
                r = parse(value, **limits); self.assertEqual(r['status'], 'overbudget')
                self.assertNotIn('nodes', r); self.assertEqual(r['metadataProvenance'], 'unavailable')
        self.assertEqual(parse([node()], json_depth=4)['status'], 'rootArray')

    def test_stage_receipts_distinguish_skipped_nil_and_incomplete(self):
        begin = dict(phase='began', operationID='op', requestDigest='digest', action='direct', monotonicNS=1, callBegan=True)
        end = dict(begin, phase='returned', monotonicNS=2, outcome='nil', bytes=0)
        self.assertEqual(graph.observe(None)['status'], 'notCalled')  # lifetime-3 style
        self.assertEqual(graph.observe(None, begin)['status'], 'unavailable')
        self.assertEqual(graph.observe(None, begin, end)['status'], 'nil')
        self.assertEqual(graph.observe(None, begin, dict(end,outcome='unsupported'))['status'], 'unsupported')
        self.assertEqual(graph.observe(b'[]', begin, dict(end,outcome='bytes',bytes=2))['status'], 'emptyArray')
        self.assertEqual(graph.observe(b'[]', begin, end)['status'], 'malformed')
        self.assertEqual(graph.observe(b'[]')['status'], 'malformed')
        self.assertEqual(graph.observe(None, begin, dict(end,operationID='other'))['status'], 'malformed')
        self.assertEqual(graph.observe(None, begin, dict(end,monotonicNS=0))['status'], 'malformed')


if __name__ == '__main__': unittest.main()
