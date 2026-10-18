#!/usr/bin/env python3
"""Terminal acceptance tests; all config, repositories, and tmux state are temporary."""

import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import pty
import re
import select
import shlex
import shutil
import struct
import subprocess
import tempfile
import termios
import time


PLUGIN = Path(__file__).resolve().parents[1]


def git(root, *args):
    return subprocess.check_output(["git", "-C", str(root), *args])


class Terminal:
    def __init__(self, stage, yazi, options):
        self.stage = stage
        self.root = stage / "fixture"
        self.root.mkdir()
        (self.root / "a_dual.py").write_text('value = "BASE_MARKER"\n')
        (self.root / "b_deleted.txt").write_text("DELETED_MARKER\n")
        (self.root / "d_old.txt").write_text("RENAME_MARKER\n")
        (self.root / "e_binary.dat").write_bytes(b"\0original\1")
        (self.root / "f_large.txt").write_text("".join(f"OLD_LINE_{i:03d}\n" for i in range(180)))
        (self.root / "z_clean.txt").write_text("CLEAN_MARKER\n")
        git(self.root, "init", "-q")
        git(self.root, "add", ".")
        git(self.root, "-c", "user.name=Preview test", "-c", "user.email=test@example.invalid",
            "commit", "-qm", "fixture")
        (self.root / "a_dual.py").write_text('value = "STAGED_MARKER"\n')
        git(self.root, "add", "a_dual.py")
        (self.root / "a_dual.py").write_text('value = "WORKTREE_MARKER"\n')
        (self.root / "b_deleted.txt").unlink()
        (self.root / "c_new 测试 ' #.txt").write_text("NEW_FILE_MARKER\n")
        git(self.root, "mv", "d_old.txt", "d_renamed.txt")
        (self.root / "e_binary.dat").write_bytes(b"\0modified\2")
        (self.root / "f_large.txt").write_text("".join(f"NEW_LINE_{i:03d}\n" for i in range(180)))
        self.initial_index = self.index_hash()
        config = stage / "config"
        plugin = config / "plugins" / "whatchanged.yazi"
        plugin.mkdir(parents=True)
        shutil.copy2(PLUGIN / "main.lua", plugin / "main.lua")
        (config / "init.lua").write_text('require("whatchanged"):setup ' + options + "\n")
        (config / "yazi.toml").write_text('''[plugin]
prepend_previewers = [
  { url = "search://*", run = "whatchanged" },
  { url = "search://*/", run = "whatchanged" },
]
''')
        self.diagnostic = stage / "diagnostic.txt"
        diagnostic = config / "plugins" / "diagnostic.yazi"
        diagnostic.mkdir()
        (diagnostic / "main.lua").write_text('''local M = {}
local snapshot = ya.sync(function()
  local r = rt.mgr.ratio
  local view = require("whatchanged").views[tostring(cx.active.id.value)]
  local cache = view and view.cache
  return string.format("%s:%s:%s\\n%s\\n%s\\n%s", r[1], r[2], r[3],
    tostring(cx.active.current.cwd), tostring(cache and cache.width),
    tostring(cache and cache.lines[#cache.lines]))
end)
function M:entry()
  Command("python3"):arg { "-c", "from pathlib import Path; import sys; Path(sys.argv[1]).write_text(sys.argv[2])",
''' + json.dumps(str(self.diagnostic)) + ''', snapshot() }:output()
end
return M
''')
        keymap = ""
        for keys, command in ((["g", "v"], "plugin whatchanged"),
                              (["g", "p"], "plugin whatchanged preview"),
                              (["g", "R"], "plugin whatchanged refresh"),
                              (["g", "D"], "plugin diagnostic"),
                              (["g", "r"], "cd " + str(self.root))):
            keymap += "\n[[mgr.prepend_keymap]]\non = " + json.dumps(keys) + "\nrun = " + json.dumps(command) + "\n"
        (config / "keymap.toml").write_text(keymap)
        self.master, slave = pty.openpty()
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 42, 200, 0, 0))

        def child_setup():
            os.setsid()
            fcntl.ioctl(0, termios.TIOCSCTTY, 0)

        env = dict(os.environ, TERM="xterm-256color", YAZI_CONFIG_HOME=str(config),
                   XDG_CACHE_HOME=str(stage / "cache"))
        self.tmux = ["tmux", "-L", "whatchanged-test-" + str(os.getpid()) + "-" + stage.name, "-f", "/dev/null"]
        self.process = subprocess.Popen(self.tmux + ["new-session", "-s", "test", "-x", "200", "-y", "42",
                                        shlex.join([yazi, str(self.root)])],
                                        stdin=slave, stdout=slave, stderr=slave, env=env,
                                        preexec_fn=child_setup)
        os.close(slave)
        self.output = bytearray()
        self.replies = {b"\x1b[0c": 0, b"\x1b[6n": 0}
        self.number = 0
        self.pump(1.0)

    def index_hash(self):
        return hashlib.sha256((self.root / ".git/index").read_bytes()).hexdigest()

    def pump(self, duration):
        deadline = time.monotonic() + duration
        while time.monotonic() < deadline:
            if not select.select([self.master], [], [], min(0.05, max(0, deadline - time.monotonic())))[0]:
                continue
            try:
                data = os.read(self.master, 65536)
            except OSError:
                break
            if not data:
                break
            self.output.extend(data)
            for query, response in ((b"\x1b[0c", b"\x1b[?1;2c"), (b"\x1b[6n", b"\x1b[1;1R")):
                count = self.output.count(query)
                if count > self.replies[query]:
                    os.write(self.master, response * (count - self.replies[query]))
                    self.replies[query] = count

    def send(self, keys=b"", wait=0.6):
        os.write(self.master, keys)
        self.pump(wait)
        text = subprocess.check_output(self.tmux + ["capture-pane", "-p", "-t", "test:0.0"]).decode()
        self.number += 1
        (self.stage / f"screen-{self.number:02d}.txt").write_text(text)
        assert self.process.poll() is None, ("Yazi exited", text)
        assert not re.search(r"runtime error|Failed to load.*plugin|attempt to (?:call|index)", text, re.I), text
        return text

    def find(self, name):
        return self.send(b"/" + name.encode() + b"\r")

    def snapshot(self, expected_ratio):
        self.diagnostic.unlink(missing_ok=True)
        text = self.send(b"gD", 0.3)
        assert self.diagnostic.exists(), ("Diagnostic missing", text)
        snapshot = self.diagnostic.read_text().split("\n", 3)
        assert snapshot[0] == expected_ratio, (snapshot, text)
        return snapshot

    def resize(self, width):
        subprocess.check_call(self.tmux + ["resize-window", "-t", "test:0", "-x", str(width), "-y", "42"])
        self.pump(0.8)

    def close(self):
        (self.stage / "terminal.log").write_bytes(self.output)
        if self.process.poll() is None:
            self.process.kill()
            self.process.wait()
        subprocess.run(self.tmux + ["kill-server"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        os.close(self.master)


def pair(text, before, after):
    assert any(before in row and after in row and row.index(before) < row.index(after)
               for row in text.splitlines()), ("Expected old/new on the same row", before, after, text)


def verify(args):
    # Personal signing, hooks, filters, and aliases must not affect temporary fixtures.
    os.environ.update(GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM="1", GIT_TERMINAL_PROMPT="0")
    artifacts = Path(tempfile.mkdtemp(prefix="whatchanged-preview-tests-"))
    print("Artifacts:", artifacts, flush=True)
    for mode in ("unified", "missing", "failing", "bounded", "side-by-side"):
        stage = artifacts / mode
        stage.mkdir()
        executable = str(artifacts / "missing-delta") if mode == "missing" else args.delta
        if mode in ("failing", "bounded"):
            helper = stage / "delta-helper"
            content = "import sys\nsys.exit(3)\n" if mode == "failing" else (
                "import os, sys, time\n"
                "from pathlib import Path\n"
                "Path(" + repr(str(stage / "delta-pids")) + ").open('a').write(str(os.getpid()) + '\\n')\n"
                "sys.stdout.write(('x' * 100 + '\\n') * 30000)\n"
                "sys.stdout.flush()\ntime.sleep(30)\n")
            helper.write_text("#!/usr/bin/env python3\n" + content)
            helper.chmod(0o755)
            executable = str(helper)
        style = "unified" if mode == "unified" else "side-by-side"
        options = '{ diff_style = ' + json.dumps(style) + ', delta = ' + json.dumps(executable)
        if mode == "unified":
            # Omit diff_style and provide an invalid Delta path: defaults must need only Git.
            options = '{ delta = ' + json.dumps(str(artifacts / "missing-delta"))
        if mode == "side-by-side":
            options += ', git_ratio = { 0, 1, 4 }'
        terminal = Terminal(stage, args.yazi, options + ' }')
        try:
            terminal.snapshot("1:4:3")
            text = terminal.send(b"gv", 1.0)
            if mode == "bounded":
                assert terminal.snapshot("1:4:3")[3] == "Preview truncated at 2 MiB"
                for pid in (stage / "delta-pids").read_text().splitlines():
                    try:
                        os.kill(int(pid), 0)
                    except ProcessLookupError:
                        continue
                    raise AssertionError("Truncated preview child was not reaped: " + pid)
                assert terminal.index_hash() == terminal.initial_index
                print("PASS: 2 MiB output bound and child cleanup", flush=True)
                continue
            assert "Staged" in text and "Unstaged" in text, text
            if mode == "side-by-side":
                terminal.snapshot("0:1:4")
                pair(text, "BASE_MARKER", "STAGED_MARKER")
                pair(text, "STAGED_MARKER", "WORKTREE_MARKER")
            else:
                terminal.snapshot("1:4:3")
                assert "BASE_MARKER" in text and "WORKTREE_MARKER" in text, text
                if mode == "missing":
                    assert "Delta unavailable" in text, text
                elif mode == "failing":
                    assert "Delta could not render" in text, text
            text = terminal.send(b"gp")
            assert "WORKTREE_MARKER" in text and "Staged" not in text, text
            terminal.send(b"gp")
            if mode == "side-by-side":
                width_before = terminal.snapshot("0:1:4")[2]
                terminal.resize(160)
                width_after = terminal.snapshot("0:1:4")[2]
                assert width_before != width_after, (width_before, width_after)
                text = terminal.send()
                pair(text, "BASE_MARKER", "STAGED_MARKER")
                terminal.resize(200)
                terminal.find("b_deleted")
                text = terminal.send(b"gp")
                assert "File deleted" in text, text
                text = terminal.send(b"gp")
                assert "DELETED_MARKER" in text, text
                text = terminal.find("c_new")
                assert "NEW_FILE_MARKER" in text and "Untracked" in text, text
                text = terminal.find("d_renamed")
                assert "renamed:" in text and "d_old.txt" in text, text
                text = terminal.find("e_binary")
                assert "binary file" in text, text
                text = terminal.find("f_large")
                initial_lines = re.findall(r"(?:OLD|NEW)_LINE_\d+", text)
                text = terminal.send(b"J")
                assert re.findall(r"(?:OLD|NEW)_LINE_\d+", text) != initial_lines, text
                text = terminal.send(b"K")
                assert re.findall(r"(?:OLD|NEW)_LINE_\d+", text) == initial_lines, text
                terminal.send(b"tt", 1.0)
                terminal.snapshot("0:1:4")
                terminal.send(b"gr")
                terminal.snapshot("1:4:3")
                terminal.send(b"1")
                terminal.snapshot("0:1:4")
                terminal.send(b"2")
                terminal.snapshot("1:4:3")
                terminal.send(b"1")
            assert terminal.index_hash() == terminal.initial_index
            terminal.find("a_dual")
            git(terminal.root, "add", "a_dual.py")
            expected_index = terminal.index_hash()
            text = terminal.send(b"gR", 0.9)
            assert "Staged" in text and "Unstaged" not in text, text
            assert "WORKTREE_MARKER" in text, text
            terminal.send(b"gv")
            terminal.snapshot("1:4:3")
            assert terminal.index_hash() == expected_index
            print("PASS:", mode, "preview/source/refresh/index/layout", flush=True)
        finally:
            terminal.close()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--yazi", default=shutil.which("yazi"))
    parser.add_argument("--delta", default=shutil.which("delta"))
    args = parser.parse_args()
    for name in ("tmux", "git", "python3"):
        parser.error(name + " is required") if shutil.which(name) is None else None
    if not args.yazi or not args.delta:
        parser.error("Yazi and Delta are required (or pass --yazi and --delta)")
    verify(args)
