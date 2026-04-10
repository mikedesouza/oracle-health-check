# Oracle Health Check Tool

This project is a beginner-friendly, read-only Oracle health check tool for real Linux Oracle database servers.

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

- clear section headings
- clean colorless output
- graceful handling when `ORACLE_HOME` or `ORACLE_SID` is missing
- support for multiple PMON processes
- automatic timestamped report files
- optional silent mode that only writes the report file
- a short executive summary with `OK`, `WARNING`, and `SKIPPED`

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
- archive log mode
- FRA usage if available
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

6. The script will print the report and also save a timestamped report file in the same folder.

Near the top of the report, you will also see a short summary section that quickly shows the status of major areas:

- `OK`
- `WARNING`
- `SKIPPED`

Example report file name:

```text
oracle_health_check_20260410_143000.log
```

## Silent Mode

If you want the script to only write the report file and not print to the screen, use:

```bash
./oracle_health_check.sh --silent
```

Short option:

```bash
./oracle_health_check.sh -s
```

## Custom Output Directory

If you want the report written to a different directory, use:

```bash
./oracle_health_check.sh --output-dir /tmp/oracle_reports
```

You can combine both options:

```bash
./oracle_health_check.sh --silent --output-dir /tmp/oracle_reports
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
- if needed, it explains that database checks were skipped

If `ORACLE_SID` is missing:

- the script still runs OS checks
- if exactly one PMON process is found, it uses that SID automatically
- if multiple PMON processes are found, it tells you to set `ORACLE_SID` explicitly

## Multiple PMON Support

The script looks for multiple `ora_pmon_<SID>` processes.

It shows:

- the PMON process list
- the detected SID names

This is helpful on Linux servers that host more than one Oracle instance.

## Example Commands

Run standard report:

```bash
./oracle_health_check.sh
```

Run silently and save the report only:

```bash
./oracle_health_check.sh --silent
```

Run with Oracle environment set:

```bash
export ORACLE_HOME=/u01/app/oracle/product/19.0.0/dbhome_1
export ORACLE_SID=PROD1
export PATH=$ORACLE_HOME/bin:$PATH
./oracle_health_check.sh
```

Run with a custom report directory:

```bash
./oracle_health_check.sh --output-dir /var/tmp/oracle_health_reports
```

## Notes

- `lsnrctl` is optional. If it does not exist, listener checks are skipped.
- FRA information depends on Oracle configuration and privileges.
- Tablespace and diagnostic queries require access to Oracle dynamic and DBA views.
- If the current user does not have the needed privileges, Oracle may return an error for some database sections while the rest of the report still prints.

## Troubleshooting

If the script says `sqlplus is not available`:

- check that Oracle binaries are installed
- check that `$ORACLE_HOME/bin` is in `PATH`

If the script says multiple PMON processes were found:

- set `ORACLE_SID` to the instance you want to check

Example:

```bash
export ORACLE_SID=PROD1
./oracle_health_check.sh
```

If the script says `ORACLE_HOME` is not set:

- set `ORACLE_HOME`
- add `$ORACLE_HOME/bin` to `PATH`

Example:

```bash
export ORACLE_HOME=/u01/app/oracle/product/19.0.0/dbhome_1
export PATH=$ORACLE_HOME/bin:$PATH
```

## Read-Only Reminder

This tool is for reporting only.
It does not make Oracle or OS configuration changes.
