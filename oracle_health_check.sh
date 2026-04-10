#!/usr/bin/env bash

# This script is a safe, read-only Oracle health check for Linux Oracle servers.
# It reads operating system and Oracle information and writes a timestamped report.
# It does not change database settings, listener settings, or Oracle files.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TIMESTAMP="$(date '+%Y%m%d_%H%M%S')"
OUTPUT_DIR="$SCRIPT_DIR"
REPORT_FILE=""
SILENT_MODE="false"
DETECTED_PMON_SIDS=""
ACTIVE_ORACLE_SID="${ORACLE_SID:-}"
ACTIVE_ORACLE_HOME="${ORACLE_HOME:-}"
SQLPLUS_BIN=""

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -s|--silent)
        SILENT_MODE="true"
        shift
        ;;
      -o|--output-dir)
        if [[ $# -lt 2 ]]; then
          echo "Missing value for $1"
          exit 1
        fi
        OUTPUT_DIR="$2"
        shift 2
        ;;
      -h|--help)
        show_help
        exit 0
        ;;
      *)
        echo "Unknown option: $1"
        show_help
        exit 1
        ;;
    esac
  done
}

show_help() {
  cat <<'HELP'
Usage:
  ./oracle_health_check.sh [options]

Options:
  -s, --silent             Write the report file only, with no screen output
  -o, --output-dir <dir>   Directory where the timestamped report will be saved
  -h, --help               Show this help message
HELP
}

init_report_output() {
  mkdir -p "$OUTPUT_DIR"
  REPORT_FILE="$OUTPUT_DIR/oracle_health_check_${TIMESTAMP}.log"
}

print_line() {
  printf '%*s\n' "${1:-80}" '' | tr ' ' '='
}

print_subline() {
  printf '%*s\n' "${1:-60}" '' | tr ' ' '-'
}

print_header() {
  echo
  print_line 80
  echo "$1"
  print_line 80
}

print_subheader() {
  echo
  echo "$1"
  print_subline 60
}

print_kv() {
  printf '%-30s : %s\n' "$1" "$2"
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

memory_source_available() {
  command_exists free || [[ -r /proc/meminfo ]]
}

ps_source_available() {
  command_exists ps
}

database_check_ready() {
  [[ -n "$SQLPLUS_BIN" && -n "$ACTIVE_ORACLE_HOME" && -n "$ACTIVE_ORACLE_SID" ]]
}

print_status_line() {
  printf '%-30s : %-8s %s\n' "$1" "$2" "$3"
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

safe_hostname() {
  hostname 2>/dev/null || echo "Unknown"
}

safe_datetime() {
  date '+%Y-%m-%d %H:%M:%S %Z' 2>/dev/null || date
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

detect_pmon_sids() {
  local pmon_output

  if ! command_exists ps; then
    return
  fi

  pmon_output="$(ps -ef 2>&1 | grep '[o]ra_pmon_' || true)"

  if [[ "$pmon_output" == *"Operation not permitted"* ]]; then
    return
  fi

  DETECTED_PMON_SIDS="$(printf '%s\n' "$pmon_output" | awk '
    /ora_pmon_/ {
      split($0, a, "ora_pmon_")
      if (a[2] != "") print a[2]
    }
  ' | awk '{print $1}' | sort -u | paste -sd, -)"
}

show_pmon_processes() {
  if command_exists ps; then
    local output
    output="$(ps -ef 2>&1 | grep '[o]ra_pmon_' || true)"
    if [[ "$output" == *"Operation not permitted"* ]]; then
      echo "Unable to read process list for PMON search."
      echo "$output"
    elif [[ -n "$output" ]]; then
      echo "$output"
      echo
      print_kv "Detected PMON SIDs" "${DETECTED_PMON_SIDS:-None detected}"
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

get_sqlplus_path() {
  if command_exists sqlplus; then
    command -v sqlplus
  elif [[ -n "$ACTIVE_ORACLE_HOME" && -x "$ACTIVE_ORACLE_HOME/bin/sqlplus" ]]; then
    echo "$ACTIVE_ORACLE_HOME/bin/sqlplus"
  else
    echo ""
  fi
}

resolve_oracle_environment() {
  detect_pmon_sids

  if [[ -z "$ACTIVE_ORACLE_SID" && -n "$DETECTED_PMON_SIDS" ]]; then
    if [[ "$DETECTED_PMON_SIDS" == *,* ]]; then
      ACTIVE_ORACLE_SID=""
    else
      ACTIVE_ORACLE_SID="$DETECTED_PMON_SIDS"
    fi
  fi

  SQLPLUS_BIN="$(get_sqlplus_path)"

  if [[ -z "$ACTIVE_ORACLE_HOME" && -n "$SQLPLUS_BIN" ]]; then
    ACTIVE_ORACLE_HOME="$(cd "$(dirname "$SQLPLUS_BIN")/.." 2>/dev/null && pwd)"
  fi
}

show_oracle_environment_summary() {
  print_header "ORACLE ENVIRONMENT"
  print_kv "Report file" "$REPORT_FILE"
  print_kv "ORACLE_HOME" "${ORACLE_HOME:-Not set}"
  print_kv "ORACLE_SID" "${ORACLE_SID:-Not set}"
  print_kv "Resolved ORACLE_HOME" "${ACTIVE_ORACLE_HOME:-Not resolved}"
  print_kv "Resolved ORACLE_SID" "${ACTIVE_ORACLE_SID:-Not resolved}"
  print_kv "Detected PMON SIDs" "${DETECTED_PMON_SIDS:-None detected}"
  print_kv "sqlplus available" "$( [[ -n "$SQLPLUS_BIN" ]] && echo Yes || echo No )"
  print_kv "lsnrctl available" "$( command_exists lsnrctl && echo Yes || echo No )"
}

show_executive_summary() {
  print_header "EXECUTIVE SUMMARY"

  print_status_line "System details" "OK" "Hostname and date/time collected."

  if command_exists df; then
    print_status_line "Filesystem usage" "OK" "Filesystem command is available."
  else
    print_status_line "Filesystem usage" "WARNING" "Filesystem command is not available."
  fi

  if memory_source_available; then
    print_status_line "Memory usage" "OK" "Memory source is available."
  else
    print_status_line "Memory usage" "WARNING" "Memory source is not available."
  fi

  if ps_source_available; then
    print_status_line "Top CPU processes" "OK" "Process list command is available."
  else
    print_status_line "Top CPU processes" "WARNING" "Process list command is not available."
  fi

  if [[ -n "$DETECTED_PMON_SIDS" ]]; then
    print_status_line "Oracle PMON" "OK" "Detected PMON SIDs: $DETECTED_PMON_SIDS"
  elif ps_source_available; then
    print_status_line "Oracle PMON" "WARNING" "No PMON processes were detected."
  else
    print_status_line "Oracle PMON" "SKIPPED" "Process list command is not available."
  fi

  if command_exists lsnrctl; then
    print_status_line "Listener status" "OK" "lsnrctl is available."
  else
    print_status_line "Listener status" "SKIPPED" "lsnrctl is not available."
  fi

  if [[ -z "$SQLPLUS_BIN" ]]; then
    print_status_line "Database checks" "SKIPPED" "sqlplus is not available."
  elif database_check_ready; then
    print_status_line "Database checks" "OK" "sqlplus and Oracle environment are ready."
  elif [[ -n "$DETECTED_PMON_SIDS" && "$DETECTED_PMON_SIDS" == *,* && -z "${ORACLE_SID:-}" ]]; then
    print_status_line "Database checks" "SKIPPED" "Multiple PMON SIDs found. Set ORACLE_SID first."
  else
    print_status_line "Database checks" "SKIPPED" "ORACLE_HOME or ORACLE_SID is not fully resolved."
  fi
}

show_missing_env_guidance() {
  echo "Oracle environment variables are missing or incomplete for database checks."
  echo
  if [[ -z "${ORACLE_HOME:-}" ]]; then
    echo "- ORACLE_HOME is not set."
  fi

  if [[ -z "${ORACLE_SID:-}" ]]; then
    if [[ -n "$ACTIVE_ORACLE_SID" ]]; then
      echo "- ORACLE_SID was not set, so the script selected: $ACTIVE_ORACLE_SID"
    elif [[ -n "$DETECTED_PMON_SIDS" && "$DETECTED_PMON_SIDS" == *,* ]]; then
      echo "- ORACLE_SID is not set and multiple PMON processes were found."
      echo "  Set ORACLE_SID to the instance you want to check."
    else
      echo "- ORACLE_SID is not set."
    fi
  fi

  echo
  echo "Example environment setup:"
  echo "  export ORACLE_HOME=/u01/app/oracle/product/19.0.0/dbhome_1"
  echo "  export ORACLE_SID=ORCL"
  echo "  export PATH=\$ORACLE_HOME/bin:\$PATH"
}

run_sqlplus_health_query() {
  local sqlplus_bin="$1"
  local oracle_sid="$2"

  ORACLE_SID="$oracle_sid" "$sqlplus_bin" -s / as sysdba <<'SQL'
set pagesize 200 linesize 200 trimspool on feedback off verify off heading on echo off timing off

prompt
prompt DATABASE INSTANCE STATUS
prompt ------------------------
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
prompt ARCHIVE LOG MODE
prompt ----------------
col log_mode format a15
col force_logging format a15
col flashback_on format a15
select log_mode, force_logging, flashback_on from v$database;

prompt
prompt FRA USAGE
prompt ---------
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
prompt TABLESPACE USAGE SUMMARY
prompt ------------------------
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
prompt ALERT LOG LOCATION
prompt ------------------
col value format a100
select name, value
from v$diag_info
where name in ('Diag Trace', 'Diag Alert', 'Default Trace File');

exit
SQL
}

show_database_checks() {
  print_header "DATABASE CHECKS"

  if [[ -z "$SQLPLUS_BIN" ]]; then
    echo "sqlplus is not available."
    echo "Database checks were skipped."
    return
  fi

  print_kv "sqlplus path" "$SQLPLUS_BIN"

  if [[ -z "$ACTIVE_ORACLE_HOME" || -z "$ACTIVE_ORACLE_SID" ]]; then
    echo
    show_missing_env_guidance
    echo
    echo "Database checks were skipped."
    return
  fi

  echo
  print_kv "Using ORACLE_HOME" "$ACTIVE_ORACLE_HOME"
  print_kv "Using ORACLE_SID" "$ACTIVE_ORACLE_SID"
  echo
  echo "Running read-only database queries..."
  echo
  run_sqlplus_health_query "$SQLPLUS_BIN" "$ACTIVE_ORACLE_SID"
}

show_system_details() {
  print_header "SYSTEM DETAILS"
  print_kv "Hostname" "$(safe_hostname)"
  print_kv "Date/Time" "$(safe_datetime)"
  print_kv "Report file" "$REPORT_FILE"

  print_subheader "OS UPTIME"
  detect_os_uptime
}

show_filesystem_usage() {
  print_header "FILESYSTEM USAGE"
  run_if_exists df -hP
}

show_memory_section() {
  print_header "MEMORY USAGE"
  show_memory_usage
}

show_cpu_section() {
  print_header "TOP CPU PROCESSES"
  show_top_cpu_processes
}

show_pmon_section() {
  print_header "ORACLE PMON PROCESSES"
  show_pmon_processes
}

show_listener_section() {
  print_header "LISTENER STATUS"
  show_listener_status
}

generate_report() {
  print_header "ORACLE SERVER HEALTH CHECK"
  echo "This script is read-only."
  echo "It reads health information and writes a report file."
  echo "It does not make Oracle or OS configuration changes."

  show_executive_summary
  show_system_details
  show_filesystem_usage
  show_memory_section
  show_cpu_section
  show_pmon_section
  show_listener_section
  show_oracle_environment_summary
  show_database_checks

  echo
  print_line 80
  echo "Health check completed."
  echo "Report saved to: $REPORT_FILE"
  echo "No Oracle or database changes were made."
  print_line 80
}

main() {
  parse_args "$@"
  init_report_output
  resolve_oracle_environment

  if [[ "$SILENT_MODE" == "true" ]]; then
    generate_report >"$REPORT_FILE" 2>&1
  else
    generate_report 2>&1 | tee "$REPORT_FILE"
  fi
}

main "$@"
