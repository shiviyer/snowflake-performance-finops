-- =============================================================================
-- Script: 04_concurrency_scaling_analysis.sql
-- Description: Analyze concurrency scaling usage, triggers, and cost
-- Source: SNOWFLAKE.ACCOUNT_USAGE
-- =============================================================================

-- -------------------------------------------------------
-- 1. Concurrency Scaling Credit Usage (Last 30 Days)
-- -------------------------------------------------------
SELECT
    DATE_TRUNC('day', start_time)                         AS day,
    warehouse_name,
    ROUND(SUM(credits_used), 4)                           AS scaling_credits,
    ROUND(SUM(credits_used) * 3.0, 2)                     AS scaling_cost_usd,
    -- Note: First 1 credit/warehouse/day is free for most editions
    ROUND(GREATEST(SUM(credits_used) - 1, 0) * 3.0, 2)  AS billable_scaling_cost_usd
FROM SNOWFLAKE.ACCOUNT_USAGE.METERING_HISTORY
WHERE service_type = 'CLOUD_SERVICES'
  AND start_time >= DATEADD('day', -30, CURRENT_TIMESTAMP)
GROUP BY 1, 2
ORDER BY 1 DESC, 3 DESC;


-- -------------------------------------------------------
-- 2. When Concurrency Scaling Triggered (Last 7 Days)
-- -------------------------------------------------------
SELECT
    DATE_TRUNC('hour', start_time)                        AS hour_bucket,
    warehouse_name,
    ROUND(AVG(avg_running), 2)                            AS avg_running_queries,
    ROUND(AVG(avg_queued_load), 2)                        AS avg_queued_load,
    ROUND(MAX(avg_queued_load), 2)                        AS peak_queued_load
FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_LOAD_HISTORY
WHERE start_time >= DATEADD('day', -7, CURRENT_TIMESTAMP)
  AND avg_queued_load > 0
GROUP BY 1, 2
ORDER BY peak_queued_load DESC
LIMIT 30;


-- -------------------------------------------------------
-- 3. Queries Served by Concurrency Scaling
-- -------------------------------------------------------
SELECT
    warehouse_name,
    COUNT(*)                                              AS total_queries,
    ROUND(AVG(total_elapsed_time) / 1000, 2)             AS avg_elapsed_sec,
    ROUND(AVG(queued_overload_time) / 1000, 2)           AS avg_queue_sec,
    ROUND(SUM(queued_overload_time) / 3600000, 2)        AS total_queue_hours,
    MIN(start_time)                                       AS first_occurrence,
    MAX(start_time)                                       AS last_occurrence
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
WHERE start_time >= DATEADD('day', -7, CURRENT_TIMESTAMP)
  AND execution_status = 'SUCCESS'
  AND queued_overload_time > 5000  -- queued > 5 sec (likely needed scaling)
GROUP BY 1
ORDER BY total_queue_hours DESC;


-- -------------------------------------------------------
-- 4. Concurrency Scaling vs Multi-Cluster Warehouse Decision
-- -------------------------------------------------------
-- If you frequently have queued queries, consider:
-- Option A: Increase warehouse size (more resources, single cluster)
-- Option B: Enable multi-cluster warehouse (scales out automatically)
-- Option C: Concurrency scaling (auto, pay per use)
--
-- Decision matrix:
-- - Predictable peak loads       -> Multi-cluster with min/max clusters
-- - Unpredictable burst loads    -> Concurrency scaling
-- - Consistently underutilized   -> Scale down or reduce clusters
-- - Always at capacity           -> Scale up primary cluster

SELECT
    warehouse_name,
    ROUND(AVG(avg_running), 2)       AS avg_concurrent,
    ROUND(MAX(avg_running), 2)       AS peak_concurrent,
    ROUND(AVG(avg_queued_load), 4)   AS avg_queue,
    ROUND(MAX(avg_queued_load), 2)   AS peak_queue,
    CASE
        WHEN AVG(avg_queued_load) > 1 AND MAX(avg_queued_load) > 5
             THEN 'MULTI-CLUSTER: Regular heavy queuing - enable multi-cluster warehouse'
        WHEN MAX(avg_queued_load) > 3
             THEN 'SCALING: Occasional spikes - concurrency scaling adequate'
        WHEN AVG(avg_running) < 0.5 AND MAX(avg_queued_load) < 0.5
             THEN 'OVER-SIZED: Very low utilization, consider smaller warehouse'
        ELSE 'NORMAL: Current configuration acceptable'
    END AS recommendation
FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_LOAD_HISTORY
WHERE start_time >= DATEADD('day', -30, CURRENT_TIMESTAMP)
GROUP BY 1
ORDER BY avg_queue DESC;


-- -------------------------------------------------------
-- 5. Concurrency Scaling Cost by Warehouse (Last 30 Days)
-- -------------------------------------------------------
WITH scaling_usage AS (
    SELECT
        warehouse_name,
        DATE_TRUNC('day', start_time)                     AS day,
        SUM(credits_used)                                 AS daily_credits
    FROM SNOWFLAKE.ACCOUNT_USAGE.METERING_HISTORY
    WHERE service_type = 'CLOUD_SERVICES'
      AND start_time >= DATEADD('day', -30, CURRENT_TIMESTAMP)
    GROUP BY 1, 2
)
SELECT
    warehouse_name,
    COUNT(DISTINCT day)                                   AS days_with_scaling,
    ROUND(SUM(daily_credits), 4)                         AS total_scaling_credits,
    ROUND(AVG(daily_credits), 4)                         AS avg_daily_scaling_credits,
    ROUND(MAX(daily_credits), 4)                         AS peak_daily_scaling_credits,
    ROUND(SUM(daily_credits) * 3.0, 2)                   AS total_scaling_cost_usd
FROM scaling_usage
GROUP BY 1
ORDER BY total_scaling_cost_usd DESC;
