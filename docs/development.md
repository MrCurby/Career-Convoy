# Development

- [Repository layout](#repository-layout)
- [Building and testing](#building-and-testing)
- [Releasing a new version](#releasing-a-new-version)
- [How it works](#how-it-works)
- [Known limitations](#known-limitations)
- [Project status](#project-status)

**Language: English only.** Everything in this repository is English: code comments, strings, logs, UI texts, test descriptions, tool output and docs. `tests/language_check.py` runs as part of `tools/test.sh` and fails on German text, so no release is built until it is fixed.

## Repository layout

```
client/                          client mod (packed into Resources/Client/SharedCareer.zip)
  lua/ge/extensions/sharedCareer/  game-engine Lua, one file per area (see below)
  lua/vehicle/extensions/auto/     vehicle Lua
  scripts/sharedCareer/            mod entry point (loads the extensions)
  ui/modules/apps/                 the two UI apps: SharedCareer-Time (menu), SharedCareer-Fuel
  levels/west_coast_usa/…          enlarged garage-computer zones (generated, see tools/zones)
Resources/Server/SharedCareer/   server plugin (main.lua)
tests/                           mock-based tests for client and server
tools/                           build, test, package, release and server scripts
docs/                            documentation
.github/workflows/release.yml    automatic releases
```

## Building and testing

You need `luajit`, `lua5.3`, `python3` and `zip`. On Fedora: `sudo dnf install luajit lua5.3 python3 zip`. On Debian/Ubuntu: `sudo apt install luajit lua5.3 python3 zip`.

```bash
tools/test.sh      # syntax check, all tests and the English-only language check
tools/build.sh     # build Resources/Client/SharedCareer.zip from client/
tools/package.sh   # tests + build + release package SharedCareer-<version>.zip
```

The tests rebuild the BeamNG and BeamMP APIs as mocks and play through joining, career start, garage, visibility, traffic, time sync, fuel prices, payments, the menu and the welcome dialog. They check the logic, but **they don't replace testing in the real game**. UI changes were additionally checked by rendering the apps in a headless browser.

## Releasing a new version

Releases are built by GitHub Actions. On every push to `main` the workflow runs all tests and builds the package. If no release exists for that version yet, it creates release `v<version>` with the zip attached.

```bash
tools/bump.sh patch      # 0.8.4 -> 0.8.5 (bug fixes)
tools/bump.sh minor      # 0.8.4 -> 0.9.0 (new features)
tools/bump.sh 1.0.0      # set a version directly
```

`bump.sh` sets the version in both places (`client/lua/ge/extensions/sharedCareer/util.lua` and `Resources/Server/SharedCareer/main.lua`) and runs the tests. Then:

```bash
git commit -am "SharedCareer 0.8.5" && git push
```

About a minute later the release is on GitHub, and `./server.sh update` installs it on a server.

- A push **without** a new version only builds and tests. No release is created.
- If a test fails, no release is created and servers stay on the old version.
- Client and server versions must match. `package.sh` refuses to build otherwise, and players with a mismatching cached mod see a dialog.

**Changing a default:** just change it in `DEFAULTS` in `main.lua`. Existing servers pick up the new default automatically, unless someone changed that value (see [How settings survive updates](configuration.md#how-settings-survive-updates)).

## How it works

### What the mod fixes, and where

| Problem with the career in multiplayer | Solution | File |
|---|---|---|
| Starting the career **deletes all other players' cars** | During `activateCareer`, `removeAll` and the "safe list" skip remote vehicles | `protect.lua` |
| One broken career module blocks all others (for example insurance) | Every `onCareerActive` handler runs inside `xpcall` during the start | `protect.lua` |
| The career has to start automatically on join | The server sends settings; the client starts the profile in *Open World* mode | `core.lua` |
| Joining hangs forever in a loading screen | Hanging loading screens are released after 60 s and the result is reported to the server | `core.lua` |
| BeamNG 0.40 sometimes lands in the main menu after joining | After the career start the mod switches back to the driving screen once | `welcome.lua` |
| The career hides and shows cars (garage, dealer), but others don't see it | Visibility is synced through the server | `vehicles.lua` |
| Your name tag above every one of your traffic cars | Traffic and parked cars are marked and their name tags hidden | `vehicles.lua` |
| Your police or traffic "takes over" other players | Remote cars get `ignoreTraffic` | `vehicles.lua` |
| **Duplicate cars** when tuning, changing parts or painting | BeamMP rebuilds the wrong car, so `getPlayerVehicle(0)` points at the right one for that call | `garage.lua` |
| Other players on foot are invisible | A visible BeamMP unicycle variant | `garage.lua` |
| You have to stand exactly in front of a garage computer | Enlarged computer zones on West Coast USA (generated from the original level file), plus a range boost while playing on other maps | `levels/…`, `tools/zones/`, `garage.lua` |
| Traffic costs a lot of performance on every PC | Traffic spawns as simplified vehicles, and BeamMP sends that model to everyone | `core.lua`, `traffic.lua` |
| Too much traffic with many players | The server splits a total limit across all players | `traffic.lua`, server |
| Traffic AI drives too close and rams players | Lower AI aggression and grip estimate; larger safety gap and sight range, set inside ai.lua through upvalues (no game files edited); police excluded | `traffic.lua`, `sharedCareerVeh.lua` |
| Everybody has a different time of day | The server runs the clock, and the pause-menu environment controls are locked | `env.lua`, server |
| Different traffic light cycles | The server syncs the signal timer | `core.lua`, server |
| Finding friends on the map | Players tab: navigate, watch, optional teleport, status on name tags, F7 | `players.lua` |
| Fuel prices differ per player, and deliveries have no effect on the world | Shared base prices, deliveries lower prices for everyone | `fuel.lua`, server |
| Settings can only be changed in the console | The SharedCareer menu syncs every change to all players | `ui/…/SharedCareer-Time`, `env.lua`, `menu.lua` |
| New players don't know the features | Welcome dialog with "Don't show again" | `welcome.lua` |
| Red "Unknown app" boxes after switching from Mileage | Mileage apps are removed from the players' layouts, with a backup first | `cleanup.lua` |
| The career blocks the node grabber in a vehicle and in the free camera | After every input filter change (hook `onActionFilterUpdated`) only the career's group `careerNodeGrabberActions` is lifted; other blocks (certification test) stay | `nodegrab.lua` |
| The career's node grabber is too weak to move heavy vehicles (engine limit) | Own grabber: `cameraMouseRayCast` picks the vehicle, then every frame `applyClusterVelocityScaleAdd` (like the game's fling) pulls the whole vehicle towards the mouse ray | `grab.lua` |
| Sending money to other players | `/pay` as a two-step transfer with refund | `money.lua`, server |

### Join flow

```
Client                                    Server
  map loaded ── sc_hello ──────────────────▶
             ◀── sc_config + sc_vehStates ── (settings, traffic share)
  start career (protected)
  ── sc_careerResult {ok} ─────────────────▶
  hidden cars / traffic ── sc_vehActive / sc_vehMarks ─▶ to all other players
```

### Money transfer

```
/pay Ben 500 ─▶ server checks ─▶ Anna: sc_payDebit ─▶ Anna checks money, debits, saves
                                ◀── sc_payDebitResult ──
                server ─▶ Ben: sc_payCredit ─▶ Ben credits ─▶ sc_payCreditAck
                (Ben gone or no confirmation within 30 s ─▶ refund to Anna)
```

### UI apps

The menu and the fuel app are AngularJS apps (`ui/modules/apps/…`). Lua pushes state via `guihooks.trigger`, and the apps call back with `bngApi.engineLua`. Two details matter in BeamNG:

- **App frames catch clicks over their whole area**, even where they look transparent. The two apps therefore must never overlap. The fuel app sits below the menu.
- Dialogs are attached to the page body, not to the app frame, so the frame can't clip them. Only the dialog card takes clicks.

### Regenerating the garage zones

The mod ships a modified copy of a West Coast USA level file (`career_garage/garage_interactions/items.level.json`, only the 4 computer zones and their icons). If BeamNG changes that file in an update, regenerate it: put the new original into `tools/zones/garage_interactions.original.json`, then run `python3 tools/zones/make_garage_zones.py` and `tools/package.sh`.

## Known limitations

- The game interfaces the mod hooks into (`career_career`, `core_vehicles`, BeamMP's `MPVehicleGE`, …) come from BeamNG 0.39/0.40. If BeamNG changes them, the mod needs an update. Errors show up in `beamng.log` under `sharedCareer.*`.
- Damage is synced by BeamMP itself. Per-part paint, races and drag strips are not part of SharedCareer.
- Missions run per player. Others don't see your mission props and cones.
- Money lives in the local save. Someone who edits their save can cheat. The server only checks transfers.

## Project status

SharedCareer brings the **normal BeamNG career** to multiplayer, nothing more and nothing less: no new game modes, but everything the career can do should work stably on a server.

Tested with BeamNG.drive 0.40.5, BeamMP 4.23.1 and BeamMP-Server 3.9.3 (Linux).

| Career feature | Status |
|---|---|
| Join, career start, own save | <img src="icons/status-done.svg" width="16" height="16" alt="tested"> tested |
| Other players' cars survive the career start | <img src="icons/status-done.svg" width="16" height="16" alt="tested"> tested (2 instances) |
| Vehicle and damage sync | <img src="icons/status-done.svg" width="16" height="16" alt="tested"> tested (BeamMP) |
| Traffic (drives, simple vehicles, more careful AI) | <img src="icons/status-done.svg" width="16" height="16" alt="tested"> tested |
| Buying cars | <img src="icons/status-done.svg" width="16" height="16" alt="tested"> tested |
| Shared time of day | <img src="icons/status-done.svg" width="16" height="16" alt="tested"> tested |
| Garage computers from a distance | <img src="icons/status-done.svg" width="16" height="16" alt="tested"> tested |
| Welcome dialog | <img src="icons/status-done.svg" width="16" height="16" alt="tested"> tested |
| SharedCareer menu: live traffic, options | <img src="icons/status-open.svg" width="16" height="16" alt="open"> open |
| Shared fuel prices, deliveries lower prices | <img src="icons/status-open.svg" width="16" height="16" alt="open"> open |
| Garage: parts, tuning, painting (no duplicates) | <img src="icons/status-open.svg" width="16" height="16" alt="open"> open |
| Garage: storing/retrieving cars, visibility for others | <img src="icons/status-open.svg" width="16" height="16" alt="open"> open |
| Saving, leaving, re-joining | <img src="icons/status-open.svg" width="16" height="16" alt="open"> open |
| Deliveries (parcels, cargo, vehicles) | <img src="icons/status-open.svg" width="16" height="16" alt="open"> open |
| Missions and challenges | <img src="icons/status-open.svg" width="16" height="16" alt="open"> open |
| Police, chases, fines, speed cameras | <img src="icons/status-open.svg" width="16" height="16" alt="open"> open |
| Insurance, repair, towing | <img src="icons/status-open.svg" width="16" height="16" alt="open"> open |
| Refueling / charging | <img src="icons/status-open.svg" width="16" height="16" alt="open"> open |
| Used car dealers, private sales | <img src="icons/status-open.svg" width="16" height="16" alt="open"> open |
| Changing maps within a save | <img src="icons/status-open.svg" width="16" height="16" alt="open"> open |
| 3+ players at the same time | <img src="icons/status-open.svg" width="16" height="16" alt="open"> open |
| `/pay` between two players | <img src="icons/status-open.svg" width="16" height="16" alt="open"> open |

**Stability goals**

- Every game function the mod touches is checked on start. If one is missing after a BeamNG update, the log names it and the rest keeps running.
- Clean re-join after a lost connection.
- <img src="icons/status-done.svg" width="16" height="16" alt="tested"> Save safety: one profile per account, the same account never twice at once.

**Maybe later**

- Traffic AI briefly reverses when stuck in tight spots.
