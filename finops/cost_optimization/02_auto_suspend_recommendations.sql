-- =============================================================================
-- Script: 02_auto_suspend_recommendations.sql
-- Description: Analyze warehouse activity patterns to recommend optimal auto-suspend settings
-- Source: SNOWFLAKE.ACCOUNT_USAGE
-- =============================================================================

-- -------------------------------------------------------
-- 1. Warehouse Idle Time Analysis (Gap between queries)
--    Find typical idle periods to set auto-suspend appropriately
-- -------------------------------------------------------
WITH query_gaps AS (
    SELECT
        warehouse_name,
        start_time,
        LAG(end_time) OVER (PARTITION BY warehouse_name ORDER BY start_time) AS prev_end_time,
        DATEDIFF('second', LAG(end_time) OVER (PARTITION BY warehouse_name ORDER BY start_time),
                 start_time) AS gap_seconds
    FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
    WHERE start_time >= DATEADD('day', -14, CURRENT_TIMESTAMP)
      AND execution_status = 'SUCCESS'
      AND warehouse_name IS NOT NULL
)
SELECT
    warehouse_name,
    COUNT(*)                                               AS total_gaps,
    ROUND(AVG(gap_seconds), 0)                            AS avg_gap_sec,
    ROUND(PERCENTILE_CONT(0.50) WITHIN GROUP (ORDER BY gap_seconds), 0) AS median_gap_sec,
    ROUND(PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY gap_seconds), 0) AS p75_gap_sec,
    ROUND(PERCENTILE_CONT(0.90) WITHIN GROUP (ORDER BY gap_seconds), 0) AS p90_gap_sec,
    -- Count gaps by duration bucket
    SUM(CASE WHEN gap_seconds < 60 THEN 1 ELSE 0 END)    AS gaps_under_1min,
    SUM(CASE WHEN gap_seconds BETWEEN 60 AND 300 THEN 1 ELSE 0 END) AS gaps_1_5min,
    SUM(CASE WHEN gap_seconds BETWEEN 300 AND 900 THEN 1 ELSE 0 END) AS gaps_5_15min,
    SUM(CASE WHEN gap_seconds > 900 THEN 1 ELSE 0 END)   AS gaps_over_15min,
    -- Recommended auto-suspend based on gap patterns
    CASE
        WHEN PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY gap_seconds) < 60
             THEN 60  -- most gaps < 1min, suspend at 60s
        WHEN PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY gap_seconds) < 300
             THEN 120 -- most gaps < 5min, suspend at 2min
        WHEN PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY gap_seconds) < 600
             THEN 300 -- most gaps < 10min, suspend at 5min
        ELSE 600      -- larger gaps, suspend at 10min
    END AS recommended_auto_suspend_sec
FROM query_gaps
WHERE gap_seconds IS NOT NULL AND gap_seconds > 0
GROUP BY warehouse_name
ORDER BY avg_gap_sec DESC;


-- -------------------------------------------------------
-- 2. Credits Wasted by Insufficient Auto-Suspend Settings
-- -------------------------------------------------------
WITH inactive_periods AS (
    SELECT
        c.warehouse_name,
        c.hour_bucket,
        c.credits_used,
        COALESCE(q.query_count, 0)                        AS query_count,
        COALESCE(q.last_query_in_hour, c.hour_bucket)     AS last_query_in_hour
    FROM (
        SELECT warehouse_name, DATE_TRUNC('hour', start_time) AS hour_bucket,
               SUM(credits_used) AS credits_used
        FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
        WHERE start_time >= DATEADD('day', -14, CURRENT_TIMESTAMP)
        GROUP BY 1, 2
    ) c
    LEFT JOIN (
        SELECT warehouse_name, DATE_TRUNC('hour', start_time) AS hour_bucket,
               COUNT(*) AS query_count,
               MAX(end_time) AS last_query_in_hour
        FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
        WHERE start_time >= DATEADD('day', -14, CURRENT_TIMESTAMP)
        GROUP BY 1, 2
    ) q ON c.warehouse_name = q.warehouse_name AND c.hour_bucket = q.hour_bucket
)
SELECT
    warehouse_name,
    ROUND(SUM(credits_used), 2)                           AS total_credits_14d,
    ROUND(SUM(CASE WHEN query_count = 0 THEN credits_used ELSE 0 END), 2) AS idle_credits,
    ROUND(SUM(CASE WHEN query_count = 0 THEN credits_used ELSE 0 END)
          * 100.0 / SUM(credits_used), 2)                AS idle_credit_pct,
    ROUND(SUM(CASE WHEN query_count = 0 THEN credits_used ELSE 0 END) * 3.0, 2) AS idle_cost_usd
FROM inactive_periods
GROUP BY 1
HAVING idle_credits > 0
ORDER BY idle_credits DESC;


-- -------------------------------------------------------
-- 3. Recommended Auto-Suspend Settings per Warehouse
-- -------------------------------------------------------
-- Best practices:
-- Dev/Sandbox:  60 seconds (minimize cost, OK to restart cold)
-- Test:         60-120 seconds
-- Analytics:    120-300 seconds (balance cost vs cold start)
-- Production ETL: 300-600 seconds (frequent use, cold start = delay)
-- Production BI: 120-300 seconds (interactive, users expect fast)
-- Background:   60 seconds

SELECT
    warehouse_name,
    CASE
        WHEN LOWER(warehouse_name) LIKE '%dev%'
             OR LOWER(warehouse_name) LIKE '%sandbox%'
             THEN 'Recommended: 60 seconds (development)'
        WHEN LOWER(warehouse_name) LIKE '%test%'
             THEN 'Recommended: 60-120 seconds (testing)'
        WHEN LOWER(warehouse_name) LIKE '%prod%'
             AND LOWER(warehouse_name) LIKE '%etl%'
             THEN 'Recommended: 300-600 seconds (production ETL)'
        WHEN LOWER(warehouse_name) LIKE '%prod%'
             THEN 'Recommended: 120-300 seconds (production interactive)'
        WHEN LOWER(warehouse_name) LIKE '%analytics%'
             OR LOWER(warehouse_name) LIKE '%bi%'
             THEN 'Recommended: 120-300 seconds (analytics/BI)'
        ELSE 'Review: Check usage patterns, default to 120-300 seconds'
    END AS auto_suspend_recommendation,
    ROUND(SUM(credits_used), 2) AS total_credits_30d,
    COUNT(DISTINCT DATE_TRUNC('hour', start_time)) AS active_hours
FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
WHERE start_time >= DATEADD('day', -30, CURRENT_TIMESTAMP)
GROUP BY 1
ORDER BY total_credits_30d DESC;
