#!/usr/bin/env python3
# history.py — `roe history`: per-(project × machine) archive of opencode session
# history. python3 STANDARD LIBRARY ONLY (sqlite3/json/gzip/argparse — no pip), the
# standing AGENTS.md carve-out alongside track_tui.py.
#
# Where the history lives: opencode keeps every project's conversations in one
# central SQLite db (~/.local/share/opencode/opencode.db by default; override with
# OPENCODE_DB or --db). THIS TOOL NEVER WRITES THERE: it opens the db read-only and
# exports only the sessions belonging to the resolved project into the project's own
# archive tree at <project>/opencode-history/<host>/<session-id>.jsonl.gz — ONE FILE PER
# SESSION. Because the archive is written inside the synced project, the normal git sync
# propagates every machine's history to every machine.
#
# Why one file per session: each backup only rewrites the sessions that actually changed
# (a content hash decides), so an unchanged session keeps its existing git blob forever
# instead of a fresh full-size blob landing in history on every single backup.
#
# Legacy layout (< v1.8.0): a single rolling <project>/opencode-history/<host>.jsonl.gz
# holding every session. `list`/`show` still read it; a successful backup migrates it to
# the per-session layout and removes the rolled-up file (only when every legacy session is
# represented in the new layout, so nothing is ever lost).
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
import hashlib
import json
import os
import sqlite3
import sys
import urllib.parse
import zlib

VERSION = 1
DB_DEFAULT = os.path.expanduser("~/.local/share/opencode/opencode.db")


# --- path/lookup helpers -----------------------------------------------------
def norm(p):
    """Absolute, normalized path with symlinks resolved. realpath matters: a project
    reached through a symlink (or /tmp -> /private/tmp on macOS) must still match the
    path opencode recorded in its db, or session matching silently returns nothing."""
    p = os.path.expanduser(p)
    try:
        return os.path.normpath(os.path.realpath(os.path.abspath(p)))
    except OSError:
        return os.path.normpath(os.path.abspath(p))


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
    session that opened the dir directly — renames/moves stay matched this way).

    Each query is guarded SEPARATELY: one missing/renamed table must not abort the
    other two lookups (they are independent ways of finding the same project), and a
    total lookup failure must be reported rather than looking like "no sessions"."""
    ids = set()
    queries = (
        ("select id, worktree from project", "worktree", "id"),
        ("select project_id, directory from project_directory", "directory",
         "project_id"),
        ("select distinct project_id, directory from session "
         "where directory is not null", "directory", "project_id"),
    )
    for sql, path_col, id_col in queries:
        try:
            for r in con.execute(sql):  # noqa: S608
                if r[path_col] and same_dir(r[path_col], root):
                    ids.add(r[id_col])
        except sqlite3.Error:
            continue  # this lookup path is unavailable; the others may still match
    return ids


# --- data extraction ---------------------------------------------------------
def _j(data):
    if not data:
        return {}
    if isinstance(data, (bytes, bytearray)):
        data = data.decode("utf-8", "replace")
    try:
        out = json.loads(data) if isinstance(data, str) else data
    except (ValueError, TypeError):
        return {}
    return out if isinstance(out, dict) else {}


def collect(con, root, host):
    """All sessions for the project, newest first, each with messages and parts.

    Returns (sessions, matched). `matched` is False when the project could not be
    located in the db at all — a very different thing from "this project has zero
    sessions", and the caller must not prune an archive in that case."""
    ids = project_ids(con, root)
    matched = bool(ids)
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
    sessions.sort(key=lambda rec: (rec.get("session") or {}).get("time_created") or 0,
                   reverse=True)
    return sessions, matched


# --- archive IO (per-session files; legacy rolled-up file still readable) --------
ARCHIVE_DIRNAME = "opencode-history"
SUFFIX = ".jsonl.gz"

# Corrupt/truncated gzip raises zlib.error, which is NOT an OSError subclass (it comes
# from zlib, not the io layer) — so it must be named explicitly. BadGzipFile only
# exists on Python 3.8+; feature-detect so 3.6/3.7 don't die with AttributeError.
_DECODE_ERRORS = (OSError, ValueError, EOFError, KeyError, zlib.error)
if hasattr(gzip, "BadGzipFile"):
    _DECODE_ERRORS = _DECODE_ERRORS + (gzip.BadGzipFile,)


def _safe_host(host):
    """Host key -> a single safe path segment (never '', never '.', never '..')."""
    h = "".join(c if (c.isalnum() or c in "._-") else "_" for c in str(host))
    h = h.strip(".") or "host"
    return h[:64]


def _safe_session_stem(session_id):
    """Session id -> a safe filename stem. Session ids come from the db and are used
    verbatim as filenames, so they must never contain a path separator or escape the
    host directory. Real ids are `ses_<base62>`; anything else is sanitized and
    disambiguated with a short hash so two different ids can never collide."""
    raw = str(session_id)
    stem = "".join(c if (c.isalnum() or c in "._-") else "_" for c in raw).strip("._-")
    if not stem:
        stem = "session"
    if stem != raw:
        stem = f"{stem}-{hashlib.sha1(raw.encode('utf-8')).hexdigest()[:8]}"
    return stem[:120]


def archive_dir(root, host):
    return os.path.join(norm(root), ARCHIVE_DIRNAME, _safe_host(host))


def legacy_archive_path(root, host):
    """The pre-v1.8.0 rolled-up single file (read-only compatibility + migration)."""
    return os.path.join(norm(root), ARCHIVE_DIRNAME, f"{_safe_host(host)}{SUFFIX}")


def session_file(root, host, session_id):
    return os.path.join(archive_dir(root, host), _safe_session_stem(session_id) + SUFFIX)


def session_ids_present(root, host):
    """session ids that already have a per-session archive file (no db read needed).
    Returns the on-disk stems (filenames), which is what prune/migrate compare against
    via session_file()."""
    d = archive_dir(root, host)
    try:
        names = os.listdir(d)
    except OSError:
        return set()
    out = set()
    for n in names:
        if n.endswith(SUFFIX) and not n.startswith("."):
            out.add(n[: -len(SUFFIX)])
    return out


def _stems_present(root, host):
    """The on-disk filename stems (what prune/migrate must match to delete safely)."""
    return session_ids_present(root, host)


def _existing_hash(root, host, session_id):
    """content hash already on disk for a session, or None if absent/unreadable."""
    p = session_file(root, host, session_id)
    try:
        with open(p, "rb") as fh:
            blob = fh.read()
        rec = json.loads(gzip.decompress(blob).decode("utf-8").split("\n", 1)[0])
        return rec.get("content_hash")
    except _DECODE_ERRORS:
        return None


def _write_one(path, record):
    """Write one session record atomically (temp file + rename) so a crash never leaves
    a half-written archive behind. The temp name is unique per process so two concurrent
    backups for the same host can't interleave, and it's always cleaned up."""
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = f"{path}.{os.getpid()}.tmp"
    try:
        with open(tmp, "wb") as fh:
            fh.write(gzip.compress((json.dumps(record, ensure_ascii=False) + "\n").encode("utf-8")))
        os.replace(tmp, path)
    finally:
        try:
            os.remove(tmp)  # no-op after a successful replace
        except OSError:
            pass


def write_archive(root, host, records):
    """One file per session. Unchanged sessions (same content hash) are NOT rewritten,
    so their existing git blobs survive — this is the whole point of the per-session
    layout. Returns (written, unchanged, bytes_written)."""
    kept, written, wrote_bytes = set(), 0, 0
    for rec in records:
        sid = (rec.get("session") or {}).get("id")
        if not sid:
            continue
        content = dict(rec)
        content.pop("backed_up_at", None)
        digest = hashlib.sha256(
            json.dumps(content, sort_keys=True, ensure_ascii=False).encode("utf-8")
        ).hexdigest()
        content["content_hash"] = digest
        content["backed_up_at"] = _iso(dt_now())
        kept.add(sid)
        if _existing_hash(root, host, sid) == digest:
            continue  # unchanged: leave the existing file (and git blob) alone
        p = session_file(root, host, sid)
        _write_one(p, content)
        written += 1
        try:
            wrote_bytes += os.path.getsize(p)
        except OSError:
            pass
    return written, len(kept) - written, wrote_bytes


def prune_gone(root, host, records, matched=True):
    """Remove per-session files for sessions no longer in the db.

    SAFETY: pruning is skipped entirely unless the project actually matched in the db
    AND produced at least one session. An empty result can mean "no sessions" OR "the
    project wasn't found" (moved path, symlink, db reset, schema drift) — and in the
    second case deleting everything would destroy the only copy of the archive."""
    if not matched or not records:
        return 0
    # live_files are the on-disk STEMS (what session_ids_present returns), so compare
    # stems to stems — comparing against a full filename would prune everything.
    live_files = {_safe_session_stem(r["session"]["id"])
                  for r in records if (r.get("session") or {}).get("id")}
    removed = 0
    for stem in _stems_present(root, host) - live_files:
        try:
            os.remove(os.path.join(archive_dir(root, host), stem + SUFFIX))
            removed += 1
        except OSError:
            pass
    return removed


def _read_file(path):
    with gzip.open(path, "rt", encoding="utf-8") as gz:
        return [json.loads(line) for line in gz if line.strip()]


def _record_digest(record):
    """Canonical hash of a session record's actual content — independent of the
    `content_hash`/`backed_up_at` bookkeeping fields. Used to decide whether a legacy
    record is already fully represented by its per-session file."""
    content = {k: v for k, v in record.items()
               if k not in ("content_hash", "backed_up_at")}
    return hashlib.sha256(
        json.dumps(content, sort_keys=True, ensure_ascii=False).encode("utf-8")
    ).hexdigest()


def _legacy_covered(root, host, rec):
    """True when the per-session layout already holds this legacy session's content.

    Judged by: a readable per-session file with the same session id whose message count
    is >= the legacy record's. A full-record digest would be too strict — a legacy file
    written by a different opencode version can differ in cosmetic fields (project_root,
    model) while holding exactly the same transcript — and id-only would be unsafe. A
    readable file with at least as many messages is the safe middle: a corrupt or empty
    replacement fails this and keeps the legacy copy."""
    sid = (rec.get("session") or {}).get("id")
    if not sid:
        return False
    new_rec = _existing_record_by_stem(root, host, _safe_session_stem(sid))
    if new_rec is None:
        return False
    new_sid = (new_rec.get("session") or {}).get("id")
    if new_sid != sid:
        return False
    legacy_msgs = len((rec.get("session") or {}).get("messages") or [])
    new_msgs = len((new_rec.get("session") or {}).get("messages") or [])
    return new_msgs >= legacy_msgs


def _existing_record_by_stem(root, host, stem):
    """The first record stored in a per-session file, or None if unreadable."""
    p = os.path.join(archive_dir(root, host), stem + SUFFIX)
    try:
        recs = _read_file(p)
        return recs[0] if recs else None
    except _DECODE_ERRORS:
        return None


def migrate_legacy(root, host):
    """Delete a pre-v1.8.0 rolled-up file ONLY when every session it holds is already
    present in the per-session layout with the same content (see _legacy_covered).
    Any unreadable file, missing session, or short/empty replacement keeps the legacy
    file, so it can never be the thing that loses data."""
    legacy = legacy_archive_path(root, host)
    if not os.path.isfile(legacy):
        return False
    try:
        with gzip.open(legacy, "rt", encoding="utf-8") as gz:
            legacy_recs = [json.loads(line) for line in gz if line.strip()]
    except _DECODE_ERRORS:
        return False
    for rec in legacy_recs:
        if not _legacy_covered(root, host, rec):
            return False  # not fully represented — keep the legacy file as a safety net
    try:
        os.remove(legacy)
        return True
    except OSError:
        return False


def read_archive(root, host):
    """All archived session records for a host: the per-session layout, plus any
    legacy rolled-up file whose sessions aren't already present. Returns None when the
    host has no archive at all."""
    have_any = False
    records = []
    for stem in sorted(session_ids_present(root, host)):
        have_any = True
        path = os.path.join(archive_dir(root, host), stem + SUFFIX)
        try:
            records.extend(_read_file(path))
        except _DECODE_ERRORS:
            # Recovery is reading the archive, so a corrupt file must be surfaced, not
            # silently dropped (it would look like the session never existed).
            print(f"warning: could not read archived session file — skipped: {path}",
                  file=sys.stderr)
    legacy = legacy_archive_path(root, host)
    if os.path.isfile(legacy):
        have_any = True
        seen = {(r.get("session") or {}).get("id") for r in records}
        try:
            for rec in _read_file(legacy):
                if (rec.get("session") or {}).get("id") not in seen:
                    records.append(rec)
        except _DECODE_ERRORS:
            print(f"warning: could not read the legacy rolled-up archive — skipped: {legacy}",
                  file=sys.stderr)
    if not have_any:
        return None
    records.sort(
        key=lambda rec: (rec.get("session") or {}).get("time_created") or 0, reverse=True
    )
    return records


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
        s = rec.get("session") or {}
        print(
            f"  {ts(s.get('time_created'))}  {s.get('title') or '(untitled)'}"
            f"  [{s.get('id')}] agent={s.get('agent') or '-'} "
            f"msgs={len(s.get('messages') or [])}"
        )


def render(rec):
    s = rec.get("session") or {}
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
        records, matched = collect(con, norm(args.root), args.host)
        written, unchanged, _bytes = write_archive(args.root, args.host, records)
        # Create the archive dir even with 0 sessions so `list`/`show` agree with the
        # "archive created" message below (git doesn't track empty dirs, but the dir
        # existing locally makes the empty-archive state honest).
        try:
            os.makedirs(archive_dir(args.root, args.host), exist_ok=True)
        except OSError:
            pass
        pruned = prune_gone(args.root, args.host, records, matched=matched)
        migrated = migrate_legacy(args.root, args.host)
        n = len(records)
        total = sum(len((r.get("session") or {}).get("messages") or [])
                   for r in records)
        if n:
            note = ""
        elif not matched:
            # Project not found in the db: NEVER prune (this is the "project moved /
            # db reset" case that used to wipe the archive), and say so plainly.
            note = (" (no opencode project matched this directory in the db — archive "
                    "left untouched; if you moved the project or opencode reset its db, "
                    "check OPENCODE_DB)")
        else:
            note = " (no sessions recorded for this project yet — archive created)"
        print(
            f"archived {n} session(s) / {total} message(s) for {args.host}"
            f" -> {archive_dir(args.root, args.host)}/{note}"
        )
        print(
            f"  {written} written, {unchanged} unchanged (untouched to keep git history "
            f"small)" + (f", {pruned} pruned" if pruned else "")
        )
        if migrated:
            print(
                "  migrated the pre-v1.8.0 rolled-up archive to per-session files "
                "(removed the old single file)"
            )
        return 0

    # list / show read the archive, not the db
    records = read_archive(args.root, args.host)
    if records is None:
        raise SystemExit(
            f"history.py: no archive for {args.host} in {norm(args.root)} — "
            f"run 'roe history backup' on that machine first."
        )
    if args.sub == "list":
        print_list(records, args.root, args.host, archive_dir(args.root, args.host))
        return 0

    want = args.session
    if not want:
        raise SystemExit("history.py: show needs --session <id>")
    match = [r for r in records if (r.get("session") or {}).get("id") == want]
    if len(match) != 1:
        match = [r for r in records if str((r.get("session") or {}).get("id", "")).startswith(want)]
    if len(match) == 0:
        raise SystemExit(
            f"history.py: no session matching '{want}' in the {args.host} archive "
            f"(run 'roe history list' to see archived sessions)"
        )
    if len(match) > 1:
        raise SystemExit(
            f"history.py: '{want}' is ambiguous ({len(match)} matches) — use a longer prefix"
        )
    print(render(match[0]))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))