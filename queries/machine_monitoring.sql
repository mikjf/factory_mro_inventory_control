-- MACHINE MONITORING CORE KPIs - FISCAL YEAR (WEEKLY DETAIL, ONE ROW PER MACHINE GROUP AND WEEK)

-- PURPOSE
--   Weekly detail behind the yearly per machine group query. Same scope, same logic: summing this output
--   per machine group reproduces the yearly totals exactly.
--   Same FY convention: 1 Oct to 30 Sep, Monday weeks assigned to the FY of their Thursday.

-- HOW TO CHANGE THE FISCAL YEAR
--   Find and replace   2026 /*FY*/   (3 occurrences) with the FY you want, e.g.  2027 /*FY*/
--   Only completed weeks are included (current week excluded).

-- WEEKS IN SCOPE (per machine group)
--   From the first week with planned hours > 0 in WEEKLYPLANNEDHOURS (all history) to the last completed week of the FY.
--   Weeks with 0 planned hours (or no planning row) are returned as unused weeks (UNUSED_WEEK = 'Y').
--   Weeks before the first active week are not returned.
--   Machine groups with no planned week at all in the FY are not returned.
--   Planning rows can sit on the group head or on a child machine, so per group and week the machine with
--   the most planned hours is used (MACHINE column). Description and department are those of the group head.

-- COLUMNS
--   MAX_CAP: planning row capacity; if the week has no planning row, the machine's configured capacity (NO_PLAN_ROW = 1)
--   MASTER_DONE: summed per machine group (jobs can be scheduled on the head or on a child machine)
--   GROUP_DOWNTIME: overlap-merged group downtime plus manual adjustments (floored at 0)
--   GROUP_DOWNTIME_CLIPPED: GROUP_DOWNTIME capped at the week's PLANNED hours (used for UPTIME)
--   MACHINE_LOAD       = PLANNED / MAX_CAP
--   MASTER_UTILIZATION = MASTER_DONE / PLANNED (empty in unused weeks)
--   UPTIME             = (PLANNED - GROUP_DOWNTIME_CLIPPED) / PLANNED (empty in unused weeks)
--   RAG_DATA_STATUS    = 'Tracked' when the three KPIs are all available, otherwise 'Untracked'

-- QUERY

SELECT
    C.FISCAL_YEAR,
    C.WEEK_START_DATE,
    C.MACHINE_GROUP,
    C.MACHINE,
    C.MACHINE_DESCRIPTION,
    C.DEPARTMENT,
    C.FIRST_ACTIVE_WEEK,
    C.MAX_CAP,
    C.PLANNED,
    C.MASTER_DONE,
    C.GROUP_DOWNTIME,
    CASE WHEN C.GROUP_DOWNTIME > C.PLANNED THEN C.PLANNED ELSE C.GROUP_DOWNTIME END AS GROUP_DOWNTIME_CLIPPED,
    CASE
        WHEN NULLIF(C.MAX_CAP, 0) IS NULL THEN NULL
        ELSE CAST(CAST(C.PLANNED AS DECIMAL(10,2)) / NULLIF(CAST(C.MAX_CAP AS DECIMAL(10,2)), 0) AS DECIMAL(10,2))
    END AS MACHINE_LOAD,
    CASE
        WHEN C.PLANNED = 0 THEN NULL
        ELSE CAST(C.MASTER_DONE / C.PLANNED AS DECIMAL(10,2))
    END AS MASTER_UTILIZATION,
    CASE
        WHEN C.PLANNED = 0 THEN NULL
        ELSE CAST((C.PLANNED - CASE WHEN C.GROUP_DOWNTIME > C.PLANNED THEN C.PLANNED ELSE C.GROUP_DOWNTIME END) / C.PLANNED AS DECIMAL(10,2))
    END AS UPTIME,
    CASE
        WHEN C.PLANNED > 0 AND NULLIF(C.MAX_CAP, 0) IS NOT NULL THEN 'Tracked'
        ELSE 'Untracked'
    END AS RAG_DATA_STATUS,
    CASE WHEN C.PLANNED = 0 THEN 'Y' ELSE 'N' END AS UNUSED_WEEK,
    C.NO_PLAN_ROW
FROM (

    SELECT
        A.*,
        SUM(CASE WHEN A.PLANNED > 0 THEN 1 ELSE 0 END) OVER (PARTITION BY A.MACHINE_GROUP) AS WEEKS_PLANNED_FY
    FROM (

    ------------------------------------------------------------
    -- WEEKLY BASE: machines of each group x weeks in scope, one row kept per group and week
    ------------------------------------------------------------
    SELECT
        B.*,
        ROW_NUMBER() OVER (
            PARTITION BY B.MACHINE_GROUP, B.WEEK_START_DATE
            ORDER BY B.PLANNED DESC, B.NO_PLAN_ROW ASC, B.IS_CHILD ASC, B.MACHINE ASC
        ) AS RN
    FROM (

    SELECT
        WKS.fiscal_year AS FISCAL_YEAR,
        WKS.week_start AS WEEK_START_DATE,
        CASE WHEN M.PARENT_ID IS NULL THEN M.NUMBER ELSE MP.NUMBER END AS MACHINE_GROUP,
        M.NUMBER AS MACHINE,
        CASE WHEN M.PARENT_ID IS NULL THEN 0 ELSE 1 END AS IS_CHILD,
        COALESCE(MP.DESCRIPTION, M.DESCRIPTION) AS MACHINE_DESCRIPTION,
        CASE WHEN COALESCE(MP.DEPARTMENT, M.DEPARTMENT) = 'Tornitura' THEN 'Lathing' ELSE COALESCE(MP.DEPARTMENT, M.DEPARTMENT) END AS DEPARTMENT,
        F.first_week AS FIRST_ACTIVE_WEEK,
        CASE WHEN P.MACHINE_ID IS NULL THEN 1 ELSE 0 END AS NO_PLAN_ROW,
        ISNULL(P.MAX_CAP_HOURS, M.MAX_CAP_HOURS) AS MAX_CAP,
        COALESCE(P.PLANNED_HOURS, 0) AS PLANNED,
        CAST(COALESCE(OPS.PLANNING_MASTER_RUN_HRS_ADJ, 0) AS DECIMAL(10,2)) AS MASTER_DONE,
        CAST(
            CASE
                WHEN COALESCE(MTG.DOWNTIME_HOURS_GROUP, 0) + COALESCE(ADJ_GROUP.HOURS_ADJUSTMENT, 0) < 0 THEN 0
                ELSE COALESCE(MTG.DOWNTIME_HOURS_GROUP, 0) + COALESCE(ADJ_GROUP.HOURS_ADJUSTMENT, 0)
            END
        AS DECIMAL(10,2)) AS GROUP_DOWNTIME

    FROM Z_FACTORYAPP_MACHINEMONITORING_MACHINE M

    LEFT JOIN Z_FACTORYAPP_MACHINEMONITORING_MACHINE MP
      ON MP.ROWID = M.PARENT_ID

    ------------------------------------------------------------
    -- FIRST ACTIVE WEEK per machine group: first Monday with planned hours > 0 (all history)
    ------------------------------------------------------------
    INNER JOIN (
        SELECT
            CASE WHEN M0.PARENT_ID IS NULL THEN M0.NUMBER ELSE MP0.NUMBER END AS MACHINE_GROUP,
            MIN(DATEADD(DAY,
                - (DATEPART(WEEKDAY, DATEFROMPARTS(P0.YEAR, 1, 4)) + 5) % 7 + ((P0.WEEK - 1) * 7),
                DATEFROMPARTS(P0.YEAR, 1, 4)
            )) AS first_week
        FROM Z_FACTORYAPP_MACHINEMONITORING_WEEKLYPLANNEDHOURS P0
        INNER JOIN Z_FACTORYAPP_MACHINEMONITORING_MACHINE M0 ON M0.ROWID = P0.MACHINE_ID
        LEFT JOIN Z_FACTORYAPP_MACHINEMONITORING_MACHINE MP0 ON MP0.ROWID = M0.PARENT_ID
        WHERE P0.PLANNED_HOURS > 0
        GROUP BY CASE WHEN M0.PARENT_ID IS NULL THEN M0.NUMBER ELSE MP0.NUMBER END
    ) F
      ON F.MACHINE_GROUP = CASE WHEN M.PARENT_ID IS NULL THEN M.NUMBER ELSE MP.NUMBER END

    ------------------------------------------------------------
    -- WEEK SERIES: completed weeks of the selected FY
    -- Monday-start weeks, FY = year of the week's Thursday (1 Oct rule)
    ------------------------------------------------------------
    CROSS JOIN (
        SELECT
            s.fiscal_year,
            CAST(DATEADD(WEEK, n.n, s.fy_start) AS datetime) AS week_start,
            CAST(DATEADD(WEEK, n.n + 1, s.fy_start) AS datetime) AS week_end
        FROM (
            SELECT
                p.fiscal_year,
                DATEADD(DAY, (7 - DATEDIFF(DAY, '19000101', d.d0) % 7) % 7, d.d0) AS fy_start,
                DATEADD(DAY, (7 - DATEDIFF(DAY, '19000101', d.d1) % 7) % 7, d.d1) AS fy_next
            FROM (SELECT 2026 /*FY*/ AS fiscal_year) p
            CROSS APPLY (
                SELECT DATEFROMPARTS(p.fiscal_year - 1, 9, 28) AS d0,
                       DATEFROMPARTS(p.fiscal_year, 9, 28) AS d1
            ) d
        ) s
        CROSS JOIN (
            SELECT TOP 53 ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) - 1 AS n
            FROM (VALUES (0),(0),(0),(0),(0),(0),(0),(0)) a(x)
            CROSS JOIN (VALUES (0),(0),(0),(0),(0),(0),(0),(0)) b(x)
        ) n
        CROSS APPLY (
            SELECT DATEADD(DAY, -(DATEDIFF(DAY, '19000101', CAST(GETDATE() AS date)) % 7), CAST(GETDATE() AS date)) AS this_monday
        ) cm
        WHERE DATEADD(WEEK, n.n, s.fy_start) < s.fy_next
          AND DATEADD(WEEK, n.n, s.fy_start) < cm.this_monday
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
    -- OPS: planning runtime + setup, per machine group and ISO week
    -- (jobs can be scheduled on the head or on a child machine, so hours are summed per group)
    ------------------------------------------------------------
    LEFT JOIN (
        SELECT
            CASE WHEN OM.PARENT_ID IS NULL THEN OM.NUMBER ELSE OMP.NUMBER END AS MACHINE_GROUP,
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
        INNER JOIN Z_FACTORYAPP_MACHINEMONITORING_MACHINE OM
            ON OM.NUMBER = PLR.CODE
        LEFT JOIN Z_FACTORYAPP_MACHINEMONITORING_MACHINE OMP
            ON OMP.ROWID = OM.PARENT_ID
        WHERE O.WORKORDER_TYPE = 'W'
          AND (O.WORKORDER_BASE_ID LIKE '%OP%' OR O.WORKORDER_BASE_ID LIKE '%OR%')
          AND O.STATUS IN ('C', 'F', 'R', 'S/U')
          AND WO.SUB_ID = '0'
          AND WO.STATUS IN ('C', 'F', 'R')
          AND O.OPERATION_TYPE NOT IN ('S RILAVORAZIONE', 'S CONTR. RITOC.')
          AND PLA.WEEK_YEAR >= 2026 /*FY*/ - 1
        GROUP BY CASE WHEN OM.PARENT_ID IS NULL THEN OM.NUMBER ELSE OMP.NUMBER END, PLA.WEEK_NUMBER, PLA.WEEK_YEAR
    ) OPS
      ON OPS.MACHINE_GROUP = CASE WHEN M.PARENT_ID IS NULL THEN M.NUMBER ELSE MP.NUMBER END
      AND OPS.WEEK_NUMBER = DATEPART(ISO_WEEK, WKS.week_start)
      AND OPS.WEEK_YEAR   = YEAR(DATEADD(DAY, 3, WKS.week_start))

    ------------------------------------------------------------
    -- MTG: downtime per machine group and week (overlap-merged)
    --
    -- Raw intervals (IS_DOWN + STARTED_DOWN) are resolved once,
    -- clipped to each week, then merged per group with a
    -- running-max so overlapping machines are not double counted.
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

                            ) raw_dt
                            JOIN Z_FACTORYAPP_MACHINEMONITORING_MACHINE M2  ON M2.NUMBER = raw_dt.MACHINE
                            LEFT JOIN Z_FACTORYAPP_MACHINEMONITORING_MACHINE MP2 ON MP2.ROWID = M2.PARENT_ID
                            CROSS JOIN (
                                SELECT
                                    CAST(DATEADD(WEEK, n.n, s.fy_start) AS datetime) AS week_start,
                                    CAST(DATEADD(WEEK, n.n + 1, s.fy_start) AS datetime) AS week_end
                                FROM (
                                    SELECT
                                        DATEADD(DAY, (7 - DATEDIFF(DAY, '19000101', d.d0) % 7) % 7, d.d0) AS fy_start,
                                        DATEADD(DAY, (7 - DATEDIFF(DAY, '19000101', d.d1) % 7) % 7, d.d1) AS fy_next
                                    FROM (SELECT 2026 /*FY*/ AS fiscal_year) p
                                    CROSS APPLY (
                                        SELECT DATEFROMPARTS(p.fiscal_year - 1, 9, 28) AS d0,
                                               DATEFROMPARTS(p.fiscal_year, 9, 28) AS d1
                                    ) d
                                ) s
                                CROSS JOIN (
                                    SELECT TOP 53 ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) - 1 AS n
                                    FROM (VALUES (0),(0),(0),(0),(0),(0),(0),(0)) a(x)
                                    CROSS JOIN (VALUES (0),(0),(0),(0),(0),(0),(0),(0)) b(x)
                                ) n
                                CROSS APPLY (
                                    SELECT DATEADD(DAY, -(DATEDIFF(DAY, '19000101', CAST(GETDATE() AS date)) % 7), CAST(GETDATE() AS date)) AS this_monday
                                ) cm
                                WHERE DATEADD(WEEK, n.n, s.fy_start) < s.fy_next
                                  AND DATEADD(WEEK, n.n, s.fy_start) < cm.this_monday
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

    ------------------------------------------------------------
    -- ADJ_GROUP: manual adjustments per machine group and week
    -- Week = Monday on or before the adjustment date (Sunday goes
    -- to the previous week, as in the official query).
    ------------------------------------------------------------
    LEFT JOIN (
        SELECT
            CASE WHEN AM.PARENT_ID IS NULL THEN AM.NUMBER ELSE AMP.NUMBER END AS MACHINE_GROUP,
            DATEADD(DAY, -(DATEDIFF(DAY, '19000101', CAST(DA.DATE AS date)) % 7), CAST(DA.DATE AS date)) AS week_start,
            SUM(DA.HOURS_ADJUSTMENT) AS HOURS_ADJUSTMENT
        FROM Z_FACTORYAPP_MAINTENANCETICKET_DOWNTIMEADJUSTMENT DA
        INNER JOIN Z_FACTORYAPP_MAINTENANCETICKET_TICKETS T ON T.ROWID = DA.TICKET_ID
        INNER JOIN Z_FACTORYAPP_MAINTENANCETICKET_ITEMS   I ON I.ROWID = T.ITEM_ID
        INNER JOIN Z_FACTORYAPP_MACHINEMONITORING_MACHINE AM  ON AM.NUMBER = I.CODE
        LEFT JOIN  Z_FACTORYAPP_MACHINEMONITORING_MACHINE AMP ON AMP.ROWID = AM.PARENT_ID
        GROUP BY
            CASE WHEN AM.PARENT_ID IS NULL THEN AM.NUMBER ELSE AMP.NUMBER END,
            DATEADD(DAY, -(DATEDIFF(DAY, '19000101', CAST(DA.DATE AS date)) % 7), CAST(DA.DATE AS date))
    ) ADJ_GROUP
      ON ADJ_GROUP.MACHINE_GROUP = CASE WHEN M.PARENT_ID IS NULL THEN M.NUMBER ELSE MP.NUMBER END
      AND ADJ_GROUP.week_start   = WKS.week_start

    WHERE WKS.week_start >= F.first_week

    ) B

    ) A
    WHERE A.RN = 1

) C
WHERE C.WEEKS_PLANNED_FY > 0
ORDER BY C.WEEK_START_DATE ASC, C.MACHINE_GROUP ASC
