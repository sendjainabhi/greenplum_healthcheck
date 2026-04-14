


# Greenplum Healthcheck

## Greenplum Health Tests 

In the Greenplum we perform following tests 

### Cluster & Infrastructure Tests
- **GP Segments Status:** Verifies the operational state of primary segments, including their configuration status and database connectivity.

- **Standby Coordinator Status:** Checks if a standby coordinator instance is configured and confirms its replication status via pg_stat_replication.

- **Mirror Segment Status:** Reviews the list of mirror segments to ensure they are synchronized with primaries and operating in the correct roles.

- **Catalog Integrity Check:** Runs a suite of 14 sub-tests (such as unique_index_violation, foreign_key, and orphaned_toast_tables) to identify inconsistencies in the system catalog.

- **Node Disk Free:** Monitors disk space across all hosts to ensure partition usage remains below critical thresholds.

- **CPU Usage:** Analyzes average and maximum CPU metrics (User, System, and Idle) across the cluster nodes.

- **MTU:** Inspects the Maximum Transmission Unit settings on network interfaces to ensure they are optimized for high-performance data transfer.

- **Resource Group and Memory Param:** Validates that Global Configuration Parameters (GUCs) for memory management—such as shared_buffers and statement_mem—are consistent across all segments.

- Kernel Parameter Compliance: Compares OS-level kernel settings on each host against a defined baseline for Greenplum compatibility.

### Database Performance & Health Tests
- **Data Skew Test:** Measures data distribution across segments by calculating the skew coefficient (skccoeff) and idle fractions to find tables that are not evenly distributed.

- **Data Bloat Test:** Examines tables using gp_toolkit.gp_bloat_diag to find "bloat" (wasted space) that may require a VACUUM or REORGANIZE.

- **Missing Stats Test:** Scans for tables that are missing optimizer statistics, which can lead to poor query plan generation.

- **Extension Verification:** Checks for the presence and versions of required extensions (like gp_toolkit etc) within each specific database.

## Deployment Guide

It is recommended to run the Greenplum Healthcheck script in a restrictive mode and
during off-peak hours. This approach is advised because certain operations, such as
`gpcheckcat` and functions like `gp_size_of_table_disk`, can be time-consuming,
especially in a production environment.

### Prerequisites  

Ensure you have the following information ready:
- The Greenplum Port Number.
- The full file path to the GP Hosts file.

### Execution Instructions
Perform the following steps on your Greenplum coordination host:
- Log In: Log in to your Greenplum environment using the `gpadmin` user.
- Clone the Git repository `https://github.com/sendjainabhi/greenplum_healthcheck.git`
- Copy the `/scripts/gp_healthcheck_html.sh` script into your Greenplum coordination host’s `/home/gpadmin/` directory.
- Set Permissions: Assign execute permission to the script: `chmod +x gp_healthcheck_html.sh`
- Execute: Run the script: gp_healthcheck.sh. Wait for the process to finish. This will
generate a log file named `gp_healthcheck_report_<timestamp>.html`
- Review and Share: Inspect the generated report file for any confidential information
before submitting it to the Tanzu account team.
- Send the file to the Tanzu account team for review
