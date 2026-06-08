-- =============================================================================
-- Script: 01_idle_warehouse_detection.sql
-- Description: Find idle and underutilized warehouses wasting credits
-- Source: SNOWFLAKE.ACCOUNT_USAGE
-- =============================================================================

-- -------------------------------------------------------
-- 1. Warehouses with High Idle Time (Credits Used but No Queries)
-- -------------------------------------------------------
WITH wh_credits AS (
    SELECT
        warehouse_name,
        DATE_TRUNC('hour', start_time)                    AS hour_bucket,
        SUM(credits_used)                                 AS credits_used
    FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
    WHERE start_time >= DATEADD('day', -30, CURRENT_TIMESTAMP)
    GROUP BY 1, 2
),
wh_queries AS (
    SELECT
        warehouse_name,
        DATE_TRUNC('hour', start_time)                    AS hour_bucket,
        COUNT(*)                                          AS query_count,
        SUM(total_elapsed_time)                           AS total_exec_ms
    FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
    WHERE start_time >= DATEADD('day', -30, CURRENT_TIMESTAMP)
      AND execution_status = 'SUCCESS'
    GROUP BY 1, 2
)
SELECT
    c.warehouse_name,
    COUNT(*)                                              AS total_hours_running,
    SUM(c.credits_used)                                   AS total_credits_consumed,
    SUM(CASE WHEN COALESCE(q.query_count, 0) = 0 THEN c.credits_used ELSE 0 END) AS idle_credits,
    SUM(CASE WHEN COALESCE(q.query_count, 0) = 0 THEN 1 ELSE 0 END)             AS idle_hours,
    ROUND(SUM(CASE WHEN COALESCE(q.query_count, 0) = 0 THEN c.credits_used ELSE 0 END)
          * 100.0 / NULLIF(SUM(c.credits_used), 0), 2)   AS idle_credit_pct,
    ROUND(SUM(CASE WHEN COALESCE(q.query_count, 0) = 0 THEN 1 ELSE 0 END)
          * 100.0 / COUNT(*), 2)                          AS idle_time_pct,
    -- Cost of idle time (adjust credit price)
    ROUND(SUM(CASE WHEN COALESCE(q.query_count, 0) = 0
              THEN c.credits_used ELSE 0 END) * 3.0, 2)  AS idle_cost_usd
FROM wh_credits c
LEFT JOIN wh_queries q
    ON c.warehouse_name = q.warehouse_name
    AND c.hour_bucket = q.hour_bucket
GROUP BY c.warehouse_name
HAVING total_credits_consumed > 1
ORDER BY idle_credits DESC;


-- -------------------------------------------------------
-- 2. Auto-Suspend Audit - Warehouses with Poor Auto-Suspend Config
-- -------------------------------------------------------
SHOW WAREHOUSES;

-- After running SHOW WAREHOUSES, check auto-suspend settings:
SELECT
    "name"                                              AS warehouse_name,
    "size"                                              AS size,
    "auto_suspend"                                      AS auto_suspend_seconds,
    "auto_resume"                                       AS auto_resume,
    "state"                                             AS current_state,
    CASE
        WHEN "auto_suspend" IS NULL OR "auto_suspend" = 0
             THEN 'CRITICAL: Auto-suspend disabled - cost leak risk'
        WHEN "auto_suspend" > 600 AND "name" ILIKE '%dev%'
             THEN 'WARNING: Dev warehouse auto-suspend > 10 min'
        WHEN "auto_suspend" > 600 AND "name" ILIKE '%test%'
             THEN 'WARNING: Test warehouse auto-suspend > 10 min'
        WHEN "auto_suspend" > 1800
             THEN 'WARNING: Auto-suspend > 30 min (high idle risk)'
        WHEN "auto_suspend" <= 60
             THEN 'OK: Aggressive auto-suspend (<= 60s)'
        ELSE 'OK'
    END AS auto_suspend_recommendation
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
WHERE "kind" = 'STANDARD'
ORDER BY "auto_suspend" DESC NULLS FIRST;


-- -------------------------------------------------------
-- 3. Warehouses Running Outside Business Hours
-- -------------------------------------------------------
WITH business_hours AS (
    -- Define business hours: Mon-Fri 8am-6pm UTC
    SELECT
        warehouse_name,
        DATE_TRUNC('hour', start_time)                    AS hour_bucket,
        SUM(credits_used)                                 AS credits_used,
        DAYOFWEEK(start_time)                             AS dow,  -- 0=Sun, 6=Sat
        HOUR(start_time)                                  AS hour_of_day
    FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
    WHERE start_time >= DATEADD('day', -30, CURRENT_TIMESTAMP)
    GROUP BY 1, 2, 4, 5
)
SELECT
    warehouse_name,
    ROUND(SUM(credits_used), 2)                           AS total_credits,
    ROUND(SUM(CASE WHEN dow BETWEEN 1 AND 5
                   AND hour_of_day BETWEEN 8 AND 17
              THEN credits_used ELSE 0 END), 2)           AS business_hours_credits,
    ROUND(SUM(CASE WHEN dow = 0 OR dow = 6
                   OR hour_of_day NOT BETWEEN 8 AND 17
              THEN credits_used ELSE 0 END), 2)           AS off_hours_credits,
    ROUND(SUM(CASE WHEN dow = 0 OR dow = 6
                   OR hour_of_day NOT BETWEEN 8 AND 17
              THEN credits_used ELSE 0 END) * 100.0 /
          NULLIF(SUM(credits_used), 0), 2)                AS off_hours_pct,
    ROUND(SUM(CASE WHEN dow = 0 OR dow = 6
                   OR hour_of_day NOT BETWEEN 8 AND 17
              THEN credits_used ELSE 0 END) * 3.0, 2)     AS off_hours_cost_usd
FROM business_hours
GROUP BY 1
HAVING off_hours_credits > 5
ORDER BY off_hours_credits DESC;


-- -------------------------------------------------------
-- 4. Credit Waste Opportunities (Summary)
-- -------------------------------------------------------
WITH idle_analysis AS (
    SELECT
        c.warehouse_name,
        SUM(CASE WHEN COALESCE(q.query_count, 0) = 0 THEN c.credits_used ELSE 0 END) AS idle_credits
    FROM (SELECT warehouse_name, DATE_TRUNC('hour', start_time) AS h,
                 SUM(credits_used) AS credits_used
          FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
          WHERE start_time >= DATEADD('day', -30, CURRENT_TIMESTAMP)
          GROUP BY 1, 2) c
    LEFT JOIN (SELECT warehouse_name, DATE_TRUNC('hour', start_time) AS h, COUNT(*) AS query_count
               FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
               WHERE start_time >= DATEADD('day', -30, CURRENT_TIMESTAMP)
               GROUP BY 1, 2) q
        ON c.warehouse_name = q.warehouse_name AND c.h = q.h
    GROUP BY 1
)
SELECT
    'TOTAL IDLE CREDITS (30 days)'                        AS metric,
    ROUND(SUM(idle_credits), 2)                           AS value,
    ROUND(SUM(idle_credits) * 3.0, 2)                     AS estimated_savings_usd
FROM idle_analysis
WHERE idle_credits > 0;
