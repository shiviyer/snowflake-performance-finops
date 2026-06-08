-- =============================================================================
-- Script: 01_performance_kpis.sql
-- Description: Key performance indicators for Snowflake query and warehouse performance
-- Source: SNOWFLAKE.ACCOUNT_USAGE
-- Run: Daily or weekly for trend analysis
-- =============================================================================

-- -------------------------------------------------------
-- 1. Core Query Performance KPIs (Last 30 Days by Week)
-- -------------------------------------------------------
SELECT
    DATE_TRUNC('week', start_time)                        AS week_start,
    -- Volume
    COUNT(*)                                              AS total_queries,
    COUNT(DISTINCT user_name)                             AS active_users,
    COUNT(DISTINCT warehouse_name)                        AS active_warehouses,
    -- Latency
    ROUND(AVG(total_elapsed_time) / 1000, 2)             AS avg_elapsed_sec,
    ROUND(PERCENTILE_CONT(0.50) WITHIN GROUP
          (ORDER BY total_elapsed_time) / 1000, 2)       AS p50_elapsed_sec,
    ROUND(PERCENTILE_CONT(0.95) WITHIN GROUP
          (ORDER BY total_elapsed_time) / 1000, 2)       AS p95_elapsed_sec,
    ROUND(PERCENTILE_CONT(0.99) WITHIN GROUP
          (ORDER BY total_elapsed_time) / 1000, 2)       AS p99_elapsed_sec,
    -- Efficiency
    ROUND(AVG(percentage_scanned_from_cache), 2)         AS avg_cache_hit_pct,
    ROUND(AVG(partitions_scanned) / NULLIF(AVG(partitions_total), 0) * 100, 2) AS avg_partition_scan_pct,
    -- Quality
    ROUND(SUM(CASE WHEN execution_status = 'FAIL' THEN 1 ELSE 0 END)
          * 100.0 / COUNT(*), 2)                         AS failure_rate_pct,
    ROUND(SUM(CASE WHEN bytes_spilled_to_local_storage > 0
                   OR bytes_spilled_to_remote_storage > 0 THEN 1 ELSE 0 END)
          * 100.0 / COUNT(*), 2)                         AS spillage_rate_pct,
    -- Throughput
    ROUND(COUNT(*) / 7.0, 0)                             AS queries_per_day_avg
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
WHERE start_time >= DATEADD('day', -30, CURRENT_TIMESTAMP)
GROUP BY 1
ORDER BY 1 DESC;


-- -------------------------------------------------------
-- 2. SLA Compliance by Warehouse (Last 7 Days)
-- -------------------------------------------------------
-- Adjust :sla_threshold_seconds to your SLA requirement
SELECT
    warehouse_name,
    warehouse_size,
    COUNT(*)                                              AS total_queries,
    SUM(CASE WHEN total_elapsed_time <= 30000 THEN 1 ELSE 0 END)  AS within_30s,
    SUM(CASE WHEN total_elapsed_time <= 60000 THEN 1 ELSE 0 END)  AS within_60s,
    SUM(CASE WHEN total_elapsed_time <= 300000 THEN 1 ELSE 0 END) AS within_5min,
    SUM(CASE WHEN total_elapsed_time > 300000 THEN 1 ELSE 0 END)  AS over_5min,
    ROUND(SUM(CASE WHEN total_elapsed_time <= 60000 THEN 1 ELSE 0 END)
          * 100.0 / COUNT(*), 2)                         AS pct_within_60s,
    ROUND(SUM(CASE WHEN total_elapsed_time <= 300000 THEN 1 ELSE 0 END)
          * 100.0 / COUNT(*), 2)                         AS pct_within_5min
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
WHERE start_time >= DATEADD('day', -7, CURRENT_TIMESTAMP)
  AND execution_status = 'SUCCESS'
  AND warehouse_name IS NOT NULL
GROUP BY 1, 2
ORDER BY total_queries DESC;


-- -------------------------------------------------------
-- 3. Query Volume Hourly Pattern (Last 7 Days)
--    Useful for capacity planning and auto-scaling setup
-- -------------------------------------------------------
SELECT
    DAYNAME(start_time)                                   AS day_of_week,
    HOUR(start_time)                                      AS hour_of_day,
    ROUND(AVG(query_count), 0)                            AS avg_queries_per_hour,
    ROUND(MAX(query_count), 0)                            AS peak_queries_per_hour,
    ROUND(AVG(avg_elapsed_sec), 2)                        AS avg_elapsed_sec
FROM (
    SELECT
        DATE_TRUNC('hour', start_time)                    AS hour_bucket,
        DAYNAME(start_time)                               AS day_of_week,
        HOUR(start_time)                                  AS hour_of_day,
        COUNT(*)                                          AS query_count,
        AVG(total_elapsed_time) / 1000                    AS avg_elapsed_sec
    FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
    WHERE start_time >= DATEADD('day', -7, CURRENT_TIMESTAMP)
      AND execution_status = 'SUCCESS'
    GROUP BY 1, 2, 3
) hourly
GROUP BY 1, 2
ORDER BY
    DECODE(day_of_week, 'Monday', 1, 'Tuesday', 2, 'Wednesday', 3,
           'Thursday', 4, 'Friday', 5, 'Saturday', 6, 'Sunday', 7),
    hour_of_day;


-- -------------------------------------------------------
-- 4. Top Performance Issues by Impact
-- -------------------------------------------------------
SELECT
    issue_type,
    COUNT(*)                                              AS occurrences,
    ROUND(SUM(impact_seconds), 2)                        AS total_impact_seconds,
    ROUND(AVG(impact_seconds), 2)                        AS avg_impact_seconds
FROM (
    -- Long-running queries
    SELECT 'Long Query (>5min)' AS issue_type,
           total_elapsed_time / 1000 AS impact_seconds
    FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
    WHERE start_time >= DATEADD('day', -7, CURRENT_TIMESTAMP)
      AND total_elapsed_time > 300000
    UNION ALL
    -- Queue wait
    SELECT 'Queue Wait (>30s)',
           queued_overload_time / 1000
    FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
    WHERE start_time >= DATEADD('day', -7, CURRENT_TIMESTAMP)
      AND queued_overload_time > 30000
    UNION ALL
    -- Spillage
    SELECT 'Remote Spillage',
           total_elapsed_time / 1000
    FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
    WHERE start_time >= DATEADD('day', -7, CURRENT_TIMESTAMP)
      AND bytes_spilled_to_remote_storage > 0
    UNION ALL
    -- Failed queries
    SELECT 'Query Failure',
           total_elapsed_time / 1000
    FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
    WHERE start_time >= DATEADD('day', -7, CURRENT_TIMESTAMP)
      AND execution_status = 'FAIL'
) issues
GROUP BY 1
ORDER BY total_impact_seconds DESC;
