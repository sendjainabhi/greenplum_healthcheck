#!/bin/bash


function check_user() {
    if [[ $USER != "gpadmin" ]]; then
        usage "you must be logged in as gpadmin to run greenplum health check"
    fi
}


echo 'To execute this health check script follow these instructions:'
echo 

read -p 'Enter the port of Greenplum  (5432): ' GP_PORT

read -p 'Enter the Greenplum Full path to segment host file: ' GPHOSTFILE_PATH 

# --- Configuration ---
LOG_FILE="/home/gpadmin/gp_health_check_$(date +%Y%m%d_%H%M%S).log"
# List of databases to check (exclude template and utility dbs)
DATABASES="postgres verizon"
# GP_PORT=5432
# GPHOSTFILE_PATH=/home/gpadmin/hostfile

echo "Greenplum Health Check started on $(date)" | tee -a $LOG_FILE
echo "Log file: $LOG_FILE" | tee -a $LOG_FILE
echo "--------------------------------------------------" | tee -a $LOG_FILE

# Function to execute a command and log the output
run_check() {
    echo "--- Running Check: $1 ---" | tee -a $LOG_FILE
    $2 >> $LOG_FILE 2>&1
    if [ $? -eq 0 ]; then
        echo "Check '$1' Passed." | tee -a $LOG_FILE
    else
        echo "Check '$1' Failed/Had Warnings. Check $LOG_FILE for details." | tee -a $LOG_FILE
    fi
    echo "--------------------------------------------------" | tee -a $LOG_FILE
}

# 1. Confirm all cluster components are up
run_check "Cluster Components Status" "gpstate -s"
# Check mirror segments status and synchronization
run_check "Mirror Segment Status" "gpstate -m"

# Check mirror segments status and synchronization
run_check "Standby coordinator Status" "gpstate -f"

#Check the cluster specification - 
echo "--- Checking GP Cluster Specifications ---" | tee -a $LOG_FILE
echo "--- Checking GP hostname from gp_segment_configuration  ---" | tee -a $LOG_FILE
psql  -c 'select distinct hostname from gp_segment_configuration order by 1;' | tee -a $LOG_FILE
psql -c 'SELECT version();' | tee -a $LOG_FILE

echo "--- Checking GP Cluster pg_available_extensions  ---" | tee -a $LOG_FILE
psql -c 'select * from pg_available_extensions order by name;' | tee -a $LOG_FILE

echo "--- Checking GP Cluster number of physical CPU sockets  ---" | tee -a $LOG_FILE

lscpu |grep 'Socket(s)'  | tee -a $LOG_FILE

echo "--- Checking GP Cluster information about the CPU  ---" | tee -a $LOG_FILE
lscpu |grep 'Core(s)' | tee -a $LOG_FILE

echo "--- Checking GP cluster all segmets are running   ---" | tee -a $LOG_FILE
psql -c 'SELECT * FROM gp_segment_configuration ORDER BY hostname, datadir;' | tee -a $LOG_FILE



# 2. Verify metadata consistency across all databases
#for db in $DATABASES; do
 #   run_check "Metadata Consistency Check for DB: $db" "gpcheckcat -O -d $db"
#done

echo "--- Verify metadata consistency across all databases   ---" | tee -a $LOG_FILE
gpcheckcat -A   -p $GP_PORT | tee -a $LOG_FILE




# 3. Check gp_vmem_protect_limit and statement_mem parameters

#create gp_toolkit externsion if it does not exist

psql -t -A -c "SELECT extname FROM pg_extension" | grep -i gp_toolkit 
# Check the exit status of grep
if [ $? -eq 0 ]; then
    echo "The gp_toolkit  extension exists in database"
else
    echo "The  extension does not exist in database , create gp_toolkit extension"

    psql -c 'CREATE EXTENSION gp_toolkit;'
fi

echo "--- Checking Greenplum resource group specification  ---" | tee -a $LOG_FILE
psql  -c  'Select * from gp_toolkit.gp_resgroup_config' |  tee -a $LOG_FILE


echo "--- Checking Memory Parameters ---" | tee -a $LOG_FILE
echo "Show gp_vmem_protect_limit " | tee -a $LOG_FILE
gpconfig -s gp_vmem_protect_limit | tee -a $LOG_FILE

echo "Show statement_mem: " | tee -a $LOG_FILE
gpconfig -s statement_mem | tee -a $LOG_FILE
echo "Show  max_connections: " | tee -a $LOG_FILE
gpconfig -s max_connections

echo "Show gp_resqueue_memory_policy: " | tee -a $LOG_FILE
psql -c "SHOW gp_resqueue_memory_policy;" | tee -a $LOG_FILE
echo "--------------------------------------------------" | tee -a $LOG_FILE

# 4. Data Skew, Stats & Bloat (using gp_toolkit views)

# Connect to the Greenplum instance and list all databases
# The -t option suppresses column names and row count footers,
# and -A suppresses alignment, making the output easier to parse.
# The -c option executes the SQL command.

DB_NAMES=$(psql -t -A -c  "SELECT datname FROM pg_database WHERE datistemplate = false AND datname != 'postgres';")

echo "DB Names : $DB_NAMES " | tee -a $LOG_FILE


# Loop through each database name
for DB_NAME  in $DB_NAMES; do
  echo "----------------Processing database Start: $DB_NAME  --------------------------"    | tee -a $LOG_FILE

echo " Show gp_skew_coefficients "  | tee -a $LOG_FILE
psql -c  'SELECT * FROM gp_toolkit.gp_skew_coefficients ORDER BY skccoeff DESC LIMIT 20;' | tee -a $LOG_FILE

echo "Show gp_skew_idle_fractions  " | tee -a $LOG_FILE
psql  -c 'SELECT * FROM gp_toolkit.gp_skew_idle_fractions ORDER BY siffraction DESC LIMIT 20;' | tee -a $LOG_FILE

echo "Show gp_stats_missing  " | tee -a $LOG_FILE
 psql -c 'SELECT * FROM gp_toolkit.gp_stats_missing LIMIT 20;' | tee -a $LOG_FILE

 echo "Show gp_bloat_diag: This view helps diagnose which tables have significant storage bloat." | tee -a $LOG_FILE

 psql -c 'SELECT * FROM gp_toolkit.gp_bloat_diag LIMIT 20;' | tee -a $LOG_FILE

 echo "Show gp_size_of_table_disk: View the size of tables on disk." | tee -a $LOG_FILE
 psql -c  'SELECT * FROM gp_toolkit.gp_size_of_table_disk;' | tee -a $LOG_FILE

 echo "----------------Processing database End: $DB_NAME --------------------------" | tee -a $LOG_FILE

done


# 5. Checking for disk free space
echo "--- Checking for Disk Free Space ---" | tee -a $LOG_FILE
# This command checks all mounted filesystems on all hosts where segments reside
gpssh -f $GPHOSTFILE_PATH -e 'df -h' | tee -a $LOG_FILE
# You can use 'df -h' on the master as well
df -h >> $LOG_FILE 2>&1
echo "--------------------------------------------------" | tee -a $LOG_FILE


echo "Greenplum Health Check finished on $(date)" | tee -a $LOG_FILE

