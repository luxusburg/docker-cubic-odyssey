#!/bin/bash

APP_FILE="$server_files/config/server_config.txt"

variables=( 
    "GALAXY_SEED" "galaxySeed"
    "SERVER_PWD" "serverPassword"
    "MAX_PLAYERS" "maxPlayers"
    "SERVER_NAME" "serverName"
    "PRIVATE_SERVER" "privateServer"
    "STARTING_PORT" "startingPort"
    "ENDING_PORT" "endingPort"
    "GAME_MODE" "gameMode"
    "ENABLE_CRASH_DUMPS" "enableCrashDumps"
    "ALLOW_RELAYING" "allowRelaying"
    "ENABLE_LOGGING" "enableLogging"    
)

for ((i=0; i<${#variables[@]}; i+=2)); do
    var_name=${variables[$i]}
    config_name=${variables[$i+1]}

    if [ ! -z "${!var_name}" ]; then
        echo "${config_name} set to: ${!var_name}"        
        value="${!var_name}"                
    fi
    if grep -q "$config_name" "$APP_FILE"; then
            sed -i "/$config_name /c $config_name $value" "$APP_FILE"
        else
            echo -ne "\n$config_name $value" >> "$APP_FILE"
    fi
done
