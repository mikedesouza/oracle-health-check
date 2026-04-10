#!/usr/bin/env bash

# Oracle health check for Linux Oracle servers.
# This script is read-only and safe: it only reads information and writes a text report.
# It does not change Oracle, RAC, Data Guard, listener, or Linux configuration.

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

OVERALL_STATUS="GREEN"
SYSTEM_STATUS="GREEN"
FILESYSTEM_STATUS="GREEN"
MEMORY_STATUS="GREEN"
CPU_STATUS="GREEN"
PMON_STATUS="GREEN"
LISTENER_STATUS_SUMMARY="GREEN"
DATABASE_STATUS="GREEN"
RAC_STATUS_SUMMARY="GREEN"
DG_STATUS_SUMMARY="GREEN"
DATABASE_DETAIL_MESSAGE="Database checks completed."
RAC_DETAIL_MESSAGE="RAC checks completed."
DG_DETAIL_MESSAGE="Data Guard checks completed."

DB_INVALID_OBJECTS="N/A"
DB_FAILED_JOBS_24H="N/A"
DB_SESSIONS_PCT="N/A"
DB_PROCESSES_PCT="N/A"
DB_TEMP_PCT="N/A"
DB_FRA_PCT="N/A"
DB_FRA_DEST="N/A"
ALERT_LOG_LOCATION="N/A"
CDB_ENABLED="N/A"
CURRENT_CONTAINER_NAME="N/A"
PDB_COUNT="N/A"

RAC_MODE="UNKNOWN"
CLUSTER_DATABASE_ENABLED="UNKNOWN"
CURRENT_INSTANCE_NAME="N/A"
CURRENT_HOST_NAME="N/A"
CURRENT_INSTANCE_STATUS="N/A"
CURRENT_STARTUP_TIME="N/A"
ALL_INSTANCES_SUMMARY="N/A"
RAC_VIEW_AVAILABLE="N"
RAC_INSTANCE_ISSUE="N"
RAC_INSTANCE_COUNT="N/A"

DATABASE_ROLE="N/A"
OPEN_MODE="N/A"
PROTECTION_MODE="N/A"
SWITCHOVER_STATUS="N/A"
FORCE_LOGGING="N/A"
ARCHIVE_LOG_MODE="N/A"
TRANSPORT_LAG="N/A"
APPLY_LAG="N/A"
TRANSPORT_LAG_MINUTES="N/A"
APPLY_LAG_MINUTES="N/A"
MANAGED_RECOVERY_STATUS="N/A"
ARCHIVE_DEST_ERROR_COUNT="0"
ARCHIVE_DEST_ERRORS="None"
DG_VIEW_AVAILABLE="N"

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
      o) REPORT_FILE="$OPTARG" ;;
      s) SILENT_MODE="true" ;;
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

sqlplus_scalar() {
  local sql_text="$1"
  local output=""

  output="$({
    ORACLE_SID="$ACTIVE_ORACLE_SID" "$SQLPLUS_BIN" -s / as sysdba <<SQL
set pagesize 0 linesize 400 trimspool on feedback off verify off heading off echo off timing off serveroutput off termout on tab off
whenever sqlerror continue
$sql_text
exit
SQL
  } 2>&1)"

  printf '%s\n' "$output" | tr -d '\r' | awk 'NF {print; exit}'
}

sqlplus_report_block() {
  local title="$1"
  local sql_text="$2"

  print_subheader "$title"
  ORACLE_SID="$ACTIVE_ORACLE_SID" "$SQLPLUS_BIN" -s / as sysdba <<SQL
set pagesize 200 linesize 220 trimspool on feedback off verify off heading on echo off timing off serveroutput off termout on tab off
whenever sqlerror continue
$sql_text
exit
SQL
}

set_metric_from_query() {
  local var_name="$1"
  local sql_text="$2"
  local value=""

  value="$(sqlplus_scalar "$sql_text")"
  if [[ -n "$value" && "$value" != ORA-* && "$value" != SP2-* ]]; then
    printf -v "$var_name" '%s' "$value"
    return 0
  fi
  return 1
}

lag_to_minutes() {
  local value="$1"
  if [[ -z "$value" || "$value" == "N/A" || "$value" == "UNKNOWN" || "$value" == "UNDEFINED" || "$value" == "Unavailable" ]]; then
    echo "N/A"
    return
  fi

  awk -v text="$value" '
    BEGIN {
      days = hours = mins = 0
      n = split(text, a, ":")
      if (n == 4) {
        days = a[1] + 0
        hours = a[2] + 0
        mins = a[3] + 0
        print (days * 24 * 60) + (hours * 60) + mins
      } else {
        print "N/A"
      }
    }
  '
}

number_ge() {
  awk -v left="$1" -v right="$2" 'BEGIN { exit !(left + 0 >= right + 0) }'
}

value_known_number() {
  [[ "$1" =~ ^[0-9]+([.][0-9]+)?$ ]]
}

collect_database_summary_metrics() {
  set_metric_from_query CLUSTER_DATABASE_ENABLED "select value from v\$parameter where name = 'cluster_database';" || true
  set_metric_from_query CURRENT_INSTANCE_NAME "select instance_name from v\$instance;" || true
  set_metric_from_query CURRENT_HOST_NAME "select host_name from v\$instance;" || true
  set_metric_from_query CURRENT_INSTANCE_STATUS "select status from v\$instance;" || true
  set_metric_from_query CURRENT_STARTUP_TIME "select to_char(startup_time, 'YYYY-MM-DD HH24:MI:SS') from v\$instance;" || true

  if set_metric_from_query RAC_INSTANCE_COUNT "select count(*) from gv\$instance;"; then
    RAC_VIEW_AVAILABLE="Y"
    set_metric_from_query ALL_INSTANCES_SUMMARY "select listagg('inst ' || inst_id || ':' || instance_name || '@' || host_name || ':' || status || ':' || to_char(startup_time, 'YYYY-MM-DD HH24:MI:SS'), ' | ') within group(order by inst_id) from gv\$instance;" || true
    set_metric_from_query RAC_INSTANCE_ISSUE "select case when exists (select 1 from gv\$instance where upper(status) not in ('OPEN', 'MOUNTED')) then 'Y' else 'N' end from dual;" || true
  else
    RAC_VIEW_AVAILABLE="N"
  fi

  if [[ "$CLUSTER_DATABASE_ENABLED" == "TRUE" ]]; then
    RAC_MODE="RAC"
  elif [[ "$CLUSTER_DATABASE_ENABLED" == "FALSE" ]]; then
    RAC_MODE="STANDALONE"
  elif value_known_number "$RAC_INSTANCE_COUNT" && number_ge "$RAC_INSTANCE_COUNT" 2; then
    RAC_MODE="RAC"
  elif [[ -n "$DETECTED_PMON_SIDS" && "$DETECTED_PMON_SIDS" == *,* ]]; then
    RAC_MODE="RAC"
  fi

  set_metric_from_query CDB_ENABLED "select cdb from v\$database;" || true
  set_metric_from_query CURRENT_CONTAINER_NAME "select sys_context('USERENV', 'CON_NAME') from dual;" || true
  set_metric_from_query PDB_COUNT "select count(*) from v\$pdbs;" || true

  if set_metric_from_query DATABASE_ROLE "select database_role from v\$database;"; then
    DG_VIEW_AVAILABLE="Y"
  fi
  set_metric_from_query OPEN_MODE "select open_mode from v\$database;" || true
  set_metric_from_query PROTECTION_MODE "select protection_mode from v\$database;" || true
  set_metric_from_query SWITCHOVER_STATUS "select switchover_status from v\$database;" || true
  set_metric_from_query FORCE_LOGGING "select force_logging from v\$database;" || true
  set_metric_from_query ARCHIVE_LOG_MODE "select log_mode from v\$database;" || true
  set_metric_from_query TRANSPORT_LAG "select max(value) from v\$dataguard_stats where name = 'transport lag';" || true
  set_metric_from_query APPLY_LAG "select max(value) from v\$dataguard_stats where name = 'apply lag';" || true
  set_metric_from_query ARCHIVE_DEST_ERROR_COUNT "select count(*) from v\$archive_dest_status where status = 'ERROR' or (error is not null and trim(error) is not null and upper(error) <> 'NO ERROR');" || true
  if ! set_metric_from_query ARCHIVE_DEST_ERRORS "select listagg(dest_id || ':' || error, '; ') within group(order by dest_id) from v\$archive_dest_status where status = 'ERROR' or (error is not null and trim(error) is not null and upper(error) <> 'NO ERROR');"; then
    if [[ "$ARCHIVE_DEST_ERROR_COUNT" == "0" ]]; then
      ARCHIVE_DEST_ERRORS="None"
    fi
  fi
  if ! set_metric_from_query MANAGED_RECOVERY_STATUS "select listagg(process || ':' || status, '; ') within group(order by process) from v\$managed_standby where process like 'MRP%';"; then
    if [[ "$DATABASE_ROLE" == "PHYSICAL STANDBY" ]]; then
      MANAGED_RECOVERY_STATUS="Unavailable"
    elif [[ "$DATABASE_ROLE" == "LOGICAL STANDBY" ]]; then
      MANAGED_RECOVERY_STATUS="Logical standby - check SQL Apply separately"
    else
      MANAGED_RECOVERY_STATUS="Not applicable"
    fi
  fi

  set_metric_from_query DB_INVALID_OBJECTS "select count(*) from dba_objects where status <> 'VALID';" || true
  set_metric_from_query DB_FAILED_JOBS_24H "select count(*) from dba_scheduler_job_run_details where log_date >= systimestamp - interval '1' day and status not in ('SUCCEEDED', 'RUNNING');" || true
  set_metric_from_query DB_SESSIONS_PCT "select round((current_utilization / to_number(limit_value)) * 100, 2) from v\$resource_limit where resource_name = 'sessions' and regexp_like(limit_value, '^[0-9]+$');" || true
  set_metric_from_query DB_PROCESSES_PCT "select round((current_utilization / to_number(limit_value)) * 100, 2) from v\$resource_limit where resource_name = 'processes' and regexp_like(limit_value, '^[0-9]+$');" || true
  set_metric_from_query DB_TEMP_PCT "select round(max((bytes_used / nullif(bytes_used + bytes_free, 0)) * 100), 2) from v\$temp_space_header;" || true
  set_metric_from_query DB_FRA_PCT "select round((space_used / nullif(space_limit, 0)) * 100, 2) from v\$recovery_file_dest;" || true
  set_metric_from_query DB_FRA_DEST "select max(name) from v\$recovery_file_dest;" || true
  set_metric_from_query ALERT_LOG_LOCATION "select max(value) from v\$diag_info where name = 'Diag Alert';" || true

  TRANSPORT_LAG_MINUTES="$(lag_to_minutes "$TRANSPORT_LAG")"
  APPLY_LAG_MINUTES="$(lag_to_minutes "$APPLY_LAG")"
}

evaluate_rac_status() {
  RAC_STATUS_SUMMARY="GREEN"
  RAC_DETAIL_MESSAGE="Database is standalone."

  if [[ "$RAC_MODE" == "RAC" ]]; then
    if [[ "$PDB_COUNT" != "N/A" && "$PDB_COUNT" != "0" ]]; then
      RAC_DETAIL_MESSAGE="RAC detected. Multitenant appears active with $PDB_COUNT PDB(s)."
    else
      RAC_DETAIL_MESSAGE="RAC detected and cluster-wide views were checked."
    fi

    if [[ "$RAC_VIEW_AVAILABLE" != "Y" ]]; then
      RAC_STATUS_SUMMARY="AMBER"
      RAC_DETAIL_MESSAGE="RAC detected, but gv\$instance could not be read."
      set_status "AMBER"
    elif [[ "$RAC_INSTANCE_ISSUE" == "Y" ]]; then
      RAC_STATUS_SUMMARY="RED"
      RAC_DETAIL_MESSAGE="One or more RAC instances are not OPEN or MOUNTED."
      set_status "RED"
    fi
  elif [[ "$RAC_MODE" == "UNKNOWN" ]]; then
    RAC_STATUS_SUMMARY="AMBER"
    RAC_DETAIL_MESSAGE="Could not determine whether the database is standalone or RAC."
    set_status "AMBER"
  fi
}

evaluate_dg_status() {
  DG_STATUS_SUMMARY="GREEN"
  DG_DETAIL_MESSAGE="Data Guard role and lag checks look healthy."

  if [[ "$DG_VIEW_AVAILABLE" != "Y" ]]; then
    DG_STATUS_SUMMARY="AMBER"
    DG_DETAIL_MESSAGE="Data Guard summary views were unavailable."
    set_status "AMBER"
    return
  fi

  if value_known_number "$ARCHIVE_DEST_ERROR_COUNT" && number_ge "$ARCHIVE_DEST_ERROR_COUNT" 1; then
    DG_STATUS_SUMMARY="RED"
    DG_DETAIL_MESSAGE="Archive destination errors were reported."
    set_status "RED"
  fi

  if [[ "$DATABASE_ROLE" == "PHYSICAL STANDBY" || "$DATABASE_ROLE" == "LOGICAL STANDBY" ]]; then
    if [[ "$DATABASE_ROLE" == "PHYSICAL STANDBY" ]]; then
      case "$MANAGED_RECOVERY_STATUS" in
        *APPLYING_LOG*|*WAIT_FOR_LOG*|*IDLE*) ;;
        *Unavailable*)
          if [[ "$DG_STATUS_SUMMARY" != "RED" ]]; then
            DG_STATUS_SUMMARY="AMBER"
            DG_DETAIL_MESSAGE="Could not confirm managed recovery state."
            set_status "AMBER"
          fi
          ;;
        *Not\ applicable*|*Not\ running*|*ERROR*|N/A)
          DG_STATUS_SUMMARY="RED"
          DG_DETAIL_MESSAGE="Managed recovery does not appear to be running."
          set_status "RED"
          ;;
      esac
    fi

    if value_known_number "$TRANSPORT_LAG_MINUTES"; then
      if number_ge "$TRANSPORT_LAG_MINUTES" 60; then
        DG_STATUS_SUMMARY="RED"
        DG_DETAIL_MESSAGE="Transport lag is in the critical range."
        set_status "RED"
      elif number_ge "$TRANSPORT_LAG_MINUTES" 15 && [[ "$DG_STATUS_SUMMARY" != "RED" ]]; then
        DG_STATUS_SUMMARY="AMBER"
        DG_DETAIL_MESSAGE="Transport lag is above the warning threshold."
        set_status "AMBER"
      fi
    fi

    if value_known_number "$APPLY_LAG_MINUTES"; then
      if number_ge "$APPLY_LAG_MINUTES" 60; then
        DG_STATUS_SUMMARY="RED"
        DG_DETAIL_MESSAGE="Apply lag is in the critical range."
        set_status "RED"
      elif number_ge "$APPLY_LAG_MINUTES" 15 && [[ "$DG_STATUS_SUMMARY" != "RED" ]]; then
        DG_STATUS_SUMMARY="AMBER"
        DG_DETAIL_MESSAGE="Apply lag is above the warning threshold."
        set_status "AMBER"
      fi
    fi
  elif [[ "$DATABASE_ROLE" == "PRIMARY" ]]; then
    DG_DETAIL_MESSAGE="Primary database role looks healthy."
  elif [[ "$DATABASE_ROLE" == "N/A" || "$DATABASE_ROLE" == "Unavailable" ]]; then
    DG_STATUS_SUMMARY="AMBER"
    DG_DETAIL_MESSAGE="Could not determine the database role."
    set_status "AMBER"
  fi
}

evaluate_database_status() {
  local max_usage="0"

  DATABASE_STATUS="GREEN"
  DATABASE_DETAIL_MESSAGE="No database warning thresholds were hit."

  if ! database_check_ready; then
    DATABASE_STATUS="AMBER"
    DATABASE_DETAIL_MESSAGE="Database checks are partially unavailable."
    set_status "AMBER"
    return
  fi

  if value_known_number "$DB_SESSIONS_PCT"; then
    max_usage="$DB_SESSIONS_PCT"
  fi
  if value_known_number "$DB_PROCESSES_PCT" && number_ge "$DB_PROCESSES_PCT" "$max_usage"; then
    max_usage="$DB_PROCESSES_PCT"
  fi

  if value_known_number "$DB_INVALID_OBJECTS" && number_ge "$DB_INVALID_OBJECTS" 100 || \
     value_known_number "$DB_FAILED_JOBS_24H" && number_ge "$DB_FAILED_JOBS_24H" 10 || \
     value_known_number "$max_usage" && number_ge "$max_usage" 95 || \
     value_known_number "$DB_TEMP_PCT" && number_ge "$DB_TEMP_PCT" 95 || \
     value_known_number "$DB_FRA_PCT" && number_ge "$DB_FRA_PCT" 95; then
    DATABASE_STATUS="RED"
    DATABASE_DETAIL_MESSAGE="At least one database threshold is in the critical range."
    set_status "RED"
  elif value_known_number "$DB_INVALID_OBJECTS" && number_ge "$DB_INVALID_OBJECTS" 1 || \
       value_known_number "$DB_FAILED_JOBS_24H" && number_ge "$DB_FAILED_JOBS_24H" 1 || \
       value_known_number "$max_usage" && number_ge "$max_usage" 85 || \
       value_known_number "$DB_TEMP_PCT" && number_ge "$DB_TEMP_PCT" 85 || \
       value_known_number "$DB_FRA_PCT" && number_ge "$DB_FRA_PCT" 85; then
    DATABASE_STATUS="AMBER"
    DATABASE_DETAIL_MESSAGE="At least one database threshold is in the warning range."
    set_status "AMBER"
  fi
}

evaluate_summary_statuses() {
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

  if database_check_ready; then
    collect_database_summary_metrics
  fi

  evaluate_rac_status
  evaluate_dg_status
  evaluate_database_status
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
  print_status_line "RAC status" "$RAC_STATUS_SUMMARY" "$RAC_DETAIL_MESSAGE"
  print_status_line "Data Guard status" "$DG_STATUS_SUMMARY" "$DG_DETAIL_MESSAGE"
  print_status_line "Database checks" "$DATABASE_STATUS" "$DATABASE_DETAIL_MESSAGE"
}

show_rac_summary() {
  print_header "RAC SUMMARY"
  print_kv "Detected mode" "$RAC_MODE"
  print_kv "Cluster database enabled" "$CLUSTER_DATABASE_ENABLED"
  print_kv "CDB enabled" "$CDB_ENABLED"
  print_kv "Current container" "$CURRENT_CONTAINER_NAME"
  print_kv "PDB count" "$PDB_COUNT"
  print_kv "Current instance name" "$CURRENT_INSTANCE_NAME"
  print_kv "Current host name" "$CURRENT_HOST_NAME"
  print_kv "Current instance status" "$CURRENT_INSTANCE_STATUS"
  print_kv "Current startup time" "$CURRENT_STARTUP_TIME"
  print_kv "gv\$instance count" "$RAC_INSTANCE_COUNT"
  print_kv "All instances from gv\$instance" "$ALL_INSTANCES_SUMMARY"

  if [[ "$RAC_VIEW_AVAILABLE" != "Y" ]]; then
    echo
    echo "RAC cluster-wide views were unavailable. The script handled this safely and continued."
  fi
}

show_dataguard_summary() {
  print_header "DATA GUARD SUMMARY"
  print_kv "Database role" "$DATABASE_ROLE"
  print_kv "Open mode" "$OPEN_MODE"
  print_kv "Protection mode" "$PROTECTION_MODE"
  print_kv "Switchover status" "$SWITCHOVER_STATUS"
  print_kv "Force logging" "$FORCE_LOGGING"
  print_kv "Archive log mode" "$ARCHIVE_LOG_MODE"
  print_kv "Transport lag" "$TRANSPORT_LAG"
  print_kv "Apply lag" "$APPLY_LAG"
  print_kv "Managed recovery status" "$MANAGED_RECOVERY_STATUS"
  print_kv "Archive destination errors" "$ARCHIVE_DEST_ERRORS"

  if [[ "$DG_VIEW_AVAILABLE" != "Y" ]]; then
    echo
    echo "Some Data Guard views were unavailable. The script handled this safely and continued."
  fi
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
  print_kv "Invalid objects count" "$DB_INVALID_OBJECTS"
  print_kv "Failed jobs last 24h" "$DB_FAILED_JOBS_24H"
  print_kv "Sessions usage percent" "$DB_SESSIONS_PCT"
  print_kv "Processes usage percent" "$DB_PROCESSES_PCT"
  print_kv "Temp usage percent" "$DB_TEMP_PCT"
  print_kv "FRA usage percent" "$DB_FRA_PCT"
  print_kv "FRA destination" "$DB_FRA_DEST"
  print_kv "Alert log location" "$ALERT_LOG_LOCATION"

  echo
  echo "Running read-only detailed database queries..."

  sqlplus_report_block "DATABASE INSTANCE STATUS" "select i.instance_name, i.host_name, i.version, i.status, d.open_mode, d.database_role, to_char(i.startup_time, 'YYYY-MM-DD HH24:MI:SS') as startup_time from v\$instance i cross join v\$database d;"

  sqlplus_report_block "RAC INSTANCE STATUS" "select inst_id, instance_name, host_name, status, to_char(startup_time, 'YYYY-MM-DD HH24:MI:SS') as startup_time from gv\$instance order by inst_id;"

  sqlplus_report_block "MULTITENANT SUMMARY" "select cdb, sys_context('USERENV', 'CON_NAME') as current_container from v\$database cross join dual; select con_id, name, open_mode from v\$pdbs order by con_id;"

  sqlplus_report_block "INVALID OBJECTS COUNT" "select count(*) as invalid_objects from dba_objects where status <> 'VALID';"

  sqlplus_report_block "FAILED SCHEDULER JOBS IN LAST 24 HOURS" "select count(*) as failed_scheduler_jobs_24h from dba_scheduler_job_run_details where log_date >= systimestamp - interval '1' day and status not in ('SUCCEEDED', 'RUNNING');"

  sqlplus_report_block "SESSIONS AND PROCESSES USAGE" "select resource_name, current_utilization, max_utilization, limit_value, case when regexp_like(limit_value, '^[0-9]+$') and to_number(limit_value) > 0 then round((current_utilization / to_number(limit_value)) * 100, 2) else null end as pct_used from v\$resource_limit where resource_name in ('sessions', 'processes') order by resource_name;"

  sqlplus_report_block "TEMP TABLESPACE USAGE" "select tablespace_name, round((bytes_used + bytes_free) / 1024 / 1024, 2) as total_mb, round(bytes_used / 1024 / 1024, 2) as used_mb, round(bytes_free / 1024 / 1024, 2) as free_mb, round((bytes_used / nullif(bytes_used + bytes_free, 0)) * 100, 2) as pct_used from v\$temp_space_header order by tablespace_name;"

  sqlplus_report_block "TABLESPACE USAGE SUMMARY" "with data_files as (select tablespace_name, sum(bytes) / 1024 / 1024 as total_mb from dba_data_files group by tablespace_name), free_space as (select tablespace_name, sum(bytes) / 1024 / 1024 as free_mb from dba_free_space group by tablespace_name) select df.tablespace_name, round(df.total_mb, 2) as total_mb, round(df.total_mb - nvl(fs.free_mb, 0), 2) as used_mb, round(nvl(fs.free_mb, 0), 2) as free_mb, round(((df.total_mb - nvl(fs.free_mb, 0)) / df.total_mb) * 100, 2) as pct_used from data_files df left join free_space fs on df.tablespace_name = fs.tablespace_name order by pct_used desc, df.tablespace_name;"

  sqlplus_report_block "ARCHIVE DESTINATION AND FRA USAGE" "select name, round(space_limit / 1024 / 1024 / 1024, 2) as space_limit_gb, round(space_used / 1024 / 1024 / 1024, 2) as space_used_gb, round((space_used / nullif(space_limit, 0)) * 100, 2) as fra_pct_used, number_of_files from v\$recovery_file_dest; select dest_id, status, destination, error from v\$archive_dest_status where status = 'ERROR' or (error is not null and trim(error) is not null and upper(error) <> 'NO ERROR') order by dest_id;"

  sqlplus_report_block "ALERT LOG LOCATION" "select name, value from v\$diag_info where name in ('Diag Trace', 'Diag Alert', 'Default Trace File');"
}

generate_report() {
  print_header "ORACLE SERVER HEALTH CHECK"
  echo "This script is read-only."
  echo "It reads health information and writes a report file."
  echo "It does not make Oracle, RAC, Data Guard, or OS configuration changes."

  show_traffic_light_summary
  show_system_details
  show_filesystem_usage
  show_memory_section
  show_cpu_section
  show_pmon_section
  show_listener_section
  show_oracle_environment_summary
  show_rac_summary
  show_dataguard_summary
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
