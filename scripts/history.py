#!/usr/bin/env python3
# history.py — `roe history`: per-(project × machine) archive of opencode session
# history. python3 STANDARD LIBRARY ONLY (sqlite3/json/gzip/argparse — no pip), the
# standing AGENTS.md carve-out alongside track_tui.py.
#
# Where the history lives: opencode keeps every project's conversations in one
# central SQLite db (~/.local/share/opencode/opencode.db by default; override with
# OPENCODE_DB or --db). THIS TOOL NEVER WRITES THERE: it opens the db read-only and
# exports only the sessions belonging to the resolved project, as a rolling
# compressed JSONL archive at <project>/opencode-history/<host>.jsonl.gz. Because the
# archive is written inside the synced project, the normal git sync propagates every
# machine's history to every machine.
#
# opencode has no "merge this db back in" API, so recovery is reading the archive
# (list / show render readable transcripts; the raw JSONL keeps full fidelity).
#
# Subcommands:
#   history.py backup --root <dir> --host <name> [--db <path>]   -> write the archive
#   history.py list   --root <dir> --host <name> [--db <path>]   -> list archived sessions
#   history.py show   --root <dir> --host <name> --session <id>  -> markdown transcript
#
# Exit codes: 0 ok; 1 db missing / no schema / archive missing / session not found.

import argparse
import datetime as _dt
import gzip
import json
import os
import sqlite3
import sys
import urllib.parse

VERSION = 1
DB_DEFAULT = os.path.expanduser("~/.local/share/opencode/opencode.db")


# --- path/lookup helpers -----------------------------------------------------
def norm(p):
    return os.path.normpath(os.path.abspath(os.path.expanduser(p)))


def same_dir(a, b):
    return norm(a) == norm(b)


def connect(db_path):
    if not os.path.isfile(db_path):
        return None
    try:
        uri = "file:" + urllib.parse.quote(db_path) + "?mode=ro"
        con = sqlite3.connect(uri, uri=True)
    except sqlite3.Error as e:
        raise SystemExit(f"history.py: cannot open {db_path} read-only: {e}")
    con.row_factory = sqlite3.Row
    return con


def tables_present(con):
    try:
        rows = con.execute(
            "select name from sqlite_master where type='table' and name in "
            "('session','message','part')"
        ).fetchall()
    except sqlite3.Error:
        return False
    return {r["name"] for r in rows} == {"session", "message", "part"}


def project_ids(con, root):
    """session.project_ids whose project matches <root> (worktree, directory, or a
    session that opened the dir directly — renames/moves stay matched this way)."""
    ids = set()
    try:
        for r in con.execute("select id, worktree from project"):  # noqa: S608
            if r["worktree"] and same_dir(r["worktree"], root):
                ids.add(r["id"])
        for r in con.execute("select project_id, directory from project_directory"):
            if r["directory"] and same_dir(r["directory"], root):
                ids.add(r["project_id"])
        for r in con.execute(
            "select distinct project_id, directory from session where directory is not null"
        ):
            if r["directory"] and same_dir(r["directory"], root):
                ids.add(r["project_id"])
    except sqlite3.Error:
        pass
    return ids


# --- data extraction ---------------------------------------------------------
def _j(data):
    if not data:
        return {}
    try:
        return json.loads(data) if isinstance(data, str) else data
    except (ValueError, TypeError):
        return {}


def collect(con, root, host):
    """All sessions for the project, newest first, each with messages and parts."""
    ids = project_ids(con, root)
    sessions = []
    try:
        rows = con.execute(
            "select * from session where project_id in (%s)"
            % ",".join("?" * len(ids)),
            tuple(sorted(ids)),
        ).fetchall() if ids else []
    except sqlite3.Error as e:
        raise SystemExit(f"history.py: failed to read sessions: {e}")
    for s in rows:
        msgs = []
        for m in con.execute(
            "select * from message where session_id=? order by time_created",
            (s["id"],),
        ):
            md = _j(m["data"])
            parts = []
            for p in con.execute(
                "select * from part where message_id=? order by time_created",
                (m["id"],),
            ):
                parts.append(
                    {"id": p["id"], "type": _j(p["data"]).get("type", p["data"]),
                     "data": _j(p["data"])}
                )
            msgs.append(
                {
                    "id": m["id"],
                    "role": md.get("role", "unknown"),
                    "time_created": m["time_created"],
                    "data": md,
                    "parts": parts,
                }
            )
        sessions.append(
            {
                "v": VERSION,
                "host": host,
                "project_root": norm(root),
                "session": {
                    "id": s["id"],
                    "title": s["title"],
                    "agent": s["agent"],
                    "model": _j(s["model"]).get("id") or s["model"],
                    "time_created": s["time_created"],
                    "time_updated": s["time_updated"],
                    "parent_id": s["parent_id"],
                    "messages": msgs,
                },
            }
        )
    sessions.sort(key=lambda rec: rec["session"]["time_created"] or 0, reverse=True)
    return sessions


# --- archive IO --------------------------------------------------------------
def archive_path(root, host):
    return os.path.join(norm(root), "opencode-history", f"{host}.jsonl.gz")


def write_archive(path, records):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with gzip.open(path, "wt", encoding="utf-8") as gz:
        for rec in records:
            rec = dict(rec)
            rec["backed_up_at"] = _iso(dt_now())
            gz.write(json.dumps(rec, ensure_ascii=False) + "\n")


def read_archive(path):
    if not os.path.isfile(path):
        return None
    with gzip.open(path, "rt", encoding="utf-8") as gz:
        return [json.loads(line) for line in gz if line.strip()]


# --- formatting --------------------------------------------------------------
def dt_now():
    return _dt.datetime.now(_dt.timezone.utc).astimezone()


def _iso(dt):
    return dt.strftime("%Y-%m-%d %H:%M:%S")


def ts(ms):
    if not ms:
        return ""
    return _iso(_dt.datetime.fromtimestamp(ms / 1000))


def print_list(records, root, host, path):
    print(f"History archive: {path}")
    print(f"project: {norm(root)} · machine: {host} · sessions: {len(records)}")
    if not records:
        print("  (empty — no archived sessions for this machine/project yet)")
    for rec in records:
        s = rec["session"]
        print(
            f"  {ts(s.get('time_created'))}  {s.get('title') or '(untitled)'}"
            f"  [{s.get('id')}] agent={s.get('agent') or '-'} "
            f"msgs={len(s.get('messages') or [])}"
        )


def render(rec):
    s = rec["session"]
    msgs = s.get("messages") or []
    out = [f"# {(s.get('title') or '(untitled)').strip()}"]
    out.append(f"")
    out.append(f"- session: {s.get('id')}")
    out.append(
        f"- machine: {rec.get('host')} · project: {rec.get('project_root')}"
    )
    out.append(
        f"- created: {ts(s.get('time_created'))} · agent: {s.get('agent') or '-'}"
        f" · model: {s.get('model') or '-'} · messages: {len(msgs)}"
    )
    out.append("")
    for m in msgs:
        head = f"**{m['role']}**"
        if m.get("time_created"):
            head += f" · {ts(m['time_created'])}"
        out.append(head)
        lines = []
        for p in m.get("parts") or []:
            t = p.get("type")
            text = (p.get("data") or {}).get("text")
            if t in ("text", "reasoning") and text:
                lines.append(text.rstrip())
            elif t == "tool":
                tool = (p.get("data") or {}).get("tool", "?")
                state = (p.get("data") or {}).get("state")
                kw = f"[tool: {tool}]"
                if isinstance(state, str) and "error" in state.lower():
                    kw += "  (error)"
                lines.append(kw)
        if not lines:
            d = m.get("data") or {}
            for key in ("display", "summary", "input"):
                if d.get(key):
                    lines.append(str(d[key]))
                    break
        for ln in lines:
            out.append(ln)
        out.append("")
    return "\n".join(out)


# --- main --------------------------------------------------------------------
def main(argv):
    ap = argparse.ArgumentParser(
        prog="history.py", description="per-machine opencode session-history archive"
    )
    ap.add_argument("sub", choices=("backup", "list", "show"))
    ap.add_argument("--root", required=True, help="project root")
    ap.add_argument("--host", required=True, help="short machine name")
    ap.add_argument("--db", default=os.environ.get("OPENCODE_DB") or DB_DEFAULT)
    ap.add_argument("--session", help="session id (or unique prefix)")
    args = ap.parse_args(argv)

    if args.sub == "backup":
        con = connect(args.db)
        if con is None:
            raise SystemExit(
                f"history.py: opencode database not found at {args.db} — nothing to "
                f"archive for {args.host} on {norm(args.root)}."
            )
        if not tables_present(con):
            raise SystemExit(
                f"history.py: {args.db} has no usable opencode schema — is this the "
                f"right database? (set OPENCODE_DB to point at the real one)"
            )
        records = collect(con, norm(args.root), args.host)
        path = archive_path(args.root, args.host)
        write_archive(path, records)
        n = len(records)
        total = sum(len(r["session"].get("messages") or []) for r in records)
        note = "" if n else " (no sessions recorded for this project yet — archive created)"
        print(
            f"archived {n} session(s) / {total} message(s) for {args.host}"
            f" -> {path}{note}"
        )
        return 0

    # list / show read the archive, not the db
    path = archive_path(args.root, args.host)
    records = read_archive(path)
    if records is None:
        raise SystemExit(
            f"history.py: no archive for {args.host} in {norm(args.root)} — "
            f"run 'roe history backup' on that machine first."
        )
    if args.sub == "list":
        print_list(records, args.root, args.host, path)
        return 0

    want = args.session
    if not want:
        raise SystemExit("history.py: show needs --session <id>")
    match = [r for r in records if r["session"]["id"] == want]
    if len(match) != 1:
        match = [r for r in records if r["session"]["id"].startswith(want)]
    if len(match) == 0:
        raise SystemExit(
            f"history.py: no session matching '{want}' in {path} (" 
            f"run 'roe history list' to see archived sessions)"
        )
    if len(match) > 1:
        raise SystemExit(
            f"history.py: '{want}' is ambiguous ({len(match)} matches) — use a longer prefix"
        )
    print(render(match[0]))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))