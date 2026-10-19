#!/bin/bash
# cubic-wrapper.sh

# Location of server executable
SERVER_EXE="$server_files/server/CubicOdysseyServer.exe"

cleanup() {
    echo "Received shutdown signal, stopping Cubic Odyssey server..."
    
    # Send SIGTERM to wine process
    kill -TERM "$wine_pid" 2>/dev/null
    
    # Wait for process to exit (with timeout)
    wait_timeout=30
    while kill -0 "$wine_pid" 2>/dev/null && [ $wait_timeout -gt 0 ]; do
        sleep 1
        ((wait_timeout--))
    done
    
    # Force kill if still running
    if kill -0 "$wine_pid" 2>/dev/null; then
        echo "Server did not shutdown gracefully, forcing exit..."
        kill -KILL "$wine_pid" 2>/dev/null
    fi
    
    echo "Server shutdown complete"
    exit 0
}

# Trap signals
trap cleanup SIGINT SIGTERM

# Start Xvfb and Wine
echo "Starting Cubic Odyssey Dedicated Server via Xvfb and Wine"
# Runtime parameters go on the command line (like the official Pterodactyl
# egg) - they take precedence over config/server_config.txt values.
server_args=(-Port="${GAME_PORT:-27001}")
[ ! -z "${SERVER_PWD}" ]  && server_args+=("-Password=${SERVER_PWD}")
[ ! -z "${GAMEMODE:-$GAME_MODE}" ] && server_args+=("-Gamemode=${GAMEMODE:-$GAME_MODE}")
[ ! -z "${MAX_PLAYERS}" ] && server_args+=("-MaxNumPlayers=${MAX_PLAYERS}")
# Extra power-user arguments, word-splitting intentional (no quoting tricks):
[ ! -z "${SERVER_ARGS}" ] && server_args+=(${SERVER_ARGS})
xvfb-run wine "$SERVER_EXE" "${server_args[@]}" 2>&1 &
wine_pid=$!

# Wait for the process to complete
wait "$wine_pid"

# Handle unexpected exits
if [ $? -ne 0 ]; then
    echo "Server process exited unexpectedly"
    exit 1
fi
