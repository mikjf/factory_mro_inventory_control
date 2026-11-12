-- FactoryApp ticket replies (the maintainers' comments), created in [?, ?).
--
-- Same filters as the team's "PM2+S REPLIES" export (operators only, not
-- deleted), plus TICKET_ID, which links each reply to its ticket directly.
-- The export had no ticket id, so replies were matched on the second of the
-- ticket's last reply. No people's names or codes.
SELECT
    TD.ROWID                                  AS REPLY_ID,
    TD.TICKET_ID,
    TK.TYPE,
    WT.NAME                                   AS WORKTYPE,
    TD.CREATE_DATE,
    TD.WORKED_HOURS,
    TD.RATING,
    TD.IS_DOWN,
    TD.STATUS,
    CAST(TD.DESCRIPTION AS NVARCHAR(MAX))     AS DESCRIPTION
FROM Z_FACTORYAPP_MAINTENANCETICKET_TICKETDETAILS TD
INNER JOIN Z_FACTORYAPP_MAINTENANCETICKET_TICKETS   TK ON TK.ROWID = TD.TICKET_ID
INNER JOIN Z_FACTORYAPP_MAINTENANCETICKET_WORKTYPES WT ON WT.ROWID = TD.WORKTYPE_ID
INNER JOIN Z_FACTORYAPP_USERS                       U  ON U.ROWID  = TD.USER_ID
WHERE TD.IS_OPERATOR = 1
  AND TD.IS_DELETED  = 0
  AND TD.CREATE_DATE >= ?
  AND TD.CREATE_DATE <  ?
