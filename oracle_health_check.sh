#!/usr/bin/env bash

# Oracle health check for Linux Oracle servers.
# This script is read-only and safe: it only reads data and prints a report.
# It does not change Oracle, listener, cluster, Data Guard, or OS configuration.

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

# Top-level traffic light summary values.
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

# Database summary metrics filled by sqlplus when available.
DB_INVALID_OBJECTS="N/A"
DB_FAILED_JOBS_24H="N/A"
DB_SESSIONS_PCT="N/A"
DB_PROCESSES_PCT="N/A"
DB_TEMP_PCT="N/A"
DB_FRA_PCT="N/A"
DB_FRA_DEST="N/A"
ALERT_LOG_LOCATION="N/A"

# RAC awareness metrics.
RAC_MODE="UNKNOWN"
CLUSTER_DATABASE_ENABLED="UNKNOWN"
CURRENT_INSTANCE_NAME="N/A"
CURRENT_HOST_NAME="N/A"
CURRENT_INSTANCE_STATUS="N/A"
CURRENT_STARTUP_TIME="N/A"
ALL_INSTANCES_SUMMARY="N/A"
RAC_VIEW_AVAILABLE="N"
RAC_INSTANCE_ISSUE="N"

# Data Guard awareness metrics.
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

# RED is the highest severity, then AMBER, then GREEN.
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

# This helper collects small summary metrics using read-only SQL and PL/SQL.
# It also handles RAC and Data Guard views gracefully, even when some are unavailable.
collect_database_summary_metrics() {
  local sqlplus_bin="$1"
  local oracle_sid="$2"
  local raw_output
  local line key value

  raw_output="$(ORACLE_SID="$oracle_sid" "$sqlplus_bin" -s / as sysdba <<'SQL'
set pagesize 0 linesize 400 trimspool on feedback off verify off heading off echo off timing off serveroutput on size unlimited

declare
  function lag_to_minutes(p_value varchar2) return varchar2 is
    d number := 0;
    h number := 0;
    m number := 0;
  begin
    if p_value is null or trim(p_value) is null then
      return 'N/A';
    end if;

    if upper(trim(p_value)) in ('UNKNOWN', 'UNDEFINED') then
      return 'N/A';
    end if;

    d := to_number(nvl(regexp_substr(p_value, '[0-9]+', 1, 1), '0'));
    h := to_number(nvl(regexp_substr(p_value, '[0-9]+', 1, 2), '0'));
    m := to_number(nvl(regexp_substr(p_value, '[0-9]+', 1, 3), '0'));
    return to_char((d * 24 * 60) + (h * 60) + m);
  exception
    when others then
      return 'N/A';
  end;

  procedure emit(p_key varchar2, p_value varchar2) is
  begin
    dbms_output.put_line(p_key || '=' || replace(nvl(p_value, 'N/A'), chr(10), ' '));
  end;

  l_cluster_database_enabled v$parameter.value%type := 'UNKNOWN';
  l_current_instance_name v$instance.instance_name%type := 'N/A';
  l_current_host_name v$instance.host_name%type := 'N/A';
  l_current_status v$instance.status%type := 'N/A';
  l_current_startup varchar2(30) := 'N/A';
  l_all_instances varchar2(4000) := 'N/A';
  l_database_role v$database.database_role%type := 'N/A';
  l_open_mode v$database.open_mode%type := 'N/A';
  l_protection_mode v$database.protection_mode%type := 'N/A';
  l_switchover_status v$database.switchover_status%type := 'N/A';
  l_force_logging v$database.force_logging%type := 'N/A';
  l_log_mode v$database.log_mode%type := 'N/A';
  l_transport_lag varchar2(64) := 'N/A';
  l_apply_lag varchar2(64) := 'N/A';
  l_transport_lag_minutes varchar2(64) := 'N/A';
  l_apply_lag_minutes varchar2(64) := 'N/A';
  l_managed_recovery varchar2(4000) := 'N/A';
  l_archive_dest_error_count number := 0;
  l_archive_dest_errors varchar2(4000) := 'None';
  l_invalid_objects number := 0;
  l_failed_jobs number := 0;
  l_sessions_pct varchar2(64) := 'N/A';
  l_processes_pct varchar2(64) := 'N/A';
  l_temp_pct varchar2(64) := 'N/A';
  l_fra_pct varchar2(64) := 'N/A';
  l_fra_dest varchar2(4000) := 'N/A';
  l_alert_log varchar2(4000) := 'N/A';
  l_rac_view_available varchar2(1) := 'N';
  l_dg_view_available varchar2(1) := 'N';
  l_rac_instance_issue varchar2(1) := 'N';
begin
  begin
    select value into l_cluster_database_enabled
    from v$parameter
    where name = 'cluster_database';
  exception
    when others then
      l_cluster_database_enabled := 'UNKNOWN';
  end;

  begin
    select instance_name,
           host_name,
           status,
           to_char(startup_time, 'YYYY-MM-DD HH24:MI:SS')
    into l_current_instance_name,
         l_current_host_name,
         l_current_status,
         l_current_startup
    from v$instance;
  exception
    when others then
      l_current_instance_name := 'Unavailable';
      l_current_host_name := substr(sqlerrm, 1, 200);
      l_current_status := 'Unavailable';
      l_current_startup := 'Unavailable';
  end;

  begin
    for r in (
      select inst_id,
             instance_name,
             host_name,
             status,
             to_char(startup_time, 'YYYY-MM-DD HH24:MI:SS') as startup_time
      from gv$instance
      order by inst_id
    ) loop
      l_rac_view_available := 'Y';
      if l_all_instances = 'N/A' then
        l_all_instances := '';
      else
        l_all_instances := l_all_instances || ' | ';
      end if;
      l_all_instances := l_all_instances || 'inst ' || r.inst_id || ':' || r.instance_name || '@' || r.host_name || ':' || r.status || ':' || r.startup_time;
      if upper(r.status) not in ('OPEN', 'MOUNTED') then
        l_rac_instance_issue := 'Y';
      end if;
    end loop;
  exception
    when others then
      l_rac_view_available := 'N';
      l_all_instances := 'Unavailable: ' || substr(sqlerrm, 1, 250);
  end;

  begin
    select database_role,
           open_mode,
           protection_mode,
           switchover_status,
           force_logging,
           log_mode
    into l_database_role,
         l_open_mode,
         l_protection_mode,
         l_switchover_status,
         l_force_logging,
         l_log_mode
    from v$database;
    l_dg_view_available := 'Y';
  exception
    when others then
      l_dg_view_available := 'N';
      l_database_role := 'Unavailable';
      l_open_mode := substr(sqlerrm, 1, 200);
  end;

  begin
    select max(case when name = 'transport lag' then value end),
           max(case when name = 'apply lag' then value end)
    into l_transport_lag,
         l_apply_lag
    from v$dataguard_stats;
  exception
    when others then
      l_transport_lag := 'Unavailable';
      l_apply_lag := 'Unavailable';
  end;

  l_transport_lag_minutes := lag_to_minutes(l_transport_lag);
  l_apply_lag_minutes := lag_to_minutes(l_apply_lag);

  if l_database_role = 'PHYSICAL STANDBY' then
    begin
      select nvl(listagg(process || ':' || status, '; ') within group(order by process), 'Not running')
      into l_managed_recovery
      from v$managed_standby
      where process like 'MRP%';
    exception
      when others then
        l_managed_recovery := 'Unavailable: ' || substr(sqlerrm, 1, 250);
    end;
  elsif l_database_role = 'LOGICAL STANDBY' then
    begin
      select nvl(max(status), 'Not available')
      into l_managed_recovery
      from v$logstdby_process;
    exception
      when others then
        l_managed_recovery := 'Unavailable: ' || substr(sqlerrm, 1, 250);
    end;
  else
    l_managed_recovery := 'Not applicable';
  end if;

  begin
    select count(*),
           nvl(listagg(dest_id || ':' || error, '; ') within group(order by dest_id), 'None')
    into l_archive_dest_error_count,
         l_archive_dest_errors
    from v$archive_dest_status
    where status = 'ERROR'
       or (error is not null and trim(error) is not null and upper(error) <> 'NO ERROR');
  exception
    when others then
      l_archive_dest_error_count := 0;
      l_archive_dest_errors := 'Unavailable: ' || substr(sqlerrm, 1, 250);
    end;

  begin
    select count(*)
    into l_invalid_objects
    from dba_objects
    where status <> 'VALID';
  exception
    when others then
      l_invalid_objects := 0;
    end;

  begin
    select count(*)
    into l_failed_jobs
    from dba_scheduler_job_run_details
    where log_date >= systimestamp - interval '1' day
      and status not in ('SUCCEEDED', 'RUNNING');
  exception
    when others then
      l_failed_jobs := 0;
    end;

  begin
    select nvl(to_char(round((current_utilization / to_number(limit_value)) * 100, 2)), 'N/A')
    into l_sessions_pct
    from v$resource_limit
    where resource_name = 'sessions'
      and regexp_like(limit_value, '^[0-9]+$');
  exception
    when others then
      l_sessions_pct := 'N/A';
  end;

  begin
    select nvl(to_char(round((current_utilization / to_number(limit_value)) * 100, 2)), 'N/A')
    into l_processes_pct
    from v$resource_limit
    where resource_name = 'processes'
      and regexp_like(limit_value, '^[0-9]+$');
  exception
    when others then
      l_processes_pct := 'N/A';
  end;

  begin
    select nvl(to_char(round(max((bytes_used / nullif(bytes_used + bytes_free, 0)) * 100), 2)), '0')
    into l_temp_pct
    from v$temp_space_header;
  exception
    when others then
      l_temp_pct := 'N/A';
  end;

  begin
    select nvl(to_char(round((space_used / nullif(space_limit, 0)) * 100, 2)), '0'),
           nvl(name, 'Not configured')
    into l_fra_pct,
         l_fra_dest
    from v$recovery_file_dest;
  exception
    when others then
      l_fra_pct := 'N/A';
      l_fra_dest := 'Unavailable';
  end;

  begin
    select nvl(max(case when name = 'Diag Alert' then value end), 'Not available')
    into l_alert_log
    from v$diag_info;
  exception
    when others then
      l_alert_log := 'Unavailable';
  end;

  emit('CLUSTER_DATABASE_ENABLED', l_cluster_database_enabled);
  if upper(l_cluster_database_enabled) = 'TRUE' then
    emit('RAC_MODE', 'RAC');
  elsif upper(l_cluster_database_enabled) = 'FALSE' then
    emit('RAC_MODE', 'STANDALONE');
  else
    emit('RAC_MODE', 'UNKNOWN');
  end if;
  emit('CURRENT_INSTANCE_NAME', l_current_instance_name);
  emit('CURRENT_HOST_NAME', l_current_host_name);
  emit('CURRENT_INSTANCE_STATUS', l_current_status);
  emit('CURRENT_STARTUP_TIME', l_current_startup);
  emit('ALL_INSTANCES_SUMMARY', l_all_instances);
  emit('RAC_VIEW_AVAILABLE', l_rac_view_available);
  emit('RAC_INSTANCE_ISSUE', l_rac_instance_issue);

  emit('DATABASE_ROLE', l_database_role);
  emit('OPEN_MODE', l_open_mode);
  emit('PROTECTION_MODE', l_protection_mode);
  emit('SWITCHOVER_STATUS', l_switchover_status);
  emit('FORCE_LOGGING', l_force_logging);
  emit('ARCHIVE_LOG_MODE', l_log_mode);
  emit('TRANSPORT_LAG', l_transport_lag);
  emit('APPLY_LAG', l_apply_lag);
  emit('TRANSPORT_LAG_MINUTES', l_transport_lag_minutes);
  emit('APPLY_LAG_MINUTES', l_apply_lag_minutes);
  emit('MANAGED_RECOVERY_STATUS', l_managed_recovery);
  emit('ARCHIVE_DEST_ERROR_COUNT', to_char(l_archive_dest_error_count));
  emit('ARCHIVE_DEST_ERRORS', l_archive_dest_errors);
  emit('DG_VIEW_AVAILABLE', l_dg_view_available);

  emit('DB_INVALID_OBJECTS', to_char(l_invalid_objects));
  emit('DB_FAILED_JOBS_24H', to_char(l_failed_jobs));
  emit('DB_SESSIONS_PCT', l_sessions_pct);
  emit('DB_PROCESSES_PCT', l_processes_pct);
  emit('DB_TEMP_PCT', l_temp_pct);
  emit('DB_FRA_PCT', l_fra_pct);
  emit('DB_FRA_DEST', l_fra_dest);
  emit('ALERT_LOG_LOCATION', l_alert_log);
end;
/
exit
SQL
)"

  while IFS= read -r line; do
    case "$line" in
      *=*)
        key="${line%%=*}"
        value="${line#*=}"
        case "$key" in
          CLUSTER_DATABASE_ENABLED) CLUSTER_DATABASE_ENABLED="$value" ;;
          RAC_MODE) RAC_MODE="$value" ;;
          CURRENT_INSTANCE_NAME) CURRENT_INSTANCE_NAME="$value" ;;
          CURRENT_HOST_NAME) CURRENT_HOST_NAME="$value" ;;
          CURRENT_INSTANCE_STATUS) CURRENT_INSTANCE_STATUS="$value" ;;
          CURRENT_STARTUP_TIME) CURRENT_STARTUP_TIME="$value" ;;
          ALL_INSTANCES_SUMMARY) ALL_INSTANCES_SUMMARY="$value" ;;
          RAC_VIEW_AVAILABLE) RAC_VIEW_AVAILABLE="$value" ;;
          RAC_INSTANCE_ISSUE) RAC_INSTANCE_ISSUE="$value" ;;
          DATABASE_ROLE) DATABASE_ROLE="$value" ;;
          OPEN_MODE) OPEN_MODE="$value" ;;
          PROTECTION_MODE) PROTECTION_MODE="$value" ;;
          SWITCHOVER_STATUS) SWITCHOVER_STATUS="$value" ;;
          FORCE_LOGGING) FORCE_LOGGING="$value" ;;
          ARCHIVE_LOG_MODE) ARCHIVE_LOG_MODE="$value" ;;
          TRANSPORT_LAG) TRANSPORT_LAG="$value" ;;
          APPLY_LAG) APPLY_LAG="$value" ;;
          TRANSPORT_LAG_MINUTES) TRANSPORT_LAG_MINUTES="$value" ;;
          APPLY_LAG_MINUTES) APPLY_LAG_MINUTES="$value" ;;
          MANAGED_RECOVERY_STATUS) MANAGED_RECOVERY_STATUS="$value" ;;
          ARCHIVE_DEST_ERROR_COUNT) ARCHIVE_DEST_ERROR_COUNT="$value" ;;
          ARCHIVE_DEST_ERRORS) ARCHIVE_DEST_ERRORS="$value" ;;
          DG_VIEW_AVAILABLE) DG_VIEW_AVAILABLE="$value" ;;
          DB_INVALID_OBJECTS) DB_INVALID_OBJECTS="$value" ;;
          DB_FAILED_JOBS_24H) DB_FAILED_JOBS_24H="$value" ;;
          DB_SESSIONS_PCT) DB_SESSIONS_PCT="$value" ;;
          DB_PROCESSES_PCT) DB_PROCESSES_PCT="$value" ;;
          DB_TEMP_PCT) DB_TEMP_PCT="$value" ;;
          DB_FRA_PCT) DB_FRA_PCT="$value" ;;
          DB_FRA_DEST) DB_FRA_DEST="$value" ;;
          ALERT_LOG_LOCATION) ALERT_LOG_LOCATION="$value" ;;
        esac
        ;;
    esac
  done <<EOF
$raw_output
EOF
}

number_ge() {
  awk -v left="$1" -v right="$2" 'BEGIN { exit !(left + 0 >= right + 0) }'
}

value_known_number() {
  [[ "$1" =~ ^[0-9]+([.][0-9]+)?$ ]]
}

evaluate_rac_status() {
  RAC_STATUS_SUMMARY="GREEN"
  RAC_DETAIL_MESSAGE="Database is standalone."

  if [[ "$RAC_MODE" == "RAC" ]]; then
    RAC_DETAIL_MESSAGE="RAC is enabled and cluster views were checked."
    if [[ "$RAC_VIEW_AVAILABLE" != "Y" ]]; then
      RAC_STATUS_SUMMARY="AMBER"
      RAC_DETAIL_MESSAGE="RAC appears enabled but gv\$instance was unavailable."
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
        *APPLYING_LOG*|*WAIT_FOR_LOG*|*IDLE*) : ;;
        *Unavailable*)
          if [[ "$DG_STATUS_SUMMARY" != "RED" ]]; then
            DG_STATUS_SUMMARY="AMBER"
            DG_DETAIL_MESSAGE="Could not confirm managed recovery state."
            set_status "AMBER"
          fi
          ;;
        *Not\ running*|*ERROR*|N/A)
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
    collect_database_summary_metrics "$SQLPLUS_BIN" "$ACTIVE_ORACLE_SID"
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
  print_kv "Current instance name" "$CURRENT_INSTANCE_NAME"
  print_kv "Current host name" "$CURRENT_HOST_NAME"
  print_kv "Current instance status" "$CURRENT_INSTANCE_STATUS"
  print_kv "Current startup time" "$CURRENT_STARTUP_TIME"
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

run_sqlplus_detail_queries() {
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
col open_mode format a22
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
col max_utilization format 99999999
col limit_value format a15
col pct_used format 990.00
select resource_name,
       current_utilization,
       max_utilization,
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
prompt ARCHIVE DESTINATION AND FRA USAGE
prompt ---------------------------------
col name format a60
col fra_pct_used format 990.00
select name,
       round(space_limit / 1024 / 1024 / 1024, 2) as space_limit_gb,
       round(space_used / 1024 / 1024 / 1024, 2) as space_used_gb,
       round((space_used / nullif(space_limit, 0)) * 100, 2) as fra_pct_used,
       number_of_files
from v$recovery_file_dest;

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
  echo
  run_sqlplus_detail_queries "$SQLPLUS_BIN" "$ACTIVE_ORACLE_SID"
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
