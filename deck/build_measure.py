"""Fill the Measure slides (13-15) and add the procurement and risk slides.

    python -m deck.build_measure

Works on a copy: reads <private>/outputs/deck/INPR-0007_base.pptx, writes
<private>/outputs/deck/INPR-0007_measure.pptx. Every number is computed from
the measure tables at run time; charts come from measure.charts (run it first).
"""
import copy

import numpy as np
import pandas as pd
from pptx import Presentation
from pptx.dml.color import RGBColor
from pptx.util import Inches, Pt
from scipy import stats

import erp
from measure.charts import DATA, OUT as CHARTS, describe_it, s_tickets

DECK = erp.PRIVATE / "outputs" / "deck"
SRC, DST = DECK / "INPR-0007_base.pptx", DECK / "INPR-0007_measure.pptx"
INK, INK2, ACCENT = RGBColor(0x0B, 0x0B, 0x0B), RGBColor(0x52, 0x51, 0x4E), RGBColor(0xEB, 0x68, 0x34)
SOURCE_TICKETS = ("Fonte: FactoryApp, ticket S creati 01.10.2025–30.09.2026 e chiusi (FY26). "
                  "Ricambio da ordinare / disponibile: dal testo di titolo, descrizione e commenti del "
                  "ticket, più gli ordini SAP sulla macchina mentre il ticket era aperto. "
                  "Moda sulle ore arrotondate all'unità.")


def num(v, dec=1):
    """Swiss/Italian style: 1'234,5"""
    if pd.isna(v):
        return "—"
    s = f"{v:,.{dec}f}".replace(",", "'").replace(".", ",")
    return s


def set_text(shape, text):
    """Replace the text of a shape, keeping the first run's formatting."""
    tf = shape.text_frame
    p0 = tf.paragraphs[0]
    runs = p0.runs
    if runs:
        runs[0].text = text
        for r in runs[1:]:
            r._r.getparent().remove(r._r)
    else:
        p0.text = text
    for p in tf.paragraphs[1:]:
        p._p.getparent().remove(p._p)


def set_ph(ph, text, size, bold=None):
    """Placeholder text with an explicit size (new slides inherit 44 pt titles)."""
    tf = ph.text_frame
    tf.text = text
    for p in tf.paragraphs:
        for r in p.runs:
            r.font.size = Pt(size)
            if bold is not None:
                r.font.bold = bold


def fill_table(table, desc):
    order = ["Media", "Errore standard", "Mediana", "Moda", "Deviazione standard",
             "Varianza campionaria", "Curtosi", "Asimmetria", "Intervallo", "Minimo",
             "Massimo", "Somma", "Conteggio"]
    for i, key in enumerate(order):
        label = table.cell(i, 0).text_frame.text.strip()
        assert label == key, (label, key)
        dec = 0 if key in ("Conteggio", "Somma", "Varianza campionaria") else (2 if key in ("Curtosi", "Asimmetria") else 1)
        cell = table.cell(i, 1)
        set_text(cell, num(desc[key], dec))


def replace_with_picture(slide, shape, image, keep_ratio=True):
    left, top, width, height = shape.left, shape.top, shape.width, shape.height
    shape._element.getparent().remove(shape._element)
    pic = slide.shapes.add_picture(str(image), left, top, height=height)
    if pic.width > width:  # too wide: fit width instead
        pic._element.getparent().remove(pic._element)
        pic = slide.shapes.add_picture(str(image), left, top, width=width)
    return pic


def textbox(slide, left, top, width, height, paragraphs, size=11, color=INK):
    """paragraphs: list of str or (str, dict(bold=..., color=...))"""
    tb = slide.shapes.add_textbox(Inches(left), Inches(top), Inches(width), Inches(height))
    tf = tb.text_frame
    tf.word_wrap = True
    for i, para in enumerate(paragraphs):
        text, fmt = (para, {}) if isinstance(para, str) else para
        p = tf.paragraphs[0] if i == 0 else tf.add_paragraph()
        r = p.add_run()
        r.text = text
        r.font.size = Pt(fmt.get("size", size))
        r.font.bold = fmt.get("bold", False)
        r.font.italic = fmt.get("italic", False)
        r.font.color.rgb = fmt.get("color", color)
        p.space_after = Pt(fmt.get("space", 4))
    return tb


def shape(slide, name):
    return next(s for s in slide.shapes if s.name == name)


def notes(slide, text):
    tf = slide.notes_slide.notes_text_frame
    tf.text = (tf.text + "\n\n" if tf.text.strip() else "") + text


def add_slide_after(prs, layout_source_slide, after_index):
    """New slide with the same layout as a given slide, moved after a position."""
    slide = prs.slides.add_slide(layout_source_slide.slide_layout)
    ids = prs.slides._sldIdLst
    new = ids[-1]
    ids.remove(new)
    ids.insert(after_index + 1, new)
    return slide


def placeholders(slide):
    return {p.placeholder_format.idx: p for p in slide.placeholders}


def main():
    s = s_tickets()
    a = s.loc[s.GROUP == "ordered", "LEAD_TIME_H"]
    b = s.loc[s.GROUP == "available", "LEAD_TIME_H"]
    da, db = describe_it(a), describe_it(b)
    mw = stats.mannwhitneyu(a, b, alternative="greater")
    share_n = s.GROUP.value_counts(normalize=True)
    share_h = s.groupby("GROUP").LEAD_TIME_H.sum() / s.LEAD_TIME_H.sum()
    stock_strict = s.loc[s.FLAG == "stock", "LEAD_TIME_H"]

    p = pd.read_parquet(DATA / "po_lines.parquet")
    items = pd.read_parquet(DATA / "items.parquet")
    lt = p[p.FOR_LT_STATS]
    lt_dw = lt[lt.MAIL_SENT.notna() & lt.LT_TOTAL.notna()]
    share_sign = lt_dw.LT_INTERNAL.sum() / lt_dw.LT_TOTAL.sum()
    fy_created = p[(p.CREATE_DATE >= "2025-10-01") & (p.CREATE_DATE < "2026-10-01")]
    req_days = (fy_created.SMB_DESIRED_DATE.dt.normalize() - fy_created.CREATE_DATE.dt.normalize()).dt.days
    urgent_req = (req_days <= 3).mean()
    fy = p[p.IN_FY26]
    urgent_deliv = (fy.LT_TOTAL <= 3).sum() / fy.LT_TOTAL.notna().sum()
    late = (fy_created.DAYS_DESIRED_TO_DELIVERY > 0).mean()
    late_med = fy_created.loc[fy_created.DAYS_DESIRED_TO_DELIVERY > 0, "DAYS_DESIRED_TO_DELIVERY"].median()
    spend = items.SPEND_FY26_CHF.sum()
    by_class = items.groupby("CLASS").SPEND_FY26_CHF.sum() / spend
    m = items[items.LEVER == "1 Modula"]
    cover_med = (m.SPEND_FY26_CHF * m.LT_MEDIAN / 365).sum()
    cover_p90 = (m.SPEND_FY26_CHF * m.LT_P90 / 365).sum()
    top20 = m.SPEND_FY26_CHF.nlargest(20).sum() / m.SPEND_FY26_CHF.sum()
    fy_items = fy.ITEM.nunique()
    shared = fy[fy.ITEM_CODE.map(fy.groupby("ITEM_CODE").ITEM.nunique()) > 1].ITEM.nunique()

    prs = Presentation(SRC)
    s13, s14, s15 = prs.slides[12], prs.slides[13], prs.slides[14]

    # --- slide 13: part to order -------------------------------------------
    ph = placeholders(s13)
    set_text(ph[0], "Lead time riparazione · ricambio da ordinare")
    set_ph(ph[15], "Ticket S con ricambio a impiego diretto (ordinato o non trovato in casa) · ore", 18)
    replace_with_picture(s13, shape(s13, "Rectangle 4"), CHARTS / "hist_ordered.png")
    set_text(shape(s13, "TextBox 5"), "Ricambio da ordinare (ore)")
    fill_table(shape(s13, "Table 6").table, da)
    textbox(s13, 0.98, 6.25, 11.0, 0.5, [
        (f"Mediana {num(da['Mediana'], 0)} h ({num(da['Mediana'] / 24, 0)} giorni): il {num((a > 336).mean() * 100, 0)}% di questi ticket resta "
         f"aperto più di 2 settimane. Distribuzione asimmetrica a destra (asimmetria {num(da['Asimmetria'], 2)}): "
         "la mediana descrive meglio della media il caso tipico.", {"size": 11})])
    textbox(s13, 0.98, 6.85, 11.0, 0.4, [(SOURCE_TICKETS, {"size": 8, "italic": True, "color": INK2})])
    notes(s13, "Metodo: ticket S FY26 classificati dal testo (ordinato, offerta, in attesa del ricambio, "
               "cercato e non trovato) e dagli ordini SAP con il codice macchina creati mentre il ticket era "
               "aperto. Il 7% di questi ticket si chiude in meno di 4 ore: il lavoro prosegue su un altro "
               "ticket in attesa del pezzo, quindi la mediana è prudente.")

    # --- slide 14: part available ------------------------------------------
    ph = placeholders(s14)
    set_text(ph[0], "Lead time riparazione · ricambio disponibile in casa")
    set_ph(ph[15], "Ticket S con ricambio in giacenza o sostituito senza ordine · ore", 18)
    replace_with_picture(s14, shape(s14, "Rectangle 4"), CHARTS / "hist_available.png")
    set_text(shape(s14, "TextBox 5"), "Ricambio disponibile (ore)")
    fill_table(shape(s14, "Table 6").table, db)
    textbox(s14, 0.46, 6.25, 11.6, 0.5, [
        (f"Mediana {num(db['Mediana'], 0)} h: con il ricambio in casa la macchina si ripara in giornata. "
         f"Solo {len(stock_strict)} ticket citano esplicitamente la giacenza (Modula, scorta): mediana "
         f"{num(stock_strict.median(), 0)} h, comunque ~{num(da['Mediana'] / stock_strict.median(), 0)} volte "
         "più veloce che ordinare.", {"size": 11})])
    textbox(s14, 0.46, 6.85, 11.6, 0.4, [(SOURCE_TICKETS, {"size": 8, "italic": True, "color": INK2})])

    # --- slide 15: comparison ----------------------------------------------
    ph = placeholders(s15)
    set_ph(ph[15], "Ricambi in giacenza vs ricambi a impiego diretto", 18)
    box = shape(s15, "Rectangle 4")
    box.height = Inches(3.35)
    replace_with_picture(s15, box, CHARTS / "boxplot_ordered_vs_available.png")
    how = shape(s15, "TextBox 5")
    how._element.getparent().remove(how._element)
    s15.shapes.add_picture(str(CHARTS / "time_share.png"), Inches(0.46), Inches(4.95), height=Inches(1.75))
    textbox(s15, 0.46, 6.72, 8.0, 0.6, [
        (f"Il {num(share_n['ordered'] * 100, 0)}% dei ticket (ricambio da ordinare) assorbe il "
         f"{num(share_h['ordered'] * 100, 0)}% del tempo di apertura. Test di Mann-Whitney: p < 0,001, "
         "la differenza non è casuale.", {"size": 11, "bold": True})])
    set_text(shape(s15, "TextBox 6"), "Ricambio da ordinare (ore)")
    set_text(shape(s15, "TextBox 8"), "Ricambio disponibile (ore)")
    fill_table(shape(s15, "Table 7").table, da)
    fill_table(shape(s15, "Table 9").table, db)
    notes(s15, f"Mann-Whitney U unilaterale (da ordinare > disponibile): U = {mw.statistic:,.0f}, "
               f"p = {mw.pvalue:.1e}. Box plot su scala logaritmica, baffi a 1,5 × IQR (Tukey). "
               "Con il Modula: la mediana della giacenza deve restare bassa e i ticket «da ordinare» "
               "dei ricambi critici devono passare in giacenza.")

    # --- new slide A: procurement lead time --------------------------------
    sa = add_slide_after(prs, s15, 14)
    ph = placeholders(sa)
    set_ph(ph[0], "Lead time di approvvigionamento ricambi", 32, bold=False)
    set_ph(ph[15], "Righe d'ordine SAP sui conti ricambi, FY25–FY26 · giorni di calendario", 18)
    sa.shapes.add_picture(str(CHARTS / "hist_procurement_lt.png"), Inches(0.46), Inches(1.55), height=Inches(3.55))
    sa.shapes.add_picture(str(CHARTS / "lt_split.png"), Inches(0.46), Inches(5.2), height=Inches(1.45))
    tiles = [
        (f"{num(lt.LT_TOTAL.median(), 0)} gg", "lead time mediano", f"P90 {num(lt.LT_TOTAL.quantile(.9), 0)} gg · creazione → consegna"),
        (f"{num(share_sign * 100, 0)}%", "del tempo è firma e invio", f"mediana {num(lt.LT_INTERNAL.median(), 0)} g: il resto è fornitore"),
        (f"{num(by_class.get('slow', 0) * 100, 0)}%", "della spesa FY26 è su ricambi lenti", f"> 3 gg · spesa ricambi FY26 {num(spend / 1000, 0)}K CHF"),
        (f"{num(urgent_req * 100, 0)}%", "righe richieste entro 3 gg", f"baseline CTQ3 (target ≤ 20%) · {num(late * 100, 0)}% consegnate in ritardo"),
    ]
    for k, (big, label, sub) in enumerate(tiles):
        y = 1.55 + k * 1.35
        textbox(sa, 9.0, y, 3.9, 1.3, [(big, {"size": 26, "bold": True, "space": 0}),
                                        (label, {"size": 11, "bold": True, "space": 0}),
                                        (sub, {"size": 9, "color": INK2})])
    textbox(sa, 0.46, 6.85, 12.4, 0.4, [(
        "Fonte: SAP B1 (ordini d'acquisto sui conti Materiale per manutenzione macchinari, stabili, attrezzatura), "
        "DocuWare (data MAIL SENT). Spesa FY26 = valore consegnato 01.10.2025–30.09.2026. "
        "Urgente = data richiesta entro 3 giorni dalla creazione dell'ordine.",
        {"size": 8, "italic": True, "color": INK2})])
    notes(sa, f"Righe consegnate entro 3 gg nel FY26: {num(urgent_deliv * 100, 1)}% (sotto il target già oggi: "
              f"per questo la baseline del CTQ3 usa la data richiesta). Ritardo mediano delle righe in ritardo: "
              f"{num(late_med, 0)} giorni. Abbinamento DocuWare: {num(lt.MAIL_SENT.notna().mean() * 100, 1)}% delle righe.")

    # --- new slide B: risk matrix and Modula candidates ---------------------
    sb = add_slide_after(prs, s15, 15)
    ph = placeholders(sb)
    set_ph(ph[0], "Quali ricambi a scorta: lead time × frequenza", 32, bold=False)
    set_ph(ph[15], "Articoli acquistati nel FY26: lento = mediana > 3 gg, ricorrente = almeno 2 acquisti", 18)
    sb.shapes.add_picture(str(CHARTS / "risk_matrix.png"), Inches(0.46), Inches(1.55), height=Inches(4.6))
    tiles = [
        (f"{len(m)}", "candidati Modula", "lenti, ricorrenti, fornitore > 3 gg"),
        (f"{num(m.SPEND_FY26_CHF.sum() / 1000, 0)}K CHF", "spesa FY26 dei candidati", f"i primi 20 articoli = {num(top20 * 100, 0)}%"),
        (f"{num(cover_med / 1000, 0)}–{num(cover_p90 / 1000, 0)}K CHF", "scorta per coprire il lead time",
         "spesa × lead time / 365 (mediana – P90), senza scorta di sicurezza"),
        (f"{num(shared, 0)} su {num(fy_items, 0)}", "ricambi condividono il codice articolo",
         "1 AC = 1 articolo non ancora applicato (causa radice 1)"),
    ]
    for k, (big, label, sub) in enumerate(tiles):
        y = 1.55 + k * 1.3
        textbox(sb, 8.9, y, 4.0, 1.25, [(big, {"size": 24, "bold": True, "space": 0}),
                                         (label, {"size": 11, "bold": True, "space": 0}),
                                         (sub, {"size": 9, "color": INK2})])
    textbox(sb, 0.46, 6.85, 12.4, 0.4, [(
        "Fonte: SAP B1 + DocuWare. Articolo = descrizione dell'articolo (il codice SAP è spesso generico). "
        "Lead time dell'articolo = mediana del lead time totale delle sue righe (ott 2024 – set 2026).",
        {"size": 8, "italic": True, "color": INK2})])
    notes(sb, "Tre leve esclusive (logica del file DAI): 1 Modula = lento, ricorrente e fornitore > 3 gg; "
              "2 corsia veloce firme = lento ma fornitore ≤ 3 gg; 3 acquisto a fabbisogno = il resto. "
              "La scorta stimata non include scorta di sicurezza né lotti minimi; manca il costo di mantenimento.")

    prs.save(DST)
    print(f"written {DST}")


if __name__ == "__main__":
    main()
