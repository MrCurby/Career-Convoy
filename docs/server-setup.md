# Server setup

This guide is for people who run a BeamMP server. Players don't need to install anything, because BeamMP sends the mod to them when they join.

- [Requirements](#requirements)
- [Install with server.sh (recommended)](#install-with-serversh-recommended)
- [server.sh reference](#serversh-reference)
- [What an update does](#what-an-update-does)
- [Manual installation and updates](#manual-installation-and-updates)
- [Rolling back](#rolling-back)
- [Save games](#save-games)
- [Switching from Mileage](#switching-from-mileage)

## Requirements

- A **BeamMP server** (tested with 3.9.3 on Linux)
- Players on **BeamNG.drive 0.39 or newer** (tested with 0.40.5) and BeamMP (tested with 4.23.1)
- **West Coast USA** is recommended. The enlarged garage-computer zones are made for this map. Other maps work, but the computers there only get the smaller in-game range boost.
- For `server.sh`: `screen`, `unzip` and `curl` (`sudo apt install screen unzip curl`)

In `ServerConfig.toml`:

```toml
MaxCars = 100                              # traffic counts as cars of the player who spawned it
Map = "/levels/west_coast_usa/info.json"
```

## Install with server.sh (recommended)

`server.sh` is a single script that starts, stops and updates your server. It runs the server in a `screen` session named after the server folder, so several servers in different folders don't get in each other's way.

Run this inside your BeamMP server folder, the one that contains `BeamMP-Server` and `ServerConfig.toml`:

```bash
curl -fsSL -o server.sh https://raw.githubusercontent.com/MrCurby/SharedCareer/main/tools/server.sh && chmod +x server.sh
```

```bash
echo 'REPO="MrCurby/SharedCareer"' > server.conf
```

```bash
./server.sh update
```

`update` downloads the newest release from GitHub, installs it and starts the server. The server console should show:

```
[SharedCareer] Version 0.8.4 loaded. Console: sc help
```

On the first start the mod creates its settings in `Resources/Server/SharedCareer/config/config.json`.

> **Already running your server in your own screen session?** Stop it there once (`screen -r <name>`, then type `exit`) and start it again with `./server.sh start`. From then on the script manages it.

## server.sh reference

| Command | What it does |
|---|---|
| `./server.sh start` | Start the server in the background |
| `./server.sh stop` | Stop it cleanly (sends `exit` to the console, forces it after 20 s) |
| `./server.sh restart` | Stop and start |
| `./server.sh status` | Is it running, and which SharedCareer version is loaded |
| `./server.sh console` | Open the live server console. Leave with **Ctrl+A, then D**. **Ctrl+C stops the server.** |
| `./server.sh logs [n]` | Show the last *n* lines of `Server.log` (default 100) |
| `./server.sh follow` | Follow `Server.log` live (Ctrl+C only stops following) |
| `./server.sh cmd "sc time"` | Send one command to the server console and show the answer |
| `./server.sh check` | Show the installed version and the newest version on GitHub |
| `./server.sh update` | Install the newest GitHub release, but only if it is newer than the installed one |
| `./server.sh update --force` | Same, even if that version is already installed |
| `./server.sh update file.zip` | Install a specific zip from the server folder |

**`server.conf`** sits next to `server.sh`:

```bash
REPO="MrCurby/SharedCareer"   # where releases come from
GITHUB_TOKEN=""               # only needed for a private repository (token with read access)
```

Without a `REPO`, `update` installs the newest `SharedCareer-*.zip` it finds in the server folder, for example one you uploaded with `scp`.

## What an update does

`./server.sh update` runs these steps, and stops at the first error so nothing is half-installed:

1. Asks GitHub for the newest release and compares it with the installed version. If it is the same, it stops here with "Already up to date".
2. Downloads the release zip and checks that it is a valid zip.
3. Stops the server.
4. Backs up the current mod **and your settings** to `sharedcareer-backup-<date>.tgz`.
5. Unpacks the release. This replaces the mod code, the client mod and `server.sh` itself, but **never touches your settings**.
6. Starts the server again and shows the SharedCareer startup lines.
7. Deletes old release zips and keeps the newest three.

After an update:

- **Players** get the new client mod automatically from BeamMP on their next join. If a player still has an old version cached, they see a dialog asking them to restart BeamNG and reconnect.
- **Settings** in `config/config.json` are kept. Values you never changed move to the new default automatically. Values you changed stay as they are. The server console lists what was changed.
- **Save game mapping** in `config/profiles.json` is kept.
- A **broken `config.json`**, for example one with a typo, is saved as `config.json.broken` instead of being overwritten.

## Manual installation and updates

A release is the file `SharedCareer-<version>.zip` from the [releases page](https://github.com/MrCurby/SharedCareer/releases). It contains:

```
server.sh                                   server control script
Resources/Client/SharedCareer.zip           client mod (BeamMP sends it to the players)
Resources/Server/SharedCareer/main.lua      server plugin
README.md
```

Settings (`Resources/Server/SharedCareer/config/`) are **not** in the zip, so unpacking over an existing installation is always safe.

1. Upload the zip from your PC:
   ```bash
   scp SharedCareer-<version>.zip <user>@<server>:<server-folder>/
   ```
2. Stop the server.
3. Optional: back up the current version together with your settings:
   ```bash
   cd <server-folder> && tar czf sharedcareer-backup-$(date +%F-%H%M).tgz Resources/Server/SharedCareer Resources/Client/SharedCareer.zip
   ```
4. Unpack:
   ```bash
   cd <server-folder> && unzip -o SharedCareer-<version>.zip
   ```
5. Start the server and look for `[SharedCareer] Version <version> loaded` in the console. When the client mod changed, BeamMP also prints `File 'Resources/Client/SharedCareer.zip' has been modified, rehashing`.

## Rolling back

Stop the server, then either install the older release:

```bash
./server.sh update SharedCareer-<old-version>.zip
```

or restore a backup made during an update:

```bash
tar xzf sharedcareer-backup-<date>.tgz
```

Then start the server. Players automatically get the matching client mod again on their next join.

## Save games

Every player has their **own career save on their own PC**. The server decides the profile name:

- **With a BeamMP account:** on the first join the server remembers the name (`config/profiles.json`, account ID → profile). Players who rename their BeamMP account keep their save.
- **As a guest:** the profile is tied to the guest name. Guests see a notice when they join.
- **The same account twice at the same time** is refused, so two games never write into the same save.
- `client.saveSuffix` is appended to the profile name, for example `_myserver` gives a separate save per server.

Saves are stored in the player's BeamNG user folder under `settings/cloud/saves/<profile>`.

## Switching from Mileage

SharedCareer and Mileage must **never run on the same server at the same time**.

1. Check whether Mileage used a save suffix:
   ```bash
   grep -i save <server-folder>/Resources/Server/Mileage/config/config.json
   ```
2. Stop the server and **move** Mileage away instead of deleting it, so you can go back:
   ```bash
   mkdir -p <server-folder>/mileage-backup && mv <server-folder>/Resources/Server/Mileage <server-folder>/Resources/Client/Mileage.zip <server-folder>/mileage-backup/
   ```
3. Install SharedCareer as described above and start the server.
4. If Mileage used a suffix (for example `_wcusa`), set the same one: `sc set client.saveSuffix _wcusa`. Otherwise leave it empty. The Mileage saves then keep working, because the profile name is built the same way.
5. Every player should back up their save folder before the first join (`<BeamNG user folder>/current/settings/cloud/saves/<name>`).
6. The red "Unknown app" boxes that Mileage leaves in the UI are removed automatically on join (`client.cleanupMileageApps`). The mod backs up the layout files first as `.sharedcareer-backup`.
