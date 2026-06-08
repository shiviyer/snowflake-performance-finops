-- =============================================================================
-- Script: 01_warehouse_utilization.sql
-- Description: Analyze warehouse CPU, memory and load utilization
-- Source: SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_LOAD_HISTORY + WAREHOUSE_METERING_HISTORY
-- =============================================================================

-- -------------------------------------------------------
-- 1. Warehouse Load History - Hourly Average (Last 7 Days)
-- -------------------------------------------------------
SELECT
    warehouse_name,
    DATE_TRUNC('hour', start_time)                    AS hour_bucket,
    ROUND(AVG(avg_running), 2)                        AS avg_running_queries,
    ROUND(AVG(avg_queued_load), 2)                    AS avg_queued_load,
    ROUND(AVG(avg_queued_provisioning), 2)            AS avg_queued_provisioning,
    ROUND(AVG(avg_blocked), 2)                        AS avg_blocked_queries,
    MAX(avg_running)                                  AS peak_running_queries
FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_LOAD_HISTORY
WHERE start_time >= DATEADD('day', -7, CURRENT_TIMESTAMP)
GROUP BY 1, 2
ORDER BY 1, 2 DESC;


-- -------------------------------------------------------
-- 2. Warehouse Credit Consumption vs Load (Last 14 Days)
-- -------------------------------------------------------
SELECT
    m.warehouse_name,
    m.warehouse_size,
    DATE_TRUNC('day', m.start_time)                   AS day_bucket,
    ROUND(SUM(m.credits_used), 4)                     AS credits_used,
    ROUND(SUM(m.credits_used_compute), 4)             AS credits_compute,
    ROUND(SUM(m.credits_used_cloud_services), 4)      AS credits_cloud,
    ROUND(AVG(l.avg_running), 2)                      AS avg_running_queries,
    ROUND(AVG(l.avg_queued_load), 2)                  AS avg_queued,
    -- Efficiency: higher running/credit ratio = better utilization
    ROUND(AVG(l.avg_running) / NULLIF(SUM(m.credits_used), 0), 4) AS queries_per_credit
FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY m
LEFT JOIN SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_LOAD_HISTORY l
    ON m.warehouse_name = l.warehouse_name
    AND DATE_TRUNC('hour', m.start_time) = DATE_TRUNC('hour', l.start_time)
WHERE m.start_time >= DATEADD('day', -14, CURRENT_TIMESTAMP)
GROUP BY 1, 2, 3
ORDER BY 1, 3 DESC;


-- -------------------------------------------------------
-- 3. Peak Load Windows per Warehouse (Last 7 Days)
-- -------------------------------------------------------
SELECT
    warehouse_name,
    DATE_TRUNC('hour', start_time)                    AS peak_hour,
    ROUND(MAX(avg_running), 2)                        AS max_concurrent_queries,
    ROUND(MAX(avg_queued_load), 2)                    AS max_queue_depth,
    DAYNAME(start_time)                               AS day_of_week,
    HOUR(start_time)                                  AS hour_of_day
FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_LOAD_HISTORY
WHERE start_time >= DATEADD('day', -7, CURRENT_TIMESTAMP)
  AND avg_running > 0
GROUP BY 1, 2, 5, 6
ORDER BY 3 DESC
LIMIT 30;


-- -------------------------------------------------------
-- 4. Warehouse Idle Detection (Hours with 0 load but credits used)
-- -------------------------------------------------------
SELECT
    m.warehouse_name,
    DATE_TRUNC('hour', m.start_time)                  AS hour_bucket,
    ROUND(SUM(m.credits_used), 4)                     AS credits_used,
    COALESCE(AVG(l.avg_running), 0)                   AS avg_running_queries,
    COALESCE(AVG(l.avg_queued_load), 0)               AS avg_queued,
    CASE
        WHEN COALESCE(AVG(l.avg_running), 0) = 0 AND SUM(m.credits_used) > 0
             THEN 'IDLE (credits wasted)'
        WHEN COALESCE(AVG(l.avg_running), 0) < 0.5
             THEN 'UNDERUTILIZED'
        WHEN COALESCE(AVG(l.avg_queued_load), 0) > 1
             THEN 'OVERLOADED (queueing)'
        ELSE 'NORMAL'
    END AS utilization_status
FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY m
LEFT JOIN SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_LOAD_HISTORY l
    ON m.warehouse_name = l.warehouse_name
    AND DATE_TRUNC('hour', m.start_time) = DATE_TRUNC('hour', l.start_time)
WHERE m.start_time >= DATEADD('day', -7, CURRENT_TIMESTAMP)
GROUP BY 1, 2
HAVING credits_used > 0
ORDER BY utilization_status, credits_used DESC;


-- -------------------------------------------------------
-- 5. Warehouse Auto-Suspend Effectiveness
-- -------------------------------------------------------
SELECT
    warehouse_name,
    COUNT(DISTINCT DATE_TRUNC('hour', start_time))    AS hours_active,
    ROUND(SUM(credits_used), 2)                       AS total_credits,
    ROUND(SUM(credits_used_compute), 2)               AS compute_credits,
    ROUND(SUM(credits_used_cloud_services), 2)        AS cloud_service_credits,
    -- Cloud services > 10% of compute can incur extra charges
    ROUND(SUM(credits_used_cloud_services) * 100.0 /
          NULLIF(SUM(credits_used_compute), 0), 2)    AS cloud_pct_of_compute
FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
WHERE start_time >= DATEADD('day', -30, CURRENT_TIMESTAMP)
GROUP BY 1
ORDER BY total_credits DESC;
