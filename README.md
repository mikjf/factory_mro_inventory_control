# Factory MRO inventory control

#### -- Project Status: [Completed]

## Objective

The data behind a Lean Six Sigma (DMAIC) project on maintenance spare parts -
MRO: maintenance, repair and operations.

When a machine breaks down, how long it stays down depends heavily on whether
the spare part is already in house or has to be ordered. This project measures
that from the plant's own systems - maintenance tickets, machine monitoring,
purchase orders and their approval trail - and turns it into the figures and
charts of the project's Define and Measure phases, and into the levers of the
Improve phase: which parts to stock in the automated warehouse, which to fast-
track through approval, which to keep buying on demand.

It is **read-only**: it extracts, analyses and fills the presentation; nothing
is written to any of the source systems.

### What this project demonstrates

- **One extract across four systems:** the ERP (Infor VISUAL), the maintenance
  ticketing app, SAP Business One purchasing and DocuWare's document audit
  trail, reached from one connection through linked servers - DocuWare through
  `OPENQUERY`, because its tables have XML columns
- **Classifying free text:** the ticketing app has no "spare part" field, so
  each breakdown ticket is classified from its title, description and replies
  (part ordered, part from stock, part of unknown source, no part), and
  cross-checked against purchase orders for the same machine while the ticket
  was open
- **Lead times split into their parts:** total, internal (approval and sending,
  from the audit trail) and supplier, with on-time delivery measured against
  the supplier's promise date
- **Statistics for the Measure phase:** lead-time distributions, a one-sided
  Mann-Whitney test of "part ordered" against "part in stock", a risk matrix
  and a spend-based classification of items into the three Improve levers
- **A presentation filled by code:** every number on the Measure slides is
  computed at run time and written into the PowerPoint with `python-pptx`, so a
  fresh extract refreshes the deck instead of someone retyping it

### Tech stack

- Python 3.12, pandas, SciPy, matplotlib, pyarrow, openpyxl
- python-pptx (and PowerPoint, for rendering slides to PNG)
- pyodbc and SQL Server (T-SQL), with linked servers to SAP Business One and
  DocuWare

### Data

The extracts and everything built from them carry real part numbers, machines,
orders and suppliers, and the presentation carries real names and figures. All
of it stays in a private folder next to this repository, which is never a
repository itself; the `.gitignore` and a commit hook keep data files out of
here. The names of the linked servers, the SAP database and the DocuWare
database are private settings too: the queries hold placeholders (`{sap}`,
`{linked}`, `{dwdb}`), filled in when the extract runs.

## Repository layout

```
queries/
  factoryapp_tickets.sql          maintenance tickets: breakdown and preventive
  factoryapp_replies.sql          the replies on those tickets
  machine_monitoring.sql          weekly planned hours and downtime per machine group
  sap_maintenance_po_lines.sql    SAP purchase order lines on maintenance accounts
  docuware_purchase_orders.sql    purchase orders as stored in DocuWare
  docuware_status_history.sql     every approval status change, from the audit trail
extract.py                        runs the queries -> Parquet, with a manifest
erp.py                            read-only database helper
define.py                         Define phase KPIs
measure/
  tickets.py                      breakdown tickets with their spare-part class
  procurement.py                  lead times, item classes, risk matrix, levers
  charts.py                       charts and tables for the slides
deck/
  build_measure.py                fills the Measure slides of the presentation
  render.ps1                      exports slides to PNG through PowerPoint
```

## Running it

In the `fmic` conda environment (Python 3.12.14 plus `requirements.txt`):

```bash
python extract.py                 # all queries; or name some: python extract.py tickets replies
python define.py                  # Define KPIs, side by side with the approved figures
python -m measure.tickets
python -m measure.procurement
python -m measure.charts
python -m deck.build_measure      # works on a copy of the presentation
```

```powershell
powershell -File deck\render.ps1 <pptx> <out folder> 13,14,15
```

- **Read-only, Windows login.** No user name or password is stored anywhere.
  The connection settings live in `../factory_shared_private/connections/`,
  the project's own private settings in
  `../factory_mro_inventory_control_private/fmic.ini`.
- **It gives way to ERP users.** A read that collides with someone saving is
  cancelled, never their work, and retried up to three times.
- **Reproducible extracts.** Periods are passed in rather than derived from
  today's date, and `extract_manifest.json` records when each query ran, its
  rows, columns and a SHA-256 of its text.
- Every output goes to the private folder; `extract.py` refuses to write
  inside this repository.
