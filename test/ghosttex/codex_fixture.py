#!/usr/bin/env python3
"""Deterministic local Responses API fixture for testing the real Codex CLI.

No account, API key, model invocation, or external network connection is used.
The fixed response is deliberately Markdown with TeX and misleading code/price
content, so terminal captures can establish which source survives CLI styling.
"""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import argparse
import json
import subprocess
import threading

MARKDOWN = r"""Inline math: \(x_1^2 + \sqrt{y}\).

Dollar inline: $x_2 + \sqrt{z}$.

Inline code: `\(not math\)`.

$$
\frac{a+b}{c+d}
$$

```sh
echo '$HOME costs $5; \(not math\)'
```

Matrix: \[\begin{pmatrix}a&b\\c&d\end{pmatrix}\]
"""


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(json.dumps({"data": [{"id": "ghosttex-fixture", "object": "model"}]}).encode())

    def do_POST(self):
        self.server.requests = getattr(self.server, "requests", 0) + 1
        self.rfile.read(int(self.headers.get("Content-Length", 0)))
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Connection", "close")
        self.end_headers()
        item = {"type": "message", "id": "msg_fixture", "role": "assistant", "status": "completed",
                "content": [{"type": "output_text", "text": MARKDOWN, "annotations": []}]}
        events = [
            {"type": "response.created", "response": {"id": "resp_fixture", "status": "in_progress", "output": []}},
            {"type": "response.output_item.added", "output_index": 0,
             "item": {"type": "message", "id": "msg_fixture", "role": "assistant", "content": []}},
            {"type": "response.content_part.added", "item_id": "msg_fixture", "output_index": 0,
             "content_index": 0, "part": {"type": "output_text", "text": "", "annotations": []}},
        ]
        events += [{"type": "response.output_text.delta", "item_id": "msg_fixture", "output_index": 0,
                    "content_index": 0, "delta": MARKDOWN[i:i+7]} for i in range(0, len(MARKDOWN), 7)]
        events += [
            {"type": "response.output_text.done", "item_id": "msg_fixture", "output_index": 0,
             "content_index": 0, "text": MARKDOWN},
            {"type": "response.output_item.done", "output_index": 0, "item": item},
            {"type": "response.completed", "response": {"id": "resp_fixture", "status": "completed",
             "output": [item], "usage": {"input_tokens": 1, "output_tokens": 100, "total_tokens": 101}}},
        ]
        for event in events:
            self.wfile.write(("data: " + json.dumps(event) + "\n\n").encode())
            self.wfile.flush()


def arguments(port):
    return ["-c", 'model_provider="ghosttex_fixture"', "-c", 'model="ghosttex-fixture"',
            "-c", 'model_providers.ghosttex_fixture.name="Ghosttex local fixture"',
            "-c", f'model_providers.ghosttex_fixture.base_url="http://127.0.0.1:{port}/v1"',
            "-c", 'model_providers.ghosttex_fixture.wire_api="responses"',
            "-c", "model_providers.ghosttex_fixture.requires_openai_auth=false"]


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--serve", action="store_true")
    parser.add_argument("--port", type=int, default=0)
    args = parser.parse_args()
    server = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    if args.serve:
        print(server.server_port, flush=True)
        server.serve_forever()
    else:
        threading.Thread(target=server.serve_forever, daemon=True).start()
        try:
            command = ["codex", "exec", "--skip-git-repo-check", "--ephemeral", "--color", "never"]
            result = subprocess.run(command + arguments(server.server_port) + ["Emit the math fixture without tools."],
                                    capture_output=True, text=True, timeout=30)
            assert result.returncode == 0, result.stderr
            assert MARKDOWN.strip() in result.stdout, result.stdout
            print("Codex CLI exec preserves the fixture's raw Markdown and TeX")
        finally:
            server.shutdown()
            server.server_close()
