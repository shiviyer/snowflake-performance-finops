-- =============================================================================
-- Script: 05_warehouse_sizing_advisor.sql
-- Description: Data-driven warehouse size recommendations based on actual usage
-- Source: SNOWFLAKE.ACCOUNT_USAGE
-- =============================================================================

-- -------------------------------------------------------
-- 1. Comprehensive Warehouse Sizing Analysis (Last 30 Days)
-- -------------------------------------------------------
WITH wh_stats AS (
    SELECT
        q.warehouse_name,
        q.warehouse_size,
        COUNT(*)                                             AS total_queries,
        ROUND(AVG(q.total_elapsed_time) / 1000, 2)         AS avg_elapsed_sec,
        ROUND(PERCENTILE_CONT(0.95) WITHIN GROUP
              (ORDER BY q.total_elapsed_time) / 1000, 2)   AS p95_elapsed_sec,
        ROUND(AVG(q.queued_overload_time) / 1000, 2)       AS avg_queue_sec,
        SUM(CASE WHEN q.queued_overload_time > 10000 THEN 1 ELSE 0 END) AS heavily_queued,
        SUM(CASE WHEN q.bytes_spilled_to_local_storage > 0
                 OR q.bytes_spilled_to_remote_storage > 0 THEN 1 ELSE 0 END) AS spilled_queries,
        ROUND(SUM(q.bytes_spilled_to_remote_storage) / 1073741824, 2) AS gb_remote_spill,
        ROUND(SUM(q.bytes_spilled_to_local_storage) / 1073741824, 2)  AS gb_local_spill
    FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY q
    WHERE q.start_time >= DATEADD('day', -30, CURRENT_TIMESTAMP)
      AND q.execution_status = 'SUCCESS'
      AND q.warehouse_name IS NOT NULL
    GROUP BY 1, 2
),
wh_credits AS (
    SELECT
        warehouse_name,
        ROUND(SUM(credits_used), 2)                        AS total_credits_30d,
        ROUND(AVG(credits_used), 4)                        AS avg_hourly_credits
    FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
    WHERE start_time >= DATEADD('day', -30, CURRENT_TIMESTAMP)
    GROUP BY 1
),
wh_load AS (
    SELECT
        warehouse_name,
        ROUND(AVG(avg_running), 2)                         AS avg_concurrent,
        ROUND(MAX(avg_running), 2)                         AS peak_concurrent,
        ROUND(AVG(avg_queued_load), 4)                     AS avg_queue_depth
    FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_LOAD_HISTORY
    WHERE start_time >= DATEADD('day', -30, CURRENT_TIMESTAMP)
    GROUP BY 1
)
SELECT
    s.warehouse_name,
    s.warehouse_size                                       AS current_size,
    s.total_queries,
    s.avg_elapsed_sec,
    s.p95_elapsed_sec,
    s.avg_queue_sec,
    ROUND(s.heavily_queued * 100.0 / s.total_queries, 2)  AS pct_heavily_queued,
    ROUND(s.spilled_queries * 100.0 / s.total_queries, 2) AS pct_spilled,
    s.gb_remote_spill,
    l.avg_concurrent,
    l.peak_concurrent,
    l.avg_queue_depth,
    c.total_credits_30d,
    -- Sizing recommendation
    CASE
        WHEN s.gb_remote_spill > 100
             OR ROUND(s.heavily_queued * 100.0 / s.total_queries, 2) > 20
             THEN 'SCALE UP: Heavy spillage or >20% queries queued'
        WHEN s.gb_local_spill > 500
             THEN 'CONSIDER UP: Significant local spillage'
        WHEN s.avg_queue_sec > 30
             THEN 'SCALE UP or MULTI-CLUSTER: High average queue time'
        WHEN l.avg_concurrent < 0.5
             AND l.avg_queue_depth = 0
             AND s.gb_remote_spill = 0
             THEN 'SCALE DOWN: Low utilization, no queuing or spillage'
        WHEN l.avg_concurrent < 1.0
             AND l.avg_queue_depth < 0.1
             THEN 'MONITOR: Could possibly scale down'
        ELSE 'OK: Current size appears appropriate'
    END AS recommendation
FROM wh_stats s
LEFT JOIN wh_credits c ON s.warehouse_name = c.warehouse_name
LEFT JOIN wh_load l ON s.warehouse_name = l.warehouse_name
ORDER BY s.gb_remote_spill DESC, pct_heavily_queued DESC;


-- -------------------------------------------------------
-- 2. Warehouse Sizes and Credit Rates Reference
-- -------------------------------------------------------
-- X-Small:   1  credit/hour
-- Small:     2  credits/hour
-- Medium:    4  credits/hour
-- Large:     8  credits/hour
-- X-Large:   16 credits/hour
-- 2X-Large:  32 credits/hour
-- 3X-Large:  64 credits/hour
-- 4X-Large: 128 credits/hour
-- 5X-Large: 256 credits/hour
-- 6X-Large: 512 credits/hour

-- -------------------------------------------------------
-- 3. Cost Impact of Resizing
-- -------------------------------------------------------
WITH current_usage AS (
    SELECT
        warehouse_name,
        warehouse_size,
        ROUND(SUM(credits_used), 2) AS credits_30d
    FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
    WHERE start_time >= DATEADD('day', -30, CURRENT_TIMESTAMP)
    GROUP BY 1, 2
)
SELECT
    warehouse_name,
    warehouse_size                AS current_size,
    credits_30d                   AS current_credits_30d,
    -- Estimated credits at different sizes (proportional to credit rate)
    CASE warehouse_size
        WHEN 'X-Small'  THEN ROUND(credits_30d / 1 * 2, 2)   -- Small
        WHEN 'Small'    THEN ROUND(credits_30d / 2 * 1, 2)   -- X-Small
        WHEN 'Medium'   THEN ROUND(credits_30d / 4 * 2, 2)   -- Small
        WHEN 'Large'    THEN ROUND(credits_30d / 8 * 4, 2)   -- Medium
        WHEN 'X-Large'  THEN ROUND(credits_30d / 16 * 8, 2)  -- Large
        WHEN '2X-Large' THEN ROUND(credits_30d / 32 * 16, 2) -- X-Large
        ELSE NULL
    END AS credits_one_size_down,
    CASE warehouse_size
        WHEN 'X-Small'  THEN ROUND(credits_30d / 1 * 4, 2)   -- Medium
        WHEN 'Small'    THEN ROUND(credits_30d / 2 * 4, 2)   -- Medium
        WHEN 'Medium'   THEN ROUND(credits_30d / 4 * 8, 2)   -- Large
        WHEN 'Large'    THEN ROUND(credits_30d / 8 * 16, 2)  -- X-Large
        WHEN 'X-Large'  THEN ROUND(credits_30d / 16 * 32, 2) -- 2X-Large
        WHEN '2X-Large' THEN ROUND(credits_30d / 32 * 64, 2) -- 3X-Large
        ELSE NULL
    END AS credits_one_size_up
FROM current_usage
ORDER BY credits_30d DESC;
