<div align="center">

<img src="docs/images/logo.svg" width="200" alt="Career-Convoy logo">

# Career-Convoy

**Play the BeamNG.drive career together on a BeamMP server.**

One shared world (same traffic, same time of day, same traffic lights), while every player keeps their **own save** on their own PC. Plus optional extras for playing together.

[![Latest release](https://img.shields.io/github/v/release/MrCurby/SharedCareer?label=release)](https://github.com/MrCurby/SharedCareer/releases/latest)
[![Build](https://github.com/MrCurby/SharedCareer/actions/workflows/release.yml/badge.svg)](https://github.com/MrCurby/SharedCareer/actions/workflows/release.yml)
![BeamNG.drive 0.39+](https://img.shields.io/badge/BeamNG.drive-0.39%2B-orange)
![BeamMP](https://img.shields.io/badge/BeamMP-server%20mod-blue)

[Features](#features) · [Quick start](#quick-start) · [Server setup](docs/server-setup.md) · [In-game guide](docs/features.md) · [Settings & commands](docs/configuration.md) · [Report a bug](#help-and-bug-reports)

</div>

---

## What is Career-Convoy?

The BeamNG career is made for playing alone. If you try it on a multiplayer server, lots of things go wrong: loading your career deletes your friends' cars, everyone has a different time of day, your traffic shows up with your name on it, and so on.

**Career-Convoy fixes all of that.** It's a small mod for BeamMP servers that lets you play the normal BeamNG career together with your friends:

- Join the server and your career **starts by itself**. No menus, nothing to set up.
- Play the career like you always do: buy cars, do deliveries and missions, use your garage.
- Everyone drives in the **same world**, and the mod keeps it the same for everyone.
- **Your progress stays yours**: your money, cars and missions are saved on your own PC, just like in single player.

**Made for small groups of friends.** Career-Convoy is built for a few friends who just want to hang out on a BeamMP server and enjoy the career together, without stress and without things breaking. It's not made for big public servers.

**How it's built.** At its heart, Career-Convoy is the normal BeamNG career, made to work with more than one player. Those fixes always run. On top of that come **extras for playing together**, like shared fuel prices, finding your friends or a rope and winch to move vehicles that can't drive. Each extra is listed separately below and can be switched off by the server.

Players **don't need to install anything**. BeamMP downloads the mod for them when they join.

## Features

### Fixes: making the career work with friends

Without these, the career breaks or behaves strangely on a multiplayer server.

| | What it does | Can be turned off? |
|---|---|---|
| <img src="docs/icons/save.svg" width="20" height="20" alt=""> **Career starts on join, own save** | Your career loads by itself when you join. Each player has their own save, tied to their BeamMP account, so renaming your account keeps your save. | No (core of the mod) |
| <img src="docs/icons/shield.svg" width="20" height="20" alt=""> **Safe career start** | Loading your career no longer deletes your friends' cars, and the garage no longer creates duplicate cars. | No |
| <img src="docs/icons/traffic-light.svg" width="20" height="20" alt=""> **Same world for everyone** | Same time of day and same traffic light cycle for everyone. Cars that the career or the traffic hides or shows are hidden or shown for everyone too, so nobody drives through a car only the other one sees. | Time and traffic lights: yes |
| <img src="docs/icons/car.svg" width="20" height="20" alt=""> **Cars look the same for everyone** | Trailers and dollies stay coupled for everyone. Your traffic doesn't appear on top of other players, and other players' cars no longer blow up when someone opens a menu. | No |
| <img src="docs/icons/car.svg" width="20" height="20" alt=""> **Traffic that doesn't overload the server** | The server splits a total traffic limit across all players, and traffic uses simplified cars that are cheap to sync. Your traffic no longer carries your name tag. | Limit and simple cars: yes |
| <img src="docs/icons/fuel.svg" width="20" height="20" alt=""> **Same fuel price for everyone** | Normally every player rolls their own random price at the same station. With Career-Convoy everyone pays the same. | Yes (together with the fuel extra below) |

### Extras: more things to do together

These go beyond the normal career. They are on by default unless noted, and each one can be switched off.

| | What it does | Can be turned off? |
|---|---|---|
| <img src="docs/icons/day-night.svg" width="20" height="20" alt=""> **Long days, short nights** | Default: 50 min day, 5 min night, instead of the game's own day length. Anyone can pause the clock, jump to a time or switch on real time. | Yes, lengths are adjustable, or each player keeps their own time |
| <img src="docs/icons/car.svg" width="20" height="20" alt=""> **More careful traffic AI** | The AI notices slow or standing vehicles earlier (for example your truck while you maneuver), keeps more distance and brakes earlier at intersections and traffic lights. It doesn't drive slower. The police are not affected. | Yes (back to the game's AI) |
| <img src="docs/icons/sliders.svg" width="20" height="20" alt=""> **Career-Convoy menu** | An in-game window (key **F7**) for time, traffic, options and players. Every change applies to everyone. | Changing things can be limited to the server console |
| <img src="docs/icons/users.svg" width="20" height="20" alt=""> **Find your friends** | Navigate to a player or watch them, and see what others are doing on their name tags (*Mission*, *On foot*, *Loading*). Teleporting to a player is **off** by default. | Name tag status and teleport: yes |
| <img src="docs/icons/fuel.svg" width="20" height="20" alt=""> **Cheaper fuel through deliveries** | Deliver gasoline or diesel to a station and it gets cheaper there for everyone for a while. The **Fuel** app on the phone shows the cheapest station. | Yes |
| <img src="docs/icons/monitor.svg" width="20" height="20" alt=""> **Garage computers from a distance** | Use the garage computer from anywhere in the room instead of standing right in front of it. | On other maps: yes. On West Coast USA it comes from a map file in the mod, so it's always on |
| <img src="docs/icons/grab.svg" width="20" height="20" alt=""> **Node grabber everywhere** | Grab and pull vehicles with the mouse also from a vehicle or the free camera, not only while walking. It stays as weak as in the career, so it's for nudging cars, not throwing them. | Yes (back to the career's rule) |
| <img src="docs/icons/grab.svg" width="20" height="20" alt=""> **Rope, winch and straps** | Move vehicles that can't drive: drag them out of a ditch, pull them onto a tow truck or tow them behind another car, all in the **Tow** app on the phone. Then strap the car down on the truck or trailer with the **Straps** app. A car stuck on a lamp post can be put back on the road for free. Your own vehicles only. | Yes |
| <img src="docs/icons/phone.svg" width="20" height="20" alt=""> **Phone** | A phone in the game (key **F4**, or the tab at the right screen edge) with the server time and the number of players, and four apps: **Jobs** (towing jobs, beta), **Tow** (rope and winch as a remote control), **Straps** (strap a car down on a trailer) and **Fuel** (gas station prices). | Yes |
| <img src="docs/icons/car.svg" width="20" height="20" alt=""> **Towing jobs** *(beta)* | Broken-down cars at the roadside, one list for everyone in the **Jobs** app: take a job, drive there, tow the car to a repair shop and get paid. New damage on the way costs part of the pay. Your level grows with every job and opens harder, better-paid ones. | Yes |
| <img src="docs/icons/money.svg" width="20" height="20" alt=""> **Send money** | `/pay <name> <amount>` in chat, with an automatic refund if something goes wrong. | Yes |
| <img src="docs/icons/message.svg" width="20" height="20" alt=""> **Welcome dialog** | A short overview when you join. Each player can pick "Don't show again". | Yes |

How to switch things off: [Settings & commands](docs/configuration.md).

### Good to know: what the mod changes on your PC

The mod only runs while you are on a Career-Convoy server (BeamMP only loads it there). While it runs:

- **Console and world editor are locked**, and time, weather and traffic in the pause menu are display-only. This keeps the shared world the same for everyone. The server can allow both.
- **Two game settings are set by the server** (simplified traffic cars, optionally simplified cars of other players). Your own values come back when you leave.
- **Your UI layout gets the Career-Convoy menu and the phone tab**, once. If you remove them, they don't come back.
- **If you played on a server with the Mileage mod before**, its apps are still in your UI layout and show up as red "Unknown app" boxes once Mileage is gone. Career-Convoy removes those boxes, after a backup of the layout file.
- **On West Coast USA, the garage computer zones are bigger** (the mod ships a changed copy of that map file).

These changes stay after you leave:

- **Your save** is a normal career save in your BeamNG user folder, named after your BeamMP account.
- **Your UI layout** keeps the two Career-Convoy apps (you can remove them). If old Mileage boxes were removed, they stay removed.
- **A small file** `settings/sharedCareer/state.json` remembers choices like "Don't show again".

For server owners: settings move to new defaults automatically on updates, and `./server.sh update` installs the newest release. See [Server setup](docs/server-setup.md).

## Screenshots

**The Career-Convoy menu**: time of day, traffic, options and players. It collapses into a small steering-wheel tab at the right screen edge.

![Career-Convoy menu with the Time, Traffic, Options and Players tabs](docs/images/menu.png)

<table>
<tr>
<td width="50%" valign="top">

**Welcome dialog** on join

![Welcome dialog](docs/images/welcome.png)

</td>
<td width="25%" valign="top">

**Tow** app: rope and winch

<img src="docs/images/phone-tow.png" alt="Tow app on the phone">

</td>
<td width="25%" valign="top">

**Fuel** app: cheapest station

<img src="docs/images/phone-fuel.png" alt="Fuel app on the phone">

</td>
</tr>
</table>

## Quick start

### For players

1. Join a server that runs Career-Convoy.
2. Wait for the career to load. You land in the world in your own career save.
3. Open the menu with the **steering-wheel tab** at the right screen edge, or press **F7**.

That's it. Your save lives in your normal BeamNG user folder under a profile named after your BeamMP account.

### For server owners

Requirements: a BeamMP server on Linux, BeamNG.drive 0.39 or newer. West Coast USA is the recommended map.

```bash
# 1. In your BeamMP server folder: get the control script
curl -fsSL -o server.sh https://raw.githubusercontent.com/MrCurby/SharedCareer/main/tools/server.sh && chmod +x server.sh

# 2. Tell it where releases come from
echo 'REPO="MrCurby/SharedCareer"' > server.conf

# 3. Install the newest release and start the server
./server.sh update
```

Then set `MaxCars = 100` in `ServerConfig.toml`, because traffic counts as the player's cars. Later updates are again just `./server.sh update`.

The full guide, including manual installation, backups, rollback and switching from Mileage, is in **[docs/server-setup.md](docs/server-setup.md)**.

## Documentation

| Guide | Contents |
|---|---|
| [Server setup](docs/server-setup.md) | Installation, `server.sh`, updates, rollback, save games, switching from Mileage |
| [In-game guide](docs/features.md) | The menu, welcome dialog, players tab, fuel economy, traffic, what everyone sees the same, garage computers, rope and winch, straps, towing jobs, phone |
| [Settings & commands](docs/configuration.md) | Chat and console commands, every setting in `config.json` |
| [Development](docs/development.md) | Building, tests, releases, how the mod works inside, known limitations, project status |
| [Making a release](docs/releasing.md) | For maintainers: a new release in one click on GitHub, with your own version or text |

## Status and known limits

Career-Convoy is under active development and was tested with **BeamNG.drive 0.40.5**, **BeamMP 4.23.1** and **BeamMP-Server 3.9.3** on Linux. Joining, the career start, traffic, buying cars, the shared time of day and the garage computers have been tested with real players.

Good to know before you play:

- **West Coast USA** is the map Career-Convoy is made for. Other maps work, with smaller garage-computer zones.
- **A crashed car takes its driver's shape on your screen once it stands still for a moment.** While it drives on, it can look a bit different for you.
- **Missions run per player.** Others don't see your mission props and cones.
- **Money lives in your own save.** The server only checks money transfers.
- **A BeamNG or BeamMP update can break things** until Career-Convoy is updated. The log then names what is missing.

More details: [Known limitations](docs/development.md#known-limitations).

## Help and bug reports

Search the [existing issues](https://github.com/MrCurby/SharedCareer/issues) first, then [open a new one](https://github.com/MrCurby/SharedCareer/issues/new). Please include:

- The Career-Convoy version (`beamng.log` shows it as `SharedCareer <version> loaded`) and your BeamNG.drive and BeamMP versions
- What you did, what you expected and what happened, ideally with a screenshot
- Whether it happened to one player or to everyone
- The Career-Convoy lines from `beamng.log` of the affected session. The game overwrites this file on the next start, so copy it before you restart.

Where to find `beamng.log`:

| System | File |
|---|---|
| Windows | `%LOCALAPPDATA%\BeamNG\BeamNG.drive\current\beamng.log` |
| Linux | `~/.local/share/BeamNG/BeamNG.drive/current/beamng.log` |

On Linux this prints the relevant lines:

```bash
grep -E "sharedCareer|Instability|FATAL" ~/.local/share/BeamNG/BeamNG.drive/current/beamng.log | tail -50
```

Logs can contain your user name and folder paths. Check them before you post.

## Credits

Career-Convoy is a community mod and is not affiliated with BeamNG GmbH or the BeamMP team.
