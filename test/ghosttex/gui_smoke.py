#!/usr/bin/env python3
"""Linux native-window correctness smoke; run under dbus-run-session/xvfb-run.

Checks asynchronous math arrival, PTY coordinate queries, responsive input,
source toggling, unchanged fixed footer pixels, and clean worker shutdown.
This is a correctness test using software GL, not a hardware frame-rate test.
"""
import argparse
import ctypes
import json
import os
from pathlib import Path
import re
import select
import subprocess
import sys
import termios
import time
import tty


def writer(output):
    previous = termios.tcgetattr(0)
    tty.setraw(0)
    try:
        rows = os.get_terminal_size().lines
        (output / "geometry.json").write_text(json.dumps({"rows": rows, "columns": os.get_terminal_size().columns}))
        content = (
            "Ghosttex native math / PTY fixture\r\n\r\n"
            "Inline: \\(x_1^2 + \\sqrt{y}\\) continues here.\r\n"
            "Fraction:\r\n$$\r\n\\frac{a+b}{\\sqrt{c^2+d^2}}\r\n$$\r\n"
            "Matrix: \\[\\begin{pmatrix}a&b\\\\c&d\\end{pmatrix}\\]\r\n"
            "Cases: \\[f(x)=\\begin{cases}x^2&x>0\\\\0&x\\le0\\end{cases}\\]\r\n"
            "Align: \\[\\begin{aligned}a&=b+c\\\\d&=e\\end{aligned}\\]\r\n"
            "Unicode: \\(\\text{中文} + x\\)\r\n"
            "```sh\r\n\\(must remain code\\) $HOME ${PATH} $5 and $10\r\n```\r\n"
            "Failure source: \\(\\unknownGhosttexCommand{x}\\)\r\n"
        )
        os.write(1, content.encode())
        footer = f"\x1b[{rows-2};1H" + "-" * 80 + f"\x1b[{rows-1};1H> input: \x1b[{rows};1Hfixed status"
        os.write(1, footer.encode())
        os.write(1, f"\x1b[{rows-1};10H\x1b[6n".encode())
        response = b""
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            ready, _, _ = select.select([0], [], [], 0.1)
            if ready:
                response += os.read(0, 1024)
                if b"R" in response:
                    break
        expected = f"\x1b[{rows-1};10R".encode()
        assert expected in response, (expected, response)
        (output / "dsr.txt").write_text(response.hex())
        deadline = time.monotonic() + 40
        while time.monotonic() < deadline:
            ready, _, _ = select.select([0], [], [], 0.1)
            if not ready:
                continue
            data = os.read(0, 1024)
            with (output / "input.bin").open("ab") as file:
                file.write(data)
            if b"q" in data:
                break
            if b"x" in data:
                os.write(1, b"x")
    finally:
        termios.tcsetattr(0, termios.TCSANOW, previous)


class Keyboard:
    def __init__(self):
        self.x = ctypes.CDLL("libX11.so.6")
        self.xt = ctypes.CDLL("libXtst.so.6")
        self.x.XOpenDisplay.argtypes = [ctypes.c_char_p]
        self.x.XOpenDisplay.restype = ctypes.c_void_p
        self.x.XStringToKeysym.argtypes = [ctypes.c_char_p]
        self.x.XStringToKeysym.restype = ctypes.c_ulong
        self.x.XKeysymToKeycode.argtypes = [ctypes.c_void_p, ctypes.c_ulong]
        self.x.XKeysymToKeycode.restype = ctypes.c_uint
        self.x.XFlush.argtypes = [ctypes.c_void_p]
        self.x.XGetInputFocus.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_ulong), ctypes.POINTER(ctypes.c_int)]
        self.x.XCloseDisplay.argtypes = [ctypes.c_void_p]
        self.xt.XTestFakeKeyEvent.argtypes = [ctypes.c_void_p, ctypes.c_uint, ctypes.c_int, ctypes.c_ulong]
        self.display = self.x.XOpenDisplay(None)
        if not self.display:
            raise RuntimeError("X display unavailable; run under xvfb-run")

    def key(self, name, pressed):
        symbol = self.x.XStringToKeysym(name.encode())
        code = self.x.XKeysymToKeycode(self.display, symbol)
        self.xt.XTestFakeKeyEvent(self.display, code, pressed, 0)
        self.x.XFlush(self.display)

    def type(self, name):
        self.key(name, True)
        self.key(name, False)

    def toggle(self):
        self.key("Control_L", True)
        self.key("Shift_L", True)
        self.type("m")
        self.key("Shift_L", False)
        self.key("Control_L", False)

    def control(self, name, shift=False):
        self.key("Control_L", True)
        if shift:
            self.key("Shift_L", True)
        self.type(name)
        if shift:
            self.key("Shift_L", False)
        self.key("Control_L", False)

    def focus(self):
        window = ctypes.c_ulong()
        revert = ctypes.c_int()
        self.x.XGetInputFocus(self.display, ctypes.byref(window), ctypes.byref(revert))
        return window.value

    def close(self):
        self.x.XCloseDisplay(self.display)


def wait_for(predicate, process, timeout=20):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if process.poll() is not None:
            raise RuntimeError(f"Ghosttex exited early: {process.returncode}")
        if predicate():
            return
        time.sleep(0.05)
    raise TimeoutError("window test condition did not arrive")


def run(args):
    from PIL import Image, ImageChops

    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    environment = os.environ.copy()
    environment.update(GDK_BACKEND="x11", LIBGL_ALWAYS_SOFTWARE="1")
    command = [str(args.binary.resolve()), "--config-default-files=false", "--gtk-single-instance=false",
               "--linux-cgroup=never", "--quit-after-last-window-closed=true", "--wait-after-command=false",
               "--shell-integration=none", "--window-width=96", "--window-height=32", "--font-size=14",
               "--window-padding-x=0", "--window-padding-y=0", "--gtk-titlebar=false", "--window-decoration=false",
               "--title=Ghosttex Math Smoke", "--cursor-style-blink=false", "--math-rendering=true",
               "--math-single-dollar=true",
               "--keybind=ctrl+shift+m=toggle_math_rendering", "--keybind=ctrl+shift+o=write_screen_file:copy,vt"]
    command += ["-e", sys.executable, str(Path(__file__).resolve()), "--writer", "--output", str(output)]
    log_path = output / "window.log"
    with log_path.open("w") as log:
        process = subprocess.Popen(command, stdout=log, stderr=log, env=environment)
        keyboard = None
        try:
            wait_for(lambda: (output / "dsr.txt").exists(), process)
            expected = 6 if environment.get("RATEX_UNICODE_FONT") else 5
            wait_for(lambda: any(int(n) >= expected for n in re.findall(r"math frame ready=(\d+)", log_path.read_text())), process)
            keyboard = Keyboard()
            keyboard.type("x")
            wait_for(lambda: (output / "input.bin").exists() and b"x" in (output / "input.bin").read_bytes(), process)
            time.sleep(0.2)
            window = str(keyboard.focus())
            subprocess.run(["import", "-window", window, str(output / "native.png")], check=True)
            keyboard.toggle()
            time.sleep(0.3)
            subprocess.run(["import", "-window", window, str(output / "source.png")], check=True)
            native = Image.open(output / "native.png").convert("RGB")
            source = Image.open(output / "source.png").convert("RGB")
            assert native.size == source.size
            difference = ImageChops.difference(native, source)
            assert difference.getbbox() is not None, "math toggle did not change the window"
            terminal_rows = json.loads((output / "geometry.json").read_text())["rows"]
            cell_height = native.height // terminal_rows
            footer_top = native.height - 3 * cell_height
            assert difference.crop((0, footer_top, native.width, native.height)).getbbox() is None, "fixed input/status rows moved"
            keyboard.toggle()
            time.sleep(0.3)
            for _ in range(args.cycles):
                keyboard.toggle()
                time.sleep(0.03)
                keyboard.toggle()
                time.sleep(0.03)
            if args.cycles:
                time.sleep(0.3)
            keyboard.type("q")
            assert process.wait(timeout=10) == 0
            text = log_path.read_text()
            assert "panic:" not in text and "error(gpa)" not in text, text[-4000:]
            print("GTK/OpenGL math, source toggle, fixed footer, PTY DSR, input, and shutdown passed")
            print(output)
        finally:
            if keyboard:
                keyboard.close()
            if process.poll() is None:
                process.terminate()
                process.wait(timeout=10)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--writer", action="store_true")
    parser.add_argument("--cycles", type=int, default=0, help="stress source/native cancellation and reactivation")
    parser.add_argument("--output", type=Path, default=Path(".zig-cache/ghosttex-gui"))
    parser.add_argument("--binary", type=Path, default=Path("zig-out/bin/ghostty"))
    arguments = parser.parse_args()
    if arguments.writer:
        writer(arguments.output)
    else:
        run(arguments)
