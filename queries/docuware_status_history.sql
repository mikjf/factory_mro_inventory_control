-- DocuWare purchase orders: every change of STATUS_PROCESS (CHECK1, CHECK2,
-- MAIL SENT, ...) with its exact time, from the document audit trail.
-- One row per status change; orders stored in DocuWare in [?, ?) are
-- filtered on the local side by extract.py's period.
--
-- DocuWare's database ({dwdb}) is reached through the linked server; both
-- placeholders are filled in by extract.py from the private settings file. OPENQUERY runs the statement on
-- the DocuWare server, because its tables have XML columns, which distributed
-- queries cannot read. No user names are selected.
SELECT *
FROM OPENQUERY({linked}, '
    SELECT
        o.DWDOCID,
        o.NUMERO_OA,
        o.DWSTOREDATETIME,
        a.eventLoggedDate AS STATUS_DATE,
        a.eventData.value(''(/AuditEntryData/AuditEntryValue[@name="Status_Process"]/@newValue)[1]'', ''nvarchar(50)'') AS NEW_STATUS,
        a.eventData.value(''(/AuditEntryData/AuditEntryValue[@name="Status_Process"]/@oldValue)[1]'', ''nvarchar(50)'') AS OLD_STATUS
    FROM {dwdb}.dbo.OA_AUD a
    JOIN {dwdb}.dbo.OA o ON o.DWDOCID = a.docid
    WHERE a.eventType = 5
      AND o.DOCUMENT_TYPE = ''Purchase Order''
      AND o.DWSTOREDATETIME >= ''20241001''
      AND a.eventData.exist(''/AuditEntryData/AuditEntryValue[@name="Status_Process"]'') = 1
')
WHERE DWSTOREDATETIME >= ? AND DWSTOREDATETIME < ?
