#!/bin/bash
# cubic-wrapper.sh

# Shared logging helpers (this file is sourced by start.sh).
source "$(dirname "${BASH_SOURCE[0]}")/log.sh"

# Location of server executable
SERVER_EXE="$server_files/server/CubicOdysseyServer.exe"

cleanup() {
    log_warn "Received shutdown signal, stopping Cubic Odyssey server..."
    
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
        log_warn "Server did not shutdown gracefully, forcing exit..."
        kill -KILL "$wine_pid" 2>/dev/null
    fi
    
    log_info "Server shutdown complete"
    exit 0
}

# Trap signals
trap cleanup SIGINT SIGTERM

# Start Xvfb and Wine
log_info "Starting Cubic Odyssey Dedicated Server via Xvfb and Wine"
# Runtime parameters go on the command line (like the official Pterodactyl
# egg) - they take precedence over config/server_config.txt values.
server_args=(-Port="${GAME_PORT:-27001}")
[ ! -z "${SERVER_PWD}" ]  && server_args+=("-Password=${SERVER_PWD}")
[ ! -z "${GAMEMODE:-$GAME_MODE}" ] && server_args+=("-Gamemode=${GAMEMODE:-$GAME_MODE}")
[ ! -z "${MAX_PLAYERS}" ] && server_args+=("-MaxNumPlayers=${MAX_PLAYERS}")
# Extra power-user arguments, word-splitting intentional (no quoting tricks):
[ ! -z "${SERVER_ARGS}" ] && server_args+=(${SERVER_ARGS})
# The engine's console thread prints a '#' prompt in a hot loop (~78k
# lines/s, 1.6 GB/h of log) when it has no real terminal to read from: the
# read returns instantly, so the prompt reprints forever. Two-layer fix:
# run the container with a TTY (tty: true, see README/compose examples) and
# drop prompt-only lines from the output stream as a hard guarantee.
# The process substitution keeps wine a direct child, so SIGTERM
# forwarding above still works.
xvfb-run wine "$SERVER_EXE" "${server_args[@]}" > >(grep --line-buffered -vE '^#+[[:space:]]*$') 2>&1 &
wine_pid=$!

# Wait for the process to complete
wait "$wine_pid"

# Handle unexpected exits
if [ $? -ne 0 ]; then
    log_error "Server process exited unexpectedly"
    exit 1
fi
