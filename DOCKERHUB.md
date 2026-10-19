# Cubic Odyssey Dedicated Server Docker Container 🚀

A ready-to-run [Cubic Odyssey](https://cubicodyssey.game/en/) dedicated server in Docker. The Windows server runs under Wine + Xvfb; downloads, config, updates, backups and an optional admin Web UI are fully automated.

**No Steam account needed** — the dedicated-server tool downloads anonymously.

```bash
docker run -d \
    --name cubic-odyssey-server \
    -p 27001:27001/udp \
    -v ./server:/home/cubic/server_files \
    -v ./data:/home/cubic/persistent_data \
    -e TZ="Europe/Paris" \
    -e SERVER_NAME="My Cubic Odyssey Server" \
    -e SERVER_PWD="change_me" \
    -e MAX_PLAYERS=8 \
    luxusburg/docker-cubic-odyssey:latest
```

## Image tags

| Tag | Backups by default | Description |
|-----|--------------------|-------------|
| `latest` | ✅ 4/day | Recommended. Scheduler + safe restores. |
| `non_cron` | ❌ | Same image, backup scheduler off by default (`BACKUPS=true` re-enables). |

## Features

* 💨 Anonymous Steam download of the server tool (app `3858450`) + license request; auto-update on every container start.
* 🔧 Environment-variable configuration written into the game's own `server_config.txt` (seeded from the official sample), or `CUSTOM_CONFIG=true` for manual control.
* 💾 Integrity-checked backups of game data only (binaries excluded), retention pruning, disk guard, staged restores with automatic safety copies.
* 🖥️ Optional token-gated admin Web UI: status, backups, config editor, log tail, restart.
* 🧪 Beta-branch support; `PUID`/`PGID` support; timestamped, levelled logging.

## Key environment variables

| Variable | Default | Description |
|----------|---------|-------------|
| `SERVER_NAME` | sample default | Server browser name. |
| `SERVER_PWD` | (none) | Server password (passed on the command line). |
| `MAX_PLAYERS` | game default `48` | Max players. |
| `GAME_PORT` | `27001` | UDP port to publish (`-p 27001:27001/udp`). |
| `GALAXY_SEED` | `0` | Galaxy seed (≤ 11 digits). |
| `GAME_MODE` / `GAMEMODE` | `ADVENTURE` | `ADVENTURE` or `CREATIVE`. |
| `PRIVATE_SERVER` | `FALSE` | Hide from public browser. |
| `CUSTOM_CONFIG` | `false` | Never touch `server_config.txt`. |
| `BACKUPS` / `BACKUPS_PER_DAY` / `BACKUP_RETENTION` | image / `4` / `30` | Backup scheduler controls. |
| `WEBUI` / `WEBUI_TOKEN` / `WEBUI_PORT` | `false` / — / `8080` | Optional admin UI (HTTP — keep it off the public internet). |
| `PUID` / `PGID` / `TZ` | `1000` / `1000` / `Europe/Berlin` | Standard container identity/timezone. |

Full documentation (ports, restore workflow, Steam Guard edge cases, troubleshooting): https://github.com/luxusburg/docker-cubic-odyssey

## Volumes

| Path | Content |
|------|---------|
| `/home/cubic/server_files` | Game install, Wine prefix, game data (`CubicOdyssey/`), `config/server_config.txt`. |
| `/home/cubic/persistent_data` | Backups (`backup/`), scheduler + container logs. |

## Backup & restore

```bash
docker exec cubic-odyssey-server bash /home/cubic/scripts/backup.sh --create
docker exec cubic-odyssey-server bash /home/cubic/scripts/backup.sh --list
docker exec cubic-odyssey-server bash /home/cubic/scripts/backup.sh --restore cubic_backup-2026-10-19_04-23-00.tar.gz
docker restart cubic-odyssey-server   # staged restore applies at start, safety copy kept
```

Cubic Odyssey is a trademark of its respective owners. This project is not affiliated with or endorsed by the game developers.
