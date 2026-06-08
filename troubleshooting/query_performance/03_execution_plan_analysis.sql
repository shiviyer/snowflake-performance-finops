-- =============================================================================
-- Script: 03_execution_plan_analysis.sql
-- Description: Analyze query execution plans and operator-level performance
-- Source: SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY + GET_QUERY_OPERATOR_STATS()
-- =============================================================================

-- -------------------------------------------------------
-- 1. Get Execution Plan Stats for a Specific Query
--    Replace :query_id with the target query ID
-- -------------------------------------------------------
SELECT *
FROM TABLE(GET_QUERY_OPERATOR_STATS(:query_id));

-- Alternative: Get operator stats from query profile
SELECT
    operator_id,
    operator_type,
    operator_statistics:input_rows::NUMBER           AS input_rows,
    operator_statistics:output_rows::NUMBER          AS output_rows,
    operator_statistics:bytes_written::NUMBER        AS bytes_written,
    ROUND(operator_statistics:io_time::NUMBER / 1000, 2) AS io_time_sec,
    ROUND(operator_statistics:network_time::NUMBER / 1000, 2) AS network_time_sec,
    ROUND(operator_statistics:local_disk_io:bytes_written_local::NUMBER / 1073741824, 4) AS gb_spilled_local,
    ROUND(operator_statistics:remote_disk_io:bytes_written_remote::NUMBER / 1073741824, 4) AS gb_spilled_remote,
    execution_time_breakdown:overall_percentage::NUMBER AS pct_overall_time,
    parent_operators
FROM TABLE(GET_QUERY_OPERATOR_STATS(:query_id))
ORDER BY operator_id;


-- -------------------------------------------------------
-- 2. Queries with High Compilation Time (Top 20, last 7 days)
-- -------------------------------------------------------
SELECT
    query_id,
    SUBSTR(query_text, 1, 200)                       AS query_text_preview,
    user_name,
    warehouse_name,
    ROUND(total_elapsed_time / 1000, 2)              AS elapsed_seconds,
    ROUND(compilation_time / 1000, 2)                AS compile_seconds,
    ROUND(execution_time / 1000, 2)                  AS execute_seconds,
    ROUND(compilation_time * 100.0 / NULLIF(total_elapsed_time, 0), 2) AS compile_pct,
    start_time
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
WHERE start_time >= DATEADD('day', -7, CURRENT_TIMESTAMP)
  AND execution_status = 'SUCCESS'
  AND total_elapsed_time > 10000
  AND compilation_time > 5000  -- more than 5 seconds compilation
ORDER BY compilation_time DESC
LIMIT 20;


-- -------------------------------------------------------
-- 3. Queries with Highest Queue Wait Time
-- -------------------------------------------------------
SELECT
    query_id,
    SUBSTR(query_text, 1, 200)                       AS query_text_preview,
    user_name,
    warehouse_name,
    warehouse_size,
    ROUND(total_elapsed_time / 1000, 2)              AS elapsed_seconds,
    ROUND(queued_overload_time / 1000, 2)            AS overload_queue_seconds,
    ROUND(queued_provisioning_time / 1000, 2)        AS provisioning_queue_seconds,
    ROUND(queued_repair_time / 1000, 2)              AS repair_queue_seconds,
    ROUND((queued_overload_time + queued_provisioning_time + queued_repair_time) / 1000, 2) AS total_queue_seconds,
    start_time
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
WHERE start_time >= DATEADD('day', -7, CURRENT_TIMESTAMP)
  AND execution_status = 'SUCCESS'
  AND (queued_overload_time + queued_provisioning_time + queued_repair_time) > 10000
ORDER BY total_queue_seconds DESC
LIMIT 30;


-- -------------------------------------------------------
-- 4. Queries Benefiting Most from Caching (cache analysis)
-- -------------------------------------------------------
SELECT
    query_hash,
    COUNT(*)                                         AS executions,
    ROUND(AVG(percentage_scanned_from_cache), 2)    AS avg_cache_pct,
    ROUND(AVG(total_elapsed_time) / 1000, 2)        AS avg_elapsed_sec,
    ROUND(AVG(bytes_scanned) / 1073741824, 4)       AS avg_gb_scanned,
    -- Estimated savings if all were cache hits vs full scans
    ROUND(SUM(bytes_scanned * (1 - percentage_scanned_from_cache / 100)) / 1073741824, 2) AS gb_that_could_be_cached,
    MAX(SUBSTR(query_text, 1, 200))                 AS sample_query
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
WHERE start_time >= DATEADD('day', -7, CURRENT_TIMESTAMP)
  AND execution_status = 'SUCCESS'
  AND bytes_scanned > 0
GROUP BY query_hash
HAVING executions > 5
ORDER BY gb_that_could_be_cached DESC
LIMIT 20;


-- -------------------------------------------------------
-- 5. Breakdown of Time by Query Phase (Compilation vs Execution vs Queue)
-- -------------------------------------------------------
SELECT
    warehouse_name,
    COUNT(*)                                          AS total_queries,
    ROUND(AVG(compilation_time) / 1000, 2)           AS avg_compile_sec,
    ROUND(AVG(execution_time) / 1000, 2)             AS avg_execute_sec,
    ROUND(AVG(queued_overload_time) / 1000, 2)       AS avg_queue_sec,
    ROUND(AVG(compilation_time) * 100.0 /
          NULLIF(AVG(total_elapsed_time), 0), 2)     AS avg_compile_pct,
    ROUND(AVG(execution_time) * 100.0 /
          NULLIF(AVG(total_elapsed_time), 0), 2)     AS avg_execute_pct,
    ROUND(AVG(queued_overload_time) * 100.0 /
          NULLIF(AVG(total_elapsed_time), 0), 2)     AS avg_queue_pct
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
WHERE start_time >= DATEADD('day', -7, CURRENT_TIMESTAMP)
  AND execution_status = 'SUCCESS'
  AND warehouse_name IS NOT NULL
GROUP BY warehouse_name
ORDER BY total_queries DESC;
