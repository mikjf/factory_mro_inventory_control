-- DocuWare purchase orders: when each order was created and when it was
-- last modified (= MAIL SENT for sent orders), one row per document.
--
-- DocuWare's database ({dwdb}) is reached through the linked server; both
-- placeholders are filled in by extract.py from the private settings file. OPENQUERY runs the statement on
-- the DocuWare server, because the table has XML columns, which distributed
-- queries cannot read. No user names are selected.
--
-- The order number joins to the SAP purchase order (NUMERO_OA = OPOR.DocNum).
-- The exact time of each status change is in docuware_status_history.sql.
SELECT *
FROM OPENQUERY({linked}, '
    SELECT
        OA.DWDOCID,
        OA.NUMERO_OA,
        OA.DOCUMENT_TYPE,
        OA.STATUS_PROCESS,
        OA.STATUS_ACQUISTO,
        OA.DATA_ORDINAZIONE,
        OA.DWSTOREDATETIME,
        OA.DWMODDATETIME,
        OA.DWCONTENTMODDATETIME
    FROM {dwdb}.dbo.OA AS OA
    WHERE OA.DOCUMENT_TYPE = ''Purchase Order''
      AND OA.DWSTOREDATETIME >= ''20241001''
')
WHERE DWSTOREDATETIME >= ? AND DWSTOREDATETIME < ?
