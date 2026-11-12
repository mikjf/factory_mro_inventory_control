"""Run the project's queries against the ERP and save each result as Parquet.

    python extract.py                  every query
    python extract.py tickets replies  only these (names in QUERIES)

Output, in ../factory_mro_inventory_control_private/data/extract/:

    <name>.parquet         one per query
    extract_manifest.json  when it ran, and per query its period, rows,
                           columns, seconds and the SHA-256 of the SQL text

Periods (CREATE_DATE in [start, end)):
    tickets, replies  FY26 + October 2026 - analyses pick their own window
    sap_po_lines      FY25 + FY26 + October 2026: an item's lead time needs
                      history, spend is FY26
    machine_monitoring  fixed in the SQL: FY26 start to the current week
    docuware_orders, docuware_status  orders stored in DocuWare in FY25 + FY26
                      + October 2026 (status history: each STATUS_PROCESS change)

Read-only, through erp.py. The SAP prefix ({sap}) and the DocuWare linked
server ({linked}) come from the private settings file
../factory_mro_inventory_control_private/fmic.ini.
The script refuses to write inside this repository.
"""
import configparser
import datetime as dt
import hashlib
import json
import sys
import time

import erp

QUERY_DIR = erp.HERE / "queries"
OUT = erp.PRIVATE / "data" / "extract"
SETTINGS = erp.PRIVATE / "fmic.ini"

QUERIES = {
    # name: (sql file, params)
    "tickets": ("factoryapp_tickets.sql", ["2025-10-01", "2026-11-01"]),
    "replies": ("factoryapp_replies.sql", ["2025-10-01", "2026-11-01"]),
    "sap_po_lines": ("sap_maintenance_po_lines.sql", ["2024-10-01", "2026-11-01"]),
    "machine_monitoring": ("machine_monitoring.sql", []),
    "docuware_orders": ("docuware_purchase_orders.sql", ["2024-10-01", "2026-11-01"]),
    "docuware_status": ("docuware_status_history.sql", ["2024-10-01", "2026-11-01"]),
}

# placeholder in the SQL -> (section, key) in the private settings file
PRIVATE_NAMES = {"{sap}": ("sap", "prefix"), "{linked}": ("docuware", "linked")}


def sql_text(file):
    sql = (QUERY_DIR / file).read_text(encoding="utf-8-sig")
    cfg = configparser.ConfigParser()
    cfg.read(SETTINGS, encoding="utf-8")
    for placeholder, (section, key) in PRIVATE_NAMES.items():
        if placeholder in sql:
            sql = sql.replace(placeholder, cfg[section][key])
    return sql


def main(names):
    out = OUT.resolve()
    if out == erp.HERE or erp.HERE in out.parents:
        sys.exit(f"refusing to write inside the repository: {out}")
    unknown = set(names) - set(QUERIES)
    if unknown:
        sys.exit(f"unknown queries: {sorted(unknown)}; known: {list(QUERIES)}")
    out.mkdir(parents=True, exist_ok=True)
    manifest_path = out / "extract_manifest.json"
    manifest = (json.loads(manifest_path.read_text(encoding="utf-8"))
                if manifest_path.exists() else {"queries": {}})

    cn = erp.connect()
    try:
        for name in names or QUERIES:
            file, params = QUERIES[name]
            raw = (QUERY_DIR / file).read_text(encoding="utf-8-sig")
            t0 = time.perf_counter()
            df = erp.query(sql_text(file), params, cn=cn)
            tmp = out / f"{name}.parquet.tmp"
            df.to_parquet(tmp, index=False)
            tmp.replace(out / f"{name}.parquet")
            secs = time.perf_counter() - t0
            manifest["queries"][name] = {
                "sql": file,
                "params": params,
                "ran": dt.datetime.now().astimezone().isoformat(timespec="seconds"),
                "rows": len(df),
                "columns": {c: str(t) for c, t in df.dtypes.items()},
                "sql_sha256": hashlib.sha256(raw.encode("utf-8")).hexdigest(),
                "seconds": round(secs, 1),
            }
            print(f"  {name:<20} {len(df):>9,} rows  {secs:6.1f} s")
    finally:
        cn.close()
    manifest_path.write_text(json.dumps(manifest, indent=2), encoding="utf-8")
    print(f"written to {out}")


if __name__ == "__main__":
    main(sys.argv[1:])
