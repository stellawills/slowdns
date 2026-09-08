import hashlib
import json
import pathlib
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]


class GeneratedInstallerParityTests(unittest.TestCase):
    def extract(self, installer: str, start: str, end: str) -> str:
        try:
            payload = installer.split(start + "\n", 1)[1].split("\n" + end + "\n", 1)[0]
        except IndexError as exc:
            self.fail(f"generated installer is missing {start} ... {end}: {exc}")
        return payload.rstrip("\n") + "\n"

    def test_generated_runtime_files_match_sources(self) -> None:
        installer = (ROOT / "iptunnel-install.sh").read_text(encoding="utf-8")
        fixtures = (
            ("cat >/opt/iptunnel/iptunnel_api.py <<'PYCODE'", "PYCODE", "iptunnel_api.py"),
            ("cat >/usr/local/bin/iptunnel-menu <<'MENU'", "MENU", "iptunnel_menu.sh"),
            ("cat >/opt/iptunnel/transport_stack.sh <<'STACK'", "STACK", "transport_stack.sh"),
        )
        for start, end, source_name in fixtures:
            with self.subTest(source=source_name):
                source = (ROOT / source_name).read_text(encoding="utf-8")
                self.assertEqual(self.extract(installer, start, end), source)

    def test_generated_installer_contains_current_release(self) -> None:
        installer = (ROOT / "iptunnel-install.sh").read_text(encoding="utf-8")
        self.assertIn('APP_VERSION = "2026.09.06.1"', installer)
        self.assertIn('MENU_VERSION="2026.09.06.1"', installer)

    def test_release_manifest_matches_generated_installer(self) -> None:
        installer = (ROOT / "iptunnel-install.sh").read_bytes()
        manifest = json.loads(
            (ROOT / "license_server_php" / "version.json").read_text(encoding="utf-8")
        )
        self.assertEqual(manifest["version"], "2026.09.06.1")
        self.assertEqual(manifest["sha256"], hashlib.sha256(installer).hexdigest())


if __name__ == "__main__":
    unittest.main()
