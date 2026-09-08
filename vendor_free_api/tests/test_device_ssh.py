import base64
import pathlib
import sys
import tempfile
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
from device_ssh import SshCredentialStore, ssh_key
from device_credentials import ProvisioningError

DER = bytes.fromhex('3059301306072a8648ce3d020106082a8648ce3d03010703420004'
    '6b17d1f2e12c4247f8bce6e563a440f277037d812deb33a0f4a13945d898c296'
    '4fe342e2fe1a7f9b8ee7eb4a7c0f9e162bce33576b315ececbb6406837bf51f5')


class Accounts:
    def check(self, username):
        pass
    def install(self, *args):
        self.last = args


class SshEnrollmentTests(unittest.TestCase):
    def setUp(self):
        folder = tempfile.TemporaryDirectory()
        self.addCleanup(folder.cleanup)
        self.now = 1000
        self.accounts = Accounts()
        self.store = SshCredentialStore({'provisioning': {'enabled': True,
            'ssh_device_keys': True, 'ssh_db_path': str(pathlib.Path(folder.name) / 'ssh.db')}},
            self.accounts, clock=lambda: self.now)
        self.body = dict(owner_id='a'*64, protocol='ssh', request_id='b'*32,
                         recover=False, public_key=base64.b64encode(DER).decode())

    def test_response_has_no_password_and_replay_is_stable(self):
        first = self.store.provision(self.body)
        self.assertEqual(first, self.store.provision(self.body))
        self.assertNotIn('password', first)
        self.assertEqual(first['auth_type'], 'ssh_publickey')
        self.assertEqual(first['key_hash'], ssh_key(self.body['public_key'])[1])

    def test_invalid_curve_point_is_rejected(self):
        with self.assertRaises(ProvisioningError):
            ssh_key(base64.b64encode(DER[:-1] + b'\x00').decode())

    def test_request_cannot_be_reused_for_other_owner(self):
        self.store.provision(self.body)
        with self.assertRaises(ProvisioningError):
            self.store.provision(dict(self.body, owner_id='c'*64))

    def test_expiry_requires_new_recovery_request(self):
        first = self.store.provision(self.body)
        self.now = first['expires_at'] + 1
        with self.assertRaises(ProvisioningError):
            self.store.provision(self.body)
        renewed = self.store.provision(dict(self.body, recover=True, request_id='d'*32))
        self.assertGreater(renewed['expires_at'], first['expires_at'])
        self.assertEqual(renewed['key_hash'], first['key_hash'])


if __name__ == '__main__':
    unittest.main()
