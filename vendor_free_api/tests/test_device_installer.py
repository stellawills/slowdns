import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]


class DeviceInstallerTests(unittest.TestCase):
    def test_embedded_device_modules_match_tested_sources(self):
        installer = (ROOT / 'iptunnel-install.sh').read_text(encoding='utf-8')
        for filename, marker in [('device_credentials.py', 'DEVICE_CREDENTIALS'),
                                 ('device_certificates.py', 'DEVICE_CERTIFICATES'),
                                 ('device_xray.py', 'DEVICE_XRAY'),
                                 ('device_ssh.py', 'DEVICE_SSH'),
                                 ('provisioning_monitor.py', 'PROVISIONING_MONITOR'),
                                 ('managed-ssh.conf', 'MANAGED_SSH_CONFIG')]:
            with self.subTest(filename=filename):
                embedded = installer.split("<<'" + marker + "'\n", 1)[1].split('\n' + marker + '\n', 1)[0]
                self.assertEqual(embedded, (ROOT / filename).read_text(encoding='utf-8').rstrip())
