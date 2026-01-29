#!/bin/bash

# --------------------------------------------------
# SCRIPT: gp_healthcheck_html.sh
# AUTHOR: Abhishek Jain (Tanzu Product Value Engineering)
# DATE: December 2, 2025
# DESCRIPTION: Greenplum Health Check HTML Report Generation Script with separate DB Bloat/Skew Summary.
# --------------------------------------------------


# ---------------- ERROR HANDLING & WATCHDOG ----------------


#fatal() {
 #   echo "[FATAL] $(date '+%Y-%m-%d %H:%M:%S') : $*" >&2
#}

#trap 'fatal "Error in ${FUNCNAME[0]:-MAIN} at line $LINENO: $BASH_COMMAND"' ERR

TIMEOUT_SEC=60   # Timeout for Disk/CPU/MTU checks

check_user() {
    if [[ $USER != "gpadmin" ]]; then
        echo "ERROR: Must run as gpadmin"
        exit 1
    fi
}

check_user

# Required inputs
while [[ -z "$Company" ]]; do
    read -p "What is your company name: " Company
done

while [[ -z "$GP_PORT" ]]; do
    read -p "Enter GPDB port (5432): " GP_PORT
    GP_PORT=${GP_PORT:-5432}
    if ! [[ "$GP_PORT" =~ ^[0-9]+$ ]]; then
        echo "Port must be a number."
        GP_PORT=""
    fi
done

while [[ -z "$GPHOSTFILE_PATH" ]]; do
    read -p "Enter path to hostfile: " GPHOSTFILE_PATH
    [[ ! -f "$GPHOSTFILE_PATH" ]] && echo "Hostfile not found." && GPHOSTFILE_PATH=""
done

# gpcheckcat prompt
while true; do
    read -r -p 'Do you want to run gpcheckcat? (y/n): ' GP_CHECK
    case "${GP_CHECK,,}" in
        y|yes) GP_CHECK=Y; break ;;
        n|no)  GP_CHECK=N; break ;;
        *) echo "Please answer y or n." ;;
    esac
done

echo "Starting Greenplum Health Check..."

TS=$(date +%Y%m%d_%H%M%S)
HTML="/home/gpadmin/gp_healthcheck_report_${TS}.html"

# Start HTML
cat > $HTML <<EOF
<html>
<head>
<title>Greenplum Health Report</title>
<style>
body { font-family: Arial; background:#f5f5f5; }
h1 { background:#004d99; padding:10px; color:white; }
section { background:white; margin:15px; padding:10px; border-radius:8px; }
.pass { color:green; font-weight:bold; }
.fail { color:red; font-weight:bold; }
pre { background:#eee; padding:10px; border-radius:5px; overflow-x:auto;}
table { border-collapse: collapse; width:80%; margin-bottom:20px;}
th, td { border: 1px solid #999; padding: 5px; text-align: center; }
th { background-color:#ddd; }
.pass_td { background-color: #b3ffb3; }
.fail_td { background-color: #ff9999; }
.skip_td { background-color: #ffff99; }
</style>
</head>
<body>
<h1>$Company Greenplum Health Check Report - $TS</h1>
EOF

declare -A SUMMARY
declare -A FAIL_REASON
declare -A PASS_REASON
declare -A NODE_DISK
declare -A NODE_CPU
declare -A NODE_MTU
declare -A COMPONENT_OUTPUT

#########################################
# Function to run commands with timeout (Disk/CPU/MTU)
#########################################
run_with_timeout() {
    local NAME="$1"
    local CMD="$2"
    local OUTPUT
    local RET

    OUTPUT=$(timeout $TIMEOUT_SEC bash -c "$CMD" 2>&1)
    RET=$?
    if [[ $RET -eq 124 ]]; then
        COMPONENT_OUTPUT["$NAME"]="Command timed out after $TIMEOUT_SEC seconds."
        return 1
    else
        COMPONENT_OUTPUT["$NAME"]="$OUTPUT"
        return 0
    fi
}

#########################################
# Infra Checks (Disk/CPU/MTU) per host
#########################################
DISK_FAIL=0
CPU_FAIL=0
MTU_FAIL=0

for HOST in $(cat "$GPHOSTFILE_PATH"); do

echo "Running Disk checks on host $HOST..."
    # Disk Free Check
    if run_with_timeout "Disk Free ($HOST)" "ssh $HOST 'df -h | grep -v tmpfs | grep -v overlay'"; then
        NODE_DISK["$HOST"]="${COMPONENT_OUTPUT["Disk Free ($HOST)"]}"
        while read -r line; do
            USEP=$(echo "$line" | awk '{print $5}' | tr -d '%')
            [[ -z "$USEP" ]] && continue
            FREE=$((100 - USEP))
            [[ "$FREE" -lt 25 ]] && DISK_FAIL=1
        done <<< "${NODE_DISK["$HOST"]}"
    else
        NODE_DISK["$HOST"]="${COMPONENT_OUTPUT["Disk Free ($HOST)"]}"
        DISK_FAIL=1
    fi

    # CPU Check
    echo "Running CPU checks on host $HOST..."
    if run_with_timeout "CPU Usage ($HOST)" "ssh $HOST 'top -b -n1 | grep \"Cpu(s)\"'"; then
        NODE_CPU["$HOST"]="${COMPONENT_OUTPUT["CPU Usage ($HOST)"]}"
        IDLE=$(echo "${NODE_CPU["$HOST"]}" | sed -n 's/.* \([0-9]*\.[0-9]*\) id.*/\1/p')
        [[ -n "$IDLE" ]] && USED=$(echo "100 - $IDLE" | bc | awk '{printf "%d",$1}')
        [[ "$USED" -gt 80 ]] && CPU_FAIL=1
    else
        NODE_CPU["$HOST"]="${COMPONENT_OUTPUT["CPU Usage ($HOST)"]}"
        CPU_FAIL=1
    fi

    # MTU Check
    echo "Running MTU checks on host $HOST..."
    if run_with_timeout "MTU Check ($HOST)" "ssh $HOST 'ip link show | grep mtu'"; then
        NODE_MTU["$HOST"]="${COMPONENT_OUTPUT["MTU Check ($HOST)"]}"
        while read -r line; do
            MTU=$(echo "$line" | sed 's/.*mtu \([0-9]*\).*/\1/')
            [[ "$MTU" -lt 9000 ]] && MTU_FAIL=1
        done <<< "${NODE_MTU["$HOST"]}"
    else
        NODE_MTU["$HOST"]="${COMPONENT_OUTPUT["MTU Check ($HOST)"]}"
        MTU_FAIL=1
    fi
done

# Populate summary with reasons
if [[ "$DISK_FAIL" -eq 1 ]]; then
    SUMMARY["Disk Free"]="FAIL"; FAIL_REASON["Disk Free"]="Disk free < 25% on one or more nodes"
else
    SUMMARY["Disk Free"]="PASS"; PASS_REASON["Disk Free"]="All disks >= 25% free"
fi

if [[ "$CPU_FAIL" -eq 1 ]]; then
    SUMMARY["CPU Usage"]="FAIL"; FAIL_REASON["CPU Usage"]="CPU usage > 80% on one or more nodes"
else
    SUMMARY["CPU Usage"]="PASS"; PASS_REASON["CPU Usage"]="All CPU usage <= 80%"
fi

if [[ "$MTU_FAIL" -eq 1 ]]; then
    SUMMARY["MTU"]="SUGGESTION"; FAIL_REASON["MTU"]="MTU < 9000 on one or more nodes.We recommend Jumbo Packets with MTU to be set ~9000 for best performance"
else
    SUMMARY["MTU"]="PASS"; PASS_REASON["MTU"]="All MTUs >= 9000"
fi

# Cluster component checks
echo "Running cluster component checks..."
OUTPUT=$(gpstate -s 2>&1); RET=$?; SUMMARY["Cluster Components Status"]=$([[ $RET -eq 0 ]] && echo "PASS" || echo "FAIL"); COMPONENT_OUTPUT["Cluster Components Status"]="$OUTPUT"
[[ "${SUMMARY["Cluster Components Status"]}" == "PASS" ]] && PASS_REASON["Cluster Components Status"]="All cluster components healthy" || FAIL_REASON["Cluster Components Status"]="gpstate -s shows issues"

OUTPUT=$(gpstate -m 2>&1); RET=$?; SUMMARY["Mirror Segment Status"]=$([[ $RET -eq 0 ]] && echo "PASS" || echo "FAIL"); COMPONENT_OUTPUT["Mirror Segment Status"]="$OUTPUT"
[[ "${SUMMARY["Mirror Segment Status"]}" == "PASS" ]] && PASS_REASON["Mirror Segment Status"]="Mirror segments healthy" || FAIL_REASON["Mirror Segment Status"]="Mirror segments report issues"

OUTPUT=$(gpstate -f 2>&1); RET=$?; SUMMARY["Standby Coordinator Status"]=$([[ $RET -eq 0 ]] && echo "PASS" || echo "FAIL"); COMPONENT_OUTPUT["Standby Coordinator Status"]="$OUTPUT"
[[ "${SUMMARY["Standby Coordinator Status"]}" == "PASS" ]] && PASS_REASON["Standby Coordinator Status"]="Standby coordinator available" || FAIL_REASON["Standby Coordinator Status"]="Standby coordinator issues detected"

if [[ "$GP_CHECK" == "Y" ]]; then
    OUTPUT=$(gpcheckcat -A -p $GP_PORT 2>&1); RET=$?
    COMPONENT_OUTPUT["Catalog Integrity Check"]="$OUTPUT"; SUMMARY["Catalog Integrity Check"]=$([[ $RET -eq 0 ]] && echo "PASS" || echo "FAIL")
    [[ "${SUMMARY["Catalog Integrity Check"]}" == "PASS" ]] && PASS_REASON["Catalog Integrity Check"]="Catalog integrity verified" || FAIL_REASON["Catalog Integrity Check"]="Catalog integrity check failed"
else
    SUMMARY["Catalog Integrity Check"]="SKIPPED"; COMPONENT_OUTPUT["Catalog Integrity Check"]="gpcheckcat skipped by user"; FAIL_REASON["Catalog Integrity Check"]="gpcheckcat skipped by user"
fi

#########################################
# Greenplum Resource Group / Memory Check
#########################################
echo "Running Greenplum Resource Group / Memory Checks..."
RG_MEM_FAIL=0
COMP_OUTPUT_MEM=""

# Fetch memory related parameters from gpconfig
MEM_PARAMS=("memory_spill_ratio" "query_mem" "statement_mem" "max_statement_mem")
for PARAM in "${MEM_PARAMS[@]}"; do
    OUTPUT=$(gpconfig -s $PARAM 2>&1)
    RET=$?
    COMPONENT_OUTPUT["$PARAM"]="$OUTPUT"
    if [[ $RET -ne 0 ]]; then
        RG_MEM_FAIL=1
    fi
done

# Add summary
if [[ $RG_MEM_FAIL -eq 1 ]]; then
    SUMMARY["Resource Group / Memory"]="FAIL"
    FAIL_REASON["Resource Group / Memory"]="One or more memory parameters(memory_spill_ratio,query_mem,statement_mem,max_statement_mem) not retrieved correctly"
else
    SUMMARY["Resource Group / Memory"]="PASS"
    PASS_REASON["Resource Group / Memory"]="All resource group memory parameters retrieved"
fi


#########################################
# Ordered Greenplum Test Summary Table
#########################################
echo "Building Summary Table..."
SUMMARY_ORDER=("Cluster Components Status" "Standby Coordinator Status" "Mirror Segment Status" "Catalog Integrity Check" "Disk Free" "CPU Usage" "MTU" "Resource Group / Memory")
echo "<section><h2>Greenplum Health Check Summary</h2><table>
<tr><th>Greenplum Test</th><th>Status</th><th>Reason</th></tr>" >> $HTML

for k in "${SUMMARY_ORDER[@]}"; do
    STATUS="${SUMMARY[$k]}"
    if [[ "$STATUS" == "PASS" ]]; then CLASS="pass_td"; REASON="${PASS_REASON[$k]}"
    elif [[ "$STATUS" == "SKIPPED" || "$STATUS" == "SUGGESTION" ]]; then CLASS="skip_td"; REASON="${FAIL_REASON[$k]}"
    else CLASS="fail_td"; REASON="${FAIL_REASON[$k]}"; fi
    echo "<tr><td>$k</td><td class='$CLASS'>$STATUS</td><td>$REASON</td></tr>" >> $HTML
done
echo "</table></section>" >> $HTML


#########################################
# DB Checks (Bloat/Skew) Test per DB with Fail Reason
#########################################
echo "<section><h2>Data Bloat/Skew Test per DB </h2><table><tr><th>DB OID</th><th>Database</th><th>Bloat Status</th><th>Bloat Fail Reason</th><th>Skew Status</th><th>Skew Fail Reason</th></tr>" >> $HTML

DBS=$(psql -t -A -c "SELECT datname FROM pg_database WHERE datistemplate=false AND datname!='postgres';")

for DB in $DBS; do
    BLOAT_FAIL_REASON=""
    SKEW_FAIL_REASON=""
    BLOAT_STATUS="PASS"
    SKEW_STATUS="PASS"
    DBOID=$(psql -t -A -c "SELECT oid FROM pg_database WHERE datname ='$DB';")
    EXT=$(psql -d "$DB" -t -A -c "SELECT 1 FROM pg_extension WHERE extname='gp_toolkit';")

    if [[ "$EXT" != "1" ]]; then
        BLOAT_STATUS="Failed"
        SKEW_STATUS="Failed"
        BLOAT_FAIL_REASON="Extension gp_toolkit not found"
        SKEW_FAIL_REASON="Extension gp_toolkit not found"
        echo "<tr><td>$DBOID</td><td>$DB</td><td>$BLOAT_STATUS</td><td>$BLOAT_FAIL_REASON</td><td>$SKEW_STATUS</td><td>$SKEW_FAIL_REASON</td></tr>" >> $HTML
        continue
    fi

    # Bloat Check
    COLS=$(psql -d "$DB" -t -A -c "SELECT column_name FROM information_schema.columns WHERE table_schema='gp_toolkit' AND table_name='gp_bloat_diag';")
    BLOAT_THRESHOLD=30
    if [[ "$COLS" == *"bloat_pct"* ]]; then
        HIGH_BLOAT=$(psql -d "$DB" -t -A -c "SELECT COUNT(*) FROM gp_toolkit.gp_bloat_diag WHERE bloat_pct > $BLOAT_THRESHOLD;")
        if [[ "$HIGH_BLOAT" -gt 0 ]]; then
            BLOAT_STATUS="FAIL"
            BLOAT_FAIL_REASON="Tables with bloat_pct > $BLOAT_THRESHOLD detected"
        fi
    else
        BLOAT_STATUS="Failed"
        BLOAT_FAIL_REASON="Missing bloat_pct column in gp_bloat_diag"
    fi

    # Skew Check
    SKEW_THRESHOLD=1.5
    SKEW_COL=$(psql -d "$DB" -t -A -c "SELECT column_name FROM information_schema.columns WHERE table_schema='gp_toolkit' AND table_name='gp_skew_coefficients' AND column_name='skccoeff';")
    if [[ "$SKEW_COL" == "skccoeff" ]]; then
        HIGH_SKEW=$(psql -d "$DB" -t -A -c "SELECT COUNT(*) FROM gp_toolkit.gp_skew_coefficients WHERE skccoeff>$SKEW_THRESHOLD;")
        if [[ "$HIGH_SKEW" -gt 0 ]]; then
            SKEW_STATUS="FAIL"
            SKEW_FAIL_REASON="Tables with skccoeff > $SKEW_THRESHOLD detected"
        fi
    else
        SKEW_STATUS="Failed"
        SKEW_FAIL_REASON="Missing skccoeff column in gp_skew_coefficients"
    fi

    SUMMARY["$DBOID Bloat"]=$BLOAT_STATUS
    FAIL_REASON["$DBOID Bloat"]=$BLOAT_FAIL_REASON
    SUMMARY["$DBOID Skew"]=$SKEW_STATUS
    FAIL_REASON["$DBOID Skew"]=$SKEW_FAIL_REASON

    echo "<tr><td>$DBOID</td><td>$DB</td><td>$BLOAT_STATUS</td><td>$BLOAT_FAIL_REASON</td><td>$SKEW_STATUS</td><td>$SKEW_FAIL_REASON</td></tr>" >> $HTML
done
echo "</table></section>" >> $HTML

##################kernel parameters check #########################
declare -A EXPECTED_KERNEL=(
  ["kernel.shmall"]="197951838"
  ["kernel.shmmax"]="810810728448"
  ["kernel.shmmni"]="4096"
  ["vm.overcommit_memory"]="2"
  ["vm.overcommit_ratio"]="95"
  ["net.ipv4.ip_local_port_range"]="65535"
  ["kernel.sem"]="8192"
  ["kernel.sysrq"]="1"
  ["kernel.core_uses_pid"]="1"
  ["kernel.msgmnb"]="65536"
  ["kernel.msgmax"]="65536"
  ["kernel.msgmni"]="2048"
  ["net.ipv4.tcp_syncookies"]="1"
  ["net.ipv4.conf.default.accept_source_route"]="0"
  ["net.ipv4.tcp_max_syn_backlog"]="4096"
  ["net.ipv4.conf.all.arp_filter"]="1"
  ["net.ipv4.ipfrag_high_thresh"]="41943040"
  ["net.ipv4.ipfrag_low_thresh"]="31457280"
  ["net.ipv4.ipfrag_time"]="60"
  ["net.core.netdev_max_backlog"]="10000"
  ["net.core.rmem_max"]="2097152"
  ["net.core.wmem_max"]="2097152"
  ["vm.swappiness"]="10"
  ["vm.zone_reclaim_mode"]="0"
  ["vm.dirty_expire_centisecs"]="500"
  ["vm.dirty_writeback_centisecs"]="100"
  ["vm.dirty_background_ratio"]="0"
  ["vm.dirty_ratio"]="0"
  ["vm.dirty_background_bytes"]="1610612736"
  ["vm.dirty_bytes"]="4294967296"
)

echo "Running kernel param complaiance Test..."

echo "<section><h2>Kernel Parameter Compliance</h2>" >> "$HTML"

CLUSTER_KERNEL_FAIL=0

# Start the main table
echo "<table border='1' cellspacing='0' cellpadding='4'>
        <tr style='background-color:#f2f2f2;'>
          <th>Host</th>
          <th>Status</th>
          <th>Kernel Parameter</th>
          <th>Expected Value</th>
          <th>Actual Value</th>
        </tr>" >> "$HTML"

for HOST in $(cat "$GPHOSTFILE_PATH"); do

    HOST_FAIL=0
    FAIL_ROWS=""

    for PARAM in "${!EXPECTED_KERNEL[@]}"; do
        EXPECTED="${EXPECTED_KERNEL[$PARAM]}"

        # Fetch the parameter value and strip hostname from gpssh output
        ACTUAL=$(gpssh -h "$HOST" -e "sysctl -n $PARAM" 2>/dev/null | tail -1 | awk '{print $NF}')

        if [[ "$ACTUAL" != "$EXPECTED" ]]; then
            HOST_FAIL=$((HOST_FAIL+1))
            CLUSTER_KERNEL_FAIL=$((CLUSTER_KERNEL_FAIL+1))

            # Append a row for the failing parameter
            FAIL_ROWS+="<tr>
                          <td>$HOST</td>
                          <td style='color:red;'><b>FAIL</b></td>
                          <td>$PARAM</td>
                          <td>$EXPECTED</td>
                          <td>${ACTUAL:-N/A}</td>
                        </tr>"
        fi
    done

    # If host passed all parameters, add one row showing PASS
    if [[ $HOST_FAIL -eq 0 ]]; then
        echo "<tr>
                <td>$HOST</td>
                <td style='color:green;'><b>PASS</b></td>
                <td colspan='3' style='text-align:center;'>All kernel parameters match baseline</td>
              </tr>" >> "$HTML"
    else
        # Append all failing rows for this host
        echo "$FAIL_ROWS" >> "$HTML"
    fi

done

# Close table
echo "</table>" >> "$HTML"



#########################################
# Detailed Cluster Component Logs
#########################################
echo "Adding Detailed Cluster Component Logs..."
echo "<section><h2>Cluster Component Details</h2>" >> $HTML
for NAME in "${SUMMARY_ORDER[@]:0}"; do
    echo "<h3>$NAME</h3><pre>${COMPONENT_OUTPUT[$NAME]}</pre>" >> $HTML
done
echo "</section>" >> $HTML

##########################################
# Combined Greenplum Infra Summary
##########################################
echo "Adding Combined Greenplum Nodes Summary..."
echo "<section><h2>Greenplum Nodes Nodes Summary</h2><pre>" >> $HTML
echo "CPU Utilization per Node (FAIL IF > 80%):" >> $HTML
CPU_OUTPUT=$(gpssh -f "$GPHOSTFILE_PATH" -e "top -b -n1 | grep 'Cpu(s)'"); echo "$CPU_OUTPUT" >> $HTML
echo -e "\n-----------------------------\n" >> $HTML

echo "Disk Free Space per Node (FAIL IF FREE < 25%):" >> $HTML
DISK_OUTPUT=$(gpssh -f "$GPHOSTFILE_PATH" -e "df -h | grep -v tmpfs | grep -v overlay"); echo "$DISK_OUTPUT" >> $HTML
echo -e "\n-----------------------------\n" >> $HTML

echo "MTU per Node (FAIL IF < 9000):" >> $HTML
MTU_OUTPUT=$(gpssh -f "$GPHOSTFILE_PATH" -e "ip link show | grep -i mtu"); echo "$MTU_OUTPUT" >> $HTML
echo "</pre></section>" >> $HTML

#########################################
# Data SKEW / STATS / BLOAT Detailed Test Logs
#########################################
echo "Adding Data SKEW / STATS / BLOAT Detailed Test Logs..."
DB_NAMES=$(psql -t -A -c "SELECT datname FROM pg_database WHERE datistemplate = false AND datname != 'postgres';")
for DB in $DB_NAMES; do
    DB_OID=$(psql -t -A -c "SELECT oid FROM pg_database WHERE datname ='$DB';")
    echo "<section><h2>Database ID: $DB_OID</h2><pre>" >> $HTML
    psql -d "$DB" -c "SELECT * FROM gp_toolkit.gp_skew_coefficients ORDER BY skccoeff DESC LIMIT 20;" >> $HTML 2>&1
    psql -d "$DB" -c "SELECT * FROM gp_toolkit.gp_skew_idle_fractions ORDER BY siffraction DESC LIMIT 20;" >> $HTML 2>&1
    psql -d "$DB" -c "SELECT * FROM gp_toolkit.gp_stats_missing LIMIT 20;" >> $HTML 2>&1
    psql -d "$DB" -c "SELECT * FROM gp_toolkit.gp_bloat_diag LIMIT 20;" >> $HTML 2>&1
    psql -d "$DB" -c "SELECT extname, extversion, extrelocatable, extconfig, extcondition FROM pg_extension;" >> $HTML 2>&1
    echo "</pre></section>" >> $HTML
done


#########################################
# Resource Memory details logs
#########################################
# Memory details log
echo "Adding Resource Memory details Logs..."
echo "<h3>Resource Group / Memory Parameters</h3><pre>${COMPONENT_OUTPUT["memory_spill_ratio"]}</pre>" >> $HTML
echo "<pre>${COMPONENT_OUTPUT["query_mem"]}</pre>" >> $HTML
echo "<pre>${COMPONENT_OUTPUT["statement_mem"]}</pre>" >> $HTML
echo "<pre>${COMPONENT_OUTPUT["max_statement_mem"]}</pre>" >> $HTML

#########################################
# Finish HTML
#########################################
echo "<h2>Greenplum Health Check HTML Report Completed: $(date) </h2>" >> $HTML
echo "<h3>Inspect the Greenplum HTML report for any confidential information before sending it to the Tanzu account team</h3>" >> $HTML
echo "</body></html>" >> $HTML

echo "Greenplum Health Check HTML report generated at $HTML"
echo "Inspect the Greenplum HTML report for any confidential information before sending it to the Tanzu account team"