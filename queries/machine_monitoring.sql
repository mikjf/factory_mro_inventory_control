-- MACHINE MONITORING CORE KPIs - FY26

-- QUERY

SELECT
    RAG.WEEK_START_DATE,
    RAG.MACHINE_GROUP,
    --RAG.MACHINE,
    RAG.MACHINE_DESCRIPTION,
    RAG.DEPARTMENT,
    ISNULL(RAG.MAX_CAP_HOURS, RAG.MAX_CAP_HOURS_CONFIG) AS MAX_CAP,
    RAG.MAX_PLANNED_HOURS AS PLANNED,
    RAG.PLANNING_MASTER_RUN_HRS_ADJ AS MASTER_DONE,
    ISNULL(RAG.DOWNTIME_HOURS_GROUP_FINAL, 0) AS GROUP_DOWNTIME,
    RAG.MACHINE_LOAD,
    RAG.MASTER_UTILIZATION,
    RAG.UPTIME,
    CASE
        WHEN RAG.MACHINE_LOAD IS NOT NULL
         AND RAG.MASTER_UTILIZATION IS NOT NULL
         AND RAG.UPTIME IS NOT NULL
        THEN 'Tracked'
        ELSE 'Untracked'
    END AS RAG_DATA_STATUS
FROM (

SELECT
    *,

    CASE
        WHEN COALESCE(DOWNTIME_ADJUSTMENT_MACHINE,0) <> 0
          OR COALESCE(DOWNTIME_ADJUSTMENT_GROUP,0) <> 0
        THEN 'Y'
        ELSE 'N'
    END AS HAS_MANUAL_DOWNTIME_ADJUSTMENT,

    -- Planned clipped downtime (recommended helper KPI)
    CAST(
        CASE
            WHEN MAX_PLANNED_HOURS IS NULL OR MAX_PLANNED_HOURS = 0 THEN NULL
            WHEN DOWNTIME_HOURS_GROUP_FINAL > MAX_PLANNED_HOURS THEN MAX_PLANNED_HOURS
            ELSE DOWNTIME_HOURS_GROUP_FINAL
        END
    AS DECIMAL(10,2)) AS DOWNTIME_HOURS_GROUP_PLANNED,

    -- MACHINE_LOAD = Planned Available Time / Maximum Capacity Time
    CASE
        WHEN NULLIF(ISNULL(MAX_CAP_HOURS, MAX_CAP_HOURS_CONFIG), 0) IS NULL THEN NULL
        ELSE CAST(
                CAST(MAX_PLANNED_HOURS AS DECIMAL(10,2))
                / NULLIF(CAST(ISNULL(MAX_CAP_HOURS, MAX_CAP_HOURS_CONFIG) AS DECIMAL(10,2)), 0)
             AS DECIMAL(10,2))
    END AS MACHINE_LOAD,

    -- MASTER_UTILIZATION = (Standard Setup + Standard Run for Completed Jobs) / Planned Available Time
    CASE
        WHEN MAX_PLANNED_HOURS IS NULL OR MAX_PLANNED_HOURS = 0 THEN NULL
        ELSE CAST(
                PLANNING_MASTER_RUN_HRS_ADJ / MAX_PLANNED_HOURS
             AS DECIMAL(10,2))
    END AS MASTER_UTILIZATION,

    -- UPTIME (True Availability) = (Planned Available Time - Downtime) / Planned Available Time
    CASE
        WHEN MAX_PLANNED_HOURS IS NULL OR MAX_PLANNED_HOURS = 0 THEN NULL
        ELSE CAST(
                (MAX_PLANNED_HOURS -
                    CASE
                        WHEN DOWNTIME_HOURS_GROUP_FINAL > MAX_PLANNED_HOURS THEN MAX_PLANNED_HOURS
                        ELSE DOWNTIME_HOURS_GROUP_FINAL
                    END
                ) / MAX_PLANNED_HOURS
             AS DECIMAL(10,2))
    END AS UPTIME

FROM (

    SELECT
        X.*,

        CAST(X.DOWNTIME_HOURS       AS DECIMAL(10,2)) AS DOWNTIME_HOURS_ORIGINAL,
        CAST(X.DOWNTIME_HOURS_GROUP AS DECIMAL(10,2)) AS DOWNTIME_HOURS_GROUP_ORIGINAL,

        CAST(COALESCE(ADJ_MACHINE.HOURS_ADJUSTMENT,0) AS DECIMAL(10,2)) AS DOWNTIME_ADJUSTMENT_MACHINE,
        CAST(COALESCE(ADJ_GROUP.HOURS_ADJUSTMENT,0)   AS DECIMAL(10,2)) AS DOWNTIME_ADJUSTMENT_GROUP,

        CAST(
            CASE
                WHEN COALESCE(X.DOWNTIME_HOURS,0) + COALESCE(ADJ_MACHINE.HOURS_ADJUSTMENT,0) < 0 THEN 0
                ELSE COALESCE(X.DOWNTIME_HOURS,0) + COALESCE(ADJ_MACHINE.HOURS_ADJUSTMENT,0)
            END
        AS DECIMAL(10,2)) AS DOWNTIME_HOURS_FINAL,

        CAST(
            CASE
                WHEN COALESCE(X.DOWNTIME_HOURS_GROUP,0) + COALESCE(ADJ_GROUP.HOURS_ADJUSTMENT,0) < 0 THEN 0
                ELSE COALESCE(X.DOWNTIME_HOURS_GROUP,0) + COALESCE(ADJ_GROUP.HOURS_ADJUSTMENT,0)
            END
        AS DECIMAL(10,2)) AS DOWNTIME_HOURS_GROUP_FINAL,

        COALESCE(ADJ_MACHINE.ADJUSTMENT_DETAILS, 'No downtime adjustments') AS DOWNTIME_ADJUSTMENT_DETAILS_MACHINE

    FROM (

        ------------------------------------------------------------
        -- BASE: machines x weeks x planning x downtime
        ------------------------------------------------------------
        SELECT
            CASE
                WHEN M.PARENT_ID IS NULL AND (
                    SELECT COUNT(*) FROM Z_FACTORYAPP_MACHINEMONITORING_MACHINE C WHERE C.PARENT_ID = M.ROWID
                ) = 0 THEN '-'
                ELSE M.PRODUCTION_LINE
            END AS PRODUCTION_LINE,

            CASE WHEN M.PARENT_ID IS NULL THEN M.NUMBER ELSE MP.NUMBER END AS MACHINE_GROUP,
            M.NUMBER AS MACHINE,

            CASE
                WHEN M.PARENT_ID IS NULL AND (
                    SELECT COUNT(*) FROM Z_FACTORYAPP_MACHINEMONITORING_MACHINE C WHERE C.PARENT_ID = M.ROWID
                ) > 0 THEN 'Parent'
                WHEN M.PARENT_ID IS NULL THEN 'Standalone'
                ELSE 'Child'
            END AS MACHINE_ROLE,

            CASE WHEN M.IS_MASTER = 1 THEN 'Main' WHEN M.IS_MASTER = 0 THEN 'Sub' END AS TRACKER,

            WKS.week_start AS WEEK_START_DATE,
            M.SERIAL_NUMBER,
            M.MANUFACTURER,
            M.MODEL,
            M.DESCRIPTION AS MACHINE_DESCRIPTION,

            CASE WHEN M.DEPARTMENT = 'Tornitura' THEN 'Lathing' ELSE M.DEPARTMENT END AS DEPARTMENT,

            M.MAX_CAP_HOURS AS MAX_CAP_HOURS_CONFIG,
            P.MAX_CAP_HOURS AS MAX_CAP_HOURS,
            P.PLANNED_HOURS AS MAX_PLANNED_HOURS,
            M.STATUS,

            CAST(COALESCE(OPS.PLANNING_MASTER_RUN_HRS_ADJ, 0) AS DECIMAL(10,2)) AS PLANNING_MASTER_RUN_HRS_ADJ,
            COALESCE(MT.DOWNTIME_HOURS,       0) AS DOWNTIME_HOURS,
            COALESCE(MTG.DOWNTIME_HOURS_GROUP, 0) AS DOWNTIME_HOURS_GROUP

        FROM Z_FACTORYAPP_MACHINEMONITORING_MACHINE M

        LEFT JOIN Z_FACTORYAPP_MACHINEMONITORING_MACHINE MP
          ON MP.ROWID = M.PARENT_ID

        ------------------------------------------------------------
        -- WEEK SERIES: FY26 start through last completed week
        -- Tally table via VALUES; no CTE needed.
        -- '20251001' anchors FY26; DATEDIFF(WEEK,...) computes
        -- the Monday of that week dynamically.
        ------------------------------------------------------------
        CROSS JOIN (
            SELECT
                DATEADD(WEEK, n.n, fy.fy26_start) AS week_start,
                DATEADD(WEEK, n.n + 1, fy.fy26_start) AS week_end
            FROM (
                SELECT DATEADD(WEEK, DATEDIFF(WEEK, 0, '20251001'), 0) AS fy26_start
            ) fy
            CROSS JOIN (
                SELECT TOP 53 ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) - 1 AS n
                FROM (VALUES
                    (0),(0),(0),(0),(0),(0),(0),(0),(0),(0),
                    (0),(0),(0),(0),(0),(0),(0),(0),(0),(0),
                    (0),(0),(0),(0),(0),(0),(0),(0),(0),(0),
                    (0),(0),(0),(0),(0),(0),(0),(0),(0),(0),
                    (0),(0),(0),(0),(0),(0),(0),(0),(0),(0),
                    (0),(0),(0)
                ) v(x)
            ) n
            WHERE DATEADD(WEEK, n.n, fy.fy26_start) < DATEADD(WEEK, DATEDIFF(WEEK, 0, GETDATE()), 0)
        ) WKS

        ------------------------------------------------------------
        -- PLANNED HOURS: matched by ISO-equivalent Monday date
        ------------------------------------------------------------
        LEFT JOIN Z_FACTORYAPP_MACHINEMONITORING_WEEKLYPLANNEDHOURS P
          ON M.ROWID = P.MACHINE_ID
          AND DATEADD(DAY,
                - (DATEPART(WEEKDAY, DATEFROMPARTS(P.YEAR, 1, 4)) + 5) % 7 + ((P.WEEK - 1) * 7),
                DATEFROMPARTS(P.YEAR, 1, 4)
              ) = WKS.week_start

        ------------------------------------------------------------
        -- OPS: planning runtime + setup
        -- Grouped by machine + WEEK_NUMBER + WEEK_YEAR so a single
        -- scan covers all FY26 weeks; joined back by week date.
        ------------------------------------------------------------
        LEFT JOIN (
            SELECT
                PLR.CODE AS MACHINE,
                PLA.WEEK_NUMBER,
                PLA.WEEK_YEAR,
                SUM(
                    COALESCE(
                        CASE
                            WHEN PLA.QTY_ADJUSTMENT = 0 THEN O.RUN_HRS
                            ELSE (COALESCE(O.RUN_HRS,0) / NULLIF(O.CALC_END_QTY, 0))
                                 * (O.CALC_END_QTY - PLA.QTY_ADJUSTMENT)
                        END, 0
                    )
                ) + SUM(COALESCE(O.SETUP_HRS,0)) AS PLANNING_MASTER_RUN_HRS_ADJ
            FROM OPERATION O
            INNER JOIN WORK_ORDER WO
                ON WO.TYPE = O.WORKORDER_TYPE
                AND WO.BASE_ID = O.WORKORDER_BASE_ID
                AND WO.LOT_ID = O.WORKORDER_LOT_ID
                AND WO.SPLIT_ID = O.WORKORDER_SPLIT_ID
                AND WO.SUB_ID = O.WORKORDER_SUB_ID
            INNER JOIN Z_PLANNING PLA
                ON O.WORKORDER_BASE_ID = PLA.WORKORDER_BASE_ID
                AND O.SEQUENCE_NO = PLA.SEQUENCE_NO
            INNER JOIN Z_PLANNING_RESOURCE PLR
                ON PLA.RESOURCE_ROWID = PLR.ROWID
            WHERE O.WORKORDER_TYPE = 'W'
              AND (O.WORKORDER_BASE_ID LIKE '%OP%' OR O.WORKORDER_BASE_ID LIKE '%OR%')
              AND O.STATUS IN ('C', 'F', 'R', 'S/U')
              AND WO.SUB_ID = '0'
              AND WO.STATUS IN ('C', 'F', 'R')
              AND O.OPERATION_TYPE NOT IN ('S RILAVORAZIONE', 'S CONTR. RITOC.')
              AND PLA.WEEK_YEAR >= 2025   -- limit scan to FY26 onwards
            GROUP BY PLR.CODE, PLA.WEEK_NUMBER, PLA.WEEK_YEAR
        ) OPS
          ON M.NUMBER = OPS.MACHINE
          AND OPS.WEEK_NUMBER = DATEPART(WEEK, WKS.week_start)
          AND OPS.WEEK_YEAR   = DATEPART(YEAR, WKS.week_start)

        ------------------------------------------------------------
        -- MT: downtime per machine per week
        --
        -- Raw intervals (IS_DOWN + STARTED_DOWN) are resolved once
        -- via OUTER APPLY, then CROSS JOINed with the week series
        -- and clipped to [week_start, week_end) before summing.
        -- This avoids re-running the event resolution N times.
        ------------------------------------------------------------
        LEFT JOIN (
            SELECT
                raw_dt.MACHINE,
                WKS2.week_start,
                CAST(SUM(
                    DATEDIFF(MINUTE,
                        CASE WHEN raw_dt.interval_start > WKS2.week_start THEN raw_dt.interval_start ELSE WKS2.week_start END,
                        CASE WHEN raw_dt.interval_end   < WKS2.week_end   THEN raw_dt.interval_end   ELSE WKS2.week_end   END
                    )
                ) / 60.0 AS DECIMAL(10,2)) AS DOWNTIME_HOURS
            FROM (

                -- IS_DOWN intervals
                SELECT
                    I.CODE AS MACHINE,
                    TD.CREATE_DATE AS interval_start,
                    COALESCE(nx.next_event, GETDATE()) AS interval_end
                FROM Z_FACTORYAPP_MAINTENANCETICKET_TICKETDETAILS TD
                JOIN Z_FACTORYAPP_MAINTENANCETICKET_TICKETS T ON T.ROWID = TD.TICKET_ID
                JOIN Z_FACTORYAPP_MAINTENANCETICKET_ITEMS   I ON I.ROWID = T.ITEM_ID
                OUTER APPLY (
                    SELECT TOP 1 next_event FROM (
                        SELECT TD2.CREATE_DATE AS next_event
                        FROM Z_FACTORYAPP_MAINTENANCETICKET_TICKETDETAILS TD2
                        JOIN Z_FACTORYAPP_MAINTENANCETICKET_TICKETS  T2 ON T2.ROWID = TD2.TICKET_ID
                        JOIN Z_FACTORYAPP_MAINTENANCETICKET_ITEMS    I2 ON I2.ROWID = T2.ITEM_ID
                        WHERE I2.CODE = I.CODE AND TD2.CREATE_DATE > TD.CREATE_DATE
                        UNION ALL
                        SELECT T2.CREATE_DATE
                        FROM Z_FACTORYAPP_MAINTENANCETICKET_TICKETS T2
                        JOIN Z_FACTORYAPP_MAINTENANCETICKET_ITEMS   I2 ON I2.ROWID = T2.ITEM_ID
                        WHERE I2.CODE = I.CODE AND T2.STARTED_DOWN = 1 AND T2.CREATE_DATE > TD.CREATE_DATE
                    ) nxt ORDER BY next_event ASC
                ) nx
                WHERE TD.IS_DOWN = 1
                  AND TD.CREATE_DATE >= DATEADD(WEEK, DATEDIFF(WEEK, 0, '20251001'), 0)

                UNION ALL

                -- STARTED_DOWN synthetic intervals
                SELECT
                    I.CODE AS MACHINE,
                    T.CREATE_DATE AS interval_start,
                    COALESCE(fd.next_event, GETDATE()) AS interval_end
                FROM Z_FACTORYAPP_MAINTENANCETICKET_TICKETS T
                JOIN Z_FACTORYAPP_MAINTENANCETICKET_ITEMS   I ON I.ROWID = T.ITEM_ID
                OUTER APPLY (
                    SELECT TOP 1 next_event FROM (
                        SELECT TD2.CREATE_DATE AS next_event
                        FROM Z_FACTORYAPP_MAINTENANCETICKET_TICKETDETAILS TD2
                        JOIN Z_FACTORYAPP_MAINTENANCETICKET_TICKETS  T2 ON T2.ROWID = TD2.TICKET_ID
                        JOIN Z_FACTORYAPP_MAINTENANCETICKET_ITEMS    I2 ON I2.ROWID = T2.ITEM_ID
                        WHERE I2.CODE = I.CODE AND TD2.CREATE_DATE > T.CREATE_DATE
                        UNION ALL
                        SELECT T2.CREATE_DATE
                        FROM Z_FACTORYAPP_MAINTENANCETICKET_TICKETS T2
                        JOIN Z_FACTORYAPP_MAINTENANCETICKET_ITEMS   I2 ON I2.ROWID = T2.ITEM_ID
                        WHERE I2.CODE = I.CODE AND T2.STARTED_DOWN = 1 AND T2.CREATE_DATE > T.CREATE_DATE
                    ) nxt ORDER BY next_event ASC
                ) fd
                WHERE T.STARTED_DOWN = 1
                  AND T.CREATE_DATE >= DATEADD(WEEK, DATEDIFF(WEEK, 0, '20251001'), 0)

            ) raw_dt

            CROSS JOIN (
                SELECT
                    DATEADD(WEEK, n.n, fy.fy26_start) AS week_start,
                    DATEADD(WEEK, n.n + 1, fy.fy26_start) AS week_end
                FROM (SELECT DATEADD(WEEK, DATEDIFF(WEEK, 0, '20251001'), 0) AS fy26_start) fy
                CROSS JOIN (
                    SELECT TOP 53 ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) - 1 AS n
                    FROM (VALUES
                        (0),(0),(0),(0),(0),(0),(0),(0),(0),(0),
                        (0),(0),(0),(0),(0),(0),(0),(0),(0),(0),
                        (0),(0),(0),(0),(0),(0),(0),(0),(0),(0),
                        (0),(0),(0),(0),(0),(0),(0),(0),(0),(0),
                        (0),(0),(0),(0),(0),(0),(0),(0),(0),(0),
                        (0),(0),(0)
                    ) v(x)
                ) n
                WHERE DATEADD(WEEK, n.n, fy.fy26_start) < DATEADD(WEEK, DATEDIFF(WEEK, 0, GETDATE()), 0)
            ) WKS2

            WHERE raw_dt.interval_start < WKS2.week_end
              AND raw_dt.interval_end   > WKS2.week_start
            GROUP BY raw_dt.MACHINE, WKS2.week_start
        ) MT
          ON M.NUMBER = MT.MACHINE
          AND MT.week_start = WKS.week_start

        ------------------------------------------------------------
        -- MTG: downtime at machine-group level (overlap-merged) per week
        --
        -- Same raw interval approach as MT above.
        -- After clipping to each week, the running-max merge
        -- removes overlapping intervals across machines in the
        -- same group before summing.
        ------------------------------------------------------------
        LEFT JOIN (
            SELECT
                final_mtg.MACHINE_GROUP,
                final_mtg.week_start,
                CAST(SUM(DATEDIFF(MINUTE, final_mtg.start_ts, final_mtg.end_ts)) / 60.0 AS DECIMAL(10,2)) AS DOWNTIME_HOURS_GROUP
            FROM (
                SELECT
                    MACHINE_GROUP,
                    week_start,
                    grp,
                    MIN(clipped_start) AS start_ts,
                    MAX(clipped_end)   AS end_ts
                FROM (
                    SELECT
                        r2.*,
                        SUM(CASE WHEN is_new = 1 THEN 1 ELSE 0 END)
                        OVER (PARTITION BY MACHINE_GROUP, week_start ORDER BY clipped_start ROWS UNBOUNDED PRECEDING) AS grp
                    FROM (
                        SELECT
                            r1.*,
                            CASE
                                WHEN clipped_start > LAG(running_end) OVER (PARTITION BY MACHINE_GROUP, week_start ORDER BY clipped_start)
                                THEN 1 ELSE 0
                            END AS is_new
                        FROM (
                            SELECT
                                r0.*,
                                MAX(clipped_end) OVER (PARTITION BY MACHINE_GROUP, week_start ORDER BY clipped_start ROWS UNBOUNDED PRECEDING) AS running_end
                            FROM (
                                SELECT
                                    CASE WHEN M2.PARENT_ID IS NULL THEN M2.NUMBER ELSE MP2.NUMBER END AS MACHINE_GROUP,
                                    WKS3.week_start,
                                    CASE WHEN raw_dt.interval_start > WKS3.week_start THEN raw_dt.interval_start ELSE WKS3.week_start END AS clipped_start,
                                    CASE WHEN raw_dt.interval_end   < WKS3.week_end   THEN raw_dt.interval_end   ELSE WKS3.week_end   END AS clipped_end
                                FROM (

                                    -- IS_DOWN intervals
                                    SELECT
                                        I.CODE AS MACHINE,
                                        TD.CREATE_DATE AS interval_start,
                                        COALESCE(nx.next_event, GETDATE()) AS interval_end
                                    FROM Z_FACTORYAPP_MAINTENANCETICKET_TICKETDETAILS TD
                                    JOIN Z_FACTORYAPP_MAINTENANCETICKET_TICKETS T ON T.ROWID = TD.TICKET_ID
                                    JOIN Z_FACTORYAPP_MAINTENANCETICKET_ITEMS   I ON I.ROWID = T.ITEM_ID
                                    OUTER APPLY (
                                        SELECT TOP 1 next_event FROM (
                                            SELECT TD2.CREATE_DATE AS next_event
                                            FROM Z_FACTORYAPP_MAINTENANCETICKET_TICKETDETAILS TD2
                                            JOIN Z_FACTORYAPP_MAINTENANCETICKET_TICKETS  T2 ON T2.ROWID = TD2.TICKET_ID
                                            JOIN Z_FACTORYAPP_MAINTENANCETICKET_ITEMS    I2 ON I2.ROWID = T2.ITEM_ID
                                            WHERE I2.CODE = I.CODE AND TD2.CREATE_DATE > TD.CREATE_DATE
                                            UNION ALL
                                            SELECT T2.CREATE_DATE
                                            FROM Z_FACTORYAPP_MAINTENANCETICKET_TICKETS T2
                                            JOIN Z_FACTORYAPP_MAINTENANCETICKET_ITEMS   I2 ON I2.ROWID = T2.ITEM_ID
                                            WHERE I2.CODE = I.CODE AND T2.STARTED_DOWN = 1 AND T2.CREATE_DATE > TD.CREATE_DATE
                                        ) nxt ORDER BY next_event ASC
                                    ) nx
                                    WHERE TD.IS_DOWN = 1
                                      AND TD.CREATE_DATE >= DATEADD(WEEK, DATEDIFF(WEEK, 0, '20251001'), 0)

                                    UNION ALL

                                    -- STARTED_DOWN synthetic intervals
                                    SELECT
                                        I.CODE AS MACHINE,
                                        T.CREATE_DATE AS interval_start,
                                        COALESCE(fd.next_event, GETDATE()) AS interval_end
                                    FROM Z_FACTORYAPP_MAINTENANCETICKET_TICKETS T
                                    JOIN Z_FACTORYAPP_MAINTENANCETICKET_ITEMS   I ON I.ROWID = T.ITEM_ID
                                    OUTER APPLY (
                                        SELECT TOP 1 next_event FROM (
                                            SELECT TD2.CREATE_DATE AS next_event
                                            FROM Z_FACTORYAPP_MAINTENANCETICKET_TICKETDETAILS TD2
                                            JOIN Z_FACTORYAPP_MAINTENANCETICKET_TICKETS  T2 ON T2.ROWID = TD2.TICKET_ID
                                            JOIN Z_FACTORYAPP_MAINTENANCETICKET_ITEMS    I2 ON I2.ROWID = T2.ITEM_ID
                                            WHERE I2.CODE = I.CODE AND TD2.CREATE_DATE > T.CREATE_DATE
                                            UNION ALL
                                            SELECT T2.CREATE_DATE
                                            FROM Z_FACTORYAPP_MAINTENANCETICKET_TICKETS T2
                                            JOIN Z_FACTORYAPP_MAINTENANCETICKET_ITEMS   I2 ON I2.ROWID = T2.ITEM_ID
                                            WHERE I2.CODE = I.CODE AND T2.STARTED_DOWN = 1 AND T2.CREATE_DATE > T.CREATE_DATE
                                        ) nxt ORDER BY next_event ASC
                                    ) fd
                                    WHERE T.STARTED_DOWN = 1
                                      AND T.CREATE_DATE >= DATEADD(WEEK, DATEDIFF(WEEK, 0, '20251001'), 0)

                                ) raw_dt
                                JOIN Z_FACTORYAPP_MACHINEMONITORING_MACHINE M2  ON M2.NUMBER = raw_dt.MACHINE
                                LEFT JOIN Z_FACTORYAPP_MACHINEMONITORING_MACHINE MP2 ON MP2.ROWID = M2.PARENT_ID
                                CROSS JOIN (
                                    SELECT
                                        DATEADD(WEEK, n.n, fy.fy26_start) AS week_start,
                                        DATEADD(WEEK, n.n + 1, fy.fy26_start) AS week_end
                                    FROM (SELECT DATEADD(WEEK, DATEDIFF(WEEK, 0, '20251001'), 0) AS fy26_start) fy
                                    CROSS JOIN (
                                        SELECT TOP 53 ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) - 1 AS n
                                        FROM (VALUES
                                            (0),(0),(0),(0),(0),(0),(0),(0),(0),(0),
                                            (0),(0),(0),(0),(0),(0),(0),(0),(0),(0),
                                            (0),(0),(0),(0),(0),(0),(0),(0),(0),(0),
                                            (0),(0),(0),(0),(0),(0),(0),(0),(0),(0),
                                            (0),(0),(0),(0),(0),(0),(0),(0),(0),(0),
                                            (0),(0),(0)
                                        ) v(x)
                                    ) n
                                    WHERE DATEADD(WEEK, n.n, fy.fy26_start) < DATEADD(WEEK, DATEDIFF(WEEK, 0, GETDATE()), 0)
                                ) WKS3
                                WHERE raw_dt.interval_start < WKS3.week_end
                                  AND raw_dt.interval_end   > WKS3.week_start
                            ) r0
                            WHERE r0.clipped_start < r0.clipped_end
                        ) r1
                    ) r2
                ) grouped
                GROUP BY MACHINE_GROUP, week_start, grp
            ) final_mtg
            GROUP BY final_mtg.MACHINE_GROUP, final_mtg.week_start
        ) MTG
          ON MTG.MACHINE_GROUP = CASE WHEN M.PARENT_ID IS NULL THEN M.NUMBER ELSE MP.NUMBER END
          AND MTG.week_start = WKS.week_start

    ) AS X

    ------------------------------------------------------------
    -- ADJ_MACHINE: manual adjustments grouped by machine + week
    -- Week is derived from the Monday of the adjustment date.
    ------------------------------------------------------------
    LEFT JOIN (
        SELECT
            I.CODE AS MACHINE,
            DATEADD(WEEK, DATEDIFF(WEEK, 0, DA.DATE), 0) AS week_start,
            SUM(DA.HOURS_ADJUSTMENT) AS HOURS_ADJUSTMENT,
            STUFF((
                SELECT CHAR(10) +
                    '||| Date: ' + CONVERT(VARCHAR(10), DA2.DATE, 120) +
                    ' | Reason: ' + DA2.REASON +
                    ' | Hours Adj: ' + CAST(DA2.HOURS_ADJUSTMENT AS VARCHAR) +
                    ' |||'
                FROM Z_FACTORYAPP_MAINTENANCETICKET_DOWNTIMEADJUSTMENT DA2
                INNER JOIN Z_FACTORYAPP_MAINTENANCETICKET_TICKETS T2 ON T2.ROWID = DA2.TICKET_ID
                INNER JOIN Z_FACTORYAPP_MAINTENANCETICKET_ITEMS   I2 ON I2.ROWID = T2.ITEM_ID
                WHERE I2.CODE = I.CODE
                  AND DATEADD(WEEK, DATEDIFF(WEEK, 0, DA2.DATE), 0)
                    = DATEADD(WEEK, DATEDIFF(WEEK, 0, DA.DATE), 0)
                FOR XML PATH(''), TYPE
            ).value('.', 'VARCHAR(MAX)'), 1, 1, '') AS ADJUSTMENT_DETAILS
        FROM Z_FACTORYAPP_MAINTENANCETICKET_DOWNTIMEADJUSTMENT DA
        INNER JOIN Z_FACTORYAPP_MAINTENANCETICKET_TICKETS T ON T.ROWID = DA.TICKET_ID
        INNER JOIN Z_FACTORYAPP_MAINTENANCETICKET_ITEMS   I ON I.ROWID = T.ITEM_ID
        WHERE DA.DATE >= DATEADD(WEEK, DATEDIFF(WEEK, 0, '20251001'), 0)
          AND DA.DATE <  DATEADD(WEEK, DATEDIFF(WEEK, 0, GETDATE()), 0)
        GROUP BY I.CODE, DATEADD(WEEK, DATEDIFF(WEEK, 0, DA.DATE), 0)
    ) ADJ_MACHINE
      ON ADJ_MACHINE.MACHINE    = X.MACHINE
      AND ADJ_MACHINE.week_start = X.WEEK_START_DATE

    ------------------------------------------------------------
    -- ADJ_GROUP: manual adjustments grouped by machine group + week
    ------------------------------------------------------------
    LEFT JOIN (
        SELECT
            CASE WHEN M.PARENT_ID IS NULL THEN M.NUMBER ELSE MP.NUMBER END AS MACHINE_GROUP,
            DATEADD(WEEK, DATEDIFF(WEEK, 0, DA.DATE), 0) AS week_start,
            SUM(DA.HOURS_ADJUSTMENT) AS HOURS_ADJUSTMENT
        FROM Z_FACTORYAPP_MAINTENANCETICKET_DOWNTIMEADJUSTMENT DA
        INNER JOIN Z_FACTORYAPP_MAINTENANCETICKET_TICKETS T ON T.ROWID = DA.TICKET_ID
        INNER JOIN Z_FACTORYAPP_MAINTENANCETICKET_ITEMS   I ON I.ROWID = T.ITEM_ID
        INNER JOIN Z_FACTORYAPP_MACHINEMONITORING_MACHINE M  ON M.NUMBER = I.CODE
        LEFT JOIN  Z_FACTORYAPP_MACHINEMONITORING_MACHINE MP ON MP.ROWID = M.PARENT_ID
        WHERE DA.DATE >= DATEADD(WEEK, DATEDIFF(WEEK, 0, '20251001'), 0)
          AND DA.DATE <  DATEADD(WEEK, DATEDIFF(WEEK, 0, GETDATE()), 0)
        GROUP BY
            CASE WHEN M.PARENT_ID IS NULL THEN M.NUMBER ELSE MP.NUMBER END,
            DATEADD(WEEK, DATEDIFF(WEEK, 0, DA.DATE), 0)
    ) ADJ_GROUP
      ON ADJ_GROUP.MACHINE_GROUP = X.MACHINE_GROUP
      AND ADJ_GROUP.week_start   = X.WEEK_START_DATE

) AS Y

) AS RAG

WHERE RAG.MACHINE_LOAD IS NOT NULL
  AND RAG.MASTER_UTILIZATION IS NOT NULL
  AND RAG.UPTIME IS NOT NULL
ORDER BY WEEK_START_DATE ASC, MACHINE_GROUP ASC, MACHINE ASC