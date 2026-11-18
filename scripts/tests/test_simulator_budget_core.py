"""Rules that mac-cu and sim-pilot share exist twice: in mac-cu and in sim-pilot. They must be the same text."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
SOURCES = ROOT / 'mac-computer-use/skills/mac-computer-use/scripts/mac-cu-src'
TOOL = ROOT / 'simulator-pilot/skills/simulator-pilot/tool/sim-pilot.swift'


def core(path: Path, name: str) -> str:
    begin, end = f'// BEGIN {name}', f'// END {name}'
    text = path.read_text()
    assert text.count(begin) == 1 and text.count(end) == 1, (path, name)
    return text[text.index(begin):text.index(end)]


class SharedSimulatorCore(unittest.TestCase):
    def check(self, source: str, name: str):
        daemon, tool = core(SOURCES / source, name), core(TOOL, name)
        self.assertGreater(len(daemon), 2000)
        self.assertEqual(daemon, tool, f'Copy the {name} block of {source} into sim-pilot.swift (or back).')

    def test_budget_copies_are_identical(self):
        self.check('SimulatorBudget.swift', 'simulator-budget-core')

    def test_collaboration_copies_are_identical(self):
        self.check('SimulatorCollaboration.swift', 'simulator-collab-core')


if __name__ == '__main__':
    unittest.main()
