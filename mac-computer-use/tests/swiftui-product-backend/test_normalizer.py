"""Portable synthetic graph-to-product contract checks; no guest operations."""
import base64
import copy
import json
from pathlib import Path
import sys
import unittest
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'skills/mac-computer-use/scripts/view-capture'))
from swiftui_product import normalize, validate_scope

SCOPE = dict(deviceID='device', bootIdentity='boot:1', displayID='main', presentation='main|rot0', generation=1, runtime='runtime|build')
NODE = dict(properties=[dict(id=0, attribute=dict(readableType='SwiftUI.Text', value='Synthetic'))], children=[])

def payload(graph=None):
    host = dict(hostingNodeID='host', sceneID='scene', captureID='capture', graphStatus='returned',
                graphCallBegan=True, graphInterval=[1,2], graphBase64=base64.b64encode(json.dumps([NODE] if graph is None else graph).encode()).decode(),
                rendering=dict(status='unavailable', drawHierarchyReturned=None, reason='notCalled'))
    return dict(target=dict(deviceID='device'), inspectionScope=copy.deepcopy(SCOPE), captureID='capture',
                editableNodes=[dict(id='host', sceneID='scene')], swiftUIRaw=[host])

class ProductTests(unittest.TestCase):
    def test_isolated_production_import(self):
        import subprocess
        backend = Path(__file__).resolve().parents[2] / 'skills/mac-computer-use/scripts/view-capture/edit_backend.py'
        code = "import importlib.util; s=importlib.util.spec_from_file_location('backend'," + repr(str(backend)) + "); m=importlib.util.module_from_spec(s); s.loader.exec_module(m); assert m.swiftui_product().classify(b'[]')['status']=='emptyArray'"
        subprocess.run([sys.executable, '-I', '-c', code], check=True, timeout=10)

    def test_actual_children_only(self):
        root=copy.deepcopy(NODE);root['children']=[NODE,NODE]
        result=normalize(payload([root]),SCOPE)['hosts'][0]
        self.assertEqual(result['status'],'available')
        self.assertEqual(len(result['nodes']),3)
        self.assertEqual(result['nodes'][1]['parentID'],'swiftui:capture:host:0')
        self.assertEqual(result['nodes'][2]['childOrdinal'],1)
        self.assertEqual(result['nodes'][0]['properties'],NODE['properties'])
        self.assertNotIn('editToken',result['nodes'][0])
    def test_empty_needs_preparation(self):
        host=normalize(payload([]),SCOPE)['hosts'][0]
        self.assertEqual(host['status'],'empty'); self.assertIn('preparation',host['reason'])
    def test_join_rejection(self):
        for key,value in [('captureID','old'),('sceneID','other'),('hostingNodeID','absent')]:
            p=payload();p['swiftUIRaw'][0][key]=value
            with self.subTest(key=key),self.assertRaises(ValueError):normalize(p,SCOPE)
        p=payload();p['swiftUIRaw']*=2
        with self.assertRaises(ValueError):normalize(p,SCOPE)
    def test_host_list_budget(self):
        p=payload();p['swiftUIRaw']*=65
        with self.assertRaises(ValueError):normalize(p,SCOPE)

    def test_scope_drift(self):
        for key in SCOPE:
            p=payload();p['inspectionScope'][key]=2 if key=='generation' else 'changed'
            with self.subTest(key=key),self.assertRaises(ValueError):normalize(p,SCOPE)
        for generation in [-1,True,2**64]:
            with self.assertRaises(ValueError):validate_scope(dict(SCOPE,generation=generation),'device')
    def test_outcomes_and_contradictions(self):
        for state in ['nil','notCalled','error','overbudget']:
            p=payload();h=p['swiftUIRaw'][0];h['graphStatus']=state;h.pop('graphBase64')
            self.assertEqual(normalize(p,SCOPE)['hosts'][0]['graphStatus'],state)
        p=payload();p['swiftUIRaw'][0]['rendering']=dict(status='available',drawHierarchyReturned=False,data='x')
        with self.assertRaises(ValueError):normalize(p,SCOPE)
    def test_graph_budgets(self):
        for graph in [[dict(properties=[dict(id=i,attribute={}) for i in range(65)],children=[])], [NODE]*4097]:
            self.assertEqual(normalize(payload(graph),SCOPE)['hosts'][0]['status'],'overbudget')
    def test_malformed_not_empty(self):
        p=payload();p['swiftUIRaw'][0]['graphBase64']=base64.b64encode(b'[{"children":[]}]').decode()
        self.assertEqual(normalize(p,SCOPE)['hosts'][0]['graphStatus'],'malformed')
    def test_aggregate_nodes(self):
        p=payload([NODE]*2100);h=copy.deepcopy(p['swiftUIRaw'][0]);h['hostingNodeID']='second'
        p['editableNodes'].append(dict(id='second',sceneID='scene'));p['swiftUIRaw'].append(h)
        result=normalize(p,SCOPE)['hosts'];self.assertEqual(result[0]['status'],'available');self.assertEqual(result[1]['status'],'overbudget')

if __name__=='__main__':unittest.main()
