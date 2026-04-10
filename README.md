# Oracle Health Check Tool

This project is a beginner-friendly, read-only Oracle health check tool for Linux Oracle database servers.

The main script is:

- `oracle_health_check.sh`

It collects server details and Oracle database details when the Oracle environment and tools are available.

## Safety

This script is safe and read-only.

It does **not**:

- start or stop Oracle
- change database settings
- create or delete files
- run DDL or DML changes
- modify listener configuration

It only reads information and prints a report.

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
- Access to run the script on the server

For full Oracle database checks, it is best to run the script as the Oracle software owner, often `oracle`.

## Files

- `oracle_health_check.sh` - the main health check script
- `README.md` - instructions and examples

## Exact Run Steps

1. Copy the project folder to your Linux Oracle server if it is not already there.
2. Open a terminal session on the Linux server.
3. Go to the project folder:

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

## Best Practice For Oracle Checks

If you want Oracle database results, run it with the Oracle environment loaded.

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

## Example Output Areas

You will see sections like:

- `SYSTEM DETAILS`
- `FILESYSTEM USAGE`
- `MEMORY USAGE`
- `TOP CPU PROCESSES`
- `ORACLE PMON PROCESSES`
- `LISTENER STATUS`
- `ORACLE ENVIRONMENT`
- `DATABASE HEALTH`

## If sqlplus Is Not Available

The script checks whether `sqlplus` exists.

If `sqlplus` is not found, it clearly says that:

- `sqlplus is not available`
- database checks were skipped

OS checks will still run.

## If Oracle Environment Variables Are Missing

The script checks for:

- `ORACLE_HOME`
- `ORACLE_SID`

If they are missing, the script clearly explains that database checks were skipped and shows an example of how to set them.

## Notes

- `lsnrctl` is optional. If it does not exist, the script skips listener checks.
- FRA information depends on Oracle configuration and privileges.
- Tablespace and diagnostic queries require access to Oracle dynamic and DBA views.
- If you do not have the needed privileges, Oracle may return an error for some database sections while the rest of the report still prints.

## Example Commands

Run basic OS and Oracle checks:

```bash
./oracle_health_check.sh
```

Run after setting Oracle variables:

```bash
export ORACLE_HOME=/u01/app/oracle/product/19.0.0/dbhome_1
export ORACLE_SID=PROD1
export PATH=$ORACLE_HOME/bin:$PATH
./oracle_health_check.sh
```

Run as Oracle user:

```bash
sudo su - oracle
cd /path/to/oracle-health-check
./oracle_health_check.sh
```

## Troubleshooting

If the script says `sqlplus is not available`:

- check that Oracle client or database binaries are installed
- check that `$ORACLE_HOME/bin` is in your `PATH`

If the script says Oracle environment variables are missing:

- set `ORACLE_HOME`
- set `ORACLE_SID`
- add `$ORACLE_HOME/bin` to `PATH`

If listener status does not work:

- check whether `lsnrctl` exists on the server
- check whether the current user can run it

## Read-Only Reminder

This tool is for reporting only.
It does not make any changes to the server or database.
