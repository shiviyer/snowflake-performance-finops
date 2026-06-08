-- =============================================================================
-- Script: 06_compilation_overhead.sql
-- Description: Identify queries with excessive compilation time
-- Source: SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
-- Note: High compilation = complex SQL, missing stats, or repeated cold-start
-- =============================================================================

-- -------------------------------------------------------
-- 1. Top Queries by Compilation Time (Last 7 Days)
-- -------------------------------------------------------
SELECT
    query_id,
    SUBSTR(query_text, 1, 300)                            AS query_text_preview,
    user_name,
    warehouse_name,
    query_type,
    ROUND(total_elapsed_time / 1000, 2)                   AS elapsed_seconds,
    ROUND(compilation_time / 1000, 2)                     AS compile_seconds,
    ROUND(execution_time / 1000, 2)                       AS execute_seconds,
    ROUND(compilation_time * 100.0 / NULLIF(total_elapsed_time, 0), 2) AS compile_pct_of_total,
    start_time
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
WHERE start_time >= DATEADD('day', -7, CURRENT_TIMESTAMP)
  AND execution_status = 'SUCCESS'
  AND compilation_time > 10000   -- over 10 seconds compilation
ORDER BY compilation_time DESC
LIMIT 30;


-- -------------------------------------------------------
-- 2. Compilation Time Trend by Day and Warehouse
-- -------------------------------------------------------
SELECT
    DATE_TRUNC('day', start_time)                         AS query_date,
    warehouse_name,
    COUNT(*)                                              AS total_queries,
    ROUND(AVG(compilation_time) / 1000, 2)               AS avg_compile_sec,
    ROUND(AVG(execution_time) / 1000, 2)                 AS avg_execute_sec,
    ROUND(AVG(compilation_time) * 100.0 /
          NULLIF(AVG(total_elapsed_time), 0), 2)         AS avg_compile_pct,
    COUNT(CASE WHEN compilation_time > 30000 THEN 1 END) AS high_compile_count
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
WHERE start_time >= DATEADD('day', -14, CURRENT_TIMESTAMP)
  AND execution_status = 'SUCCESS'
  AND warehouse_name IS NOT NULL
GROUP BY 1, 2
ORDER BY 1 DESC, avg_compile_pct DESC;


-- -------------------------------------------------------
-- 3. Query Patterns with Repeated High Compilation (cache-miss patterns)
-- -------------------------------------------------------
SELECT
    query_hash,
    COUNT(*)                                              AS executions,
    ROUND(AVG(compilation_time) / 1000, 2)               AS avg_compile_sec,
    ROUND(MAX(compilation_time) / 1000, 2)               AS max_compile_sec,
    ROUND(SUM(compilation_time) / 60000, 2)              AS total_compile_minutes,
    ROUND(AVG(compilation_time) * 100.0 /
          NULLIF(AVG(total_elapsed_time), 0), 2)         AS avg_compile_pct,
    MAX(SUBSTR(query_text, 1, 300))                      AS sample_query
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
WHERE start_time >= DATEADD('day', -7, CURRENT_TIMESTAMP)
  AND execution_status = 'SUCCESS'
  AND compilation_time > 5000
GROUP BY query_hash
HAVING executions > 3
ORDER BY total_compile_minutes DESC
LIMIT 20;


-- -------------------------------------------------------
-- 4. Compilation Overhead by User/Role
-- -------------------------------------------------------
SELECT
    user_name,
    role_name,
    COUNT(*)                                              AS total_queries,
    ROUND(AVG(compilation_time) / 1000, 2)               AS avg_compile_sec,
    ROUND(SUM(compilation_time) / 60000, 2)              AS total_compile_minutes,
    ROUND(AVG(compilation_time) * 100.0 /
          NULLIF(AVG(total_elapsed_time), 0), 2)         AS avg_compile_pct
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
WHERE start_time >= DATEADD('day', -7, CURRENT_TIMESTAMP)
  AND execution_status = 'SUCCESS'
GROUP BY 1, 2
ORDER BY total_compile_minutes DESC
LIMIT 20;


-- -------------------------------------------------------
-- 5. Recommendations: Reduce Compilation Time
-- -------------------------------------------------------
-- Key tactics:
-- a) Use QUERY_TAG to group and cache compiled plans
-- b) Avoid dynamically generated SQL where possible
-- c) Use prepared statements / parameterized queries
-- d) Keep warehouse running (warm state reduces cold-compile time)
-- e) Simplify deeply nested CTEs and sub-queries

-- Check if queries are using query result reuse
SELECT
    query_id,
    SUBSTR(query_text, 1, 200)                           AS query_text_preview,
    query_hash,
    ROUND(compilation_time / 1000, 2)                    AS compile_sec,
    ROUND(execution_time / 1000, 2)                      AS execute_sec,
    percentage_scanned_from_cache                        AS result_cache_hit_pct,
    start_time
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
WHERE start_time >= DATEADD('day', -3, CURRENT_TIMESTAMP)
  AND execution_status = 'SUCCESS'
  AND compilation_time > 30000   -- > 30 sec compile
ORDER BY compilation_time DESC
LIMIT 20;
