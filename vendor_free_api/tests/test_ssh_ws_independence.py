import pathlib
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]


def shell_function(source: str, name: str, next_name: str) -> str:
    start = source.index(f"{name}() {{")
    end = source.index(f"{next_name}() {{", start)
    return source[start:end]


class SshWebSocketIndependenceTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.stack = (ROOT / "transport_stack.sh").read_text(encoding="utf-8")

    def test_named_path_bridge_targets_ssh_directly(self) -> None:
        function = shell_function(self.stack, "configure_edge_proxy", "configure_fronting_proxy")
        self.assertNotIn("SLOWDNS_TARGET_PROXY", function)
        self.assertIn("After=network.target ssh.service", function)
        self.assertIn("--target-host 127.0.0.1 --target-port 22", function)

    def test_root_compatibility_bridge_targets_ssh_directly(self) -> None:
        function = shell_function(self.stack, "configure_fronting_proxy", "configure_ssh_ssl")
        self.assertNotIn("SLOWDNS_TARGET_PROXY", function)
        self.assertIn('DEFAULT_TARGET = "127.0.0.1:22"', function)
        self.assertIn("After=network.target ssh.service", function)
        self.assertIn("--default-target 127.0.0.1:22", function)

    def test_disabling_slowdns_cannot_remove_websocket_upstream(self) -> None:
        disable = shell_function(self.stack, "disable_slowdns_runtime", "configure_slowdns_target_proxy")
        self.assertIn('systemctl disable --now "${SLOWDNS_TARGET_PROXY_SERVICE}"', disable)

        edge = shell_function(self.stack, "configure_edge_proxy", "configure_fronting_proxy")
        fronting = shell_function(self.stack, "configure_fronting_proxy", "configure_ssh_ssl")
        self.assertNotIn("SLOWDNS_TARGET_PROXY_SERVICE", edge + fronting)
        self.assertNotIn("SLOWDNS_TARGET_PROXY_PORT", edge + fronting)


if __name__ == "__main__":
    unittest.main()
