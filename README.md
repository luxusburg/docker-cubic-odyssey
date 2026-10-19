# Cubic Odyssey Dedicated Server Docker Container 🚀
[![Docker Hub](https://img.shields.io/badge/Docker_Hub-cubic--odyssey-blue?logo=docker)](https://hub.docker.com/r/luxusburg/docker-cubic-odyssey)
[![Docker Pulls](https://img.shields.io/docker/pulls/luxusburg/docker-cubic-odyssey)](https://hub.docker.com/r/luxusburg/docker-cubic-odyssey)
[![Image Size](https://img.shields.io/docker/image-size/luxusburg/docker-cubic-odyssey/latest)](https://hub.docker.com/r/luxusburg/docker-cubic-odyssey/tags)
[![Github](https://img.shields.io/badge/Github-cubic--odyssey-blue?logo=github)](https://github.com/luxusburg/docker-cubic-odyssey)
![GitHub last commit](https://img.shields.io/github/last-commit/luxusburg/docker-cubic-odyssey)

This Docker container simplifies hosting your own [Cubic Odyssey](https://cubicodyssey.game/en/) dedicated server. 🚀

The Windows dedicated server runs under Wine + Xvfb; everything else (downloads, config, backups, optional admin UI) is handled for you. Tested on Linux (Ubuntu/Debian). 🐧

Contributions and feedback for improvements are welcome! 🤝

## 📜 Table of Contents

- [✨ Features](#-features)
- [✅ Prerequisites](#-prerequisites)
- [🚀 Quick Start](#-quick-start)
  - [🐳 Using `docker run`](#-using-docker-run)
  - [🏗️ Using `docker-compose`](#-using-docker-compose)
- [⚙️ Server Configuration](#️-server-configuration)
  - [🗂️ Volumes](#-volumes)
  - [🔌 Ports](#-ports)
- [💾 Backup and Recovery](#-backup-and-recovery)
- [🖥️ Admin Web UI](#-admin-web-ui)
- [🔧 Environment Variables](#-environment-variables)
  - [🎮 Game Settings](#-game-settings)
  - [🗳️ Backup Settings](#-backup-settings)
  - [👤 User PUID/PGID](#-user-puidpgid)
  - [🧪 Beta Branch](#-beta-branch)
  - [🔐 Optional Steam Account Login](#-optional-steam-account-login)
  - [🖥️ Web UI Settings](#-web-ui-settings)
- [📜 Logging](#-logging)
- [🩺 Troubleshooting](#-troubleshooting)
- [💖 Contributing](#-contributing)

## ✨ Features

* 💨 Zero-account setup: the server tool downloads **anonymously** from Steam (no Steam account needed).
* 🔄 Automated game server updates on container start.
* 🔧 Configurable via environment variables (written into the game's `server_config.txt`), or bring your own config with `CUSTOM_CONFIG=true`.
* 💾 Automatic backups of your **game data only** (binaries are re-downloadable and excluded), with integrity-checked archives, retention pruning and safe deferred restores.
* 🖥️ Optional token-gated admin Web UI (status, backups, config editor, logs, restart).
* 🧪 Support for game beta branches.

## ✅ Prerequisites

* Docker installed on your system.
* Docker Compose (for the `docker-compose` method).
* Basic understanding of Docker concepts (volumes, ports).

> [!NOTE]
> You do **not** need a Steam account, an app password, or an account without email guard — the dedicated-server tool (Steam app `3858450`) is free and downloads anonymously. See [Optional Steam Account Login](#-optional-steam-account-login) for edge cases.

## 🚀 Quick Start

It's recommended to create a dedicated directory on your host machine to store server data and configuration before running the commands. For example:

```bash
mkdir ~/cubic-odyssey-server
cd ~/cubic-odyssey-server
```

The examples map `./server` (game install + saves) and `./data` (backups & logs) from your current working directory into the container.

## 🐳 Using `docker run`
```bash
docker run -d \
    --name cubic-odyssey-server \
    -p 27001:27001/udp \
    -v ./server:/home/cubic/server_files \
    -v ./data:/home/cubic/persistent_data \
    -e TZ="Europe/Paris" \
    -e SERVER_NAME="Cubic Odyssey Docker by Luxusburg" \
    -e SERVER_PWD="change_me" \
    -e MAX_PLAYERS=8 \
    luxusburg/docker-cubic-odyssey:latest
```
## 🏗️ Using `docker-compose`
Create a `docker-compose.yml` file:
```yaml
# version: '3.8' # Uncomment if your Docker Compose version requires it
services:
  cubic-odyssey:
    container_name: cubic-odyssey-server
    image: luxusburg/docker-cubic-odyssey:latest
    network_mode: bridge # Or 'host' if preferred, adjust ports accordingly
    environment:
      - TZ=Europe/Paris
      - SERVER_NAME=Cubic Odyssey Docker - by Luxusburg
      - SERVER_PWD=change_me_strong_password
      - GALAXY_SEED=123456
      - MAX_PLAYERS=10
      - GAME_PORT=27001
      # Backup Settings
      - BACKUPS=true
      - BACKUPS_PER_DAY=4
      - BACKUP_RETENTION=30
      # PUID/PGID Settings
      # - PUID=1000
      # - PGID=1000
      # Optional admin Web UI (see section below)
      # - WEBUI=true
      # - WEBUI_TOKEN=choose_a_long_random_token
    volumes:
      - ./server:/home/cubic/server_files:rw
      - ./data:/home/cubic/persistent_data:rw
    ports:
      - "27001:27001/udp"
    restart: unless-stopped
```

Then run:

```bash
docker compose up -d
```

## ⚙️ Server Configuration

Server options are written into the game's own `config/server_config.txt` inside the server volume — on first start the container seeds it from the official `server_config.txt.sample` shipped with the game.

> [!TIP]
> Want full manual control? Set `CUSTOM_CONFIG=true` and the container will never touch your `server_config.txt`.

### 🗂️ Volumes

| Container path            | Content |
|---------------------------|---------|
| `/home/cubic/server_files`  | Game server install (SteamCMD), the Wine prefix (`.wine/`), the mutable game data in `CubicOdyssey/` (world/saves) and `config/server_config.txt`. |
| `/home/cubic/persistent_data` | Backups (`backup/`), scheduler log, container logs for the Web UI. |

### 🔌 Ports

The game listens on **one UDP port** (`GAME_PORT`, default `27001`). If it is busy the server tries the range `STARTING_PORT`→`ENDING_PORT` from `server_config.txt`. Expose the port you choose:

```yaml
ports:
  - "27001:27001/udp"
```

## 💾 Backup and Recovery

Backups run automatically on a schedule (`:latest` image default: 4/day) and archive **only the game data** (`server_files/CubicOdyssey`), never the ~1.2 GB of re-downloadable binaries. Archives land in `./data/backup/` as `cubic_backup-YYYY-MM-DD_HH-MM-SS.tar.gz`.

Each archive is integrity-checked before it is kept, disk space is guarded (`MIN_FREE_DISK_GB`), and old archives are pruned by count (`BACKUP_RETENTION`).

**Create a backup manually:**
```bash
docker exec cubic-odyssey-server bash /home/cubic/scripts/backup.sh --create
```

**List archives:**
```bash
docker exec cubic-odyssey-server bash /home/cubic/scripts/backup.sh --list
```

**Restore a backup:**
```bash
# Safe default: the restore is *staged* and applied during the next
# container start, with an automatic pre_restore_<timestamp> safety copy.
docker exec cubic-odyssey-server bash /home/cubic/scripts/backup.sh --restore cubic_backup-2026-10-19_04-23-00.tar.gz
docker restart cubic-odyssey-server
```
> [!IMPORTANT]
> ❗ A restore overwrites your current game data. A safety copy is kept automatically as `pre_restore_<timestamp>` in the persistent data volume, but keep separate copies of anything irreplaceable.

`--restore <name> --now` applies immediately instead of staging (only when the server is idle).

## 🖥️ Admin Web UI

Optional, off by default. A single-page admin interface served by the container itself (stdlib Python, no extra services):

* **Status** — running/stopped, PID, uptime, server name, game-data presence, disk usage, backup count.
* **Backups** — list, create, restore (staged), scheduler log tail.
* **Config** — edit `server_config.txt` (sanity-checked, restart to apply).
* **Logs** — tail of the container log.
* **Danger zone** — restart the container (applies staged restores).

```yaml
environment:
  - WEBUI=true
  - WEBUI_TOKEN=choose_a_long_random_token   # required
ports:
  - "27001:27001/udp"
  - "127.0.0.1:8080:8080"   # bind to localhost or an VPN/SSH tunnel; do not expose to the internet
```

Open `http://<host>:8080/`, paste the token. Traffic is **unencrypted HTTP** — keep it off the public internet.

## 🔧 Environment Variables

The container uses environment variables for configuration.

### 🎮 Game Settings

| Variable                  | Default / Example             | Description |
|---------------------------|-------------------------------|-------------|
| `TZ`                      | `Europe/Paris`                | Container timezone 🌍. [List of tz database time zones](https://en.wikipedia.org/wiki/List_of_tz_database_time_zones). |
| `SERVER_NAME`             | `Cubic Odyssey Dedicated Server` | Name of the server in the browser 📢. |
| `SERVER_PWD`              | (none)                        | Server password 🔑 (also passed on the command line, overriding the config file). |
| `MAX_PLAYERS`             | (game default `48`)           | Maximum number of players 🧑‍🤝‍🧑. |
| `GAME_PORT`               | `27001`                       | The UDP port the server binds 🔌 (command line, overrides config). |
| `GAMEMODE`                | `ADVENTURE` or `CREATIVE`     | Game mode; `GAME_MODE` is accepted as an alias 🎲. |
| `GALAXY_SEED`             | `0`                           | Galaxy seed 🗺️ — up to 11 digits. |
| `PRIVATE_SERVER`          | `FALSE`                       | `true`/`false` — hide from the public browser. |
| `STARTING_PORT` / `ENDING_PORT` | `0` / `0`               | Port fallback range written to `server_config.txt` when `GAME_PORT` is taken 📡. |
| `ENABLE_CRASH_DUMPS`      | `FALSE`                       | Enable/disable crash dumps. |
| `ALLOW_RELAYING`          | `FALSE`                       | Enable/disable relay servers. |
| `ENABLE_LOGGING`          | `FALSE`                       | Enable in-game logging. |
| `SERVER_ARGS`             | (none)                        | Extra raw command-line arguments for power users (e.g. `-Foo Bar`). |
| `CUSTOM_CONFIG`           | `false`                       | `true` = never touch your `server_config.txt`. |

Only variables you actually set are written — everything else keeps the values in your `server_config.txt`.

### 🗳️ Backup Settings

| Variable               | Default        | Description |
|------------------------|----------------|-------------|
| `BACKUPS`              | `true` (`:latest`), `false` (`:non_cron`) | `true`/`false` — enable/disable the backup scheduler. Overrides the image default. |
| `BACKUPS_PER_DAY`      | `4`            | Backups spread evenly over the day. |
| `BACKUP_INTERVAL_MINUTES` | (unset)     | Set instead of `BACKUPS_PER_DAY` for a fixed interval in minutes. |
| `BOOT_DELAY_MINUTES`   | `10`           | Wait after boot before the first backup may run. |
| `RUN_BACKUP_ON_BOOT`   | `false`        | Run a backup shortly after every boot. |
| `BACKUP_RETENTION`     | `30`           | Number of archives kept (oldest pruned). |
| `MIN_FREE_DISK_GB`     | `5`            | Skip backups when the backup volume has less free space. |
| `BACKUP_INCLUDE`       | `$SERVER_FILES/CubicOdyssey` | Space-separated paths to archive. |

### 👤 User PUID/PGID

These variables are used to set the user and group ID for the `cubic` user inside the container, which helps manage file permissions on mounted volumes.

| Variable | Default | Description                     |
|----------|---------|---------------------------------|
| `PUID`   | `1000`  | User ID for the cubic user.    |
| `PGID`   | `1000`  | Group ID for the cubic user.   |

To find your user's ID on Linux, you can use the command `id $(whoami)`.

### 🧪 Beta Branch

To use a beta branch of the game:

> [!WARNING]
> Do **not** use double ("") or single ('') quotes around the beta name or password.

| Variable        | Default / Example | Description                                      |
|-----------------|-------------------|--------------------------------------------------|
| `BETANAME`      | `(none)`          | Name of the Steam beta branch to use.            |
| `BETAPASSWORD`  | `(none)`          | Password for the beta branch, if required.       |

### 🔐 Optional Steam Account Login

Not needed — downloads work anonymously. Set these only if Valve changes the license setup or you need an account-gated branch:

| Variable           | Default | Description |
|--------------------|---------|-------------|
| `STEAM_LOGIN`      | (none)  | Steam account name (log in instead of anonymous). |
| `STEAM_PWD`        | (none)  | Account password (a [Steam Guard code](https://help.steampowered.com/) may be required). |
| `STEAM_GUARD_CODE` | (none)  | Steam Guard code for headless logins (short-lived; refresh it when the container starts). |

The server **license** (`+app_license_request`) is requested automatically either way.

### 🖥️ Web UI Settings

| Variable       | Default | Description |
|----------------|---------|-------------|
| `WEBUI`        | `false` | `true` = enable the admin UI. |
| `WEBUI_TOKEN`  | (none)  | Required when `WEBUI=true`. Bearer token for all API/UI access. |
| `WEBUI_PORT`   | `8080`  | Listen port (map it through `ports:` as shown above). |

## 📜 Logging

All container scripts log through one shared helper, so every line is timestamped:

```
[2026-10-19 08:15:02] [INFO ] No beta branch used.
[2026-10-19 08:15:41] [WARN ] steamclient.so not found next to SteamCMD - the server may fail to start.
[2026-10-19 08:15:41] [ERROR] Cubic Odyssey server installation failed - CubicOdysseyServer.exe missing.
== SteamCMD update ==
```

* Timestamp format: `[YYYY-MM-DD HH:MM:SS] [LEVEL ] message` (container local time, i.e. `TZ`).
* Set `LOG_LEVEL` to control verbosity: `error`, `warn`, `info` (default) or `debug`/`trace` for script-level debugging.
* Errors go to stderr, everything else to stdout - both are visible in `docker logs -f <container>`.
* Colour codes are emitted only on an interactive terminal; when the logs are captured by Docker the output stays free of escape sequences.
* SteamCMD and wine/game output is passed through unmodified.

## 🩺 Troubleshooting

* **First start takes a while** — the server tool (~1.2 GB) downloads on first boot; watch progress with `docker logs -f cubic-odyssey-server`.
* **Server starts then quits with a Steam error** — check that `server_files` isn't mounted with an odd `PUID` that blocks SteamCMD's caches (the entrypoint fixes the common cases; if you remap deeply, `chown` your host folders too).
* **Port already used** — the server falls through `STARTING_PORT`→`ENDING_PORT`; change `GAME_PORT` or free the port.
* **No backups appear** — game data (`CubicOdyssey/`) is created only after the world has been generated; the scheduler logs a warning until then. Check `BACKUPS` is not `false` and that the `:non_cron` image was not intended.
* **Wine prefix** — lives in `server_files` (`.wine`); deleting it forces first-time setup (game data is not lost, but expect a longer start).

## 💖 Contributing

Feedback, bug reports, and pull requests are welcome! Please feel free to open an issue or submit a PR on the [GitHub repository](https://github.com/luxusburg/docker-cubic-odyssey).
