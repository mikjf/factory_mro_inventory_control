"""Define KPIs of slides 3 and 5, for a ticket window and a monitoring window.

    python define.py

Method (approved by the team, see the slide 3 box "Come si calcola"):
- tickets: S (breakdown) and PM2 (preventive) created in the ticket window;
  hours = sum of WORKED_HOURS.
- interventions per week: tickets per full monitoring week (Mon-Sun), averaged.
- downtime: per machine-group/week with planned hours, GROUP_DOWNTIME
  (calendar hours from the "down" ticket to the machine back up, plus manual
  adjustments) capped at 168 h (one week).
- production impact today: downtime x PLANNED/168 x hourly value;
  maximum: downtime x MAX_CAP/168 x hourly value; 12 months: x 52 / weeks.
"""
import configparser
import json

import pandas as pd

import erp

DATA = erp.PRIVATE / "data" / "extract"


def _hourly_value():
    """CHF per produced hour (slide 3 source): private, in fmic.ini [define]."""
    cfg = configparser.ConfigParser()
    cfg.read(erp.PRIVATE / "fmic.ini", encoding="utf-8")
    return cfg.getfloat("define", "hourly_value")


HOURLY_VALUE = _hourly_value()
WEEK_HOURS = 168

WINDOWS = {
    # name: (tickets from, tickets to (excl.), first week start, last week start)
    "approved (data of 24.09)": None,
    "same window, data today": ("2026-01-01", "2026-09-20", "2026-01-05", "2026-09-14"),
    "Jan-Sep 2026, data today": ("2026-01-01", "2026-10-01", "2026-01-05", "2026-09-21"),
}

# The figures on the approved slide, for comparison: kept in the private
# folder, like all results.
APPROVED_FILE = erp.PRIVATE / "approved_define.json"


def kpis(tickets, monitoring, t_from, t_to, w_first, w_last):
    t = tickets[(tickets.CREATE_DATE >= t_from) & (tickets.CREATE_DATE < t_to)
                & tickets.TYPE.isin(["s", "pm2"])]
    s = t[t.TYPE == "s"]
    days = (pd.Timestamp(t_to) - pd.Timestamp(t_from)).days

    # Tracked weeks only (planned hours and capacity), as on the approved
    # slide: the query also returns unused weeks (UNUSED_WEEK = 'Y').
    m = monitoring[(monitoring.WEEK_START_DATE >= w_first)
                   & (monitoring.WEEK_START_DATE <= w_last)
                   & (monitoring.RAG_DATA_STATUS == "Tracked")].copy()
    # calendar weeks, so a closed week (no planned hours) still counts in the
    # 12-month scaling, with zero impact
    weeks = len(pd.date_range(w_first, w_last, freq="7D"))
    m["down"] = m.GROUP_DOWNTIME.fillna(0).clip(upper=WEEK_HOURS)
    down_planned = (m.down * m.PLANNED.fillna(0) / WEEK_HOURS).sum()
    down_max = (m.down * m.MAX_CAP.fillna(0) / WEEK_HOURS).sum()

    week_start = t.CREATE_DATE.dt.normalize() - pd.to_timedelta(t.CREATE_DATE.dt.day_of_week, unit="D")
    full = week_start[(week_start >= w_first) & (week_start <= w_last)]
    per_week = full.value_counts()

    r = {
        "tickets S + PM2": len(t), "tickets S": len(s),
        "hours worked total": t.WORKED_HOURS.sum(), "hours worked S": s.WORKED_HOURS.sum(),
        "share of hours S": s.WORKED_HOURS.sum() / t.WORKED_HOURS.sum(),
        "interventions per week": per_week.mean(), "S per week": len(s) / (days / 7),
        "share of interventions S": len(s) / len(t),
        "weeks of monitoring": weeks,
        "downtime h": m.down.sum(), "downtime h, planned": down_planned,
        "downtime h, max capacity": down_max,
        "impact CHF": down_planned * HOURLY_VALUE, "impact max CHF": down_max * HOURLY_VALUE,
        "impact 12 months CHF": down_planned * HOURLY_VALUE * 52 / weeks,
        "impact max 12 months CHF": down_max * HOURLY_VALUE * 52 / weeks,
    }
    by_dept = m.groupby("DEPARTMENT").down.sum()
    for d, v in by_dept.items():
        r[f"downtime h, {d}"] = v
    r["weeks capped at 168 h"] = int((m.GROUP_DOWNTIME > WEEK_HOURS).sum())
    r["first week with Forgia"] = m.loc[m.DEPARTMENT == "Forgia", "WEEK_START_DATE"].min().date()
    return r


def main():
    tickets = pd.read_parquet(DATA / "tickets.parquet")
    monitoring = pd.read_parquet(DATA / "machine_monitoring.parquet")
    monitoring["WEEK_START_DATE"] = pd.to_datetime(monitoring.WEEK_START_DATE)
    cols = {}
    for name, w in WINDOWS.items():
        cols[name] = (json.loads(APPROVED_FILE.read_text(encoding="utf-8")) if w is None
                      else kpis(tickets, monitoring, *w))
    table = pd.DataFrame(cols)
    pd.set_option("display.width", 200)
    print(table.to_string(float_format=lambda v: f"{v:,.3f}" if abs(v) < 1 else f"{v:,.0f}"))


if __name__ == "__main__":
    main()
