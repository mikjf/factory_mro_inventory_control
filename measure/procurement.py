"""Spare-part procurement: lead times (total / internal / supplier), item
classes, risk matrix and the three Improve levers. Rebuilds the logic of the
team's DAI workbook on the fresh extracts.

    python -m measure.procurement

Lines: SAP purchase order lines on the three spare-part accounts.
  LT total    = delivery date - creation date (days); empty if delivered
                before creation ("a posteriori": urgent purchase regularised).
  LT internal = DocuWare MAIL SENT date - creation date (signature and sending);
                MAIL SENT from the DocuWare audit trail (extracts
                docuware_status and docuware_orders).
  LT supplier = max(0, delivery date - MAIL SENT date); without a DocuWare
                date: max(0, LT total - median internal LT).
  On time     = the company's vendor on-time delivery rule: delivery date on or
                before the vendor's promise date (POR1.U_CONFERMATO), else the
                desired date when there is no promise. DAYS_LATE > 0 = late.
Lead-time statistics: lines created in FY25 + FY26 and delivered.
Item = normalised item description (the SAP item code is often generic:
"1 AC = 1 articolo" is not applied yet). Item LT = median LT total of its lines.
  fast: LT <= 3 days; slow: > 3; a posteriori: only deliveries before creation.
Spend: FY26 (delivery date), value of the delivered quantity.
Recurring: >= 2 deliveries in FY26.
Levers (exclusive): 1 Modula = slow, recurring, supplier LT > 3;
  2 fast signatures lane = slow but supplier LT <= 3;  3 buy on demand = rest.

Output: ../factory_mro_inventory_control_private/data/measure/po_lines.parquet, items.parquet
"""
import pandas as pd

import erp
from measure.tickets import SPARE_PART_ACCOUNTS

EXTRACT = erp.PRIVATE / "data" / "extract"
OUT = erp.PRIVATE / "data" / "measure"
FY26 = ("2025-10-01", "2026-10-01")
LT_FROM = "2024-10-01"
FAST_DAYS = 3
RECURRING = 2


def _order_no(s):
    return s.astype(str).str.strip().str.replace(r"\.0$", "", regex=True)


def docuware_sent():
    """When each purchase order was sent: the first change to MAIL SENT in the
    DocuWare audit trail; for a sent order without an audit entry, its last
    modification time (DWMODDATETIME, a close proxy)."""
    a = pd.read_parquet(EXTRACT / "docuware_status.parquet")
    a = a[a.NEW_STATUS.eq("MAIL SENT")].assign(PURCHASE_ORDER=lambda d: _order_no(d.NUMERO_OA))
    audit = a.groupby("PURCHASE_ORDER").STATUS_DATE.min()
    o = pd.read_parquet(EXTRACT / "docuware_orders.parquet")
    o = o[o.STATUS_PROCESS.eq("MAIL SENT")].assign(PURCHASE_ORDER=lambda d: _order_no(d.NUMERO_OA))
    proxy = o.groupby("PURCHASE_ORDER").DWMODDATETIME.min()
    sent = audit.combine_first(proxy)
    return pd.to_datetime(sent).rename("MAIL_SENT")


def lines():
    p = pd.read_parquet(EXTRACT / "sap_po_lines.parquet")
    p = p[p.GL_ACCOUNT_NAME.isin(SPARE_PART_ACCOUNTS)].copy()
    p["ITEM"] = (p.ITEM_DESCRIPTION.fillna("").str.upper()
                 .str.replace(r"\s+", " ", regex=True).str.strip())
    p["MAIL_SENT"] = p.PURCHASE_ORDER.map(docuware_sent())
    c, d, m = (p.CREATE_DATE.dt.normalize(), p.DELIVERY_DATE.dt.normalize(),
               p.MAIL_SENT.dt.normalize())
    p["A_POSTERIORI"] = d < c
    p["LT_TOTAL"] = (d - c).dt.days.where(~p.A_POSTERIORI)
    p["LT_INTERNAL"] = (m - c).dt.days.clip(lower=0)
    median_internal = p.LT_INTERNAL.median()
    p["LT_SUPPLIER"] = (d - m).dt.days.clip(lower=0)
    no_dw = p.MAIL_SENT.isna()
    p.loc[no_dw, "LT_SUPPLIER"] = (p.LT_TOTAL - median_internal).clip(lower=0)
    p.loc[p.A_POSTERIORI, "LT_SUPPLIER"] = None
    p["SUPPLIER_LT_SOURCE"] = no_dw.map({True: "estimate", False: "DocuWare"})
    p["REFERENCE_DATE"] = p.VENDOR_PROMISE_DATE.fillna(p.SMB_DESIRED_DATE)
    p["HAS_PROMISE"] = p.VENDOR_PROMISE_DATE.notna()
    p["DAYS_LATE"] = (d - p.REFERENCE_DATE.dt.normalize()).dt.days
    p["DELIVERED_VALUE_CHF"] = p.VALUE_CHF * p.DELIVERED_QTY.fillna(0) / p.ORDER_QTY
    p["IN_FY26"] = (p.DELIVERY_DATE >= FY26[0]) & (p.DELIVERY_DATE < FY26[1])
    p["FOR_LT_STATS"] = (p.CREATE_DATE >= LT_FROM) & (p.CREATE_DATE < FY26[1]) & p.DELIVERY_DATE.notna()
    return p


def items(p):
    h = p[p.DELIVERY_DATE.notna() & (p.CREATE_DATE < FY26[1])]
    fy = p[p.IN_FY26]
    i = pd.DataFrame({
        "LT_MEDIAN": h.groupby("ITEM").LT_TOTAL.median(),
        "LT_P90": h.groupby("ITEM").LT_TOTAL.quantile(0.9),
        "SUPPLIER_LT_MEDIAN": h.groupby("ITEM").LT_SUPPLIER.median(),
        "LINES_HISTORY": h.groupby("ITEM").size(),
        "ONLY_A_POSTERIORI": h.groupby("ITEM").A_POSTERIORI.all(),
        "DELIVERIES_FY26": fy.groupby("ITEM").size(),
        "SPEND_FY26_CHF": fy.groupby("ITEM").DELIVERED_VALUE_CHF.sum(),
        "MAIN_VENDOR": h.groupby("ITEM").VENDOR.agg(lambda v: v.mode().iloc[0]),
        "ITEM_CODES": h.groupby("ITEM").ITEM_CODE.nunique(),
    })
    i["DELIVERIES_FY26"] = i.DELIVERIES_FY26.fillna(0).astype(int)
    i["SPEND_FY26_CHF"] = i.SPEND_FY26_CHF.fillna(0)
    i["CLASS"] = "slow"
    i.loc[i.LT_MEDIAN <= FAST_DAYS, "CLASS"] = "fast"
    i.loc[i.ONLY_A_POSTERIORI, "CLASS"] = "a posteriori"
    i["RECURRING"] = i.DELIVERIES_FY26 >= RECURRING
    i["LEVER"] = "3 buy on demand"
    slow = i.CLASS.eq("slow")
    i.loc[slow & (i.SUPPLIER_LT_MEDIAN <= FAST_DAYS), "LEVER"] = "2 fast signatures"
    i.loc[slow & i.RECURRING & (i.SUPPLIER_LT_MEDIAN > FAST_DAYS), "LEVER"] = "1 Modula"
    i.loc[i.CLASS.eq("a posteriori"), "LEVER"] = "a posteriori"
    # items the team excluded from stock (e.g. building, not machine spares):
    # listed in the private folder, never in this repository
    i["EXCLUDED"] = i.index.isin(excluded_items())
    i.loc[i.EXCLUDED & i.LEVER.eq("1 Modula"), "LEVER"] = "excluded"
    return i


def excluded_items():
    f = erp.PRIVATE / "exclude_from_stock.txt"
    if not f.exists():
        return set()
    lines = (x.strip() for x in f.read_text(encoding="utf-8").splitlines())
    return {x.upper() for x in lines if x and not x.startswith("#")}


def build():
    p = lines()
    i = items(p)
    OUT.mkdir(parents=True, exist_ok=True)
    p.to_parquet(OUT / "po_lines.parquet", index=False)
    i.reset_index().to_parquet(OUT / "items.parquet", index=False)
    return p, i


if __name__ == "__main__":
    p, i = build()
    pd.set_option("display.width", 200)
    s = p[p.FOR_LT_STATS]
    print("lines for LT stats", len(s), " DocuWare match", round(s.MAIL_SENT.notna().mean(), 3))
    print(s[["LT_TOTAL", "LT_INTERNAL", "LT_SUPPLIER"]].describe(percentiles=[.25, .5, .75, .9]).round(1))
    print("share of time in signatures", round(s.LT_INTERNAL.sum() / s.loc[s.MAIL_SENT.notna(), "LT_TOTAL"].sum(), 3))
    fy = i[i.SPEND_FY26_CHF > 0]
    print(fy.groupby("CLASS").agg(items=("SPEND_FY26_CHF", "size"), spend=("SPEND_FY26_CHF", "sum")).round(0))
    print(fy.groupby("LEVER").agg(items=("SPEND_FY26_CHF", "size"), spend=("SPEND_FY26_CHF", "sum")).round(0))
    fy2 = fy[fy.CLASS.isin(["fast", "slow"])]
    print(pd.crosstab(fy2.CLASS, fy2.RECURRING, values=fy2.SPEND_FY26_CHF, aggfunc="sum").round(0))
    print(pd.crosstab(fy2.CLASS, fy2.RECURRING))
