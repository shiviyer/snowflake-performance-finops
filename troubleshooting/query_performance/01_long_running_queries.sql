-- =============================================================================
-- Script: 01_long_running_queries.sql
-- Description: Identify currently running queries that exceed a time threshold
-- Source: INFORMATION_SCHEMA (real-time) + ACCOUNT_USAGE (historical)
-- Usage: Set :threshold_minutes to your desired cutoff
-- =============================================================================

-- -------------------------------------------------------
-- 1. Currently executing queries over threshold (real-time)
-- -------------------------------------------------------
SELECT
    query_id,
    query_text,
    user_name,
    role_name,
    warehouse_name,
    warehouse_size,
    database_name,
    schema_name,
    query_type,
    execution_status,
    ROUND(execution_time / 60000, 2)          AS execution_minutes,
    ROUND(bytes_scanned / 1073741824, 2)      AS gb_scanned,
    ROUND(bytes_processed / 1073741824, 2)    AS gb_processed,
    ROUND(percentage_scanned_from_cache, 2)   AS cache_hit_pct,
    partitions_scanned,
    partitions_total,
    ROUND(partitions_scanned / NULLIF(partitions_total, 0) * 100, 2) AS partition_scan_pct,
    start_time,
    DATEDIFF('second', start_time, CURRENT_TIMESTAMP) / 60.0 AS running_minutes
FROM TABLE(INFORMATION_SCHEMA.QUERY_HISTORY_BY_SESSION(
    RESULT_LIMIT => 10000,
    END_TIME_RANGE_START => DATEADD('hour', -1, CURRENT_TIMESTAMP)
))
WHERE execution_status = 'RUNNING'
  AND DATEDIFF('minute', start_time, CURRENT_TIMESTAMP) > 5  -- threshold: 5 minutes
ORDER BY running_minutes DESC;


-- -------------------------------------------------------
-- 2. Completed long-running queries (last 7 days, ACCOUNT_USAGE)
-- -------------------------------------------------------
SELECT
    query_id,
    query_text,
    user_name,
    role_name,
    warehouse_name,
    warehouse_size,
    database_name,
    schema_name,
    query_type,
    execution_status,
    ROUND(total_elapsed_time / 60000, 2)           AS elapsed_minutes,
    ROUND(compilation_time / 1000, 2)              AS compile_seconds,
    ROUND(execution_time / 1000, 2)                AS execute_seconds,
    ROUND(queued_overload_time / 1000, 2)          AS queue_seconds,
    ROUND(bytes_scanned / 1073741824, 2)           AS gb_scanned,
    ROUND(bytes_written / 1073741824, 2)           AS gb_written,
    ROUND(bytes_spilled_to_local_storage / 1073741824, 2)  AS gb_spilled_local,
    ROUND(bytes_spilled_to_remote_storage / 1073741824, 2) AS gb_spilled_remote,
    ROUND(percentage_scanned_from_cache, 2)        AS cache_hit_pct,
    partitions_scanned,
    partitions_total,
    ROUND(partitions_scanned / NULLIF(partitions_total, 0) * 100, 2) AS partition_scan_pct,
    credits_used_cloud_services,
    start_time,
    end_time
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
WHERE start_time >= DATEADD('day', -7, CURRENT_TIMESTAMP)
  AND execution_status = 'SUCCESS'
  AND total_elapsed_time > 300000  -- threshold: 5 minutes = 300,000 ms
ORDER BY total_elapsed_time DESC
LIMIT 100;


-- -------------------------------------------------------
-- 3. Top N slowest queries by user (last 24 hours)
-- -------------------------------------------------------
SELECT
    user_name,
    COUNT(*)                                        AS query_count,
    ROUND(AVG(total_elapsed_time) / 1000, 2)       AS avg_elapsed_seconds,
    ROUND(MAX(total_elapsed_time) / 60000, 2)      AS max_elapsed_minutes,
    ROUND(SUM(total_elapsed_time) / 3600000, 2)    AS total_elapsed_hours,
    ROUND(AVG(bytes_scanned) / 1073741824, 2)      AS avg_gb_scanned,
    SUM(CASE WHEN bytes_spilled_to_local_storage > 0 THEN 1 ELSE 0 END) AS queries_with_spillage
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
WHERE start_time >= DATEADD('hour', -24, CURRENT_TIMESTAMP)
  AND execution_status = 'SUCCESS'
GROUP BY user_name
ORDER BY total_elapsed_hours DESC
LIMIT 20;


-- -------------------------------------------------------
-- 4. Long-running query trend (hourly buckets, last 48h)
-- -------------------------------------------------------
SELECT
    DATE_TRUNC('hour', start_time)                  AS hour_bucket,
    COUNT(*)                                        AS total_queries,
    SUM(CASE WHEN total_elapsed_time > 300000 THEN 1 ELSE 0 END)  AS slow_queries_5min,
    SUM(CASE WHEN total_elapsed_time > 1800000 THEN 1 ELSE 0 END) AS slow_queries_30min,
    ROUND(AVG(total_elapsed_time) / 1000, 2)        AS avg_elapsed_seconds,
    ROUND(PERCENTILE_CONT(0.95) WITHIN GROUP
          (ORDER BY total_elapsed_time) / 1000, 2) AS p95_elapsed_seconds
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
WHERE start_time >= DATEADD('hour', -48, CURRENT_TIMESTAMP)
  AND execution_status = 'SUCCESS'
GROUP BY 1
ORDER BY 1 DESC;
