#!/usr/bin/env python3
"""track_tui.py — interactive `roe track` UI (python3 standard library ONLY).

A thin curses presentation layer over scripts/track.sh: it renders the three sync
states (tracked / untracked-not-ignored / ignored), and every mutation is delegated
back to `track.sh --ignore/--unignore`, which stays the single source of truth (and
the only thing the test suite exercises).

Usage: track_tui.py --root <project-root> --track-sh <path-to-track.sh>
"""

import argparse
import curses
import subprocess


def parse_args():
    ap = argparse.ArgumentParser(add_help=False)
    ap.add_argument("--root", required=True)
    ap.add_argument("--track-sh", required=True)
    return ap.parse_args()


def run(track_sh, root, args):
    proc = subprocess.run(
        [track_sh] + args + ["--dir", root],
        capture_output=True,
        text=True,
    )
    return proc.returncode, proc.stdout


def fetch(track_sh, root):
    """Return (tracked, untracked, ignored) as lists of root-relative paths."""
    rc, out = run(track_sh, root, ["--list"])
    lists = {"T": [], "U": [], "I": []}
    if rc != 0:
        return [], [], []
    for line in out.splitlines():
        if len(line) >= 2 and line[1] == "\t" and line[0] in lists:
            lists[line[0]].append(line[2:])
    return lists["T"], lists["U"], lists["I"]


def clip(text, width):
    """Left-truncate a path to fit; keeps the filename (the tail) visible."""
    text = text.rstrip("/")
    if width <= 0:
        return ""
    if text and text.endswith("/"):
        text = text[:-1]
    return text if len(text) <= width else "\u2026" + text[-(width - 1):]


class App:
    def __init__(self, track_sh, root):
        self.track_sh = track_sh
        self.root = root
        self.project = root.rstrip("/").split("/")[-1] or root
        self.panes = [None, None, None]   # lists of paths, index by pane
        self.idx = 0
        self.pane = 0
        self.msg = ""
        self._refresh()

    def _refresh(self):
        self.panes = list(fetch(self.track_sh, self.root))
        self.idx = min(self.idx, max(0, len(self.panes[self.pane]) - 1))

    def _toggle(self, stdscr):
        pane_paths = self.panes[self.pane]
        if not pane_paths:
            return
        path = pane_paths[self.idx]
        if self.pane == 2:
            rc, out = run(self.track_sh, self.root, ["--unignore", path])
        else:
            rc, out = run(self.track_sh, self.root, ["--ignore", path])
        last = [l for l in out.splitlines() if l.strip()] or ["<no output>"]
        self.msg = last[-1]
        keep = self.idx
        self._refresh()
        self.msg = f"{self.msg} \u2014 pane now {len(self.panes[self.pane])} item(s)"

    def draw(self, stdscr):
        curses.curs_set(0)
        stdscr.erase()
        rows, cols = stdscr.getmaxyx()
        colors = curses.has_colors()

        def put(row, col, text, attr=None):
            if row >= rows or col >= cols:
                return
            text = clip(text, cols - col)
            stdscr.addnstr(row, col, text, cols - col, attr or curses.A_NORMAL)

        names = [
            f"1 Tracked ({len(self.panes[0])})",
            f"2 Untracked ({len(self.panes[1])})",
            f"3 Ignored ({len(self.panes[2])})",
        ]
        # header
        header = f"  roe track \u2014 {self.project} @ {self.root}"
        attr = curses.A_REVERSE if colors else curses.A_BOLD
        if colors:
            attr = curses.color_pair(1) | curses.A_BOLD
        put(0, 0, header, attr)
        # tab bar
        pos = 1
        for i, name in enumerate(names):
            tab = f"  [{name}]  "
            a = curses.color_pair(2) | curses.A_BOLD if colors and i == self.pane else curses.A_NORMAL
            if i == self.pane and not colors:
                a = curses.A_REVERSE
            put(1, pos, tab, a)
            pos += len(tab)
        # active pane content
        content_top = 3
        view_h = rows - content_top - 1
        pane_paths = self.panes[self.pane]
        first = max(0, self.idx - view_h + 1)
        first = min(first, max(0, len(pane_paths) - view_h)) if view_h > 0 else 0
        for off in range(view_h):
            row = content_top + off
            li = first + off
            if li >= len(pane_paths):
                put(row, 0, "")
                continue
            marker = "  "
            a = curses.A_NORMAL
            styled = clip("  " + pane_paths[li], cols)
            if li == self.idx:
                a = (curses.color_pair(3) | curses.A_REVERSE) if colors else curses.A_REVERSE
            put(row, 0, styled, a)
        # footer / legend
        legend = f"[Tab] pane  [\u2191/\u2193] move  [Enter] toggle  [r] refresh  [q] quit"
        if self.msg:
            legend = self.msg + "  \u2022  " + legend
        put(rows - 1, 0, clip(legend, cols))

    def loop(self, stdscr):
        while True:
            self.draw(stdscr)
            stdscr.refresh()
            key = stdscr.get_wch()
            if key in ("q", "Q", "\x1b", curses.KEY_F10):
                break
            elif key == "\t" or key == curses.KEY_BTAB:
                self.pane = (self.pane + 1) % 3 if key == "\t" else (self.pane - 1) % 3
                self.idx = min(self.idx, max(0, len(self.panes[self.pane]) - 1))
                self.msg = ""
            elif key in (curses.KEY_UP, "k", "K", "8"):
                if self.idx > 0:
                    self.idx -= 1
            elif key in (curses.KEY_DOWN, "j", "J", "2"):
                if self.idx < len(self.panes[self.pane]) - 1:
                    self.idx += 1
            elif key in (curses.KEY_PPAGE, "b", "B"):
                self.idx = max(0, self.idx - 20)
            elif key in (curses.KEY_NPAGE, "f", "F"):
                self.idx = min(len(self.panes[self.pane]) - 1, self.idx + 20)
            elif key in ("\n", "\r", " ", "1", "2", "3"):
                if key in ("1", "2", "3"):
                    self.pane = int(key) - 1
                    self.idx = min(self.idx, max(0, len(self.panes[self.pane]) - 1))
                else:
                    self._toggle(stdscr)
            elif key == "r" or key == "R":
                self.msg = ""
                self._refresh()
            elif key == curses.KEY_RESIZE:
                self.draw(stdscr)
            elif key in ("h", "H", "?"):
                self.msg = "Tracked = committed+synced  |  Untracked = syncs on next snapshot  |  Ignored = never syncs"


def main():
    args = parse_args()

    def wrapper(stdscr):
        if curses.has_colors():
            try:
                curses.start_color()
                curses.use_default_colors()
                curses.init_pair(1, curses.COLOR_CYAN, -1)
                curses.init_pair(2, curses.COLOR_GREEN, -1)
                curses.init_pair(3, curses.COLOR_BLACK, curses.COLOR_WHITE)
            except curses.error:
                pass
        stdscr.keypad(True)
        App(args.track_sh, args.root).loop(stdscr)

    try:
        curses.wrapper(wrapper)
    except Exception as err:  # curses errors on broken terminals — fail soft
        print(f"roe track: could not start the TUI ({err}); use --list instead")
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())