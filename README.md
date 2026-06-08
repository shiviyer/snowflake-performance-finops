# Snowflake Performance Troubleshooting & FinOps Toolkit

A comprehensive collection of SQL scripts for diagnosing Snowflake performance bottlenecks and implementing FinOps strategies to reduce costs while maximizing efficiency.

## Repository Structure

- troubleshooting/query_performance/ - Query analysis and optimization scripts
- troubleshooting/warehouse_performance/ - Warehouse sizing and load scripts  
- troubleshooting/storage_performance/ - Clustering and partition scripts
- troubleshooting/network_io/ - Data transfer analysis scripts
- finops/cost_analysis/ - Credit consumption and cost tracking
- finops/cost_optimization/ - Idle warehouse and cache optimization
- finops/chargeback/ - Team and project cost allocation
- metrics/ - KPIs, SLAs and executive dashboards

## Quick Start

1. Connect to Snowflake with ACCOUNTADMIN or SYSADMIN role
2. Navigate to the relevant folder for your use case
3. Run the SQL scripts in your Snowflake worksheet or SnowSQL client

Note: Most scripts query SNOWFLAKE.ACCOUNT_USAGE views (up to 45 min latency).
For real-time data, use INFORMATION_SCHEMA equivalents where noted.

## FinOps KPIs & Targets

| Metric | Description | Target |
|--------|-------------|--------|
| Credits/Query | Average credits consumed per query | Minimize |
| Cache Hit Rate | Queries served from result cache | > 40% |
| Idle Warehouse Time | Warehouses running without queries | < 10% |
| Spillage Rate | Queries spilling to disk | < 5% |
| P95 Query Latency | 95th percentile query duration | SLA-defined |
| Queue Wait Time | Avg wait time before execution | < 10 sec |
| Partition Pruning % | Micro-partitions pruned vs scanned | > 80% |
| Failed Query Rate | Queries that fail or timeout | < 1% |

## Top 10 Cost Optimization Quick Wins

1. Enable Result Caching - eliminates 30-50% of redundant query costs
2. Right-size Warehouses - use sizing advisor to match size to workload
3. Set Aggressive Auto-Suspend - 60s for dev, 5 min for production
4. Cluster Hot Tables - on frequently filtered columns
5. Use Search Optimization - for selective point-lookups on large tables
6. Leverage Materialized Views - pre-compute expensive aggregations
7. Fix Spillage - disk spills signal under-sizing or poor clustering
8. Implement Resource Monitors - set credit quotas per warehouse
9. Tag All Resources - for cost allocation and chargeback
10. Reduce Time Travel Retention - long retention doubles storage costs

## Key Snowflake Views

| View | Schema | Description |
|------|--------|-------------|
| QUERY_HISTORY | ACCOUNT_USAGE / INFO_SCHEMA | All query executions |
| WAREHOUSE_METERING_HISTORY | ACCOUNT_USAGE | Credit consumption |
| STORAGE_USAGE | ACCOUNT_USAGE | Storage usage |
| METERING_HISTORY | ACCOUNT_USAGE | Service credit usage |
| WAREHOUSE_LOAD_HISTORY | ACCOUNT_USAGE | Warehouse load |
| TABLE_STORAGE_METRICS | ACCOUNT_USAGE | Per-table storage |
| DATA_TRANSFER_HISTORY | ACCOUNT_USAGE | Data transfer events |
| AUTOMATIC_CLUSTERING_HISTORY | ACCOUNT_USAGE | Clustering credits |

## Required Privileges

Grant IMPORTED PRIVILEGES ON DATABASE SNOWFLAKE to your monitoring role.

## License

MIT License

*Maintained by Shiv Iyer | MinervaDB & ChistaDATA*
