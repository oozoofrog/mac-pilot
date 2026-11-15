"""Keep the headless recording integration in the existing repository UI suite."""
from pathlib import Path


def load_tests(loader, tests, pattern):
    fixture = Path(__file__).resolve().parents[1] / 'view-hierarchy-fixture'
    return loader.discover(str(fixture), pattern='test_recording_integration.py', top_level_dir=str(fixture))
