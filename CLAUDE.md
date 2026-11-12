# factory_mro_inventory_control

MRO (maintenance, repair and operations) inventory control: the data behind
the Lean Six Sigma project on maintenance spare parts (Modula warehouse, SAP,
FactoryApp tickets).

## Layout

- `queries/*.sql`: the extract queries (FactoryApp tickets and replies,
  machine monitoring, SAP maintenance purchase order lines; DocuWare for IT).
- `extract.py`: runs them and writes Parquet to
  `../factory_mro_inventory_control_private/data/extract/`.
- `define.py`: the Define KPIs of slides 3 and 5.
- Private settings (the SAP linked-server prefix) live in
  `../factory_mro_inventory_control_private/fmic.ini`, never here.

## ERP access (Infor VISUAL on SQL Server) - read-only

- Python: conda env `fmic`
  (`%LOCALAPPDATA%\miniconda3\envs\fmic\python.exe`), built from Python
  3.12.14 (conda-forge) plus `requirements.txt`.
- Connect only through `erp.py` (`erp.query(sql, params)` returns a
  DataFrame). It reads server/database/driver from
  `../factory_planner_private/extract.ini`, section `[database]`. Never copy
  those values into code, commits or chat.
- Windows authentication only (`Trusted_Connection=yes`), no username or
  password anywhere.
- The connection is opened `readonly=True` and runs
  `SET DEADLOCK_PRIORITY LOW`, so the ERP users always win; a query chosen as
  deadlock victim (SQLSTATE 40001) is retried after 10 s, at most 3 times.

### Rules

- **SELECT only.** Never INSERT, UPDATE, DELETE, MERGE, EXEC or any DDL. If
  something must change in the database, write the statement and hand it to
  the user to run.
- **Keep queries light:** it is the live production database. Filter by date,
  select only the columns needed, no `SELECT *` on large tables.
- **Data never goes into git.** Results stay in
  `../factory_mro_inventory_control_private/` (not under git), e.g. its
  `data/` folder.
- **No identifiers in commits or commit messages:** no work orders, part IDs,
  families, customers, suppliers or people's names.
- **People:** never share names outside the company, and no speed or output
  per person.
