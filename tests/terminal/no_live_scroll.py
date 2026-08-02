#!/usr/bin/env python3
"""Fail if primer's live update renderer scrolls or loses cursor ownership.

This is intentionally not a Bats test. It runs primer in a real pseudo-terminal
with a small window, captures the raw ANSI stream, and replays enough terminal
semantics to catch the visible "spazzing" class of bugs:

* live output scrolling the viewport
* cursor-up moving above the frame start
* missing final expanded report
"""

from __future__ import annotations

import errno
import fcntl
import os
import pty
import re
import shutil
import select
import signal
import struct
import sys
import termios
import tempfile
import time
from pathlib import Path


ROWS = 24
COLS = 80
CSI_RE = re.compile(rb"\x1b\[([?0-9;]*)([A-Za-z])")


class TerminalProbe:
    def __init__(self, rows: int, cols: int) -> None:
        self.rows = rows
        self.cols = cols
        self.row = 0
        self.col = 0
        self.in_live = False
        self.live_scrolls = 0
        self.cursor_underflows = 0
        self.live_frame_lines = 0
        self.max_live_frame_lines = 0
        self.oversized_live_frames = 0

    def feed(self, data: bytes) -> None:
        i = 0
        while i < len(data):
            byte = data[i]
            if byte == 0x1B:
                match = CSI_RE.match(data, i)
                if match:
                    self._csi(match.group(1).decode("ascii", "ignore"), chr(match.group(2)[0]))
                    i = match.end()
                    continue
                i += 1
                continue
            if byte == 0x0D:
                self.col = 0
            elif byte == 0x0A:
                if self.in_live:
                    self.live_frame_lines += 1
                self._newline()
            elif byte == 0x08:
                self.col = max(0, self.col - 1)
            elif byte >= 0xC0:
                self.col += 1
                if self.col > self.cols:
                    self.col = 0
                    self._newline()
            elif byte >= 0x80:
                pass
            elif byte >= 0x20:
                self.col += 1
                if self.col > self.cols:
                    self.col = 0
                    self._newline()
            i += 1

    def _newline(self) -> None:
        if self.row >= self.rows - 1:
            if self.in_live:
                self.live_scrolls += 1
        else:
            self.row += 1
        self.col = 0

    def _csi(self, params: str, cmd: str) -> None:
        if params == "?25" and cmd == "l":
            self.in_live = True
            self._start_live_frame()
            return
        if params == "?25" and cmd == "h":
            self._finish_live_frame()
            self.in_live = False
            return

        n = self._first_param(params, default=1)
        if cmd == "A":
            if self.in_live:
                self._start_live_frame()
            if self.in_live and n > self.row:
                self.cursor_underflows += 1
            self.row = max(0, self.row - n)
        elif cmd == "B":
            self.row = min(self.rows - 1, self.row + n)
        elif cmd == "C":
            self.col = min(self.cols - 1, self.col + n)
        elif cmd == "D":
            self.col = max(0, self.col - n)
        elif cmd in ("H", "f"):
            parts = [int(p) if p else 1 for p in params.split(";") if not p.startswith("?")]
            row = parts[0] if len(parts) >= 1 else 1
            col = parts[1] if len(parts) >= 2 else 1
            self.row = max(0, min(self.rows - 1, row - 1))
            self.col = max(0, min(self.cols - 1, col - 1))
        elif cmd == "J":
            if self.in_live:
                self._finish_live_frame()
                self.live_frame_lines = 0
            pass
        elif cmd == "K":
            pass

    @staticmethod
    def _first_param(params: str, default: int) -> int:
        if not params or params.startswith("?"):
            return default
        first = params.split(";", 1)[0]
        if not first:
            return default
        try:
            return int(first)
        except ValueError:
            return default

    def _start_live_frame(self) -> None:
        self._finish_live_frame()
        self.live_frame_lines = 0

    def _finish_live_frame(self) -> None:
        if self.live_frame_lines == 0:
            return
        self.max_live_frame_lines = max(self.max_live_frame_lines, self.live_frame_lines)
        if self.live_frame_lines > self.rows:
            self.oversized_live_frames += 1


def set_winsize(fd: int, rows: int, cols: int) -> None:
    winsize = struct.pack("HHHH", rows, cols, 0, 0)
    fcntl.ioctl(fd, termios.TIOCSWINSZ, winsize)


def write_test_config(root: Path, text: str) -> None:
    """Write a config that every profile resolves to.

    Primer loads configs/common.conf plus configs/profiles/<profile>.conf.
    The profile files stay empty so the shared config drives the run.
    """
    profiles = root / "configs" / "profiles"
    profiles.mkdir(parents=True, exist_ok=True)
    (root / "configs" / "common.conf").write_text(text, encoding="utf-8")
    for profile in ("mac", "linux-vps", "ubuntu-desktop"):
        (profiles / f"{profile}.conf").write_text(
            "# Test profile fragment.\n", encoding="utf-8"
        )


def build_stress_repo(repo: Path) -> tempfile.TemporaryDirectory[str]:
    tmp = tempfile.TemporaryDirectory(prefix="primer-terminal-stress-")
    root = Path(tmp.name)
    shutil.copytree(repo / "bin", root / "bin")
    shutil.copytree(repo / "lib", root / "lib")
    (root / "modules" / "many").mkdir(parents=True)
    (root / "modules" / "quick").mkdir(parents=True)
    (root / "modules" / "hostile").mkdir(parents=True)
    write_test_config(
        root,
        """
[many]
label = Many Items

[quick]
label = Quick Collapse
depends_on = many

[hostile]
label = Hostile TTY
depends_on = quick
""".lstrip(),
    )
    (root / "modules" / "many" / "module.zsh").write_text(
        r'''
mod_update() {
    local items=()
    local i
    for i in {01..36}; do items+=("item-$i"); done
    primer::items_init "${items[@]}"
    for i in "${items[@]}"; do
        primer::status_msg "working $i..."
        primer::item_update "$i" running
        sleep 0.01
        primer::item_update "$i" done
    done
    primer::status_msg "done"
}
mod_status() { primer::status_msg "ok"; }
'''.lstrip(),
        encoding="utf-8",
    )
    (root / "modules" / "quick" / "module.zsh").write_text(
        r'''
mod_update() {
    primer::items_init one two three four five six seven eight
    primer::status_msg "expanding..."
    primer::item_update one done
    primer::item_update two done
    primer::item_update three done
    primer::item_update four done
    sleep 0.05
    primer::status_msg "done"
}
mod_status() { primer::status_msg "ok"; }
'''.lstrip(),
        encoding="utf-8",
    )
    (root / "modules" / "hostile" / "module.zsh").write_text(
        r'''
mod_update() {
    primer::items_init tty-noise
    primer::status_msg "testing tty noise..."
    primer::item_update tty-noise running
    if [[ -e /dev/tty ]]; then
        for i in {1..8}; do
            print -- "HOSTILE-TTY-LINE-$i" > /dev/tty
            sleep 0.01
        done
    fi
    primer::item_update tty-noise done
    primer::status_msg "done"
}
mod_status() { primer::status_msg "ok"; }
'''.lstrip(),
        encoding="utf-8",
    )
    return tmp


def build_parallel_stress_repo(repo: Path) -> tempfile.TemporaryDirectory[str]:
    tmp = tempfile.TemporaryDirectory(prefix="primer-terminal-parallel-stress-")
    root = Path(tmp.name)
    shutil.copytree(repo / "bin", root / "bin")
    shutil.copytree(repo / "lib", root / "lib")
    modules_dir = root / "modules"
    modules_dir.mkdir()
    write_test_config(
        root,
        """
[wide-a]
label = Wide A

[wide-b]
label = Wide B

[wide-c]
label = Wide C

[wide-d]
label = Wide D

[wide-e]
label = Wide E

[wide-f]
label = Wide F
""".lstrip(),
    )
    module_body = r'''
mod_update() {
    local items=()
    local i
    for i in {01..24}; do items+=("${MOD_NAME}-$i"); done
    primer::items_init "${items[@]}"
    sleep 0.25
    for i in "${items[@]}"; do
        primer::status_msg "working $i..."
        primer::item_update "$i" running
        sleep 0.03
    done
    for i in "${items[@]}"; do
        primer::item_update "$i" done
    done
    primer::status_msg "done"
}
mod_status() { primer::status_msg "ok"; }
'''.lstrip()
    for name in ("wide-a", "wide-b", "wide-c", "wide-d", "wide-e", "wide-f"):
        (modules_dir / name).mkdir()
        (modules_dir / name / "module.zsh").write_text(module_body, encoding="utf-8")
    return tmp


def build_interrupt_repo(repo: Path) -> tempfile.TemporaryDirectory[str]:
    tmp = tempfile.TemporaryDirectory(prefix="primer-terminal-interrupt-")
    root = Path(tmp.name)
    shutil.copytree(repo / "bin", root / "bin")
    shutil.copytree(repo / "lib", root / "lib")
    (root / "modules" / "slow").mkdir(parents=True)
    write_test_config(
        root,
        """
[slow]
label = Slow Module
""".lstrip(),
    )
    (root / "modules" / "slow" / "module.zsh").write_text(
        r'''
mod_update() {
    primer::status_msg "sleeping..."
    sleep 5
    primer::status_msg "done"
}
mod_status() { primer::status_msg "ok"; }
'''.lstrip(),
        encoding="utf-8",
    )
    return tmp


def run_in_pty(repo: Path, command: list[str] | None = None) -> tuple[int, bytes]:
    if command is None:
        command = ["zsh", "bin/primer", "update", "--dry-run"]
    pid, fd = pty.fork()
    if pid == 0:
        env = os.environ.copy()
        env.update(
            {
                "PRIMER_LOCAL": str(repo),
                "TERM": "xterm-256color",
                "COLUMNS": str(COLS),
                "LINES": str(ROWS),
            }
        )
        os.chdir(repo)
        os.execvpe(command[0], command, env)

    set_winsize(fd, ROWS, COLS)
    chunks: list[bytes] = []
    while True:
        ready, _, _ = select.select([fd], [], [], 10)
        if not ready:
            os.kill(pid, signal.SIGTERM)
            raise TimeoutError("primer update --dry-run timed out")
        try:
            chunk = os.read(fd, 65536)
        except OSError as exc:
            if exc.errno == errno.EIO:
                break
            raise
        if not chunk:
            break
        chunks.append(chunk)

    _, status = os.waitpid(pid, 0)
    rc = os.waitstatus_to_exitcode(status)
    os.close(fd)
    return rc, b"".join(chunks)


def run_in_pty_and_interrupt(repo: Path) -> tuple[int, bytes]:
    pid, fd = pty.fork()
    if pid == 0:
        env = os.environ.copy()
        env.update(
            {
                "PRIMER_LOCAL": str(repo),
                "TERM": "xterm-256color",
                "COLUMNS": str(COLS),
                "LINES": str(ROWS),
            }
        )
        os.chdir(repo)
        os.execvpe("zsh", ["zsh", "bin/primer", "update", "--dry-run"], env)

    set_winsize(fd, ROWS, COLS)
    chunks: list[bytes] = []
    sent_interrupt = False
    started = time.time()
    while True:
        ready, _, _ = select.select([fd], [], [], 0.1)
        if ready:
            try:
                chunk = os.read(fd, 65536)
            except OSError as exc:
                if exc.errno == errno.EIO:
                    break
                raise
            if not chunk:
                break
            chunks.append(chunk)

        stream = b"".join(chunks)
        if not sent_interrupt and b"Slow Module" in stream and time.time() - started > 0.3:
            os.write(fd, b"\x03")
            sent_interrupt = True
        if time.time() - started > 8:
            os.kill(pid, signal.SIGTERM)
            raise TimeoutError("primer interrupt probe timed out")

    _, status = os.waitpid(pid, 0)
    rc = os.waitstatus_to_exitcode(status)
    os.close(fd)
    return rc, b"".join(chunks)


def strip_ansi(data: bytes) -> str:
    return CSI_RE.sub(b"", data).decode("utf-8", "replace")


def check_stream(name: str, repo: Path, stream: bytes, rc: int, *, expect_hostile: bool = False) -> list[str]:
    probe = TerminalProbe(ROWS, COLS)
    probe.feed(stream)
    plain = strip_ansi(stream)
    raw = stream.decode("latin1", "ignore")

    failures: list[str] = []
    if rc != 0:
        failures.append(f"{name}: primer exited {rc}")
    if probe.live_scrolls:
        failures.append(f"{name}: live renderer scrolled viewport {probe.live_scrolls} time(s)")
    if probe.cursor_underflows:
        failures.append(f"{name}: cursor-up moved above frame {probe.cursor_underflows} time(s)")
    if probe.oversized_live_frames:
        failures.append(
            f"{name}: live renderer drew {probe.oversized_live_frames} oversized frame(s), max {probe.max_live_frame_lines} rows"
        )
    if raw.count("\x1b[?1049h") != 1:
        failures.append(f"{name}: live renderer did not enter alternate screen exactly once")
    if raw.count("\x1b[?1049l") != 1:
        failures.append(f"{name}: live renderer did not leave alternate screen exactly once")
    if raw.find("\x1b[?1049l") < raw.find("\x1b[?1049h"):
        failures.append(f"{name}: live renderer left alternate screen before entering it")
    if raw.count("\x1b[2J") != 1:
        failures.append(f"{name}: live renderer should clear the screen once on alternate-screen entry")
    if "\x1b[J" in raw:
        failures.append(f"{name}: live renderer used erase-to-end-of-screen during alternate-screen updates")
    if "Ctrl-C to stop" not in plain:
        failures.append(f"{name}: full-screen footer was not rendered")
    if expect_hostile:
        leave_idx = raw.find("\x1b[?1049l")
        after_leave = strip_ansi(stream[leave_idx:]) if leave_idx != -1 else plain
        if "HOSTILE-TTY-LINE" in after_leave:
            failures.append(f"{name}: module output leaked into normal scrollback")
    return failures


def main() -> int:
    repo = Path(__file__).resolve().parents[2]
    failures: list[str] = []

    rc, stream = run_in_pty(repo)
    plain = strip_ansi(stream)
    failures.extend(check_stream("primer-dry-run", repo, stream, rc))
    raw = stream.decode("latin1", "ignore")
    leave_idx = raw.find("\x1b[?1049l")
    if leave_idx == -1 or "primer update (dry run)" not in strip_ansi(stream[leave_idx:]):
        failures.append("primer-dry-run: final report did not appear after leaving alternate screen")
    if "tomagranate/tap" not in plain:
        failures.append("primer-dry-run: final report did not include Homebrew substeps")
    if "helium-browser" not in plain:
        failures.append("primer-dry-run: final report did not include Mac Apps substeps")

    stress_tmp = build_stress_repo(repo)
    try:
        stress_repo = Path(stress_tmp.name)
        stress_rc, stress_stream = run_in_pty(stress_repo, ["zsh", "bin/primer", "update", "--dry-run"])
        failures.extend(check_stream("stress", stress_repo, stress_stream, stress_rc, expect_hostile=True))
        stress_plain = strip_ansi(stress_stream)
        if "item-36" not in stress_plain:
            failures.append("stress: final report did not include all synthetic substeps")
    finally:
        stress_tmp.cleanup()

    parallel_tmp = build_parallel_stress_repo(repo)
    try:
        parallel_repo = Path(parallel_tmp.name)
        parallel_rc, parallel_stream = run_in_pty(parallel_repo, ["zsh", "bin/primer", "update", "--dry-run"])
        failures.extend(check_stream("parallel-stress", parallel_repo, parallel_stream, parallel_rc))
        parallel_plain = strip_ansi(parallel_stream)
        if "wide-a-24" not in parallel_plain or "wide-b-24" not in parallel_plain or "wide-f-24" not in parallel_plain:
            failures.append("parallel-stress: final report did not include all synthetic substeps")
    finally:
        parallel_tmp.cleanup()

    interrupt_tmp = build_interrupt_repo(repo)
    try:
        interrupt_repo = Path(interrupt_tmp.name)
        interrupt_rc, interrupt_stream = run_in_pty_and_interrupt(interrupt_repo)
        interrupt_raw = interrupt_stream.decode("latin1", "ignore")
        interrupt_plain = strip_ansi(interrupt_stream)
        if interrupt_rc != 130:
            failures.append(f"interrupt: primer exited {interrupt_rc}, expected 130")
        if interrupt_raw.count("\x1b[?1049h") != 1 or interrupt_raw.count("\x1b[?1049l") != 1:
            failures.append("interrupt: alternate screen was not restored exactly once")
        if "\x1b[?25h" not in interrupt_raw:
            failures.append("interrupt: cursor was not restored")
        leave_idx = interrupt_raw.find("\x1b[?1049l")
        if leave_idx == -1 or "interrupted" not in strip_ansi(interrupt_stream[leave_idx:]):
            failures.append("interrupt: interrupted summary did not appear after leaving alternate screen")
        if "Slow Module" not in interrupt_plain:
            failures.append("interrupt: final report did not include interrupted module")
    finally:
        interrupt_tmp.cleanup()

    if failures:
        artifact = repo / "tests" / "terminal" / "no_live_scroll.out"
        artifact.write_bytes(stream)
        stress_artifact = repo / "tests" / "terminal" / "no_live_scroll_stress.out"
        if "stress_stream" in locals():
            stress_artifact.write_bytes(stress_stream)
        parallel_artifact = repo / "tests" / "terminal" / "no_live_scroll_parallel.out"
        if "parallel_stream" in locals():
            parallel_artifact.write_bytes(parallel_stream)
        interrupt_artifact = repo / "tests" / "terminal" / "no_live_scroll_interrupt.out"
        if "interrupt_stream" in locals():
            interrupt_artifact.write_bytes(interrupt_stream)
        print("terminal live-render regression failed:", file=sys.stderr)
        for failure in failures:
            print(f"  - {failure}", file=sys.stderr)
        print(f"raw stream saved to {artifact}", file=sys.stderr)
        if "stress_stream" in locals():
            print(f"stress stream saved to {stress_artifact}", file=sys.stderr)
        if "parallel_stream" in locals():
            print(f"parallel stress stream saved to {parallel_artifact}", file=sys.stderr)
        if "interrupt_stream" in locals():
            print(f"interrupt stream saved to {interrupt_artifact}", file=sys.stderr)
        return 1

    print(
        f"ok: dry-run bytes={len(stream)}, stress bytes={len(stress_stream)}, "
        f"parallel bytes={len(parallel_stream)}, interrupt bytes={len(interrupt_stream)}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
