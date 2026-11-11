"""Read-only access to the ERP database (Infor VISUAL on SQL Server).

    import erp
    df = erp.query("SELECT ... WHERE x >= ?", [since])

Connection settings come from ../factory_planner_private/extract.ini, section
[database] (server, database, driver), never from this repository. Windows
authentication only: no password is read or stored.

IT YIELDS TO ERP USERS. The session runs at DEADLOCK_PRIORITY LOW, so when a
read collides with someone saving in the ERP, the read is the one cancelled;
it is retried up to three times, 10 s apart, before giving up.

SELECT ONLY. The connection is opened read-only and every statement is checked
before it is sent: it must start with SELECT or WITH and contain no keyword
that writes or changes the schema.
"""
import configparser
import decimal
import pathlib
import re
import sys
import time

import pandas as pd
import pyodbc

HERE = pathlib.Path(__file__).resolve().parent
CONFIG = HERE.parent / "factory_planner_private" / "extract.ini"
PRIVATE = HERE.parent / "factory_mro_inventory_control_private"
DEADLOCK_STATE = "40001"    # SQLSTATE of "chosen as the deadlock victim"
DEADLOCK_TRIES = 4          # the first attempt and three retries
DEADLOCK_WAIT = 10          # seconds between attempts

_WRITE_WORDS = re.compile(
    r"\b(INSERT|UPDATE|DELETE|MERGE|INTO|DROP|ALTER|CREATE|TRUNCATE|EXEC|"
    r"EXECUTE|GRANT|REVOKE|DENY|BACKUP|RESTORE|DBCC|SHUTDOWN|KILL)\b")


def connect(config_path=CONFIG):
    if not config_path.exists():
        sys.exit(f"{config_path} not found - it holds the server and database names")
    cfg = configparser.ConfigParser()
    cfg.read(config_path, encoding="utf-8")
    db = cfg["database"]
    cn = pyodbc.connect(
        f"DRIVER={{{db.get('driver', 'ODBC Driver 18 for SQL Server')}}};"
        f"SERVER={db['server']};DATABASE={db['database']};"
        "Trusted_Connection=yes;TrustServerCertificate=yes;",
        readonly=True)
    cn.execute("SET DEADLOCK_PRIORITY LOW")
    return cn


def check_select_only(sql):
    """Refuse anything but a plain SELECT (or WITH ... SELECT)."""
    text = re.sub(r"--[^\n]*|/\*.*?\*/", " ", sql, flags=re.S)   # comments
    text = re.sub(r"'(?:[^']|'')*'", "''", text)                  # string literals
    text = re.sub(r"\[[^\]]*\]", "[]", text).upper()              # [quoted names]
    first = text.split(None, 1)[0] if text.strip() else ""
    if first not in ("SELECT", "WITH"):
        raise ValueError(f"only SELECT queries are allowed, got {first or 'nothing'}")
    bad = _WRITE_WORDS.search(text)
    if bad:
        raise ValueError(f"only SELECT queries are allowed, found {bad.group(1)}")


def _fetch(cn, sql, params):
    """Read through the pyodbc cursor (pd.read_sql wants SQLAlchemy).
    SQL Server DECIMAL/NUMERIC arrive as Python Decimal and become float."""
    cur = cn.cursor()
    try:
        cur.execute(sql, params or [])
        names = [d[0] for d in cur.description]
        rows = [tuple(r) for r in cur.fetchall()]
    finally:
        cur.close()
    df = pd.DataFrame.from_records(rows, columns=names)
    for c in df.columns:
        if df[c].map(lambda v: isinstance(v, decimal.Decimal)).any():
            df[c] = pd.to_numeric(df[c].map(lambda v: None if v is None else float(v)))
    return df


def query(sql, params=None, cn=None):
    """Run one SELECT and return a DataFrame; retry when chosen as deadlock victim."""
    check_select_only(sql)
    own = cn is None
    cn = cn or connect()
    try:
        for attempt in range(1, DEADLOCK_TRIES + 1):
            try:
                return _fetch(cn, sql, params)
            except pyodbc.Error as e:
                if e.args[0] != DEADLOCK_STATE or attempt == DEADLOCK_TRIES:
                    raise
                print(f"gave way to an ERP user (deadlock), "
                      f"retry {attempt} of {DEADLOCK_TRIES - 1} in {DEADLOCK_WAIT} s")
                time.sleep(DEADLOCK_WAIT)
    finally:
        if own:
            cn.close()
