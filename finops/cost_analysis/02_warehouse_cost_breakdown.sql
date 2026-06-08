-- =============================================================================
-- Script: 02_warehouse_cost_breakdown.sql
-- Description: Detailed cost breakdown per warehouse with efficiency metrics
-- Source: SNOWFLAKE.ACCOUNT_USAGE
-- =============================================================================

-- -------------------------------------------------------
-- 1. Warehouse Cost Summary (Last 30 Days)
-- -------------------------------------------------------
SELECT
    m.warehouse_name,
    m.warehouse_size,
    ROUND(SUM(m.credits_used), 2)                         AS total_credits,
    ROUND(SUM(m.credits_used_compute), 2)                 AS compute_credits,
    ROUND(SUM(m.credits_used_cloud_services), 2)          AS cloud_service_credits,
    -- Cost estimates at $3/credit (adjust for your contract)
    ROUND(SUM(m.credits_used) * 3.0, 2)                   AS estimated_cost_usd,
    -- Credit rate per hour for this warehouse size
    CASE m.warehouse_size
        WHEN 'X-Small' THEN 1
        WHEN 'Small' THEN 2
        WHEN 'Medium' THEN 4
        WHEN 'Large' THEN 8
        WHEN 'X-Large' THEN 16
        WHEN '2X-Large' THEN 32
        WHEN '3X-Large' THEN 64
        WHEN '4X-Large' THEN 128
        ELSE NULL
    END AS credits_per_hour,
    -- Active hours (how many billing hours)
    COUNT(DISTINCT DATE_TRUNC('hour', m.start_time))      AS active_hours,
    -- Queries executed
    COALESCE(q.total_queries, 0)                          AS total_queries,
    COALESCE(q.avg_elapsed_sec, 0)                        AS avg_elapsed_sec,
    COALESCE(q.cache_hit_rate, 0)                         AS cache_hit_rate,
    -- Efficiency: queries per credit (higher = more efficient)
    ROUND(COALESCE(q.total_queries, 0) / NULLIF(SUM(m.credits_used), 0), 2) AS queries_per_credit
FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY m
LEFT JOIN (
    SELECT
        warehouse_name,
        COUNT(*)                                          AS total_queries,
        ROUND(AVG(total_elapsed_time) / 1000, 2)         AS avg_elapsed_sec,
        ROUND(AVG(percentage_scanned_from_cache), 2)     AS cache_hit_rate
    FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
    WHERE start_time >= DATEADD('day', -30, CURRENT_TIMESTAMP)
      AND execution_status = 'SUCCESS'
    GROUP BY 1
) q ON m.warehouse_name = q.warehouse_name
WHERE m.start_time >= DATEADD('day', -30, CURRENT_TIMESTAMP)
GROUP BY 1, 2, q.total_queries, q.avg_elapsed_sec, q.cache_hit_rate
ORDER BY total_credits DESC;


-- -------------------------------------------------------
-- 2. Warehouse Cost vs Activity Correlation
-- -------------------------------------------------------
SELECT
    DATE_TRUNC('day', m.start_time)                       AS day,
    m.warehouse_name,
    ROUND(SUM(m.credits_used), 4)                         AS daily_credits,
    COUNT(q.query_id)                                     AS queries_run,
    ROUND(AVG(q.total_elapsed_time) / 1000, 2)           AS avg_elapsed_sec,
    -- Cost efficiency score
    ROUND(COUNT(q.query_id) / NULLIF(SUM(m.credits_used), 0), 2) AS efficiency_ratio
FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY m
LEFT JOIN SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY q
    ON m.warehouse_name = q.warehouse_name
    AND DATE_TRUNC('hour', m.start_time) = DATE_TRUNC('hour', q.start_time)
    AND q.execution_status = 'SUCCESS'
WHERE m.start_time >= DATEADD('day', -14, CURRENT_TIMESTAMP)
GROUP BY 1, 2
ORDER BY 1 DESC, 3 DESC;


-- -------------------------------------------------------
-- 3. Warehouses with Declining Efficiency (Cost Trending Up)
-- -------------------------------------------------------
WITH weekly_cost AS (
    SELECT
        warehouse_name,
        DATE_TRUNC('week', start_time)                    AS week,
        SUM(credits_used)                                 AS weekly_credits
    FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
    WHERE start_time >= DATEADD('week', -4, CURRENT_TIMESTAMP)
    GROUP BY 1, 2
)
SELECT
    warehouse_name,
    MAX(CASE WHEN week = DATE_TRUNC('week', CURRENT_TIMESTAMP) THEN weekly_credits END) AS current_week,
    MAX(CASE WHEN week = DATE_TRUNC('week', DATEADD('week', -1, CURRENT_TIMESTAMP)) THEN weekly_credits END) AS last_week,
    MAX(CASE WHEN week = DATE_TRUNC('week', DATEADD('week', -2, CURRENT_TIMESTAMP)) THEN weekly_credits END) AS two_weeks_ago,
    MAX(CASE WHEN week = DATE_TRUNC('week', DATEADD('week', -3, CURRENT_TIMESTAMP)) THEN weekly_credits END) AS three_weeks_ago,
    ROUND((MAX(CASE WHEN week = DATE_TRUNC('week', CURRENT_TIMESTAMP) THEN weekly_credits END) -
           MAX(CASE WHEN week = DATE_TRUNC('week', DATEADD('week', -1, CURRENT_TIMESTAMP)) THEN weekly_credits END))
          * 100.0 /
          NULLIF(MAX(CASE WHEN week = DATE_TRUNC('week', DATEADD('week', -1, CURRENT_TIMESTAMP)) THEN weekly_credits END), 0), 2) AS wow_change_pct
FROM weekly_cost
GROUP BY 1
HAVING current_week IS NOT NULL
ORDER BY wow_change_pct DESC NULLS LAST;


-- -------------------------------------------------------
-- 4. Cloud Services Credit Monitoring by Warehouse
-- -------------------------------------------------------
SELECT
    warehouse_name,
    DATE_TRUNC('day', start_time)                         AS day,
    ROUND(SUM(credits_used_compute), 4)                   AS compute_credits,
    ROUND(SUM(credits_used_cloud_services), 4)            AS cloud_credits,
    ROUND(SUM(credits_used_cloud_services) * 100.0 /
          NULLIF(SUM(credits_used_compute), 0), 2)        AS cloud_pct,
    CASE
        WHEN SUM(credits_used_cloud_services) >
             SUM(credits_used_compute) * 0.10
        THEN 'ALERT: Cloud services > 10% of compute (may incur charges)'
        ELSE 'OK'
    END AS alert
FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
WHERE start_time >= DATEADD('day', -30, CURRENT_TIMESTAMP)
GROUP BY 1, 2
HAVING cloud_pct > 5
ORDER BY cloud_pct DESC;
