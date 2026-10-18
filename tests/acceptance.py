"""Exercise whatchanged in an isolated real Yazi/tmux session.

Requirements: Python 3.9+, Git, tmux, ripgrep, Yazi v26.8.15+, and a POSIX host.
Run from any directory: python3 /path/to/whatchanged.yazi/tests/acceptance.py
"""

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


def run(args, cwd=None, data=None):
    return subprocess.check_output(args, cwd=cwd, input=data, stderr=subprocess.PIPE)


YAZI = os.environ.get("YAZI_BINARY", "yazi")
for executable in ("git", "tmux", "rg", YAZI):
    if not shutil.which(executable):
        raise SystemExit(f"Missing test dependency: {executable}")

ARTIFACTS = Path(tempfile.mkdtemp(prefix="whatchanged-acceptance-"))
ROOT = ARTIFACTS / "fixture"
ORIGIN = ARTIFACTS / "origin.git"
PEER = ARTIFACTS / "peer"
CONFIG = ARTIFACTS / "config"
DIAGNOSTIC = ARTIFACTS / "runtime.txt"
SOURCE = Path(__file__).resolve().parents[1]
# Prevent personal Git settings (signing, hooks, filters) affecting the fixture.
os.environ.update(GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM="1", GIT_TERMINAL_PROMPT="0")


def git(*args, root=ROOT, data=None):
    return run(["git", "-C", str(root), *args], data=data)


def identity(root):
    git("config", "user.name", "Whatchanged acceptance", root=root)
    git("config", "user.email", "whatchanged@example.invalid", root=root)


run(["git", "init", "--bare", "-q", str(ORIGIN)])
run(["git", "clone", "-q", str(ORIGIN), str(ROOT)])
identity(ROOT)
git("checkout", "-qb", "main")
base = {
    "a_dual.py": 'value = "BASE_MARKER"\n',
    "b_staged.txt": "STAGED_OLD\n",
    "c_unstaged.txt": "UNSTAGED_OLD\n",
    "d_deleted.txt": "DELETED_MARKER\n",
    "e_staged_deleted.txt": "STAGED_DELETED_MARKER\n",
    "x_conflict.txt": "CONFLICT_BASE\n",
    "z_clean.txt": "CLEAN_FILE_MARKER\n",
}
for name, content in base.items():
    (ROOT / name).write_text(content)
git("add", ".")
git("commit", "-qm", "fixture base")
git("push", "-qu", "origin", "main")
git("symbolic-ref", "HEAD", "refs/heads/main", root=ORIGIN)
run(["git", "clone", "-q", str(ORIGIN), str(PEER)])
identity(PEER)
(ROOT / "z_clean.txt").write_text("CLEAN_FILE_MARKER\nLOCAL_COMMIT\n")
git("add", "z_clean.txt")
git("commit", "-qm", "local ahead one")
for number in (1, 2):
    (PEER / f"remote_{number}.txt").write_text(f"REMOTE_COMMIT_{number}\n")
    git("add", ".", root=PEER)
    git("commit", "-qm", f"remote ahead {number}", root=PEER)
git("push", "-q", root=PEER)
git("fetch", "-q")
assert git("rev-list", "--left-right", "--count", "HEAD...@{upstream}").split() == [b"1", b"2"]

(ROOT / "a_dual.py").write_text('value = "STAGED_MARKER"\n')
git("add", "a_dual.py")
(ROOT / "a_dual.py").write_text('value = "WORKTREE_MARKER"\n')
(ROOT / "b_staged.txt").write_text("STAGED_NEW\n")
git("add", "b_staged.txt")
(ROOT / "c_unstaged.txt").write_text("UNSTAGED_NEW\n")
(ROOT / "d_deleted.txt").unlink()
git("rm", "-q", "e_staged_deleted.txt")
SPECIAL = "f_new 测试 ' #.txt"
(ROOT / SPECIAL).write_text("UNTRACKED_SPECIAL_MARKER\n")
objects = [git("hash-object", "-w", "--stdin", data=content).strip().decode()
           for content in (b"CONFLICT_BASE\n", b"CONFLICT_OURS\n", b"CONFLICT_THEIRS\n")]
index_info = "0 0000000000000000000000000000000000000000\tx_conflict.txt\n"
index_info += "".join(f"100644 {oid} {stage}\tx_conflict.txt\n"
                      for stage, oid in enumerate(objects, 1))
git("update-index", "--index-info", data=index_info.encode())
(ROOT / "x_conflict.txt").write_text("<<<<<<< ours\nCONFLICT_OURS\n=======\nCONFLICT_THEIRS\n>>>>>>> theirs\n")

ALL = {"a_dual.py", "b_staged.txt", "c_unstaged.txt", "d_deleted.txt",
       "e_staged_deleted.txt", SPECIAL, "x_conflict.txt"}
STAGED = {"a_dual.py", "b_staged.txt", "e_staged_deleted.txt"}
UNSTAGED = {"a_dual.py", "c_unstaged.txt", "d_deleted.txt", SPECIAL, "x_conflict.txt"}

(CONFIG / "plugins" / "whatchanged.yazi").mkdir(parents=True)
shutil.copy2(SOURCE / "main.lua", CONFIG / "plugins" / "whatchanged.yazi" / "main.lua")
(CONFIG / "init.lua").write_text('require("whatchanged"):setup()\n')
# A wide preview makes assertions independent of source-code wrapping. This is
# fixture configuration, not a plugin feature or a user configuration change.
(CONFIG / "yazi.toml").write_text('''[mgr]
ratio = [0, 1, 3]
[plugin]
prepend_previewers = [
  { url = "search://*", run = "whatchanged" },
  { url = "search://*/", run = "whatchanged" },
]
''')
actions = {"v": "", "s": "staged", "w": "unstaged", "a": "all",
           "R": "refresh", "p": "preview"}
keymap = "".join(f'''[[mgr.prepend_keymap]]
on = ["g", "{key}"]
run = "plugin whatchanged {action}"
''' for key, action in actions.items())
keymap += '''[[mgr.prepend_keymap]]
on = ["g", "D"]
run = "plugin diagnostic"
[[mgr.prepend_keymap]]
on = ["g", "N"]
run = "tab_create --current"
'''
(CONFIG / "keymap.toml").write_text(keymap)
diagnostic_plugin = CONFIG / "plugins" / "diagnostic.yazi"
diagnostic_plugin.mkdir()
(diagnostic_plugin / "main.lua").write_text('''local M = {}
local context = ya.sync(function()
  local files = {}
  for _, file in ipairs(cx.active.current.files) do
    files[#files + 1] = tostring(fs.clean_url(file.url))
  end
  return tostring(cx.active.current.cwd) .. "\\n" .. table.concat(files, "\\n")
end)
function M:entry()
  local file = assert(io.open(''' + json.dumps(str(DIAGNOSTIC)) + ''', "w"))
  file:write(context())
  file:close()
end
return M
''')

master, slave = pty.openpty()
fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 44, 220, 0, 0))


def child_setup():
    os.setsid()
    fcntl.ioctl(0, termios.TIOCSCTTY, 0)


env = dict(os.environ, TERM="xterm-256color", YAZI_CONFIG_HOME=str(CONFIG))
socket = "whatchanged-acceptance-" + str(os.getpid())
TMUX = ["tmux", "-L", socket, "-f", "/dev/null"]
command = shlex.join([YAZI, str(ROOT), "--cwd-file=" + str(ARTIFACTS / "cwd")])
process = subprocess.Popen(TMUX + ["new-session", "-s", "acceptance", command],
                           stdin=slave, stdout=slave, stderr=slave, env=env,
                           preexec_fn=child_setup)
os.close(slave)
terminal = bytearray()
replies = {b"\x1b[0c": 0, b"\x1b[6n": 0}
capture_number = 0


def pump(duration):
    deadline = time.monotonic() + duration
    while time.monotonic() < deadline:
        remaining = max(0, deadline - time.monotonic())
        if not select.select([master], [], [], min(0.05, remaining))[0]:
            continue
        try:
            data = os.read(master, 65536)
        except OSError:
            break
        if not data:
            break
        terminal.extend(data)
        for query, response in ((b"\x1b[0c", b"\x1b[?1;2c"), (b"\x1b[6n", b"\x1b[1;1R")):
            count = terminal.count(query)
            if count > replies[query]:
                os.write(master, response * (count - replies[query]))
                replies[query] = count


def capture():
    global capture_number
    assert process.poll() is None, ("Yazi exited", terminal.decode(errors="replace"))
    text = run(TMUX + ["capture-pane", "-p", "-t", "acceptance:0.0"]).decode()
    capture_number += 1
    (ARTIFACTS / f"screen-{capture_number:02d}.txt").write_text(text)
    assert not re.search(r"runtime error|Failed to load.*plugin|attempt to (?:call|index)", text, re.I), text
    return text


def send(keys, wait=0.7):
    os.write(master, keys)
    pump(wait)
    return capture()


def names():
    DIAGNOSTIC.unlink(missing_ok=True)
    text = send(b"gD", 0.4)
    assert DIAGNOSTIC.exists(), ("Diagnostic missing", text)
    lines = DIAGNOSTIC.read_text().splitlines()
    return text, {Path(url.split("?", 1)[0]).name for url in lines[1:]}


def assert_list(expected, label):
    text, actual = names()
    assert actual == expected, (label, actual, expected, text)
    print("PASS:", label, flush=True)
    return text


def index_hash():
    return hashlib.sha256((ROOT / ".git/index").read_bytes()).hexdigest()


passed = False
try:
    pump(1.2)
    original_index = index_hash()
    send(b"gv", 1.2)
    text = assert_list(ALL, "all changes, including deleted/conflicted/untracked paths")
    assert "main → origin/main ↓2 ↑1" in text, text
    assert "modified:5 staged:3 new:1 conflicts:1" in text and "[all]" in text, text
    assert all(label in text for label in ("[staged+modified]", "[staged]", "[modified]", "[new]", "[conflict]")), text
    assert all(marker in text for marker in ("BASE_MARKER", "STAGED_MARKER", "WORKTREE_MARKER")), text
    send(b"gs", 1)
    text = assert_list(STAGED, "staged includes MM and staged deletion")
    assert "[staged]" in text and "BASE_MARKER" in text and "STAGED_MARKER" in text, text
    assert "Unstaged" not in text and "WORKTREE_MARKER" not in text, text
    send(b"gN", 1)
    assert_list(STAGED, "duplicated tab adopts the staged filter")
    send(b"gw", 1)
    assert_list(UNSTAGED, "duplicate can change its filter independently")
    send(b"1", 0.8)
    assert_list(STAGED, "original tab retains its own filter")
    send(b"gw", 1)
    text = assert_list(UNSTAGED, "unstaged includes MM, conflict, untracked, deletion")
    assert "[unstaged]" in text and "STAGED_MARKER" in text and "WORKTREE_MARKER" in text, text
    assert not re.search(r"\bStaged\b", text) and "BASE_MARKER" not in text, text
    send(b"ga", 1)
    assert_list(ALL, "all restores the complete list")
    send(b"gp")
    text = assert_list(ALL, "source preview preserves listing")
    assert "WORKTREE_MARKER" in text and "Unstaged" not in text, text
    send(b"gp")
    assert index_hash() == original_index, "Read-only operations changed the Git index"

    send(b"gw")
    git("add", "c_unstaged.txt")
    expected_index = index_hash()
    send(b"gR", 1)
    text = assert_list(UNSTAGED - {"c_unstaged.txt"}, "refresh retains filter after external staging")
    assert "[unstaged]" in text and "modified:4 staged:4 new:1 conflicts:1" in text, text
    send(b"gs", 1)
    assert_list(STAGED | {"c_unstaged.txt"}, "refresh updates the staged list")
    git("branch", "--unset-upstream")
    text = send(b"gR", 1)
    assert "main (no upstream)" in text and "↓" not in text and "↑" not in text, text
    git("branch", "--set-upstream-to", "origin/main")
    upstream = git("rev-parse", "origin/main").strip().decode()
    git("update-ref", "-d", "refs/remotes/origin/main")
    text = send(b"gR", 1)
    assert "origin/main (upstream gone)" in text and "↓" not in text and "↑" not in text, text
    git("update-ref", "refs/remotes/origin/main", upstream)
    head = git("rev-parse", "HEAD").strip().decode()
    git("update-ref", "--no-deref", "HEAD", head)
    text = send(b"gR", 1)
    assert f"HEAD@{head[:7]} (detached)" in text and "origin/main" not in text, text
    git("symbolic-ref", "HEAD", "refs/heads/unborn")
    text = send(b"gR", 1)
    assert "unborn (unborn) (no upstream)" in text and "↑" not in text and "↓" not in text, text
    git("symbolic-ref", "HEAD", "refs/heads/main")
    text = send(b"gR", 1)
    assert "main → origin/main ↓2 ↑1" in text, text
    print("PASS: no-upstream, missing-upstream, detached, and unborn branch headers", flush=True)
    send(b"gv")
    text = capture()
    assert "origin/main" not in text and "[staged]" not in text, text
    send(b"gw", 1)
    assert_list(UNSTAGED - {"c_unstaged.txt"}, "filter action opens changes from a normal directory")
    send(b"gv")
    # A non-whatchanged search must delegate to Yazi's ordinary source preview.
    send(b"S", 0.2)
    send(b"WORKTREE_MARKER\r", 1.2)
    text = capture()
    assert "WORKTREE_MARKER" in text and "Unstaged" not in text and "origin/main" not in text, text
    assert index_hash() == expected_index, "Preview/search operations changed the Git index"
    print("PASS: ordinary searches and Git index remain unchanged", flush=True)
    os.write(master, b"q")
    pump(0.5)
    process.wait(timeout=8)
    assert process.returncode == 0
    passed = True
    print("PASS: clean quit", flush=True)
finally:
    (ARTIFACTS / "terminal.bin").write_bytes(terminal)
    if process.poll() is None:
        process.kill()
        process.wait()
    subprocess.run(TMUX + ["kill-server"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    os.close(master)
    if passed:
        shutil.rmtree(ARTIFACTS)
    else:
        print("Artifacts:", ARTIFACTS, flush=True)
