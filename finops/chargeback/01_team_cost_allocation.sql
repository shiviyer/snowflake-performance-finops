-- =============================================================================
-- Script: 01_team_cost_allocation.sql
-- Description: Allocate Snowflake costs to teams and departments
-- Source: SNOWFLAKE.ACCOUNT_USAGE
-- Prerequisites: Tag warehouses with team names using OBJECT TAGGING
--   ALTER WAREHOUSE my_wh SET TAG team = 'data_engineering';
-- =============================================================================

-- -------------------------------------------------------
-- 1. Cost Allocation by Warehouse (Team/Department Proxy)
-- -------------------------------------------------------
SELECT
    warehouse_name,
    warehouse_size,
    DATE_TRUNC('month', start_time)                       AS month,
    ROUND(SUM(credits_used), 2)                           AS total_credits,
    ROUND(SUM(credits_used_compute), 2)                   AS compute_credits,
    ROUND(SUM(credits_used_cloud_services), 2)            AS cloud_credits,
    -- Estimated cost at $3/credit - adjust to your contract rate
    ROUND(SUM(credits_used) * 3.0, 2)                     AS estimated_cost_usd
FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
WHERE start_time >= DATEADD('month', -3, CURRENT_TIMESTAMP)
GROUP BY 1, 2, 3
ORDER BY month DESC, total_credits DESC;


-- -------------------------------------------------------
-- 2. Cost Allocation via Object Tags (Recommended Approach)
-- Prerequisite: Create and assign tags to warehouses
-- -------------------------------------------------------

-- Step 1: Create tag objects
-- CREATE TAG IF NOT EXISTS team VARCHAR COMMENT 'Team or department name';
-- CREATE TAG IF NOT EXISTS cost_center VARCHAR COMMENT 'Finance cost center code';
-- CREATE TAG IF NOT EXISTS environment VARCHAR COMMENT 'prod/staging/dev/test';
-- CREATE TAG IF NOT EXISTS project VARCHAR COMMENT 'Project or initiative name';

-- Step 2: Assign tags to warehouses
-- ALTER WAREHOUSE analytics_wh SET TAG team = 'analytics', cost_center = 'CC-1234', environment = 'prod';
-- ALTER WAREHOUSE etl_wh SET TAG team = 'data_engineering', cost_center = 'CC-5678', environment = 'prod';
-- ALTER WAREHOUSE dev_wh SET TAG team = 'engineering', cost_center = 'CC-9999', environment = 'dev';

-- Step 3: Query cost by tag (once tags are set)
SELECT
    wt.tag_value                                          AS team_name,
    DATE_TRUNC('month', m.start_time)                     AS month,
    ROUND(SUM(m.credits_used), 2)                         AS total_credits,
    ROUND(SUM(m.credits_used) * 3.0, 2)                   AS estimated_cost_usd
FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY m
JOIN SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES wt
    ON wt.object_name = m.warehouse_name
    AND wt.object_database IS NULL
    AND wt.domain = 'WAREHOUSE'
    AND wt.tag_name = 'TEAM'
WHERE m.start_time >= DATEADD('month', -3, CURRENT_TIMESTAMP)
GROUP BY 1, 2
ORDER BY 2 DESC, 3 DESC;


-- -------------------------------------------------------
-- 3. Query Cost Allocation by Role (Team Proxy via Roles)
-- -------------------------------------------------------
WITH wh_hourly AS (
    SELECT
        warehouse_name,
        DATE_TRUNC('hour', start_time)                    AS hour_bucket,
        SUM(credits_used_compute)                         AS compute_credits_hour
    FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
    WHERE start_time >= DATEADD('month', -1, CURRENT_TIMESTAMP)
    GROUP BY 1, 2
),
query_hourly AS (
    SELECT
        warehouse_name,
        DATE_TRUNC('hour', start_time)                    AS hour_bucket,
        SUM(total_elapsed_time)                           AS total_wh_query_ms
    FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
    WHERE start_time >= DATEADD('month', -1, CURRENT_TIMESTAMP)
      AND execution_status = 'SUCCESS'
    GROUP BY 1, 2
)
SELECT
    q.role_name,
    COUNT(DISTINCT q.user_name)                           AS distinct_users,
    COUNT(*)                                              AS query_count,
    ROUND(AVG(q.total_elapsed_time) / 1000, 2)           AS avg_elapsed_sec,
    ROUND(SUM(q.total_elapsed_time / NULLIF(qh.total_wh_query_ms, 0)
              * wh.compute_credits_hour), 4)              AS estimated_credits,
    ROUND(SUM(q.total_elapsed_time / NULLIF(qh.total_wh_query_ms, 0)
              * wh.compute_credits_hour) * 3.0, 2)        AS estimated_cost_usd
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY q
JOIN wh_hourly wh
    ON q.warehouse_name = wh.warehouse_name
    AND DATE_TRUNC('hour', q.start_time) = wh.hour_bucket
JOIN query_hourly qh
    ON q.warehouse_name = qh.warehouse_name
    AND DATE_TRUNC('hour', q.start_time) = qh.hour_bucket
WHERE q.start_time >= DATEADD('month', -1, CURRENT_TIMESTAMP)
  AND q.execution_status = 'SUCCESS'
GROUP BY q.role_name
ORDER BY estimated_cost_usd DESC;


-- -------------------------------------------------------
-- 4. Environment Cost Split (Prod vs Dev vs Staging)
-- -------------------------------------------------------
-- Uses naming convention: warehouse names contain env keywords
SELECT
    CASE
        WHEN LOWER(warehouse_name) LIKE '%prod%'    THEN 'Production'
        WHEN LOWER(warehouse_name) LIKE '%staging%' THEN 'Staging'
        WHEN LOWER(warehouse_name) LIKE '%dev%'     THEN 'Development'
        WHEN LOWER(warehouse_name) LIKE '%test%'    THEN 'Testing'
        WHEN LOWER(warehouse_name) LIKE '%sandbox%' THEN 'Sandbox'
        ELSE 'Unclassified'
    END AS environment,
    DATE_TRUNC('month', start_time)                       AS month,
    COUNT(DISTINCT warehouse_name)                        AS warehouse_count,
    ROUND(SUM(credits_used), 2)                           AS total_credits,
    ROUND(SUM(credits_used) * 3.0, 2)                     AS estimated_cost_usd,
    ROUND(SUM(credits_used) * 100.0 /
          SUM(SUM(credits_used)) OVER
              (PARTITION BY DATE_TRUNC('month', start_time)), 2) AS pct_of_total
FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
WHERE start_time >= DATEADD('month', -3, CURRENT_TIMESTAMP)
GROUP BY 1, 2
ORDER BY 2 DESC, 4 DESC;
