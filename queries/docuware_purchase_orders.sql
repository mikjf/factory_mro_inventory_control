-- DocuWare purchase orders: when each order was created and when it was
-- signed and sent to the supplier (STATUS_PROCESS = 'MAIL SENT').
--
-- For IT: please run on the DocuWare database (dwdata) and send the result
-- as .xlsx or .csv. Read-only, about 30k rows. If possible, instead grant
-- read access on dwdata.dbo.OA to our Windows account (or expose it through
-- the linked server) so the project can refresh it itself.
--
-- Used to split the spare-part lead time into internal (creation -> signed
-- and sent) and supplier (sent -> delivery). The order number joins to the
-- SAP purchase order (NUMERO_OA = OPOR.DocNum).
--
-- Last modification time is used as the "mail sent" time: after MAIL SENT
-- the document is no longer changed. If DocuWare keeps a workflow history
-- with the actual signature / sending timestamps, those are better.

SELECT
    OA.DWDOCID,
    OA.NUMERO_OA,
    OA.DOCUMENT_TYPE,
    OA.STATUS_PROCESS,
    OA.STATUS_ACQUISTO,
    OA.DATA_ORDINAZIONE,
    OA.DWSTOREDATETIME,        -- document created in DocuWare
    OA.DWMODDATETIME,          -- last modification (= MAIL SENT)
    OA.DWCONTENTMODDATETIME
FROM dwdata.dbo.OA AS OA
WHERE OA.DOCUMENT_TYPE = 'Purchase Order'
  AND OA.DWSTOREDATETIME >= '20241001'
  AND OA.DWSTOREDATETIME <  '20261101'
