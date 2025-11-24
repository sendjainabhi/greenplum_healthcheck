


## Deployment Instructions

We recommend executing the GP Health check script in restrictive mode during off hours. This is because certain tests, such as `gpcheckcat` and functions like `gp_size_of_table_disk`, may take longer to execute in production.

- Log in to your Greenplum environment as the `gpadmin` user.

- Clone the Git repository `https://github.com/sendjainabhi/greenplum_healthcheck.git`.

- Copy the `/scripts/gp_healthcheck.sh` script into your Greenplum coordination host’s `/home/gpadmin/` directory.

- Assign the script with the `chmod +x gp7_healthcheck.sh` permission.

- Execute the `gp_healthcheck.sh` script and wait for the process to complete, generating the log file `gp_health_check_<timestamp>.log`.

- Inspect the log file for any confidential information before sending it to the Tanzu account team. 
 