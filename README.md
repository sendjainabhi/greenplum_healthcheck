

# Greenplum Healthcheck

## Overview

**gp_healthcheck_html_v3.sh** performs 24 automated health checks across a live Greenplum 6 or 7 cluster and produces a self-contained HTML report. The report includes a scorecard, a Failure Summary panel with actionable remediation steps, a full check-by-check summary table (benchmark vs actual), collapsible raw detail logs, per-database bloat/skew diagnostics, kernel parameter compliance, and an infrastructure overview card.

All checks are **read-only** — the script never modifies the customer environment.

---

## Health Checks — 24 Checks across 7 Categories

### Cluster Health

- **GP Segments Status:** Runs `gpstate -s` to verify all primary segments are up and in sync. Flags any segment showing as down or failed.

- **Mirror Segment Status:** Runs `gpstate -m` to confirm all mirror segments are synchronized with their primaries. Detects out-of-sync or failed mirrors.

- **Standby Coordinator Status:** Runs `gpstate -f` to check whether a standby coordinator is configured and actively replicating. Reports as a suggestion if no standby is present.

- **Replication Lag:** Queries `pg_stat_replication` for the maximum WAL/xlog lag between the primary coordinator and its standby. Fails if lag exceeds 100 MB.

- **Catalog Integrity Check:** Optionally runs `gpcheckcat -g -A` against all databases to detect catalog inconsistencies such as orphaned objects, foreign-key violations, and unique-index violations. Skipped if the user opts out at runtime (recommended to run off-peak).

### Database Reliability

- **XID Wraparound Risk:** Queries `pg_database` for the maximum transaction ID age across all databases. Warns above 500 million XIDs; critical above 1.5 billion (approaching forced shutdown).

- **Connection Saturation:** Reports current vs maximum connections from `pg_stat_activity`. Fails if connection usage exceeds 80% of `max_connections`.

- **Long Running Queries:** Detects queries active for more than 1 hour and sessions idle-in-transaction for more than 30 minutes via `pg_stat_activity`.

- **Lock Waits:** Detects ungranted locks in `pg_locks` and reports blocked/blocking query pairs with wait duration.

### Storage & Maintenance

- **Disk Free:** Uses `gpssh` to run `df -h` across all cluster hosts. Fails if any host has less than 25% free disk space on any mounted filesystem.

- **Tables Needing VACUUM:** Queries `pg_stat_user_tables` for tables with more than 10,000 dead tuples or tables with live rows that have never been vacuumed.

### OS / Infrastructure

- **CPU Usage:** Requires Greenplum Command Center (GPCC). Queries `gpmetrics.gpcc_system_history` for 30-day average and peak CPU utilisation per host. Skipped if GPCC is not installed.

- **Transparent Huge Pages:** Reads `/sys/kernel/mm/transparent_hugepage/enabled` on each host via `gpssh`. Fails if THP is set to `always` on any host (causes query latency spikes).

- **Swap Usage:** Runs `free -m` on all cluster hosts via `gpssh`. Fails if any host is using swap (indicates memory pressure).

- **File Descriptor Limits:** Checks `ulimit -n` on each host via `gpssh`. Fails if any host has a file descriptor limit below 524,288.

- **MTU:** Reads `ip link show` MTU values across all cluster hosts. Reports a suggestion if any interface is below 9000 (Jumbo Frames not configured).

### Query Optimization

- **GPORCA Optimizer:** Runs `gpconfig -s optimizer` to verify GPORCA is enabled on both the coordinator and all segments. GPORCA is required for optimal query planning on GP6+.

- **Random Distribution Tables:** Detects user tables that use `DISTRIBUTED RANDOMLY` (GP7: `policytype='r'`; GP6: `attrnums IS NULL`). Random distribution causes full data redistribution on every join.

- **Stale Statistics:** Queries `pg_stat_user_tables` for tables with more than 10,000 live rows whose statistics have not been updated in the last 7 days.

- **Planner GUC Settings:** Checks 8 planner-related GUC parameters against Greenplum-recommended values: `optimizer`, `optimizer_analyze_root_partition`, `gp_enable_multiphase_agg`, `enable_hashjoin`, `enable_nestloop`, `enable_bitmapscan`, `gp_interconnect_type`, and `default_statistics_target`.

- **Workfile Spill:** Queries `gp_toolkit.gp_workfile_usage_per_query` for queries currently spilling to disk. Skipped if the view is unavailable on the running GP version.

### Configuration

- **Resource Group and Memory Param:** Reads 7 memory and resource management GUC parameters via `gpconfig -s`: `gp_vmem_protect_limit`, `statement_mem`, `max_statement_mem`, `shared_buffers`, `gp_resgroup_memory_policy`, `gp_resource_manager`, and (GP6 only) `gp_instrument_shmem_size`.

### Security

- **Trust Authentication:** Checks `pg_hba.conf` for non-local `trust` authentication rules that allow passwordless remote connections. GP7 uses `pg_hba_file_rules`; GP6 reads the file directly. Only counts are reported — IP ranges and network topology are never included in the HTML report.

- **Privileged Roles:** Counts superuser roles, login roles without passwords, and total login roles via `pg_roles`/`pg_authid`. Fails if more than 2 superusers exist or more than 1 login role has no password set. Role names are never included in the HTML report — only aggregate counts.

---

## Additional Diagnostics (not part of the 24 checks)

- **Data Bloat / Skew per Database:** Summary table showing bloat ratio (via `gp_toolkit.gp_bloat_diag`) and skew coefficient (via `gp_toolkit.gp_skew_coefficients`) for every non-template database.

- **Kernel Parameter Compliance:** Compares 28 OS-level `sysctl` kernel parameters on each host against the Greenplum-recommended baseline.

- **Per-Database Detail Logs:** Collapsible sections per database showing top skewed tables, idle-fraction tables, missing statistics, bloat details, table distribution keys, installed extensions, and database size.

- **Cluster Component Detail Logs:** Collapsible raw output for all 24 checks — the exact command output that determined each PASS/FAIL result.

---

## Deployment Guide

Run the script during off-peak hours. The optional `gpcheckcat` step can be time-consuming on large clusters with many databases.

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
4. Whether to run `gpcheckcat` (y/n)

On completion it prints the path to the generated HTML report:

```
<Company>_gp_healthcheck_report_<YYYYMMDD_HHMMSS>.html
```

### Review and Share

> **Important:** Inspect the generated report for any confidential information before sending it to the Tanzu account team.

The script is designed to minimise data exposure:
- Trust Authentication: shows only rule counts, never IP addresses or network ranges
- Privileged Roles: shows only aggregate counts, never role names or account details
