#!/bin/bash
# Backup tool for the Cubic Odyssey dedicated server (mutable game data).
#
# Usage:
#   backup.sh                       create a backup (default action)
#   backup.sh --create              same as above
#   backup.sh --list                list existing backups
#   backup.sh --restore <f|latest> [--now] [--yes]
#                                   restore a backup. Without --now the restore
#                                   is deferred: it is applied automatically on
#                                   the next container start (safe while the
#                                   server keeps running). With --now the
#                                   restore happens immediately and requires
#                                   the server to be stopped.
#   backup.sh --cron-quiet          suppress progress lines (errors + summary stay)
#
# What gets archived is BACKUP_INCLUDE - by default only the CubicOdyssey game
# data directory. The ~1.2 GB of server binaries next to it are re-downloadable
# via SteamCMD and are therefore NOT part of a backup.
#
# Environment:
#   PERSISTENT_DATA     backup storage + bookkeeping (default /home/cubic/persistent_data)
#   SERVER_FILES        server install root, archive layout is relative to it
#   BACKUP_INCLUDE      space-separated paths to archive (default "$SERVER_FILES/CubicOdyssey")
#   BACKUP_RETENTION    number of archives to keep (default 30)
#   MIN_FREE_DISK_GB    minimum free space required on the backup volume (default 5)

set -u

server_files="${SERVER_FILES:-/home/cubic/server_files}"
LOC_DIR="${PERSISTENT_DATA:-/home/cubic/persistent_data}"
BACKUP_DIR="$LOC_DIR/backup"
PENDING_FILE="$LOC_DIR/.restore_pending"
PREFIX="cubic_backup-"
SUFFIX=".tar.gz"
DEFAULT_RETENTION=30
MIN_FREE_DISK_GB="${MIN_FREE_DISK_GB:-5}"
LOCK_FILE="${CUBIC_BACKUP_LOCK:-/tmp/cubic_backup.lock}"
BACKUP_INCLUDE="${BACKUP_INCLUDE:-$server_files/CubicOdyssey}"

QUIET="no"

# Tagged logging.
log()  { [ "$QUIET" = "yes" ] && return 0; printf '[%s] [BACKUP] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
log_always() { printf '[%s] [BACKUP] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
err()  { printf '[%s] [BACKUP] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2; }

human_size() {
    awk -v b="${1:-0}" 'BEGIN {
        if      (b >= 1073741824) printf "%.1f GB", b/1073741824;
        else if (b >= 1048576)    printf "%.1f MB", b/1048576;
        else                      printf "%.1f KB", b/1024;
    }'
}

file_bytes() { stat -c %s "$1" 2>/dev/null || echo 0; }

validate_retention() {
    local val="${BACKUP_RETENTION:-$DEFAULT_RETENTION}"
    if [[ "$val" =~ ^[0-9]+$ ]] && (( 10#$val > 0 )); then
        BACKUP_RETENTION=$((10#$val))
    else
        log "[WARNING] '$val' is not a valid retention count. Using $DEFAULT_RETENTION."
        BACKUP_RETENTION=$DEFAULT_RETENTION
    fi
}

# --- single-instance lock ---------------------------------------------------

# PID lock so a scheduled backup, a manual one and the boot-time restore cannot
# overwrite each other. A lock whose process is gone is stale and removed.
acquire_lock() {
    if ( set -o noclobber; printf '%s\n' "$$" > "$LOCK_FILE" ) 2>/dev/null; then
        trap 'rm -f "$LOCK_FILE"' EXIT
        return 0
    fi
    local pid
    pid=$(cat "$LOCK_FILE" 2>/dev/null)
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        err "Another backup operation is already running (pid $pid, lock $LOCK_FILE). Skipping."
        exit 0
    fi
    log "[WARN] Removing stale lock file $LOCK_FILE (pid ${pid:-?} not running)."
    rm -f "$LOCK_FILE"
    ( set -o noclobber; printf '%s\n' "$$" > "$LOCK_FILE" ) 2>/dev/null || {
        err "Cannot create lock file $LOCK_FILE."
        exit 1
    }
    trap 'rm -f "$LOCK_FILE"' EXIT
}

# --- backup sources ---------------------------------------------------------

# Each BACKUP_INCLUDE entry is stored relative to $server_files, so an archive
# can simply be unpacked over $server_files again. Entries that do not exist
# yet (world not generated, mods not installed) are skipped.
# Prints one relative path per line.
existing_members() {
    local path rel
    for path in $BACKUP_INCLUDE; do
        case "$path" in
            "$server_files"/*) rel="${path#"$server_files"/}" ;;
            /*)                err "[WARN] '$path' is outside $server_files - not archivable, skipping."; continue ;;
            *)                 rel="$path"; path="$server_files/$path" ;;
        esac
        [ -e "$path" ] && printf '%s\n' "$rel"
    done
}

# Same list, but from the configuration (existing or not) - used to know what
# a restore has to move out of the way.
configured_members() {
    local path rel
    for path in $BACKUP_INCLUDE; do
        case "$path" in
            "$server_files"/*) rel="${path#"$server_files"/}" ;;
            /*)                continue ;;
            *)                 rel="$path" ;;
        esac
        [ -n "$rel" ] && printf '%s\n' "$rel"
    done
}

sorted_backups() {
    # oldest first, one path per line; only regular archives
    find "$BACKUP_DIR" -maxdepth 1 -name "${PREFIX}*${SUFFIX}" -type f \
        -printf '%T@ %p\n' 2>/dev/null | sort -n | cut -d' ' -f2-
}

do_list() {
    mkdir -p "$BACKUP_DIR"
    local count=0 b
    log "Backups in $BACKUP_DIR (oldest first):"
    while IFS= read -r b; do
        count=$((count+1))
        printf '  %s  %s\n' "$(human_size "$(file_bytes "$b")")" "$b"
    done < <(sorted_backups)
    if (( count == 0 )); then
        log "  (none)"
    fi
}

do_create() {
    validate_retention
    mkdir -p "$BACKUP_DIR"

    local -a members
    mapfile -t members < <(existing_members)
    if [ ${#members[@]} -eq 0 ]; then
        log "[WARN] no backup source present yet (CubicOdyssey data dir not created by the server yet?)"
        return 0
    fi

    # --- disk space guard: current source size + headroom ---
    local src_kb free_kb min_free_kb
    src_kb=$(du -sk "${members[@]/#/$server_files/}" 2>/dev/null | tail -n1 | cut -f1)
    free_kb=$(df -k --output=avail "$BACKUP_DIR" 2>/dev/null | tail -n1 | tr -d ' ')
    min_free_kb=$(( ${src_kb:-0} + MIN_FREE_DISK_GB * 1024 * 1024 ))
    if [ -n "$free_kb" ] && (( free_kb < min_free_kb )); then
        err "Not enough disk space: $(human_size $((free_kb*1024))) free, need ~$(human_size $((min_free_kb*1024))) (data + ${MIN_FREE_DISK_GB} GB headroom). Backup skipped."
        return 1
    fi

    local start_ts=$SECONDS archive tmp delete_count=0
    archive="${PREFIX}$(date '+%Y-%m-%d_%H-%M-%S')${SUFFIX}"
    # second-granularity names can collide (e.g. manual backup right after a
    # scheduled one); never overwrite an existing archive
    local n=1
    while [ -e "$BACKUP_DIR/$archive" ]; do
        archive="${PREFIX}$(date '+%Y-%m-%d_%H-%M-%S')-$n${SUFFIX}"
        n=$((n+1))
    done
    tmp="$BACKUP_DIR/.$archive.staged"

    # staged build, only a verified archive is renamed into place
    if ! tar -czf "$tmp" -C "$server_files" "${members[@]}"; then
        rm -f "$tmp"
        err "tar failed. No backup created."
        return 1
    fi

    # integrity check before promoting the archive
    if ! tar -tzf "$tmp" > /dev/null 2>&1; then
        rm -f "$tmp"
        err "Integrity check failed. Discarding $archive."
        return 1
    fi
    mv "$tmp" "$BACKUP_DIR/$archive"

    # --- retention (count based, keep the newest BACKUP_RETENTION) ---
    local -a backups
    mapfile -t backups < <(sorted_backups)
    local total=${#backups[@]} i
    if (( total > BACKUP_RETENTION )); then
        delete_count=$(( total - BACKUP_RETENTION ))
        for (( i = 0; i < delete_count; i++ )); do
            rm -f -- "${backups[i]}"
        done
    fi
    mapfile -t backups < <(sorted_backups)

    local size dur total_size
    size=$(human_size "$(file_bytes "$BACKUP_DIR/$archive")")
    dur=$(( SECONDS - start_ts ))
    total_size=$(( $(du -ck "$BACKUP_DIR" 2>/dev/null | tail -n1 | cut -f1) * 1024 ))
    log_always "Created $archive ($size, ${dur}s) · pruned $delete_count · keeping ${#backups[@]} of $BACKUP_RETENTION · total $total_size"
}

resolve_target() {
    local target=$1
    if [ "$target" = "latest" ]; then
        sorted_backups | tail -n1
    else
        # accept bare filename or full path
        if [ -f "$target" ]; then echo "$target"
        elif [ -f "$BACKUP_DIR/$target" ]; then echo "$BACKUP_DIR/$target"
        else echo ""
        fi
    fi
}

do_restore() {
    local target=$1 immediate=$2 assume_yes=$3
    local archive
    archive=$(resolve_target "$target")

    if [ -z "$archive" ] || [ ! -f "$archive" ]; then
        err "Backup '$target' not found. Use --list to see available backups."
        return 1
    fi
    if ! tar -tzf "$archive" > /dev/null 2>&1; then
        err "Backup '$archive' is corrupt (integrity check failed). Refusing to restore."
        return 1
    fi

    if [ "$immediate" != "yes" ]; then
        mkdir -p "$LOC_DIR"
        printf '%s\n' "$archive" > "$PENDING_FILE"
        log "Restore of $(basename "$archive") scheduled. Restart the container to apply it:"
        log "  docker restart <container>   (or: docker compose up -d --force-recreate)"
        log "The current game data will be kept as a safety copy before restoring."
        return 0
    fi

    # An interactive operator has to confirm; the container start (which runs
    # with no terminal) applies the pending restore right away.
    if [ "$assume_yes" != "yes" ] && [ -t 0 ]; then
        err "Immediate restore overwrites the current game data. The server must be stopped. Re-run with --yes to confirm."
        return 1
    fi

    local quarantine="$LOC_DIR/pre_restore_$(date '+%Y-%m-%d_%H-%M-%S')"
    rm -f "$PENDING_FILE"   # a --now restore supersedes any deferred one
    mkdir -p "$quarantine"

    local -a rels=() moved=()
    mapfile -t rels < <(configured_members)
    local rel
    for rel in "${rels[@]}"; do
        if [ -e "$server_files/$rel" ]; then
            mkdir -p "$quarantine/$(dirname "$rel")"
            mv "$server_files/$rel" "$quarantine/$rel"
            moved+=("$rel")
        fi
    done

    if tar -xzf "$archive" -C "$server_files"; then
        log "Restored $(basename "$archive"). Previous game data moved to $(basename "$quarantine")."
    else
        err "Extraction failed! Restoring safety copy..."
        for rel in "${moved[@]}"; do
            mkdir -p "$server_files/$(dirname "$rel")"
            mv "$quarantine/$rel" "$server_files/$rel"
        done
        return 1
    fi
}

# Apply a restore deferred by 'backup.sh --restore <name>' (called by start.sh
# before the server launches). Without a pending marker this is a no-op.
apply_restore_pending() {
    [ -f "$PENDING_FILE" ] || return 0
    local pending
    pending=$(cat "$PENDING_FILE")
    if [ -z "$pending" ]; then
        rm -f "$PENDING_FILE"
        return 0
    fi
    log "Pending restore found: $pending"
    do_restore "$pending" yes yes
}

usage() {
    sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'
}

# --- argument parsing -------------------------------------------------------

ACTION="create"
TARGET=""
IMMEDIATE="no"
ASSUME_YES="no"

while [ $# -gt 0 ]; do
    case "$1" in
        --create)        ACTION="create" ;;
        --list)          ACTION="list" ;;
        --restore)       ACTION="restore"; TARGET="${2:-}"; shift ;;
        --deferred)      IMMEDIATE="no" ;;
        --now)           IMMEDIATE="yes" ;;
        --yes)           ASSUME_YES="yes" ;;
        --cron-quiet)    QUIET="yes" ;;
        --apply-pending) ACTION="apply-pending" ;;
        -h|--help)       usage; exit 0 ;;
        *)               err "Unknown argument: $1"; usage; exit 1 ;;
    esac
    shift
done

case "$ACTION" in
    create)  acquire_lock; do_create ;;
    list)    do_list ;;
    apply-pending)
        if [ -f "$PENDING_FILE" ]; then acquire_lock; fi
        apply_restore_pending ;;
    restore)
        if [ -z "$TARGET" ]; then err "--restore needs a backup filename or 'latest'."; exit 1; fi
        acquire_lock; do_restore "$TARGET" "$IMMEDIATE" "$ASSUME_YES" ;;
esac
