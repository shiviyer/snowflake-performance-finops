-- =============================================================================
-- Script: 05_executive_summary.sql
-- Description: Executive-level Snowflake performance and cost summary
-- Schedule: Run weekly / monthly for leadership reporting
-- Source: SNOWFLAKE.ACCOUNT_USAGE
-- =============================================================================

-- -------------------------------------------------------
-- 1. Monthly Executive Summary (Last 3 Months)
-- -------------------------------------------------------
WITH monthly_queries AS (
    SELECT
        DATE_TRUNC('month', start_time)                   AS month,
        COUNT(*)                                          AS total_queries,
        COUNT(DISTINCT user_name)                         AS active_users,
        ROUND(AVG(total_elapsed_time) / 1000, 2)         AS avg_elapsed_sec,
        ROUND(PERCENTILE_CONT(0.95) WITHIN GROUP
              (ORDER BY total_elapsed_time) / 1000, 2)   AS p95_elapsed_sec,
        ROUND(AVG(percentage_scanned_from_cache), 2)     AS cache_hit_rate,
        ROUND(SUM(CASE WHEN bytes_spilled_to_local_storage > 0
                       OR bytes_spilled_to_remote_storage > 0 THEN 1 ELSE 0 END)
              * 100.0 / COUNT(*), 2)                     AS spillage_pct,
        ROUND(SUM(CASE WHEN execution_status = 'FAIL' THEN 1 ELSE 0 END)
              * 100.0 / COUNT(*), 2)                     AS failure_rate_pct
    FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
    WHERE start_time >= DATEADD('month', -3, CURRENT_TIMESTAMP)
    GROUP BY 1
),
monthly_costs AS (
    SELECT
        DATE_TRUNC('month', start_time)                   AS month,
        ROUND(SUM(credits_used), 2)                       AS total_credits,
        ROUND(SUM(CASE WHEN service_type = 'WAREHOUSE_METERING'
                  THEN credits_used ELSE 0 END), 2)       AS compute_credits,
        ROUND(SUM(CASE WHEN service_type = 'AUTO_CLUSTERING'
                  THEN credits_used ELSE 0 END), 2)       AS clustering_credits,
        ROUND(SUM(CASE WHEN service_type = 'MATERIALIZED_VIEW'
                  THEN credits_used ELSE 0 END), 2)       AS mv_credits,
        ROUND(SUM(credits_used) * 3.0, 2)                 AS estimated_cost_usd
    FROM SNOWFLAKE.ACCOUNT_USAGE.METERING_HISTORY
    WHERE start_time >= DATEADD('month', -3, CURRENT_TIMESTAMP)
    GROUP BY 1
),
monthly_storage AS (
    SELECT
        DATE_TRUNC('month', USAGE_DATE)                   AS month,
        ROUND(AVG(STORAGE_BYTES + FAILSAFE_BYTES) / 1099511627776, 4) AS avg_storage_tb,
        ROUND(AVG(STORAGE_BYTES + FAILSAFE_BYTES) / 1099511627776 * 23.0, 2) AS storage_cost_usd
    FROM SNOWFLAKE.ACCOUNT_USAGE.STORAGE_USAGE
    WHERE USAGE_DATE >= DATEADD('month', -3, CURRENT_DATE)
    GROUP BY 1
)
SELECT
    q.month,
    -- Usage Metrics
    q.total_queries,
    q.active_users,
    -- Performance Metrics
    q.avg_elapsed_sec,
    q.p95_elapsed_sec,
    q.cache_hit_rate                                      AS cache_hit_pct,
    q.spillage_pct,
    q.failure_rate_pct,
    -- Cost Metrics
    c.total_credits,
    c.estimated_cost_usd                                  AS compute_cost_usd,
    s.storage_cost_usd,
    ROUND(c.estimated_cost_usd + s.storage_cost_usd, 2)  AS total_estimated_cost_usd,
    -- Efficiency Ratio (queries per credit = value for money)
    ROUND(q.total_queries / NULLIF(c.total_credits, 0), 2) AS queries_per_credit
FROM monthly_queries q
LEFT JOIN monthly_costs c ON q.month = c.month
LEFT JOIN monthly_storage s ON q.month = s.month
ORDER BY 1 DESC;


-- -------------------------------------------------------
-- 2. Top 5 Cost Drivers (Last 30 Days)
-- -------------------------------------------------------
SELECT
    'COMPUTE' AS cost_type,
    warehouse_name AS resource_name,
    ROUND(SUM(credits_used), 2) AS credits,
    ROUND(SUM(credits_used) * 3.0, 2) AS estimated_usd
FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
WHERE start_time >= DATEADD('day', -30, CURRENT_TIMESTAMP)
GROUP BY 2
UNION ALL
SELECT
    'STORAGE',
    'TOTAL',
    NULL,
    ROUND(AVG(STORAGE_BYTES + FAILSAFE_BYTES) / 1099511627776 * 23.0, 2)
FROM SNOWFLAKE.ACCOUNT_USAGE.STORAGE_USAGE
WHERE USAGE_DATE >= DATEADD('day', -30, CURRENT_DATE)
ORDER BY estimated_usd DESC
LIMIT 10;


-- -------------------------------------------------------
-- 3. Cost Optimization Opportunities Summary
-- -------------------------------------------------------
WITH savings AS (
    -- Idle warehouse credits
    SELECT
        'Idle Warehouse Credits (30d)' AS opportunity,
        ROUND(SUM(CASE WHEN COALESCE(q.query_count, 0) = 0 THEN c.credits ELSE 0 END) * 3.0, 2) AS potential_savings_usd
    FROM (SELECT warehouse_name, DATE_TRUNC('hour', start_time) AS h,
                 SUM(credits_used) AS credits
          FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
          WHERE start_time >= DATEADD('day', -30, CURRENT_TIMESTAMP)
          GROUP BY 1, 2) c
    LEFT JOIN (SELECT warehouse_name, DATE_TRUNC('hour', start_time) AS h, COUNT(*) AS query_count
               FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
               WHERE start_time >= DATEADD('day', -30, CURRENT_TIMESTAMP)
               GROUP BY 1, 2) q
        ON c.warehouse_name = q.warehouse_name AND c.h = q.h
    UNION ALL
    -- Spillage cost (queries that could be fixed with better sizing/clustering)
    SELECT
        'Remote Spillage Credits (30d)',
        ROUND(COUNT(*) * 0.1 * 3.0, 2)  -- rough estimate: 0.1 extra credits per spilled query
    FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
    WHERE start_time >= DATEADD('day', -30, CURRENT_TIMESTAMP)
      AND bytes_spilled_to_remote_storage > 1073741824  -- > 1GB remote spill
    UNION ALL
    -- Reducible Time Travel storage
    SELECT
        'Reducible Time Travel Storage (monthly)',
        ROUND(SUM(TIME_TRAVEL_BYTES * 0.7) / 1099511627776 * 23.0, 2)  -- 70% reduction possible
    FROM SNOWFLAKE.ACCOUNT_USAGE.TABLE_STORAGE_METRICS
    WHERE DATA_RETENTION_TIME_IN_DAYS > 7
      AND TIME_TRAVEL_BYTES > ACTIVE_BYTES
      AND DELETED = FALSE
)
SELECT
    opportunity,
    potential_savings_usd,
    'Review scripts in finops/cost_optimization/ for details' AS action
FROM savings
ORDER BY potential_savings_usd DESC;


-- -------------------------------------------------------
-- 4. Resource Monitor Status
-- -------------------------------------------------------
SHOW RESOURCE MONITORS;

-- After SHOW RESOURCE MONITORS, check if all warehouses have monitors:
-- SELECT "name", "credit_quota", "frequency", "start_time", "end_time", 
--        "notify_at", "suspend_at", "suspend_immediately_at"
-- FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));
