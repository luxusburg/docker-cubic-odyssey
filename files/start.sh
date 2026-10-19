#!/bin/bash
# Location of server data and save data for docker

# Shared logging helpers (timestamped, levelled output).
source "$(dirname "${BASH_SOURCE[0]}")/log.sh"

# Image version stamped at build time (Dockerfile), 'dev' when unset.
LOG_IMAGE_VERSION="dev"
for LOG_VERSION_FILE in ./scripts/VERSION "$(dirname "${BASH_SOURCE[0]}")/VERSION"; do
    if [ -f "$LOG_VERSION_FILE" ]; then
        LOG_IMAGE_VERSION=$(cat "$LOG_VERSION_FILE")
        break
    fi
done
log_banner "CUBIC ODYSSEY DEDICATED SERVER CONTAINER" \
    "Image version: $LOG_IMAGE_VERSION"

# The web admin UI tails the container log, so mirror everything into a file
# when it is enabled. Only then; the normal boot keeps writing to stdout alone.
if [ "${WEBUI:-false}" = true ]; then
    webui_log_dir="${PERSISTENT_DATA:-/home/cubic/persistent_data}/logs"
    mkdir -p "$webui_log_dir"
    [ -f "$webui_log_dir/container.log" ] && > "$webui_log_dir/container.log"
    exec > >(tee -a "$webui_log_dir/container.log") 2>&1
fi

server_files=/home/cubic/server_files
# backup.sh/scheduler.sh resolve paths from the exported SERVER_FILES var
export SERVER_FILES="$server_files"
# Keep the Wine prefix inside the persistent server volume so recreated
# containers don't redo first-time Wine setup (default is $HOME/.wine).
export WINEPREFIX="$server_files/.wine"

log_info "Server files location is set to : $server_files"

mkdir -p /home/cubic/.steam 2>/dev/null
chmod -R 777 /home/cubic/.steam 2>/dev/null
log_phase "SteamCMD update"

# The dedicated server TOOL downloads anonymously (verified 2026-10).
# Only set STEAM_LOGIN/STEAM_PWD if Valve ever gates it behind game
# ownership again; with Steam Guard on the account also set
# STEAM_GUARD_CODE (delivered to SteamCMD's prompt via stdin).
update_args="3858450"
if [ ! -z "$BETANAME" ]; then
    update_args="3858450 -beta $BETANAME"
    if [ ! -z "$BETAPASSWORD" ]; then
        update_args="$update_args -betapassword $BETAPASSWORD"
        log_info "Using beta $BETANAME with the password ****"
    else
        log_info "Using beta $BETANAME without a password!"
    fi
else
    log_info "No beta branch used."
fi

if [ ! -z "$STEAM_LOGIN" ]; then
    log_info "Logging in to Steam as $STEAM_LOGIN"
    printf '%s\n' "${STEAM_GUARD_CODE:-}" | steamcmd +@sSteamCmdForcePlatformType windows +force_install_dir "$server_files" +login "$STEAM_LOGIN" "$STEAM_PWD" +app_license_request 3858450 +app_update "$update_args" validate +quit
else
    steamcmd +@sSteamCmdForcePlatformType windows +force_install_dir "$server_files" +login anonymous +app_license_request 3858450 +app_update "$update_args" validate +quit
fi

# The wine game process loads steamclient.so from ~/.steam/sdk64 (and sdk32)
# at startup; without it the server aborts with a Steam library error.
# Copied from SteamCMD's payload, same as the official Pterodactyl egg.
steamcmd_home=$(dirname "$(readlink -f "$(command -v steamcmd)")")
sc64="$steamcmd_home/linux64/steamclient.so"
[ -f "$sc64" ] || sc64=$(find / -path /proc -prune -o -path '*/linux64/steamclient.so' -print 2>/dev/null | head -1)
if [ -n "$sc64" ] && [ -f "$sc64" ]; then
    mkdir -p "$HOME/.steam/sdk64" "$HOME/.steam/sdk32"
    cp -f "$sc64" "$HOME/.steam/sdk64/steamclient.so"
    sc32="${sc64/linux64/linux32}"
    [ -f "$sc32" ] && cp -f "$sc32" "$HOME/.steam/sdk32/steamclient.so"
    log_info "Steam client libraries staged for wine."
else
    log_warn "steamclient.so not found next to SteamCMD - the server may fail to start."
fi

# Fail fast with a clear message instead of crash-looping wine on a broken
# or partial download (Steam outage, empty credentials, disk full).
log_phase "Install check"
if [ ! -f "$server_files/server/CubicOdysseyServer.exe" ]; then
    log_error "Cubic Odyssey server installation failed - server/CubicOdysseyServer.exe missing."
    log_error "The SteamCMD update above did not produce a usable server. Check the output above"
    log_error "(Steam outage? invalid STEAM_LOGIN/STEAM_PWD/STEAM_GUARD_CODE? disk full?) and restart."
    exit 1
fi
log_info "Server files installed OK."

log_phase "Config generation"
if [ "$CUSTOM_CONFIG" = "true" ]; then
    log_info "CUSTOM_CONFIG=true: using your own server_config.txt untouched"
else
    log_info "Running setup script for server_config.txt"
    source ./scripts/env2cfg.sh
fi

# Apply a deferred restore (backup.sh --restore without --now) before the
# server starts, so the game loads the restored game data. No-op if none.
bash ./scripts/backup.sh --apply-pending

# Automatic backups run through an in-process scheduler instead of cron:
# it sees the container environment (BACKUP_RETENTION, TZ), logs to
# `docker logs`, and runs as the cubic user (no root-owned archives).
log_phase "Scheduler start"
if [ -n "$BACKUPS" ]; then
    # explicit env wins: BACKUPS=false/off/no disables anything else
    if [ "$BACKUPS" = false ] || [ "$BACKUPS" = off ] || [ "$BACKUPS" = no ]; then
        log_info "Backups disabled (BACKUPS=$BACKUPS)"
    else
        nohup bash ./scripts/scheduler.sh >/dev/null 2>&1 &
        log_info "Backup scheduler started (BACKUPS=$BACKUPS)"
    fi
elif [ -f "$HOME/.image_cron" ]; then
    # default for :latest / image-cron builds: backups on
    nohup bash ./scripts/scheduler.sh >/dev/null 2>&1 &
    log_info "Backup scheduler started (image default; disable with BACKUPS=false)"
else
    # :non_cron builds keep the historical backups-off default
    log_info "Backups disabled (:non_cron image default; enable with BACKUPS=true)"
fi

if [ "${WEBUI:-false}" = true ]; then
    log_info 'Launching web admin UI'
    bash ./scripts/webui.sh &
fi

log_info "Cleaning possible X11 leftovers"
# Targeted cleanup only: the old condition was always true and wiped ALL of
# /tmp, including files other processes still need.
rm -f /tmp/.X*-lock 2>/dev/null
rm -rf /tmp/.X11-unix 2>/dev/null

cd "$server_files"
log_phase "Wine launch"
log_info "Starting Cubic Odyssey Dedicated Server"
log_info "Launching wine Cubic Odyssey"
source /home/cubic/scripts/wrapper.sh
