-- SAP B1 purchase order lines booked on maintenance accounts, with their
-- goods receipts: one row per order line, orders created in [?, ?).
--
-- Based on the team's SIXSIGMA_3 query. {sap} is the SAP database prefix
-- (reached through a linked server), filled in by extract.py from the private
-- settings file: it never appears in this repository.
--
-- Changes from SIXSIGMA_3:
-- * VALUE_CHF = POR1.LINETOTAL. LINETOTAL is already in CHF (local currency);
--   SIXSIGMA_3 multiplied it by the document rate again, so EUR/USD lines
--   were converted twice. UNIT_PRICE_CHF = LINETOTAL / QUANTITY.
-- * The period is passed in (CREATE_DATE), instead of being derived from
--   today's date, so the extract is reproducible; the extra filter on the
--   year of the desired date is dropped.
-- * GL_ACCOUNT_CODE added, so the spare-part accounts can be selected by code.
-- * Cancelled goods receipts (OPDN.CANCELED <> 'N') are left out. A receipt
--   cancelled and entered again was counted twice (double quantity and
--   value), and a receipt cancelled without replacement counted as delivered.
WITH RECEIPTS AS (
SELECT
    OPOR.CARDCODE COLLATE SQL_Latin1_General_CP850_CI_AS AS VENDOR_ID,
    OPOR.CARDNAME COLLATE SQL_Latin1_General_CP850_CI_AS AS VENDOR,
    POR1.DOCENTRY                         AS PO_ENTRY,
    CAST(OPOR.DOCNUM AS NVARCHAR(20))     AS PURCHASE_ORDER,
    POR1.LINENUM                          AS LINE_NO,
    POR1.ITEMCODE                         AS ITEM_CODE,
    POR1.DSCRIPTION                       AS ITEM_DESCRIPTION,
    POR1.ACCTCODE                         AS GL_ACCOUNT_CODE,
    OACT.ACCTNAME                         AS GL_ACCOUNT_NAME,
    OPOR.CREATEDATE                       AS CREATE_DATE,
    ISNULL(POR1.SHIPDATE, OPOR.DOCDUEDATE) AS SMB_DESIRED_DATE,
    CASE
        WHEN OSHP.TRNSPNAME LIKE 'EXW%' OR OSHP.TRNSPNAME LIKE 'FCA%' OR OSHP.TRNSPNAME LIKE 'CPT%' OR OSHP.TRNSPNAME LIKE 'CIP%' THEN OPDN.TAXDATE
        WHEN OSHP.TRNSPNAME LIKE 'Fran%' OR OSHP.TRNSPNAME LIKE 'Frank%' THEN OPDN.TAXDATE
        WHEN OSHP.TRNSPNAME LIKE 'DAP%' OR OSHP.TRNSPNAME LIKE 'DPU%' OR OSHP.TRNSPNAME LIKE 'DDP%' THEN OPDN.DOCDATE
        WHEN OSHP.TRNSPNAME LIKE 'DAF%' OR OSHP.TRNSPNAME LIKE 'DDU%' THEN OPDN.DOCDATE
    END                                   AS DELIVERY_DATE,
    POR1.QUANTITY                         AS ORDER_QTY,
    PDN1.QUANTITY                         AS DELIVERED_QTY_LINE,
    OPOR.DOCCUR                           AS DOC_CURRENCY,
    POR1.PRICE                            AS UNIT_PRICE_FC,
    POR1.LINETOTAL                        AS LINE_VALUE_CHF
FROM {sap}.OPOR
INNER JOIN {sap}.POR1 ON POR1.DOCENTRY = OPOR.DOCENTRY
LEFT JOIN  {sap}.OSHP ON OSHP.TRNSPCODE = OPOR.TRNSPCODE
LEFT JOIN ({sap}.PDN1
           INNER JOIN {sap}.OPDN ON OPDN.DOCENTRY = PDN1.DOCENTRY
                                AND OPDN.CANCELED = 'N')
                      ON PDN1.BASEENTRY = POR1.DOCENTRY
                     AND PDN1.BASELINE  = POR1.LINENUM
                     AND PDN1.BASETYPE  = 22
LEFT JOIN  {sap}.OACT ON OACT.ACCTCODE = POR1.ACCTCODE
WHERE OPOR.CREATEDATE >= ?
  AND OPOR.CREATEDATE <  ?
  AND NOT (OPOR.DOCSTATUS = 'C' AND OPDN.DOCSTATUS IS NULL)
  AND (OPOR.U_ORDINE_QUADRO = 'N' OR OPOR.U_ORDINE_QUADRO IS NULL)
  AND OACT.FRGNNAME = 'Maintenance'
),
PO_LINES AS (
SELECT
    VENDOR_ID, VENDOR, PO_ENTRY, PURCHASE_ORDER, LINE_NO, ITEM_CODE, ITEM_DESCRIPTION,
    GL_ACCOUNT_CODE, GL_ACCOUNT_NAME, CREATE_DATE, SMB_DESIRED_DATE, ORDER_QTY, DOC_CURRENCY,
    SUM(DELIVERED_QTY_LINE) AS DELIVERED_QTY,
    MAX(DELIVERY_DATE)      AS DELIVERY_DATE,
    MAX(UNIT_PRICE_FC)      AS UNIT_PRICE_FC,
    MAX(LINE_VALUE_CHF)     AS VALUE_CHF
FROM RECEIPTS
GROUP BY VENDOR_ID, VENDOR, PO_ENTRY, PURCHASE_ORDER, LINE_NO, ITEM_CODE, ITEM_DESCRIPTION,
         GL_ACCOUNT_CODE, GL_ACCOUNT_NAME, CREATE_DATE, SMB_DESIRED_DATE, ORDER_QTY, DOC_CURRENCY
)
SELECT
    VENDOR_ID,
    VENDOR,
    PURCHASE_ORDER,
    LINE_NO,
    ITEM_CODE,
    ITEM_DESCRIPTION,
    GL_ACCOUNT_CODE,
    GL_ACCOUNT_NAME,
    CREATE_DATE,
    SMB_DESIRED_DATE,
    DELIVERY_DATE,
    ORDER_QTY,
    DELIVERED_QTY,
    DOC_CURRENCY,
    UNIT_PRICE_FC,
    CASE WHEN ORDER_QTY <> 0 THEN VALUE_CHF / ORDER_QTY END AS UNIT_PRICE_CHF,
    VALUE_CHF,
    CASE WHEN DELIVERY_DATE >= CREATE_DATE THEN DATEDIFF(DAY, CREATE_DATE, DELIVERY_DATE) END AS DAYS_CREATE_TO_DELIVERY,
    DATEDIFF(DAY, SMB_DESIRED_DATE, DELIVERY_DATE) AS DAYS_DESIRED_TO_DELIVERY
FROM PO_LINES
