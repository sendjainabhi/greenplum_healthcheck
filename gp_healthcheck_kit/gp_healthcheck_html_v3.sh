#!/bin/bash

# --------------------------------------------------
# SCRIPT: gp_healthcheck_html.sh V 3.0
# AUTHOR: Abhishek Jain (Tanzu Product Value Engineering)
# DATE: June 2026
# DESCRIPTION: Greenplum Health Check HTML Report.
#              24 checks across Cluster, DB Reliability, OS/Infra,
#              Query Optimization, Configuration, and Security.
#              Benchmark vs Actual shown for every check.
# COMPATIBLE:  Greenplum 6 & 7 (RHEL 7 / 8 / 9)
# --------------------------------------------------

TIMEOUT_SEC=60

# ─────────────────────────────────────────────────────────────
# 1.  SAFETY CHECK
# ─────────────────────────────────────────────────────────────
check_user() {
    if [[ $USER != "gpadmin" ]]; then
        echo "ERROR: Must run as gpadmin"; exit 1
    fi
}
check_user

# ─────────────────────────────────────────────────────────────
# 2.  INPUTS
# ─────────────────────────────────────────────────────────────
while [[ -z "$Company" ]]; do
    read -p "What is your company name: " Company
done

while [[ -z "$GP_PORT" ]]; do
    read -p "Enter GPDB port (default 5432): " GP_PORT
    GP_PORT=${GP_PORT:-5432}
    if ! [[ "$GP_PORT" =~ ^[0-9]+$ ]]; then
        echo "Port must be a number."; GP_PORT=""
    fi
done

# ── Hostfile: find by GP hostname content (cdw/mdw/sdw*) or prompt manually ──
echo ""
echo "Searching for Greenplum hostfiles..."
mapfile -t CANDIDATE_FILES < <(
    grep -rlE "^[[:space:]]*(cdw|scdw|mdw|smdw|sdw[0-9])" /home/gpadmin "$HOME" 2>/dev/null \
    | grep -vE "\.(html|log|sh|py|conf|rpm|deb|jar|so|gz|tar|zip|sql|sh)$" \
    | sort -u | head -10
)

if [[ ${#CANDIDATE_FILES[@]} -gt 0 ]]; then
    echo "Found potential hostfiles:"
    for i in "${!CANDIDATE_FILES[@]}"; do
        echo "  [$((i+1))] ${CANDIDATE_FILES[$i]}"
    done
    echo "  [0] Enter path manually"
    echo ""
    read -p "Select [1-${#CANDIDATE_FILES[@]}] or 0: " HSEL
    if [[ "$HSEL" =~ ^[1-9][0-9]*$ && "$HSEL" -le "${#CANDIDATE_FILES[@]}" ]]; then
        GPHOSTFILE_PATH="${CANDIDATE_FILES[$((HSEL-1))]}"
        echo "Using: $GPHOSTFILE_PATH"
    fi
else
    echo "No files with GP hostnames found — enter path manually."
fi

while [[ -z "$GPHOSTFILE_PATH" || ! -f "$GPHOSTFILE_PATH" ]]; do
    read -e -p "Enter full path to hostfile: " GPHOSTFILE_PATH
    [[ ! -f "$GPHOSTFILE_PATH" ]] && echo "  File not found: $GPHOSTFILE_PATH" && GPHOSTFILE_PATH=""
done

# ── Catalog check prompt ──
while true; do
    read -r -p 'Run gpcheckcat (catalog integrity)? Heavy — recommended off-peak (y/n): ' GP_CHECK
    case "${GP_CHECK,,}" in y|yes) GP_CHECK=Y; break ;; n|no) GP_CHECK=N; break ;;
        *) echo "Please answer y or n." ;; esac
done

echo ""
echo "Starting Greenplum Health Check V3..."

# ─────────────────────────────────────────────────────────────
# 3.  GREENPLUM VERSION DETECTION
# ─────────────────────────────────────────────────────────────
GP_FULL_VERSION=$(psql -p "$GP_PORT" -t -A -c "SELECT version();" 2>/dev/null | head -1)
GP_MAJOR_VERSION=$(echo "$GP_FULL_VERSION" | grep -oE 'Greenplum Database [0-9]+' | grep -oE '[0-9]+$' || echo "unknown")
HOST_COUNT=$(grep -cvE "^[[:space:]]*#|^[[:space:]]*$" "$GPHOSTFILE_PATH" 2>/dev/null; true)
HOST_COUNT=${HOST_COUNT:-"?"}

# ── Infrastructure data for overview panel ──
COORD_HOST=$(psql -p "$GP_PORT" -t -A -c \
    "SELECT hostname FROM gp_segment_configuration WHERE content=-1 AND role='p';" 2>/dev/null | xargs)
STANDBY_HOST=$(psql -p "$GP_PORT" -t -A -c \
    "SELECT hostname FROM gp_segment_configuration WHERE content=-1 AND role='m';" 2>/dev/null | xargs)
PRIMARY_SEG_COUNT=$(psql -p "$GP_PORT" -t -A -c \
    "SELECT count(*) FROM gp_segment_configuration WHERE content<>-1 AND role='p';" 2>/dev/null | xargs)
PRIMARY_SEG_COUNT=${PRIMARY_SEG_COUNT:-0}
SEG_HOST_COUNT=$(psql -p "$GP_PORT" -t -A -c \
    "SELECT count(DISTINCT hostname) FROM gp_segment_configuration WHERE content<>-1;" 2>/dev/null | xargs)
SEG_HOST_COUNT=${SEG_HOST_COUNT:-0}
SEGS_PER_HOST=$(psql -p "$GP_PORT" -t -A -c \
    "SELECT coalesce(count(*)/nullif(count(DISTINCT hostname),0), 0) FROM gp_segment_configuration WHERE content<>-1 AND role='p';" \
    2>/dev/null | xargs)
SEGS_PER_HOST=${SEGS_PER_HOST:-0}
MIRRORS_STATUS=$(psql -p "$GP_PORT" -t -A -c \
    "SELECT CASE WHEN count(*)>0 THEN 'Enabled' ELSE 'Not configured' END FROM gp_segment_configuration WHERE content!=-1 AND role='m';" \
    2>/dev/null | xargs)
DB_COUNT=$(psql -p "$GP_PORT" -t -A -c \
    "SELECT count(*) FROM pg_database WHERE datistemplate=false;" 2>/dev/null | xargs)
TOTAL_DATA_SIZE=$(psql -p "$GP_PORT" -t -A -c \
    "SELECT pg_size_pretty(sum(pg_database_size(datname))::bigint) FROM pg_database WHERE datistemplate=false;" \
    2>/dev/null | xargs)
MAX_CONN=$(psql -p "$GP_PORT" -t -A -c \
    "SELECT setting FROM pg_settings WHERE name='max_connections';" 2>/dev/null | xargs)
GP_RESOURCE_MGR=$(psql -p "$GP_PORT" -t -A -c \
    "SELECT setting FROM pg_settings WHERE name='gp_resource_manager';" 2>/dev/null | xargs)
CLUSTER_START=$(psql -p "$GP_PORT" -t -A -c \
    "SELECT to_char(pg_postmaster_start_time(),'YYYY-MM-DD HH24:MI:SS');" 2>/dev/null | xargs)
OS_INFRA=$(grep "^PRETTY_NAME" /etc/os-release 2>/dev/null | cut -d'"' -f2 \
         || cat /etc/redhat-release 2>/dev/null || echo "Unknown")
KERNEL_VER=$(uname -r 2>/dev/null || echo "Unknown")

TS=$(date +%Y%m%d_%H%M%S)
HTML="/home/gpadmin/${Company}_gp_healthcheck_report_${TS}.html"

# ─────────────────────────────────────────────────────────────
# 4.  START HTML  +  CSS
# ─────────────────────────────────────────────────────────────
cat > "$HTML" <<'HTMLEOF'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Greenplum Health Report</title>
<style>
/* ── Reset & base ── */
*, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }
body   { font-family: "Segoe UI", Arial, sans-serif; background: #f0f2f5;
         color: #1a1a2e; font-size: 14px; line-height: 1.5; }

/* ── Top nav bar ── */
.topnav { position: sticky; top: 0; z-index: 100; background: #002855;
          display: flex; gap: 4px; padding: 6px 16px; flex-wrap: wrap;
          box-shadow: 0 2px 6px rgba(0,0,0,0.3); }
.topnav a { color: #a8c6f0; text-decoration: none; padding: 4px 10px;
            border-radius: 4px; font-size: 0.82em; white-space: nowrap; }
.topnav a:hover { background: #1a4a8a; color: white; }
.topnav .logo  { color: white; font-weight: bold; font-size: 0.9em;
                 margin-right: 10px; align-self: center; }

/* ── Page header ── */
.page-header { background: linear-gradient(135deg,#004d99,#002855);
               padding: 18px 24px; color: white; }
.page-header h1 { font-size: 1.5em; margin-bottom: 6px; }
.page-header .meta { font-size: 0.82em; color: #b0c8e8; }

/* ── Version strip ── */
.ver-strip { background: #dce6f5; border-left: 4px solid #004d99;
             padding: 8px 20px; font-size: 0.85em; color: #333; }

/* ── Scorecard ── */
.scorecard { display: flex; gap: 12px; padding: 14px 16px; flex-wrap: wrap;
             background: #fff; border-bottom: 1px solid #dde; }
.score-box { flex: 1; min-width: 120px; border-radius: 8px; padding: 12px 8px;
             text-align: center; color: white; font-weight: bold;
             font-size: 1.6em; box-shadow: 0 2px 6px rgba(0,0,0,0.12); }
.score-box span { display: block; font-size: 0.42em; font-weight: normal;
                  letter-spacing: 1px; text-transform: uppercase; margin-top: 4px; }
.s-fail { background: #c0392b; }
.s-pass { background: #27ae60; }
.s-skip { background: #e67e22; }

/* ── Banners ── */
.banner { padding: 12px 20px; margin: 12px 16px; border-radius: 6px;
          font-size: 1em; font-weight: bold; }
.banner-fail { background: #fdedec; color: #922b21;
               border-left: 6px solid #c0392b; }
.banner-pass { background: #eafaf1; color: #1e8449;
               border-left: 6px solid #27ae60; }

/* ── Section card ── */
.section { background: white; margin: 14px 16px; border-radius: 8px;
           box-shadow: 0 1px 4px rgba(0,0,0,0.08); overflow: hidden; }
.section-header { padding: 10px 16px; color: white; font-weight: bold;
                  font-size: 1em; display: flex; align-items: center; gap: 8px; }
.section-body   { padding: 14px 16px; }
.sh-blue   { background: #004d99; }
.sh-teal   { background: #0e7c7b; }
.sh-purple { background: #6c3483; }
.sh-orange { background: #ca6f1e; }
.sh-green  { background: #1e8449; }
.sh-red    { background: #922b21; }
.sh-gray   { background: #566573; }

/* ── Summary table ── */
table   { border-collapse: collapse; width: 100%; font-size: 0.88em; }
th, td  { border: 1px solid #d5d8dc; padding: 7px 10px;
          vertical-align: top; text-align: left; }
th      { background: #dce6f1; color: #003366; font-weight: 600; }

/* Category separator rows */
.cat-row td { background: #f2f3f4; color: #555; font-weight: bold;
              font-size: 0.8em; letter-spacing: 1px; text-transform: uppercase;
              padding: 5px 10px; border-top: 2px solid #bbb; }

/* Row-level colours */
.r-pass td { background: #f0faf4; }
.r-fail td { background: #fdf2f2; }
.r-skip td { background: #fef9ee; }
.r-fail .col-status { color: #c0392b; font-weight: bold; }
.r-pass .col-status { color: #1e8449; font-weight: bold; }
.r-skip .col-status { color: #d68910; font-weight: bold; }

/* Columns */
.col-name   { min-width: 160px; }
.col-prio   { width: 70px;  text-align: center; }
.col-status { width: 80px;  text-align: center; }
.col-bench  { width: 16%;   color: #555; font-style: italic; font-size: 0.85em; }
.col-actual { width: 16%; }
.col-detail { width: 18%; }
.col-remedy { width: 22%; font-size: 0.84em; }
.r-fail .col-remedy { background: #fff3ef; color: #6e2510; }
.r-skip .col-remedy { background: #fffbf0; color: #6e4c10; }

/* ── Failure summary panel ── */
.fail-summary { margin: 12px 16px; border-radius: 8px; overflow: hidden;
                border: 1px solid #e8a09a; }
.fail-summary-hdr { background: #922b21; color: white; padding: 10px 16px;
                    font-weight: bold; font-size: 0.95em; }
.fail-summary table { font-size: 0.86em; }
.fail-summary th { background: #f9e8e6; color: #6e2510; }
.fs-remedy { background: #fff8f5; color: #6e2510; font-style: italic; }

/* Priority badges */
.prio { display: inline-block; padding: 1px 7px; border-radius: 10px;
        font-size: 0.75em; font-weight: bold; }
.p-crit   { background: #922b21; color: white; }
.p-high   { background: #d35400; color: white; }
.p-med    { background: #7d6608; color: white; }

/* Status pills */
.pill { display: inline-block; padding: 2px 9px; border-radius: 12px;
        font-size: 0.85em; font-weight: bold; }
.pill-pass { background: #27ae60; color: white; }
.pill-fail { background: #c0392b; color: white; }
.pill-skip { background: #e67e22; color: white; }

/* ── Per-DB table (Bloat/Skew) ── */
.tbl-pass { background: #d5f5e3; color: #1e8449; font-weight: bold; }
.tbl-fail { background: #fadbd8; color: #c0392b; font-weight: bold; }

/* ── Kernel table ── */
.k-pass { background: #d5f5e3; color: #1e8449; font-weight: bold; text-align:center; }
.k-fail { background: #fadbd8; color: #c0392b; font-weight: bold; text-align:center; }
.k-exp  { color: #555; font-style: italic; }

/* ── Collapsible detail logs ── */
details { margin-bottom: 10px; border: 1px solid #dde; border-radius: 6px;
          overflow: hidden; }
summary { padding: 9px 14px; cursor: pointer; font-weight: bold;
          font-size: 0.9em; list-style: none; display: flex;
          align-items: center; gap: 10px; user-select: none; }
summary::-webkit-details-marker { display: none; }
summary::before { content: "▶"; font-size: 0.7em; transition: transform 0.2s; }
details[open] summary::before { transform: rotate(90deg); }
.det-pass summary { background: #eafaf1; border-left: 4px solid #27ae60; }
.det-fail summary { background: #fdedec; border-left: 4px solid #c0392b; }
.det-skip summary { background: #fef9e7; border-left: 4px solid #e67e22; }
.det-body { padding: 0; }
pre { background: #f8f8f8; padding: 12px; overflow-x: auto; font-size: 0.82em;
      font-family: "Courier New", monospace; border-top: 1px solid #ddd;
      white-space: pre-wrap; word-break: break-word; margin: 0; }

/* ── Infrastructure overview cards ── */
.infra-overview { background: #fff; border-bottom: 2px solid #d0dcea;
                  padding: 12px 16px; }
.infra-overview-title { font-size: 0.78em; font-weight: bold; color: #004d99;
                        text-transform: uppercase; letter-spacing: 1px;
                        margin-bottom: 10px; }
.infra-grid { display: flex; flex-wrap: wrap; gap: 8px; }
.infra-card { background: #f4f7fb; border: 1px solid #cad8ec; border-radius: 6px;
              padding: 8px 14px; min-width: 130px; flex: 0 0 auto; }
.infra-label { display: block; font-size: 0.69em; color: #5a6a80;
               text-transform: uppercase; letter-spacing: 0.6px; margin-bottom: 3px; }
.infra-val { display: block; font-size: 0.92em; font-weight: 700; color: #002855;
             word-break: break-word; }
.infra-val.warn { color: #c0392b; }

/* ── Print ── */
@media print {
  .topnav, .banner { display: none; }
  .section { box-shadow: none; border: 1px solid #ccc; }
  details { display: block; }
  details summary::before { display: none; }
  pre { font-size: 0.75em; }
}
</style>
</head>
<body>
HTMLEOF

# ── Navigation bar ──
cat >> "$HTML" <<EOF
<nav class="topnav">
  <span class="logo">GP HealthCheck V3</span>
  <a href="#summary">&#128203; Summary</a>
  <a href="#fail-summary">&#9888; Failures</a>
  <a href="#bloat-skew">&#128202; Bloat / Skew</a>
  <a href="#kernel">&#9881; Kernel Params</a>
  <a href="#detail-logs">&#128196; Detail Logs</a>
  <a href="#db-detail">&#128260; DB Detail</a>
</nav>

<div class="page-header">
  <h1>${Company} &mdash; Greenplum Health Check Report</h1>
  <div class="meta">Generated: $(date) &nbsp;|&nbsp; Report file: ${HTML}</div>
</div>

<div class="ver-strip">
  <b>GP${GP_MAJOR_VERSION}</b> &nbsp;|&nbsp; ${GP_FULL_VERSION:-Unknown} &nbsp;|&nbsp; Port: ${GP_PORT}
</div>

<div class="infra-overview">
  <div class="infra-overview-title">&#128202; Cluster Infrastructure Overview</div>
  <div class="infra-grid">
    <div class="infra-card">
      <span class="infra-label">Coordinator</span>
      <span class="infra-val">${COORD_HOST:-unknown}</span>
    </div>
    <div class="infra-card">
      <span class="infra-label">Standby Coordinator</span>
      <span class="infra-val">${STANDBY_HOST:-not configured}</span>
    </div>
    <div class="infra-card">
      <span class="infra-label">Segment Hosts</span>
      <span class="infra-val">${SEG_HOST_COUNT:-?}</span>
    </div>
    <div class="infra-card">
      <span class="infra-label">Primary Segments</span>
      <span class="infra-val">${PRIMARY_SEG_COUNT:-?} (${SEGS_PER_HOST:-?}/host)</span>
    </div>
    <div class="infra-card">
      <span class="infra-label">Mirrors</span>
      <span class="infra-val">${MIRRORS_STATUS:-unknown}</span>
    </div>
    <div class="infra-card">
      <span class="infra-label">Databases</span>
      <span class="infra-val">${DB_COUNT:-?}</span>
    </div>
    <div class="infra-card">
      <span class="infra-label">Total Data Size</span>
      <span class="infra-val">${TOTAL_DATA_SIZE:-unknown}</span>
    </div>
    <div class="infra-card">
      <span class="infra-label">Max Connections</span>
      <span class="infra-val">${MAX_CONN:-?}</span>
    </div>
    <div class="infra-card">
      <span class="infra-label">Resource Manager</span>
      <span class="infra-val">${GP_RESOURCE_MGR:-unknown}</span>
    </div>
    <div class="infra-card">
      <span class="infra-label">Cluster Started</span>
      <span class="infra-val">${CLUSTER_START:-unknown}</span>
    </div>
    <div class="infra-card">
      <span class="infra-label">OS</span>
      <span class="infra-val">${OS_INFRA:-unknown}</span>
    </div>
    <div class="infra-card">
      <span class="infra-label">Kernel</span>
      <span class="infra-val">${KERNEL_VER:-unknown}</span>
    </div>
    <div class="infra-card">
      <span class="infra-label">Hosts in Hostfile</span>
      <span class="infra-val">${HOST_COUNT}</span>
    </div>
  </div>
</div>
EOF

# ─────────────────────────────────────────────────────────────
# 5.  DECLARE ALL TRACKING ARRAYS
# ─────────────────────────────────────────────────────────────
declare -A SUMMARY FAIL_REASON PASS_REASON COMPONENT_OUTPUT BENCHMARK ACTUAL_VAL

# ─────────────────────────────────────────────────────────────
# 6.  STATIC BENCHMARKS
# ─────────────────────────────────────────────────────────────
# Cluster Health
BENCHMARK["GP Segments Status"]="All primaries UP (status=u, mode=s or n)"
BENCHMARK["Mirror Segment Status"]="All mirrors synchronized (mode=s)"
BENCHMARK["Standby Coordinator Status"]="Standby configured and replicating"
BENCHMARK["Replication Lag"]="Standby lag < 100 MB"
BENCHMARK["Catalog Integrity Check"]="0 catalog inconsistencies"
# DB Reliability
BENCHMARK["XID Wraparound Risk"]="XID age < 500 M (warning) / < 1.5 B (critical)"
BENCHMARK["Connection Saturation"]="< 80% of max_connections in use"
BENCHMARK["Long Running Queries"]="0 queries running > 1 hour; 0 idle-in-transaction > 30 min"
BENCHMARK["Lock Waits"]="0 ungranted locks"
# Storage & Maintenance
BENCHMARK["Disk Free"]="All nodes >= 25% free disk"
BENCHMARK["Tables Needing VACUUM"]="0 tables with > 10,000 dead tuples or never vacuumed"
# OS / Infrastructure
BENCHMARK["CPU Usage"]="30-day Avg <= 80%, 30-day Peak <= 95%"
BENCHMARK["Transparent Huge Pages"]="THP = never or madvise on all hosts (NOT always)"
BENCHMARK["Swap Usage"]="0 MB swap in use on all hosts"
BENCHMARK["File Descriptor Limits"]="ulimit -n >= 524288 on all hosts"
BENCHMARK["MTU"]="All interfaces MTU >= 9000 (Jumbo Frames)"
# Query Optimization
BENCHMARK["GPORCA Optimizer"]="optimizer = on (GPORCA enabled)"
BENCHMARK["Random Distribution Tables"]="0 user tables with DISTRIBUTED RANDOMLY"
BENCHMARK["Stale Statistics"]="All tables > 10k rows analyzed within last 7 days"
BENCHMARK["Planner GUC Settings"]="optimizer=on, enable_nestloop=off, default_statistics_target>=100, gp_interconnect_type=udpifc"
BENCHMARK["Workfile Spill"]="0 active queries spilling to disk"
# Configuration
BENCHMARK["Resource Group and Memory Param"]="All GUC parameters readable and consistent"
# Security
BENCHMARK["Trust Authentication"]="0 non-local trust auth rules in pg_hba.conf"
BENCHMARK["Privileged Roles"]="Superusers = gpadmin only; no login roles without passwords"

# Benchmark thresholds (used in checks and displayed in tables)
DISK_WARN_PCT=25
CPU_AVG_WARN=80
CPU_MAX_WARN=95
MTU_MIN=9000
BLOAT_THRESHOLD=30
BLOAT_PAGE_THRESHOLD=1600
SKEW_THRESHOLD=1.5
XID_WARN=500000000
XID_CRIT=1500000000
FD_MIN=524288
LAG_THRESHOLD_BYTES=$((100 * 1024 * 1024))   # 100 MB

# Priority and category per check (used in summary table)
declare -A CHECK_PRIORITY CHECK_CATEGORY

CHECK_PRIORITY["GP Segments Status"]="Critical"
CHECK_PRIORITY["Mirror Segment Status"]="Critical"
CHECK_PRIORITY["Standby Coordinator Status"]="High"
CHECK_PRIORITY["Replication Lag"]="High"
CHECK_PRIORITY["Catalog Integrity Check"]="Critical"
CHECK_PRIORITY["XID Wraparound Risk"]="Critical"
CHECK_PRIORITY["Connection Saturation"]="High"
CHECK_PRIORITY["Long Running Queries"]="High"
CHECK_PRIORITY["Lock Waits"]="High"
CHECK_PRIORITY["Disk Free"]="High"
CHECK_PRIORITY["Tables Needing VACUUM"]="High"
CHECK_PRIORITY["CPU Usage"]="High"
CHECK_PRIORITY["Transparent Huge Pages"]="Critical"
CHECK_PRIORITY["Swap Usage"]="High"
CHECK_PRIORITY["File Descriptor Limits"]="High"
CHECK_PRIORITY["MTU"]="Medium"
CHECK_PRIORITY["GPORCA Optimizer"]="Critical"
CHECK_PRIORITY["Random Distribution Tables"]="Critical"
CHECK_PRIORITY["Stale Statistics"]="High"
CHECK_PRIORITY["Planner GUC Settings"]="High"
CHECK_PRIORITY["Workfile Spill"]="High"
CHECK_PRIORITY["Resource Group and Memory Param"]="High"
CHECK_PRIORITY["Trust Authentication"]="Critical"
CHECK_PRIORITY["Privileged Roles"]="High"

CHECK_CATEGORY["GP Segments Status"]="Cluster Health"
CHECK_CATEGORY["Mirror Segment Status"]="Cluster Health"
CHECK_CATEGORY["Standby Coordinator Status"]="Cluster Health"
CHECK_CATEGORY["Replication Lag"]="Cluster Health"
CHECK_CATEGORY["Catalog Integrity Check"]="Cluster Health"
CHECK_CATEGORY["XID Wraparound Risk"]="Database Reliability"
CHECK_CATEGORY["Connection Saturation"]="Database Reliability"
CHECK_CATEGORY["Long Running Queries"]="Database Reliability"
CHECK_CATEGORY["Lock Waits"]="Database Reliability"
CHECK_CATEGORY["Disk Free"]="Storage & Maintenance"
CHECK_CATEGORY["Tables Needing VACUUM"]="Storage & Maintenance"
CHECK_CATEGORY["CPU Usage"]="OS / Infrastructure"
CHECK_CATEGORY["Transparent Huge Pages"]="OS / Infrastructure"
CHECK_CATEGORY["Swap Usage"]="OS / Infrastructure"
CHECK_CATEGORY["File Descriptor Limits"]="OS / Infrastructure"
CHECK_CATEGORY["MTU"]="OS / Infrastructure"
CHECK_CATEGORY["GPORCA Optimizer"]="Query Optimization"
CHECK_CATEGORY["Random Distribution Tables"]="Query Optimization"
CHECK_CATEGORY["Stale Statistics"]="Query Optimization"
CHECK_CATEGORY["Planner GUC Settings"]="Query Optimization"
CHECK_CATEGORY["Workfile Spill"]="Query Optimization"
CHECK_CATEGORY["Resource Group and Memory Param"]="Configuration"
CHECK_CATEGORY["Trust Authentication"]="Security"
CHECK_CATEGORY["Privileged Roles"]="Security"

# Remediation guidance per check (shown in failure summary and summary table)
declare -A REMEDY
REMEDY["GP Segments Status"]="Run 'gprecoverseg' to recover failed segments. Use 'gprecoverseg -F' for full recovery after restoring the segment host. Monitor with 'gpstate -s'."
REMEDY["Mirror Segment Status"]="Run 'gprecoverseg' to resync out-of-sync mirrors, then 'gprecoverseg -r' to rebalance primary/mirror roles. Verify with 'gpstate -m'."
REMEDY["Standby Coordinator Status"]="Configure a standby: 'gpinitstandby -s <standby_host>'. Required for coordinator HA and zero-downtime failover in production."
REMEDY["Replication Lag"]="Check network bandwidth and standby host I/O. Review pg_stat_replication for details. Re-initialise standby replication if lag is stuck."
REMEDY["Catalog Integrity Check"]="Review gpcheckcat output in Detail Logs. Run 'gpcheckcat -R <repair_option>' for specific repairs. Contact Broadcom Support for critical catalog corruption."
REMEDY["XID Wraparound Risk"]="Run VACUUM FREEZE immediately: 'vacuumdb --freeze --analyze -d <dbname>'. Enable autovacuum. Contact Broadcom Support if XID age exceeds 1.5 billion."
REMEDY["Connection Saturation"]="Terminate idle sessions via pg_terminate_backend(). Deploy a connection pooler (PgBouncer). Increase max_connections: 'gpconfig -c max_connections -v <N>' then restart."
REMEDY["Long Running Queries"]="Terminate long-running queries: SELECT pg_terminate_backend(pid). Check for missing statistics or bad query plans. Enable statement_timeout to prevent recurrence."
REMEDY["Lock Waits"]="Terminate the blocking session: SELECT pg_terminate_backend(<blocking_pid>). Review application code for lock-prone transaction patterns and ensure timely COMMIT/ROLLBACK."
REMEDY["Disk Free"]="Archive or delete old data. Run VACUUM to reclaim dead-tuple space. Add storage or move data to a tablespace on a larger volume. Alert threshold: >= 25% free required."
REMEDY["Tables Needing VACUUM"]="Run 'VACUUM ANALYZE <table>' on affected tables or 'vacuumdb -d <database>' for a full pass. Tune autovacuum cost parameters via gpconfig."
REMEDY["CPU Usage"]="Identify heavy queries via pg_stat_activity or GPCC. Use resource groups to cap CPU. Schedule ETL and heavy workloads during off-peak hours."
REMEDY["Transparent Huge Pages"]="As root on each affected host: echo never > /sys/kernel/mm/transparent_hugepage/enabled. Persist via /etc/rc.d/rc.local or a tuned profile. Requires OS-level access."
REMEDY["Swap Usage"]="Reduce gp_vmem_protect_limit. Set vm.swappiness=10 in /etc/sysctl.conf and run 'sysctl -p'. Add RAM or reduce concurrent query workload. Requires OS-level access."
REMEDY["File Descriptor Limits"]="Add to /etc/security/limits.conf on each host: 'gpadmin soft nofile 524288' and 'gpadmin hard nofile 524288'. Restart Greenplum to apply. Requires OS access."
REMEDY["MTU"]="Set Jumbo Frames on all hosts (as root): 'ip link set <iface> mtu 9000'. Persist in /etc/sysconfig/network-scripts/ifcfg-<iface>. Coordinate with the network team."
REMEDY["GPORCA Optimizer"]="Enable GPORCA: 'gpconfig -c optimizer -v on' then reload with 'gpstop -u'. Verify with 'gpconfig -s optimizer'. GPORCA is strongly recommended for GP6+ workloads."
REMEDY["Random Distribution Tables"]="Redistribute: ALTER TABLE <name> SET DISTRIBUTED BY (<high_cardinality_column>). Choose a column with many distinct values to avoid data movement on joins."
REMEDY["Stale Statistics"]="Run 'analyzedb -d <database> -a' for a full pass, or 'ANALYZE <table>' on specific tables. Schedule regular analyzedb runs via cron to keep statistics current."
REMEDY["Planner GUC Settings"]="Apply mismatched settings: 'gpconfig -c <param> -v <value>' then reload with 'gpstop -u'. Key fixes: enable_nestloop=off, optimizer=on, default_statistics_target=100."
REMEDY["Workfile Spill"]="Increase statement_mem: 'gpconfig -c statement_mem -v 2GB'. Increase resource group memory limit. Optimize spill-heavy queries to reduce sort and hash operations."
REMEDY["Resource Group and Memory Param"]="Review Detail Logs for failed parameters. Re-run 'gpconfig -s <param>' to diagnose. Contact Broadcom Support if cluster state is inconsistent."
REMEDY["Trust Authentication"]="Change 'trust' to 'scram-sha-256' or 'md5' in pg_hba.conf for non-local entries. Reload with 'gpstop -u'. Assign strong passwords to all login roles."
REMEDY["Privileged Roles"]="Remove excess superuser rights: ALTER ROLE <name> NOSUPERUSER. Set passwords: ALTER ROLE <name> PASSWORD '<strong_pwd>'. Audit all superuser accounts regularly."

SUMMARY_ORDER=(
    "GP Segments Status" "Mirror Segment Status" "Standby Coordinator Status"
    "Replication Lag" "Catalog Integrity Check"
    "XID Wraparound Risk" "Connection Saturation" "Long Running Queries" "Lock Waits"
    "Disk Free" "Tables Needing VACUUM"
    "CPU Usage" "Transparent Huge Pages" "Swap Usage" "File Descriptor Limits" "MTU"
    "GPORCA Optimizer" "Random Distribution Tables" "Stale Statistics"
    "Planner GUC Settings" "Workfile Spill"
    "Resource Group and Memory Param"
    "Trust Authentication" "Privileged Roles"
)

# ─────────────────────────────────────────────────────────────
# 7.  HELPER
# ─────────────────────────────────────────────────────────────
run_with_timeout() {
    local NAME="$1" CMD="$2" OUTPUT RET
    OUTPUT=$(timeout "$TIMEOUT_SEC" bash -c "$CMD" 2>&1); RET=$?
    if [[ $RET -eq 124 ]]; then
        COMPONENT_OUTPUT["$NAME"]="Command timed out after ${TIMEOUT_SEC}s."
        return 1
    fi
    COMPONENT_OUTPUT["$NAME"]="$OUTPUT"; return 0
}

html_escape() { printf '%s' "$1" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g'; }

# ── Terminal progress helpers ──
CHECK_NUM=0
if [[ -t 1 ]]; then
    _RED='\033[0;31m'; _GRN='\033[0;32m'; _YLW='\033[0;33m'
    _BLD='\033[1m';    _DIM='\033[2m';    _RST='\033[0m'; _CYN='\033[0;36m'
else
    _RED=''; _GRN=''; _YLW=''; _BLD=''; _DIM=''; _RST=''; _CYN=''
fi

log_stage() {
    printf "\n${_BLD}${_CYN}── %s ──${_RST}\n" "$1"
}

log_check() {
    local NAME="$1"
    local STATUS="${SUMMARY[$NAME]:-UNKNOWN}"
    CHECK_NUM=$((CHECK_NUM + 1))
    local REASON
    case "$STATUS" in
        PASS) REASON="${PASS_REASON[$NAME]:-}" ;;
        *)    REASON="${FAIL_REASON[$NAME]:-}" ;;
    esac
    [[ ${#REASON} -gt 90 ]] && REASON="${REASON:0:87}..."
    local STATUS_STR
    case "$STATUS" in
        PASS)       STATUS_STR="${_GRN}PASS${_RST}" ;;
        FAIL)       STATUS_STR="${_RED}FAIL${_RST}" ;;
        SKIPPED)    STATUS_STR="${_YLW}SKIP${_RST}" ;;
        SUGGESTION) STATUS_STR="${_YLW}INFO${_RST}" ;;
        *)          STATUS_STR="${_YLW}${STATUS}${_RST}" ;;
    esac
    printf "${_BLD}[%2d/24]${_RST} %-44s %b\n" "$CHECK_NUM" "$NAME" "$STATUS_STR"
    [[ "$STATUS" != "PASS" && -n "$REASON" ]] && \
        printf "         └─ %b%s%b\n" "$_DIM" "$REASON" "$_RST"
}

# ═══════════════════════════════════════════════════════════════
# 8.  ALL CHECKS
# ═══════════════════════════════════════════════════════════════

# ── CLUSTER HEALTH ────────────────────────────────────────────
log_stage "Cluster Health"

OUTPUT=$(gpstate -s 2>&1); RET=$?
COMPONENT_OUTPUT["GP Segments Status"]="$OUTPUT"
if [[ $RET -eq 0 ]]; then
    SUMMARY["GP Segments Status"]="PASS"
    PASS_REASON["GP Segments Status"]="gpstate -s exited cleanly — primary segments healthy"
    ACTUAL_VAL["GP Segments Status"]="All primary segments reporting UP"
else
    DOWN_LINES=$(echo "$OUTPUT" | grep -cE -i "down|not sync|failed" || true)
    SUMMARY["GP Segments Status"]="FAIL"
    FAIL_REASON["GP Segments Status"]="gpstate -s reported issues with primary segments"
    ACTUAL_VAL["GP Segments Status"]="${DOWN_LINES} line(s) showing down/failed — see detail log"
fi
log_check "GP Segments Status"

OUTPUT=$(gpstate -m 2>&1); RET=$?
COMPONENT_OUTPUT["Mirror Segment Status"]="$OUTPUT"
if [[ $RET -eq 0 ]]; then
    SUMMARY["Mirror Segment Status"]="PASS"
    PASS_REASON["Mirror Segment Status"]="All mirrors synchronized with primaries"
    ACTUAL_VAL["Mirror Segment Status"]="All mirrors in synchronized state"
else
    NOT_SYNC=$(echo "$OUTPUT" | grep -cE -i "not sync|resync|down|failed" || true)
    SUMMARY["Mirror Segment Status"]="FAIL"
    FAIL_REASON["Mirror Segment Status"]="gpstate -m detected mirror segment issues"
    ACTUAL_VAL["Mirror Segment Status"]="${NOT_SYNC} mirror(s) not synchronized — see detail log"
fi
log_check "Mirror Segment Status"

OUTPUT=$(gpstate -f 2>&1); RET=$?
COMPONENT_OUTPUT["Standby Coordinator Status"]="$OUTPUT"
if echo "$OUTPUT" | grep -qiE "no standby master|no standby coordinator|standby master is not configured"; then
    SUMMARY["Standby Coordinator Status"]="SUGGESTION"
    FAIL_REASON["Standby Coordinator Status"]="No standby coordinator configured — recommended for HA production clusters"
    ACTUAL_VAL["Standby Coordinator Status"]="No standby coordinator configured"
elif [[ $RET -eq 0 ]]; then
    SUMMARY["Standby Coordinator Status"]="PASS"
    PASS_REASON["Standby Coordinator Status"]="Standby coordinator available and replicating"
    ACTUAL_VAL["Standby Coordinator Status"]="Standby coordinator replicating (gpstate -f OK)"
else
    SUMMARY["Standby Coordinator Status"]="FAIL"
    FAIL_REASON["Standby Coordinator Status"]="gpstate -f reported standby issues"
    ACTUAL_VAL["Standby Coordinator Status"]="Standby not reachable or not replicating — see detail log"
fi
log_check "Standby Coordinator Status"

REP_COUNT=$(psql -p "$GP_PORT" -t -A -c "SELECT count(*) FROM pg_stat_replication;" 2>/dev/null | xargs)
if [[ "${REP_COUNT:-0}" == "0" ]]; then
    SUMMARY["Replication Lag"]="SUGGESTION"
    FAIL_REASON["Replication Lag"]="No standby replication connections found in pg_stat_replication"
    ACTUAL_VAL["Replication Lag"]="0 standby connections detected"
    COMPONENT_OUTPUT["Replication Lag"]="No standby replication connections in pg_stat_replication."
else
    # GP6 uses pg_xlog_location_diff; GP7 uses pg_wal_lsn_diff
    if [[ "$GP_MAJOR_VERSION" == "7" ]]; then
        LAG_QUERY="SELECT client_addr, state,
                          pg_size_pretty(pg_wal_lsn_diff(sent_lsn, replay_lsn)) AS lag_size,
                          write_lag, flush_lag, replay_lag
                   FROM pg_stat_replication;"
        LAG_BYTES=$(psql -p "$GP_PORT" -t -A -c \
            "SELECT coalesce(max(pg_wal_lsn_diff(sent_lsn, replay_lsn)),0) FROM pg_stat_replication;" \
            2>/dev/null | xargs)
    else
        LAG_QUERY="SELECT client_addr, state,
                          pg_size_pretty(pg_xlog_location_diff(sent_location, replay_location)) AS lag_size
                   FROM pg_stat_replication;"
        LAG_BYTES=$(psql -p "$GP_PORT" -t -A -c \
            "SELECT coalesce(max(pg_xlog_location_diff(sent_location, replay_location)),0) FROM pg_stat_replication;" \
            2>/dev/null | xargs)
    fi
    REP_OUTPUT=$(psql -p "$GP_PORT" -c "$LAG_QUERY" 2>&1)
    COMPONENT_OUTPUT["Replication Lag"]="$REP_OUTPUT"
    LAG_PRETTY=$(psql -p "$GP_PORT" -t -A -c \
        "SELECT pg_size_pretty(${LAG_BYTES:-0}::bigint);" 2>/dev/null || echo "unknown")
    ACTUAL_VAL["Replication Lag"]="Max standby lag: ${LAG_PRETTY}"
    if [[ "$LAG_BYTES" =~ ^[0-9]+$ && "$LAG_BYTES" -gt "$LAG_THRESHOLD_BYTES" ]]; then
        SUMMARY["Replication Lag"]="FAIL"
        FAIL_REASON["Replication Lag"]="Standby lag ${LAG_PRETTY} exceeds 100 MB threshold"
    else
        SUMMARY["Replication Lag"]="PASS"
        PASS_REASON["Replication Lag"]="Standby lag ${LAG_PRETTY} is within acceptable range"
    fi
fi
log_check "Replication Lag"

if [[ "$GP_CHECK" == "Y" ]]; then
    OUTPUT=$(gpcheckcat -g -A -p "$GP_PORT" 2>&1); RET=$?
    COMPONENT_OUTPUT["Catalog Integrity Check"]="$OUTPUT"
    ISSUE_COUNT=$(echo "$OUTPUT" | grep -cE -i "error|inconsisten|mismatch|problem" || true)
    if [[ $RET -eq 0 ]]; then
        SUMMARY["Catalog Integrity Check"]="PASS"
        PASS_REASON["Catalog Integrity Check"]="No catalog inconsistencies detected"
        ACTUAL_VAL["Catalog Integrity Check"]="0 catalog issues found"
    else
        SUMMARY["Catalog Integrity Check"]="FAIL"
        FAIL_REASON["Catalog Integrity Check"]="Catalog integrity issues detected"
        ACTUAL_VAL["Catalog Integrity Check"]="${ISSUE_COUNT} issue line(s) detected — see detail log"
    fi
else
    SUMMARY["Catalog Integrity Check"]="SKIPPED"
    COMPONENT_OUTPUT["Catalog Integrity Check"]="gpcheckcat skipped by user at runtime."
    FAIL_REASON["Catalog Integrity Check"]="User chose not to run gpcheckcat"
    ACTUAL_VAL["Catalog Integrity Check"]="Not run"
fi
log_check "Catalog Integrity Check"

# ── DATABASE RELIABILITY ──────────────────────────────────────
log_stage "Database Reliability"

WRAP_OUTPUT=$(psql -p "$GP_PORT" -c "
SELECT datname,
       age(datfrozenxid)                                        AS xid_age,
       2100000000 - age(datfrozenxid)                           AS xids_remaining,
       round(age(datfrozenxid)::numeric / 2100000000 * 100, 1) AS pct_toward_limit
FROM pg_database
ORDER BY xid_age DESC;" 2>&1)
COMPONENT_OUTPUT["XID Wraparound Risk"]="$WRAP_OUTPUT"
MAX_XID_AGE=$(psql -p "$GP_PORT" -t -A -c \
    "SELECT max(age(datfrozenxid)) FROM pg_database;" 2>/dev/null | xargs)
MAX_XID_DB=$(psql -p "$GP_PORT" -t -A -c \
    "SELECT datname FROM pg_database ORDER BY age(datfrozenxid) DESC LIMIT 1;" 2>/dev/null)
ACTUAL_VAL["XID Wraparound Risk"]="Max XID age: ${MAX_XID_AGE} on DB: ${MAX_XID_DB}"
if [[ "$MAX_XID_AGE" =~ ^[0-9]+$ ]]; then
    if [[ "$MAX_XID_AGE" -gt "$XID_CRIT" ]]; then
        SUMMARY["XID Wraparound Risk"]="FAIL"
        FAIL_REASON["XID Wraparound Risk"]="CRITICAL: XID age ${MAX_XID_AGE} > 1.5 B on '${MAX_XID_DB}' — shutdown imminent without VACUUM FREEZE"
    elif [[ "$MAX_XID_AGE" -gt "$XID_WARN" ]]; then
        SUMMARY["XID Wraparound Risk"]="FAIL"
        FAIL_REASON["XID Wraparound Risk"]="WARNING: XID age ${MAX_XID_AGE} > 500 M on '${MAX_XID_DB}' — run VACUUM FREEZE soon"
    else
        SUMMARY["XID Wraparound Risk"]="PASS"
        PASS_REASON["XID Wraparound Risk"]="Max XID age ${MAX_XID_AGE} is well within safe range"
    fi
else
    SUMMARY["XID Wraparound Risk"]="FAIL"
    FAIL_REASON["XID Wraparound Risk"]="Could not retrieve XID age from pg_database"
    ACTUAL_VAL["XID Wraparound Risk"]="Query failed"
fi
log_check "XID Wraparound Risk"

CONN_OUTPUT=$(psql -p "$GP_PORT" -c "
SELECT count(*)                                                           AS current_connections,
       (SELECT setting::int FROM pg_settings WHERE name='max_connections') AS max_connections,
       round(count(*)::numeric /
           (SELECT setting::int FROM pg_settings WHERE name='max_connections') * 100, 1) AS pct_used,
       count(*) FILTER (WHERE state='active')            AS active,
       count(*) FILTER (WHERE state='idle')              AS idle,
       count(*) FILTER (WHERE state='idle in transaction') AS idle_in_txn
FROM pg_stat_activity;" 2>&1)
COMPONENT_OUTPUT["Connection Saturation"]="$CONN_OUTPUT"
CONN_PCT=$(psql -p "$GP_PORT" -t -A -c "
SELECT round(count(*)::numeric /
    (SELECT setting::int FROM pg_settings WHERE name='max_connections') * 100, 1)
FROM pg_stat_activity;" 2>/dev/null | xargs)
CONN_CURR=$(psql -p "$GP_PORT" -t -A -c "SELECT count(*) FROM pg_stat_activity;" 2>/dev/null | xargs)
CONN_MAX=$(psql -p "$GP_PORT" -t -A -c "SELECT setting FROM pg_settings WHERE name='max_connections';" 2>/dev/null | xargs)
ACTUAL_VAL["Connection Saturation"]="${CONN_CURR}/${CONN_MAX} connections used (${CONN_PCT}%)"
if [[ "$CONN_PCT" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
    CONN_PCT_INT=$(printf "%.0f" "$CONN_PCT")
    if [[ "$CONN_PCT_INT" -ge 80 ]]; then
        SUMMARY["Connection Saturation"]="FAIL"
        FAIL_REASON["Connection Saturation"]="${CONN_CURR}/${CONN_MAX} connections (${CONN_PCT}%) — at or approaching limit"
    else
        SUMMARY["Connection Saturation"]="PASS"
        PASS_REASON["Connection Saturation"]="${CONN_CURR}/${CONN_MAX} connections (${CONN_PCT}%) within safe range"
    fi
else
    SUMMARY["Connection Saturation"]="FAIL"
    FAIL_REASON["Connection Saturation"]="Could not retrieve connection statistics"
    ACTUAL_VAL["Connection Saturation"]="Query failed"
fi
log_check "Connection Saturation"

LRQ_OUTPUT=$(psql -p "$GP_PORT" -c "
SELECT pid, state,
       now() - query_start                       AS duration,
       wait_event_type, wait_event,
       left(query, 120)                          AS query_snippet
FROM pg_stat_activity
WHERE state != 'idle'
  AND query_start < now() - interval '1 hour'
  AND query NOT LIKE '%pg_stat_activity%'
ORDER BY duration DESC LIMIT 20;

-- Idle-in-transaction > 30 min:
SELECT pid, state,
       now() - query_start AS idle_txn_duration,
       left(query, 120)    AS last_query
FROM pg_stat_activity
WHERE state = 'idle in transaction'
  AND query_start < now() - interval '30 minutes'
ORDER BY idle_txn_duration DESC LIMIT 10;" 2>&1)
COMPONENT_OUTPUT["Long Running Queries"]="$LRQ_OUTPUT"
LRQ_COUNT=$(psql -p "$GP_PORT" -t -A -c "
SELECT count(*) FROM pg_stat_activity
WHERE state != 'idle' AND query_start < now() - interval '1 hour'
  AND query NOT LIKE '%pg_stat_activity%';" 2>/dev/null | xargs)
IDLE_TXN=$(psql -p "$GP_PORT" -t -A -c "
SELECT count(*) FROM pg_stat_activity
WHERE state = 'idle in transaction'
  AND query_start < now() - interval '30 minutes';" 2>/dev/null | xargs)
ACTUAL_VAL["Long Running Queries"]="${LRQ_COUNT:-0} queries >1 hour; ${IDLE_TXN:-0} idle-in-transaction >30 min"
if [[ "${LRQ_COUNT:-0}" -gt 0 || "${IDLE_TXN:-0}" -gt 0 ]]; then
    SUMMARY["Long Running Queries"]="FAIL"
    FAIL_REASON["Long Running Queries"]="${LRQ_COUNT:-0} long-running query/queries (>1h) and ${IDLE_TXN:-0} idle-in-transaction (>30min)"
else
    SUMMARY["Long Running Queries"]="PASS"
    PASS_REASON["Long Running Queries"]="No queries >1 hour and no idle-in-transaction >30 min detected"
fi
log_check "Long Running Queries"

LOCK_OUTPUT=$(psql -p "$GP_PORT" -c "
SELECT blocked.pid            AS blocked_pid,
       blocked_q.state        AS state,
       now() - blocked_q.query_start AS wait_duration,
       left(blocked_q.query, 100)    AS blocked_query,
       blocking.pid           AS blocking_pid,
       left(blocking_q.query, 100)   AS blocking_query
FROM pg_locks blocked
JOIN pg_stat_activity blocked_q   ON blocked.pid = blocked_q.pid
JOIN pg_locks blocking            ON  blocking.relation = blocked.relation
                                  AND blocking.granted = true
                                  AND blocking.pid != blocked.pid
JOIN pg_stat_activity blocking_q  ON blocking.pid = blocking_q.pid
WHERE NOT blocked.granted
LIMIT 20;" 2>&1)
COMPONENT_OUTPUT["Lock Waits"]="$LOCK_OUTPUT"
LOCK_COUNT=$(psql -p "$GP_PORT" -t -A -c \
    "SELECT count(*) FROM pg_locks WHERE NOT granted;" 2>/dev/null | xargs)
ACTUAL_VAL["Lock Waits"]="${LOCK_COUNT:-0} ungranted lock(s) at time of check"
if [[ "${LOCK_COUNT:-0}" -gt 0 ]]; then
    SUMMARY["Lock Waits"]="FAIL"
    FAIL_REASON["Lock Waits"]="${LOCK_COUNT} ungranted lock(s) — queries are blocked waiting for locks"
else
    SUMMARY["Lock Waits"]="PASS"
    PASS_REASON["Lock Waits"]="No lock waits detected at time of report"
fi
log_check "Lock Waits"

# ── STORAGE & MAINTENANCE ─────────────────────────────────────
log_stage "Storage & Maintenance"

DISK_FAIL=0; LOWEST_DISK_FREE=100; LOWEST_DISK_HOST="(unknown)"
if run_with_timeout "Disk Free (Cluster)" \
   "gpssh -f $GPHOSTFILE_PATH -e \"df -h | grep -v tmpfs | grep -v overlay\""; then
    DISK_OUTPUT="${COMPONENT_OUTPUT["Disk Free (Cluster)"]}"
    while read -r line; do
        USEP=$(echo "$line" | grep -o '[0-9]\+%' | tail -1 | tr -d '%')
        [[ "$USEP" =~ ^[0-9]+$ ]] || continue
        FREE=$((100 - USEP))
        HOST_LABEL=$(echo "$line" | grep -oE '^\[[^]]+\]' | tr -d '[]')
        if [[ "$FREE" -lt "$LOWEST_DISK_FREE" ]]; then
            LOWEST_DISK_FREE=$FREE; LOWEST_DISK_HOST="${HOST_LABEL:-unknown}"
        fi
        [[ "$FREE" -lt "$DISK_WARN_PCT" ]] && DISK_FAIL=1
    done <<< "$DISK_OUTPUT"
else
    DISK_OUTPUT="${COMPONENT_OUTPUT["Disk Free (Cluster)"]}"; DISK_FAIL=1
fi
COMPONENT_OUTPUT["Disk Free"]="$DISK_OUTPUT"
ACTUAL_VAL["Disk Free"]="Lowest free: ${LOWEST_DISK_FREE}% on ${LOWEST_DISK_HOST}"
if [[ "$DISK_FAIL" -eq 1 ]]; then
    SUMMARY["Disk Free"]="FAIL"
    FAIL_REASON["Disk Free"]="Disk free < ${DISK_WARN_PCT}% on one or more nodes"
else
    SUMMARY["Disk Free"]="PASS"
    PASS_REASON["Disk Free"]="All disks >= ${DISK_WARN_PCT}% free"
fi
log_check "Disk Free"

VAC_OUTPUT=$(psql -p "$GP_PORT" -c "
SELECT schemaname, relname AS table_name,
       n_dead_tup,
       last_vacuum,
       last_autovacuum,
       now() - greatest(last_vacuum, last_autovacuum) AS time_since_vacuum
FROM pg_stat_user_tables
WHERE n_dead_tup > 10000
   OR (last_vacuum IS NULL AND last_autovacuum IS NULL AND n_live_tup > 1000)
ORDER BY n_dead_tup DESC NULLS LAST
LIMIT 20;" 2>&1)
COMPONENT_OUTPUT["Tables Needing VACUUM"]="$VAC_OUTPUT"
VAC_COUNT=$(psql -p "$GP_PORT" -t -A -c "
SELECT count(*) FROM pg_stat_user_tables
WHERE n_dead_tup > 10000
   OR (last_vacuum IS NULL AND last_autovacuum IS NULL AND n_live_tup > 1000);" \
    2>/dev/null | xargs)
ACTUAL_VAL["Tables Needing VACUUM"]="${VAC_COUNT:-0} table(s) with >10k dead tuples or never vacuumed"
if [[ "${VAC_COUNT:-0}" -gt 0 ]]; then
    SUMMARY["Tables Needing VACUUM"]="FAIL"
    FAIL_REASON["Tables Needing VACUUM"]="${VAC_COUNT} table(s) accumulating dead tuples — run VACUUM to reclaim space"
else
    SUMMARY["Tables Needing VACUUM"]="PASS"
    PASS_REASON["Tables Needing VACUUM"]="No tables with significant dead tuple accumulation"
fi
log_check "Tables Needing VACUUM"

# ── OS / INFRASTRUCTURE ───────────────────────────────────────
log_stage "OS / Infrastructure"

GPCC_AVAIL=$(psql -p "$GP_PORT" -d gpperfmon -t -A \
    -c "SELECT 1 FROM information_schema.tables
        WHERE table_schema='gpmetrics' AND table_name='gpcc_system_history';" 2>/dev/null)
if [[ "$GPCC_AVAIL" != "1" ]]; then
    SUMMARY["CPU Usage"]="SKIPPED"
    FAIL_REASON["CPU Usage"]="GPCC not installed — gpmetrics.gpcc_system_history unavailable"
    ACTUAL_VAL["CPU Usage"]="gpperfmon / GPCC not present"
    COMPONENT_OUTPUT["CPU Usage"]="Skipped: Greenplum Command Center (GPCC) is not installed on this cluster."
else
    CPU_DETAIL=$(psql -p "$GP_PORT" -d gpperfmon -A -F"," -c "
        SELECT hostname,
               round(avg(cpu_user+cpu_sys)::numeric,1) AS avg_total_cpu,
               round(max(cpu_user+cpu_sys)::numeric,1) AS max_total_cpu,
               round(avg(cpu_idle)::numeric,1)          AS avg_idle_cpu
        FROM gpmetrics.gpcc_system_history
        WHERE ctime > now() - interval '30 day'
        GROUP BY hostname ORDER BY avg_total_cpu DESC;" 2>&1)
    CPU_COMPARE=$(psql -p "$GP_PORT" -d gpperfmon -t -A -F"," -c "
        SELECT round(avg(cpu_user+cpu_sys)) avg_cpu,
               round(max(cpu_user+cpu_sys)) max_cpu
        FROM gpmetrics.gpcc_system_history
        WHERE ctime > now() - interval '30 day';" 2>&1)
    COMPONENT_OUTPUT["CPU Usage"]="$CPU_DETAIL"
    AVG_CPU=$(echo "$CPU_COMPARE" | awk -F',' '{print $1}' | xargs)
    MAX_CPU=$(echo "$CPU_COMPARE" | awk -F',' '{print $2}' | xargs)
    if [[ -z "$AVG_CPU" || -z "$MAX_CPU" ]]; then
        SUMMARY["CPU Usage"]="FAIL"
        FAIL_REASON["CPU Usage"]="CPU metrics query returned no data"
        ACTUAL_VAL["CPU Usage"]="No data returned from gpmetrics"
    else
        AVG_CPU_INT=$(printf "%.0f" "$AVG_CPU")
        MAX_CPU_INT=$(printf "%.0f" "$MAX_CPU")
        ACTUAL_VAL["CPU Usage"]="30-day Avg: ${AVG_CPU_INT}%, 30-day Peak: ${MAX_CPU_INT}%"
        if [[ "$AVG_CPU_INT" -gt "$CPU_AVG_WARN" || "$MAX_CPU_INT" -gt "$CPU_MAX_WARN" ]]; then
            SUMMARY["CPU Usage"]="FAIL"
            FAIL_REASON["CPU Usage"]="Avg=${AVG_CPU_INT}% or Peak=${MAX_CPU_INT}% exceeds threshold (Avg>${CPU_AVG_WARN}% / Peak>${CPU_MAX_WARN}%)"
        else
            SUMMARY["CPU Usage"]="PASS"
            PASS_REASON["CPU Usage"]="Avg=${AVG_CPU_INT}%, Peak=${MAX_CPU_INT}% — within limits"
        fi
    fi
fi
log_check "CPU Usage"

THP_FAIL=0; THP_LOG=""; THP_FAIL_HOSTS=""
while IFS= read -r HOST; do
    [[ -z "$HOST" || "$HOST" == \#* ]] && continue
    THP_VAL=$(gpssh -h "$HOST" -e "cat /sys/kernel/mm/transparent_hugepage/enabled" 2>/dev/null \
              | grep "\[$HOST\]" | sed "s/.*\[$HOST\] //" | tr -d '\r' | xargs)
    THP_LOG+="${HOST}: ${THP_VAL}\n"
    echo "$THP_VAL" | grep -q "\[always\]" && { THP_FAIL=1; THP_FAIL_HOSTS+="${HOST} "; }
done < "$GPHOSTFILE_PATH"
COMPONENT_OUTPUT["Transparent Huge Pages"]="$(printf '%b' "$THP_LOG")"
if [[ "$THP_FAIL" -eq 1 ]]; then
    SUMMARY["Transparent Huge Pages"]="FAIL"
    FAIL_REASON["Transparent Huge Pages"]="THP=[always] on: ${THP_FAIL_HOSTS}— causes latency spikes; set to never or madvise"
    ACTUAL_VAL["Transparent Huge Pages"]="THP=always on hosts: ${THP_FAIL_HOSTS}"
else
    SUMMARY["Transparent Huge Pages"]="PASS"
    PASS_REASON["Transparent Huge Pages"]="THP correctly set to never/madvise on all hosts"
    ACTUAL_VAL["Transparent Huge Pages"]="THP never/madvise on all hosts"
fi
log_check "Transparent Huge Pages"

SWAP_FAIL=0; SWAP_LOG=""; SWAP_FAIL_HOSTS=""
if run_with_timeout "Swap Usage (Cluster)" \
   "gpssh -f $GPHOSTFILE_PATH -e \"free -m | grep -i swap\""; then
    SWAP_RAW="${COMPONENT_OUTPUT["Swap Usage (Cluster)"]}"
    SWAP_LOG="$SWAP_RAW"
    while read -r line; do
        HOST_LABEL=$(echo "$line" | grep -oE '^\[[^]]+\]' | tr -d '[]')
        SWAP_USED=$(echo "$line" | grep -i "swap" | awk '{print $3}')
        [[ "$SWAP_USED" =~ ^[0-9]+$ ]] || continue
        if [[ "$SWAP_USED" -gt 0 ]]; then
            SWAP_FAIL=1; SWAP_FAIL_HOSTS+="${HOST_LABEL}(${SWAP_USED}MB) "
        fi
    done <<< "$SWAP_LOG"
else
    SWAP_LOG="${COMPONENT_OUTPUT["Swap Usage (Cluster)"]}"; SWAP_FAIL=1
fi
COMPONENT_OUTPUT["Swap Usage"]="$SWAP_LOG"
if [[ "$SWAP_FAIL" -eq 1 ]]; then
    SUMMARY["Swap Usage"]="FAIL"
    FAIL_REASON["Swap Usage"]="Swap in use on: ${SWAP_FAIL_HOSTS}— memory pressure detected; queries will be degraded"
    ACTUAL_VAL["Swap Usage"]="Swap used on: ${SWAP_FAIL_HOSTS}"
else
    SUMMARY["Swap Usage"]="PASS"
    PASS_REASON["Swap Usage"]="Swap = 0 MB on all hosts"
    ACTUAL_VAL["Swap Usage"]="No swap in use on any host"
fi
log_check "Swap Usage"

FD_FAIL=0; FD_LOG=""; FD_FAIL_HOSTS=""; LOWEST_FD=99999999; LOWEST_FD_HOST=""
while IFS= read -r HOST; do
    [[ -z "$HOST" || "$HOST" == \#* ]] && continue
    FD_VAL=$(gpssh -h "$HOST" -e "ulimit -n" 2>/dev/null \
             | grep "\[$HOST\]" | sed "s/.*\[$HOST\] //" | tr -d '\r' | xargs)
    FD_LOG+="${HOST}: ulimit -n = ${FD_VAL}\n"
    if [[ "$FD_VAL" =~ ^[0-9]+$ ]]; then
        [[ "$FD_VAL" -lt "$FD_MIN" ]] && { FD_FAIL=1; FD_FAIL_HOSTS+="${HOST}(${FD_VAL}) "; }
        [[ "$FD_VAL" -lt "$LOWEST_FD" ]] && { LOWEST_FD=$FD_VAL; LOWEST_FD_HOST=$HOST; }
    fi
done < "$GPHOSTFILE_PATH"
COMPONENT_OUTPUT["File Descriptor Limits"]="$(printf '%b' "$FD_LOG")"
ACTUAL_VAL["File Descriptor Limits"]="Lowest: ${LOWEST_FD} on ${LOWEST_FD_HOST}"
if [[ "$FD_FAIL" -eq 1 ]]; then
    SUMMARY["File Descriptor Limits"]="FAIL"
    FAIL_REASON["File Descriptor Limits"]="ulimit -n < ${FD_MIN} on: ${FD_FAIL_HOSTS}"
else
    SUMMARY["File Descriptor Limits"]="PASS"
    PASS_REASON["File Descriptor Limits"]="All hosts have ulimit -n >= ${FD_MIN}"
fi
log_check "File Descriptor Limits"

MTU_FAIL=0; LOWEST_MTU=99999; LOWEST_MTU_HOST="(unknown)"
if run_with_timeout "MTU Check (Cluster)" \
   "gpssh -f $GPHOSTFILE_PATH -e \"ip link show | grep -i mtu\""; then
    MTU_OUTPUT="${COMPONENT_OUTPUT["MTU Check (Cluster)"]}"
    while read -r line; do
        MTU=$(echo "$line" | sed -n 's/.*mtu \([0-9]*\).*/\1/p')
        [[ "$MTU" =~ ^[0-9]+$ ]] || continue
        HOST_LABEL=$(echo "$line" | grep -oE '^\[[^]]+\]' | tr -d '[]')
        if [[ "$MTU" -lt "$LOWEST_MTU" ]]; then LOWEST_MTU=$MTU; LOWEST_MTU_HOST="${HOST_LABEL:-unknown}"; fi
        [[ "$MTU" -lt "$MTU_MIN" ]] && MTU_FAIL=1
    done <<< "$MTU_OUTPUT"
else
    MTU_OUTPUT="${COMPONENT_OUTPUT["MTU Check (Cluster)"]}"; MTU_FAIL=1
fi
COMPONENT_OUTPUT["MTU"]="$MTU_OUTPUT"
ACTUAL_VAL["MTU"]="Lowest MTU: ${LOWEST_MTU} on ${LOWEST_MTU_HOST}"
if [[ "$MTU_FAIL" -eq 1 ]]; then
    SUMMARY["MTU"]="SUGGESTION"
    FAIL_REASON["MTU"]="MTU < ${MTU_MIN} on one or more nodes — Jumbo Frames recommended for best Greenplum network performance"
else
    SUMMARY["MTU"]="PASS"
    PASS_REASON["MTU"]="All interfaces MTU >= ${MTU_MIN}"
fi
log_check "MTU"

# ── QUERY OPTIMIZATION ────────────────────────────────────────
log_stage "Query Optimization"

GPORCA_RAW=$(gpconfig -s optimizer 2>&1)
COMPONENT_OUTPUT["GPORCA Optimizer"]="$GPORCA_RAW"
GPORCA_COORD=$(echo "$GPORCA_RAW" | grep -iE "^(Coordinator|Master)[[:space:]]+value" \
               | awk -F': ' '{print $2}' | xargs)
GPORCA_SEG=$(echo "$GPORCA_RAW" | grep -iE "^Segment[[:space:]]+value" \
             | awk -F': ' '{print $2}' | xargs)
ACTUAL_VAL["GPORCA Optimizer"]="Coordinator: ${GPORCA_COORD:-unknown}, Segment: ${GPORCA_SEG:-unknown}"
if [[ "$GPORCA_COORD" == "on" && "$GPORCA_SEG" == "on" ]]; then
    SUMMARY["GPORCA Optimizer"]="PASS"
    PASS_REASON["GPORCA Optimizer"]="GPORCA enabled on coordinator and all segments"
else
    SUMMARY["GPORCA Optimizer"]="FAIL"
    FAIL_REASON["GPORCA Optimizer"]="GPORCA is OFF (Coord: ${GPORCA_COORD:-unknown}, Seg: ${GPORCA_SEG:-unknown}) — all queries use less efficient legacy planner"
fi
log_check "GPORCA Optimizer"

# GP6: random = no entry in gp_distribution_policy with attrnums set
# GP7: random = policytype = 'r' in gp_distribution_policy
if [[ "$GP_MAJOR_VERSION" == "7" ]]; then
    RAND_COUNT_QUERY="SELECT count(*) FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
        JOIN gp_distribution_policy dp ON dp.localoid = c.oid
        WHERE dp.policytype = 'r' AND c.relkind = 'r'
          AND n.nspname NOT IN ('pg_catalog','information_schema','gp_toolkit','pg_aoseg');"
    RAND_DETAIL_QUERY="SELECT n.nspname AS schema, c.relname AS table_name,
               pg_size_pretty(pg_total_relation_size(c.oid)) AS size
        FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
        JOIN gp_distribution_policy dp ON dp.localoid = c.oid
        WHERE dp.policytype = 'r' AND c.relkind = 'r'
          AND n.nspname NOT IN ('pg_catalog','information_schema','gp_toolkit','pg_aoseg')
        ORDER BY pg_total_relation_size(c.oid) DESC LIMIT 30;"
else
    RAND_COUNT_QUERY="SELECT count(*) FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE c.relkind = 'r'
          AND n.nspname NOT IN ('pg_catalog','information_schema','gp_toolkit','pg_aoseg')
          AND NOT EXISTS (SELECT 1 FROM gp_distribution_policy p
                          WHERE p.localoid = c.oid AND p.attrnums IS NOT NULL);"
    RAND_DETAIL_QUERY="SELECT n.nspname AS schema, c.relname AS table_name,
               pg_size_pretty(pg_total_relation_size(c.oid)) AS size
        FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE c.relkind = 'r'
          AND n.nspname NOT IN ('pg_catalog','information_schema','gp_toolkit','pg_aoseg')
          AND NOT EXISTS (SELECT 1 FROM gp_distribution_policy p
                          WHERE p.localoid = c.oid AND p.attrnums IS NOT NULL)
        ORDER BY pg_total_relation_size(c.oid) DESC LIMIT 30;"
fi
RAND_COUNT=$(psql -p "$GP_PORT" -t -A -c "$RAND_COUNT_QUERY" 2>/dev/null | xargs)
RAND_OUTPUT=$(psql -p "$GP_PORT" -c "$RAND_DETAIL_QUERY" 2>&1)
COMPONENT_OUTPUT["Random Distribution Tables"]="$RAND_OUTPUT"
ACTUAL_VAL["Random Distribution Tables"]="${RAND_COUNT:-0} table(s) with DISTRIBUTED RANDOMLY in user schemas"
if [[ "${RAND_COUNT:-0}" -gt 0 ]]; then
    SUMMARY["Random Distribution Tables"]="FAIL"
    FAIL_REASON["Random Distribution Tables"]="${RAND_COUNT} table(s) randomly distributed — full data redistribution occurs on every join; add a distribution key"
else
    SUMMARY["Random Distribution Tables"]="PASS"
    PASS_REASON["Random Distribution Tables"]="No randomly distributed tables in user schemas"
fi
log_check "Random Distribution Tables"

STALE_OUTPUT=$(psql -p "$GP_PORT" -c "
SELECT schemaname, relname AS table_name, n_live_tup, n_dead_tup,
       last_analyze, last_autoanalyze,
       now() - greatest(last_analyze, last_autoanalyze) AS stats_age
FROM pg_stat_user_tables
WHERE n_live_tup > 10000
  AND (greatest(last_analyze, last_autoanalyze) < now() - interval '7 days'
       OR (last_analyze IS NULL AND last_autovacuum IS NULL))
ORDER BY n_live_tup DESC LIMIT 20;" 2>&1)
COMPONENT_OUTPUT["Stale Statistics"]="$STALE_OUTPUT"
STALE_COUNT=$(psql -p "$GP_PORT" -t -A -c "
SELECT count(*) FROM pg_stat_user_tables
WHERE n_live_tup > 10000
  AND (greatest(last_analyze, last_autoanalyze) < now() - interval '7 days'
       OR (last_analyze IS NULL AND last_autovacuum IS NULL));" 2>/dev/null | xargs)
ACTUAL_VAL["Stale Statistics"]="${STALE_COUNT:-0} table(s) >10k rows with statistics older than 7 days"
if [[ "${STALE_COUNT:-0}" -gt 0 ]]; then
    SUMMARY["Stale Statistics"]="FAIL"
    FAIL_REASON["Stale Statistics"]="${STALE_COUNT} large table(s) have stale statistics — planner may choose poor query plans; run ANALYZE"
else
    SUMMARY["Stale Statistics"]="PASS"
    PASS_REASON["Stale Statistics"]="All large tables analyzed within the last 7 days"
fi
log_check "Stale Statistics"

declare -A PLANNER_BENCHMARKS=(
    ["optimizer"]="on"
    ["optimizer_analyze_root_partition"]="on"
    ["gp_enable_multiphase_agg"]="on"
    ["enable_hashjoin"]="on"
    ["enable_nestloop"]="off"
    ["enable_bitmapscan"]="on"
    ["gp_interconnect_type"]="udpifc"
)
PLANNER_FAIL_COUNT=0; PLANNER_CHECKED=0; PLANNER_LOG=""; PLANNER_FAIL_DETAILS=""
for PARAM in "${!PLANNER_BENCHMARKS[@]}"; do
    EXPECTED="${PLANNER_BENCHMARKS[$PARAM]}"
    RAW=$(gpconfig -s "$PARAM" 2>/dev/null) || { PLANNER_LOG+="\n[SKIPPED on GP${GP_MAJOR_VERSION}] $PARAM\n"; continue; }
    PLANNER_CHECKED=$((PLANNER_CHECKED+1))
    ACTUAL=$(echo "$RAW" | grep -iE "^(Coordinator|Master)[[:space:]]+value" \
             | awk -F': ' '{print $2}' | xargs)
    PLANNER_LOG+="\n=== $PARAM ===\nExpected: $EXPECTED  |  Found: ${ACTUAL:-unknown}\n$RAW\n"
    if [[ -n "$ACTUAL" && "$ACTUAL" != "$EXPECTED" ]]; then
        PLANNER_FAIL_COUNT=$((PLANNER_FAIL_COUNT+1))
        PLANNER_FAIL_DETAILS+="${PARAM}=${ACTUAL} (expected: ${EXPECTED}); "
    fi
done
# default_statistics_target needs a >= comparison
STATS_TGT_RAW=$(gpconfig -s default_statistics_target 2>/dev/null)
STATS_TGT=$(echo "$STATS_TGT_RAW" | grep -iE "^(Coordinator|Master)[[:space:]]+value" \
            | awk -F': ' '{print $2}' | xargs)
PLANNER_LOG+="\n=== default_statistics_target ===\nExpected: >= 100  |  Found: ${STATS_TGT:-unknown}\n$STATS_TGT_RAW\n"
if [[ "$STATS_TGT" =~ ^[0-9]+$ && "$STATS_TGT" -lt 100 ]]; then
    PLANNER_FAIL_COUNT=$((PLANNER_FAIL_COUNT+1))
    PLANNER_FAIL_DETAILS+="default_statistics_target=${STATS_TGT} (expected >= 100); "
fi
COMPONENT_OUTPUT["Planner GUC Settings"]="$(printf '%b' "$PLANNER_LOG")"
ACTUAL_VAL["Planner GUC Settings"]="${PLANNER_FAIL_COUNT} of ${PLANNER_CHECKED} settings differ from Greenplum recommendation"
if [[ "$PLANNER_FAIL_COUNT" -gt 0 ]]; then
    SUMMARY["Planner GUC Settings"]="FAIL"
    FAIL_REASON["Planner GUC Settings"]="${PLANNER_FAIL_DETAILS}"
else
    SUMMARY["Planner GUC Settings"]="PASS"
    PASS_REASON["Planner GUC Settings"]="All ${PLANNER_CHECKED} planner GUC settings match Greenplum recommendations"
fi
log_check "Planner GUC Settings"

WF_EXISTS=$(psql -p "$GP_PORT" -t -A -c "
SELECT 1 FROM information_schema.views
WHERE table_schema='gp_toolkit'
  AND table_name='gp_workfile_usage_per_query';" 2>/dev/null | xargs)
if [[ "$WF_EXISTS" != "1" ]]; then
    SUMMARY["Workfile Spill"]="SKIPPED"
    FAIL_REASON["Workfile Spill"]="gp_toolkit.gp_workfile_usage_per_query not available on this version"
    ACTUAL_VAL["Workfile Spill"]="View not available"
    COMPONENT_OUTPUT["Workfile Spill"]="gp_toolkit.gp_workfile_usage_per_query not found on this GP version."
else
    WF_OUTPUT=$(psql -p "$GP_PORT" -c "
-- Active query workfile usage (spilling right now):
SELECT * FROM gp_toolkit.gp_workfile_usage_per_query ORDER BY size DESC LIMIT 20;
-- Per-segment summary:
SELECT * FROM gp_toolkit.gp_workfile_usage_per_segment;" 2>&1)
    COMPONENT_OUTPUT["Workfile Spill"]="$WF_OUTPUT"
    SPILL_COUNT=$(psql -p "$GP_PORT" -t -A -c \
        "SELECT count(*) FROM gp_toolkit.gp_workfile_usage_per_query;" 2>/dev/null | xargs)
    ACTUAL_VAL["Workfile Spill"]="${SPILL_COUNT:-0} query/queries actively spilling to disk"
    if [[ "${SPILL_COUNT:-0}" -gt 0 ]]; then
        SUMMARY["Workfile Spill"]="FAIL"
        FAIL_REASON["Workfile Spill"]="${SPILL_COUNT} query/queries spilling to disk — increase statement_mem or resource group memory limit"
    else
        SUMMARY["Workfile Spill"]="PASS"
        PASS_REASON["Workfile Spill"]="No active workfile spill detected"
    fi
fi
log_check "Workfile Spill"

# ── CONFIGURATION ─────────────────────────────────────────────
log_stage "Configuration"

GP6_ONLY_PARAMS=("gp_instrument_shmem_size")
MEM_PARAMS=("gp_vmem_protect_limit" "statement_mem" "max_statement_mem" \
            "shared_buffers" "gp_resgroup_memory_policy" \
            "gp_resource_manager" "gp_instrument_shmem_size")
RG_MEM_FAIL=0; MEM_LOG=""; PARAMS_CHECKED=0; PARAMS_FAILED=0; PARAMS_SKIPPED=0
for PARAM in "${MEM_PARAMS[@]}"; do
    if [[ "$GP_MAJOR_VERSION" == "7" ]] && [[ " ${GP6_ONLY_PARAMS[*]} " == *" $PARAM "* ]]; then
        MEM_LOG+="\n[SKIPPED — GP7] ${PARAM}\n"; PARAMS_SKIPPED=$((PARAMS_SKIPPED+1)); continue
    fi
    OUTPUT=$(gpconfig -s "$PARAM" 2>&1); RET=$?
    PARAMS_CHECKED=$((PARAMS_CHECKED+1))
    MEM_LOG+="\n==================== $PARAM ====================\n$OUTPUT\n"
    if [[ $RET -ne 0 ]]; then RG_MEM_FAIL=1; PARAMS_FAILED=$((PARAMS_FAILED+1)); fi
done
COMPONENT_OUTPUT["Resource Group and Memory Param"]="$(printf '%b' "$MEM_LOG")"
ACTUAL_VAL["Resource Group and Memory Param"]="Checked: ${PARAMS_CHECKED}, Failed: ${PARAMS_FAILED}, Skipped: ${PARAMS_SKIPPED}"
if [[ $RG_MEM_FAIL -eq 1 ]]; then
    SUMMARY["Resource Group and Memory Param"]="FAIL"
    FAIL_REASON["Resource Group and Memory Param"]="${PARAMS_FAILED} parameter(s) could not be retrieved"
else
    SUMMARY["Resource Group and Memory Param"]="PASS"
    PASS_REASON["Resource Group and Memory Param"]="All ${PARAMS_CHECKED} GUC parameters readable and consistent"
fi
log_check "Resource Group and Memory Param"

# ── SECURITY ─────────────────────────────────────────────────
log_stage "Security"

if [[ "$GP_MAJOR_VERSION" == "7" ]]; then
    TRUST_COUNT=$(psql -p "$GP_PORT" -t -A -c \
        "SELECT count(*) FROM pg_hba_file_rules
         WHERE auth_method = 'trust' AND type != 'local';" 2>/dev/null | xargs)
    TRUST_LOCAL=$(psql -p "$GP_PORT" -t -A -c \
        "SELECT count(*) FROM pg_hba_file_rules
         WHERE auth_method = 'trust' AND type = 'local';" 2>/dev/null | xargs)
    COMPONENT_OUTPUT["Trust Authentication"]="Trust authentication rule counts (rule content withheld — contains network topology):
  Non-local trust rules : ${TRUST_COUNT:-0}   <- allows passwordless remote connections (should be 0)
  Local trust rules     : ${TRUST_LOCAL:-0}   <- local socket only (generally acceptable)

To investigate: SELECT count(*), type FROM pg_hba_file_rules WHERE auth_method='trust' GROUP BY type;"
else
    HBA_FILE=$(psql -p "$GP_PORT" -t -A -c "SHOW hba_file;" 2>/dev/null)
    TRUST_ALL=$(grep -vE "^[[:space:]]*#|^[[:space:]]*$" "$HBA_FILE" 2>/dev/null | grep "trust" || true)
    TRUST_COUNT=$(echo "$TRUST_ALL" | grep -cv "^local " || echo "0")
    TRUST_LOCAL=$(echo "$TRUST_ALL" | grep -c  "^local " || echo "0")
    COMPONENT_OUTPUT["Trust Authentication"]="Trust authentication rule counts (rule content withheld — contains network topology):
  Non-local trust rules : ${TRUST_COUNT:-0}   <- allows passwordless remote connections (should be 0)
  Local trust rules     : ${TRUST_LOCAL:-0}   <- local socket only (generally acceptable)

To investigate, review: ${HBA_FILE:-unknown}"
fi
ACTUAL_VAL["Trust Authentication"]="${TRUST_COUNT:-0} non-local trust auth rule(s) in pg_hba.conf"
if [[ "${TRUST_COUNT:-0}" -gt 0 ]]; then
    SUMMARY["Trust Authentication"]="FAIL"
    FAIL_REASON["Trust Authentication"]="${TRUST_COUNT} non-local trust auth rule(s) — users can connect without a password from these addresses"
else
    SUMMARY["Trust Authentication"]="PASS"
    PASS_REASON["Trust Authentication"]="No non-local trust authentication rules found"
fi
log_check "Trust Authentication"

SUPER_COUNT=$(psql -p "$GP_PORT" -t -A -c \
    "SELECT count(*) FROM pg_roles WHERE rolsuper = true;" 2>/dev/null | xargs)
NO_PASS_COUNT=$(psql -p "$GP_PORT" -t -A -c \
    "SELECT count(*) FROM pg_authid WHERE rolcanlogin = true AND rolpassword IS NULL;" 2>/dev/null | xargs)
LOGIN_COUNT=$(psql -p "$GP_PORT" -t -A -c \
    "SELECT count(*) FROM pg_authid WHERE rolcanlogin = true;" 2>/dev/null | xargs)
COMPONENT_OUTPUT["Privileged Roles"]="Role privilege summary (role names withheld to protect user account information):
  Superuser roles              : ${SUPER_COUNT:-0}   (benchmark: 1 — gpadmin only)
  Login roles without password : ${NO_PASS_COUNT:-0}   (benchmark: <= 1)
  Total login roles            : ${LOGIN_COUNT:-0}

To investigate: SELECT count(*), rolsuper, rolcanlogin, (rolpassword IS NULL) no_pwd
FROM pg_authid GROUP BY rolsuper, rolcanlogin, no_pwd ORDER BY rolsuper DESC;"
ACTUAL_VAL["Privileged Roles"]="${SUPER_COUNT:-0} superuser(s), ${NO_PASS_COUNT:-0} login role(s) with no password"
PRIV_FAIL=0; PRIV_DETAILS=""
[[ "${SUPER_COUNT:-0}" -gt 2 ]] && { PRIV_FAIL=1; PRIV_DETAILS+="${SUPER_COUNT} superusers (expected: gpadmin only); "; }
[[ "${NO_PASS_COUNT:-0}" -gt 1 ]] && { PRIV_FAIL=1; PRIV_DETAILS+="${NO_PASS_COUNT} login roles with no password set; "; }
if [[ "$PRIV_FAIL" -eq 1 ]]; then
    SUMMARY["Privileged Roles"]="FAIL"
    FAIL_REASON["Privileged Roles"]="$PRIV_DETAILS"
else
    SUMMARY["Privileged Roles"]="PASS"
    PASS_REASON["Privileged Roles"]="${SUPER_COUNT} superuser(s), ${NO_PASS_COUNT} passwordless login role(s) — within expected range"
fi
log_check "Privileged Roles"

# ═══════════════════════════════════════════════════════════════
# 9.  SCORECARD + FAILURE BANNER
# ═══════════════════════════════════════════════════════════════
FAIL_COUNT=0; PASS_COUNT=0; SKIP_COUNT=0
for k in "${SUMMARY_ORDER[@]}"; do
    case "${SUMMARY[$k]:-}" in
        FAIL)                FAIL_COUNT=$((FAIL_COUNT+1)) ;;
        PASS)                PASS_COUNT=$((PASS_COUNT+1)) ;;
        SKIPPED|SUGGESTION)  SKIP_COUNT=$((SKIP_COUNT+1)) ;;
    esac
done

cat >> "$HTML" <<EOF
<div class="scorecard">
  <div class="score-box s-fail">${FAIL_COUNT}<span>Failed</span></div>
  <div class="score-box s-pass">${PASS_COUNT}<span>Passed</span></div>
  <div class="score-box s-skip">${SKIP_COUNT}<span>Skipped / Suggestions</span></div>
</div>
EOF

if [[ "$FAIL_COUNT" -gt 0 ]]; then
    echo "<div class='banner banner-fail'>&#9888;&nbsp; ${FAIL_COUNT} CHECK(S) FAILED &mdash; Review highlighted rows below and share this report with the Tanzu account team.</div>" >> "$HTML"
else
    echo "<div class='banner banner-pass'>&#10003;&nbsp; All checks passed &mdash; No failures detected at time of report generation.</div>" >> "$HTML"
fi

# ═══════════════════════════════════════════════════════════════
# 10.  FAILURE SUMMARY PANEL  (only when failures exist)
# ═══════════════════════════════════════════════════════════════
echo "<a id='fail-summary'></a>" >> "$HTML"
if [[ "$FAIL_COUNT" -gt 0 ]]; then
    echo "<div class='fail-summary'>
<div class='fail-summary-hdr'>&#9888;&nbsp; Failure Summary &mdash; ${FAIL_COUNT} check(s) require immediate attention</div>
<div class='section-body'>
<table>
<thead>
<tr>
  <th class='col-name'>Check</th>
  <th class='col-prio'>Priority</th>
  <th class='col-actual'>What Was Found</th>
  <th class='col-detail'>Failure Reason</th>
  <th class='col-remedy'>Recommended Action</th>
</tr>
</thead>
<tbody>" >> "$HTML"
    for k in "${SUMMARY_ORDER[@]}"; do
        [[ "${SUMMARY[$k]:-}" != "FAIL" ]] && continue
        PRIO="${CHECK_PRIORITY[$k]:-Medium}"
        case "$PRIO" in Critical) PC="p-crit" ;; High) PC="p-high" ;; *) PC="p-med" ;; esac
        echo "<tr class='r-fail'>
  <td class='col-name'><b>$k</b></td>
  <td class='col-prio'><span class='prio ${PC}'>${PRIO}</span></td>
  <td class='col-actual'>$(html_escape "${ACTUAL_VAL[$k]:-—}")</td>
  <td class='col-detail'>$(html_escape "${FAIL_REASON[$k]:-—}")</td>
  <td class='col-remedy fs-remedy'>&#128295;&nbsp;$(html_escape "${REMEDY[$k]:-—}")</td>
</tr>" >> "$HTML"
    done
    echo "</tbody></table></div></div>" >> "$HTML"
fi

# ═══════════════════════════════════════════════════════════════
# 11.  SUMMARY TABLE  (with category separators)
# ═══════════════════════════════════════════════════════════════
echo "<a id='summary'></a>" >> "$HTML"
echo "<div class='section'>
<div class='section-header sh-blue'>&#128203; Greenplum Health Check Summary &mdash; 24 Checks</div>
<div class='section-body'>
<table>
<thead>
<tr>
  <th class='col-name'>Check</th>
  <th class='col-prio'>Priority</th>
  <th class='col-status'>Status</th>
  <th class='col-bench'>Benchmark / Expected</th>
  <th class='col-actual'>Actual Value Found</th>
  <th class='col-detail'>Failure Reason / Details</th>
  <th class='col-remedy'>Possible Remedy</th>
</tr>
</thead>
<tbody>" >> "$HTML"

LAST_CAT=""
for k in "${SUMMARY_ORDER[@]}"; do
    CAT="${CHECK_CATEGORY[$k]}"
    if [[ "$CAT" != "$LAST_CAT" ]]; then
        echo "<tr class='cat-row'><td colspan='7'>$CAT</td></tr>" >> "$HTML"
        LAST_CAT="$CAT"
    fi

    STATUS="${SUMMARY[$k]:-UNKNOWN}"
    PRIO="${CHECK_PRIORITY[$k]:-Medium}"
    BENCH="$(html_escape "${BENCHMARK[$k]:-—}")"
    ACTUAL="$(html_escape "${ACTUAL_VAL[$k]:-—}")"

    case "$STATUS" in
        PASS)                ROW="r-pass"; PILL="pill-pass"; REASON="$(html_escape "${PASS_REASON[$k]:-}")"
                             REM="&mdash;" ;;
        SKIPPED|SUGGESTION)  ROW="r-skip"; PILL="pill-skip"; REASON="$(html_escape "${FAIL_REASON[$k]:-}")"
                             REM="$(html_escape "${REMEDY[$k]:-—}")" ;;
        *)                   ROW="r-fail"; PILL="pill-fail"; REASON="$(html_escape "${FAIL_REASON[$k]:-}")"
                             REM="$(html_escape "${REMEDY[$k]:-—}")" ;;
    esac

    case "$PRIO" in
        Critical) PRIO_CLASS="p-crit" ;;
        High)     PRIO_CLASS="p-high" ;;
        *)        PRIO_CLASS="p-med"  ;;
    esac

    echo "<tr class='${ROW}'>
  <td class='col-name'><b>$k</b></td>
  <td class='col-prio'><span class='prio ${PRIO_CLASS}'>${PRIO}</span></td>
  <td class='col-status'><span class='pill ${PILL}'>${STATUS}</span></td>
  <td class='col-bench'>${BENCH}</td>
  <td class='col-actual'>${ACTUAL}</td>
  <td class='col-detail'>${REASON}</td>
  <td class='col-remedy'>${REM}</td>
</tr>" >> "$HTML"
done

echo "</tbody></table></div></div>" >> "$HTML"

# ═══════════════════════════════════════════════════════════════
# 11.  BLOAT / SKEW PER DATABASE
# ═══════════════════════════════════════════════════════════════
echo "<a id='bloat-skew'></a>" >> "$HTML"
echo "<div class='section'>
<div class='section-header sh-teal'>&#128202; Data Bloat / Skew per Database</div>
<div class='section-body'>
<p style='font-size:0.85em;color:#555;margin-bottom:10px;'>
  Bloat benchmark: tables &gt;${BLOAT_PAGE_THRESHOLD} pages (~50MB) with bloat ratio &gt;${BLOAT_THRESHOLD}% flagged. &nbsp;|&nbsp;
  Skew benchmark: skccoeff &gt;${SKEW_THRESHOLD} flagged.
</p>
<table>
<thead>
<tr>
  <th>DB OID</th><th>Database</th>
  <th>Bloat Status</th><th>Bloat Benchmark</th><th>Bloat Finding</th>
  <th>Skew Status</th><th>Skew Benchmark</th><th>Skew Finding</th>
</tr>
</thead>
<tbody>" >> "$HTML"

DBS=$(psql -p "$GP_PORT" -t -A -c \
    "SELECT datname FROM pg_database WHERE datistemplate=false AND datname!='postgres';" 2>/dev/null)

for DB in $DBS; do
    BLOAT_STATUS="PASS"; SKEW_STATUS="PASS"
    BLOAT_FINDING="No significant bloat detected"; SKEW_FINDING="No tables exceed skew threshold"
    DBOID=$(psql -p "$GP_PORT" -t -A -c "SELECT oid FROM pg_database WHERE datname='$DB';" 2>/dev/null)
    EXT=$(psql -p "$GP_PORT" -d "$DB" -t -A -c \
          "SELECT 1 FROM pg_namespace WHERE nspname='gp_toolkit';" 2>/dev/null)
    if [[ "$EXT" != "1" ]]; then
        BLOAT_STATUS="FAIL"; SKEW_STATUS="FAIL"
        BLOAT_FINDING="gp_toolkit schema not found"; SKEW_FINDING="gp_toolkit schema not found"
    else
        HIGH_BLOAT=$(psql -p "$GP_PORT" -d "$DB" -t -A -c \
            "SELECT count(*)
             FROM gp_toolkit.gp_bloat_expected_pages e
             JOIN pg_class c ON e.btdrelid = c.oid
             JOIN pg_namespace n ON c.relnamespace = n.oid
             WHERE e.btdrelpages > ${BLOAT_PAGE_THRESHOLD}
               AND e.btdrelpages > e.btdexppages
               AND ((e.btdrelpages::float - e.btdexppages) / nullif(e.btdexppages,0))*100 > ${BLOAT_THRESHOLD}
               AND n.nspname NOT LIKE 'pg_temp_%'
               AND n.nspname NOT LIKE 'pg_toast_temp_%'
               AND n.nspname NOT IN ('pg_catalog','pg_toast','pg_bitmapindex','pg_aoseg','information_schema','gp_toolkit');" \
            2>/dev/null)
        if [[ "$HIGH_BLOAT" =~ ^[0-9]+$ && "$HIGH_BLOAT" -gt 0 ]]; then
            BLOAT_STATUS="FAIL"
            BLOAT_FINDING="${HIGH_BLOAT} table(s) &gt;50MB with bloat &gt;${BLOAT_THRESHOLD}% — VACUUM or REORGANIZE recommended"
        elif ! [[ "$HIGH_BLOAT" =~ ^[0-9]+$ ]]; then
            BLOAT_STATUS="FAIL"; BLOAT_FINDING="Could not query gp_bloat_diag"
        fi
        SKEW_COL=$(psql -p "$GP_PORT" -d "$DB" -t -A -c \
            "SELECT column_name FROM information_schema.columns
             WHERE table_schema='gp_toolkit' AND table_name='gp_skew_coefficients'
               AND column_name='skccoeff';" 2>/dev/null)
        if [[ "$SKEW_COL" == "skccoeff" ]]; then
            HIGH_SKEW=$(psql -p "$GP_PORT" -d "$DB" -t -A -c \
                "SELECT count(*) FROM gp_toolkit.gp_skew_coefficients WHERE skccoeff > ${SKEW_THRESHOLD};" 2>/dev/null)
            if [[ "$HIGH_SKEW" =~ ^[0-9]+$ && "$HIGH_SKEW" -gt 0 ]]; then
                SKEW_STATUS="FAIL"
                SKEW_FINDING="${HIGH_SKEW} table(s) with skccoeff &gt;${SKEW_THRESHOLD} — data redistribution may help"
            fi
        else
            SKEW_STATUS="FAIL"; SKEW_FINDING="skccoeff column not found in gp_skew_coefficients"
        fi
    fi
    BC=$([[ "$BLOAT_STATUS" == "PASS" ]] && echo "tbl-pass" || echo "tbl-fail")
    SC=$([[ "$SKEW_STATUS"  == "PASS" ]] && echo "tbl-pass" || echo "tbl-fail")
    echo "<tr>
  <td>$DBOID</td><td>$DB</td>
  <td class='$BC'>$BLOAT_STATUS</td>
  <td style='font-style:italic;color:#555;font-size:0.85em;'>&gt;${BLOAT_PAGE_THRESHOLD} pages &amp; &gt;${BLOAT_THRESHOLD}% ratio</td>
  <td>$BLOAT_FINDING</td>
  <td class='$SC'>$SKEW_STATUS</td>
  <td style='font-style:italic;color:#555;font-size:0.85em;'>skccoeff &gt;${SKEW_THRESHOLD}</td>
  <td>$SKEW_FINDING</td>
</tr>" >> "$HTML"
done

echo "</tbody></table></div></div>" >> "$HTML"

# ═══════════════════════════════════════════════════════════════
# 12.  KERNEL PARAMETER COMPLIANCE
# ═══════════════════════════════════════════════════════════════
declare -A EXPECTED_KERNEL=(
  ["kernel.shmmni"]="4096"         ["vm.overcommit_memory"]="2"
  ["vm.overcommit_ratio"]="95"     ["net.ipv4.ip_local_port_range"]="10000 65535"
  ["kernel.sem"]="250 2048000 200 8192" ["kernel.sysrq"]="1"
  ["kernel.core_uses_pid"]="1"     ["kernel.msgmnb"]="65536"
  ["kernel.msgmax"]="65536"        ["kernel.msgmni"]="2048"
  ["net.ipv4.tcp_syncookies"]="1"  ["net.ipv4.conf.default.accept_source_route"]="0"
  ["net.ipv4.tcp_max_syn_backlog"]="4096" ["net.ipv4.conf.all.arp_filter"]="1"
  ["net.ipv4.ipfrag_high_thresh"]="41943040" ["net.ipv4.ipfrag_low_thresh"]="31457280"
  ["net.ipv4.ipfrag_time"]="60"    ["net.core.netdev_max_backlog"]="10000"
  ["net.core.rmem_max"]="2097152"  ["net.core.wmem_max"]="2097152"
  ["vm.swappiness"]="10"           ["vm.zone_reclaim_mode"]="0"
  ["vm.dirty_expire_centisecs"]="500" ["vm.dirty_writeback_centisecs"]="100"
  ["vm.dirty_background_ratio"]="0" ["vm.dirty_ratio"]="0"
  ["vm.dirty_background_bytes"]="1610612736" ["vm.dirty_bytes"]="4294967296"
)


echo "<a id='kernel'></a>" >> "$HTML"
echo "<div class='section'>
<div class='section-header sh-gray'>&#9881; Kernel Parameter Compliance</div>
<div class='section-body'>
<p style='font-size:0.85em;color:#555;margin-bottom:10px;'>
  Each kernel parameter is compared against the Greenplum-recommended baseline.
  Only mismatches are shown per host — fully compliant hosts show a single PASS row.
  Parameters not present on the running kernel (e.g. ipfrag_* on RHEL 9) are silently skipped.
</p>
<table>
<thead>
<tr style='background:#dce6f1;'>
  <th>Host</th><th class='col-status'>Status</th>
  <th>Kernel Parameter</th>
  <th class='k-exp'>Expected (Benchmark)</th>
  <th>Actual Value</th>
</tr>
</thead>
<tbody>" >> "$HTML"

CLUSTER_KERNEL_FAIL=0; CLUSTER_KERNEL_PASS=0
PARAM_LIST="${!EXPECTED_KERNEL[*]}"

while IFS= read -r HOST; do
    [[ -z "$HOST" || "$HOST" == \#* ]] && continue
    HOST_FAIL=0; FAIL_ROWS=""
    RAW_ALL=$(gpssh -h "$HOST" -e "sysctl $PARAM_LIST" 2>/dev/null)
    for PARAM in "${!EXPECTED_KERNEL[@]}"; do
        EXPECTED="${EXPECTED_KERNEL[$PARAM]}"
        RAW_VAL=$(echo "$RAW_ALL" | grep -E "^\[$HOST\].*${PARAM}[[:space:]]*=" | tail -1)
        ACTUAL=$(echo "$RAW_VAL" | sed "s/.*${PARAM}[[:space:]]*=[[:space:]]*//" | tr -d '\r' | xargs)
        [[ -z "$ACTUAL" || "$ACTUAL" == *"cannot stat"* || "$ACTUAL" == *"No such file"* ]] && continue
        if [[ "$ACTUAL" != "$EXPECTED" ]]; then
            HOST_FAIL=$((HOST_FAIL+1)); CLUSTER_KERNEL_FAIL=$((CLUSTER_KERNEL_FAIL+1))
            FAIL_ROWS+="<tr>
  <td>${HOST}</td><td class='k-fail'>FAIL</td>
  <td>${PARAM}</td>
  <td class='k-exp'>${EXPECTED}</td>
  <td style='color:#c0392b;font-weight:bold;'>${ACTUAL:-N/A}</td>
</tr>"
        fi
    done
    if [[ $HOST_FAIL -eq 0 ]]; then
        CLUSTER_KERNEL_PASS=$((CLUSTER_KERNEL_PASS+1))
        echo "<tr>
  <td>${HOST}</td><td class='k-pass'>PASS</td>
  <td colspan='3' style='text-align:center;color:#1e8449;'>
    All ${#EXPECTED_KERNEL[@]} kernel parameters match the Greenplum baseline</td>
</tr>" >> "$HTML"
    else
        echo "$FAIL_ROWS" >> "$HTML"
    fi
done < "$GPHOSTFILE_PATH"

echo "</tbody></table>
<p style='font-size:0.85em;color:#555;margin-top:8px;'>
  <b>${CLUSTER_KERNEL_PASS}</b> host(s) fully compliant &nbsp;|&nbsp;
  <b>${CLUSTER_KERNEL_FAIL}</b> total kernel parameter mismatch(es) across cluster.
</p>
</div></div>" >> "$HTML"

# ═══════════════════════════════════════════════════════════════
# 13.  CLUSTER COMPONENT DETAIL LOGS  (collapsible)
# ═══════════════════════════════════════════════════════════════

echo "<a id='detail-logs'></a>" >> "$HTML"
echo "<div class='section'>
<div class='section-header sh-purple'>&#128196; Cluster Component Detail Logs</div>
<div class='section-body'>
<p style='font-size:0.85em;color:#555;margin-bottom:12px;'>
  Click any check to expand its raw output. Each header shows the benchmark and actual value found.
  Entries marked FAIL contain the evidence for the failure in the output below.
</p>" >> "$HTML"

for NAME in "${SUMMARY_ORDER[@]}"; do
    OUTPUT="${COMPONENT_OUTPUT[$NAME]:-No output captured for this component.}"
    STATUS="${SUMMARY[$NAME]:-UNKNOWN}"
    BENCH_ESC="$(html_escape "${BENCHMARK[$NAME]:-—}")"
    ACTUAL_ESC="$(html_escape "${ACTUAL_VAL[$NAME]:-—}")"
    SAFE_OUTPUT="$(html_escape "$OUTPUT")"

    case "$STATUS" in
        PASS)               DET_CLASS="det-pass"; ICON="&#10003;" ;;
        SKIPPED|SUGGESTION) DET_CLASS="det-skip"; ICON="&#8505;" ;;
        *)                  DET_CLASS="det-fail"; ICON="&#9888;" ;;
    esac

    echo "<details class='${DET_CLASS}'>
<summary>
  ${ICON} &nbsp;<b>${NAME}</b> &nbsp;
  <span class='pill $( [[ "$STATUS" == "PASS" ]] && echo pill-pass || ([[ "$STATUS" =~ SKIP|SUGGESTION ]] && echo pill-skip || echo pill-fail) )'>${STATUS}</span>
  &nbsp;<span style='font-size:0.82em;font-weight:normal;color:#555;'>
    Benchmark: ${BENCH_ESC} &nbsp;|&nbsp; Found: ${ACTUAL_ESC}
  </span>
</summary>
<div class='det-body'><pre>${SAFE_OUTPUT}</pre></div>
</details>" >> "$HTML"
done

echo "</div></div>" >> "$HTML"

# ═══════════════════════════════════════════════════════════════
# 14.  PER-DATABASE DETAIL  (collapsible)
# ═══════════════════════════════════════════════════════════════
echo "<a id='db-detail'></a>" >> "$HTML"
echo "<div class='section'>
<div class='section-header sh-orange'>&#128260; Per-Database Detail: Skew / Missing Stats / Bloat / Distribution / Extensions</div>
<div class='section-body'>
<p style='font-size:0.85em;color:#555;margin-bottom:12px;'>
  Skew benchmark: skccoeff &le; ${SKEW_THRESHOLD} &nbsp;|&nbsp;
  Bloat benchmark: &le;${BLOAT_THRESHOLD}% ratio on tables &gt;${BLOAT_PAGE_THRESHOLD} pages &nbsp;|&nbsp;
  Missing stats benchmark: 0 tables.
</p>" >> "$HTML"

DB_NAMES=$(psql -p "$GP_PORT" -t -A -c \
    "SELECT datname FROM pg_database WHERE datistemplate=false AND datname!='postgres';" 2>/dev/null)

# Distribution key query (GP6/GP7 compatible)
if [[ "$GP_MAJOR_VERSION" == "7" ]]; then
    DIST_KEY_QUERY="SELECT n.nspname AS schema, c.relname AS table_name,
           pg_size_pretty(pg_total_relation_size(c.oid)) AS size,
           CASE dp.policytype
               WHEN 'p' THEN 'Partitioned'
               WHEN 'r' THEN 'RANDOM (no key)'
               ELSE array_to_string(ARRAY(
                   SELECT a.attname FROM pg_attribute a
                   WHERE a.attrelid=c.oid AND a.attnum=ANY(dp.attrnums)
                   ORDER BY a.attnum), ', ')
           END AS distribution
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    JOIN gp_distribution_policy dp ON dp.localoid = c.oid
    WHERE c.relkind = 'r'
      AND n.nspname NOT IN ('pg_catalog','information_schema','gp_toolkit','pg_aoseg')
    ORDER BY pg_total_relation_size(c.oid) DESC LIMIT 30;"
else
    DIST_KEY_QUERY="SELECT n.nspname AS schema, c.relname AS table_name,
           pg_size_pretty(pg_total_relation_size(c.oid)) AS size,
           CASE
               WHEN dp.attrnums IS NULL THEN 'RANDOM (no key)'
               ELSE array_to_string(ARRAY(
                   SELECT a.attname FROM pg_attribute a
                   WHERE a.attrelid=c.oid AND a.attnum=ANY(dp.attrnums)
                   ORDER BY a.attnum), ', ')
           END AS distribution
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    LEFT JOIN gp_distribution_policy dp ON dp.localoid = c.oid
    WHERE c.relkind = 'r'
      AND n.nspname NOT IN ('pg_catalog','information_schema','gp_toolkit','pg_aoseg')
    ORDER BY pg_total_relation_size(c.oid) DESC LIMIT 30;"
fi

for DB in $DB_NAMES; do
    echo "<details class='det-skip'>
<summary>&#128260; &nbsp;<b>Database: ${DB}</b> &nbsp;
  <span style='font-size:0.82em;font-weight:normal;color:#555;'>Click to expand all diagnostic queries</span>
</summary>
<div class='det-body'><pre>" >> "$HTML"

    declare -a DB_QUERIES=(
        "Top 20 Tables by Skew Coefficient (benchmark: skccoeff <= ${SKEW_THRESHOLD})|SELECT * FROM gp_toolkit.gp_skew_coefficients ORDER BY skccoeff DESC LIMIT 20;"
        "Top 20 Tables by Idle Fraction|SELECT * FROM gp_toolkit.gp_skew_idle_fractions ORDER BY siffraction DESC LIMIT 20;"
        "Tables with Missing Statistics (benchmark: 0 tables)|SELECT * FROM gp_toolkit.gp_stats_missing LIMIT 20;"
        "Top 20 Tables by Bloat (benchmark: ratio <= ${BLOAT_THRESHOLD}% on pages > ${BLOAT_PAGE_THRESHOLD})|SELECT n.nspname AS schema_name, c.relname AS table_name, e.btdrelpages AS actual_pages, e.btdexppages AS expected_pages, (e.btdrelpages - e.btdexppages) AS wasted_pages, ((e.btdrelpages - e.btdexppages) * 32) / 1024 AS wasted_mb, round(((e.btdrelpages::float - e.btdexppages) / nullif(e.btdexppages, 0)) * 100) AS bloat_pct FROM gp_toolkit.gp_bloat_expected_pages e JOIN pg_class c ON e.btdrelid = c.oid JOIN pg_namespace n ON c.relnamespace = n.oid WHERE e.btdrelpages > ${BLOAT_PAGE_THRESHOLD} AND e.btdrelpages > e.btdexppages AND ((e.btdrelpages::float - e.btdexppages) / nullif(e.btdexppages, 0)) * 100 > ${BLOAT_THRESHOLD} AND n.nspname NOT LIKE 'pg_temp_%' AND n.nspname NOT LIKE 'pg_toast_temp_%' AND n.nspname NOT IN ('pg_catalog','pg_toast','pg_bitmapindex','pg_aoseg','information_schema','gp_toolkit') ORDER BY wasted_pages DESC LIMIT 20;"
        "Top 30 Tables by Size with Distribution Keys|${DIST_KEY_QUERY}"
        "Installed Extensions|SELECT extname, extversion, extrelocatable FROM pg_extension ORDER BY extname;"
        "Database Size|SELECT pg_size_pretty(pg_database_size('${DB}')) AS database_size;"
    )

    for ENTRY in "${DB_QUERIES[@]}"; do
        LABEL="${ENTRY%%|*}"
        QUERY="${ENTRY##*|}"
        RAW=$(psql -p "$GP_PORT" -d "$DB" -c "$QUERY" 2>&1)
        SAFE=$(html_escape "$RAW")
        printf '%s\n%s\n\n' "--- ${LABEL} ---" "${SAFE}" >> "$HTML"
    done

    echo "</pre></div></details>" >> "$HTML"
done

echo "</div></div>" >> "$HTML"

# ═══════════════════════════════════════════════════════════════
# 15.  FOOTER
# ═══════════════════════════════════════════════════════════════
OVERALL_PILL="$([[ $FAIL_COUNT -gt 0 ]] && echo "pill-fail" || echo "pill-pass")"
echo "<div class='section' style='background:#f8f9fa;'>
<div class='section-body' style='padding:14px 20px;'>
  <p><b>Report completed:</b> $(date)</p>
  <p><b>Overall result:</b>
    <span class='pill ${OVERALL_PILL}'>
      ${FAIL_COUNT} FAIL(S) &nbsp;|&nbsp; ${PASS_COUNT} PASS &nbsp;|&nbsp; ${SKIP_COUNT} SKIPPED / SUGGESTION
    </span>
  </p>
  <p style='color:#922b21;margin-top:8px;'>
    &#9888; <b>Inspect this report for any confidential information before sending it to the Tanzu account team.</b>
  </p>
</div>
</div>
</body></html>" >> "$HTML"

# ─────────────────────────────────────────────────────────────
# TERMINAL SUMMARY
# ─────────────────────────────────────────────────────────────
printf "\n${_BLD}══════════════════════════════════════════════════════════${_RST}\n"
printf "${_BLD} Greenplum Health Check V3 — Complete${_RST}\n"
printf "${_BLD}══════════════════════════════════════════════════════════${_RST}\n"
printf " Report : %s\n" "$HTML"
printf "${_BLD}══════════════════════════════════════════════════════════${_RST}\n"
printf " ${_YLW}Inspect the report for confidential info before sharing.${_RST}\n"
