# Settings & commands

- [Chat commands](#chat-commands-players)
- [Console commands](#console-commands-server)
- [Settings](#settings-configjson)

## Chat commands (players)

| Command | What it does |
|---|---|
| `/pay <name> <amount>` | Send money to another player. Part of the name is enough, and names may contain spaces. |
| `/players` | Who is on the server, and who is still loading |
| `/schelp` | Short help |

## Console commands (server)

Type these into the server console, or send them with `./server.sh cmd "..."`.

| Command | What it does |
|---|---|
| `sc help` | List of all commands |
| `sc get` | Show all settings |
| `sc set <setting> <value>` | Change a setting, for example `sc set client.roadTraffic 4`. It is saved and sent to all players immediately. |
| `sc time` | Show the current time |
| `sc time 18:30` | Set the time for everyone |
| `sc time stop` / `sc time start` | Pause / resume the clock |
| `sc time real` | Real time: the time follows the real clock (time zone: `server.realtimeZone`). `sc time 18:30`, `stop` or `start` end it. |
| `sc fuel` | Show the current fuel discounts per station |
| `sc fuel reset` | Reset all stations to the normal price |
| `sc jobs` | Show the jobs and who took them |
| `sc jobs reset` | Drop all jobs (new ones follow) |
| `sc levels` | Show every player's job levels |
| `sc levels reset <name>` | Set a player's job levels back to level 1 (a player on the server, or a profile name) |
| `sc players` | Players and their career status |
| `sc reload` | Reload `config.json` from disk |

## Settings (`config.json`)

The file is `Resources/Server/SharedCareer/config/config.json`. It is created on the first start. Change settings with `sc set` while the server runs, or edit the file and use `sc reload`.

`server.*` settings are used by the server, and `client.*` settings are sent to every player. Many of them can also be changed by players in the [SharedCareer menu](features.md#the-sharedcareer-menu), unless you lock it.

### Save games

| Setting | Default | Meaning |
|---|---|---|
| `client.saveSuffix` | `""` | Appended to the profile name, for example `_myserver` for a separate save per server |
| `server.kickOnFailedStart` | `false` | Kick a player whose career fails to start |

### Traffic

| Setting | Default | Meaning |
|---|---|---|
| `server.roadTrafficTotal` | `20` | Driving traffic on the whole server, shared between all players (0 = no limit) |
| `server.parkedTrafficTotal` | `24` | Parked cars on the whole server |
| `client.roadTraffic` | `6` | Driving traffic per player (max 50) |
| `client.parkedTraffic` | `8` | Parked cars per player |
| `client.trafficReserve` | `4` | Extra hidden cars per player, so the menu can raise the amount live |
| `client.trafficSimpleVehicles` | `true` | Traffic as simplified vehicles (`simple_traffic`) for all players |
| `client.enableSpawnQueue` | `false` | BeamMP's spawn queue: other players' new cars wait until you slow down. Off, so their new traffic is never missing while you drive (a short stutter when many come at once) |
| `client.trafficAllowMods` | `false` | Mod vehicles in the traffic. Off, because other players without the mod don't see such a car and drive through it |
| `client.trafficAggression` | `0.2` | Traffic AI aggression, from 0.05 (careful) to 1 (aggressive). 0 = game default. Lower means more distance and earlier braking. Police are not affected. |
| `client.trafficGrip` | `0.85` | How much tire grip the traffic AI thinks it has (0.5–0.95, game default 0.95). Lower means it brakes earlier and more gently at intersections and traffic lights, and takes corners more slowly. 0 = game default. Police are not affected. |
| `client.trafficReactionGap` | `1.0` | Safety gap in seconds that the traffic AI keeps to a vehicle on its path (0.3–3, game default 0.3). Larger means it starts braking earlier behind slow or standing vehicles, without driving slower. 0 = game default. |
| `client.trafficSightRange` | `5` | How far ahead the traffic AI checks its path for vehicles: (speed in m/s + 10) × this factor, in meters (3–8, game default 3). With 5 it sees about 190 m ahead at 100 km/h instead of 114 m. 0 = game default. |
| `server.trafficSignalSync` | `true` | Same traffic light cycle for everyone |

### Time of day

| Setting | Default | Meaning |
|---|---|---|
| `server.startHour` | `10` | Time after a server start (hour, `10.5` = 10:30) |
| `server.dayMinutes` | `50` | Real minutes for the day, from `dayStartHour` to `nightStartHour` |
| `server.nightMinutes` | `5` | Real minutes for the night. If either length is 0, time stands still. |
| `server.dayStartHour` / `server.nightStartHour` | `6` / `20` | When day and night begin |
| `server.timePaused` | `false` | Clock paused. Set by Pause/Run in the menu or `sc time stop/start`. |
| `server.realtimeSync` | `false` | Real time: the time of day is the server's local time, at real speed. Start time, day/night length and pause don't apply then. Set by "Real time" in the menu or `sc time real`. |
| `server.realtimeZone` | `""` | Time zone for real time, with summer/winter time: e.g. `Europe/Berlin`, `Europe/London`, `America/New_York`, `Australia/Sydney`, or `UTC+2` (no summer time). Empty = the server's own local time – right only if the server's system has the right time zone (many servers run on UTC). An unknown name falls back to the server's local time (see the server log). |
| `client.syncTimeOfDay` | `true` | Same time of day for everyone (re-synced every 30 s) |
| `client.lockEnvironment` | `true` | Time, weather, slow motion and traffic in the pause menu are display-only |

### Players, menu and permissions

| Setting | Default | Meaning |
|---|---|---|
| `server.allowPlayerSettings` | `true` | Everybody may change traffic and options in the menu, for everyone |
| `server.allowPlayerTimeControl` | `true` | Everybody may change the time and the day/night length, for everyone (`false` = console only) |
| `server.allowTeleport` | `false` | **Go** in the Players tab: teleport your vehicle to another player |
| `client.showPlayerStatus` | `true` | Status after other players' names: `[Mission]`, `[On foot]`, `[Loading]` |
| `client.showWelcome` | `true` | Welcome dialog on join (everyone can still pick "Don't show again") |
| `client.addApps` | `true` | Add the SharedCareer menu and the phone tab to the career UI once, on the first join |
| `client.cleanupMileageApps` | `true` | For players who used the Mileage mod before: remove its apps that are left in their UI layouts (red "Unknown app" boxes) and bring back the BeamMP player list |

### Vehicles and collisions

| Setting | Default | Meaning |
|---|---|---|
| `client.remoteVehicleGhost` | `false` | Other players' cars without collision (AI traffic always collides) |
| `client.remoteUnicycleGhost` | `true` | Players on foot without collision |
| `client.simplifyRemoteVehicles` | `false` | Build other players' cars as simplified models locally (for weak PCs) |
| `client.computerAccessRange` | `6` | Use garage computers from this distance in meters (max 30, 0 = right in front, like in single player) |

### Fuel economy

| Setting | Default | Meaning |
|---|---|---|
| `server.fuelEconomy` | `true` | Shared fuel prices, and deliveries lower the price |
| `server.fuelLitersPerStep` / `server.fuelDiscountPerStep` | `1000` / `5` | 5 % cheaper per 1,000 liters delivered |
| `server.fuelMaxDiscount` | `30` | Maximum discount in % |
| `server.fuelRecoveryPercent` / `server.fuelRecoveryMinutes` | `1` / `5` | The discount drops by 1 percentage point every 5 minutes |

### Jobs (beta)

| Setting | Default | Meaning |
|---|---|---|
| `server.jobs` | `true` | Jobs (for now towing jobs) and the Jobs app on the phone |
| `server.jobsOpen` | `3` | Open jobs per level group: for beginners and for the highest level each player on the server has reached. New ones are made up as needed |
| `server.jobTimeoutMinutes` | `30` | A taken job is open again after this many minutes |
| `server.jobPayMax` | `5000` | Highest pay of one job, in $ |
| `client.jobPay` | `1` | Factor on the pay of every job (towing: $150 + $120 per km, 25 % more with a flat tire); `2` = double |

### Money

| Setting | Default | Meaning |
|---|---|---|
| `server.allowPayments` | `true` | Allow `/pay` |
| `server.paymentMax` | `1000000` | Maximum amount per transfer |
| `server.paymentCooldownSeconds` | `5` | Waiting time between two transfers of the same player |

### Game restrictions

| Setting | Default | Meaning |
|---|---|---|
| `client.allowConsole` | `false` | Allow the in-game Lua console |
| `client.allowWorldEditor` | `false` | Allow the world editor |
| `client.phone` | `true` | The phone (key F4, tab at the right screen edge) with the Jobs, Tow, Straps and Fuel apps |
| `client.allowRopes` | `true` | Ropes with physics on the phone: the Tow app (rope and winch, move your own vehicles slowly) and the Straps app (strap a car down on a truck or trailer). Before 0.22.0: `allowGrab` |
| `client.winchSpeed` | `1` | How fast the winch hauls in at most, in m/s (0.2–5). Before 0.22.0: `grabSpeed` |
| `client.winchStrength` | `150` | Highest pull strength a player may pick in the Tow app, in % of the vehicle's weight (10–150). Below 100 you can lift one end and drag or push the vehicle, but not float it. Before 0.22.0: `grabStrength` |
| `client.allowTowToRoad` | `true` | "Tow to the road" in the Tow app: puts a vehicle the rope can't free (the one you look at, or the one on the rope) on the last road it drove on, free of charge (the career's own recovery menu charges $75). The damage stays. |
| `client.allowNodeGrabber` | `true` | Node grabber (grab and pull vehicles with the mouse) also in a vehicle and in the free camera. The normal career only allows it while walking. The vehicle certification test still blocks it. `false` = the career's own rule. |

### How settings survive updates

New versions sometimes change a default. On startup the server compares your `config.json` with the defaults of the version that wrote it:

- If a value is still the **old default**, it moves to the **new default**.
- If you **changed** a value, it stays as it is.
- **Nothing is thrown away.** A setting the new version no longer uses, or a value of the wrong type, moves to `_retired` in `config.json`. If the setting was renamed, or comes back later, it gets that value again.
- The console lists every value that was changed or retired.
