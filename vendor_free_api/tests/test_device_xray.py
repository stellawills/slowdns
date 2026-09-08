import hashlib
import json
import pathlib
import sys
import tempfile
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
from device_xray import XrayDeviceStore
from device_credentials import ProvisioningError


class XrayConfigurationTests(unittest.TestCase):
    def test_internal_port_collision_rejected(self):
        for port in (19440, 19441, 19442, 19449):
            with self.assertRaises(ProvisioningError):
                XrayDeviceStore({'provisioning': {'enabled': True,
                    'xray_device_certificates': True, 'managed_port': port,
                    'managed_server_name': 'example.com'}})

    def test_only_journaled_write_can_recover(self):
        with tempfile.TemporaryDirectory() as directory:
            store = object.__new__(XrayDeviceStore)
            store.root = pathlib.Path(directory)
            path = store.root/'config.json'
            path.write_text('new')
            journal = store.root/'config-pending.json'
            journal.write_text(json.dumps([hashlib.sha256(s.encode()).hexdigest()
                                          for s in ('old', 'new')]))
            store.reconcile_config('old')
            self.assertEqual(path.read_text(), 'old')
            self.assertFalse(journal.exists())
            path.write_text('operator edit')
            with self.assertRaises(ProvisioningError):
                store.reconcile_config('old')
            self.assertEqual(path.read_text(), 'operator edit')

    def test_managed_users_never_enter_legacy_listeners(self):
        store = object.__new__(XrayDeviceStore)
        config = store.core_config([])
        for inbound in config['inbounds']:
            self.assertEqual(inbound['listen'], '127.0.0.1')
            self.assertTrue(inbound['tag'].startswith('device-'))
