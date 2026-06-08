-- =============================================================================
-- Script: 04_spillage_detection.sql
-- Description: Detect queries causing local and remote disk spillage
-- Source: SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
-- Impact: Spillage drastically slows queries and increases costs
-- =============================================================================

-- -------------------------------------------------------
-- 1. Queries with Significant Disk Spillage (Last 7 Days)
-- -------------------------------------------------------
SELECT
    query_id,
    SUBSTR(query_text, 1, 200)                            AS query_text_preview,
    user_name,
    warehouse_name,
    warehouse_size,
    ROUND(total_elapsed_time / 1000, 2)                   AS elapsed_seconds,
    ROUND(bytes_scanned / 1073741824, 2)                  AS gb_scanned,
    ROUND(bytes_spilled_to_local_storage / 1073741824, 2) AS gb_spilled_local,
    ROUND(bytes_spilled_to_remote_storage / 1073741824, 2) AS gb_spilled_remote,
    ROUND((bytes_spilled_to_local_storage + bytes_spilled_to_remote_storage)
          / 1073741824, 2)                                AS gb_spilled_total,
    ROUND(bytes_spilled_to_local_storage * 100.0 /
          NULLIF(bytes_scanned, 0), 2)                   AS local_spill_ratio_pct,
    start_time
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
WHERE start_time >= DATEADD('day', -7, CURRENT_TIMESTAMP)
  AND execution_status = 'SUCCESS'
  AND (bytes_spilled_to_local_storage > 1073741824   -- > 1 GB local spill
       OR bytes_spilled_to_remote_storage > 0)        -- any remote spill
ORDER BY gb_spilled_total DESC
LIMIT 50;


-- -------------------------------------------------------
-- 2. Spillage Summary by Warehouse
-- -------------------------------------------------------
SELECT
    warehouse_name,
    warehouse_size,
    COUNT(*)                                               AS total_queries,
    SUM(CASE WHEN bytes_spilled_to_local_storage > 0
             OR bytes_spilled_to_remote_storage > 0 THEN 1 ELSE 0 END) AS spilled_queries,
    ROUND(SUM(CASE WHEN bytes_spilled_to_local_storage > 0
                   OR bytes_spilled_to_remote_storage > 0 THEN 1 ELSE 0 END)
          * 100.0 / COUNT(*), 2)                         AS spillage_rate_pct,
    ROUND(SUM(bytes_spilled_to_local_storage) / 1073741824, 2)  AS total_gb_local_spill,
    ROUND(SUM(bytes_spilled_to_remote_storage) / 1073741824, 2) AS total_gb_remote_spill,
    ROUND(AVG(CASE WHEN bytes_spilled_to_local_storage > 0
              THEN total_elapsed_time ELSE NULL END) / 1000, 2) AS avg_elapsed_when_spilling_sec
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
WHERE start_time >= DATEADD('day', -7, CURRENT_TIMESTAMP)
  AND execution_status = 'SUCCESS'
  AND warehouse_name IS NOT NULL
GROUP BY 1, 2
HAVING spilled_queries > 0
ORDER BY total_gb_local_spill + total_gb_remote_spill DESC;


-- -------------------------------------------------------
-- 3. Spillage Trend (Daily, Last 30 Days)
-- -------------------------------------------------------
SELECT
    DATE_TRUNC('day', start_time)                         AS query_date,
    COUNT(*)                                              AS total_queries,
    SUM(CASE WHEN bytes_spilled_to_local_storage > 0
             OR bytes_spilled_to_remote_storage > 0 THEN 1 ELSE 0 END) AS spilled_queries,
    ROUND(SUM(bytes_spilled_to_local_storage) / 1073741824, 2)  AS gb_local_spill,
    ROUND(SUM(bytes_spilled_to_remote_storage) / 1073741824, 2) AS gb_remote_spill,
    ROUND(SUM(CASE WHEN bytes_spilled_to_local_storage > 0
                   OR bytes_spilled_to_remote_storage > 0 THEN 1 ELSE 0 END)
          * 100.0 / COUNT(*), 2)                         AS spillage_pct
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
WHERE start_time >= DATEADD('day', -30, CURRENT_TIMESTAMP)
  AND execution_status = 'SUCCESS'
GROUP BY 1
ORDER BY 1 DESC;


-- -------------------------------------------------------
-- 4. Top Users Causing Spillage
-- -------------------------------------------------------
SELECT
    user_name,
    COUNT(*)                                              AS total_queries,
    SUM(CASE WHEN bytes_spilled_to_local_storage > 0
             OR bytes_spilled_to_remote_storage > 0 THEN 1 ELSE 0 END) AS spilled_queries,
    ROUND(SUM(bytes_spilled_to_local_storage) / 1073741824, 2)  AS gb_local_spill,
    ROUND(SUM(bytes_spilled_to_remote_storage) / 1073741824, 2) AS gb_remote_spill,
    ROUND(AVG(total_elapsed_time) / 1000, 2)             AS avg_elapsed_sec
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
WHERE start_time >= DATEADD('day', -7, CURRENT_TIMESTAMP)
  AND execution_status = 'SUCCESS'
GROUP BY user_name
HAVING spilled_queries > 0
ORDER BY gb_local_spill + gb_remote_spill DESC
LIMIT 20;


-- -------------------------------------------------------
-- 5. Remediation: Warehouse Size Recommendation for Spillage
-- Rule of thumb: Remote spillage = need larger warehouse
--                Local spillage only = may need clustering or query optimization
-- -------------------------------------------------------
SELECT
    warehouse_name,
    warehouse_size,
    ROUND(SUM(bytes_spilled_to_remote_storage) / 1073741824, 2) AS gb_remote_spill,
    CASE
        WHEN SUM(bytes_spilled_to_remote_storage) > 107374182400 THEN 'CRITICAL: Scale up 2+ sizes immediately'
        WHEN SUM(bytes_spilled_to_remote_storage) > 10737418240  THEN 'WARNING: Consider scaling up 1-2 sizes'
        WHEN SUM(bytes_spilled_to_remote_storage) > 1073741824   THEN 'MONITOR: Review query patterns'
        ELSE 'OK: Remote spillage acceptable'
    END AS recommendation,
    COUNT(DISTINCT query_id)                              AS affected_queries
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
WHERE start_time >= DATEADD('day', -7, CURRENT_TIMESTAMP)
  AND execution_status = 'SUCCESS'
GROUP BY 1, 2
ORDER BY gb_remote_spill DESC;
