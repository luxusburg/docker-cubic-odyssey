#!/bin/bash
# Background backup scheduler for Cubic Odyssey.
#
# Replaces the old cron setup. Running the schedule in-process means backups:
#   - see the container environment (BACKUP_RETENTION, TZ, ...)
#   - log straight to the container stdout (visible in `docker logs`)
#   - run as the cubic user, so archives are never root-owned on the host
#
# BACKUP_INTERVAL keeps its old contract: a standard 5-field cron expression
# (minute hour day-of-month month day-of-week), e.g. "0 * * * *" for hourly.
# Without BACKUP_INTERVAL the schedule is derived from BACKUPS_PER_DAY
# (or directly from BACKUP_INTERVAL_MINUTES).
#
# Environment:
#   PERSISTENT_DATA         backup dir + scheduler log live here
#   BACKUP_INTERVAL         5-field cron expression (overrides *_MINUTES)
#   BACKUPS_PER_DAY         number of backups per day (default 4)
#   BACKUP_INTERVAL_MINUTES run every N minutes (overrides BACKUPS_PER_DAY)
#   RUN_BACKUP_ON_BOOT      true -> one backup right after BOOT_DELAY_MINUTES
#   BOOT_DELAY_MINUTES      grace period after container start (default 5)
#   SCHEDULER_STOP_FILE     create this file to stop the scheduler gracefully
#   BACKUP_SCRIPT           path of backup.sh

SCHEDULER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PERSISTENT_DATA="${PERSISTENT_DATA:-/home/cubic/persistent_data}"
BACKUP_SCRIPT="${BACKUP_SCRIPT:-$SCHEDULER_DIR/backup.sh}"
SCHEDULER_LOG="${SCHEDULER_LOG:-$PERSISTENT_DATA/cubic_scheduler.log}"
SCHEDULER_STOP_FILE="${SCHEDULER_STOP_FILE:-$PERSISTENT_DATA/.scheduler_stop}"
BOOT_DELAY_MINUTES="${BOOT_DELAY_MINUTES:-5}"
RUN_BACKUP_ON_BOOT="${RUN_BACKUP_ON_BOOT:-false}"
BACKUPS_PER_DAY="${BACKUPS_PER_DAY:-4}"
DEFAULT_INTERVAL="0 * * * *"

# Tagged logging: plain timestamped lines, mirrored to the scheduler log.
log() {
    printf '[%s] [SCHEDULER] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

# --- cron expression matching ---------------------------------------------

# _cron_field_match <value> <field>
# Supports: * a b-d */n and comma-separated lists of those.
_cron_field_match() {
    local val=$1 field=$2 part lo hi step
    local parts
    IFS=',' read -ra parts <<< "$field"
    for part in "${parts[@]}"; do
        case "$part" in
            \*)
                return 0 ;;
            \*/[0-9]*)
                step=${part#*/}
                (( step > 0 && val % step == 0 )) && return 0 ;;
            [0-9]*-[0-9]*)
                lo=${part%-*}; hi=${part#*-}
                (( val >= 10#$lo && val <= 10#$hi )) && return 0 ;;
            [0-9]*)
                (( val == 10#$part )) && return 0 ;;
        esac
    done
    return 1
}

# cron_match <5-field expression> [epoch]  -> 0 when epoch (default: now) matches
cron_match() {
    local expr=$1 epoch=${2:-$(date +%s)}
    local f_min f_hour f_dom f_mon f_dow
    read -r f_min f_hour f_dom f_mon f_dow <<< "$expr"

    local min hour dom mon dow
    min=$((10#$(date -d "@$epoch" +%M)))
    hour=$((10#$(date -d "@$epoch" +%H)))
    dom=$((10#$(date -d "@$epoch" +%d)))
    mon=$((10#$(date -d "@$epoch" +%m)))
    dow=$((10#$(date -d "@$epoch" +%w)))

    _cron_field_match "$min"  "$f_min"  || return 1
    _cron_field_match "$hour" "$f_hour" || return 1
    _cron_field_match "$mon"  "$f_mon"  || return 1

    # day-of-week: allow 7 as Sunday, same as standard cron
    local dow_expr=${f_dow//7/0}

    # Standard Vixie-cron rule for day fields: when BOTH day-of-month and
    # day-of-week are restricted, either match counts; otherwise both must
    # match (an unrestricted field always matches).
    local dom_restricted=1 dow_restricted=1
    [[ $f_dom != '*' ]] && dom_restricted=0
    [[ $f_dow != '*' ]] && dow_restricted=0

    local dom_match=0 dow_match=0
    _cron_field_match "$dom" "$f_dom" && dom_match=1
    _cron_field_match "$dow" "$dow_expr" && dow_match=1

    if (( dom_restricted && dow_restricted )); then
        return 0
    elif (( dom_restricted )); then
        return $(( 1 - dow_match ))
    elif (( dow_restricted )); then
        return $(( 1 - dom_match ))
    else
        (( dom_match || dow_match ))
    fi
}

# --- main loop --------------------------------------------------------------
# (guarded so the cron_match functions can be sourced for tests)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then

# Mirror everything into the scheduler log (visible on the volume even after
# the container is gone) while keeping it on stdout for `docker logs`.
mkdir -p "$PERSISTENT_DATA" 2>/dev/null
if [ -d "$PERSISTENT_DATA" ]; then
    exec > >(tee -a "$SCHEDULER_LOG") 2>&1
fi

stopped=0
on_stop() { stopped=1; }
trap 'log "Scheduler stopping."; exit 0' TERM INT

# Schedule selection: explicit cron expression wins, otherwise minutes.
expr="${BACKUP_INTERVAL:-}"
interval_min=0
if [ -n "$expr" ]; then
    if [ "$(wc -w <<< "$expr")" -ne 5 ]; then
        log "[WARNING] BACKUP_INTERVAL='$expr' is not a 5-field cron expression. Using BACKUPS_PER_DAY instead."
        expr=""
    fi
fi
if [ -z "$expr" ]; then
    if [ -n "$BACKUP_INTERVAL_MINUTES" ] && [[ "$BACKUP_INTERVAL_MINUTES" =~ ^[0-9]+$ ]] && (( 10#$BACKUP_INTERVAL_MINUTES > 0 )); then
        interval_min=$((10#$BACKUP_INTERVAL_MINUTES))
    else
        if ! [[ "$BACKUPS_PER_DAY" =~ ^[0-9]+$ ]] || (( 10#$BACKUPS_PER_DAY < 1 )); then
            log "[WARNING] BACKUPS_PER_DAY='$BACKUPS_PER_DAY' is not a positive number. Using 4."
            BACKUPS_PER_DAY=4
        fi
        interval_min=$(( 1440 / 10#$BACKUPS_PER_DAY ))
        (( interval_min < 1 )) && interval_min=1
    fi
    log "Backup schedule: every ${interval_min} minute(s) (${BACKUPS_PER_DAY}/day, TZ=${TZ:-UTC})"
else
    log "Backup schedule: '$expr' (TZ=${TZ:-UTC})"
fi

# Grace period after container start: the SteamCMD update and the world load
# should finish before a backup competes for disk and CPU.
wait_for() {
    local until=$1
    while [ "$(date +%s)" -lt "$until" ]; do
        [ "$stopped" = 1 ] && exit 0
        [ -f "$SCHEDULER_STOP_FILE" ] && return 1
        sleep 5
    done
    return 0
}

if [[ "$BOOT_DELAY_MINUTES" =~ ^[0-9]+$ ]] && (( 10#$BOOT_DELAY_MINUTES > 0 )); then
    log "Waiting ${BOOT_DELAY_MINUTES} minute(s) before the first backup."
    wait_for $(( $(date +%s) + 10#$BOOT_DELAY_MINUTES * 60 )) || { log "Stop file found, scheduler exiting."; exit 0; }
fi

run_backup() {
    log "Scheduled backup starting."
    if bash "$BACKUP_SCRIPT" --create --cron-quiet; then
        log "Scheduled backup finished."
    else
        log "[ERROR] Scheduled backup failed (exit $?)."
    fi
}

if [ "$RUN_BACKUP_ON_BOOT" = true ] || [ "$RUN_BACKUP_ON_BOOT" = yes ]; then
    run_backup
fi

last_fired_minute=""
next_run=$(( $(date +%s) ))
stop_requested() {
    [ -n "$SCHEDULER_STOP_FILE" ] && [ -f "$SCHEDULER_STOP_FILE" ]
}

while true; do
    now=$(date +%s)
    if stop_requested; then
        log "Stop file $SCHEDULER_STOP_FILE found. Scheduler stopping."
        exit 0
    fi
    if [ -n "$expr" ]; then
        minute=$(( now / 60 ))
        if [ "$minute" != "$last_fired_minute" ] && cron_match "$expr" "$now"; then
            last_fired_minute=$minute
            run_backup
        fi
    else
        if (( now >= next_run )); then
            run_backup
            next_run=$(( now + interval_min * 60 ))
        fi
    fi
    # short sleeps keep both the stop file and SIGTERM responsive
    for _ in 1 2 3; do
        stop_requested && break
        sleep 5
    done
done
fi
