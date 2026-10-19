#!/bin/bash
# Location of server data and save data for docker

server_files=/home/cubic/server_files

echo " "
echo "Server files location is set to : $server_files"
echo " "

mkdir -p /home/cubic/.steam 2>/dev/null
chmod -R 777 /home/cubic/.steam 2>/dev/null
echo " "
echo "Updating Cubic Odyssey Dedicated Server files..."
echo " "

# The dedicated server TOOL downloads anonymously (verified 2026-10).
# Only set STEAM_LOGIN/STEAM_PWD if Valve ever gates it behind game
# ownership again; with Steam Guard on the account also set
# STEAM_GUARD_CODE (delivered to SteamCMD's prompt via stdin).
update_args="3858450"
if [ ! -z "$BETANAME" ]; then
    update_args="3858450 -beta $BETANAME"
    if [ ! -z "$BETAPASSWORD" ]; then
        update_args="$update_args -betapassword $BETAPASSWORD"
        echo "Using beta $BETANAME with the password ****"
    else
        echo "Using beta $BETANAME without a password!"
    fi
else
    echo "No beta branch used."
fi

if [ ! -z "$STEAM_LOGIN" ]; then
    echo "Logging in to Steam as $STEAM_LOGIN"
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
    echo "Steam client libraries staged for wine."
else
    echo "[WARN] steamclient.so not found next to SteamCMD - the server may fail to start."
fi

# Fail fast with a clear message instead of crash-looping wine on a broken
# or partial download (Steam outage, empty credentials, disk full).
if [ ! -f "$server_files/server/CubicOdysseyServer.exe" ]; then
    echo "[ERROR] Cubic Odyssey server installation failed - server/CubicOdysseyServer.exe missing."
    echo "[ERROR] The SteamCMD update above did not produce a usable server. Check the output above"
    echo "[ERROR] (Steam outage? invalid STEAM_LOGIN/STEAM_PWD/STEAM_GUARD_CODE? disk full?) and restart."
    exit 1
fi
echo "Server files installed OK."
echo " "

echo "Running setup script for the app.cfg file"
source ./scripts/env2cfg.sh   

echo " "
if [ -n "$NO_CRON" ]; then
    echo "No Cron image used!"
else
    sudo -u root cron

    if [ "$BACKUPS" = false ]; then
        echo "[IMPORTANT] Backups are disabled!"
        sudo -u root sed -i "/backup.sh/c # 0 * * * * /home/cubic/scripts/backup.sh 2>&1" /var/spool/cron/crontabs/root
    elif [ -n "$BACKUP_INTERVAL" ]; then
        echo "Changing backup interval to $BACKUP_INTERVAL"
        sudo -u root sed -i "/backup.sh/c $BACKUP_INTERVAL /home/cubic/scripts/backup.sh 2>&1" /var/spool/cron/crontabs/root
    fi
fi

echo " "
echo "Cleaning possible X11 leftovers"
echo " "
# Targeted cleanup only: the old condition was always true and wiped ALL of
# /tmp, including files other processes still need.
rm -f /tmp/.X*-lock 2>/dev/null
rm -rf /tmp/.X11-unix 2>/dev/null

cd "$server_files"
echo "Starting Cubic Odyssey Dedicated Server"
echo " "
echo "Launching wine Cubic Odyssey"
echo " "
source /home/cubic/scripts/wrapper.sh
