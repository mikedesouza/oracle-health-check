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
- delete or update server files

It only reads information and writes a plain text report file.

## New Features In This Version

- a traffic light summary at the top with `GREEN`, `AMBER`, and `RED`
- command line options: `-o <file>`, `-s`, and `-h`
- Oracle checks for invalid objects, failed scheduler jobs, sessions vs processes usage, temp usage, and FRA usage
- clean colorless output
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
- database instance status if `sqlplus` works
- database open mode
- database role
- startup time
- invalid objects count
- failed scheduler jobs in last 24 hours
- sessions vs processes usage
- temp tablespace usage
- archive log destination / FRA usage where available
- tablespace usage summary
- alert log location if available

## Requirements

- Linux server
- Bash shell
- Oracle database server or Oracle client tools if you want database checks
- access to run the script on the server

For the Oracle database section, it is best to run the script as the Oracle software owner, often `oracle`.

## Files

- `oracle_health_check.sh` - main health check script
- `README.md` - instructions and examples

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

## Traffic Light Summary

At the top of the report, you will see a simple summary:

- `GREEN` means healthy
- `AMBER` means a warning or something needs attention
- `RED` means a critical threshold was hit

The overall status is based on what the script can see safely.

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
./oracle_health_check.sh
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

## Example Commands

Run standard report:

```bash
./oracle_health_check.sh
```

Run silently and write a named report file:

```bash
./oracle_health_check.sh -s -o /var/tmp/oracle_prod1_health.log
```

Run with Oracle environment set:

```bash
export ORACLE_HOME=/u01/app/oracle/product/19.0.0/dbhome_1
export ORACLE_SID=PROD1
export PATH=$ORACLE_HOME/bin:$PATH
./oracle_health_check.sh -o /tmp/prod1_health.log
```

## Notes

- `lsnrctl` is optional. If it does not exist, listener checks are skipped.
- FRA information depends on Oracle configuration and privileges.
- Scheduler, object, temp, and tablespace queries require Oracle access to dynamic and DBA views.
- If the current user does not have the needed privileges, Oracle may return an error for some database sections while the rest of the report still prints.

## Read-Only Reminder

This tool is for reporting only.
It does not make Oracle or OS configuration changes.
