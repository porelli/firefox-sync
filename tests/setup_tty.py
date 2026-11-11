#!/usr/bin/env python3
"""prepare_environment.sh on a terminal (a pty): its menus, answers edited in place, the review.

Usage: python3 -I tests/setup_tty.py <checkout> [--capture]

Runs the setup in <checkout> (a copy: it writes .env there) on a pseudo-terminal, as a person
would: it waits for each question, then types. The flow: the domain edited in place, a public
URL with a path (refused, asked again with it to edit), the Sync server's engine picked by its
number, the max users then < from the next question, the self-hosted accounts by the arrow
keys, the admin UI signing in with them, then in the review a part changed (2, the Sync
server: its questions again, the parts after it kept) and written. Checks the .env written,
and that the admin UI's password is shown on the terminal. The environment of the setup is
this one's (tests/setup_output.sh gives it stubs and a temporary HOME). --capture prints the
screen at each step instead (docs, review). Stdlib only (pty: Linux, macOS).
"""

import os
import pty
import re
import select
import signal
import sys
import time

ANSI = re.compile(r"\x1b\[[0-9;?]*[A-Za-z]|\x1b[()][0-9A-B]|\x1b[=>]")
UP, DOWN, KILL = "\x1b[A", "\x1b[B", "\x15"

# (what to wait for, what to type, a caption for --capture)
FLOW = [
    ("Directory of the checkout", "\r", "the first question: its part, its hint, the default ready to edit"),
    ("User that runs docker compose", "\r", None),
    ("Your domain", KILL + "example.org\r", None),
    ("Public URL of the Sync server", KILL + "sync.example.org/sync\r", None),
    (r"ERROR: the Sync server's public URL: only https://host", KILL + "https://sync.example.org\r",
     "an answer that is not valid: said, the same question again with it to edit"),
    ("listens on", "\r", None),
    ("Image tag", "\r", None),
    ("Engine of the Sync server", "3", "a list: the arrows, Enter or a number"),
    ("own server", "\r", None),
    ("Max users", KILL + "5\r", None),
    ("Which accounts", "<", None),
    ("Max users", KILL + "2\r", "< at the next question: back here, the answer typed before ready to edit"),
    ("Which accounts", DOWN, None),
    ("service runs here", "\r", "the description of the option selected, under the list"),
    ("Public URL of the accounts pages", "\r", None),
    ("Public URL of the accounts API", "\r", None),
    ("profile server", "\r", None),
    ("Engine of the self-hosted", "\r", None),
    ("accounts' database on your own", "\r", None),
    ("SMTP server for", "smtp.example.org\r", None),
    ("SMTP port", "\r", None),
    ("SMTP user", "\r", None),
    ("SMTP password", "s3cret\r", None),
    ("Sender of the emails", "\r", None),
    ("Who can create an account", "\r", None),
    ("Max accounts", "\r", None),
    ("security history", "\r", None),
    ("own pairing server", "\r", None),
    ("Run the admin UI", "\r", None),
    ("How admins sign in", DOWN, None),
    (r"self-hosted Mozilla accounts \(OpenID", "\r", "how admins sign in"),
    ("Public URL of the admin UI", "\r", None),
    ("Who is an admin", "me@example.org\r", None),
    ("Keep a password as a fallback", "\r", None),
    ("Destinations of the alerts", "\r", None),
    ("Reset Sync data through the Sync server", "\r", None),
    ("Enable nightly backups", "\r", None),
    ("Do you already run a reverse proxy", "\r", None),
    ("Who can open the admin UI's public address", "\r", None),
    ("Change any of these ports", "\r", "the ports of this host the stack listens on, the next free one where something listens"),
    ("How your proxy has their certificates", "\r", None),
    ("write .env and the examples now", "2", "the review: every answer, the secrets it generates named"),
    ("Public URL of the Sync server", "\r", "a part changed from the review: its questions again"),
    ("listens on", "\r", None),
    ("Image tag", "\r", None),
    ("Engine of the Sync server", "\r", None),
    ("own server", "\r", None),
    ("Max users", KILL + "3\r", None),
    ("write .env and the examples now", "\r", "the review again: the parts after it kept their answers"),
]


class Screen:
    """Enough of a terminal for the captures: text, CR, LF, cursor up and down, erase."""

    def __init__(self):
        self.lines, self.row, self.col = [""], 0, 0

    def feed(self, data):
        i = 0
        while i < len(data):
            m = re.match(r"\x1b\[([0-9;?]*)([A-Za-z])", data[i:])
            if m:
                arg, cmd = m.group(1), m.group(2)
                n = int(arg) if arg.isdigit() else 1
                while len(self.lines) <= self.row:
                    self.lines.append("")
                if cmd == "A":
                    self.row = max(0, self.row - n)
                elif cmd == "B":
                    self.row += n
                elif cmd == "C":
                    self.col += n
                elif cmd == "D":
                    self.col = max(0, self.col - n)
                elif cmd == "K":
                    self.lines[self.row] = "" if arg == "2" else self.lines[self.row][: self.col]
                elif cmd == "J":
                    self.lines[self.row] = self.lines[self.row][: self.col]
                    del self.lines[self.row + 1:]
                i += len(m.group(0))
                continue
            c = data[i]
            i += 1
            if c == "\x1b":
                i += 1
            elif c == "\r":
                self.col = 0
            elif c == "\n":
                self.row, self.col = self.row + 1, 0
            elif c == "\b":
                self.col = max(0, self.col - 1)
            elif c >= " ":
                while len(self.lines) <= self.row:
                    self.lines.append("")
                line = self.lines[self.row].ljust(self.col)
                self.lines[self.row] = line[: self.col] + c + line[self.col + 1:]
                self.col += 1

    def text(self, last):
        lines = [line.rstrip() for line in self.lines]
        while lines and not lines[-1]:
            lines.pop()
        return "\n".join(lines[-last:])


def main():
    checkout, capture = sys.argv[1], "--capture" in sys.argv
    pid, fd = pty.fork()
    if pid == 0:
        # (Python ignores SIGPIPE, and a child would too: then tr | head never ends)
        signal.signal(signal.SIGPIPE, signal.SIG_DFL)
        os.chdir(checkout)
        os.environ.setdefault("TERM", "xterm-256color")
        os.execvp("bash", ["bash", "./prepare_environment.sh"])
    screen, raw, seen = Screen(), "", 0

    def pump(timeout):
        nonlocal raw
        if not select.select([fd], [], [], timeout)[0]:
            return False
        try:
            data = os.read(fd, 65536).decode("utf-8", "replace")
        except OSError:
            return None
        if not data:
            return None
        raw += data
        screen.feed(data)
        return True

    for wait, keys, caption in FLOW:
        deadline, rx = time.time() + 30, re.compile(wait)
        while not rx.search(ANSI.sub("", raw[seen:])):
            if time.time() > deadline or pump(0.2) is None:
                print(f"FAIL: setup on a terminal: waited for {wait!r}; the screen:\n{screen.text(25)}")
                return 1
        # the rest of what it draws, then the keys
        time.sleep(0.1)
        while pump(0.1):
            pass
        seen = len(raw)
        if capture and caption:
            print(f"----- {caption}\n{screen.text(24)}\n", flush=True)
        os.write(fd, keys.encode())
    # what it prints until it exits (macOS: no end of file on the pty once it did)
    status, deadline = None, time.time() + 60
    while status is None and time.time() < deadline:
        if pump(0.5) is None:
            break
        done, code = os.waitpid(pid, os.WNOHANG)
        if done:
            status = os.waitstatus_to_exitcode(code)
    while pump(0.2):
        pass
    if status is None:
        status = os.waitstatus_to_exitcode(os.waitpid(pid, 0)[1])
    if capture:
        print(f"----- the end: what it wrote, the secrets it generated\n{screen.text(40)}\n")
    env = {}
    try:
        for line in open(os.path.join(checkout, ".env")):
            if "=" in line and not line.startswith("#"):
                key, value = line.rstrip("\n").split("=", 1)
                env[key] = value
    except OSError:
        pass
    want = {"SYNC_PUBLIC_URL": "https://sync.example.org", "SYNC_IMAGE": "syncstorage-rs-postgres",
            "SYNC_MAX_USERS": "initial:3", "FXA_CONTENT_URL": "https://accounts.example.org",
            "FXA_SMTP_PASS": "'s3cret'", "ADMIN_ALLOWED_USERS": "me@example.org",
            "ADMIN_OIDC_REDIRECT_URL": "https://admin.example.org/auth/callback"}
    got = {key: env.get(key) for key in want}
    plain = ANSI.sub("", raw)
    password = env.get("ADMIN_PASSWORD", "")
    shown = bool(password) and f"ADMIN_PASSWORD: the admin UI's sign-in password: {password}" in plain
    failed = 0
    for ok, what in ((status == 0, f"the setup on a terminal ends with 0 (got {status})"),
                     (got == want, f"the menus, the answers edited in place, < and the review wrote .env ({got})"),
                     (shown, "the admin UI's password shown once on the terminal"),
                     (plain.count("Which accounts people sign in with") == 3, "the parts after the one changed in the review not asked again")):
        print(("PASS: " if ok else "FAIL: ") + what)
        failed |= not ok
    return failed


sys.exit(main())
