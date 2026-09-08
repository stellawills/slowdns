import pathlib
import sys
import tempfile
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
from device_credentials import CredentialStore, ProvisioningError


class DeviceCredentialsTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.now = 1000
        self.store = CredentialStore({
            "openvpn": {"enabled": True},
            "provisioning": {"enabled": True, "server_id": "test",
                "db_path": str(pathlib.Path(self.tmp.name) / "credentials.sqlite"),
                "openvpn_management": {"udp": "/run/iptunnel-provisioning/udp.sock"}}
        }, clock=lambda: self.now)
        self.store.heartbeat("udp", True)
        self.body = dict(owner_id="a" * 64, protocol="openvpn",
                         request_id="b" * 32, recover=False)

    def test_creation_and_replay_are_identical(self):
        first = self.store.provision(self.body)
        self.assertEqual(first, self.store.provision(self.body))
        self.assertEqual(first["version"], 1)
        self.assertGreaterEqual(len(first["password"]), 32)

    def test_request_id_cannot_change_owner(self):
        self.store.provision(self.body)
        with self.assertRaises(ProvisioningError) as error:
            self.store.provision(dict(self.body, owner_id="c" * 64))
        self.assertEqual(error.exception.message, "idempotency_key_conflict")

    def test_monitor_unavailable_fails_closed(self):
        self.now += 11
        with self.assertRaises(ProvisioningError):
            self.store.provision(self.body)

    def test_two_sessions_wrong_password_and_overuse_recovery(self):
        old = self.store.provision(self.body)
        def auth(cid, password=old["password"]):
            return self.store.authorize("udp", cid, old["username"], password)
        for cid in ("1", "2"):
            self.assertTrue(auth(cid))
            self.store.established("udp", cid)
        self.assertFalse(auth("3", "wrong"))
        self.now += 31
        self.store.heartbeat("udp", True)
        self.assertFalse(auth("3"))
        self.assertEqual(self.store.status()["credentials"][0]["state"], "active")
        self.store.reconcile("udp", {"1", "2"})
        self.now += 31
        self.store.heartbeat("udp", True)
        self.assertFalse(auth("3"))
        self.assertEqual(self.store.reconcile("udp", {"1", "2"}), ["1", "2"])
        recovery = dict(self.body, request_id="d" * 32, recover=True)
        with self.assertRaises(ProvisioningError):
            self.store.provision(recovery)
        for cid in ("1", "2"):
            self.store.disconnected("udp", cid)
        self.store.reconcile("udp", set())
        new = self.store.provision(recovery)
        self.assertEqual(new["version"], 2)
        self.assertNotEqual(new["password"], old["password"])
        self.assertFalse(auth("4"))
        self.assertTrue(auth("4", new["password"]))
        self.assertEqual(new, self.store.provision(recovery))

    def test_unsupported_protocol_is_not_silently_enabled(self):
        with self.assertRaises(ProvisioningError):
            self.store.provision(dict(self.body, protocol="ssh"))

    def test_expired_credential_requires_recovery_and_rotates_once(self):
        old = self.store.provision(self.body)
        self.now = old["expires_at"] + 1
        self.store.heartbeat("udp", True)
        with self.assertRaises(ProvisioningError) as error:
            self.store.provision(dict(self.body, request_id="e" * 32))
        self.assertEqual(error.exception.message, "credential_expired")

        recovery = dict(self.body, request_id="f" * 32, recover=True)
        new = self.store.provision(recovery)
        self.assertEqual(new["version"], old["version"] + 1)
        self.assertNotEqual(new["password"], old["password"])
        self.assertGreater(new["expires_at"], self.now)
        self.assertEqual(new, self.store.provision(recovery))

    def test_expired_credential_does_not_rotate_with_active_session(self):
        old = self.store.provision(self.body)
        self.assertTrue(self.store.authorize("udp", "10", old["username"], old["password"]))
        self.store.established("udp", "10")
        self.now = old["expires_at"] + 1
        self.store.heartbeat("udp", True)
        with self.assertRaises(ProvisioningError) as error:
            self.store.provision(dict(self.body, request_id="f" * 32, recover=True))
        self.assertEqual(error.exception.message, "credential_disconnect_pending")


if __name__ == "__main__":
    unittest.main()
