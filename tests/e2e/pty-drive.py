#!/usr/bin/env python3
"""Run a command on a pseudo-terminal and answer marmot's prompts as a person would.

    pty-drive.py --log FILE [--timeout SECONDS] -- COMMAND [ARG...]

Nothing is typed ahead: the driver waits until the command has printed a prompt and gone quiet,
then answers that prompt, so every answer goes to the question it is meant for.

  "... [y/N] "                       y        every confirmation is accepted
  "Purge which artifacts? ..."       s        stale artifacts only (marmot's default)
  fzf picker ("filter> ")            ctrl-a, Enter: everything marmot offered

Accepting everything is deliberate: what must survive has to be protected by marmot's own
checks, not by the answers. The terminal output (escape sequences and carriage returns removed)
goes to FILE, followed by one "pty-drive: <kind>: <prompt> -> <answer>" line per answer. Exits
with the command's status; 124 when it runs longer than --timeout (default 600) or sits at output
the driver does not recognize for 120 seconds.
"""
import argparse
import fcntl
import os
import pty
import re
import select
import signal
import struct
import sys
import termios
import time

ESCAPES = re.compile(rb"\x1b\[[0-?]*[ -/]*[@-~]|\x1b\][^\x07]*\x07|\x1b[()][0-9A-Za-z]|\x1b[=>78]|\r|\x07")
QUIET = 0.5    # seconds without output before the tail counts as a waiting prompt
STUCK = 120    # seconds at an unrecognized quiet tail before giving up

RULES = [
    # fzf draws its header and prompt with cursor movements; the prompt survives the stripping.
    ("picker", re.compile(r"filter> "), [b"\x01", b"\r"]),
    ("artifacts", re.compile(r"Purge which artifacts\?[^\n]*\[n\]one *$"), [b"s\r"]),
    ("confirm", re.compile(r"\[y/N\] *$"), [b"y\r"]),
]


class Session:
    def __init__(self, fd, log):
        self.fd, self.log = fd, log
        self.text = ""          # everything the command printed, escapes stripped
        self.last_out = time.monotonic()

    def pump(self, seconds):
        """Read output for up to SECONDS; False once the command has closed the terminal."""
        end = time.monotonic() + seconds
        while True:
            r, _, _ = select.select([self.fd], [], [], max(end - time.monotonic(), 0))
            if not r:
                return True
            try:
                data = os.read(self.fd, 65536)
            except OSError:
                data = b""
            if not data:
                return False
            # fzf's --height mode asks where the cursor is (DSR) and waits for the answer
            for _ in range(data.count(b"\x1b[6n")):
                os.write(self.fd, b"\x1b[1;1R")
            chunk = ESCAPES.sub(b"", data).decode("utf-8", "replace")
            self.text += chunk
            self.log.write(chunk)
            self.log.flush()
            self.last_out = time.monotonic()


def drive(s, timeout):
    """Answer prompts until the command closes the terminal (True) or it has to be stopped."""
    consumed = 0                # text before this offset has been answered already
    answers = []
    start = time.monotonic()
    try:
        while time.monotonic() - start < timeout:
            if not s.pump(0.1):
                return True
            quiet = time.monotonic() - s.last_out
            if quiet < QUIET:
                continue
            tail = s.text[consumed:]
            for name, pattern, keys in RULES:
                m = pattern.search(tail)
                if not m:
                    continue
                line = tail[: m.end()].rstrip().rsplit("\n", 1)[-1].strip()
                consumed = len(s.text)
                for k in keys:
                    os.write(s.fd, k)
                    s.pump(0.3)
                if name == "picker":
                    # fzf redraws its prompt while it runs: only what follows the last one is new
                    s.pump(0.5)
                    consumed = max(consumed, s.text.rfind("filter> ") + len("filter> "))
                answers.append("pty-drive: %s: %s -> %r" % (name, line[-150:], b"".join(keys).decode()))
                break
            else:
                if quiet > STUCK:
                    s.log.write("\npty-drive: no known prompt for %ds; last output:\n%s\n" % (STUCK, tail[-600:]))
                    return False
        s.log.write("\npty-drive: timed out after %ds\n" % timeout)
        return False
    finally:
        s.log.write("\n" + "".join(x + "\n" for x in answers))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--log", required=True)
    ap.add_argument("--timeout", type=float, default=600)
    ap.add_argument("command", nargs=argparse.REMAINDER)
    a = ap.parse_args()
    cmd = a.command[1:] if a.command[:1] == ["--"] else a.command
    if not cmd:
        ap.error("no command")

    env = dict(os.environ)
    env.setdefault("TERM", "xterm")
    pid, fd = pty.fork()
    if pid == 0:
        os.execvpe(cmd[0], cmd, env)
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 50, 160, 0, 0))
    with open(a.log, "w", encoding="utf-8", errors="replace") as log:
        finished = drive(Session(fd, log), a.timeout)
    if not finished:
        for sig in (signal.SIGTERM, signal.SIGKILL):
            try:
                os.killpg(pid, sig)
            except ProcessLookupError:
                break
            time.sleep(1)
    _, st = os.waitpid(pid, 0)
    return os.waitstatus_to_exitcode(st) if finished else 124


if __name__ == "__main__":
    sys.exit(main())
