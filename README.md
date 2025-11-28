


## Greenplum Healthcheck: Deployment Guide

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
