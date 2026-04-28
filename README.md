# Oracle Health Check Tool

A read-only Oracle health check script for Linux database servers.

`oracle_health_check.sh` collects operating system, Oracle listener, database, RAC, multitenant, and Data Guard information when the required Oracle tools and environment are available. It prints a plain text report and saves the same output to a timestamped log file by default.

## Safety

This tool is designed for reporting only. It does not start, stop, create, delete, modify, or reconfigure Oracle, RAC, Data Guard, listener, database objects, or Linux settings.

The script only:

- reads OS and Oracle health information
- runs read-only SQL queries through `sqlplus`
- writes a text report file

## Requirements

Minimum requirements for OS-level checks:

- Linux shell environment
- `bash`
- standard Linux tools such as `date`, `hostname`, `df`, `free`, `ps`, and `uptime`

Optional Oracle requirements for database-level checks:

- Oracle database server access
- `sqlplus`
- `ORACLE_HOME`
- `ORACLE_SID`
- permission to connect locally as `/ as sysdba`

Optional Oracle tools:

- `lsnrctl` for listener status

If Oracle variables or tools are missing, the script still runs the OS sections and explains which database checks were skipped.

## Quick Start

Copy the folder to the Oracle database server, then run:

```bash
cd /path/to/oracle-health-check
chmod +x oracle_health_check.sh
./oracle_health_check.sh
```

By default, the script prints the report to the terminal and saves a timestamped log file in the script directory:

```text
oracle_health_check_YYYYMMDD_HHMMSS.log
```

For full database results, run as the Oracle software owner or another user that can connect locally as SYSDBA:

```bash
sudo su - oracle
cd /path/to/oracle-health-check
./oracle_health_check.sh
```

## Oracle Environment Setup

For best results, set the Oracle environment before running the script:

```bash
export ORACLE_HOME=/u01/app/oracle/product/19.0.0/dbhome_1
export ORACLE_SID=ORCL
export PATH=$ORACLE_HOME/bin:$PATH
./oracle_health_check.sh
```

If `ORACLE_HOME` is not set, the script tries to resolve it from the `sqlplus` path. If `ORACLE_SID` is not set and exactly one PMON process is found, the script uses that SID automatically. If multiple PMON processes are found, set `ORACLE_SID` explicitly.

## Command Line Options

Show help:

```bash
./oracle_health_check.sh -h
```

Write to a specific report file:

```bash
./oracle_health_check.sh -o /tmp/oracle_health_prod1.log
```

Run silently and only write the report file:

```bash
./oracle_health_check.sh -s
```

Print only the top summary sections:

```bash
./oracle_health_check.sh --summary-only
```

Combine options:

```bash
./oracle_health_check.sh --summary-only -s -o /tmp/oracle_health_summary.log
```

## What The Report Includes

The report starts with operator-focused summary sections:

- traffic light summary
- exceptions summary with only non-green items
- resolved Oracle environment
- RAC summary
- Data Guard summary
- database summary

In normal mode, it also includes detailed sections for:

- hostname, date, time, and uptime
- filesystem usage
- memory usage
- top CPU processes
- Oracle PMON processes
- listener status when `lsnrctl` is available
- database instance status
- RAC instance status
- multitenant and PDB status
- invalid objects count
- failed scheduler jobs in the last 24 hours
- sessions and processes usage
- temp tablespace usage
- tablespace usage summary
- FRA and archive destination usage
- archive destination errors
- alert log locations

Use `--summary-only` when you only want the high-level sections and exception list.

## Traffic Light Status

The script uses simple status labels:

- `GREEN`: the tracked check completed without a warning threshold
- `AMBER`: review is recommended
- `RED`: a critical threshold or failure condition was detected

The overall status becomes `AMBER` or `RED` when any tracked section reaches that level.

## Thresholds

Database warning thresholds:

- invalid objects: 1 or more is `AMBER`
- failed scheduler jobs in last 24 hours: 1 or more is `AMBER`
- sessions or processes usage: 85% or higher is `AMBER`
- temp usage: 85% or higher is `AMBER`
- FRA usage: 85% or higher is `AMBER`
- Data Guard transport or apply lag: 15 minutes or higher is `AMBER`

Database critical thresholds:

- invalid objects: 100 or more is `RED`
- failed scheduler jobs in last 24 hours: 10 or more is `RED`
- sessions or processes usage: 95% or higher is `RED`
- temp usage: 95% or higher is `RED`
- FRA usage: 95% or higher is `RED`
- Data Guard transport or apply lag: 60 minutes or higher is `RED`
- archive destination errors are `RED`
- physical standby managed recovery not running is `RED`
- RAC instances not `OPEN` or `MOUNTED` are `RED`

Missing optional tools or unavailable Oracle views are usually reported as `AMBER` so the report can continue safely.

## RAC Checks

The RAC summary uses multiple signals:

- `cluster_database` from `v$parameter`
- instance count from `gv$instance`
- PMON process discovery as a fallback

When RAC information is available, the report shows:

- detected mode: standalone, RAC, or unknown
- cluster database setting
- current instance name, host, status, and startup time
- `gv$instance` count
- all instances from `gv$instance`

If `gv$instance` cannot be read, the script marks the RAC section as `AMBER` and continues.

Example RAC run:

```bash
export ORACLE_SID=ORCL1
./oracle_health_check.sh -o /tmp/orcl1_health.log
```

## Multitenant Checks

When database views are available, the report shows:

- whether the database is a CDB
- current container name
- PDB count
- PDB open modes in the detailed database section

These checks rely on `v$database`, `v$pdbs`, and `sys_context('USERENV', 'CON_NAME')`.

## Data Guard Checks

The Data Guard summary reports:

- database role
- open mode
- protection mode
- switchover status
- force logging
- archive log mode
- transport lag
- apply lag
- managed recovery status on standby databases
- archive destination errors

Example primary run:

```bash
export ORACLE_SID=PROD1
./oracle_health_check.sh -o /tmp/prod1_primary_health.log
```

Example standby run:

```bash
export ORACLE_SID=PROD1STB
./oracle_health_check.sh -o /tmp/prod1_standby_health.log
```

If Data Guard views are unavailable or the current user lacks privileges, the script marks the section as `AMBER` and continues with the rest of the report.

## Troubleshooting

If database checks are skipped:

- confirm `sqlplus` is installed or on `PATH`
- confirm `ORACLE_HOME` is set correctly
- confirm `ORACLE_SID` is set correctly
- run as the Oracle software owner if local SYSDBA authentication is required

If multiple PMON processes are found:

```bash
export ORACLE_SID=ivory1
./oracle_health_check.sh -o /tmp/rac_health_ivory1.log
```

If listener checks are skipped:

- confirm `lsnrctl` is on `PATH`
- confirm `ORACLE_HOME/bin` is included in `PATH`

If RAC, multitenant, FRA, or Data Guard details are incomplete:

- confirm the connected user has privileges to read the required dynamic performance views
- review the detailed database section for Oracle errors
- verify the feature is configured for that database

## Notes

- `lsnrctl` is optional.
- FRA information depends on Oracle recovery area configuration.
- RAC and Data Guard sections rely on Oracle dynamic performance views.
- The report is a point-in-time health snapshot, not a monitoring daemon.
- The script continues when optional views or tools are unavailable.
