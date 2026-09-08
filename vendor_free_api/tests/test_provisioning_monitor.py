import pathlib
import sys
import tempfile
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
from provisioning_monitor import configure, required_directives


class ProvisioningMonitorConfigurationTests(unittest.TestCase):
    def config(self, sockets):
        return {
            'openvpn': {'enabled': True},
            'provisioning': {
                'enabled': True,
                'server_id': 'test',
                'openvpn_management': sockets,
                'openvpn_device_certificates': True,
                'client_ca_certificate': '/var/lib/iptunnel-provisioning/client-ca.pem',
            },
        }

    def test_configures_only_profiles_that_exist(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = pathlib.Path(temporary)
            profile = directory / 'iptunnel-udp.conf'
            profile.write_text('port 53\nmanagement old.sock unix\n', encoding='utf-8')
            socket_path = '/run/iptunnel-provisioning/udp.sock'

            configure(self.config({'udp': socket_path}), directory)

            text = profile.read_text(encoding='utf-8')
            for directive in required_directives(socket_path):
                self.assertEqual(text.splitlines().count(directive), 1)
            self.assertIn('verify-client-cert require', text)
            self.assertNotIn('management old.sock unix', text)

    def test_rejects_profile_and_socket_mismatch_before_editing(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = pathlib.Path(temporary)
            profile = directory / 'iptunnel-udp.conf'
            original = 'port 53\n'
            profile.write_text(original, encoding='utf-8')

            with self.assertRaises(RuntimeError):
                configure(self.config({'tcp': '/run/iptunnel-provisioning/tcp.sock'}), directory)
            self.assertEqual(profile.read_text(encoding='utf-8'), original)


if __name__ == '__main__':
    unittest.main()
