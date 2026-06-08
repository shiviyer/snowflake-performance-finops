-- =============================================================================
-- Script: 05_blocking_queries.sql
-- Description: Identify blocking queries, lock waits, and transaction conflicts
-- Source: INFORMATION_SCHEMA (real-time) + ACCOUNT_USAGE
-- =============================================================================

-- -------------------------------------------------------
-- 1. Currently Blocked Queries (Real-time)
-- -------------------------------------------------------
SELECT
    query_id,
    query_text,
    user_name,
    role_name,
    warehouse_name,
    database_name,
    schema_name,
    execution_status,
    DATEDIFF('second', start_time, CURRENT_TIMESTAMP) AS waiting_seconds,
    start_time,
    blocked_by
FROM TABLE(INFORMATION_SCHEMA.QUERY_HISTORY_BY_SESSION(
    RESULT_LIMIT => 1000
))
WHERE execution_status = 'BLOCKED'
ORDER BY waiting_seconds DESC;


-- -------------------------------------------------------
-- 2. Transaction Lock History (Last 24 Hours)
--    Note: Requires ACCOUNTADMIN or SYSADMIN role
-- -------------------------------------------------------
SELECT
    query_id,
    SUBSTR(query_text, 1, 200)                       AS query_text_preview,
    user_name,
    role_name,
    warehouse_name,
    execution_status,
    ROUND(total_elapsed_time / 1000, 2)              AS elapsed_seconds,
    ROUND(queued_repair_time / 1000, 2)              AS repair_queue_seconds,
    transaction_blocked_time,
    start_time,
    end_time
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
WHERE start_time >= DATEADD('hour', -24, CURRENT_TIMESTAMP)
  AND transaction_blocked_time > 0
ORDER BY transaction_blocked_time DESC
LIMIT 50;


-- -------------------------------------------------------
-- 3. Lock Contention by Table (Last 7 Days)
-- -------------------------------------------------------
SELECT
    t.table_catalog,
    t.table_schema,
    t.table_name,
    COUNT(DISTINCT q.query_id)                        AS blocked_queries,
    ROUND(AVG(q.transaction_blocked_time) / 1000, 2) AS avg_blocked_seconds,
    ROUND(SUM(q.transaction_blocked_time) / 1000, 2) AS total_blocked_seconds
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY q
JOIN SNOWFLAKE.ACCOUNT_USAGE.ACCESS_HISTORY ah
    ON q.query_id = ah.query_id
JOIN SNOWFLAKE.ACCOUNT_USAGE.TABLES t
    ON ah.objects_modified[0]:objectId::STRING = t.table_id::STRING
WHERE q.start_time >= DATEADD('day', -7, CURRENT_TIMESTAMP)
  AND q.transaction_blocked_time > 0
GROUP BY 1, 2, 3
ORDER BY total_blocked_seconds DESC
LIMIT 20;


-- -------------------------------------------------------
-- 4. Long-running Transactions (Active right now)
-- -------------------------------------------------------
SHOW TRANSACTIONS;

-- After SHOW TRANSACTIONS, query it:
SELECT *
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
WHERE state = 'running'
  AND DATEDIFF('minute', transaction_started_on, CURRENT_TIMESTAMP) > 10
ORDER BY transaction_started_on ASC;


-- -------------------------------------------------------
-- 5. Queries Waiting on Provisioning vs Overload
-- -------------------------------------------------------
SELECT
    DATE_TRUNC('hour', start_time)                   AS hour_bucket,
    warehouse_name,
    SUM(queued_overload_time)                        AS total_overload_ms,
    SUM(queued_provisioning_time)                    AS total_provisioning_ms,
    SUM(queued_repair_time)                          AS total_repair_ms,
    COUNT(CASE WHEN queued_overload_time > 0 THEN 1 END)      AS overload_count,
    COUNT(CASE WHEN queued_provisioning_time > 0 THEN 1 END)  AS provisioning_count,
    COUNT(*)                                         AS total_queries
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
WHERE start_time >= DATEADD('day', -7, CURRENT_TIMESTAMP)
  AND execution_status = 'SUCCESS'
GROUP BY 1, 2
HAVING total_overload_ms + total_provisioning_ms > 0
ORDER BY 1 DESC, total_overload_ms DESC;
