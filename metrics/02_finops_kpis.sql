-- =============================================================================
-- Script: 02_finops_kpis.sql
-- Description: Key FinOps metrics and KPI dashboard for Snowflake
-- Source: SNOWFLAKE.ACCOUNT_USAGE
-- Schedule: Run daily to track cost efficiency trends
-- =============================================================================

-- -------------------------------------------------------
-- 1. FinOps KPI Summary (Last 7 Days vs Previous 7 Days)
-- -------------------------------------------------------
WITH current_period AS (
    SELECT
        COUNT(*)                                          AS total_queries,
        ROUND(AVG(total_elapsed_time) / 1000, 2)         AS avg_query_sec,
        ROUND(AVG(percentage_scanned_from_cache), 2)     AS cache_hit_rate,
        ROUND(SUM(bytes_scanned) / POWER(1024, 4), 4)    AS total_tb_scanned,
        SUM(CASE WHEN bytes_spilled_to_local_storage > 0
                 OR bytes_spilled_to_remote_storage > 0 THEN 1 ELSE 0 END) AS spilled_queries,
        ROUND(SUM(CASE WHEN bytes_spilled_to_local_storage > 0
                       OR bytes_spilled_to_remote_storage > 0 THEN 1 ELSE 0 END)
              * 100.0 / COUNT(*), 2)                     AS spillage_rate_pct,
        ROUND(AVG(queued_overload_time) / 1000, 2)       AS avg_queue_sec,
        SUM(CASE WHEN execution_status = 'FAIL' THEN 1 ELSE 0 END) AS failed_queries,
        ROUND(SUM(CASE WHEN execution_status = 'FAIL' THEN 1 ELSE 0 END)
              * 100.0 / COUNT(*), 2)                     AS failure_rate_pct
    FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
    WHERE start_time >= DATEADD('day', -7, CURRENT_TIMESTAMP)
),
previous_period AS (
    SELECT
        COUNT(*)                                          AS total_queries,
        ROUND(AVG(total_elapsed_time) / 1000, 2)         AS avg_query_sec,
        ROUND(AVG(percentage_scanned_from_cache), 2)     AS cache_hit_rate,
        SUM(CASE WHEN bytes_spilled_to_local_storage > 0
                 OR bytes_spilled_to_remote_storage > 0 THEN 1 ELSE 0 END) AS spilled_queries,
        ROUND(SUM(CASE WHEN bytes_spilled_to_local_storage > 0
                       OR bytes_spilled_to_remote_storage > 0 THEN 1 ELSE 0 END)
              * 100.0 / COUNT(*), 2)                     AS spillage_rate_pct,
        ROUND(AVG(queued_overload_time) / 1000, 2)       AS avg_queue_sec
    FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
    WHERE start_time BETWEEN DATEADD('day', -14, CURRENT_TIMESTAMP)
                         AND DATEADD('day', -7, CURRENT_TIMESTAMP)
),
credit_current AS (
    SELECT
        ROUND(SUM(credits_used), 2)                      AS total_credits,
        ROUND(SUM(credits_used) / 7.0, 2)                AS daily_avg_credits
    FROM SNOWFLAKE.ACCOUNT_USAGE.METERING_HISTORY
    WHERE start_time >= DATEADD('day', -7, CURRENT_TIMESTAMP)
),
credit_previous AS (
    SELECT
        ROUND(SUM(credits_used), 2)                      AS total_credits
    FROM SNOWFLAKE.ACCOUNT_USAGE.METERING_HISTORY
    WHERE start_time BETWEEN DATEADD('day', -14, CURRENT_TIMESTAMP)
                         AND DATEADD('day', -7, CURRENT_TIMESTAMP)
)
SELECT
    -- Credit Metrics
    cc.total_credits                                      AS current_7d_credits,
    cp.total_credits                                      AS prev_7d_credits,
    ROUND((cc.total_credits - cp.total_credits) * 100.0 /
          NULLIF(cp.total_credits, 0), 2)                AS credit_wow_change_pct,
    cc.daily_avg_credits,
    -- Query Metrics
    c.total_queries                                       AS current_7d_queries,
    c.avg_query_sec,
    c.cache_hit_rate                                      AS cache_hit_pct,
    p.cache_hit_rate                                      AS prev_cache_hit_pct,
    -- Efficiency Metrics
    c.spillage_rate_pct,
    c.avg_queue_sec,
    c.failure_rate_pct,
    -- KPI Status
    CASE WHEN c.cache_hit_rate >= 40 THEN 'GOOD' WHEN c.cache_hit_rate >= 20 THEN 'OK' ELSE 'BAD' END AS cache_status,
    CASE WHEN c.spillage_rate_pct <= 5 THEN 'GOOD' WHEN c.spillage_rate_pct <= 15 THEN 'OK' ELSE 'BAD' END AS spillage_status,
    CASE WHEN c.avg_queue_sec <= 10 THEN 'GOOD' WHEN c.avg_queue_sec <= 30 THEN 'OK' ELSE 'BAD' END AS queue_status,
    CASE WHEN c.failure_rate_pct <= 1 THEN 'GOOD' WHEN c.failure_rate_pct <= 3 THEN 'OK' ELSE 'BAD' END AS failure_status
FROM current_period c, previous_period p, credit_current cc, credit_previous cp;


-- -------------------------------------------------------
-- 2. Daily FinOps Scorecard (Last 30 Days)
-- -------------------------------------------------------
SELECT
    DATE_TRUNC('day', q.start_time)                       AS metric_date,
    COUNT(*)                                              AS total_queries,
    ROUND(AVG(q.total_elapsed_time) / 1000, 2)           AS avg_elapsed_sec,
    ROUND(PERCENTILE_CONT(0.95) WITHIN GROUP
          (ORDER BY q.total_elapsed_time) / 1000, 2)     AS p95_elapsed_sec,
    ROUND(AVG(q.percentage_scanned_from_cache), 2)       AS cache_hit_pct,
    ROUND(SUM(CASE WHEN q.bytes_spilled_to_local_storage > 0
                   OR q.bytes_spilled_to_remote_storage > 0 THEN 1 ELSE 0 END)
          * 100.0 / COUNT(*), 2)                         AS spillage_rate_pct,
    ROUND(AVG(q.queued_overload_time) / 1000, 2)         AS avg_queue_sec,
    ROUND(SUM(CASE WHEN q.execution_status = 'FAIL' THEN 1 ELSE 0 END)
          * 100.0 / COUNT(*), 2)                         AS failure_rate_pct,
    ROUND(SUM(m.credits_used), 4)                        AS daily_credits,
    ROUND(SUM(m.credits_used) * 3.0, 2)                  AS daily_cost_usd_estimate
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY q
LEFT JOIN (
    SELECT DATE_TRUNC('day', start_time) AS day, SUM(credits_used) AS credits_used
    FROM SNOWFLAKE.ACCOUNT_USAGE.METERING_HISTORY
    WHERE start_time >= DATEADD('day', -30, CURRENT_TIMESTAMP)
    GROUP BY 1
) m ON DATE_TRUNC('day', q.start_time) = m.day
WHERE q.start_time >= DATEADD('day', -30, CURRENT_TIMESTAMP)
GROUP BY 1
ORDER BY 1 DESC;


-- -------------------------------------------------------
-- 3. FinOps Maturity Score
-- -------------------------------------------------------
WITH metrics AS (
    SELECT
        ROUND(AVG(percentage_scanned_from_cache), 2)     AS cache_hit_rate,
        ROUND(SUM(CASE WHEN bytes_spilled_to_remote_storage > 0 THEN 1 ELSE 0 END)
              * 100.0 / COUNT(*), 2)                     AS remote_spill_rate,
        ROUND(AVG(queued_overload_time) / 1000, 2)       AS avg_queue_sec,
        ROUND(SUM(CASE WHEN execution_status = 'FAIL' THEN 1 ELSE 0 END)
              * 100.0 / COUNT(*), 2)                     AS failure_rate,
        ROUND(AVG(partitions_scanned) / NULLIF(AVG(partitions_total), 0) * 100, 2) AS avg_partition_scan_pct
    FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
    WHERE start_time >= DATEADD('day', -7, CURRENT_TIMESTAMP)
      AND execution_status IN ('SUCCESS', 'FAIL')
)
SELECT
    -- Score each metric 0-25
    CASE WHEN cache_hit_rate >= 50 THEN 25
         WHEN cache_hit_rate >= 30 THEN 15
         WHEN cache_hit_rate >= 10 THEN 5
         ELSE 0 END                                       AS cache_score,
    CASE WHEN remote_spill_rate <= 1 THEN 25
         WHEN remote_spill_rate <= 5 THEN 15
         WHEN remote_spill_rate <= 10 THEN 5
         ELSE 0 END                                       AS spillage_score,
    CASE WHEN avg_queue_sec <= 5 THEN 25
         WHEN avg_queue_sec <= 15 THEN 15
         WHEN avg_queue_sec <= 30 THEN 5
         ELSE 0 END                                       AS queue_score,
    CASE WHEN failure_rate <= 0.5 THEN 25
         WHEN failure_rate <= 2 THEN 15
         WHEN failure_rate <= 5 THEN 5
         ELSE 0 END                                       AS reliability_score,
    -- Total FinOps maturity score (0-100)
    (CASE WHEN cache_hit_rate >= 50 THEN 25 WHEN cache_hit_rate >= 30 THEN 15 WHEN cache_hit_rate >= 10 THEN 5 ELSE 0 END +
     CASE WHEN remote_spill_rate <= 1 THEN 25 WHEN remote_spill_rate <= 5 THEN 15 WHEN remote_spill_rate <= 10 THEN 5 ELSE 0 END +
     CASE WHEN avg_queue_sec <= 5 THEN 25 WHEN avg_queue_sec <= 15 THEN 15 WHEN avg_queue_sec <= 30 THEN 5 ELSE 0 END +
     CASE WHEN failure_rate <= 0.5 THEN 25 WHEN failure_rate <= 2 THEN 15 WHEN failure_rate <= 5 THEN 5 ELSE 0 END) AS total_finops_score,
    cache_hit_rate,
    remote_spill_rate,
    avg_queue_sec,
    failure_rate,
    avg_partition_scan_pct
FROM metrics;
