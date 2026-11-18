"""The simulator budget rules exist twice: in mac-cu and in sim-pilot. They must be the same text."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
BEGIN, END = '// BEGIN simulator-budget-core', '// END simulator-budget-core'


def core(path: Path) -> str:
    text = path.read_text()
    assert text.count(BEGIN) == 1 and text.count(END) == 1, path
    return text[text.index(BEGIN):text.index(END)]


class SimulatorBudgetCore(unittest.TestCase):
    def test_both_copies_are_identical(self):
        daemon = core(ROOT / 'mac-computer-use/skills/mac-computer-use/scripts/mac-cu-src/SimulatorBudget.swift')
        tool = core(ROOT / 'simulator-pilot/skills/simulator-pilot/tool/sim-pilot.swift')
        self.assertGreater(len(daemon), 2000)
        self.assertEqual(daemon, tool, 'Copy the core of SimulatorBudget.swift into sim-pilot.swift (or back).')


if __name__ == '__main__':
    unittest.main()
