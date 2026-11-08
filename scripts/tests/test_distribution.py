import importlib.util
import sys
import unittest
from pathlib import Path

SCRIPTS=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(SCRIPTS))
from validate_distribution import distributable,local_targets,validate,ROOT

class DistributionTests(unittest.TestCase):
    def test_real_catalog_and_links(self): validate(ROOT)
    def test_user_and_generated_data_are_never_delivery_inputs(self):
        for path in ('mac-computer-use/docs/development/capture.png','mac-computer-use/skills/mac-computer-use/scripts/mac-cu','mac-computer-use/skills/mac-computer-use/always-allow.txt','simulator-pilot/skills/simulator-pilot/__pycache__/test.pyc','mac-computer-use/skills/mac-computer-use/browser-profile/Cookies'):
            self.assertFalse(distributable(path),path)
        self.assertTrue(distributable('mac-computer-use/skills/mac-computer-use/scripts/setup.py'))
        self.assertTrue(distributable('simulator-pilot/skills/simulator-pilot/tool/sim-pilot.swift'))
    def test_example_links_are_not_actual_file_dependencies(self):
        self.assertEqual(list(local_targets('[real](docs/a.md#b)\n`[example](missing)`\n```md\n[example](missing)\n```\n[web](https://example.com/a)')),['docs/a.md'])

if __name__=='__main__': unittest.main()
