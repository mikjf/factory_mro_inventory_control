-- FactoryApp maintenance tickets (S = breakdown, PM2 = preventive), one row
-- per ticket, created in [?, ?).
--
-- Same joins and filters as the team's "PM2+S TICKETS" export, plus the
-- ticket id (to join the replies), title and description. No people's names.
SELECT
    T.ROWID                                   AS TICKET_ID,
    T.TYPE,
    I.CODE                                    AS MACHINE_CODE,
    I.NAME                                    AS MACHINE_NAME,
    M.NAME                                    AS MANUFACTURER,
    D.NAME                                    AS DEPARTMENT,
    CA.NAME                                   AS CATEGORY,
    T.CREATE_DATE,
    T.EXPECTED_CLOSE_DATE,
    T.CLOSE_DATE,
    T.LAST_REPLY,
    T.STARTED_DOWN,
    T.IS_DOWN,
    T.EXPECTED_WORKED_HOURS,
    T.WORKED_HOURS,
    T.STATUS,
    T.TITLE,
    CAST(T.DESCRIPTION AS NVARCHAR(MAX))      AS DESCRIPTION
FROM Z_FACTORYAPP_MAINTENANCETICKET_TICKETS T
INNER JOIN Z_FACTORYAPP_MAINTENANCETICKET_CATEGORIES    CA ON CA.ROWID = T.CATEGORY_ID
INNER JOIN Z_FACTORYAPP_MAINTENANCETICKET_ITEMS         I  ON I.ROWID  = T.ITEM_ID
INNER JOIN Z_FACTORYAPP_MAINTENANCETICKET_MANUFACTURERS M  ON M.ROWID  = I.MANUFACTURER_ID
INNER JOIN Z_FACTORYAPP_MAINTENANCETICKET_DEPARTMENTS   D  ON D.ROWID  = I.DEPARTMENT_ID
WHERE T.CREATE_DATE >= ?
  AND T.CREATE_DATE <  ?
