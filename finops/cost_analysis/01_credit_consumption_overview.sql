-- =============================================================================
-- Script: 01_credit_consumption_overview.sql
-- Description: Overall credit usage breakdown by service type
-- Source: SNOWFLAKE.ACCOUNT_USAGE.METERING_HISTORY
-- =============================================================================

-- -------------------------------------------------------
-- 1. Monthly Credit Consumption by Service Type
-- -------------------------------------------------------
SELECT
    DATE_TRUNC('month', start_time)                    AS month,
    service_type,
    ROUND(SUM(credits_used), 2)                        AS total_credits,
    ROUND(SUM(credits_used) * 100.0 /
          SUM(SUM(credits_used)) OVER (PARTITION BY DATE_TRUNC('month', start_time)), 2)
                                                       AS pct_of_monthly_total
FROM SNOWFLAKE.ACCOUNT_USAGE.METERING_HISTORY
WHERE start_time >= DATEADD('month', -6, CURRENT_TIMESTAMP)
GROUP BY 1, 2
ORDER BY 1 DESC, 3 DESC;


-- -------------------------------------------------------
-- 2. Daily Credit Burn Rate (Last 30 Days)
-- -------------------------------------------------------
SELECT
    DATE_TRUNC('day', start_time)                      AS day,
    ROUND(SUM(credits_used), 2)                        AS daily_credits,
    ROUND(SUM(CASE WHEN service_type = 'WAREHOUSE_METERING'
              THEN credits_used ELSE 0 END), 2)        AS warehouse_credits,
    ROUND(SUM(CASE WHEN service_type = 'CLOUD_SERVICES'
              THEN credits_used ELSE 0 END), 2)        AS cloud_services_credits,
    ROUND(SUM(CASE WHEN service_type = 'AUTO_CLUSTERING'
              THEN credits_used ELSE 0 END), 2)        AS clustering_credits,
    ROUND(SUM(CASE WHEN service_type = 'MATERIALIZED_VIEW'
              THEN credits_used ELSE 0 END), 2)        AS materialized_view_credits,
    ROUND(SUM(CASE WHEN service_type = 'SEARCH_OPTIMIZATION'
              THEN credits_used ELSE 0 END), 2)        AS search_opt_credits,
    ROUND(SUM(CASE WHEN service_type = 'SERVERLESS_TASK'
              THEN credits_used ELSE 0 END), 2)        AS serverless_task_credits,
    ROUND(SUM(CASE WHEN service_type = 'PIPE'
              THEN credits_used ELSE 0 END), 2)        AS pipe_credits,
    ROUND(SUM(CASE WHEN service_type = 'SNOWPIPE_STREAMING'
              THEN credits_used ELSE 0 END), 2)        AS streaming_credits
FROM SNOWFLAKE.ACCOUNT_USAGE.METERING_HISTORY
WHERE start_time >= DATEADD('day', -30, CURRENT_TIMESTAMP)
GROUP BY 1
ORDER BY 1 DESC;


-- -------------------------------------------------------
-- 3. Credit Consumption YoY/MoM Comparison
-- -------------------------------------------------------
SELECT
    DATE_TRUNC('month', start_time)                    AS month,
    ROUND(SUM(credits_used), 2)                        AS total_credits,
    LAG(ROUND(SUM(credits_used), 2)) OVER
        (ORDER BY DATE_TRUNC('month', start_time))     AS prev_month_credits,
    ROUND((SUM(credits_used) -
           LAG(SUM(credits_used)) OVER
               (ORDER BY DATE_TRUNC('month', start_time)))
          * 100.0 /
          NULLIF(LAG(SUM(credits_used)) OVER
                     (ORDER BY DATE_TRUNC('month', start_time)), 0), 2) AS mom_growth_pct
FROM SNOWFLAKE.ACCOUNT_USAGE.METERING_HISTORY
WHERE start_time >= DATEADD('month', -12, CURRENT_TIMESTAMP)
GROUP BY 1
ORDER BY 1 DESC;


-- -------------------------------------------------------
-- 4. Credit Projection (30-day forecast based on 7-day average)
-- -------------------------------------------------------
WITH recent_daily AS (
    SELECT
        DATE_TRUNC('day', start_time)                  AS day,
        SUM(credits_used)                              AS daily_credits
    FROM SNOWFLAKE.ACCOUNT_USAGE.METERING_HISTORY
    WHERE start_time >= DATEADD('day', -7, CURRENT_TIMESTAMP)
    GROUP BY 1
),
stats AS (
    SELECT
        ROUND(AVG(daily_credits), 2)                   AS avg_daily_credits,
        ROUND(AVG(daily_credits) * 30, 2)              AS projected_30d,
        ROUND(AVG(daily_credits) * 365, 2)             AS projected_annual
    FROM recent_daily
)
SELECT
    avg_daily_credits,
    projected_30d                                      AS projected_next_30_days,
    projected_annual                                   AS projected_annual,
    -- Cost estimate (adjust :credit_price to your contract rate)
    ROUND(projected_30d * 3.0, 2)                      AS estimated_30d_cost_usd_at_3,
    ROUND(projected_30d * 4.0, 2)                      AS estimated_30d_cost_usd_at_4
FROM stats;


-- -------------------------------------------------------
-- 5. Cloud Services Credit Check (free tier = 10% of compute)
-- -------------------------------------------------------
SELECT
    DATE_TRUNC('day', start_time)                      AS day,
    ROUND(SUM(CASE WHEN service_type = 'WAREHOUSE_METERING'
              THEN credits_used ELSE 0 END), 4)        AS compute_credits,
    ROUND(SUM(CASE WHEN service_type = 'CLOUD_SERVICES'
              THEN credits_used ELSE 0 END), 4)        AS cloud_service_credits,
    ROUND(SUM(CASE WHEN service_type = 'CLOUD_SERVICES'
              THEN credits_used ELSE 0 END)
          * 100.0 /
          NULLIF(SUM(CASE WHEN service_type = 'WAREHOUSE_METERING'
                     THEN credits_used ELSE 0 END), 0), 2) AS cloud_pct_of_compute,
    CASE
        WHEN SUM(CASE WHEN service_type = 'CLOUD_SERVICES'
                 THEN credits_used ELSE 0 END)
             > SUM(CASE WHEN service_type = 'WAREHOUSE_METERING'
                   THEN credits_used ELSE 0 END) * 0.10
        THEN 'ALERT: Cloud services exceed 10% free threshold'
        ELSE 'OK: Within free tier'
    END AS cloud_services_status
FROM SNOWFLAKE.ACCOUNT_USAGE.METERING_HISTORY
WHERE start_time >= DATEADD('day', -30, CURRENT_TIMESTAMP)
GROUP BY 1
HAVING cloud_service_credits > 0
ORDER BY 1 DESC;
