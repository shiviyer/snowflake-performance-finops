-- =============================================================================
-- Script: 03_cost_per_query.sql
-- Description: Attribute credit costs to individual queries, users, and teams
-- Source: SNOWFLAKE.ACCOUNT_USAGE
-- Note: Set :credit_price to your Snowflake contract price per credit
-- =============================================================================

-- -------------------------------------------------------
-- 1. Cost Attribution Per Query (Last 7 Days)
-- Methodology: credit cost = (query_execution_time / warehouse_total_time) * warehouse_credits * credit_price
-- -------------------------------------------------------
WITH wh_hourly AS (
    SELECT
        warehouse_name,
        DATE_TRUNC('hour', start_time)                    AS hour_bucket,
        SUM(credits_used_compute)                         AS compute_credits_hour
    FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
    WHERE start_time >= DATEADD('day', -7, CURRENT_TIMESTAMP)
    GROUP BY 1, 2
),
query_hourly AS (
    SELECT
        warehouse_name,
        DATE_TRUNC('hour', start_time)                    AS hour_bucket,
        SUM(total_elapsed_time)                           AS total_wh_query_ms
    FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
    WHERE start_time >= DATEADD('day', -7, CURRENT_TIMESTAMP)
      AND execution_status = 'SUCCESS'
    GROUP BY 1, 2
),
query_cost AS (
    SELECT
        q.query_id,
        q.query_text,
        q.user_name,
        q.role_name,
        q.warehouse_name,
        q.warehouse_size,
        q.query_type,
        q.database_name,
        q.schema_name,
        q.total_elapsed_time,
        q.bytes_scanned,
        wh.compute_credits_hour,
        qh.total_wh_query_ms,
        -- Pro-rate credits by query share of warehouse time
        ROUND(q.total_elapsed_time / NULLIF(qh.total_wh_query_ms, 0)
              * wh.compute_credits_hour, 6)               AS estimated_credits,
        ROUND(q.total_elapsed_time / NULLIF(qh.total_wh_query_ms, 0)
              * wh.compute_credits_hour * 3.0, 4)         AS estimated_cost_usd,  -- adjust $3/credit
        q.start_time
    FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY q
    JOIN wh_hourly wh
        ON q.warehouse_name = wh.warehouse_name
        AND DATE_TRUNC('hour', q.start_time) = wh.hour_bucket
    JOIN query_hourly qh
        ON q.warehouse_name = qh.warehouse_name
        AND DATE_TRUNC('hour', q.start_time) = qh.hour_bucket
    WHERE q.start_time >= DATEADD('day', -7, CURRENT_TIMESTAMP)
      AND q.execution_status = 'SUCCESS'
)
SELECT
    query_id,
    SUBSTR(query_text, 1, 200)                            AS query_text_preview,
    user_name,
    role_name,
    warehouse_name,
    warehouse_size,
    query_type,
    ROUND(total_elapsed_time / 1000, 2)                   AS elapsed_seconds,
    ROUND(bytes_scanned / 1073741824, 4)                  AS gb_scanned,
    estimated_credits,
    estimated_cost_usd,
    start_time
FROM query_cost
ORDER BY estimated_cost_usd DESC
LIMIT 50;


-- -------------------------------------------------------
-- 2. Cost Per User (Last 30 Days)
-- -------------------------------------------------------
WITH wh_hourly AS (
    SELECT
        warehouse_name,
        DATE_TRUNC('hour', start_time)                    AS hour_bucket,
        SUM(credits_used_compute)                         AS compute_credits_hour
    FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
    WHERE start_time >= DATEADD('day', -30, CURRENT_TIMESTAMP)
    GROUP BY 1, 2
),
query_hourly AS (
    SELECT
        warehouse_name,
        DATE_TRUNC('hour', start_time)                    AS hour_bucket,
        SUM(total_elapsed_time)                           AS total_wh_query_ms
    FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
    WHERE start_time >= DATEADD('day', -30, CURRENT_TIMESTAMP)
      AND execution_status = 'SUCCESS'
    GROUP BY 1, 2
)
SELECT
    q.user_name,
    COUNT(*)                                              AS query_count,
    ROUND(AVG(q.total_elapsed_time) / 1000, 2)           AS avg_elapsed_sec,
    ROUND(SUM(q.total_elapsed_time / NULLIF(qh.total_wh_query_ms, 0)
              * wh.compute_credits_hour), 4)              AS estimated_total_credits,
    ROUND(SUM(q.total_elapsed_time / NULLIF(qh.total_wh_query_ms, 0)
              * wh.compute_credits_hour) * 3.0, 2)        AS estimated_total_cost_usd
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY q
JOIN wh_hourly wh
    ON q.warehouse_name = wh.warehouse_name
    AND DATE_TRUNC('hour', q.start_time) = wh.hour_bucket
JOIN query_hourly qh
    ON q.warehouse_name = qh.warehouse_name
    AND DATE_TRUNC('hour', q.start_time) = qh.hour_bucket
WHERE q.start_time >= DATEADD('day', -30, CURRENT_TIMESTAMP)
  AND q.execution_status = 'SUCCESS'
GROUP BY q.user_name
ORDER BY estimated_total_cost_usd DESC
LIMIT 25;


-- -------------------------------------------------------
-- 3. Cost by Query Type (Last 30 Days)
-- -------------------------------------------------------
SELECT
    q.query_type,
    COUNT(*)                                              AS query_count,
    ROUND(SUM(q.total_elapsed_time / NULLIF(qh.total_wh_query_ms, 0)
              * wh.compute_credits_hour), 2)              AS estimated_credits,
    ROUND(SUM(q.total_elapsed_time / NULLIF(qh.total_wh_query_ms, 0)
              * wh.compute_credits_hour) * 3.0, 2)        AS estimated_cost_usd,
    ROUND(AVG(q.total_elapsed_time) / 1000, 2)           AS avg_elapsed_sec
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY q
JOIN (SELECT warehouse_name, DATE_TRUNC('hour', start_time) AS hour_bucket,
             SUM(credits_used_compute) AS compute_credits_hour
      FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
      WHERE start_time >= DATEADD('day', -30, CURRENT_TIMESTAMP)
      GROUP BY 1, 2) wh
    ON q.warehouse_name = wh.warehouse_name
    AND DATE_TRUNC('hour', q.start_time) = wh.hour_bucket
JOIN (SELECT warehouse_name, DATE_TRUNC('hour', start_time) AS hour_bucket,
             SUM(total_elapsed_time) AS total_wh_query_ms
      FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
      WHERE start_time >= DATEADD('day', -30, CURRENT_TIMESTAMP)
        AND execution_status = 'SUCCESS'
      GROUP BY 1, 2) qh
    ON q.warehouse_name = qh.warehouse_name
    AND DATE_TRUNC('hour', q.start_time) = qh.hour_bucket
WHERE q.start_time >= DATEADD('day', -30, CURRENT_TIMESTAMP)
  AND q.execution_status = 'SUCCESS'
GROUP BY q.query_type
ORDER BY estimated_cost_usd DESC;
