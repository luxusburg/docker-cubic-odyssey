# Cubic Odyssey Dedicated Server Docker Container 🏭
[![Docker Hub](https://img.shields.io/badge/Docker_Hub-foundry-blue?logo=docker)](https://hub.docker.com/r/luxusburg/docker-cubic-odyssey)
[![Docker Pulls](https://img.shields.io/docker/pulls/luxusburg/docker-cubic-odyssey)](https://hub.docker.com/r/luxusburg/docker-cubic-odyssey)
[![Image Size](https://img.shields.io/docker/image-size/luxusburg/docker-cubic-odyssey/latest)](https://hub.docker.com/r/luxusburg/docker-cubic-odyssey/tags)
[![Github](https://img.shields.io/badge/Github-foundry-blue?logo=github)](https://github.com/luxusburg/docker-cubic-odyssey)
![GitHub last commit](https://img.shields.io/github/last-commit/luxusburg/docker-cubic-odyssey)

This Docker container simplifies hosting your own [Cubic Odyssey](https://cubicodyssey.game/en/) dedicated server. 🚀

It has been tested and confirmed to work on Linux (Ubuntu/Debian). 🐧

Contributions and feedback for improvements are welcome! 🤝

## 📜 Table of Contents

- [✨ Features](#-features)
- [✅ Prerequisites](#-prerequisites)
- [🚀 Quick Start](#-quick-start)
  - [🐳 Using `docker run`](#-using-docker-run)
  - [🏗️ Using `docker-compose`](#-using-docker-compose)
- [⚙️ Server Configuration](#-server-configuration)
  - [🗂️ Volumes](#-volumes)
- [💾 Backup and Recovery](#-backup-and-recovery)
- [🔧 Environment Variables](#-environment-variables)
  - [🎮 Game Settings](#-game-settings)
  - [🗳️ Backup Settings](#-backup-settings)
  - [👤 User PUID/PGID](#-user-puidpgid)
  - [🧪 Beta Branch](#-beta-branch)
- [💖 Contributing](#-contributing)

## ✨ Features

* 💨 Easy setup for a Cubic Odyssey dedicated server.
* 🔄 Automated game server updates on container start.
* 🔧 Configurable via environment variables.
* 💾 Built-in backup and restore functionality.
* 🧪 Support for game beta branches.

## ✅ Prerequisites

* Docker installed on your system.
* Docker Compose (for `docker-compose` method).
* Basic understanding of Docker concepts (volumes, ports).

>
> Create an steam account without an email guard to be able to use this Version! 
> User variables `LOGIN` and `PASSWORD` to download the server

## 🚀 Quick Start

It's recommended to create a dedicated directory on your host machine to store server data and configuration before running the commands. For example:

```bash
mkdir ~/cubic-odyssey-server
cd ~/cubic-odyssey-server
```
The following examples will map `./server` (for game and save files) in your current working directory to the container.

## 🐳 Using `docker run`
```bash
docker run -d \
    --name cubic-odyssey-server \
    -p 3724:3724/udp \
    -p 27015:27015/udp \
    -v ./server:/home/cubic/server_files \    
    -e TZ="Europe/Paris" \
    -e SERVER_NAME=Cubic Odyssey Docker by Luxusburg \
    -e SERVER_PWD=change_me \
    -e PAUSE_SERVER_WHEN_EMPTY=false \
    -e MAX_TRANSFER_RATE=8192 \
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
      - GALAXY_SEED_='123456'
      - SERVER_PWD=change_me_strong_password
      - SERVER_NAME=Cubic Odyssey Docker - by Luxusburg
      - MAX_PLAYERS_=10            
      # Backup Settings
      - BACKUPS=true
      - BACKUP_INTERVAL=0 * * * * # Every hour at minute 0
      - BACKUP_RETENTION=3 # Keep backups older than X days      
      # PUID/PGID Settings
      # - PUID=1000
      # - PGID=1000
    volumes:
      - ./server:/home/cubic/server_files:rw      
    ports:
      - "27001:27001/udp"      
    restart: unless-stopped
```

Then run:

```bash
docker compose up -d
```

## ⚙️ Server Configuration

### 🗂️ Volumes

- `/home/cubic/server_files` (e.g., `./server` on host): Stores the main game server files installed via SteamCMD.

## 💾 Backup and Recovery

Backups are enabled by default and stored in the `backup` subfolder within your persistent data volume (e.g., `./server/backup/`).

**To recover a backup:**

1. Stop the Cubic Odyssey server container:
```bash
docker stop cubic-odyssey-server
# or for docker-compose
docker compose down
```
>[!IMPORTANT]
> ❗ The following command will overwrite your current world save files! **Ensure you have a separate copy of your current world data if you might need it.**

2. Extract the desired backup archive into your persistent data directory. Replace `your_persistent_data_path` in our example (e.g., `./server`) and the backup filename accordingly:
```bash
# Example:
tar -xzvf ./server/backup/cubic-odyssey-backup-YYYY-MM-DD_HH-MM-SS.tar.gz -C ./server
```
**This will restore the save folder into `./server`**
3. Restart the container

## 🔧 Environment Variables

The container uses environment variables for configuration.

### 🎮 Game Settings

| Variable                  | Default / Example             | Description |
|---------------------------|-------------------------------|-------------|
| `TZ`                      | `Europe/Paris`                | Sets the timezone for the container 🌍. [List of tz database time zones](https://en.wikipedia.org/wiki/List_of_tz_database_time_zones). |
| `GALAXY_SEED`             | `123456`                      | Sets the galaxy seed 🗺️. |
| `SERVER_PWD`              | (none)                        | Sets the server password 🔑. **Highly recommended**. |
| `SERVER_NAME`             | `Cubic Odyssey Docker Server` | Name of the server listed in the Steam server browser (if public) 📢. |
| `MAX_PLAYERS`             | `10`                          | Sets the maximum number of players allowed on the server 🧑‍🤝‍🧑. |
| `STARTING_PORT`           | `27001`                       | Set the port to bind the game to 🔌. |
| `ENDING_PORT`             | `27001`                       | The maximum port to try to bind to starting from the port value📡. |
| `GAME_MODE`               | `ADVENTURE` or `CREATIVE`     | Sets the desired game mode, it's adventure by default.
| `ENABLE_CRASH_DUMPS`      | `TRUE` or `FALSE`             | Enable/disable crash dumps. |
| `ALLOW RELAYING`          | `TRUE` or `FALSE`             | Enable/diable relaying. |
| `ENABLE_LOGGING`          | `TRUE` or `FALSE`             | Enable/disable logging. |

### 🗳️ Backup Settings

> [!WARNING]  
> For `BACKUP_INTERVAL`, do not use double (`""`) or single (`''`) quotes around the cron schedule value.

| Variable          | Default / Example      | Description |
|-------------------|------------------------|-------------|
| `BACKUPS`         | `true`                 | `true` or `false`. Enables or disables the automatic backup system. |
| `BACKUP_INTERVAL` | `0 * * * *`            | Cron schedule for backups (e.g., `0 * * * *` for every hour at minute 0) 🗓️ [Cron schedule](https://en.wikipedia.org/wiki/Cron#Overview) |
| `BACKUP_RETENTION`| `10` (backups)         | Sets how many backup files are kept. |

### 👤 User PUID/PGID

These variables are used to set the user and group ID for the `cubic` user inside the container, which helps manage file permissions on mounted volumes.

| Variable | Default | Description                     |
|----------|---------|---------------------------------|
| `PUID`   | `1000`  | User ID for the cubic user.    |
| `PGID`   | `1000`  | Group ID for the cubic user.   |

To find your user's ID on Linux, you can use the command `id $(whoami)`.

## 🧪 Beta Branch

To use a beta branch of the game:

> [!WARNING]
> Do **not** use double ("") or single ('') quotes around the beta name or password.

 | Variable        | Default / Example | Description                                      |
|-----------------|-------------------|--------------------------------------------------|
| `BETANAME`     | `(none)`          | Name of the Steam beta branch to use.            |
| `BETAPASSWORD` | `(none)`          | Password for the beta branch, if required.       |

## 💖 Contributing

Feedback, bug reports, and pull requests are welcome! Please feel free to open an issue or submit a PR on the [GitHub repository](https://github.com/luxusburg/docker-cubic-odyssey).
