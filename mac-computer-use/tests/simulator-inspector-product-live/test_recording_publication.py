"""Actual UI writer -> unchanged private Python reader; no UI, device or debugger."""
import os
from pathlib import Path
import sys
import tempfile
from types import SimpleNamespace
import unittest

from recording_writer_check import RecordingWriter
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'view-hierarchy-prototype'))
import ui_capture_contract as a

NAMES = ('recording-ready.json', 'recording-action.json')


class RecordingWriterContract(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.writer = RecordingWriter()
        print(cls.writer.output, flush=True)

    def setUp(self):
        # Retain adverse files and generated native logs as failure evidence.
        self.root = Path(tempfile.mkdtemp(prefix='case-', dir=self.writer.output))

    def test_both_actual_publications_are_private_before_visibility_and_reader_accepts(self):
        for mask in ('022', '777'):
            out = self.root / mask; out.mkdir(mode=0o700)
            values = {name: dict(name=name, disclosure='현재 실행 상태가 사라집니다.') for name in NAMES}
            self.assertEqual(self.writer.publish(out, values, mask=mask), 0)
            for name in NAMES:
                pins = []
                self.assertEqual(a.read_json(out / name, pins), values[name])
                self.assertEqual((out / name).stat().st_mode & 0o777, 0o600)
                a.revalidate(SimpleNamespace(files=tuple(pins)))
            self.assertFalse(list(out.glob('.recording-*')))

    def test_existing_and_replaced_destinations_are_preserved(self):
        for name in NAMES:
            out = self.root / name; out.mkdir(mode=0o700)
            self.assertEqual(self.writer.publish(out, {name: {'first': True}}), 0)
            pins = []; a.read_json(out / name, pins)
            original = (out / name).read_bytes()
            self.assertEqual(self.writer.publish(out, {name: {'second': True}}), 1)
            self.assertEqual((out / name).read_bytes(), original)
            # Keep the old inode alive so this is a proven replacement, never inode reuse.
            (out / name).rename(out / 'retained-original')
            (out / name).write_bytes(b'{"foreign":true}')
            with self.assertRaises(a.ContractError): a.revalidate(SimpleNamespace(files=tuple(pins)))
            self.assertEqual(self.writer.publish(out, {name: {'second': True}}), 1)
            self.assertEqual((out / name).read_bytes(), b'{"foreign":true}')

    def test_nonregular_destinations_and_nonprivate_directories_are_refused(self):
        for name in NAMES:
            for kind in ('symlink', 'hardlink', 'directory', 'fifo', 'public-directory'):
                out = self.root / (name + kind); out.mkdir(mode=0o755 if kind == 'public-directory' else 0o700)
                path = out / name
                sentinel = out / 'sentinel'; sentinel.write_bytes(b'preserve')
                if kind == 'symlink': path.symlink_to(sentinel)
                elif kind == 'hardlink': os.link(sentinel, path)
                elif kind == 'directory': path.mkdir()
                elif kind == 'fifo': os.mkfifo(path)
                else: self.assertTrue(out.stat().st_mode & 0o077, 'adverse directory must be nonprivate')
                before = path.lstat() if kind != 'public-directory' else None
                self.assertEqual(self.writer.publish(out, {name: {'new': True}}), 1)
                self.assertEqual(sentinel.read_bytes(), b'preserve')
                if before: self.assertEqual(a.stamp(path.lstat()), a.stamp(before))
                else: self.assertFalse(path.exists())
                self.assertFalse(list(out.glob('.recording-*')))

    def test_bounded_schema_path_and_directory_symlink_refusals(self):
        self.assertEqual(self.writer.publish(self.root, {NAMES[0]: {'huge': 'x' * 65536}}), 1)
        self.assertEqual(self.writer.publish(self.root, {'../outside.json': {}}), 1)
        link = self.root / 'link'; link.symlink_to(self.root, target_is_directory=True)
        self.assertEqual(self.writer.publish(link, {NAMES[0]: {}}), 1)
        self.assertFalse((self.root / NAMES[0]).exists())
        self.assertFalse(list(self.root.glob('.recording-*')))

    def test_racing_destination_and_staging_replacements_fail_closed(self):
        for name in NAMES:
            for race in ('destination', 'staging', 'parent'):
                out = self.root / (name + race); out.mkdir(mode=0o700)
                self.assertEqual(self.writer.publish(out, {name: {'owned': True}}, race=race), 1)
                if race == 'parent':
                    self.assertFalse((out / name).exists())
                    self.assertEqual(a.read_json(Path(str(out) + '-retained') / name, []), {'owned': True})
                else:
                    self.assertEqual((out / name).read_bytes(), b'{"foreign":true}')
                self.assertFalse(list(out.glob('.recording-*')))

    def test_failed_sync_or_rename_never_publishes_and_preserves_foreign_staging(self):
        for name in NAMES:
            for race in ('sync-error', 'rename-error', 'staging-refuse'):
                out = self.root / (name + race); out.mkdir(mode=0o700)
                self.assertEqual(self.writer.publish(out, {name: {'owned': True}}, race=race), 1)
                self.assertFalse((out / name).exists())
                staging = list(out.glob('.recording-*'))
                if race == 'staging-refuse':
                    self.assertEqual(len(staging), 1)
                    self.assertEqual(staging[0].read_bytes(), b'{"foreign":true}')
                else:
                    self.assertFalse(staging)
