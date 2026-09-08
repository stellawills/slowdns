import copy
import hashlib
import json
import pathlib
import subprocess
import sys
import tempfile
import unittest
from unittest import mock


sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))

import iptunnel_api as api


class Udp53ModeTests(unittest.TestCase):
    def make_state(self, config_path: pathlib.Path) -> api.IptunnelState:
        config = copy.deepcopy(api.DEFAULT_CONFIG)
        config["config_path"] = str(config_path)
        config["hostname"] = "vpn.example.com"
        config["slowdns"]["enabled"] = True
        config["slowdns"]["udp53_mode"] = "slowdns"
        config["openvpn"]["enabled"] = False
        config["openvpn"]["udp_public_port"] = 1194
        config["openvpn"]["udp_public_ports"] = [1194]
        state = api.IptunnelState(config, dry_run=True)
        state.save_config()
        return state

    def test_openvpn_mode_is_saved_before_transport_and_verified(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            config_path = pathlib.Path(tmp) / "config.json"
            state = self.make_state(config_path)

            def run(command, **kwargs):
                saved = json.loads(config_path.read_text(encoding="utf-8"))
                self.assertEqual(saved["slowdns"]["udp53_mode"], "openvpn")
                self.assertFalse(saved["slowdns"]["enabled"])
                self.assertTrue(saved["openvpn"]["enabled"])
                self.assertEqual(saved["openvpn"]["udp_public_ports"], [53, 1194])
                self.assertEqual(kwargs["env"]["IPTUNNEL_SLOWDNS_UDP53_MODE"], "openvpn")
                return subprocess.CompletedProcess(command, 0, "", "")

            with mock.patch.object(state, "_ensure_linux"), mock.patch.object(api.subprocess, "run", side_effect=run):
                result = state.set_udp53_mode("openvpn")

            self.assertEqual(result["udp53_mode"], "openvpn")
            self.assertEqual(result["udp_public_ports"], [53, 1194])

    def test_transport_failure_restores_previous_config(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            config_path = pathlib.Path(tmp) / "config.json"
            state = self.make_state(config_path)
            calls = 0

            def run(command, **kwargs):
                nonlocal calls
                calls += 1
                return subprocess.CompletedProcess(command, 1 if calls == 1 else 0, "", "runtime failed")

            with mock.patch.object(state, "_ensure_linux"), mock.patch.object(api.subprocess, "run", side_effect=run):
                with self.assertRaises(api.ApiError):
                    state.set_udp53_mode("openvpn")

            saved = json.loads(config_path.read_text(encoding="utf-8"))
            self.assertEqual(saved["slowdns"]["udp53_mode"], "slowdns")
            self.assertTrue(saved["slowdns"]["enabled"])
            self.assertFalse(saved["openvpn"]["enabled"])

    def test_false_success_is_rejected_and_rolled_back(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            config_path = pathlib.Path(tmp) / "config.json"
            state = self.make_state(config_path)
            calls = 0

            def run(command, **kwargs):
                nonlocal calls
                calls += 1
                if calls == 1:
                    saved = json.loads(config_path.read_text(encoding="utf-8"))
                    saved["slowdns"]["udp53_mode"] = "slowdns"
                    config_path.write_text(json.dumps(saved, indent=2) + "\n", encoding="utf-8")
                return subprocess.CompletedProcess(command, 0, "", "")

            with mock.patch.object(state, "_ensure_linux"), mock.patch.object(api.subprocess, "run", side_effect=run):
                with self.assertRaisesRegex(api.ApiError, "did not persist"):
                    state.set_udp53_mode("openvpn")

            saved = json.loads(config_path.read_text(encoding="utf-8"))
            self.assertEqual(saved["slowdns"]["udp53_mode"], "slowdns")
            self.assertFalse(saved["openvpn"]["enabled"])


class UpdateInstallerVerificationTests(unittest.TestCase):
    def test_matching_release_and_hash_are_accepted(self) -> None:
        data = b'APP_VERSION = "2026.08.27.1"\nMENU_VERSION="2026.08.27.1"\n'
        expected = hashlib.sha256(data).hexdigest()
        self.assertEqual(api.IptunnelState.verify_update_installer(data, "2026.08.27.1", expected), expected)

    def test_stale_installer_is_rejected(self) -> None:
        data = b'APP_VERSION = "2026.08.22.3"\nMENU_VERSION="2026.08.22.3"\n'
        with self.assertRaisesRegex(api.ApiError, "does not contain release"):
            api.IptunnelState.verify_update_installer(data, "2026.08.27.1")

    def test_hash_mismatch_is_rejected(self) -> None:
        data = b'APP_VERSION = "2026.08.27.1"\nMENU_VERSION="2026.08.27.1"\n'
        with self.assertRaisesRegex(api.ApiError, "does not match"):
            api.IptunnelState.verify_update_installer(data, "2026.08.27.1", "0" * 64)

if __name__ == "__main__":
    unittest.main()
