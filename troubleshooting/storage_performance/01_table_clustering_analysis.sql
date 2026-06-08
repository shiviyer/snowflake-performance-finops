-- =============================================================================
-- Script: 01_table_clustering_analysis.sql
-- Description: Analyze table clustering efficiency and identify candidates for clustering
-- Source: SNOWFLAKE.ACCOUNT_USAGE + SYSTEM$ functions
-- =============================================================================

-- -------------------------------------------------------
-- 1. Tables with Poor Partition Pruning (Clustering Candidates)
-- -------------------------------------------------------
SELECT
    q.database_name,
    q.schema_name,
    -- Extract table name from query text (approximate)
    q.query_id,
    SUBSTR(q.query_text, 1, 200)                          AS query_text_preview,
    q.warehouse_name,
    q.partitions_scanned,
    q.partitions_total,
    ROUND(q.partitions_scanned / NULLIF(q.partitions_total, 0) * 100, 2) AS partition_scan_pct,
    ROUND(q.bytes_scanned / 1073741824, 2)                AS gb_scanned,
    ROUND(q.total_elapsed_time / 1000, 2)                 AS elapsed_seconds,
    q.start_time
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY q
WHERE q.start_time >= DATEADD('day', -7, CURRENT_TIMESTAMP)
  AND q.execution_status = 'SUCCESS'
  AND q.partitions_total > 50
  AND q.partitions_scanned / NULLIF(q.partitions_total, 0) > 0.80  -- scanning > 80%
  AND q.bytes_scanned > 1073741824  -- scanning > 1 GB
ORDER BY q.bytes_scanned DESC
LIMIT 30;


-- -------------------------------------------------------
-- 2. Automatic Clustering Credit Usage
-- -------------------------------------------------------
SELECT
    DATE_TRUNC('day', start_time)                         AS day,
    table_name,
    database_name,
    schema_name,
    ROUND(SUM(credits_used), 4)                           AS credits_used,
    SUM(bytes_reclustered)                                AS bytes_reclustered,
    SUM(partitions_reclustered)                           AS partitions_reclustered
FROM SNOWFLAKE.ACCOUNT_USAGE.AUTOMATIC_CLUSTERING_HISTORY
WHERE start_time >= DATEADD('day', -30, CURRENT_TIMESTAMP)
GROUP BY 1, 2, 3, 4
ORDER BY credits_used DESC;


-- -------------------------------------------------------
-- 3. Clustering Credit ROI Analysis
--    Compare clustering cost vs query performance improvement
-- -------------------------------------------------------
WITH clustering_cost AS (
    SELECT
        table_name,
        database_name,
        schema_name,
        ROUND(SUM(credits_used), 4)                       AS total_cluster_credits,
        ROUND(SUM(credits_used) * 3.0, 2)                 AS cluster_cost_usd
    FROM SNOWFLAKE.ACCOUNT_USAGE.AUTOMATIC_CLUSTERING_HISTORY
    WHERE start_time >= DATEADD('day', -30, CURRENT_TIMESTAMP)
    GROUP BY 1, 2, 3
)
SELECT
    cc.database_name,
    cc.schema_name,
    cc.table_name,
    cc.total_cluster_credits,
    cc.cluster_cost_usd,
    -- Check table information
    t.row_count,
    ROUND(t.bytes / 1073741824, 2)                        AS table_size_gb,
    t.clustering_key
FROM clustering_cost cc
LEFT JOIN INFORMATION_SCHEMA.TABLES t
    ON UPPER(cc.table_name) = UPPER(t.table_name)
    AND UPPER(cc.schema_name) = UPPER(t.table_schema)
    AND UPPER(cc.database_name) = UPPER(t.table_catalog)
ORDER BY cc.cluster_cost_usd DESC;


-- -------------------------------------------------------
-- 4. System Clustering Information for a Specific Table
--    Replace DATABASE.SCHEMA.TABLE_NAME with your target table
-- -------------------------------------------------------
-- SELECT SYSTEM$CLUSTERING_INFORMATION('DATABASE.SCHEMA.TABLE_NAME');

-- Clustering depth interpretation:
-- Average depth closer to 1 = well-clustered (efficient scans)
-- Average depth >> 1 = poorly clustered (many overlapping partitions)

-- SELECT SYSTEM$CLUSTERING_DEPTH('DATABASE.SCHEMA.TABLE_NAME');


-- -------------------------------------------------------
-- 5. Tables That Would Benefit Most from Clustering
--    Identify large tables with high partition scan ratios
-- -------------------------------------------------------
WITH scan_stats AS (
    SELECT
        database_name,
        schema_name,
        ROUND(AVG(partitions_scanned / NULLIF(partitions_total, 0)) * 100, 2) AS avg_partition_scan_pct,
        COUNT(*)                                           AS scan_count,
        ROUND(SUM(bytes_scanned) / 1073741824, 2)         AS total_gb_scanned,
        ROUND(AVG(total_elapsed_time) / 1000, 2)          AS avg_elapsed_sec
    FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
    WHERE start_time >= DATEADD('day', -7, CURRENT_TIMESTAMP)
      AND execution_status = 'SUCCESS'
      AND partitions_total > 100
      AND bytes_scanned > 1073741824
    GROUP BY 1, 2
    HAVING avg_partition_scan_pct > 70
)
SELECT
    database_name,
    schema_name,
    scan_count,
    avg_partition_scan_pct,
    total_gb_scanned,
    avg_elapsed_sec,
    'Consider clustering on common filter columns' AS recommendation
FROM scan_stats
ORDER BY total_gb_scanned DESC
LIMIT 20;
