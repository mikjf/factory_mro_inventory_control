"""S (breakdown) tickets of FY26 with a spare-part flag, for the Measure slides.

    python -m measure.tickets

FactoryApp has no "spare part" field, so the flag is read from the ticket's
title, description and all its replies (joined on TICKET_ID), and from SAP:

  ordered  (impiego diretto)  the text says the part was ordered / awaited
           (ordinato, da ordinare, offerta, in attesa del ricambio, appena
           arriva, ...) or searched and not found in stock; or the text
           mentions a replaced part and a maintenance purchase order line for
           the ticket's machine (machine code in the item description) was
           created while the ticket was open.
  stock    (giacenza)         no order signal, and the text says the part was
           taken from stock (Modula, scorta, preso/recuperato a magazzino,
           soppalco, ...).
  part, source unknown        replaced / mounted a part, but neither of the above.
  no part                     none of the above.

Lead time = CLOSE_DATE - CREATE_DATE, in hours (open tickets excluded).
Output: ../factory_mro_inventory_control_private/data/measure/s_tickets.parquet
"""
import re

import pandas as pd

import erp

EXTRACT = erp.PRIVATE / "data" / "extract"
OUT = erp.PRIVATE / "data" / "measure"
FY_START, FY_END = "2025-10-01", "2026-10-01"
SPARE_PART_ACCOUNTS = [
    "Materiale per manutenzione macchinari",
    "acquisto attrezzatura/utensili x manutenzione",
    "Materiale per manutenzione stabili",
]

PARTS = r"(?:ricamb\w*|pezz[oi]|component\w*|material\w*|motore|pompa|sensore|valvola|cuscinett\w*)"
ORDERED = re.compile(
    r"\bordinat[oiae]\b(?! (?:sotto|in|e pulit))|\bordinare\b|\bordine\b|effettuato ordine"
    r"|\bofferta\b|in attesa (?:del|dei|di|della|delle) " + PARTS +
    r"|attesa ricamb|appena arriva|all.arrivo (?:del|dei|della) " + PARTS +
    r"|arrivo (?:del|dei|della) " + PARTS + r"|richiesta d.acquisto|\bspedit"
    r"|riordin\w* (?:pezz|ricamb)")
NOT_FOUND = re.compile(
    r"(?:cercat\w*|cercare|ricerca)[^|]{0,60}(?:senza successo|non trovat|non presente|non c.è)"
    r"|non (?:presenti|presente|disponibil\w*|abbiamo)[^|]{0,30}(?:ricamb|a magazzino|in magazzino|a stock)")
STOCK = re.compile(
    r"(?:di|a|da) scorta|(?:ricamb\w*|pezz[oi])[^|]{0,30}già presente"
    r"|(?:pres[oa]|prelevat\w*|recuperat\w*|trovat\w*|presente|revisionat\w*|usat[oa]|avevamo"
    r"|sostituit\w*|montat\w*)[^|]{0,40}(?:nel |dal |in |a |sul )(?:modula|magazzin\w*|stock|soppalco)"
    r"|ricambio (?:già )?(?:presente|disponibile)")
PART = re.compile(r"ricamb|sostitu|cambiat|montat\w* (?:nuov|il|la|un)|pezz[oi] nuov")


# Why a "to order" ticket waits (sensei: outliers by cause), first match wins:
# a project or investment, an external company or technician, else the part.
INVESTMENT = re.compile(r"investiment|preventivo\b|bozza|linee? vita|progett")
EXTERNAL = re.compile(
    r"\bditta\b|azienda esterna|\btecnic[oi]\s+(?!ma\b|e\b|di\b|per\b)[a-z]{3,}|sopralluogo"
    r"|intervento esterno|\bservice\b|assistenza (?:tecnica|esterna|idraulica|modula|del fornitore)"
    r"|tecnici modula|arrivo del tecnico")


def wait_cause(text):
    if INVESTMENT.search(text):
        return "lavori / investimento"
    if EXTERNAL.search(text):
        return "intervento esterno"
    return "ricambio"


def flag(text):
    """Text flag; the order of the tests is the precedence."""
    if re.search(r"(?:ricamb\w*|pezz[oi])[^|]{0,30}già presente", text):
        return "stock"
    if ORDERED.search(text) or NOT_FOUND.search(text):
        return "ordered"
    if STOCK.search(text):
        return "stock"
    if PART.search(text):
        return "part, source unknown"
    return "no part"


def build():
    t = pd.read_parquet(EXTRACT / "tickets.parquet")
    r = pd.read_parquet(EXTRACT / "replies.parquet")
    po = pd.read_parquet(EXTRACT / "sap_po_lines.parquet")

    s = t[(t.TYPE == "s") & (t.CREATE_DATE >= FY_START) & (t.CREATE_DATE < FY_END)].copy()
    replies = (r[r.TICKET_ID.isin(s.TICKET_ID)].dropna(subset=["DESCRIPTION"])
               .groupby("TICKET_ID").DESCRIPTION.apply(lambda x: " || ".join(x.astype(str))))
    s["REPLIES"] = s.TICKET_ID.map(replies)
    s["N_REPLIES"] = s.TICKET_ID.map(r.groupby("TICKET_ID").size()).fillna(0).astype(int)
    s["TEXT"] = (s.TITLE.fillna("") + " || " + s.DESCRIPTION.fillna("") + " || "
                 + s.REPLIES.fillna("")).str.lower().str.replace(r"\s+", " ", regex=True)
    s["FLAG_TEXT"] = s.TEXT.map(flag)

    # SAP: a purchase order line naming the machine, created while the ticket was open
    codes = set(s.MACHINE_CODE.dropna().str.strip())
    pat = re.compile(r"(?<![\d.])(\d\.\d{3})(?!\d)")
    lines = po[po.GL_ACCOUNT_NAME.isin(SPARE_PART_ACCOUNTS)].copy()
    lines["MACHINE_CODE"] = lines.ITEM_DESCRIPTION.fillna("").str.findall(pat)
    lines = lines.explode("MACHINE_CODE")
    lines = lines[lines.MACHINE_CODE.isin(codes)]
    m = s[["TICKET_ID", "MACHINE_CODE", "CREATE_DATE", "CLOSE_DATE"]].merge(
        lines[["MACHINE_CODE", "PURCHASE_ORDER", "CREATE_DATE", "VALUE_CHF"]],
        on="MACHINE_CODE", suffixes=("", "_PO"))
    close = m.CLOSE_DATE.fillna(pd.Timestamp(FY_END))
    m = m[(m.CREATE_DATE_PO >= m.CREATE_DATE.dt.normalize()) & (m.CREATE_DATE_PO <= close)]
    s["SAP_PO_LINES"] = s.TICKET_ID.map(m.groupby("TICKET_ID").size()).fillna(0).astype(int)
    s["SAP_PO_VALUE_CHF"] = s.TICKET_ID.map(m.groupby("TICKET_ID").VALUE_CHF.sum()).fillna(0)

    # SAP only confirms a part the text already mentions: a machine has many
    # purchase orders, so on its own the date overlap is too noisy.
    s["FLAG"] = s.FLAG_TEXT
    s.loc[(s.SAP_PO_LINES > 0) & (s.FLAG_TEXT == "part, source unknown"), "FLAG"] = "ordered"
    s["LEAD_TIME_H"] = (s.CLOSE_DATE - s.CREATE_DATE).dt.total_seconds() / 3600
    s["WAIT_CAUSE"] = s.TEXT.map(wait_cause).where(s.FLAG == "ordered")
    OUT.mkdir(parents=True, exist_ok=True)
    s.drop(columns=["REPLIES"]).to_parquet(OUT / "s_tickets.parquet", index=False)
    return s


if __name__ == "__main__":
    s = build()
    print(pd.crosstab(s.FLAG_TEXT, s.SAP_PO_LINES > 0, margins=True))
    print(s.groupby("FLAG").LEAD_TIME_H.describe().round(1))
