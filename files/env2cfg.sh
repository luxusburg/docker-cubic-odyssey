#!/bin/bash
# Generate/patch server_config.txt from environment variables.
#
# IMPORTANT: only env variables that are set to a NON-EMPTY value are written.
# Unset/empty variables leave the value already in the file untouched, so the
# defaults shipped in server_config.txt.sample survive.

# Shared logging helpers. start.sh sources log.sh before sourcing this file,
# so only load it when it is not already there (double-sourcing is guarded in
# log.sh itself, this check keeps the intent obvious).
if [ -z "${LOG_SH_LOADED:-}" ]; then
    source "$(dirname "${BASH_SOURCE[0]}")/log.sh"
fi

APP_FILE="$server_files/config/server_config.txt"
SAMPLE_FILE="$server_files/config/server_config.txt.sample"

# ---------------------------------------------------------------------------
# The Steam download does not ship server_config.txt, only the .sample copy.
# ---------------------------------------------------------------------------
if [ ! -f "$APP_FILE" ]; then
    mkdir -p "$(dirname "$APP_FILE")"
    if [ -f "$SAMPLE_FILE" ]; then
        log_info "server_config.txt not found - creating it from server_config.txt.sample"
        cp "$SAMPLE_FILE" "$APP_FILE"
    else
        log_warn "server_config.txt.sample not found - writing a minimal default config"
        cat > "$APP_FILE" <<'EOF'
GameParams
{
	m_server ServerParams
	{
		startingPort 0
		endingPort 0
		serverName "Cubic Odyssey Dedicated Server"
		serverPassword ""
		maxPlayers 48
		galaxySeed 0
		allowRelaying FALSE
		privateServer FALSE
		enableCrashDumps FALSE
		enableLogging FALSE
	}

	m_difficulty DifficultySettings
	{
		damagePlayerScale 1
		damagePirateScale 1
		damageCreatureScale 1
		damageDarknessScale 1
		damagePlayerShipScale 1
		damagePirateShipScale 1
		craftingCostScale 1
		tradingCostScale 1
		damageGearOnDeath true
		loseQbitsOnDeath true
	}
}
EOF
    fi
fi

if [ "$CUSTOM_CONFIG" = "true" ]; then
    log_info "Not changing server_config.txt"
    # This file is SOURCED by start.sh: a plain 'exit' would kill the whole
    # container startup. Return when sourced, exit only when executed.
    return 0 2>/dev/null || exit 0
fi

# ---------------------------------------------------------------------------
# Helpers. Values are handed to awk through the environment (ENVIRON), never
# interpolated into the program text.
# ---------------------------------------------------------------------------
write_key() {
    # $1 = config key, $2 = value (already formatted), $3 = "secret" to mask output
    local key="$1" value="$2" secret="${3:-}"

    CO_KEY="$key" CO_VALUE="$value" awk '
        BEGIN { key = ENVIRON["CO_KEY"]; val = ENVIRON["CO_VALUE"] }
        {
            line = $0; cr = ""
            if (line ~ /\r$/) { cr = "\r"; sub(/\r$/, "", line) }
            if (!done && line ~ ("^[ \t]*" key "[ \t]")) {
                print "\t" key " " val cr
                done = 1
                next
            }
            # key absent from the file: insert it before the closing brace of
            # the m_server block (the first standalone "}" in the file)
            if (!done && !inserted && line ~ /^[ \t]*\}[ \t]*$/) {
                print "\t" key " " val cr
                inserted = 1
            }
            print line cr
        }
        END {
            if (!done && !inserted) print "\t" key " " val
        }
    ' "$APP_FILE" > "$APP_FILE.tmp" || { log_warn "could not rewrite $APP_FILE"; rm -f "$APP_FILE.tmp"; return 1; }
    mv "$APP_FILE.tmp" "$APP_FILE"

    if [ "$secret" = "secret" ]; then
        log_info "$key set to: ****"
    else
        log_info "$key set to: $value"
    fi
}

set_string() {
    # $1 = config key, $2 = env var name, $3 = "secret" to mask output
    local key="$1" var="$2" secret="${3:-}" value="${!2}"
    [ -z "$value" ] && return 0
    case "$value" in
        *'"'*)
            log_warn "$var: quotes not supported in this value - $key not changed"
            return 0
            ;;
    esac
    write_key "$key" "\"$value\"" "$secret"
}

set_int() {
    local key="$1" var="$2" value="${!2}"
    [ -z "$value" ] && return 0
    if ! [[ "$value" =~ ^[0-9]+$ ]]; then
        log_warn "$var: '$value' is not a number - $key not changed"
        return 0
    fi
    if [ "$key" = "maxPlayers" ] && [ "$((10#$value))" -le 0 ]; then
        log_warn "$var: '$value' is not a positive number - $key not changed"
        return 0
    fi
    write_key "$key" "$value"
}

set_bool() {
    local key="$1" var="$2" value="${!2}"
    [ -z "$value" ] && return 0
    case "$(echo "$value" | tr '[:upper:]' '[:lower:]')" in
        true|1|yes)  write_key "$key" "TRUE" ;;
        false|0|no)  write_key "$key" "FALSE" ;;
        *) log_warn "$var: '$value' is not a boolean (true/false/1/0/yes/no) - $key not changed" ;;
    esac
}

# ---------------------------------------------------------------------------
# Environment -> server_config.txt mapping (only non-empty variables apply)
# ---------------------------------------------------------------------------
if [ -n "$GALAXY_SEED" ]; then
    if [[ "$GALAXY_SEED" =~ ^[0-9]{1,11}$ ]]; then
        write_key "galaxySeed" "$GALAXY_SEED"
    else
        log_warn "GALAXY_SEED: '$GALAXY_SEED' is not up to 11 digits - galaxySeed not changed"
    fi
fi

set_string "serverPassword" "SERVER_PWD" "secret"
set_int      "maxPlayers"   "MAX_PLAYERS"
set_string "serverName"     "SERVER_NAME"
set_bool     "privateServer"    "PRIVATE_SERVER"
set_int      "startingPort"     "STARTING_PORT"
set_int      "endingPort"       "ENDING_PORT"

if [ -n "$GAME_MODE" ]; then
    case "$(echo "$GAME_MODE" | tr '[:upper:]' '[:lower:]')" in
        adventure) write_key "gameMode" "ADVENTURE" ;;
        creative)  write_key "gameMode" "CREATIVE" ;;
        *) log_warn "GAME_MODE: '$GAME_MODE' is not ADVENTURE or CREATIVE - gameMode not changed" ;;
    esac
fi

set_bool "enableCrashDumps" "ENABLE_CRASH_DUMPS"
set_bool "allowRelaying"    "ALLOW_RELAYING"
set_bool "enableLogging"    "ENABLE_LOGGING"
