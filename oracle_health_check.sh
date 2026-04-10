#!/usr/bin/env bash

# Oracle health check for Linux Oracle servers.
# This script is read-only and safe: it only reads data and prints a report.
# It does not change Oracle, listener, or OS configuration.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TIMESTAMP="$(date '+%Y%m%d_%H%M%S')"
DEFAULT_REPORT_FILE="$SCRIPT_DIR/oracle_health_check_${TIMESTAMP}.log"
REPORT_FILE="$DEFAULT_REPORT_FILE"
SILENT_MODE="false"
DETECTED_PMON_SIDS=""
ACTIVE_ORACLE_SID="${ORACLE_SID:-}"
ACTIVE_ORACLE_HOME="${ORACLE_HOME:-}"
SQLPLUS_BIN=""

# These variables hold the traffic light summary results.
OVERALL_STATUS="GREEN"
SYSTEM_STATUS="GREEN"
FILESYSTEM_STATUS="GREEN"
MEMORY_STATUS="GREEN"
CPU_STATUS="GREEN"
PMON_STATUS="GREEN"
LISTENER_STATUS_SUMMARY="GREEN"
DATABASE_STATUS="GREEN"
DATABASE_DETAIL_MESSAGE="Database checks completed."

# These variables are filled by a small SQL summary query.
DB_INVALID_OBJECTS="N/A"
DB_FAILED_JOBS_24H="N/A"
DB_SESSIONS_PCT="N/A"
DB_PROCESSES_PCT="N/A"
DB_TEMP_PCT="N/A"
DB_FRA_PCT="N/A"
DB_FRA_DEST="N/A"

show_help() {
  cat <<'HELP'
Usage:
  ./oracle_health_check.sh [-s] [-o report_file] [-h]

Options:
  -o <file>   Write output to this report file
  -s          Silent mode. Write report file only
  -h          Show help
HELP
}

parse_args() {
  while getopts ":o:sh" opt; do
    case "$opt" in
      o)
        REPORT_FILE="$OPTARG"
        ;;
      s)
        SILENT_MODE="true"
        ;;
      h)
        show_help
        exit 0
        ;;
      :)
        echo "Option -$OPTARG requires a value."
        show_help
        exit 1
        ;;
      \?)
        echo "Unknown option: -$OPTARG"
        show_help
        exit 1
        ;;
    esac
  done
}

init_report_output() {
  local report_dir
  report_dir="$(dirname "$REPORT_FILE")"
  mkdir -p "$report_dir"
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

print_status_line() {
  printf '%-30s : %-6s %s\n' "$1" "$2" "$3"
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

set_status() {
  # RED is the highest severity, then AMBER, then GREEN.
  local new_status="$1"
  if [[ "$new_status" == "RED" ]]; then
    OVERALL_STATUS="RED"
  elif [[ "$new_status" == "AMBER" && "$OVERALL_STATUS" != "RED" ]]; then
    OVERALL_STATUS="AMBER"
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

  # If ORACLE_SID is missing and exactly one PMON SID is found, use it.
  if [[ -z "$ACTIVE_ORACLE_SID" && -n "$DETECTED_PMON_SIDS" ]]; then
    if [[ "$DETECTED_PMON_SIDS" == *,* ]]; then
      ACTIVE_ORACLE_SID=""
    else
      ACTIVE_ORACLE_SID="$DETECTED_PMON_SIDS"
    fi
  fi

  SQLPLUS_BIN="$(get_sqlplus_path)"

  # If sqlplus exists, we can often infer ORACLE_HOME from it.
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

show_missing_env_guidance() {
  echo "Oracle environment variables are missing or incomplete for database checks."
  echo
  if [[ -z "${ORACLE_HOME:-}" && -z "$ACTIVE_ORACLE_HOME" ]]; then
    echo "- ORACLE_HOME is not set and could not be resolved from sqlplus."
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

collect_database_summary_metrics() {
  local sqlplus_bin="$1"
  local oracle_sid="$2"
  local raw_output

  raw_output="$(ORACLE_SID="$oracle_sid" "$sqlplus_bin" -s / as sysdba <<'SQL'
set pagesize 0 linesize 400 trimspool on feedback off verify off heading off echo off timing off
select
  nvl((select count(*) from dba_objects where status <> 'VALID'), 0) || '|' ||
  nvl((select count(*) from dba_scheduler_job_run_details
       where log_date >= systimestamp - interval '1' day
         and status not in ('SUCCEEDED', 'RUNNING')), 0) || '|' ||
  nvl((select round((current_utilization / to_number(limit_value)) * 100, 2)
       from v\$resource_limit
       where resource_name = 'sessions'
         and regexp_like(limit_value, '^[0-9]+$')), 0) || '|' ||
  nvl((select round((current_utilization / to_number(limit_value)) * 100, 2)
       from v\$resource_limit
       where resource_name = 'processes'
         and regexp_like(limit_value, '^[0-9]+$')), 0) || '|' ||
  nvl((select round(max((bytes_used / nullif(bytes_used + bytes_free, 0)) * 100), 2)
       from v\$temp_space_header), 0) || '|' ||
  nvl((select round((space_used / nullif(space_limit, 0)) * 100, 2)
       from v\$recovery_file_dest), 0) || '|' ||
  nvl((select max(name) from v\$recovery_file_dest), 'Not configured')
from dual;
exit
SQL
)"

  raw_output="$(printf '%s\n' "$raw_output" | tail -n 1 | tr -d '\r')"
  IFS='|' read -r DB_INVALID_OBJECTS DB_FAILED_JOBS_24H DB_SESSIONS_PCT DB_PROCESSES_PCT DB_TEMP_PCT DB_FRA_PCT DB_FRA_DEST <<< "$raw_output"

  DB_INVALID_OBJECTS="${DB_INVALID_OBJECTS:-N/A}"
  DB_FAILED_JOBS_24H="${DB_FAILED_JOBS_24H:-N/A}"
  DB_SESSIONS_PCT="${DB_SESSIONS_PCT:-N/A}"
  DB_PROCESSES_PCT="${DB_PROCESSES_PCT:-N/A}"
  DB_TEMP_PCT="${DB_TEMP_PCT:-N/A}"
  DB_FRA_PCT="${DB_FRA_PCT:-N/A}"
  DB_FRA_DEST="${DB_FRA_DEST:-N/A}"
}

number_ge() {
  awk -v left="$1" -v right="$2" 'BEGIN { exit !(left + 0 >= right + 0) }'
}

evaluate_summary_statuses() {
  local max_usage

  OVERALL_STATUS="GREEN"
  SYSTEM_STATUS="GREEN"

  if command_exists df; then
    FILESYSTEM_STATUS="GREEN"
  else
    FILESYSTEM_STATUS="AMBER"
    set_status "AMBER"
  fi

  if memory_source_available; then
    MEMORY_STATUS="GREEN"
  else
    MEMORY_STATUS="AMBER"
    set_status "AMBER"
  fi

  if ps_source_available; then
    CPU_STATUS="GREEN"
  else
    CPU_STATUS="AMBER"
    set_status "AMBER"
  fi

  if [[ -n "$DETECTED_PMON_SIDS" ]]; then
    PMON_STATUS="GREEN"
  else
    PMON_STATUS="AMBER"
    set_status "AMBER"
  fi

  if command_exists lsnrctl; then
    LISTENER_STATUS_SUMMARY="GREEN"
  else
    LISTENER_STATUS_SUMMARY="AMBER"
    set_status "AMBER"
  fi

  if ! database_check_ready; then
    DATABASE_STATUS="AMBER"
    DATABASE_DETAIL_MESSAGE="Database checks are partially unavailable."
    set_status "AMBER"
    return
  fi

  collect_database_summary_metrics "$SQLPLUS_BIN" "$ACTIVE_ORACLE_SID"

  DATABASE_STATUS="GREEN"
  DATABASE_DETAIL_MESSAGE="No database warning thresholds were hit."
  max_usage="$DB_SESSIONS_PCT"
  if number_ge "$DB_PROCESSES_PCT" "$max_usage"; then
    max_usage="$DB_PROCESSES_PCT"
  fi

  if number_ge "$DB_INVALID_OBJECTS" 100 || \
     number_ge "$DB_FAILED_JOBS_24H" 10 || \
     number_ge "$max_usage" 95 || \
     number_ge "$DB_TEMP_PCT" 95 || \
     number_ge "$DB_FRA_PCT" 95; then
    DATABASE_STATUS="RED"
    DATABASE_DETAIL_MESSAGE="At least one database threshold is in the critical range."
    set_status "RED"
  elif number_ge "$DB_INVALID_OBJECTS" 1 || \
       number_ge "$DB_FAILED_JOBS_24H" 1 || \
       number_ge "$max_usage" 85 || \
       number_ge "$DB_TEMP_PCT" 85 || \
       number_ge "$DB_FRA_PCT" 85; then
    DATABASE_STATUS="AMBER"
    DATABASE_DETAIL_MESSAGE="At least one database threshold is in the warning range."
    set_status "AMBER"
  fi
}

show_traffic_light_summary() {
  print_header "TRAFFIC LIGHT SUMMARY"
  print_status_line "Overall status" "$OVERALL_STATUS" "GREEN is healthy, AMBER needs attention, RED is critical."
  print_status_line "System details" "$SYSTEM_STATUS" "Basic server identity checks completed."
  print_status_line "Filesystem usage" "$FILESYSTEM_STATUS" "Filesystem information was checked."
  print_status_line "Memory usage" "$MEMORY_STATUS" "Memory information was checked."
  print_status_line "Top CPU processes" "$CPU_STATUS" "Process information was checked."
  print_status_line "Oracle PMON" "$PMON_STATUS" "PMON discovery checked for running Oracle instances."
  print_status_line "Listener status" "$LISTENER_STATUS_SUMMARY" "Listener command availability was checked."
  print_status_line "Database checks" "$DATABASE_STATUS" "$DATABASE_DETAIL_MESSAGE"
}

run_sqlplus_health_query() {
  local sqlplus_bin="$1"
  local oracle_sid="$2"

  ORACLE_SID="$oracle_sid" "$sqlplus_bin" -s / as sysdba <<'SQL'
set pagesize 200 linesize 220 trimspool on feedback off verify off heading on echo off timing off

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
prompt ARCHIVE LOG MODE AND FRA DESTINATION
prompt ------------------------------------
col log_mode format a15
col force_logging format a15
col flashback_on format a15
col fra_name format a55
select d.log_mode,
       d.force_logging,
       d.flashback_on,
       r.name as fra_name,
       round((r.space_used / nullif(r.space_limit, 0)) * 100, 2) as fra_pct_used
from v$database d
left join v$recovery_file_dest r on 1 = 1;

prompt
prompt INVALID OBJECTS COUNT
prompt ---------------------
select count(*) as invalid_objects
from dba_objects
where status <> 'VALID';

prompt
prompt FAILED SCHEDULER JOBS IN LAST 24 HOURS
prompt --------------------------------------
select count(*) as failed_scheduler_jobs_24h
from dba_scheduler_job_run_details
where log_date >= systimestamp - interval '1' day
  and status not in ('SUCCEEDED', 'RUNNING');

prompt
prompt SESSIONS AND PROCESSES USAGE
prompt ----------------------------
col resource_name format a15
col current_utilization format 99999999
col limit_value format a15
col pct_used format 990.00
select resource_name,
       current_utilization,
       limit_value,
       case
         when regexp_like(limit_value, '^[0-9]+$') and to_number(limit_value) > 0
           then round((current_utilization / to_number(limit_value)) * 100, 2)
         else null
       end as pct_used
from v$resource_limit
where resource_name in ('sessions', 'processes')
order by resource_name;

prompt
prompt TEMP TABLESPACE USAGE
prompt ---------------------
col tablespace_name format a30
col total_mb format 99999990.00
col used_mb format 99999990.00
col free_mb format 99999990.00
col pct_used format 990.00
select tablespace_name,
       round((bytes_used + bytes_free) / 1024 / 1024, 2) as total_mb,
       round(bytes_used / 1024 / 1024, 2) as used_mb,
       round(bytes_free / 1024 / 1024, 2) as free_mb,
       round((bytes_used / nullif(bytes_used + bytes_free, 0)) * 100, 2) as pct_used
from v$temp_space_header
order by pct_used desc, tablespace_name;

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
col value format a110
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
  if command_exists df; then
    df -hP
  else
    echo "Command 'df' is not available."
  fi
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

  show_traffic_light_summary
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
  evaluate_summary_statuses

  if [[ "$SILENT_MODE" == "true" ]]; then
    generate_report >"$REPORT_FILE" 2>&1
  else
    generate_report 2>&1 | tee "$REPORT_FILE"
  fi
}

main "$@"
