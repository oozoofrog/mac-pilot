import copy
import hashlib
import json
import os
from pathlib import Path
import tempfile
import time
import unittest
import uuid
from unittest.mock import patch

import protocol as p
import debugger


def request():
    return {'experiment': 'resident-lifetime-v1', 'operation': 'setHiddenTrue',
            'ownerID': str(uuid.uuid4()), 'operationID': str(uuid.uuid4()), 'sequence': 1,
            'target': {'pid': 42, 'start': [1234, 5678], 'path': '/private/tmp/Fixture.app/HierarchyFixture',
                       'deviceID': str(uuid.uuid4())}, 'expiresUnixMS': int(time.time() * 1000) + 60000,
            'nodeGeneration': str(uuid.uuid4()), 'hiddenCount': 1, 'sceneID': 'fixture-scene',
            'parentName': 'fixture.root', 'image': '/private/tmp/operation/resident-simulator.dylib',
            'imageUUID': str(uuid.uuid4())}


class ProtocolTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='mac-cu-resident-test-')
        self.folder = Path(self.temp.name).resolve()
        self.r = request()

    def tearDown(self):
        self.temp.cleanup()

    def test_wire_digest_is_complete_fixed_scalar_payload(self):
        wire, digest = p.encode(self.r)
        self.assertEqual(len(wire), 2554)
        self.assertEqual(hashlib.sha256(wire[:-65]).hexdigest(), digest)
        self.assertEqual(wire[-65:], digest.encode() + b'\0')
        for key in ('ownerID', 'operationID', 'nodeGeneration', 'imageUUID', 'sceneID', 'parentName'):
            self.assertIn(self.r[key].encode() + b'\0', wire)

    def test_closed_schema_rejects_callbacks_code_addresses_and_production(self):
        for field in ('callback', 'context', 'targetPointer', 'selector', 'expression', 'schemaVersion', 'value'):
            r = dict(self.r, **{field: 1})
            with self.subTest(field=field), self.assertRaises(RuntimeError):
                p.encode(r)
        for field, value in [('operation', 'setAlpha'), ('sequence', 2), ('sequence', True),
                             ('hiddenCount', True), ('expiresUnixMS', 0), ('expiresUnixMS', 2**63),
                             ('sceneID', 'x' * 128), ('parentName', 'fixture.other'), ('image', '/tmp/a/../b'),
                             ('image', '/private/tmp/evil"path')]:
            with self.subTest(field=field, value=value), self.assertRaises((RuntimeError, ValueError)):
                p.encode(dict(self.r, **{field: value}))
        r = copy.deepcopy(self.r); r['target']['pointer'] = 123
        with self.assertRaises(RuntimeError):
            p.encode(r)

    def test_directory_symlink_and_nonprivate_directory_refused(self):
        real = self.folder / 'real'; real.mkdir(mode=0o700)
        link = self.folder / 'link'; link.symlink_to(real)
        for folder in (link, self.folder / 'link' / 'child'):
            with self.assertRaises(OSError):
                p.directory(folder)
        real.chmod(0o755)
        with self.assertRaises(RuntimeError):
            p.directory(real)

    def test_file_symlink_fifo_hardlink_permissions_and_oversize_refused(self):
        candidate = self.folder / 'terminal.json'
        source = self.folder / 'source'; source.write_bytes(b'{}'); source.chmod(0o600)
        candidate.symlink_to(source)
        with self.assertRaises(OSError):
            p.read(self.folder, candidate.name)
        candidate.unlink(); os.mkfifo(candidate, 0o600)
        with self.assertRaises(RuntimeError):
            p.read(self.folder, candidate.name)
        candidate.unlink(); os.link(source, candidate)
        with self.assertRaises(RuntimeError):
            p.read(self.folder, candidate.name)
        candidate.unlink(); candidate.write_bytes(b'{}'); candidate.chmod(0o644)
        with self.assertRaises(RuntimeError):
            p.read(self.folder, candidate.name)
        candidate.chmod(0o600); candidate.write_bytes(b'x' * 4097)
        with self.assertRaises(RuntimeError):
            p.read(self.folder, candidate.name)

    def test_uncertain_reservation_refuses_replay_and_new_authority(self):
        ledger = p.Admission(self.folder); digest = ledger.reserve(self.r)
        reservation = json.loads(p.read(self.folder, 'reservation.json'))
        self.assertEqual(reservation['state'], 'pending/uncertain')
        self.assertEqual(reservation['requestDigest'], digest)
        for r in (self.r, request()):
            with self.assertRaises(FileExistsError):
                p.Admission(self.folder).reserve(r)
        self.assertEqual(p.read(self.folder, 'request.bin'), p.encode(self.r)[0])

    def test_cancel_revokes_before_marker_and_late_receipt_stays_revoked(self):
        ledger = p.Admission(self.folder); ledger.reserve(self.r)
        original = p.write; ordering = []
        def write(folder, name, data):
            ordering.append(name)
            if name == 'cancel':
                self.assertTrue(ledger.revoked)
                self.assertEqual(json.loads(p.read(folder, 'authority.json'))['authority'], 'revoked')
            return original(folder, name, data)
        with patch.object(p, 'write', write):
            ledger.cancel('finiteDelayEntered', {'phase': 'finiteDelayEntered'})
        self.assertEqual(ordering, ['authority.json', 'cancel'])
        result = {'requestDigest': ledger.digest, 'operationID': self.r['operationID'],
                  'authorityRestored': False, 'admissionClosed': True, 'outcome': 'enteredUnverified'}
        self.assertEqual(ledger.observe(result)['inspectionAuthority'], 'revoked')
        with self.assertRaises(RuntimeError):
            ledger.cancel('duplicate')

    def test_cancel_transport_failure_does_not_restore_host_authority(self):
        ledger = p.Admission(self.folder); ledger.reserve(self.r)
        original = p.write
        def write(folder, name, data):
            if name == 'cancel':
                raise OSError('transport failed')
            return original(folder, name, data)
        with patch.object(p, 'write', write), self.assertRaises(OSError):
            ledger.cancel('stop')
        self.assertTrue(ledger.revoked)
        self.assertFalse((self.folder / 'cancel').exists())
        self.assertEqual(json.loads(p.read(self.folder, 'authority.json'))['authority'], 'revoked')

    def test_submission_only_fixed_address_and_literal_copied_path(self):
        self.assertEqual(debugger.submission(0x1234, self.folder),
                         '(int)((int (*)(const char *))0x1234)(' + json.dumps(str(self.folder)) + ')')
        for address in (True, -1, 0):
            with self.assertRaises(RuntimeError):
                debugger.submission(address, self.folder)
        with self.assertRaises(RuntimeError):
            debugger.submission(1234, Path('/private/tmp/evil";run'))


if __name__ == '__main__':
    unittest.main()
