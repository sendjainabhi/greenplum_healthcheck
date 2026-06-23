

# Greenplum Healthcheck

## Overview

**gp_healthcheck_html_v3.sh** performs 26 automated health checks across a live Greenplum 6 or 7 cluster and produces a self-contained HTML report. The report includes a scorecard, a Failure Summary panel with actionable remediation steps, a full check-by-check summary table (benchmark vs actual), collapsible raw detail logs, per-database bloat/skew diagnostics, kernel parameter compliance, and an infrastructure overview card.

All checks are **read-only** — the script never modifies the customer environment.

---

## Health Checks — 26 Checks across 7 Categories

### Cluster Health

- **GP Segments Status:** Verifies all primary segments are up and in sync. Flags any segment that is down or has failed over.

- **Mirror Segment Status:** Confirms all mirror segments are synchronized with their primaries. Detects out-of-sync or failed mirrors that leave the cluster without redundancy.

- **Standby Coordinator Status:** Checks whether a standby coordinator is configured and actively replicating. Reports as a suggestion if no standby is present — a single coordinator is a single point of failure.

- **Replication Lag:** Measures the WAL replay lag between the primary coordinator and its standby. Excessive lag means the standby is behind and failover would lose recent transactions.

- **Catalog Integrity Check:** Optionally scans all databases for catalog inconsistencies such as orphaned objects and broken internal references. Skipped if the user opts out at runtime — recommended to run off-peak as it can be time-consuming on large clusters.

### Database Reliability

- **XID Wraparound Risk:** Checks how close each database is to transaction ID exhaustion. Left unaddressed, wraparound causes Greenplum to shut down the database to prevent data corruption.

- **Connection Saturation:** Reports how much of the available connection capacity is in use. A saturated connection pool causes new sessions to be rejected and applications to queue or fail.

- **Long Running Queries:** Detects queries that have been running for more than one hour and sessions stuck idle inside an open transaction. Both conditions hold locks and consume resources unnecessarily.

- **Lock Waits:** Identifies sessions that are blocked waiting for a lock held by another session. Persistent lock waits indicate contention that can cascade into a cluster-wide slowdown.

### Storage & Maintenance

- **Disk Free:** Checks available disk space on every host in the cluster. Any host below 25% free space risks segment crashes and data loss when Greenplum cannot write new data.

- **Tables Needing VACUUM:** Identifies tables with a large number of deleted or updated rows that have not been cleaned up. Accumulated dead rows bloat table size and degrade query performance over time.

- **Data Bloat and Skew per Database:** Checks every database for two common storage problems. Bloat flags tables that are significantly larger than their actual data content — a sign that VACUUM or reorganization is overdue. Skew flags tables whose data is unevenly spread across segments, which forces some segments to do most of the work and limits the benefit of parallel processing.

### OS / Infrastructure

- **CPU Usage:** Requires Greenplum Command Center. Checks 30-day average and peak CPU utilisation per host. Consistently high CPU indicates workload saturation or runaway queries.

- **Transparent Huge Pages:** Checks the Linux memory page setting on every host. When set to always, Transparent Huge Pages causes latency spikes and is explicitly unsupported by Greenplum.

- **Swap Usage:** Checks whether any host is actively using swap space. Swap usage is a sign of memory pressure — Greenplum segment processes hitting swap will run orders of magnitude slower than expected.

- **File Descriptor Limits:** Verifies the open file descriptor limit on every host. Greenplum opens many files simultaneously during query execution; too low a limit causes segment failures under normal load.

- **MTU:** Checks the network interface MTU across all hosts. Jumbo Frames (MTU 9000) are required for efficient interconnect traffic between segments — a mismatch causes unnecessary packet fragmentation.

- **Kernel Parameter Compliance:** Verifies 28 OS-level kernel settings on every host against Greenplum-recommended values. Kernel misconfiguration is one of the most common root causes of poor query performance and cluster instability, yet it is invisible from inside the database.

### Query Optimization

- **GPORCA Optimizer:** Verifies GPORCA is enabled across the coordinator and all segments. GPORCA is Greenplum's cost-based optimizer and produces significantly better query plans than the legacy planner for analytical workloads.

- **Random Distribution Tables:** Detects user tables that distribute rows randomly across segments. Random distribution forces a full data reshuffle on every join involving these tables, eliminating the performance benefit of co-located joins.

- **Stale Statistics:** Identifies tables with a large number of live rows whose statistics have not been refreshed recently. The query planner relies on statistics to choose join strategies and scan methods — stale statistics lead to bad plans and slow queries.

- **Planner GUC Settings:** Checks key query planner configuration parameters against Greenplum-recommended values. Incorrect planner settings can silently disable optimizations like hash joins, multi-phase aggregation, and partition pruning.

- **Workfile Spill:** Detects queries currently spilling intermediate data to disk because they exceeded their memory allocation. Spilling queries run significantly slower and compete for disk I/O with other workloads.

### Configuration

- **Resource Group and Memory Parameters:** Checks memory and resource management configuration parameters against recommended values. Misconfigured memory limits lead to out-of-memory errors under load or underutilisation of available RAM.

### Security

- **Trust Authentication:** Scans the host-based authentication configuration for rules that allow remote connections without a password. Trust rules are appropriate only for local administrative access — remote trust rules are a significant security exposure.

- **Privileged Roles:** Checks for excessive superuser accounts and login roles with no password set. Superuser proliferation and passwordless accounts are the most common access control gaps in Greenplum deployments.

---

## Additional Diagnostics

- **Per-Database Detail Logs:** Collapsible sections per database showing top skewed tables, idle-fraction tables, missing statistics, top 20 bloated tables with wasted space, table distribution keys, installed extensions, and database size.

- **Cluster Component Detail Logs:** Collapsible raw output for all 26 checks — the exact command output that determined each PASS/FAIL result.

---

## Deployment Guide

Run the script during off-peak hours. The optional catalog integrity check can be time-consuming on large clusters with many databases.

### Prerequisites

- Log in to the Greenplum coordinator host as `gpadmin`
- Have the Greenplum port number ready (default: 5432)
- Have a hostfile listing all cluster hosts (one hostname per line)
- Source the Greenplum environment (`source /usr/local/greenplum-db/greenplum_path.sh`)

### Execution

```bash
# Clone the repository
git clone https://github.com/sendjainabhi/greenplum_healthcheck.git

# Copy the script to the coordinator home directory
cp gp_healthcheck_kit/gp_healthcheck_html_v3.sh /home/gpadmin/

# Set execute permission
chmod +x /home/gpadmin/gp_healthcheck_html_v3.sh

# Run as gpadmin
/home/gpadmin/gp_healthcheck_html_v3.sh
```

The script prompts for:
1. Company name (used in report filename and title)
2. Greenplum port (default: 5432)
3. Hostfile path (auto-detected from common locations, or enter manually)
4. Whether to run the catalog integrity check (y/n)

On completion it prints the path to the generated HTML report:

```
<Company>_gp_healthcheck_report_<YYYYMMDD_HHMMSS>.html
```

### Review and Share

> **Important:** Inspect the generated report for any confidential information before sending it to the Tanzu account team.

The script is designed to minimise data exposure:
- Trust Authentication: shows only rule counts, never IP addresses or network ranges
- Privileged Roles: shows only aggregate counts, never role names or account details
