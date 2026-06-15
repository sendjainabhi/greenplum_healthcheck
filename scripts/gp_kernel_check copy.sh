#!/bin/bash

# --------------------------------------------------
# SCRIPT: gp_kernel_audit_failures.sh
# COMPATIBILITY: Greenplum 6 & 7 (RHEL 7/8/9)
# DESCRIPTION: GP Kernel Filtered Audit - Reports ONLY Failures or Missing Parameters
# --------------------------------------------------

# Ensure running as gpadmin
if [[ $USER != "gpadmin" ]]; then
    echo "ERROR: Must run as gpadmin"
    exit 1
fi

# Get Hostfile
while [[ -z "$GPHOSTFILE_PATH" ]]; do
    read -p "Enter path to Greenplum hostfile: " GPHOSTFILE_PATH
    [[ ! -f "$GPHOSTFILE_PATH" ]] && echo "File not found." && GPHOSTFILE_PATH=""
done

TS=$(date +%Y%m%d_%H%M%S)
HTML="gp_kernel_exceptions_${TS}.html"

# Define Tanzu/Greenplum Recommended Baseline
declare -A EXPECTED_KERNEL=(
  ["kernel.shmmni"]="4096"
  ["vm.overcommit_memory"]="2"
  ["vm.overcommit_ratio"]="95"
  ["net.ipv4.ip_local_port_range"]="10000 65535"
  ["kernel.sem"]="250 64000 100 128"
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

# Start HTML Report
cat > "$HTML" <<EOF
<html>
<head>
<title>Greenplum Kernel Exceptions</title>
<style>
  body { font-family: Segoe UI, Arial, sans-serif; margin: 30px; background: #fdfdfd; }
  h2 { color: #b30000; border-bottom: 2px solid #b30000; padding-bottom: 10px; }
  table { border-collapse: collapse; width: 100%; background: white; margin-top: 20px; }
  th, td { border: 1px solid #ddd; padding: 12px; text-align: left; }
  th { background: #333; color: white; }
  .fail_text { color: #dc3545; font-weight: bold; }
  .na_text { color: #666; font-style: italic; }
  tr:hover { background-color: #f5f5f5; }
</style>
</head>
<body>
<h2>Greenplum Kernel Compliance Test</h2>
<p><strong>Note:</strong> This report only lists parameters that are <b>Incorrect</b> or <b>Missing (NA)</b>.</p>
<table>
<tr>
  <th>Host</th>
  <th>Parameter</th>
  <th>Expected Value</th>
  <th>Actual Value</th>
  <th>Status</th>
</tr>
EOF

echo "Greenplum Kernel Compliance Test Started..."

TOTAL_EXCEPTIONS=0

for HOST in $(cat "$GPHOSTFILE_PATH"); do
    for PARAM in "${!EXPECTED_KERNEL[@]}"; do
        EXPECTED="${EXPECTED_KERNEL[$PARAM]}"
        
        # GP6/GP7 compatible capture
        RAW_VAL=$(gpssh -h "$HOST" -e "sysctl -n $PARAM 2>/dev/null" 2>/dev/null | grep "\[$HOST\]" | tail -1)
        ACTUAL=$(echo "$RAW_VAL" | sed "s/.*\[$HOST\] //" | tr -d '\r' | xargs)

        # Logic: If result is empty (Missing/NA) OR doesn't match expected
        if [[ -z "$ACTUAL" ]]; then
            TOTAL_EXCEPTIONS=$((TOTAL_EXCEPTIONS+1))
            echo "<tr>
                    <td>$HOST</td>
                    <td>$PARAM</td>
                    <td>$EXPECTED</td>
                    <td class='na_text'>NA</td>
                    <td class='fail_text'>MISSING</td>
                  </tr>" >> "$HTML"
        elif [[ "$ACTUAL" != "$EXPECTED" ]]; then
            TOTAL_EXCEPTIONS=$((TOTAL_EXCEPTIONS+1))
            echo "<tr>
                    <td>$HOST</td>
                    <td>$PARAM</td>
                    <td>$EXPECTED</td>
                    <td>$ACTUAL</td>
                    <td class='fail_text'>FAIL</td>
                  </tr>" >> "$HTML"
        fi
    done
done

# If no issues were found, add a success message
if [[ $TOTAL_EXCEPTIONS -eq 0 ]]; then
    echo "<tr><td colspan='5' style='text-align:center; color:green; padding:20px;'><b>All parameters on all hosts are COMPLIANT.</b></td></tr>" >> "$HTML"
fi

cat >> "$HTML" <<EOF
</table>
</body>
</html>
EOF

echo "Greenplum Kernel Compliance Test Completed.Report generated: $HTML"
echo "Total issues found: $TOTAL_EXCEPTIONS"