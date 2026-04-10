#!/usr/bin/env bash

# This script is a safe, read-only Oracle health check.
# It collects operating system details and, when possible, Oracle database details.
# It does not change database settings, files, or server configuration.

set -u

print_line() {
  printf '%*s\n' "${1:-80}" '' | tr ' ' '-'
}

print_header() {
  echo
  print_line 80
  echo "$1"
  print_line 80
}

print_kv() {
  printf '%-30s : %s\n' "$1" "$2"
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

run_if_exists() {
  local cmd="$1"
  shift

  if command_exists "$cmd"; then
    "$cmd" "$@"
  else
    echo "Command '$cmd' is not available."
  fi
}

detect_os_uptime() {
  if command_exists uptime; then
    uptime
  elif [[ -r /proc/uptime ]]; then
    awk '{print "Uptime seconds: " $1}' /proc/uptime
  else
    echo "Unable to determine uptime."
  fi
}

show_memory_usage() {
  if command_exists free; then
    free -h
  elif [[ -r /proc/meminfo ]]; then
    awk '
      /MemTotal/ {total=$2}
      /MemFree/ {free=$2}
      /MemAvailable/ {avail=$2}
      END {
        print "Memory information from /proc/meminfo"
        print "MemTotal      : " total " kB"
        print "MemFree       : " free " kB"
        print "MemAvailable  : " avail " kB"
      }
    ' /proc/meminfo
  else
    echo "Unable to determine memory usage."
  fi
}

show_top_cpu_processes() {
  if command_exists ps; then
    local output
    output="$(ps -eo pid,ppid,user,%cpu,%mem,etime,args --sort=-%cpu 2>&1)"
    if [[ $? -eq 0 ]]; then
      echo "$output" | head -n 11
    else
      echo "Unable to read top CPU processes."
      echo "$output"
    fi
  else
    echo "Command 'ps' is not available."
  fi
}

show_pmon_processes() {
  if command_exists ps; then
    local output
    output="$(ps -ef 2>&1 | grep [p]mon || true)"
    if [[ "$output" == *"Operation not permitted"* ]]; then
      echo "Unable to read process list for PMON search."
      echo "$output"
    elif [[ -n "$output" ]]; then
      echo "$output"
    else
      echo "No Oracle PMON processes were found."
    fi
  else
    echo "Command 'ps' is not available."
  fi
}

show_listener_status() {
  if command_exists lsnrctl; then
    lsnrctl status 2>&1
  else
    echo "lsnrctl is not available on PATH."
    echo "Listener status check skipped."
  fi
}

oracle_env_ready() {
  if [[ -z "${ORACLE_HOME:-}" ]]; then
    return 1
  fi

  if [[ -z "${ORACLE_SID:-}" ]]; then
    return 1
  fi

  return 0
}

show_oracle_env_help() {
  echo "Oracle environment variables are missing or incomplete."
  echo "This script needs at least these variables for database checks:"
  echo "  ORACLE_HOME"
  echo "  ORACLE_SID"
  echo
  echo "Example:"
  echo "  export ORACLE_HOME=/u01/app/oracle/product/19.0.0/dbhome_1"
  echo "  export ORACLE_SID=ORCL"
  echo "  export PATH=\$ORACLE_HOME/bin:\$PATH"
  echo
  echo "OS checks still ran, but database checks were skipped."
}

get_sqlplus_path() {
  if command_exists sqlplus; then
    command -v sqlplus
  elif [[ -n "${ORACLE_HOME:-}" && -x "${ORACLE_HOME}/bin/sqlplus" ]]; then
    echo "${ORACLE_HOME}/bin/sqlplus"
  else
    echo ""
  fi
}

run_sqlplus_health_query() {
  local sqlplus_bin="$1"

  "$sqlplus_bin" -s / as sysdba <<'SQL'
set pagesize 200 linesize 200 trimspool on feedback off verify off heading on echo off timing off

prompt
prompt DATABASE HEALTH
prompt ----------------

prompt
prompt Instance status, open mode, role, startup time
col instance_name format a18
col host_name format a30
col version format a18
col status format a12
col open_mode format a20
col database_role format a20
col startup_time format a20
select
  i.instance_name,
  i.host_name,
  i.version,
  i.status,
  d.open_mode,
  d.database_role,
  to_char(i.startup_time, 'YYYY-MM-DD HH24:MI:SS') as startup_time
from v$instance i
cross join v$database d;

prompt
prompt Archive log mode
col log_mode format a15
col force_logging format a15
col flashback_on format a15
select log_mode, force_logging, flashback_on from v$database;

prompt
prompt FRA usage
col name format a45
col space_limit_gb format 9999990.00
col space_used_gb format 9999990.00
col space_reclaimable_gb format 9999990.00
select
  name,
  round(space_limit/1024/1024/1024, 2) as space_limit_gb,
  round(space_used/1024/1024/1024, 2) as space_used_gb,
  round(space_reclaimable/1024/1024/1024, 2) as space_reclaimable_gb,
  number_of_files
from v$recovery_file_dest;

prompt
prompt Tablespace usage summary
col tablespace_name format a30
col total_mb format 99999990.00
col used_mb format 99999990.00
col free_mb format 99999990.00
col pct_used format 990.00
with data_files as (
  select tablespace_name, sum(bytes) / 1024 / 1024 as total_mb
  from dba_data_files
  group by tablespace_name
),
free_space as (
  select tablespace_name, sum(bytes) / 1024 / 1024 as free_mb
  from dba_free_space
  group by tablespace_name
)
select
  df.tablespace_name,
  round(df.total_mb, 2) as total_mb,
  round(df.total_mb - nvl(fs.free_mb, 0), 2) as used_mb,
  round(nvl(fs.free_mb, 0), 2) as free_mb,
  round(((df.total_mb - nvl(fs.free_mb, 0)) / df.total_mb) * 100, 2) as pct_used
from data_files df
left join free_space fs on df.tablespace_name = fs.tablespace_name
order by pct_used desc, df.tablespace_name;

prompt
prompt Alert log location
col value format a100
select name, value
from v$diag_info
where name in ('Diag Trace', 'Diag Alert', 'Default Trace File');

exit
SQL
}

show_database_checks() {
  local sqlplus_bin
  sqlplus_bin="$(get_sqlplus_path)"

  print_header "ORACLE ENVIRONMENT"
  print_kv "ORACLE_HOME" "${ORACLE_HOME:-Not set}"
  print_kv "ORACLE_SID" "${ORACLE_SID:-Not set}"
  print_kv "PATH has sqlplus" "$(command_exists sqlplus && echo "Yes" || echo "No")"

  echo
  if [[ -z "$sqlplus_bin" ]]; then
    echo "sqlplus is not available."
    echo "Database health checks were skipped."
    return
  fi

  print_kv "sqlplus path" "$sqlplus_bin"

  if ! oracle_env_ready; then
    echo
    show_oracle_env_help
    return
  fi

  echo
  echo "Running read-only database checks with sqlplus..."
  echo
  run_sqlplus_health_query "$sqlplus_bin"
}

main() {
  print_header "ORACLE SERVER HEALTH CHECK"
  echo "This script is read-only. It reports health information and does not make changes."

  print_header "SYSTEM DETAILS"
  print_kv "Hostname" "$(hostname 2>/dev/null || echo "Unknown")"
  print_kv "Date/Time" "$(date '+%Y-%m-%d %H:%M:%S %Z' 2>/dev/null || date)"

  echo
  echo "OS Uptime"
  echo "---------"
  detect_os_uptime

  print_header "FILESYSTEM USAGE"
  run_if_exists df -hP

  print_header "MEMORY USAGE"
  show_memory_usage

  print_header "TOP CPU PROCESSES"
  show_top_cpu_processes

  print_header "ORACLE PMON PROCESSES"
  show_pmon_processes

  print_header "LISTENER STATUS"
  show_listener_status

  show_database_checks

  echo
  print_line 80
  echo "Health check completed."
  echo "No changes were made to the server or database."
  print_line 80
}

main "$@"
