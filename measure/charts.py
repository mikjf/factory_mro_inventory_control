"""Charts and tables for the Measure slides (PNG for PowerPoint + one Excel).

    python -m measure.charts

Reads the tables built by measure.tickets and measure.procurement; writes to
../factory_mro_inventory_control_private/outputs/measure/.
"""
import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402
import numpy as np  # noqa: E402
import pandas as pd  # noqa: E402
from scipy import stats  # noqa: E402

import erp  # noqa: E402

DATA = erp.PRIVATE / "data" / "measure"
OUT = erp.PRIVATE / "outputs" / "measure"

# reference palette (dataviz skill), light surface
SURFACE, INK, INK2, GRID = "#ffffff", "#0b0b0b", "#52514e", "#e4e3df"
ORDERED, AVAILABLE, NEUTRAL = "#eb6834", "#2a78d6", "#a3a29c"
FAST_C, SLOW_C = "#2a78d6", "#eb6834"

plt.rcParams.update({
    "font.family": ["Segoe UI", "DejaVu Sans"], "font.size": 10,
    "axes.edgecolor": GRID, "axes.labelcolor": INK2, "axes.titlecolor": INK,
    "xtick.color": INK2, "ytick.color": INK2, "axes.spines.top": False,
    "axes.spines.right": False, "figure.facecolor": SURFACE, "axes.facecolor": SURFACE,
    "savefig.dpi": 300, "savefig.bbox": "tight",
})

BINS_H = [0, 4, 8, 24, 72, 168, 336, 720, 1440, np.inf]
BIN_LABELS = ["< 4 h", "4–8 h", "8–24 h", "1–3 gg", "3–7 gg", "1–2 sett", "2–4 sett", "1–2 mesi", "> 2 mesi"]

GROUPS = {
    "ordered": ("Ricambio da ordinare (impiego diretto)", ORDERED),
    "available": ("Ricambio disponibile in casa (giacenza)", AVAILABLE),
}


def s_tickets():
    s = pd.read_parquet(DATA / "s_tickets.parquet")
    s = s[s.LEAD_TIME_H.notna()].copy()
    s["GROUP"] = s.FLAG.map({"ordered": "ordered", "stock": "available",
                             "part, source unknown": "available", "no part": "no part"})
    return s


def describe_it(x):
    """Excel's 'Statistica descrittiva', in the same order and labels."""
    x = pd.Series(x, dtype=float).dropna()
    return pd.Series({
        "Media": x.mean(), "Errore standard": x.std() / np.sqrt(len(x)),
        "Mediana": x.median(), "Moda": x.round().mode().iloc[0],
        "Deviazione standard": x.std(), "Varianza campionaria": x.var(),
        "Curtosi": x.kurt(), "Asimmetria": x.skew(), "Intervallo": x.max() - x.min(),
        "Minimo": x.min(), "Massimo": x.max(), "Somma": x.sum(), "Conteggio": len(x),
    })


def histogram(x, color, title, path):
    counts = pd.cut(x, BINS_H, labels=BIN_LABELS, right=False).value_counts().reindex(BIN_LABELS)
    share = counts / counts.sum()
    fig, ax = plt.subplots(figsize=(7.2, 3.6))
    bars = ax.bar(BIN_LABELS, counts, color=color, width=0.72, zorder=2)
    for b, c, p in zip(bars, counts, share):
        if c:
            ax.text(b.get_x() + b.get_width() / 2, c, f"{c}\n{p:.0%}", ha="center", va="bottom",
                    fontsize=8, color=INK2)
    ax.set_ylabel("Ticket S")
    ax.set_xlabel("Lead time riparazione (apertura → chiusura ticket)")
    ax.grid(axis="y", color=GRID, linewidth=0.8, zorder=0)
    ax.set_ylim(0, counts.max() * 1.25)
    med = x.median()
    ax.set_title(f"{title} · n = {len(x)} · mediana {med:,.0f} h ({med / 24:,.1f} gg)".replace(",", "'"),
                 loc="left", fontsize=10.5)
    fig.savefig(path)
    plt.close(fig)


def boxplot(s, path):
    data = [s.loc[s.GROUP == g, "LEAD_TIME_H"].clip(lower=0.1) for g in GROUPS]
    fig, ax = plt.subplots(figsize=(7.2, 3.8))
    bp = ax.boxplot(data, vert=False, widths=0.5, patch_artist=True, showfliers=True,
                    medianprops=dict(color=INK, linewidth=2),
                    whiskerprops=dict(color=INK2), capprops=dict(color=INK2),
                    flierprops=dict(marker="o", markersize=3, alpha=0.35, markeredgecolor="none"))
    for patch, fl, (_, (_, c)) in zip(bp["boxes"], bp["fliers"], GROUPS.items()):
        patch.set_facecolor(c)
        patch.set_alpha(0.85)
        patch.set_edgecolor(c)
        fl.set_markerfacecolor(c)
    ax.set_xscale("log")
    ticks = [1, 8, 24, 168, 720, 2160]
    ax.set_xticks(ticks, ["1 h", "8 h", "1 g", "1 sett", "1 mese", "3 mesi"])
    ax.set_yticks([1, 2], [f"{GROUPS[g][0]}\nn = {len(d)}" for g, d in zip(GROUPS, data)])
    ax.grid(axis="x", color=GRID, linewidth=0.8)
    for i, d in enumerate(data, start=1):
        ax.text(d.median(), i + 0.33, f"mediana {d.median():,.0f} h".replace(",", "'"),
                ha="center", fontsize=8.5, color=INK)
    ax.set_xlabel("Lead time riparazione, scala logaritmica")
    ax.set_title("Lead time dei ticket S: ricambio da ordinare vs disponibile in casa (FY26)",
                 loc="left", fontsize=10.5)
    fig.savefig(path)
    plt.close(fig)


def time_share(s, path):
    """Share of tickets vs share of open time, per group (one 100% bar each)."""
    order = ["ordered", "available", "no part"]
    lab = {"ordered": "Ricambio da ordinare", "available": "Ricambio disponibile",
           "no part": "Senza ricambio"}
    col = {"ordered": ORDERED, "available": AVAILABLE, "no part": NEUTRAL}
    n = s.GROUP.value_counts(normalize=True).reindex(order)
    h = s.groupby("GROUP").LEAD_TIME_H.sum().reindex(order)
    h = h / h.sum()
    fig, ax = plt.subplots(figsize=(7.2, 2.4))
    for row, ser in [(1, n), (0, h)]:
        left = 0
        for g in order:
            ax.barh(row, ser[g], left=left, color=col[g], height=0.55, edgecolor=SURFACE, linewidth=2)
            if ser[g] > 0.06:
                ax.text(left + ser[g] / 2, row, f"{ser[g]:.0%}", ha="center", va="center",
                        color="white", fontsize=9, fontweight="bold")
            left += ser[g]
    ax.set_yticks([1, 0], ["Ticket S", "Tempo di apertura"])
    ax.set_xlim(0, 1)
    ax.set_xticks([])
    ax.spines[["left", "bottom"]].set_visible(False)
    handles = [plt.Rectangle((0, 0), 1, 1, color=col[g]) for g in order]
    ax.legend(handles, [lab[g] for g in order], ncol=3, frameon=False, loc="upper center",
              bbox_to_anchor=(0.5, -0.05), fontsize=8.5)
    ax.set_title("Pochi ticket, tanto tempo: quota di ticket S e di ore di apertura (FY26)",
                 loc="left", fontsize=10.5)
    fig.savefig(path)
    plt.close(fig)


def procurement_hist(p, path):
    x = p.loc[p.FOR_LT_STATS, "LT_TOTAL"].dropna()
    bins = list(range(0, 61, 2)) + [np.inf]
    counts, _ = np.histogram(x.clip(upper=61), bins=bins)
    fig, ax = plt.subplots(figsize=(7.2, 3.4))
    centers = [b + 1 for b in bins[:-1]]
    colors = [FAST_C if b + 2 <= 4 and b < 3 else SLOW_C for b in bins[:-1]]
    ax.bar(centers, counts, width=1.7, color=colors, zorder=2)
    ax.axvline(4, color=INK, linestyle="--", linewidth=1)
    ax.set_ylim(0, counts.max() * 1.15)
    ax.text(4.4, counts.max() * 1.08, "soglia 3 gg: a sinistra veloci, a destra lenti",
            fontsize=8.5, color=INK)
    ax.set_xticks([0, 7, 14, 21, 28, 35, 42, 49, 56, 61], ["0", "7", "14", "21", "28", "35", "42", "49", "56", "> 60"])
    ax.set_xlabel("Lead time totale (giorni): creazione ordine → consegna")
    ax.set_ylabel("Righe d'ordine")
    ax.grid(axis="y", color=GRID, linewidth=0.8, zorder=0)
    ax.set_title(f"Lead time di approvvigionamento ricambi · n = {len(x):,} righe · mediana {x.median():.0f} gg · P90 {x.quantile(.9):.0f} gg".replace(",", "'"),
                 loc="left", fontsize=10.5)
    fig.savefig(path)
    plt.close(fig)


def lt_split(p, path):
    s = p[p.FOR_LT_STATS & p.MAIL_SENT.notna() & p.LT_TOTAL.notna()]
    med_int, med_sup = s.LT_INTERNAL.median(), s.LT_SUPPLIER.median()
    share_int = s.LT_INTERNAL.sum() / s.LT_TOTAL.sum()
    fig, ax = plt.subplots(figsize=(7.2, 1.9))
    ax.barh(0, share_int, color=AVAILABLE, height=0.5, edgecolor=SURFACE, linewidth=2)
    ax.barh(0, 1 - share_int, left=share_int, color=ORDERED, height=0.5, edgecolor=SURFACE, linewidth=2)
    ax.annotate(f"Firme e invio {share_int:.0%} · mediana {med_int:.0f} g", xy=(share_int / 2, -0.26),
                xytext=(0, -0.62), ha="left", va="center", fontsize=9, color=INK,
                arrowprops=dict(arrowstyle="-", color=INK2, linewidth=0.8))
    ax.text(share_int + (1 - share_int) / 2, 0, f"Fornitore {1 - share_int:.0%} · mediana {med_sup:.0f} gg",
            ha="center", va="center", color="white", fontsize=9.5, fontweight="bold")
    ax.set_xlim(0, 1)
    ax.set_ylim(-1.1, 0.5)
    ax.axis("off")
    ax.set_title("Dove va il tempo di approvvigionamento (somma dei giorni, righe con data DocuWare)",
                 loc="left", fontsize=10.5)
    fig.savefig(path)
    plt.close(fig)


def risk_matrix(i, path):
    i = i[(i.SPEND_FY26_CHF > 0) & i.CLASS.isin(["fast", "slow"])]
    cells = i.groupby(["CLASS", "RECURRING"]).agg(n=("SPEND_FY26_CHF", "size"), chf=("SPEND_FY26_CHF", "sum"))
    tot_n, tot_chf = cells.n.sum(), cells.chf.sum()
    fig, ax = plt.subplots(figsize=(7.2, 4.0))
    spec = {("slow", True): ("ALTO", 0, 1, "#f6c2ad"), ("slow", False): ("MEDIO", 1, 1, "#fbe3d9"),
            ("fast", True): ("BASSO", 0, 0, "#dbe8f9"), ("fast", False): ("BASSO", 1, 0, "#eef4fc")}
    for key, (lvl, cx, cy, bg) in spec.items():
        n, chf = cells.loc[key, "n"], cells.loc[key, "chf"]
        ax.add_patch(plt.Rectangle((cx, cy), 0.98, 0.98, color=bg))
        ax.text(cx + 0.49, cy + 0.68, f"Rischio {lvl}", ha="center", fontsize=10, fontweight="bold", color=INK)
        ax.text(cx + 0.49, cy + 0.42, f"{n:,} articoli ({n / tot_n:.0%})".replace(",", "'"), ha="center", fontsize=9.5, color=INK)
        ax.text(cx + 0.49, cy + 0.22, f"{chf / 1000:,.0f}K CHF ({chf / tot_chf:.0%} della spesa)".replace(",", "'"), ha="center", fontsize=9.5, color=INK)
    ax.set_xlim(0, 2)
    ax.set_ylim(0, 2)
    ax.set_xticks([0.49, 1.49], ["Ricorrente (≥ 2 acquisti FY26)", "Una tantum (1 acquisto)"])
    ax.set_yticks([0.49, 1.49], ["Veloce\n(≤ 3 gg)", "Lento\n(> 3 gg)"])
    ax.tick_params(length=0)
    ax.spines[["left", "bottom"]].set_visible(False)
    ax.set_title("Rischio ricambi: lead time × frequenza d'acquisto (articoli acquistati nel FY26)",
                 loc="left", fontsize=10.5)
    fig.savefig(path)
    plt.close(fig)


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    s = s_tickets()
    p = pd.read_parquet(DATA / "po_lines.parquet")
    i = pd.read_parquet(DATA / "items.parquet")

    for g, (title, color) in GROUPS.items():
        histogram(s.loc[s.GROUP == g, "LEAD_TIME_H"], color, title, OUT / f"hist_{g}.png")
    boxplot(s, OUT / "boxplot_ordered_vs_available.png")
    time_share(s, OUT / "time_share.png")
    procurement_hist(p, OUT / "hist_procurement_lt.png")
    lt_split(p, OUT / "lt_split.png")
    risk_matrix(i, OUT / "risk_matrix.png")

    a = s.loc[s.GROUP == "ordered", "LEAD_TIME_H"]
    b = s.loc[s.GROUP == "available", "LEAD_TIME_H"]
    desc = pd.DataFrame({GROUPS["ordered"][0]: describe_it(a), GROUPS["available"][0]: describe_it(b),
                         "Giacenza esplicita (Modula, scorta)": describe_it(s.loc[s.FLAG == "stock", "LEAD_TIME_H"]),
                         "Senza ricambio": describe_it(s.loc[s.GROUP == "no part", "LEAD_TIME_H"])})
    mw = stats.mannwhitneyu(a, b, alternative="greater")
    test = pd.Series({"Test": "Mann-Whitney U (unilaterale: da ordinare > disponibile)",
                      "U": mw.statistic, "p-value": mw.pvalue,
                      "Mediana da ordinare (h)": a.median(), "Mediana disponibile (h)": b.median()})
    sp = p[p.FOR_LT_STATS]
    lt = pd.DataFrame({"Totale (creazione → consegna)": describe_it(sp.LT_TOTAL),
                       "Interno (creazione → MAIL SENT)": describe_it(sp.LT_INTERNAL),
                       "Fornitore (MAIL SENT → consegna)": describe_it(sp.LT_SUPPLIER)})
    with pd.ExcelWriter(OUT / "measure_tables.xlsx") as xw:
        desc.to_excel(xw, sheet_name="Lead time riparazione (h)")
        test.to_frame("valore").to_excel(xw, sheet_name="Test")
        lt.to_excel(xw, sheet_name="Lead time acquisto (gg)")
    pd.set_option("display.width", 220)
    import sys
    sys.stdout.reconfigure(encoding="utf-8")
    print(desc.round(1).to_string())
    print(test.to_string())
    print(lt.round(1).to_string())
    print(f"written to {OUT}")


if __name__ == "__main__":
    main()
