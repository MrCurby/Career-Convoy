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
  ui/modules/apps/                 the two UI apps: SharedCareer-Menu (the menu with the steering
                                   wheel) and SharedCareer-Phone (phone with the Tow and Fuel apps)
  levels/west_coast_usa/…          enlarged garage-computer zones (generated, see tools/zones)
Resources/Server/SharedCareer/   server plugin (main.lua)
tests/                           mock-based tests for client and server
tools/                           build, test, package, release and server scripts
docs/                            documentation
.github/workflows/release.yml    automatic releases
.github/workflows/dev-build.yml  dev builds of every branch but main (pre-releases "build-<branch>")
.github/workflows/tests.yml      checks of a pull request into main (tests, version)
```

## Building and testing

You need `luajit`, `lua5.3`, `python3`, `node` and `zip`. On Fedora: `sudo dnf install luajit lua5.3 python3 nodejs zip`. On Debian/Ubuntu: `sudo apt install luajit lua5.3 python3 nodejs zip`.

```bash
tools/test.sh      # syntax check, all tests and the English-only language check
tools/build.sh     # build Resources/Client/SharedCareer.zip from client/
tools/package.sh   # tests + build + release package SharedCareer-<version>.zip
tools/package.sh --dev   # the same as a dev build, SharedCareer-<version>-dev.<commit>.zip
tools/version_check.sh   # a branch that changes the mod must raise the version, one that changes
                         # tools/server.sh its SCRIPT_REVISION (PR check)
```

The tests rebuild the BeamNG and BeamMP APIs as mocks and play through joining, career start, garage, visibility, traffic, time sync, the node grabber, rope and winch, the phone, UI layout cleanup, fuel prices, payments, the menu and the welcome dialog. The menu and phone windows (`app.js`) run in node with stand-ins for AngularJS and `bngApi` (`tests/ui_mock.js`, `tests/ui_test.js`); a timeline of random clicks on them is then replayed against the real `menu.lua` (`tests/ui_replay.lua`). They check the logic, but **they don't replace testing in the real game**. UI changes were additionally checked by rendering the apps in a headless browser.

## Branches: a branch per change, then main

- **Every change gets its own branch** (from `main`), named `<type>/<topic>`: `feat/`, `fix/`, `refactor/`, `docs/`, `ci/` or `chore/`, e.g. `fix/rope-after-reset` (see `CLAUDE.md`). Every push to a branch other than `main` runs `.github/workflows/dev-build.yml`: all tests, then `tools/package.sh --dev`, which stamps the version as `<version>-dev.<commit>` only inside the package (the files in the repository keep their version). The zip replaces the branch's GitHub pre-release `build-<branch>`. A test server installs the newest dev build with `./server.sh update --dev`, or one branch's with `./server.sh update --dev=<branch>` (see [Test server](server-setup.md#test-server-dev-builds)). No version bump is needed for this.
- **`main`** is what players get. Once a change works in the game, raise the version (below) in its branch and open a pull request into `main`. `.github/workflows/tests.yml` checks it: all tests, and `tools/version_check.sh` – a pull request that changes the mod (`client/`, `Resources/`) must raise the version, so merging always builds a release. Changes of tools, tests or docs only need no new version.
- When a branch is deleted (after its pull request was merged), the workflow removes its dev build. Turn on "Automatically delete head branches" in the repository settings, so this happens by itself.
- Nothing is pushed to `main` directly; a ruleset for `main` (require a pull request and the checks "tests" and "version", block force pushes) makes sure of it.

## Releasing a new version

Releases are built by GitHub Actions (`.github/workflows/release.yml`). On every push to `main` the workflow runs all tests and builds the package. If no release exists for that version yet, it creates release `v<version>` with the zip attached.

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
- `tests/config_update_test.lua` compares with the last release tag (`v*`); the `build-*` tags of dev builds don't count.
- Client and server versions must match. `package.sh` refuses to build otherwise, and players with a mismatching cached mod see a dialog.

**Changing a default:** just change it in `DEFAULTS` in `main.lua`. Existing servers pick up the new default automatically, unless someone changed that value (see [How settings survive updates](configuration.md#how-settings-survive-updates)).

**Renaming or removing a setting:** add it to `RENAMED` (new name → old name) or `REMOVED` in `main.lua`. Servers keep the old value under `_retired` either way, and a rename takes it from there. `tests/config_update_test.lua` compares `DEFAULTS` with the last release (git tag) and fails if a setting is gone without an entry or changed its type, so this can't be forgotten.

## How it works

### What the mod fixes, and where

| Problem with the career in multiplayer | Solution | File |
|---|---|---|
| Starting the career **deletes all other players' cars** | During `activateCareer`, `removeAll` and the "safe list" skip remote vehicles | `protect.lua` |
| One broken career module blocks all others (for example insurance) | Every `onCareerActive` handler runs inside `xpcall` during the start | `protect.lua` |
| The career has to start automatically on join | The server sends settings; the client starts the profile in *Open World* mode | `core.lua` |
| Joining hangs forever in a loading screen | Hanging loading screens are released after 60 s and the result is reported to the server | `core.lua` |
| BeamNG 0.40 sometimes lands in the main menu after joining | After the career start the mod switches back to the driving screen once | `welcome.lua` |
| The career hides and shows cars (garage, dealer, hidden traffic reserve), but others don't see it | Every client reports its own cars' visibility every second (also cars hidden before BeamMP gave them a server id); the server sends the changes to everyone | `vehicles.lua` |
| Your name tag above every one of your traffic cars | Traffic and parked cars are marked and their name tags hidden | `vehicles.lua` |
| Your police or traffic "takes over" other players | Remote cars get `ignoreTraffic` | `vehicles.lua` |
| Your traffic and parked cars appear on top of other players, or vanish right next to them | Other players' own vehicles (not their traffic) get the game's `trafficClearRadius` (40 m): traffic spawn points, traffic respawns and parking spots keep that distance | `vehicles.lua` |
| Every PC works out the deformation itself (BeamMP only syncs parts that break off): a car that hits something only one PC sees looks crashed there only | The owner's damage counts, for player vehicles only: once its damage hasn't changed for 1.5 s, an own vehicle sends its node positions (in its own frame), deformed beams and broken beams (`sharedCareerVeh.damageSnapshot`, `sc_damage`). The others load it the way the game loads a saved vehicle (`beamstate.load`), and only while their copy stands still: reset in place, node positions turned into the copy's frame, rest lengths, deformation, broken beams, `commitLoad` (`damageLoad`). Changing the beams of a moving car made its physics blow up. A copy that crashed only on one PC asks the owner (`sc_damageRequest`). The server keeps the latest damage per vehicle for players who join later and tells everyone to forget it when the vehicle is rebuilt or its id is used again | `damage.lua`, `sharedCareerVeh.lua`, server |
| **Duplicate cars** when tuning, changing parts or painting | BeamMP rebuilds the wrong car, so `getPlayerVehicle(0)` points at the right one for that call | `garage.lua` |
| Other players on foot are invisible | A visible BeamMP unicycle variant | `garage.lua` |
| You have to stand exactly in front of a garage computer | Enlarged computer zones on West Coast USA (generated from the original level file), plus a range boost while playing on other maps | `levels/…`, `tools/zones/`, `garage.lua` |
| Traffic costs a lot of performance on every PC | Traffic spawns as simplified vehicles, and BeamMP sends that model to everyone | `core.lua`, `traffic.lua` |
| Too much traffic with many players | The server splits a total limit across all players | `traffic.lua`, server |
| Traffic AI drives too close and rams players | Lower AI aggression and grip estimate; larger safety gap and sight range, set inside ai.lua through upvalues (no game files edited); police excluded | `traffic.lua`, `sharedCareerVeh.lua` |
| Everybody has a different time of day | The server runs the clock, and the pause-menu environment controls are locked | `env.lua`, server |
| Different traffic light cycles | The server syncs the signal timer | `core.lua`, server |
| Finding friends on the map | Players tab: navigate, watch, optional teleport, status on name tags | `players.lua` |
| Fuel prices differ per player, and deliveries have no effect on the world | Shared base prices, deliveries lower prices for everyone | `fuel.lua`, server |
| Settings can only be changed in the console | The SharedCareer menu syncs every change to all players | `ui/…/SharedCareer-Menu`, `menu.lua`, `env.lua` (time) |
| New players don't know the features | Welcome dialog with "Don't show again" | `welcome.lua` |
| Red "Unknown app" boxes after switching from Mileage | Mileage apps are removed from the players' layouts, with a backup first | `cleanup.lua` |
| The career blocks the node grabber in a vehicle and in the free camera | After every input filter change (hook `onActionFilterUpdated`) only the career's group `careerNodeGrabberActions` is lifted; other blocks (certification test) stay | `nodegrab.lua` |
| The career's node grabber is too weak to move heavy vehicles (engine limit) | Own rope and winch, run from the Tow app: the GE side picks the vehicle along the view line (or the nearest own vehicle), places the anchor and sends the rope state; the vehicle Lua pulls the nodes around the grip at the physics rate (`onPhysicsStep`, switched on with the game's `enablePhysicsStepHook`; `applyForceVector`): a stiff, damped, pull-only rope tied to the node aimed at (0.5 % stretch under the vehicle's weight), a winch motor that slows down under load and stalls at the pull limit, a drum that is locked when stopped (holds like a tow rope), a rope that snaps at 4× the vehicle's weight; the force is split by node mass. Without the hook the same runs once per frame in `updateGFX` (`applyForceVectorTime`, softer for stability) | `grab.lua`, `sharedCareerVeh.lua` |
| Towing on the rope: the anchor on another vehicle (its tow hitch) | The anchor hooks on by itself: five times per second the GE side asks your vehicles near the anchor `anchorNear(x, y, z, canSnap)`; each reports its tow hitches near it (`onAnchorTargets`, drawn as rings) and takes the rope within 0.7 m of a hitch (a coupler node tagged hitch, fifth wheel or gooseneck) or 0.3 m of any node (`onAnchorNode`); it hooks on only while no remote button is held (it hooks on when let go), and after "Detach" not until the anchor was moved once; holding an arrow for 0.6 s while hooked on pops it off (not while the anchor vehicle drives faster than 1 m/s); the GE side sends that node's position and the vehicle's speed to the roped vehicle every frame, which moves the anchor on at that speed between messages and damps on the speed between both vehicles; the rope's pull comes back every frame (`onRopePull`) and goes on to the anchor vehicle (`anchorPull`, applied at the physics rate, spread over the nodes around the hitch, dropped after 0.25 s without news) | `grab.lua`, `sharedCareerVeh.lua` |
| A rope must never pull a vehicle that was reset or teleported back to its old anchor, or drag a torn-off part | The vehicle drops the rope on `onReset`, on a jump its speed doesn't explain, and when the tie node moves 2 m from the reference node, and reports `onHandLost(id, reason)`; the GE side also releases on `onVehicleResetted` and after 2 s of game time without a report (watchdog; a paused game doesn't count) | `sharedCareerVeh.lua`, `grab.lua` |
| The rope end stuttered: the vehicle reports its grip only 10 times per second | The vehicle reports the tie node's cid in `onGrip`; the GE side draws the rope end from `veh:getPosition() + veh:getNodePosition(cid)` every frame, and falls back to the last report if that is missing or implausible | `grab.lua` |
| A vehicle wrapped around a lamp post can't be pulled free, and the career's "Tow to road" costs $75 | "Tow to the road" in the Tow app calls the game's own `spawn.teleportToLastRoad(veh, {resetVehicle = false})` for the vehicle on the rope or, without a rope, the one in the middle of the view, free; only when it stands still and isn't chased by the police | `grab.lua` |
| One place for SharedCareer apps | The phone: `phone.lua` keeps an app registry (`registerApp({id, title, icon, color, order, beta, onOpen, onClose})`; `beta` shows a BETA badge), the UI app `SharedCareer-Phone` is only a tab at the edge and attaches the phone to the page body when opened | `phone.lua`, `ui/…/SharedCareer-Phone` |
| Sending money to other players | `/pay` as a two-step transfer with refund | `money.lua`, server |
| Towing jobs (beta) for everyone | The server keeps one job list and asks one client at a time to make up a job (it knows the map: a roadside spot from the road network, an old car from the career's delivery filter, a garage as repair shop). The taker spawns the car within 400 m (so the rope works on it), `sharedCareerVeh.jobBreakDown` disables its engines and sets neutral, parking brake off, hazard lights and an optional flat tire; at the drop-off the new damage (`beamstate.damage`) lowers the pay; the server pays once: it keeps the pay in `config/payouts.json` and sends it (`sc_jobPaid`) until the client has credited it, saved the career and confirmed it (`sc_jobPaidAck`), also after a crash or reconnect; the client credits each payout only once | `jobs.lua`, `sharedCareerVeh.lua`, server, `ui/…/SharedCareer-Phone` |

### Join flow

```
Client                                    Server
  map loaded ── sc_hello ──────────────────▶
             ◀── sc_config + sc_vehStates ── (settings, traffic share)
  start career (protected)
  ── sc_careerResult {ok} ─────────────────▶
  own cars: visible, traffic ── sc_vehReport (every second) ─▶ to all other players
```

### Money transfer

```
/pay Ben 500 ─▶ server checks ─▶ Anna: sc_payDebit ─▶ Anna checks money, debits, saves
                                ◀── sc_payDebitResult ──
                server ─▶ Ben: sc_payCredit ─▶ Ben credits ─▶ sc_payCreditAck
                (Ben gone or no confirmation within 30 s ─▶ refund to Anna)
```

### UI apps

The menu and the phone are AngularJS apps (`ui/modules/apps/…`). Lua pushes state via `guihooks.trigger`, and the apps call back with `bngApi.engineLua`. Two details matter in BeamNG:

- **App frames catch clicks over their whole area**, even where they look transparent. The apps therefore must never overlap. The phone's frame is only its tab, directly below the menu.
- Dialogs and the phone are attached to the page body, not to the app frame, so the frame can't clip them. Only the dialog card / the phone take clicks.
- **State only while someone looks.** `menu.lua` builds and sends `SharedCareerState` only while the menu is expanded, the phone is out or the Fuel app is open (the fuel prices only for the Fuel app). The windows report this with `sharedCareer_menu.uiVisible(view, on)` on every change and every 2 s; a view counts as visible for 5 s after its last report, so a lost report fixes itself. A view that appears gets the state at once. The prices at the pumps and on the signs don't depend on it (`fuel.lua` sets them itself).

### Regenerating the garage zones

The mod ships a modified copy of a West Coast USA level file (`career_garage/garage_interactions/items.level.json`, only the 4 computer zones and their icons). If BeamNG changes that file in an update, regenerate it: put the new original into `tools/zones/garage_interactions.original.json`, then run `python3 tools/zones/make_garage_zones.py` and `tools/package.sh`.

## Known limitations

- The game interfaces the mod hooks into (`career_career`, `core_vehicles`, BeamMP's `MPVehicleGE`, …) come from BeamNG 0.39/0.40. If BeamNG changes them, the mod needs an update. Errors show up in `beamng.log` under `sharedCareer.*`.
- BeamMP itself only syncs parts that break off; SharedCareer syncs the deformation of player vehicles (`damage.lua`) once a crash is over and the car stands still on the other PCs, so while it drives on after a crash it can look different there. Per-part paint, races and drag strips are not part of SharedCareer.
- Missions run per player. Others don't see your mission props and cones.
- Money lives in the local save. Someone who edits their save can cheat. The server only checks transfers.

## Project status

At its core, SharedCareer brings the **normal BeamNG career** to multiplayer: everything the career can do should work stably on a server. On top of that come extras for playing together (see [Features](../README.md#features)), each of which the server can switch off.

Tested with BeamNG.drive 0.40.5, BeamMP 4.23.1 and BeamMP-Server 3.9.3 (Linux).

**Stability goals**

- Every game function the mod touches is checked on start. If one is missing after a BeamNG update, the log names it and the rest keeps running.
- Clean re-join after a lost connection.
- <img src="icons/status-done.svg" width="16" height="16" alt="tested"> Save safety: one profile per account, the same account never twice at once.
