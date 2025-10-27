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

if [ ! -z $BETANAME ];then
    if [ ! -z $BETAPASSWORD ]; then
        echo "Using beta $BETANAME with the password $BETAPASSWORD"
        steamcmd +@sSteamCmdForcePlatformType windows +force_install_dir "$server_files" +login anonymous +app_update "3858450 -beta $BETANAME -betapassword $BETAPASSWORD" validate +quit
    else
        echo "Using beta $BETANAME without a password!" 
        steamcmd +@sSteamCmdForcePlatformType windows +force_install_dir "$server_files" +login anonymous +app_update "3858450 -beta $BETANAME" validate +quit
    fi
else
    echo "No beta branch used."
    steamcmd +@sSteamCmdForcePlatformType windows +force_install_dir "$server_files" +login anonymous +app_update 3858450 validate +quit
fi

echo "steam_appid: "`cat $server_files/steam_appid.txt`
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
if [ -f /tmp/.X0-lock ] || [ -d /tmp/ ]; then
    if [ -f /tmp/.X0-lock ]; then
        rm /tmp/.X0-lock > /dev/null 2>&1
    fi
    if [ -d /tmp/ ]; then
        rm -r /tmp/* > /dev/null 2>&1
    fi
fi

cd "$server_files"
echo "Starting Cubic Odyssey Dedicated Server"
echo " "
echo "Launching wine Cubic Odyssey"
echo " "
source /home/cubic/scripts/wrapper.sh
