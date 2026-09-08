import pathlib
import sys
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
from provisioning_setup import SetupError, provisioning


class ProvisioningSetupTests(unittest.TestCase):
    def test_defaults_are_disabled_except_master_after_explicit_prepare(self):
        config = {}
        value = provisioning(config, 'germany-1')
        self.assertTrue(value['enabled'])
        self.assertFalse(value['ssh_device_keys'])
        self.assertFalse(value['openvpn_device_certificates'])
        self.assertFalse(value['xray_device_certificates'])
        self.assertEqual(value['managed_port'], 9443)

    def test_server_id_is_immutable(self):
        config = {'provisioning': {'server_id': 'germany-1'}}
        with self.assertRaises(SetupError):
            provisioning(config, 'germany-2')

    def test_invalid_server_id_is_rejected(self):
        with self.assertRaises(SetupError):
            provisioning({}, '../bad')

    def test_menu_exposes_explicit_activation(self):
        menu = (pathlib.Path(__file__).resolve().parents[1]/'iptunnel_menu.sh').read_text(encoding='utf-8')
        self.assertIn('Device provisioning', menu)
        self.assertIn('Type PREPARE to validate and activate', menu)
        self.assertIn('previous configuration was restored', menu)


if __name__ == '__main__':
    unittest.main()
