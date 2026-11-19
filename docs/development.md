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
  lua/vehicle/extensions/auto/     vehicle Lua (sharedCareerVeh: ghost, AI, ropes, towing jobs, damage;
                                   sharedCareerPauseGuard: BeamMP's position sync during a pause)
  scripts/sharedCareer/            mod entry point (loads the extensions)
  ui/modules/apps/                 the two UI apps: SharedCareer-Menu (the menu with the steering
                                   wheel) and SharedCareer-Phone (phone with the Jobs, Tow, Straps
                                   and Fuel apps)
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

The tests rebuild the BeamNG and BeamMP APIs as mocks and play through joining, career start, garage, visibility, traffic, time sync, the node grabber, rope and winch, straps, the phone, UI layout cleanup, fuel prices, payments, the menu and the welcome dialog. The menu and phone windows (`app.js`) run in node with stand-ins for AngularJS and `bngApi` (`tests/ui_mock.js`, `tests/ui_test.js`); a timeline of random clicks on them is then replayed against the real `menu.lua` (`tests/ui_replay.lua`). They check the logic, but **they don't replace testing in the real game**. UI changes were additionally checked by rendering the apps in a headless browser.

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

One line per problem. Each file starts with a comment that explains the details.

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
| Other players' vehicles blow up after someone pauses ("Instability detected") and wreck cars next to them | On a pause BeamMP sets the game speed to 0, and `positionVE` divides by it. The guard keeps the last real speed and skips `positionVE` while paused | `sharedCareerPauseGuard.lua` |
| A trailer or dolly follows the truck but hangs uncoupled on other PCs | BeamMP sends a coupling only once. Every client reports its own couplings (`sc_couplings`), and the others retry missing ones with BeamMP's `couplerVE.toggleCouplerState` until they hold | `couplings.lua`, server |
| Every PC works out the deformation itself (BeamMP only syncs parts that break off), so a crash seen on one PC only looks different everywhere | The owner sends its damage once a crash is over (`sc_damage`). The others load it like `beamstate.load` (reset, node positions, beams, `commitLoad`) while their copy stands still. Player vehicles only | `damage.lua`, `sharedCareerVeh.lua`, server |
| **Duplicate cars** when tuning, changing parts or painting | BeamMP rebuilds the wrong car, so `getPlayerVehicle(0)` points at the right one for that call | `garage.lua` |
| Other players on foot are invisible | A visible BeamMP unicycle variant | `garage.lua` |
| You have to stand exactly in front of a garage computer | Enlarged computer zones on West Coast USA (generated from the original level file), plus a range boost while playing on other maps | `levels/…`, `tools/zones/`, `garage.lua` |
| Traffic costs a lot of performance on every PC | Traffic spawns as simplified vehicles, and BeamMP sends that model to everyone | `core.lua`, `traffic.lua` |
| Too much traffic with many players | The server splits a total limit across all players | `traffic.lua`, server |
| Traffic AI drives too close and rams players | Lower aggression and grip estimate, larger safety gap and sight range (set inside `ai.lua` through upvalues, no game files edited). Police excluded | `traffic.lua`, `sharedCareerVeh.lua` |
| Everybody has a different time of day | The server runs the clock, and the pause-menu environment controls are locked | `env.lua`, server |
| Different traffic light cycles | The server syncs the signal timer | `core.lua`, server |
| Finding friends on the map | Players tab: navigate, watch, optional teleport, status on name tags | `players.lua` |
| Fuel prices differ per player, and deliveries have no effect on the world | Shared base prices, deliveries lower prices for everyone | `fuel.lua`, server |
| Settings can only be changed in the console | The SharedCareer menu syncs every change to all players | `ui/…/SharedCareer-Menu`, `menu.lua`, `env.lua` (time) |
| New players don't know the features | Welcome dialog with "Don't show again" | `welcome.lua` |
| Red "Unknown app" boxes after switching from Mileage | Mileage apps are removed from the players' layouts, with a backup first | `cleanup.lua` |
| The career blocks the node grabber in a vehicle and in the free camera | After every input filter change (hook `onActionFilterUpdated`) only the career's group `careerNodeGrabberActions` is lifted; other blocks (certification test) stay | `nodegrab.lua` |
| The career's node grabber is too weak to move heavy vehicles (engine limit) | Own ropes with physics. The vehicle Lua pulls the nodes around the grip at the physics rate (`onPhysicsStep`, `applyForceVector`): a stiff, pull-only rope with a winch motor that stalls at the pull limit and a rope that snaps on a hard jolt. A vehicle holds several ropes at once, each under the rope id the GE side gave it. `rope.lua` keeps them all, talks to the vehicles and draws them; the Tow app (`tow.lua`) and the Straps app (`straps.lua`) use it | `rope.lua`, `tow.lua`, `sharedCareerVeh.lua` |
| Towing on the rope: the anchor on another vehicle | Nothing hooks on by itself. Your vehicles near the anchor name their tow hitches and the point where it would hook on (`anchorNear` → `onAnchorNear`: a hitch within 0.7 m, else the nearest sturdy node within 0.5 m); the Tow app shows it as a ring and offers "Hook on" (`anchorHook` → `onAnchorNode`). Then the anchor moves with that vehicle, at the speed of its node (from its movement, so turning counts), and the rope's pull goes back to it (`onRopePull` → `anchorPull`) | `rope.lua`, `tow.lua`, `sharedCareerVeh.lua` |
| A car on a trailer slides off | Straps: ropes of kind STRAP from the car to the vehicle below, without a winch, pulled tight by 1.2 cm when hooked on and softer than a winch line. "Strap down" asks the car for four sturdy, low corners (`strapCorners`) and your vehicles near it for the nearest sturdy node below each (`hookBelow`) | `straps.lua`, `rope.lua`, `sharedCareerVeh.lua` |
| A rope must never pull a vehicle that was reset or teleported back to its old anchor, or drag a torn-off part | The vehicle drops the rope on a reset, a jump or a torn-off tie node (`onRopeLost`); the GE side also releases it after a reset and when the vehicle stops reporting | `sharedCareerVeh.lua`, `rope.lua` |
| The rope end stuttered (the vehicle reports its grip only 10 times per second) | The GE side draws the rope end from the tie node's position every frame | `rope.lua` |
| A vehicle wrapped around a lamp post can't be pulled free, and the career's "Tow to road" costs $75 | "To the road" in the Tow app uses the game's own `spawn.teleportToLastRoad`, free, while the vehicle stands still and isn't chased by the police | `tow.lua` |
| One place for SharedCareer apps | The phone with an app registry (`phone.registerApp`); the UI app is only a tab at the screen edge | `phone.lua`, `ui/…/SharedCareer-Phone` |
| Sending money to other players | `/pay` as a two-step transfer with refund | `money.lua`, server |
| Jobs (beta) for everyone | The server keeps one job list and asks a client to make up each job. What all jobs share (taking, giving up, the route, the Jobs app, a pay that arrives exactly once, also after a crash or reconnect: `config/payouts.json`, `sc_jobPaid` / `sc_jobPaidAck`) is in `jobs.lua`; each kind of job is a job type, see [Job types](#job-types) | `jobs.lua`, server, `ui/…/SharedCareer-Phone` |
| Towing jobs (the first job type) | A roadside spot, an old car and a repair shop; the taker spawns the broken-down car (`jobBreakDown`), new damage lowers the pay | `towJobs.lua`, `sharedCareerVeh.lua` |

### Job types

The Jobs app knows nothing about towing: `jobs.lua` is the core, and each kind of job is a job type in a file of its own. `towJobs.lua` is the first one and the example to follow. A new job type is:

1. **A file** `client/lua/ge/extensions/sharedCareer/<name>Jobs.lua`, loaded in `modScript.lua` after `jobs`. In `onExtensionLoaded` it calls `sharedCareer_jobs.registerType(M)`.
2. **What it brings** (the list is at the top of `jobs.lua`): `id`, `name` (for the money history), `icon`, `steps`, and the functions `generate`, `tags`, `start`, `step`, `status`, `stop`, optionally `draw` and `vehicleReset`. Don't use the game's hook names (`onUpdate`, `onVehicleResetted`, …) for them: the game calls those on every extension.
3. **Its own fields** go into `job.data` (at most 2 KB as JSON). The server checks only what every job has (`type`, `title`, `pos`, `dest`, `length`, `pay`) and passes `data` on.
4. **When the job is done**, `step` calls `jobs.handOver(a, pay, deduction)`. The core sends it to the server, which pays it once (at most `server.jobPayMax`).
5. **An icon** in the Jobs app: the job card shows the SVG for `icon` in `app.html` (`scp-job-icon`); without one it shows `icon` as text.

The server needs no change for a new job type. A client that doesn't know a job's type (an older mod version) lists it but doesn't start it. Making up jobs, the job types take turns; `server.jobsOpen` counts all of them.

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
- BeamMP itself only syncs parts that break off; SharedCareer syncs the deformation of player vehicles (`damage.lua`) once a crash is over and the car stands still on the other PCs, so while it drives on after a crash it can look different there. Traffic and parked cars keep the damage each PC works out itself. Per-part paint, races and drag strips are not part of SharedCareer.
- Coupling sync (`couplings.lua`) uses BeamMP's own coupling and leaves couplings that involve one of your own vehicles to your physics.
- Missions run per player. Others don't see your mission props and cones.
- Money lives in the local save. Someone who edits their save can cheat. The server only checks transfers.

## Project status

At its core, SharedCareer brings the **normal BeamNG career** to multiplayer: everything the career can do should work stably on a server. On top of that come extras for playing together (see [Features](../README.md#features)), each of which the server can switch off.

Tested with BeamNG.drive 0.40.5, BeamMP 4.23.1 and BeamMP-Server 3.9.3 (Linux).

**Stability goals**

- Every game function the mod touches is checked on start. If one is missing after a BeamNG update, the log names it and the rest keeps running.
- Clean re-join after a lost connection.
- <img src="icons/status-done.svg" width="16" height="16" alt="tested"> Save safety: one profile per account, the same account never twice at once.
