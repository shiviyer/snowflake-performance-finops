-- =============================================================================
-- Script: 03_sla_monitoring.sql
-- Description: Monitor query SLA compliance and track violations
-- Source: SNOWFLAKE.ACCOUNT_USAGE
-- =============================================================================

-- -------------------------------------------------------
-- 1. SLA Compliance by Warehouse and Query Type (Last 7 Days)
-- Adjust thresholds to match your SLA agreements
-- -------------------------------------------------------
SELECT
    warehouse_name,
    query_type,
    COUNT(*)                                              AS total_queries,
    -- SLA tiers (customize these thresholds)
    ROUND(SUM(CASE WHEN total_elapsed_time <= 5000   THEN 1 ELSE 0 END) * 100.0 / COUNT(*), 2)   AS pct_under_5s,
    ROUND(SUM(CASE WHEN total_elapsed_time <= 30000  THEN 1 ELSE 0 END) * 100.0 / COUNT(*), 2)   AS pct_under_30s,
    ROUND(SUM(CASE WHEN total_elapsed_time <= 60000  THEN 1 ELSE 0 END) * 100.0 / COUNT(*), 2)   AS pct_under_60s,
    ROUND(SUM(CASE WHEN total_elapsed_time <= 300000 THEN 1 ELSE 0 END) * 100.0 / COUNT(*), 2)   AS pct_under_5min,
    -- SLA violations
    SUM(CASE WHEN total_elapsed_time > 300000 THEN 1 ELSE 0 END) AS violations_over_5min,
    SUM(CASE WHEN total_elapsed_time > 1800000 THEN 1 ELSE 0 END) AS violations_over_30min,
    -- Latency stats
    ROUND(PERCENTILE_CONT(0.95) WITHIN GROUP (ORDER BY total_elapsed_time) / 1000, 2) AS p95_sec,
    ROUND(PERCENTILE_CONT(0.99) WITHIN GROUP (ORDER BY total_elapsed_time) / 1000, 2) AS p99_sec
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
WHERE start_time >= DATEADD('day', -7, CURRENT_TIMESTAMP)
  AND execution_status = 'SUCCESS'
  AND warehouse_name IS NOT NULL
GROUP BY 1, 2
ORDER BY total_queries DESC;


-- -------------------------------------------------------
-- 2. Daily SLA Compliance Trend (Last 30 Days)
-- -------------------------------------------------------
SELECT
    DATE_TRUNC('day', start_time)                         AS day,
    COUNT(*)                                              AS total_queries,
    -- Assuming SLA = 95% queries under 60 seconds
    ROUND(SUM(CASE WHEN total_elapsed_time <= 60000 THEN 1 ELSE 0 END) * 100.0 / COUNT(*), 2) AS pct_meeting_60s_sla,
    SUM(CASE WHEN total_elapsed_time > 60000 THEN 1 ELSE 0 END) AS sla_violations,
    ROUND(PERCENTILE_CONT(0.95) WITHIN GROUP (ORDER BY total_elapsed_time) / 1000, 2) AS p95_sec,
    -- SLA status
    CASE
        WHEN SUM(CASE WHEN total_elapsed_time <= 60000 THEN 1 ELSE 0 END) * 100.0 / COUNT(*) >= 99
             THEN 'EXCELLENT'
        WHEN SUM(CASE WHEN total_elapsed_time <= 60000 THEN 1 ELSE 0 END) * 100.0 / COUNT(*) >= 95
             THEN 'MEETING SLA'
        WHEN SUM(CASE WHEN total_elapsed_time <= 60000 THEN 1 ELSE 0 END) * 100.0 / COUNT(*) >= 90
             THEN 'NEAR MISS'
        ELSE 'SLA BREACH'
    END AS sla_status
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
WHERE start_time >= DATEADD('day', -30, CURRENT_TIMESTAMP)
  AND execution_status = 'SUCCESS'
GROUP BY 1
ORDER BY 1 DESC;


-- -------------------------------------------------------
-- 3. SLA Breaching Queries (Last 24 Hours)
-- -------------------------------------------------------
SELECT
    query_id,
    SUBSTR(query_text, 1, 200)                            AS query_text_preview,
    user_name,
    role_name,
    warehouse_name,
    warehouse_size,
    query_type,
    ROUND(total_elapsed_time / 1000, 2)                   AS elapsed_seconds,
    ROUND(compilation_time / 1000, 2)                     AS compile_sec,
    ROUND(execution_time / 1000, 2)                       AS execute_sec,
    ROUND(queued_overload_time / 1000, 2)                 AS queue_sec,
    ROUND(bytes_scanned / 1073741824, 2)                  AS gb_scanned,
    ROUND(bytes_spilled_to_local_storage / 1073741824, 2) AS gb_spilled_local,
    ROUND(bytes_spilled_to_remote_storage / 1073741824, 2) AS gb_spilled_remote,
    start_time
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
WHERE start_time >= DATEADD('hour', -24, CURRENT_TIMESTAMP)
  AND execution_status = 'SUCCESS'
  AND total_elapsed_time > 300000  -- > 5 minutes (SLA breach threshold)
ORDER BY total_elapsed_time DESC;


-- -------------------------------------------------------
-- 4. Mean Time to Detect Slowdowns (MTTD) - Weekly
-- -------------------------------------------------------
WITH weekly_latency AS (
    SELECT
        DATE_TRUNC('week', start_time)                    AS week,
        ROUND(PERCENTILE_CONT(0.95) WITHIN GROUP
              (ORDER BY total_elapsed_time) / 1000, 2)   AS p95_sec,
        ROUND(AVG(total_elapsed_time) / 1000, 2)          AS avg_sec
    FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
    WHERE start_time >= DATEADD('week', -8, CURRENT_TIMESTAMP)
      AND execution_status = 'SUCCESS'
    GROUP BY 1
)
SELECT
    week,
    p95_sec,
    avg_sec,
    LAG(p95_sec) OVER (ORDER BY week) AS prev_week_p95,
    ROUND((p95_sec - LAG(p95_sec) OVER (ORDER BY week))
          * 100.0 / NULLIF(LAG(p95_sec) OVER (ORDER BY week), 0), 2) AS wow_p95_change_pct,
    CASE
        WHEN (p95_sec - LAG(p95_sec) OVER (ORDER BY week))
             * 100.0 / NULLIF(LAG(p95_sec) OVER (ORDER BY week), 0) > 20
             THEN 'DEGRADATION DETECTED: P95 increased >20% vs last week'
        WHEN (p95_sec - LAG(p95_sec) OVER (ORDER BY week))
             * 100.0 / NULLIF(LAG(p95_sec) OVER (ORDER BY week), 0) < -20
             THEN 'IMPROVEMENT: P95 decreased >20% vs last week'
        ELSE 'STABLE'
    END AS performance_status
FROM weekly_latency
ORDER BY week DESC;
