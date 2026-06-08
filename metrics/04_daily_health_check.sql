-- =============================================================================
-- Script: 04_daily_health_check.sql
-- Description: Comprehensive daily health check for Snowflake performance & cost
-- Schedule: Run at the start of each business day
-- Source: SNOWFLAKE.ACCOUNT_USAGE + INFORMATION_SCHEMA
-- =============================================================================

-- -------------------------------------------------------
-- Section 1: Yesterday's Summary
-- -------------------------------------------------------
SELECT
    '=== YESTERDAY SUMMARY ===' AS section,
    '' AS metric, '' AS value, '' AS status, '' AS notes;

SELECT
    metric,
    value,
    target,
    status
FROM (
    SELECT
        'Total Queries (Yesterday)'                       AS metric,
        COUNT(*)::VARCHAR                                 AS value,
        '>= 1'                                            AS target,
        'INFO'                                            AS status
    FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
    WHERE start_time >= DATEADD('day', -1, CURRENT_DATE)
      AND start_time < CURRENT_DATE
    UNION ALL
    SELECT
        'Failed Queries'                                  AS metric,
        SUM(CASE WHEN execution_status = 'FAIL' THEN 1 ELSE 0 END)::VARCHAR,
        '< 1%',
        CASE WHEN SUM(CASE WHEN execution_status = 'FAIL' THEN 1 ELSE 0 END) * 100.0 / COUNT(*) < 1 THEN 'OK'
             WHEN SUM(CASE WHEN execution_status = 'FAIL' THEN 1 ELSE 0 END) * 100.0 / COUNT(*) < 3 THEN 'WARN'
             ELSE 'CRITICAL' END
    FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
    WHERE start_time >= DATEADD('day', -1, CURRENT_DATE)
      AND start_time < CURRENT_DATE
    UNION ALL
    SELECT
        'Avg Query Duration (sec)',
        ROUND(AVG(total_elapsed_time) / 1000, 2)::VARCHAR,
        'N/A (baseline)',
        'INFO'
    FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
    WHERE start_time >= DATEADD('day', -1, CURRENT_DATE)
      AND start_time < CURRENT_DATE
      AND execution_status = 'SUCCESS'
    UNION ALL
    SELECT
        'P95 Query Duration (sec)',
        ROUND(PERCENTILE_CONT(0.95) WITHIN GROUP (ORDER BY total_elapsed_time) / 1000, 2)::VARCHAR,
        'SLA-defined',
        'INFO'
    FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
    WHERE start_time >= DATEADD('day', -1, CURRENT_DATE)
      AND start_time < CURRENT_DATE
      AND execution_status = 'SUCCESS'
    UNION ALL
    SELECT
        'Result Cache Hit Rate (%)',
        ROUND(AVG(percentage_scanned_from_cache), 2)::VARCHAR,
        '>= 40%',
        CASE WHEN AVG(percentage_scanned_from_cache) >= 40 THEN 'OK'
             WHEN AVG(percentage_scanned_from_cache) >= 20 THEN 'WARN'
             ELSE 'LOW' END
    FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
    WHERE start_time >= DATEADD('day', -1, CURRENT_DATE)
      AND start_time < CURRENT_DATE
      AND execution_status = 'SUCCESS'
    UNION ALL
    SELECT
        'Queries with Spillage (%)',
        ROUND(SUM(CASE WHEN bytes_spilled_to_local_storage > 0
                       OR bytes_spilled_to_remote_storage > 0 THEN 1 ELSE 0 END)
              * 100.0 / COUNT(*), 2)::VARCHAR,
        '< 5%',
        CASE WHEN SUM(CASE WHEN bytes_spilled_to_local_storage > 0 OR bytes_spilled_to_remote_storage > 0 THEN 1 ELSE 0 END) * 100.0 / COUNT(*) <= 5 THEN 'OK'
             WHEN SUM(CASE WHEN bytes_spilled_to_local_storage > 0 OR bytes_spilled_to_remote_storage > 0 THEN 1 ELSE 0 END) * 100.0 / COUNT(*) <= 15 THEN 'WARN'
             ELSE 'CRITICAL' END
    FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
    WHERE start_time >= DATEADD('day', -1, CURRENT_DATE)
      AND start_time < CURRENT_DATE
      AND execution_status = 'SUCCESS'
    UNION ALL
    SELECT
        'Credits Used (Yesterday)',
        ROUND(SUM(credits_used), 2)::VARCHAR,
        '< daily_budget',
        'INFO'
    FROM SNOWFLAKE.ACCOUNT_USAGE.METERING_HISTORY
    WHERE start_time >= DATEADD('day', -1, CURRENT_DATE)
      AND start_time < CURRENT_DATE
);


-- -------------------------------------------------------
-- Section 2: Currently Running (Real-time)
-- -------------------------------------------------------
SELECT
    'CURRENTLY RUNNING QUERIES' AS section,
    COUNT(*)                    AS total_running,
    SUM(CASE WHEN DATEDIFF('minute', start_time, CURRENT_TIMESTAMP) > 30
             THEN 1 ELSE 0 END) AS running_over_30min,
    SUM(CASE WHEN DATEDIFF('minute', start_time, CURRENT_TIMESTAMP) > 60
             THEN 1 ELSE 0 END) AS running_over_60min
FROM TABLE(INFORMATION_SCHEMA.QUERY_HISTORY_BY_SESSION(
    RESULT_LIMIT => 10000,
    END_TIME_RANGE_START => DATEADD('hour', -2, CURRENT_TIMESTAMP)
))
WHERE execution_status = 'RUNNING';


-- -------------------------------------------------------
-- Section 3: Top Issues to Investigate Today
-- -------------------------------------------------------
-- Top 10 Long-running queries from yesterday
SELECT
    'TOP SLOW QUERIES YESTERDAY'                          AS issue_type,
    query_id,
    SUBSTR(query_text, 1, 100)                            AS query_preview,
    user_name,
    warehouse_name,
    ROUND(total_elapsed_time / 60000, 2)                  AS elapsed_minutes
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
WHERE start_time >= DATEADD('day', -1, CURRENT_DATE)
  AND start_time < CURRENT_DATE
  AND total_elapsed_time > 300000  -- > 5 min
ORDER BY total_elapsed_time DESC
LIMIT 5;


-- -------------------------------------------------------
-- Section 4: Warehouse Status (Last 24h Credits)
-- -------------------------------------------------------
SELECT
    warehouse_name,
    warehouse_size,
    ROUND(SUM(credits_used), 2)                           AS credits_24h,
    ROUND(SUM(credits_used) * 3.0, 2)                     AS cost_usd_24h,
    ROUND(SUM(credits_used_cloud_services) * 100.0 /
          NULLIF(SUM(credits_used_compute), 0), 2)        AS cloud_pct_of_compute
FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
WHERE start_time >= DATEADD('hour', -24, CURRENT_TIMESTAMP)
GROUP BY 1, 2
ORDER BY credits_24h DESC;
