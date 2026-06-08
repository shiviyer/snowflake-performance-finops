-- =============================================================================
-- Script: 03_query_result_cache_analysis.sql
-- Description: Analyze result cache hit rates and identify cache optimization opportunities
-- Source: SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
-- =============================================================================

-- -------------------------------------------------------
-- 1. Cache Hit Rate Trend (Daily, Last 30 Days)
-- -------------------------------------------------------
SELECT
    DATE_TRUNC('day', start_time)                         AS day,
    COUNT(*)                                              AS total_queries,
    ROUND(AVG(percentage_scanned_from_cache), 2)         AS avg_cache_hit_pct,
    SUM(CASE WHEN percentage_scanned_from_cache = 100 THEN 1 ELSE 0 END) AS full_cache_hits,
    SUM(CASE WHEN percentage_scanned_from_cache > 0
             AND percentage_scanned_from_cache < 100 THEN 1 ELSE 0 END)  AS partial_cache_hits,
    SUM(CASE WHEN percentage_scanned_from_cache = 0 THEN 1 ELSE 0 END)   AS cache_misses,
    ROUND(SUM(CASE WHEN percentage_scanned_from_cache = 100 THEN 1 ELSE 0 END)
          * 100.0 / COUNT(*), 2)                         AS full_hit_pct,
    -- Estimated bytes saved by cache
    ROUND(SUM(bytes_scanned * percentage_scanned_from_cache / 100) / 1099511627776, 4) AS tb_saved_by_cache
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
WHERE start_time >= DATEADD('day', -30, CURRENT_TIMESTAMP)
  AND execution_status = 'SUCCESS'
GROUP BY 1
ORDER BY 1 DESC;


-- -------------------------------------------------------
-- 2. Cache Hit Rate by Warehouse
-- -------------------------------------------------------
SELECT
    warehouse_name,
    COUNT(*)                                              AS total_queries,
    ROUND(AVG(percentage_scanned_from_cache), 2)         AS avg_cache_hit_pct,
    ROUND(SUM(CASE WHEN percentage_scanned_from_cache = 100 THEN 1 ELSE 0 END)
          * 100.0 / COUNT(*), 2)                         AS full_hit_pct,
    ROUND(SUM(CASE WHEN percentage_scanned_from_cache = 0 THEN 1 ELSE 0 END)
          * 100.0 / COUNT(*), 2)                         AS miss_pct,
    -- Estimated credit savings from caching
    ROUND(SUM(bytes_scanned * percentage_scanned_from_cache / 100) / 1099511627776, 4) AS tb_served_from_cache
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
WHERE start_time >= DATEADD('day', -7, CURRENT_TIMESTAMP)
  AND execution_status = 'SUCCESS'
  AND warehouse_name IS NOT NULL
GROUP BY 1
ORDER BY miss_pct DESC;


-- -------------------------------------------------------
-- 3. Repeated Queries NOT Benefiting from Cache
--    These are candidates for result caching investigation
-- -------------------------------------------------------
SELECT
    query_hash,
    COUNT(*)                                              AS executions,
    ROUND(AVG(percentage_scanned_from_cache), 2)         AS avg_cache_pct,
    ROUND(AVG(total_elapsed_time) / 1000, 2)             AS avg_elapsed_sec,
    ROUND(AVG(bytes_scanned) / 1073741824, 4)            AS avg_gb_scanned,
    -- Estimated waste: scans that should have been cached
    ROUND(SUM(bytes_scanned * (1 - percentage_scanned_from_cache / 100.0))
          / 1073741824, 2)                               AS gb_wasted_on_repeated_scans,
    MAX(SUBSTR(query_text, 1, 300))                      AS sample_query
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
WHERE start_time >= DATEADD('day', -7, CURRENT_TIMESTAMP)
  AND execution_status = 'SUCCESS'
  AND bytes_scanned > 1073741824  -- queries scanning > 1GB
GROUP BY query_hash
HAVING executions >= 3
   AND avg_cache_pct < 50  -- poor cache utilization
ORDER BY gb_wasted_on_repeated_scans DESC
LIMIT 20;


-- -------------------------------------------------------
-- 4. Reasons Cache May Not Be Used
-- -------------------------------------------------------
-- Common reasons result cache is bypassed:
-- a) USE_CACHED_RESULT = FALSE in session
-- b) Query uses CURRENT_TIMESTAMP/CURRENT_DATE (non-deterministic)
-- c) Underlying data has changed since last execution
-- d) Different session variables or warehouse context
-- e) Query has been modified (even slightly)

-- Check sessions with cache disabled
SELECT
    user_name,
    COUNT(*)                                              AS queries_with_cache_disabled,
    ROUND(AVG(bytes_scanned) / 1073741824, 4)            AS avg_gb_scanned,
    ROUND(SUM(bytes_scanned) / 1099511627776, 4)         AS total_tb_scanned
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
WHERE start_time >= DATEADD('day', -7, CURRENT_TIMESTAMP)
  AND execution_status = 'SUCCESS'
  AND percentage_scanned_from_cache = 0
  AND query_type = 'SELECT'
  AND bytes_scanned > 0
GROUP BY user_name
ORDER BY total_tb_scanned DESC
LIMIT 20;


-- -------------------------------------------------------
-- 5. Cache ROI - Credits Saved by Caching (Last 30 Days)
-- -------------------------------------------------------
WITH cache_savings AS (
    SELECT
        ROUND(SUM(bytes_scanned * percentage_scanned_from_cache / 100.0)
              / 1099511627776, 4)                        AS tb_served_from_cache,
        ROUND(SUM(bytes_scanned) / 1099511627776, 4)     AS total_tb_scanned,
        ROUND(AVG(percentage_scanned_from_cache), 2)     AS avg_cache_hit_pct,
        COUNT(*)                                         AS total_queries
    FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
    WHERE start_time >= DATEADD('day', -30, CURRENT_TIMESTAMP)
      AND execution_status = 'SUCCESS'
      AND bytes_scanned > 0
)
SELECT
    total_queries,
    avg_cache_hit_pct,
    tb_served_from_cache,
    total_tb_scanned,
    ROUND(tb_served_from_cache * 100.0 / NULLIF(total_tb_scanned, 0), 2)  AS cache_tb_pct,
    -- If cache had 0% hit rate, estimate additional credits needed
    -- Rough: 1TB scan at Medium WH ≈ 0.003 credits
    ROUND(tb_served_from_cache * 0.003, 2)               AS estimated_credits_saved,
    ROUND(tb_served_from_cache * 0.003 * 3.0, 2)         AS estimated_cost_saved_usd
FROM cache_savings;
