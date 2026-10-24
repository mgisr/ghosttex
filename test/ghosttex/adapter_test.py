#!/usr/bin/env python3
"""Deterministic Codex integration and terminal-control filtering tests."""
import importlib.util
from pathlib import Path
import subprocess
import sys
import threading
import unittest

from codex_fixture import Handler, MARKDOWN, ThreadingHTTPServer, arguments

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("ghosttex_codex", ROOT / "scripts/ghosttex-codex.py")
ADAPTER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(ADAPTER)


class AdapterTest(unittest.TestCase):
    def test_terminal_controls_are_data_and_tex_is_unchanged(self):
        source = "\\(x_1\\)\n$5 and $HOME\t\x1b]52;c;payload\x07\r\x9b"
        clean = ADAPTER.terminal_text(source)
        self.assertTrue(clean.startswith("\\(x_1\\)\n$5 and $HOME\t"))
        self.assertNotIn("\x1b", clean)
        self.assertNotIn("\x07", clean)
        self.assertNotIn("\x9b", clean)

    def test_real_codex_json_preserves_markdown_and_code_boundaries(self):
        server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        try:
            command = [sys.executable, str(ROOT / "scripts/ghosttex-codex.py"), "--once", "Emit the fixture.",
                       "--", "--skip-git-repo-check", "--ephemeral"] + arguments(server.server_port)
            result = subprocess.run(command, cwd=ROOT, capture_output=True, text=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
            self.assertIn(MARKDOWN.strip(), result.stdout)
            self.assertIn("```sh", result.stdout)
            self.assertIn("`\\(not math\\)`", result.stdout)
        finally:
            server.shutdown()
            server.server_close()


if __name__ == "__main__":
    unittest.main()
