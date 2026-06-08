-- =============================================================================
-- Script: 02_queue_depth_analysis.sql
-- Description: Analyze query queue depth and wait times by warehouse
-- Source: SNOWFLAKE.ACCOUNT_USAGE
-- =============================================================================

-- -------------------------------------------------------
-- 1. Average Queue Depth by Hour and Warehouse (Last 7 Days)
-- -------------------------------------------------------
SELECT
    warehouse_name,
    DATE_TRUNC('hour', start_time)                      AS hour_bucket,
    DAYNAME(start_time)                                 AS day_of_week,
    HOUR(start_time)                                    AS hour_of_day,
    ROUND(AVG(avg_queued_load), 2)                      AS avg_overload_queue,
    ROUND(AVG(avg_queued_provisioning), 2)              AS avg_provisioning_queue,
    ROUND(MAX(avg_queued_load), 2)                      AS peak_overload_queue,
    ROUND(AVG(avg_running), 2)                          AS avg_running
FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_LOAD_HISTORY
WHERE start_time >= DATEADD('day', -7, CURRENT_TIMESTAMP)
GROUP BY 1, 2, 3, 4
HAVING avg_overload_queue > 0
ORDER BY avg_overload_queue DESC
LIMIT 50;


-- -------------------------------------------------------
-- 2. Query-Level Queue Wait Times (Last 24 Hours)
-- -------------------------------------------------------
SELECT
    warehouse_name,
    warehouse_size,
    COUNT(*)                                            AS total_queries,
    COUNT(CASE WHEN queued_overload_time > 0 THEN 1 END) AS queued_queries,
    ROUND(AVG(CASE WHEN queued_overload_time > 0
              THEN queued_overload_time ELSE NULL END) / 1000, 2) AS avg_queue_sec_when_queued,
    ROUND(MAX(queued_overload_time) / 1000, 2)         AS max_queue_sec,
    ROUND(PERCENTILE_CONT(0.95) WITHIN GROUP
          (ORDER BY queued_overload_time) / 1000, 2)   AS p95_queue_sec,
    ROUND(SUM(queued_overload_time) / 3600000, 2)      AS total_queue_hours,
    ROUND(COUNT(CASE WHEN queued_overload_time > 0 THEN 1 END) * 100.0 /
          COUNT(*), 2)                                  AS queued_pct
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
WHERE start_time >= DATEADD('hour', -24, CURRENT_TIMESTAMP)
  AND execution_status = 'SUCCESS'
  AND warehouse_name IS NOT NULL
GROUP BY 1, 2
ORDER BY total_queue_hours DESC;


-- -------------------------------------------------------
-- 3. Busiest Hours Requiring Concurrency Scaling (Last 30 Days)
-- -------------------------------------------------------
SELECT
    DAYNAME(start_time)                                 AS day_of_week,
    HOUR(start_time)                                    AS hour_of_day,
    warehouse_name,
    COUNT(DISTINCT DATE(start_time))                    AS days_observed,
    ROUND(AVG(avg_queued_load), 4)                      AS avg_queue_depth,
    ROUND(MAX(avg_queued_load), 2)                      AS max_queue_depth,
    ROUND(AVG(avg_running), 2)                          AS avg_concurrent_queries
FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_LOAD_HISTORY
WHERE start_time >= DATEADD('day', -30, CURRENT_TIMESTAMP)
GROUP BY 1, 2, 3
HAVING avg_queue_depth > 0.1
ORDER BY avg_queue_depth DESC
LIMIT 20;


-- -------------------------------------------------------
-- 4. Impact of Queue Depth on Query Latency
-- -------------------------------------------------------
SELECT
    warehouse_name,
    CASE
        WHEN queued_overload_time = 0 THEN '0: No Queue'
        WHEN queued_overload_time < 5000  THEN '1: < 5s'
        WHEN queued_overload_time < 30000 THEN '2: 5-30s'
        WHEN queued_overload_time < 60000 THEN '3: 30s-1min'
        ELSE '4: > 1min'
    END AS queue_bucket,
    COUNT(*)                                            AS query_count,
    ROUND(AVG(total_elapsed_time) / 1000, 2)           AS avg_elapsed_sec,
    ROUND(AVG(execution_time) / 1000, 2)               AS avg_exec_sec,
    ROUND(AVG(bytes_scanned) / 1073741824, 4)          AS avg_gb_scanned
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
WHERE start_time >= DATEADD('day', -7, CURRENT_TIMESTAMP)
  AND execution_status = 'SUCCESS'
  AND warehouse_name IS NOT NULL
GROUP BY 1, 2
ORDER BY 1, 2;


-- -------------------------------------------------------
-- 5. Warehouse Sizing Signal: Queue Rate Threshold
-- Recommend scale-up if queued_pct > 10% for > 2 hours/day
-- -------------------------------------------------------
WITH hourly_stats AS (
    SELECT
        warehouse_name,
        DATE_TRUNC('hour', start_time)                  AS hour_bucket,
        COUNT(*)                                        AS queries,
        SUM(CASE WHEN queued_overload_time > 10000 THEN 1 ELSE 0 END) AS heavily_queued,
        ROUND(SUM(CASE WHEN queued_overload_time > 10000 THEN 1 ELSE 0 END) * 100.0 /
              COUNT(*), 2)                              AS queue_rate_pct
    FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
    WHERE start_time >= DATEADD('day', -7, CURRENT_TIMESTAMP)
      AND execution_status = 'SUCCESS'
      AND warehouse_name IS NOT NULL
    GROUP BY 1, 2
),
summary AS (
    SELECT
        warehouse_name,
        COUNT(*)                                        AS total_hours,
        SUM(CASE WHEN queue_rate_pct > 10 THEN 1 ELSE 0 END) AS hours_with_high_queue,
        ROUND(AVG(queue_rate_pct), 2)                  AS avg_queue_rate_pct
    FROM hourly_stats
    GROUP BY warehouse_name
)
SELECT
    warehouse_name,
    total_hours,
    hours_with_high_queue,
    avg_queue_rate_pct,
    CASE
        WHEN hours_with_high_queue > 14 THEN 'CRITICAL: Scale up warehouse immediately'
        WHEN hours_with_high_queue > 7  THEN 'WARNING: Consider scaling up or enabling multi-cluster'
        WHEN hours_with_high_queue > 2  THEN 'MONITOR: Occasional queuing detected'
        ELSE 'OK: Queue depth acceptable'
    END AS recommendation
FROM summary
ORDER BY hours_with_high_queue DESC;
