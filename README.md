# Oracle Health Check Tool

This project is a beginner-friendly, read-only Oracle health check tool for Linux Oracle database servers.

The main script is:

- `oracle_health_check.sh`

It collects Linux server details and Oracle database details when Oracle tools and environment settings are available.

## Safety

This script is safe and read-only.

It does not:

- start or stop Oracle
- change database settings
- create database objects
- modify listener configuration
- change RAC configuration
- change Data Guard configuration
- delete or update server files

It only reads information and writes a plain text report file.

## New Features In This Version

- RAC awareness
- multitenant awareness
- Data Guard awareness
- traffic light logic for RAC and Data Guard
- graceful handling when RAC or Data Guard views are unavailable
- clear section-based output
- beginner-friendly comments inside the script

## What It Checks

The script displays:

- hostname
- date and time
- OS uptime
- filesystem usage
- memory usage
- top CPU processes
- Oracle PMON processes
- listener status if `lsnrctl` exists
- traffic light summary with `GREEN`, `AMBER`, and `RED`
- exceptions summary that lists only non-green items
- RAC summary
- multitenant summary
- Data Guard summary
- database instance status if `sqlplus` works
- invalid objects count
- failed scheduler jobs in last 24 hours
- sessions vs processes usage
- temp tablespace usage
- archive destination / FRA usage where available
- tablespace usage summary
- alert log location if available

## RAC Awareness

The script detects whether the database is:

- standalone
- RAC

The RAC summary section shows:

- whether cluster database is enabled
- current instance name
- host name
- all instances from `gv$instance`
- instance status and startup time

If `gv$instance` is unavailable, the script handles that safely and continues.

The script also checks multitenant information when available:

- whether the database is a CDB
- current container name
- PDB count


## Data Guard Awareness

The script detects whether the database is:

- `PRIMARY`
- `PHYSICAL STANDBY`
- `LOGICAL STANDBY`

The Data Guard summary section shows:

- database role
- open mode
- protection mode
- switchover status
- force logging
- archive log mode
- transport lag if available
- apply lag if available
- managed recovery status if standby
- archive destination errors if any

If Data Guard views are unavailable, the script handles that safely and continues.

## Traffic Light Summary

At the top of the report, you will see a simple summary:

- `GREEN` means healthy
- `AMBER` means a warning or something needs attention
- `RED` means a critical threshold was hit

The script uses this logic for RAC and Data Guard too.

Right below the traffic light summary, the report now includes an `EXCEPTIONS SUMMARY` section. This section only lists warning or critical items so an operator can quickly scan what needs attention.

Examples:

- `RED` for critical RAC or Data Guard issues
- `AMBER` for warning situations such as lag thresholds or unavailable views
- `GREEN` when the checks look healthy

## Command Line Options

Show help:

```bash
./oracle_health_check.sh -h
```

Run silently and only write the report file:

```bash
./oracle_health_check.sh -s
```

Write to a specific report file:

```bash
./oracle_health_check.sh -o /tmp/oracle_health_prod1.log
```

Use both together:

```bash
./oracle_health_check.sh -s -o /tmp/oracle_health_prod1.log
```

## Exact Run Steps

1. Copy this folder to your Linux Oracle server.
2. Open a terminal session on the Linux server.
3. Go to the folder:

```bash
cd /path/to/oracle-health-check
```

4. Make the script executable:

```bash
chmod +x oracle_health_check.sh
```

5. Run the script:

```bash
./oracle_health_check.sh
```

6. The script prints the report and saves a report file.

## Best Practice For Oracle Checks

If you want full Oracle database results, load the Oracle environment first.

Example:

```bash
export ORACLE_HOME=/u01/app/oracle/product/19.0.0/dbhome_1
export ORACLE_SID=ORCL
export PATH=$ORACLE_HOME/bin:$PATH
./oracle_health_check.sh
```

If your site uses the Oracle user:

```bash
sudo su - oracle
cd /path/to/oracle-health-check
./oracle_health_check.sh -o /tmp/oracle_health_orcl.log
```

## RAC Examples

Run on a RAC server and write the report to a named file:

```bash
./oracle_health_check.sh -o /tmp/rac_health_orcl1.log
```

If multiple PMON processes are found, set `ORACLE_SID` explicitly:

```bash
export ORACLE_SID=ORCL1
./oracle_health_check.sh -o /tmp/orcl1_health.log
```

## Data Guard Examples

Run on a primary database server:

```bash
export ORACLE_SID=PROD1
./oracle_health_check.sh -o /tmp/prod1_primary_health.log
```

Run on a standby database server:

```bash
export ORACLE_SID=PROD1STB
./oracle_health_check.sh -o /tmp/prod1_standby_health.log
```

## Handling Missing Oracle Variables

The script handles missing Oracle variables gracefully.

If `ORACLE_HOME` is missing:

- the script still runs OS checks
- it checks whether `sqlplus` is already on `PATH`
- if possible, it resolves `ORACLE_HOME` from the `sqlplus` binary path
- if needed, it explains that database checks were skipped

If `ORACLE_SID` is missing:

- the script still runs OS checks
- if exactly one PMON process is found, it uses that SID automatically
- if multiple PMON processes are found, it tells you to set `ORACLE_SID` explicitly

## Troubleshooting Real RAC Servers

If your server has multiple PMON processes, set `ORACLE_SID` to the specific instance you want to query before running the script.

Example:

```bash
export ORACLE_SID=ivory1
./oracle_health_check.sh -o /tmp/rac_health_ivory1.log
```

For RAC detection, the script now uses multiple signals:

- `cluster_database` from `v$parameter`
- instance count from `gv$instance`
- PMON detection as a fallback

For multitenant visibility, it checks `v$database`, `sys_context('USERENV','CON_NAME')`, and `v$pdbs` when available.

## Notes

- `lsnrctl` is optional. If it does not exist, listener checks are skipped.
- FRA information depends on Oracle configuration and privileges.
- RAC and Data Guard sections rely on Oracle dynamic performance views.
- If the current user does not have the needed privileges, Oracle may return limited data for some sections while the rest of the report still prints.

## Read-Only Reminder

This tool is for reporting only.
It does not make Oracle, RAC, Data Guard, or OS configuration changes.
