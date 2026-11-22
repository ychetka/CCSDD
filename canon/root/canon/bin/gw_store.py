#!/usr/bin/env python3
"""gw_store.py - SQLite/WAL storage for the CCSDD gateway.

Replaces the flat gateway_counters.json + flock scheme:

- WAL + synchronous=FULL: a crash mid-call cannot truncate or
  corrupt counter state; readers never block writers.
- Quota increments and journal entries are individual atomic
  transactions - no transaction is ever held open across the
  partner/network call (the caller increments+commits, calls the
  backend, then journals+commits).
- The journal table is append-only audit evidence (INSERT only,
  no UPDATE/DELETE helpers exist here).
- One-shot migration: a legacy gateway_counters.json is imported
  once, then renamed to .migrated so it can never be replayed.

DB file: <canon>/gateway.db (deployed state, gitignored like
roadmap.md and the journals).
"""
import json
import os
import sqlite3
import sys

SCHEMA = """
PRAGMA journal_mode=WAL;
PRAGMA synchronous=FULL;
CREATE TABLE IF NOT EXISTS counters (
  key   TEXT PRIMARY KEY,
  value INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE IF NOT EXISTS journal (
  id         INTEGER PRIMARY KEY AUTOINCREMENT,
  ts         TEXT NOT NULL,
  partner    TEXT NOT NULL,
  tool       TEXT,
  call_class TEXT,
  round      INTEGER,
  audit_key  TEXT,
  request    TEXT,
  response   TEXT
);
"""


def connect(db_path):
    con = sqlite3.connect(db_path, timeout=10, isolation_level=None)
    con.execute("PRAGMA busy_timeout=10000")
    for stmt in SCHEMA.strip().split(";"):
        if stmt.strip():
            con.execute(stmt)
    _migrate_legacy(con, db_path)
    return con


def _migrate_legacy(con, db_path):
    """Import the retired JSON counters file exactly once."""
    legacy = os.path.join(os.path.dirname(db_path), "gateway_counters.json")
    if not os.path.exists(legacy):
        return
    try:
        data = json.load(open(legacy, encoding="utf-8"))
        if not isinstance(data, dict):
            raise ValueError("not an object")
    except Exception as e:
        # Same fail-closed rule as before: corrupt quota state must
        # not silently reset budgets - refuse until a human repairs.
        print(f"gw_store: legacy counters unreadable ({e}) - "
              f"fail closed, repair {legacy}", file=sys.stderr)
        sys.exit(4)
    con.execute("BEGIN IMMEDIATE")
    try:
        for k, v in data.items():
            if isinstance(k, str) and isinstance(v, (int, float)):
                con.execute(
                    "INSERT INTO counters(key,value) VALUES(?,?) "
                    "ON CONFLICT(key) DO UPDATE SET value = value + excluded.value",
                    (k, int(v)))
        con.execute("COMMIT")
    except Exception:
        con.execute("ROLLBACK")
        raise
    os.replace(legacy, legacy + ".migrated")


def counter_get(con, key):
    row = con.execute("SELECT value FROM counters WHERE key=?", (key,)).fetchone()
    return int(row[0]) if row else 0


def counter_incr(con, key):
    """Atomic increment inside one transaction; returns new value."""
    con.execute("BEGIN IMMEDIATE")
    try:
        con.execute(
            "INSERT INTO counters(key,value) VALUES(?,1) "
            "ON CONFLICT(key) DO UPDATE SET value = value + 1", (key,))
        new_val = con.execute(
            "SELECT value FROM counters WHERE key=?", (key,)).fetchone()[0]
        con.execute("COMMIT")
        return int(new_val)
    except Exception:
        con.execute("ROLLBACK")
        raise


def counters_check_incr(con, pairs):
    """Atomic check-and-increment in ONE transaction.

    pairs: [(key, limit_or_None), ...] - every key is checked
    against its limit (None = no check); if ANY is at/over limit,
    nothing is written and the result is (None, tripped_key);
    otherwise all keys are incremented and a list of new values is
    returned as ([v1,...], None). The audit path passes the per-key
    AND the global daily counter in one call so the two can never
    diverge mid-race."""
    con.execute("BEGIN IMMEDIATE")
    try:
        cur_vals = []
        for key, _lim in pairs:
            row = con.execute("SELECT value FROM counters WHERE key=?",
                              (key,)).fetchone()
            cur_vals.append(int(row[0]) if row else 0)
        for (key, lim), cur in zip(pairs, cur_vals):
            if lim is not None and cur >= lim:
                con.execute("ROLLBACK")
                return None, key      # tripped key for the error path
        for key, _lim in pairs:
            con.execute(
                "INSERT INTO counters(key,value) VALUES(?,1) "
                "ON CONFLICT(key) DO UPDATE SET value = value + 1",
                (key,))
        con.execute("COMMIT")
        return [c + 1 for c in cur_vals], None
    except Exception:
        con.execute("ROLLBACK")
        raise


def journal_append(con, entry):
    """Append an audit journal row. entry: dict with ts/partner/..."""
    con.execute(
        "INSERT INTO journal(ts,partner,tool,call_class,round,audit_key,"
        " request,response) VALUES(?,?,?,?,?,?,?,?)",
        (entry.get("ts"), entry.get("partner"), entry.get("tool"),
         entry.get("class"), entry.get("round"), entry.get("audit_key"),
         json.dumps(entry.get("request_args"), ensure_ascii=False),
         json.dumps(entry.get("response"), ensure_ascii=False)))
