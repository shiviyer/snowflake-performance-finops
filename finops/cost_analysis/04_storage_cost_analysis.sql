-- =============================================================================
-- Script: 04_storage_cost_analysis.sql
-- Description: Analyze Snowflake storage costs and identify optimization opportunities
-- Source: SNOWFLAKE.ACCOUNT_USAGE
-- Note: Snowflake storage ~$23/TB/month (on-demand). Adjust for your contract.
-- =============================================================================

-- -------------------------------------------------------
-- 1. Overall Storage Usage Trend (Last 90 Days)
-- -------------------------------------------------------
SELECT
    USAGE_DATE,
    ROUND(STORAGE_BYTES / 1099511627776, 4)                AS database_storage_tb,
    ROUND(STAGE_BYTES / 1099511627776, 4)                  AS stage_storage_tb,
    ROUND(FAILSAFE_BYTES / 1099511627776, 4)               AS failsafe_storage_tb,
    ROUND((STORAGE_BYTES + STAGE_BYTES + FAILSAFE_BYTES)
          / 1099511627776, 4)                              AS total_storage_tb,
    -- Estimated monthly cost at $23/TB/month
    ROUND((STORAGE_BYTES + STAGE_BYTES + FAILSAFE_BYTES)
          / 1099511627776 * 23.0, 2)                       AS estimated_monthly_cost_usd
FROM SNOWFLAKE.ACCOUNT_USAGE.STORAGE_USAGE
WHERE USAGE_DATE >= DATEADD('day', -90, CURRENT_DATE)
ORDER BY USAGE_DATE DESC;


-- -------------------------------------------------------
-- 2. Per-Database Storage Breakdown
-- -------------------------------------------------------
SELECT
    TABLE_CATALOG                                          AS database_name,
    COUNT(DISTINCT TABLE_SCHEMA)                           AS schema_count,
    COUNT(*)                                              AS table_count,
    ROUND(SUM(ACTIVE_BYTES) / 1099511627776, 4)           AS active_storage_tb,
    ROUND(SUM(TIME_TRAVEL_BYTES) / 1099511627776, 4)      AS time_travel_tb,
    ROUND(SUM(FAILSAFE_BYTES) / 1099511627776, 4)         AS failsafe_tb,
    ROUND(SUM(RETAINED_FOR_CLONE_BYTES) / 1099511627776, 4) AS clone_retained_tb,
    ROUND((SUM(ACTIVE_BYTES) + SUM(TIME_TRAVEL_BYTES) +
           SUM(FAILSAFE_BYTES) + SUM(RETAINED_FOR_CLONE_BYTES))
          / 1099511627776, 4)                             AS total_billable_tb,
    -- Time Travel as % of active storage
    ROUND(SUM(TIME_TRAVEL_BYTES) * 100.0 /
          NULLIF(SUM(ACTIVE_BYTES), 0), 2)                AS time_travel_pct_of_active
FROM SNOWFLAKE.ACCOUNT_USAGE.TABLE_STORAGE_METRICS
WHERE DELETED = FALSE
GROUP BY 1
ORDER BY total_billable_tb DESC;


-- -------------------------------------------------------
-- 3. Largest Tables by Total Storage (Top 50)
-- -------------------------------------------------------
SELECT
    TABLE_CATALOG                                         AS database_name,
    TABLE_SCHEMA,
    TABLE_NAME,
    ROW_COUNT,
    ROUND(ACTIVE_BYTES / 1073741824, 2)                  AS active_gb,
    ROUND(TIME_TRAVEL_BYTES / 1073741824, 2)             AS time_travel_gb,
    ROUND(FAILSAFE_BYTES / 1073741824, 2)                AS failsafe_gb,
    ROUND((ACTIVE_BYTES + TIME_TRAVEL_BYTES + FAILSAFE_BYTES) / 1073741824, 2) AS total_billable_gb,
    -- Time Travel multiplier (how much extra overhead Time Travel adds)
    ROUND((TIME_TRAVEL_BYTES + FAILSAFE_BYTES) * 100.0 /
          NULLIF(ACTIVE_BYTES, 0), 2)                    AS overhead_pct,
    DATA_RETENTION_TIME_IN_DAYS                          AS time_travel_days
FROM SNOWFLAKE.ACCOUNT_USAGE.TABLE_STORAGE_METRICS
WHERE DELETED = FALSE
  AND ACTIVE_BYTES > 0
ORDER BY total_billable_gb DESC
LIMIT 50;


-- -------------------------------------------------------
-- 4. Tables with High Time Travel Overhead (Optimization Candidates)
-- -------------------------------------------------------
SELECT
    TABLE_CATALOG,
    TABLE_SCHEMA,
    TABLE_NAME,
    DATA_RETENTION_TIME_IN_DAYS                           AS retention_days,
    ROUND(ACTIVE_BYTES / 1073741824, 2)                  AS active_gb,
    ROUND(TIME_TRAVEL_BYTES / 1073741824, 2)             AS time_travel_gb,
    ROUND(FAILSAFE_BYTES / 1073741824, 2)                AS failsafe_gb,
    ROUND(TIME_TRAVEL_BYTES * 100.0 / NULLIF(ACTIVE_BYTES, 0), 2) AS tt_pct_of_active,
    -- Potential savings if retention reduced to 1 day
    ROUND((TIME_TRAVEL_BYTES - ACTIVE_BYTES * 0.05) / 1073741824, 2) AS potential_savings_gb,
    CASE
        WHEN DATA_RETENTION_TIME_IN_DAYS = 90
             AND TIME_TRAVEL_BYTES > ACTIVE_BYTES * 2
             THEN 'HIGH: Reduce retention to 7-30 days'
        WHEN DATA_RETENTION_TIME_IN_DAYS > 30
             AND TIME_TRAVEL_BYTES > ACTIVE_BYTES
             THEN 'MEDIUM: Consider reducing retention'
        ELSE 'REVIEW'
    END AS recommendation
FROM SNOWFLAKE.ACCOUNT_USAGE.TABLE_STORAGE_METRICS
WHERE DELETED = FALSE
  AND ACTIVE_BYTES > 1073741824  -- tables > 1 GB
  AND TIME_TRAVEL_BYTES > ACTIVE_BYTES * 0.5  -- TT > 50% of active
ORDER BY TIME_TRAVEL_BYTES DESC
LIMIT 30;


-- -------------------------------------------------------
-- 5. Stage Storage Analysis
-- -------------------------------------------------------
SELECT
    STAGE_CATALOG,
    STAGE_SCHEMA,
    STAGE_NAME,
    STAGE_URL,
    STAGE_REGION,
    STAGE_TYPE,
    COMMENT
FROM SNOWFLAKE.ACCOUNT_USAGE.STAGES
ORDER BY STAGE_CATALOG, STAGE_SCHEMA, STAGE_NAME;

-- Check internal stage usage (requires warehouse)
-- SELECT SYSTEM$ESTIMATE_QUERY_ACCELERATION(query_id);
