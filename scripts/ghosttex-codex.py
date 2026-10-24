#!/usr/bin/env python3
"""Run Codex with original Markdown output for Ghosttex native math.

Codex's interactive renderer removes math and code delimiters. This adapter
uses its supported `exec --json` interface, preserves completed assistant
messages, fences tool output, and resumes the session between prompts.
Codex authentication, providers, sandbox, and approvals keep their CLI defaults.
Pass Codex options after --. No credentials or global configuration are edited.
"""
import argparse
from collections import deque
import json
import os
import re
import signal
import subprocess
import sys
import threading

MAX_EVENT = 1024 * 1024


def mark(code):
    if sys.stdout.isatty():
        print(f"\x1b]133;{code}\x1b\\", end="", flush=True)


def terminal_text(text):
    """Keep Markdown/TeX and Unicode; never execute model-provided VT controls."""
    text = text.replace("\r\n", "\n")
    return "".join(c if c in "\n\t" or ord(c) >= 32 and ord(c) != 127 and not 0x80 <= ord(c) < 0xA0
                   else f"\\x{ord(c):02x}" for c in text)


def code_output(text):
    text = terminal_text(text)
    longest = max((len(m.group()) for m in re.finditer(r"`+", text)), default=0)
    fence = "`" * max(3, longest + 1)
    print(f"{fence}\n{text}\n{fence}", flush=True)


def run_turn(prompt, session, codex_args, executable="codex"):
    mark("C")
    command = [executable, "exec", "--json"]
    if session:
        command += ["resume", session]
    command += codex_args + ["--", prompt]
    errors = deque(maxlen=64)
    process = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                               stderr=subprocess.PIPE, start_new_session=True)

    def read_errors():
        while True:
            line = process.stderr.readline(8192)
            if not line:
                return
            errors.append(line.decode("utf-8", "replace"))

    error_reader = threading.Thread(target=read_errors, daemon=True)
    error_reader.start()
    failed = False
    seen = set()
    try:
        while True:
            line = process.stdout.readline(MAX_EVENT + 1)
            if not line:
                break
            if len(line) > MAX_EVENT:
                raise ValueError("Codex event exceeds 1 MiB")
            try:
                event = json.loads(line)
            except (ValueError, UnicodeDecodeError):
                raise ValueError("Codex emitted an invalid JSON event") from None
            kind = event.get("type")
            if kind == "thread.started":
                identifier = event.get("thread_id", "")
                if re.fullmatch(r"[0-9a-fA-F-]{36}", identifier):
                    session = identifier
            elif kind == "item.completed":
                item = event.get("item", {})
                identifier = item.get("id")
                if identifier in seen:
                    continue
                seen.add(identifier)
                if item.get("type") == "agent_message":
                    print(terminal_text(item.get("text", "")), flush=True)
                    print(flush=True)
                elif item.get("type") == "command_execution":
                    code_output(item.get("command", "") + "\n" + item.get("aggregated_output", ""))
            elif kind in ("error", "turn.failed"):
                failed = True
                detail = event.get("message") or event.get("error", {}).get("message") or "Codex turn failed"
                code_output(str(detail))
        status = process.wait()
        if status != 0:
            failed = True
    except KeyboardInterrupt:
        failed = True
        os.killpg(process.pid, signal.SIGINT)
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait()
        print("\n[Canceled]", flush=True)
    except Exception:
        if process.poll() is None:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait()
        raise
    finally:
        error_reader.join(timeout=2)
        process.stdout.close()
        process.stderr.close()
    if failed and errors:
        code_output("".join(errors).strip())
    mark("D;1" if failed else "D;0")
    return session, failed


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--once", help="run one prompt and exit")
    parser.add_argument("--prompt", help="initial prompt before entering the input loop")
    parser.add_argument("--codex", default="codex", help="Codex CLI executable")
    parser.add_argument("--session", help="resume an existing Codex session")
    parser.add_argument("codex_args", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    forwarded = args.codex_args[1:] if args.codex_args[:1] == ["--"] else args.codex_args
    session = args.session
    if session and not re.fullmatch(r"[0-9a-fA-F-]{36}", session):
        parser.error("session must be a Codex UUID")
    if args.once is not None:
        _, failed = run_turn(args.once, session, forwarded, args.codex)
        return int(failed)
    try:
        import readline  # noqa: F401 -- use native line editing when available
    except ImportError:
        pass
    print("Ghosttex / Codex raw Markdown. /new starts a session; /quit exits.", flush=True)
    prompt = args.prompt
    while True:
        if prompt is None:
            try:
                marker = "\x01\x1b]133;A\x1b\\\x02› \x01\x1b]133;B\x1b\\\x02" if sys.stdout.isatty() else "› "
                prompt = input(marker)
            except EOFError:
                print()
                break
            except KeyboardInterrupt:
                print()
                continue
        if prompt == "/quit":
            break
        if prompt == "/new":
            session = None
        elif prompt.strip():
            session, _ = run_turn(prompt, session, forwarded, args.codex)
        prompt = None
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
