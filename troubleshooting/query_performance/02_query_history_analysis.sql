-- =============================================================================
-- Script: 02_query_history_analysis.sql
-- Description: Deep dive into query history for performance analysis
-- Source: SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY (45 min latency)
-- =============================================================================

-- -------------------------------------------------------
-- 1. Query Performance Summary - Last 7 Days
-- -------------------------------------------------------
SELECT
    DATE_TRUNC('day', start_time)                        AS query_date,
    warehouse_name,
    COUNT(*)                                             AS total_queries,
    COUNT(DISTINCT user_name)                            AS distinct_users,
    ROUND(AVG(total_elapsed_time) / 1000, 2)            AS avg_elapsed_sec,
    ROUND(PERCENTILE_CONT(0.50) WITHIN GROUP
          (ORDER BY total_elapsed_time) / 1000, 2)     AS p50_elapsed_sec,
    ROUND(PERCENTILE_CONT(0.95) WITHIN GROUP
          (ORDER BY total_elapsed_time) / 1000, 2)     AS p95_elapsed_sec,
    ROUND(PERCENTILE_CONT(0.99) WITHIN GROUP
          (ORDER BY total_elapsed_time) / 1000, 2)     AS p99_elapsed_sec,
    ROUND(AVG(bytes_scanned) / 1073741824, 4)           AS avg_gb_scanned,
    SUM(CASE WHEN execution_status = 'FAIL' THEN 1 ELSE 0 END)  AS failed_queries,
    SUM(CASE WHEN bytes_spilled_to_local_storage > 0
             OR bytes_spilled_to_remote_storage > 0 THEN 1 ELSE 0 END) AS spilled_queries,
    ROUND(AVG(percentage_scanned_from_cache), 2)        AS avg_cache_hit_pct
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
WHERE start_time >= DATEADD('day', -7, CURRENT_TIMESTAMP)
GROUP BY 1, 2
ORDER BY 1 DESC, 3 DESC;


-- -------------------------------------------------------
-- 2. Most Expensive Queries by Resource Consumption
-- -------------------------------------------------------
SELECT
    query_id,
    SUBSTR(query_text, 1, 200)                          AS query_text_preview,
    user_name,
    warehouse_name,
    warehouse_size,
    query_type,
    ROUND(total_elapsed_time / 1000, 2)                 AS elapsed_seconds,
    ROUND(compilation_time / 1000, 2)                   AS compile_seconds,
    ROUND(execution_time / 1000, 2)                     AS execute_seconds,
    ROUND(queued_overload_time / 1000, 2)               AS queue_seconds,
    ROUND(bytes_scanned / 1073741824, 2)                AS gb_scanned,
    ROUND(bytes_spilled_to_local_storage / 1073741824, 2)  AS gb_spilled_local,
    ROUND(bytes_spilled_to_remote_storage / 1073741824, 2) AS gb_spilled_remote,
    ROUND(percentage_scanned_from_cache, 2)             AS cache_hit_pct,
    partitions_scanned,
    partitions_total,
    ROUND(partitions_scanned / NULLIF(partitions_total, 0) * 100, 2) AS pct_partitions_scanned,
    credits_used_cloud_services,
    start_time
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
WHERE start_time >= DATEADD('day', -7, CURRENT_TIMESTAMP)
  AND execution_status = 'SUCCESS'
  AND total_elapsed_time > 30000  -- queries over 30 seconds
ORDER BY total_elapsed_time DESC
LIMIT 50;


-- -------------------------------------------------------
-- 3. Query Type Distribution
-- -------------------------------------------------------
SELECT
    query_type,
    COUNT(*)                                            AS query_count,
    ROUND(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER (), 2) AS pct_of_total,
    ROUND(AVG(total_elapsed_time) / 1000, 2)           AS avg_elapsed_sec,
    ROUND(SUM(total_elapsed_time) / 3600000, 2)        AS total_hours,
    ROUND(AVG(bytes_scanned) / 1073741824, 4)          AS avg_gb_scanned,
    SUM(CASE WHEN execution_status = 'FAIL' THEN 1 ELSE 0 END) AS failed_count
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
WHERE start_time >= DATEADD('day', -7, CURRENT_TIMESTAMP)
GROUP BY query_type
ORDER BY query_count DESC;


-- -------------------------------------------------------
-- 4. Repeated / Identical Queries (Cache Optimization Candidates)
-- -------------------------------------------------------
SELECT
    query_hash,
    COUNT(*)                                            AS execution_count,
    COUNT(DISTINCT user_name)                           AS distinct_users,
    ROUND(AVG(total_elapsed_time) / 1000, 2)           AS avg_elapsed_sec,
    ROUND(SUM(total_elapsed_time) / 3600000, 2)        AS total_cpu_hours,
    ROUND(AVG(percentage_scanned_from_cache), 2)       AS avg_cache_hit_pct,
    ROUND(AVG(bytes_scanned) / 1073741824, 4)          AS avg_gb_scanned,
    MIN(start_time)                                    AS first_seen,
    MAX(start_time)                                    AS last_seen,
    MAX(SUBSTR(query_text, 1, 300))                    AS sample_query
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
WHERE start_time >= DATEADD('day', -7, CURRENT_TIMESTAMP)
  AND execution_status = 'SUCCESS'
GROUP BY query_hash
HAVING execution_count > 10
   AND avg_cache_hit_pct < 50  -- cache not being fully utilized
ORDER BY total_cpu_hours DESC
LIMIT 30;


-- -------------------------------------------------------
-- 5. Queries with Poor Partition Pruning
-- -------------------------------------------------------
SELECT
    query_id,
    SUBSTR(query_text, 1, 300)                         AS query_text_preview,
    user_name,
    warehouse_name,
    ROUND(total_elapsed_time / 1000, 2)                AS elapsed_seconds,
    partitions_scanned,
    partitions_total,
    ROUND(partitions_scanned / NULLIF(partitions_total, 0) * 100, 2) AS pct_scanned,
    ROUND(bytes_scanned / 1073741824, 2)               AS gb_scanned,
    start_time
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
WHERE start_time >= DATEADD('day', -7, CURRENT_TIMESTAMP)
  AND execution_status = 'SUCCESS'
  AND partitions_total > 100
  AND partitions_scanned / NULLIF(partitions_total, 0) > 0.90  -- scanning > 90% of partitions
ORDER BY bytes_scanned DESC
LIMIT 30;
