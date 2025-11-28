#!/bin/bash

# --------------------------------------------------
# SCRIPT: gp_healthcheck_html.sh
# AUTHOR: Abhishek Jain (Tanzu Product Value Engineering)
# DATE: November 27, 2025
# DESCRIPTION: Greenplum Health Check HTML Report Generation Script.
# --------------------------------------------------

#########################################
# Greenplum Health Check HTML Report
#########################################

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
    read -r -p 'gpcheckcat utility tests Greenplum Database catalog tables for inconsistencies and can take time to perform all tests. Do you want to run gpcheckcat? (y/n): ' GP_CHECK
    case "${GP_CHECK,,}" in
        y|yes) GP_CHECK=Y; break ;;
        n|no)  GP_CHECK=N; break ;;
        *) echo "Please answer y or n." ;;
    esac
done

echo "Greenplum health checks and report generation is in progress. Please wait..."

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
table { border-collapse: collapse; width:70%; }
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
declare -A NODE_DISK
declare -A NODE_CPU
declare -A NODE_MTU

#########################################
# Infra Checks (per host)
#########################################
DISK_FAIL=0
CPU_FAIL=0
MTU_FAIL=0

for HOST in $(cat "$GPHOSTFILE_PATH"); do

    # Disk Free Check (<15% = FAIL)
    DISK_OUT=$(ssh "$HOST" "df -h | grep -v tmpfs | grep -v overlay")
    NODE_DISK["$HOST"]="$DISK_OUT"
    while read -r line; do
        USEP=$(echo "$line" | awk '{print $5}' | tr -d '%')
        [[ -z "$USEP" ]] && continue
        FREE=$((100 - USEP))
        [[ "$FREE" -lt 15 ]] && DISK_FAIL=1
    done <<< "$DISK_OUT"

    # CPU Check (>80% = FAIL)
    CPU_LINE=$(ssh "$HOST" "top -b -n1 | grep 'Cpu(s)'")
    NODE_CPU["$HOST"]="$CPU_LINE"
    IDLE=$(echo "$CPU_LINE" | sed -n 's/.* \([0-9]*\.[0-9]*\) id.*/\1/p')
    [[ -n "$IDLE" ]] && USED=$(echo "100 - $IDLE" | bc | awk '{printf "%d",$1}')
    [[ "$USED" -gt 80 ]] && CPU_FAIL=1

    # MTU Check (<9000 = FAIL)
    MTU_OUT=$(ssh "$HOST" "ip link show | grep mtu")
    NODE_MTU["$HOST"]="$MTU_OUT"
    while read -r line; do
        MTU=$(echo "$line" | sed 's/.*mtu \([0-9]*\).*/\1/')
        [[ "$MTU" -lt 9000 ]] && MTU_FAIL=1
    done <<< "$MTU_OUT"

done

SUMMARY["Disk Free"]=$([[ $DISK_FAIL -eq 1 ]] && echo "FAIL" || echo "PASS")
SUMMARY["CPU Usage"]=$([[ $CPU_FAIL -eq 1 ]] && echo "FAIL" || echo "PASS")
SUMMARY["MTU"]=$([[ $MTU_FAIL -eq 1 ]] && echo "FAIL" || echo "PASS")
SUMMARY["Cluster Components Status"]="PENDING"
SUMMARY["Mirror Segment Status"]="PENDING"
SUMMARY["Standby Coordinator Status"]="PENDING"
SUMMARY["Catalog Integrity Check"]="PENDING"




run_check() {
    NAME="$1"
    CMD="$2"

    OUT=$(eval "$CMD" 2>&1)
    RET=$?

    if [[ $RET -eq 0 ]]; then
        SUMMARY["$NAME"]="PASS"
    else
        SUMMARY["$NAME"]="FAIL"
    fi

    # Still print in later detailed section
    COMPONENT_OUTPUT["$NAME"]="$OUT"
}

declare -A COMPONENT_OUTPUT

run_check "Cluster Components Status" "gpstate -s"
run_check "Mirror Segment Status" "gpstate -m"
run_check "Standby Coordinator Status" "gpstate -f"

# gpcheckcat (run before summary)
if [[ "$GP_CHECK" == "Y" ]]; then
    OUT=$(gpcheckcat -A -p $GP_PORT 2>&1)
    RET=$?

    COMPONENT_OUTPUT["Catalog Integrity Check"]="$OUT"

    if [[ $RET -eq 0 ]]; then
        SUMMARY["Catalog Integrity Check"]="PASS"
    else
        SUMMARY["Catalog Integrity Check"]="FAIL"
    fi
else
    SUMMARY["Catalog Integrity Check"]="SKIPPED"
    COMPONENT_OUTPUT["Catalog Integrity Check"]="gpcheckcat skipped by user"
fi

echo "Evaluating Greenplum Health Check Summary Status for all components..."
#########################################
# Top Summary Table
#########################################
echo "<section><h2>Greenplum Health Check Summary</h2><table><tr><th>Greenplum Test</th><th>Status</th></tr>" >> $HTML
for k in "${!SUMMARY[@]}"; do
    STATUS="${SUMMARY[$k]}"
   
   if [[ "$STATUS" == "PASS" ]]; then
    CLASS="pass_td"
   elif [[ "$STATUS" == "SKIPPED" ]]; then
    CLASS="skip_td"
   else
    CLASS="fail_td"
   fi

    echo "<tr><td>$k</td><td class='$CLASS'>$STATUS</td></tr>" >> $HTML
done
echo "</table></section>" >> $HTML



echo "Executing DB Checks (Bloat/Skew) Warnings..."
#########################################
# DB Checks (Bloat/Skew) Warnings per DB
#########################################
echo "<section><h2>Data Bloat/Skew Warnings per DB </h2>" >> $HTML

DBS=$(psql -t -A -c "SELECT datname FROM pg_database WHERE datistemplate=false AND datname!='postgres';")

for DB in $DBS; do
    BLOAT_FAIL=0
    SKEW_FAIL=0
    DBOID=$(psql -t -A -c "SELECT oid FROM pg_database WHERE datname ='$DB';")
    EXT=$(psql -d "$DB" -t -A -c "SELECT 1 FROM pg_extension WHERE extname='gp_toolkit';")
  
    if [[ "$EXT" != "1" ]]; then
        SUMMARY["$DBOID Bloat"]="SKIPPED"
        SUMMARY["$DBOID Skew"]="SKIPPED"
        
        echo -e "<ul><li><p style='color: orange;'> Warning: gp_toolkit not found in database $DBOID, skipping bloat/skew checks. \n </p></li></ul>" >> $HTML
        continue
    fi

    # Bloat Check
    COLS=$(psql -d "$DB" -t -A -c "
SELECT column_name FROM information_schema.columns
WHERE table_schema='gp_toolkit' AND table_name='gp_bloat_diag';
")
    BLOAT_THRESHOLD=30
    if [[ "$COLS" == *"bloat_pct"* ]]; then
        HIGH_BLOAT=$(psql -d "$DB" -t -A -c "
        SELECT COUNT(*) FROM gp_toolkit.gp_bloat_diag
        WHERE bloat_pct > $BLOAT_THRESHOLD;
        ")
        [[ "$HIGH_BLOAT" -gt 0 ]] && SUMMARY["$DBOID Bloat"]="FAIL" || SUMMARY["$DBOID Bloat"]="PASS"
    else
        SUMMARY["$DBOID Bloat"]="SKIPPED"
        echo -e "<ul><li><p style='color: orange;'> Warning: Cannot compute bloat for database $DBOID - missing bloat_pct column. \n </p></li></ul>" >> $HTML
    fi

    # Skew Check
    SKEW_THRESHOLD=1.5
    SKEW_COL=$(psql -d "$DB" -t -A -c "
SELECT column_name FROM information_schema.columns
WHERE table_schema='gp_toolkit' AND table_name='gp_skew_coefficients' AND column_name='skccoeff';
")
    if [[ "$SKEW_COL" == "skccoeff" ]]; then
        HIGH_SKEW=$(psql -d "$DB" -t -A -c "
        SELECT COUNT(*) FROM gp_toolkit.gp_skew_coefficients WHERE skccoeff>$SKEW_THRESHOLD;
        ")
        [[ "$HIGH_SKEW" -gt 0 ]] && SUMMARY["$DBOID Skew"]="FAIL" || SUMMARY["$DBOID Skew"]="PASS"
    else
        SUMMARY["$DBOID Skew"]="SKIPPED"
        echo -e "<ul><li><p style='color: orange;'> Warning: Cannot compute skew for database $DBOID - gp_skew_coefficients missing skccoeff. \n </p></li></ul>" >> $HTML
    fi

done


#########################################
# Detailed Logs from  Various Tests Output
#########################################

echo "<section><h2>Greenplum Detailed Logs from  Various Tests Output</h2><pre>" >> $HTML

echo "Executing Detailed Cluster Components Output..."
#########################################
# Detailed Cluster Components Output
#########################################
echo "<section><h2>Cluster Component Details</h2>. Check all GP components are in healthy state" >> $HTML

for NAME in "Cluster Components Status" "Mirror Segment Status" "Standby Coordinator Status" "Catalog Integrity Check"; do
    echo "<h3>$NAME</h3><pre>${COMPONENT_OUTPUT[$NAME]}</pre>" >> $HTML
done

echo "</section>" >> $HTML

echo "Executing Detail Per-Host Infra Details..."
#########################################
# Detail Per-Host Infra Details
#########################################
echo "<section><h2>Per-Host Infrastructure Details</h2>" >> $HTML
for HOST in $(cat "$GPHOSTFILE_PATH"); do
    echo "<h3>Host: $HOST</h3><pre>" >> $HTML
    echo "DISK:" >> $HTML
    echo "${NODE_DISK[$HOST]}" >> $HTML
    echo -e "\nCPU:" >> $HTML
    echo "${NODE_CPU[$HOST]}" >> $HTML
    echo -e "\nMTU:" >> $HTML
    echo "${NODE_MTU[$HOST]}" >> $HTML
    echo "</pre>" >> $HTML
done
echo "</section>" >> $HTML

echo "Executing Greenplum Nodes CPU UTILIZATION CHECK Details..."
##########################################
# Greenplum Nodes CPU UTILIZATION CHECK – FAIL IF > 80%
##########################################

echo "<section><h2>Greenplum nodes CPU Utilization Check  (FAIL IF > 80%) </h2><pre>" >> $HTML

# Collect CPU usage from all nodes
CPU_OUTPUT=$(gpssh -f "$GPHOSTFILE_PATH" -e "top -b -n1 | grep 'Cpu(s)'")

# Print raw output
echo "$CPU_OUTPUT" >> $HTML
echo "</pre>" >> $HTML

echo "Executing Greenplum Infra check - DISK FREE CHECK Details..."
##########################################
# Greenplum Infra check - DISK FREE CHECK – FAIL IF FREE < 15%
##########################################

echo "<section><h2>Greenplum Nodes Disk Free Space Check (FAIL IF FREE < 15% )</h2><pre>" >> $HTML

# Collect df output from all segment hosts
DISK_OUTPUT=$(gpssh -f "$GPHOSTFILE_PATH" -e "df -h | grep -v tmpfs | grep -v overlay")

# Print the raw disk info to HTML
echo "$DISK_OUTPUT" >> $HTML
echo "</pre>" >> $HTML

echo "Executing Greenplum Infra check - MTU CHECK Details..."
##########################################
# Greenplum Infra check - MTU CHECK – FAIL IF < 9000
##########################################

echo "<section><h2>Greenplum Network MTU Check (FAIL IF < 9000)</h2><pre>" >> $HTML

# Gather MTU values from all hosts
MTU_OUTPUT=$(gpssh -f "$GPHOSTFILE_PATH" -e "ip link show | grep -i mtu")

# Write full output to HTML
echo "$MTU_OUTPUT" >> $HTML

echo "</pre>" >> $HTML

echo "Executing Data SKEW / STATS / BLOAT Detalied Test Details..."
#########################################
# Data SKEW / STATS / BLOAT Detalied Test
#########################################

DB_NAMES=$(psql -t -A -c "SELECT datname FROM pg_database WHERE datistemplate = false AND datname != 'postgres';")

for DB in $DB_NAMES; do

    DB_OID=$(psql -t -A -c "SELECT oid FROM pg_database WHERE datname ='$DB';")
    echo "<section><h2>Database ID: $DB_OID</h2><pre>" >> $HTML

    psql -d "$DB" -c "SELECT * FROM gp_toolkit.gp_skew_coefficients ORDER BY skccoeff DESC LIMIT 20;" >> $HTML 2>&1
    psql -d "$DB" -c "SELECT * FROM gp_toolkit.gp_skew_idle_fractions ORDER BY siffraction DESC LIMIT 20;" >> $HTML 2>&1
    psql -d "$DB" -c "SELECT * FROM gp_toolkit.gp_stats_missing LIMIT 20;" >> $HTML 2>&1
    psql -d "$DB" -c "SELECT * FROM gp_toolkit.gp_bloat_diag LIMIT 20;" >> $HTML 2>&1
    psql -d "$DB" -c "SELECT * FROM gp_toolkit.gp_size_of_table_disk LIMIT 50;" >> $HTML 2>&1

    echo "</pre></section>" >> $HTML
done

echo "<h2>Greenplum Health Check HTML Report Completed: $(date) </h2>" >> $HTML
echo "<h3>Inspect the Greenplum HTML report for any confidential information before sending it to the Tanzu account team</h3>" >> $HTML
echo "</body></html>" >> $HTML
echo "Greenplum Health Check HTML report generated $(date) $HTML . Inspect the Greenplum HTML report for any confidential information before sending it to the Tanzu account team" 