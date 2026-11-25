# Development

- [Repository layout](#repository-layout)
- [Building and testing](#building-and-testing)
- [Releasing a new version](#releasing-a-new-version) (step by step: [Making a release](releasing.md))
- [How it works](#how-it-works)
- [Known limitations](#known-limitations)
- [Project status](#project-status)

**Language: English only.** Everything in this repository is English: code comments, strings, logs, UI texts, test descriptions, tool output and docs. `tests/language_check.py` runs as part of `tools/test.sh` and fails on German text, so no release is built until it is fixed.

## Repository layout

```
client/                          client mod (packed into Resources/Client/SharedCareer.zip)
  lua/ge/extensions/sharedCareer/  game-engine Lua, one file per area (see below)
  lua/vehicle/extensions/auto/     vehicle Lua (sharedCareerVeh: ghost, AI, ropes, towing jobs, damage;
                                   sharedCareerSyncGuard: BeamMP's position sync during a pause and
                                   with invalid values)
  scripts/sharedCareer/            mod entry point (loads the extensions)
  ui/modules/apps/                 the three UI apps: SharedCareer-Menu (the menu with the steering
                                   wheel), SharedCareer-Phone (phone with the Jobs, Tow, Straps
                                   and Fuel apps) and SharedCareer-SpeedLimit (the speed limit sign)
  ui/sharedCareer/icons.svg        every icon of the UI apps, in one file (see "Icons" below)
  levels/west_coast_usa/…          enlarged garage-computer zones (generated, see tools/zones)
Resources/Server/SharedCareer/   server plugin (main.lua)
tests/                           mock-based tests for client and server
tools/                           build, test, package, release and server scripts
docs/                            documentation
.github/workflows/release.yml    releases: the "Run workflow" button, and the Discord post
.github/workflows/dev-build.yml  dev builds of every branch but main (pre-releases "build-<branch>")
.github/workflows/tests.yml      checks of a pull request into main (tests, version)
stylua.toml                      Lua formatting (StyLua)
.vscode/                         VS Code: StyLua formats Lua on save; recommended extensions
```

## Building and testing

You need `luajit`, `lua5.3`, `python3`, `node` and `zip`. On Fedora: `sudo dnf install luajit lua5.3 python3 nodejs zip`. On Debian/Ubuntu: `sudo apt install luajit lua5.3 python3 nodejs zip`.

```bash
tools/test.sh      # syntax check, all tests, Lua formatting and the English-only language check
tools/build.sh     # build Resources/Client/SharedCareer.zip from client/
tools/package.sh 0.35.0  # tests + build + release package SharedCareer-0.35.0.zip
tools/package.sh --dev   # the same as a dev build, SharedCareer-<last release>-dev.<commit>.zip
tools/version.sh         # the last release's version; "patch", "minor", "major": the next one
tools/version_check.sh   # the version in the code stays "dev"; a change of tools/server.sh
                         # raises its SCRIPT_REVISION (PR check)
tools/release_notes.sh   # notes of the next release: the pull requests since the last one
tools/discord_release.sh # post a release to the Discord releases channel (release workflow)
```

The tests rebuild the BeamNG and BeamMP APIs as mocks and play through joining, career start, garage, visibility, traffic, time sync, the node grabber, rope and winch, straps, the phone, UI layout cleanup, fuel prices, payments, the menu and the welcome dialog. The menu and phone windows (`app.js`) run in node with stand-ins for AngularJS and `bngApi` (`tests/ui_mock.js`, `tests/ui_test.js`); a timeline of random clicks on them is then replayed against the real `menu.lua` (`tests/ui_replay.lua`). They check the logic, but **they don't replace testing in the real game**. UI changes were additionally checked by rendering the apps in a headless browser.

### Lua formatting

All Lua code is formatted with [StyLua](https://github.com/JohnnyMorganz/StyLua) as set in `stylua.toml` (tabs, lines up to 120 characters, double quotes). In VS Code, install the recommended "StyLua" extension: `.vscode/settings.json` makes it format a Lua file on save. Without VS Code: `stylua .` formats everything.

`tools/test.sh` checks it with `stylua --check .` when `stylua` is installed (`cargo install stylua` or `npm install -g @johnnymorganz/stylua-bin`), and skips it with a note otherwise. The pull request check always runs it, with the StyLua version pinned in `.github/workflows/tests.yml`.

StyLua puts only one space before a comment at the end of a line, so comments are not lined up in columns. To keep a hand-made layout (a table laid out as a grid, for example), put `-- stylua: ignore start` and `-- stylua: ignore end` around it.

## Branches: a branch per change, then main

- **Every change gets its own branch** (from `main`), named `<type>/<topic>`: `feat/`, `fix/`, `refactor/`, `docs/`, `ci/` or `chore/`, e.g. `fix/rope-after-reset` (see `CLAUDE.md`). Every push to a branch other than `main` runs `.github/workflows/dev-build.yml`: all tests, then `tools/package.sh --dev`, which stamps the version `<last release>-dev.<commit>` into the package (the code itself always says `"dev"`). The zip replaces the branch's GitHub pre-release `build-<branch>`. A test server installs the newest dev build with `./server.sh update --dev`, or one branch's with `./server.sh update --dev=<branch>` (see [Test server](server-setup.md#test-server-dev-builds)).
- **`main`** collects the changes for the next release. Once a change works in the game, open a pull request into `main`. `.github/workflows/tests.yml` checks it: all tests, and `tools/version_check.sh` – the version in the code stays `"dev"`.
- When a branch is deleted (after its pull request was merged), the workflow removes its dev build. Turn on "Automatically delete head branches" in the repository settings, so this happens by itself.
- Nothing is pushed to `main` directly; a ruleset for `main` (require a pull request and the checks "tests" and "version", block force pushes) makes sure of it.

## Releasing a new version

Step by step, for everyone: **[Making a release](releasing.md)**. In short: on GitHub, **Actions → Release → Run workflow**, pick patch, minor or major, run. How it works inside:

- **Version:** the code says `VERSION = "dev"` (`util.lua`, `main.lua`); the releases are the tags `v<x.y.z>`. `tools/version.sh` gives the next version after the last tag (or checks an exact one), and `tools/package.sh <version>` stamps it into the package only. Client and server versions in a package always match; players with a mismatching cached mod see a dialog.
- **The run** (`.github/workflows/release.yml`): stops with a note if `client/`, `Resources/` and `tools/server.sh` are unchanged since the last tag; otherwise runs all tests, builds `SharedCareer-<version>.zip` and creates release `v<version>` on the commit of `main`. If a test fails, nothing is released.
- **Notes:** title and text of every pull request merged into `main` since the last release (`tools/release_notes.sh`). Write every pull request text for players and server owners: `.github/pull_request_template.md` gives the sections (short bullet points), and its hints (HTML comments) are left out.
- **Discord:** the same notes are posted to the releases channel (`tools/discord_release.sh`), through the webhook in the repository secret `DISCORD_RELEASE_WEBHOOK` (Settings → Secrets and variables → Actions; the webhook comes from Edit Channel → Integrations → Webhooks). Without the secret, nothing is posted.
- **Review first:** the release is created as a draft and not posted. Publishing it by hand fires the `release: published` event; the workflow's job `discord` then posts the release's text. A release the workflow publishes itself fires no event (events of the workflow's own token start no workflows), so nothing is posted twice.
- `tests/config_update_test.lua` compares with the last release tag (`v*`); the `build-*` tags of dev builds don't count.

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
| Other players' vehicles blow up after someone pauses ("Instability detected") and wreck cars next to them | On a pause BeamMP sets the game speed to 0, and `positionVE` divides by it. The guard keeps the last real speed and skips `positionVE` while paused | `sharedCareerSyncGuard.lua` |
| BeamMP's sync pushes invalid values (NaN, infinite) into other players' vehicles; they blow up and wreck the cars next to them | Nothing of BeamMP checks the numbers. `velocityVE`'s corrections and `positionGE.setPositionRotationVelocity` (setting a car in place) drop a call with a value that is not a finite number, or for a car that is already broken | `sharedCareerSyncGuard.lua`, `instability.lua` |
| Other players' parked cars and traffic blow up ("Instability detected") and wreck the cars next to them | BeamMP sends every own car's position up to 50 times a second and holds each copy to it with forces while the last packet is younger than 0.1 s, also a parked car standing still. `positionGE.sendVehiclePosRot` drops positions of your parked cars standing still (once a second), of traffic far from every other player (twice a second) and of hidden cars (none); in between BeamMP leaves the copy to the game's physics. Like Mileage's send rate | `sendRate.lua`, `vehicles.lua` (`trafficKind`) |
| A physics glitch goes unnoticed: which cars blew up, and whose | BeamMP cleans up after a glitch itself (`onInstabilityDetected`: physics reset, which puts your car back where it was spawned, in the career the garage). SharedCareer leaves that as it is and shows one toast per glitch that hits one of your cars, naming the other players whose cars blew up in the same moment; the log lists every vehicle | `instability.lua` |
| A trailer or dolly follows the truck but hangs uncoupled on other PCs | BeamMP sends a coupling only once. Every client reports its own couplings (`sc_couplings`), and the others retry missing ones with BeamMP's `couplerVE.toggleCouplerState` until they hold | `couplings.lua`, server |
| **Duplicate cars** when tuning, changing parts or painting | BeamMP rebuilds the wrong car, so `getPlayerVehicle(0)` points at the right one for that call | `garage.lua` |
| Other players on foot are invisible | A visible BeamMP unicycle variant | `garage.lua` |
| You have to stand exactly in front of a garage computer | Enlarged computer zones on West Coast USA (generated from the original level file), plus a range boost while playing on other maps | `levels/…`, `tools/zones/`, `garage.lua` |
| Traffic costs a lot of performance on every PC | Traffic spawns as simplified vehicles, and BeamMP sends that model to everyone | `core.lua`, `traffic.lua` |
| A mission start deletes all your traffic and parked cars and spawns them again at its end. BeamMP builds other players' new cars only once you slow down (its spawn queue), so while you drive their new traffic is missing on your PC, and on its owner's PC you crash into it | On a server the cars are hidden for the mission instead (`gameplay_traffic.freezeState` / `unfreezeState` with `despawnVehicles` / `respawnVehicles` off) and shown again at its end; the visibility sync hides them for everyone | `traffic.lua`, `vehicles.lua` |
| A mod car in someone's traffic is missing for players without the mod | The server turns off mod cars in the traffic (`trafficAllowMods`) | `core.lua`, server |
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
| The career's node grabber is too weak to move heavy vehicles (engine limit) | Own ropes with physics. The vehicle Lua pulls the nodes around the grip at the physics rate (`onPhysicsStep`, `applyForceVector`): a stiff, pull-only rope with a winch motor that stalls at the pull limit and a rope that snaps on a hard jolt. A vehicle holds several ropes at once, each under the rope id the GE side gave it. `rope.lua` keeps them all, talks to the vehicles and draws them; the Tow app (`tow.lua`) and the Straps app (`straps.lua`) use it. A rope's loose end (the Tow app's anchor, a strap added by hand) is moved with one remote: `ropeRemote.lua` (moving it, where it would hook on) and the phone's `remote.html` | `rope.lua`, `ropeRemote.lua`, `tow.lua`, `sharedCareerVeh.lua` |
| Towing on the rope: the anchor on another vehicle | Nothing hooks on by itself. Your vehicles near the anchor name their tow hitches and the point where it would hook on (`anchorNear` → `onAnchorNear`: a hitch within 0.7 m, else the nearest sturdy node within 0.5 m); the Tow app shows it as a ring and offers "Hook on" (`anchorHook` → `onAnchorNode`). Then the anchor moves with that vehicle, at the speed of its node (from its movement, so turning counts), and the rope's pull goes back to it (`onRopePull` → `anchorPull`) | `rope.lua`, `tow.lua`, `sharedCareerVeh.lua` |
| A car on a trailer slides off | Straps: ropes of kind STRAP from the car to the vehicle below, pulled tight by 1.2 cm when hooked on and softer than a winch line. "Tighten" hauls them in like a very weak winch (winch 1 at 0.1 m/s, stalling at 25 % of the car's weight); a strap never pays out. A strap pulls only once it is hooked on; by hand, its end is moved with the remote (`ropeRemote.lua`). A strap's pull reaches the trailer a few frames late (through the GE side), which rocked it, with four straps more and more: for straps `rope.lua` smooths that pull and the anchor's speed, so only the steady load gets through. "Strap down" asks the car for four sturdy, low corners (`strapCorners`) and your vehicles near it for the nearest sturdy node below each (`hookBelow`). The Tow app's "Strap down" (`straps.strapOnto`) asks only the vehicle the tow rope is hooked on | `straps.lua`, `rope.lua`, `sharedCareerVeh.lua` |
| A rope must never pull a vehicle that was reset or teleported back to its old anchor, or drag a torn-off part | The vehicle drops the rope on a reset, a jump or a torn-off tie node (`onRopeLost`); the GE side also releases it after a reset and when the vehicle stops reporting | `sharedCareerVeh.lua`, `rope.lua` |
| The rope end stuttered (the vehicle reports its grip only 10 times per second) | The GE side draws the rope end from the tie node's position every frame | `rope.lua` |
| A vehicle wrapped around a lamp post can't be pulled free, and the career's "Tow to road" costs $75 | "To the road" in the Tow app uses the game's own `spawn.teleportToLastRoad`, free, while the vehicle stands still and isn't chased by the police | `tow.lua` |
| One place for SharedCareer apps | The phone with an app registry (`phone.registerApp`); the UI app is only a tab at the screen edge | `phone.lua`, `ui/…/SharedCareer-Phone` |
| Sending money to other players | `/pay` as a two-step transfer with refund | `money.lua`, server |
| Jobs for everyone | The server keeps one job list and asks a client to make up each job. What all jobs share (taking, giving up, the route, the Jobs app, levels, a pay that arrives exactly once, also after a crash or reconnect: `config/payouts.json`, `sc_jobPaid` / `sc_jobPaidAck`) is in `jobs.lua`; each kind of job is a job type, see [Job types](#job-types) | `jobs.lua`, server, `ui/…/SharedCareer-Phone` |
| Job levels per player, but one job list for everyone | The server keeps every player's XP per job type (`config/progress.json`) and decides: which tiers you can take, your pay, the XP. It keeps tier 1 and every online player's highest tier stocked. See [Job levels](#job-levels) | server, `jobs.lua` |
| Towing jobs (a job type) | A roadside spot (only a side with nothing in the way and ground at the road's height, so never inside a tunnel wall), an old car and a repair shop; the taker spawns the broken-down car (`jobBreakDown`), new damage lowers the pay. A crash: the car is spawned in the air, tilted (nose, tail, side, corner or roof first), and falls at the crash's speed, so the game's physics wrecks it (spawned with `safeSpawn = false`: the game's safe spawn would turn it onto its wheels and put it on the ground); it breaks down once it lies still. Faults use the game's own damage: engines `disable()`, gearboxes `onBreak()`, a friction clutch's `damageLockTorqueCoef`, the engine thermals' `applyDeformGroupDamageRadiator` / `applyDeformGroupDamageOilpan` (leaks), glass and lights through their deform groups | `towJobs.lua`, `sharedCareerVeh.lua` |
| The speed limit of the road you drive on | `speedLimit.limitAt(pos)`: the nearest road (`map.findClosestRoad`) and its link's `speedLimit` (m/s), nil off the road. The UI app SharedCareer-SpeedLimit shows it as a sign, in km/h or mph by the game's `uiUnitLength`, rounded to 5; taxi jobs use the same limit for speeding | `speedLimit.lua`, `ui/…/SharedCareer-SpeedLimit` |
| Calls on the phone | `phone.ring(def)`: the phone comes out with the call (Accept / Decline) for 15 s; `onAnswer(accepted, missed)`, `hangUp(id)`; "Accept" opens the app and page the call names. Taxi jobs ring for the nearest ride while you are on duty (`taxiJobs.lua`, "Calls"), with pauses after a call and off duty after two missed calls | `phone.lua`, `taxiJobs.lua`, `ui/…/SharedCareer-Phone` |
| Taxi jobs (a job type) | A passenger at a roadside spot (a marker, no vehicle is spawned) and a facility of the map as the place to go. Stopping next to them in a vehicle (not the unicycle) makes it the taxi. A smooth ride: a jolt is the taxi's speed changing faster than 7 m/s² between two checks (hard braking, a crash, a hard landing); speeding is more than 15 % over the road's speed limit (`map.findClosestRoad`, the link's `speedLimit`) for 2 s; jolts, speeding, new damage (`map.objects[id].damage`) and a reset lower the pay and the passenger's stars; 4 or 5 stars earn a tip (`sc_jobDone {tip}`, paid with the payout) | `taxiJobs.lua` |

### Job types

The Jobs app knows nothing about towing or taxis: `jobs.lua` is the core, and each kind of job is a job type in a file of its own. `taxiJobs.lua` is the short example to follow, `towJobs.lua` the big one. A new job type is:

1. **A file** `client/lua/ge/extensions/sharedCareer/<name>Jobs.lua`, loaded in `modScript.lua` after `jobs`. In `onExtensionLoaded` it calls `sharedCareer_jobs.registerType(M)`.
2. **What it brings** (the list is at the top of `jobs.lua`): `id`, `name` (its section in the Jobs app, and "<name> job" in the money history), `icon`, `steps`, optionally `branch` (the career branch whose XP it also gives) and `deduction` (what the pay held back is for in the pay's toast, default "damage"), and the functions `generate(tier)`, `tags`, `start`, `step`, `status`, `stop`, optionally `iconOf`, `draw`, `vehicleReset` and `isOnDuty` / `setOnDuty` (an "On duty" switch on its page; taxi: calls). Don't use the game's hook names (`onUpdate`, `onVehicleResetted`, …) for them: the game calls those on every extension.
3. **Making one up:** `jobs.lua` has the helpers both job types use: `randomRoadside()` (a place beside a normal road, never inside a tunnel wall), `farFromVehicles(pos, m)`, `facilityPlaces(kinds)` (the map's garages, gas stations, …), `pickDestination(places, from, min, max)` and `roadLength(a, b)`; for the markers in `draw`: `drawMarker(pos, color)` and `drawDropOff(pos, radius, name, waitLeft)`.
4. **Its own fields** go into `job.data` (at most 2 KB as JSON). The server checks only what every job has (`type`, `title`, `pos`, `dest`, `length`, `pay`) and passes `data` on.
5. **When the job is done**, `step` calls `jobs.handOver(a, share, tip)`: how much of the pay was earned (0..1, less after damage, for example) and optionally a tip on top (a share of the pay, at most 25 %; taxi: by the passenger's stars). The server turns it into the player's pay and XP (from the share, not the tip) and pays it once. While the job runs, `status` may give `share` (the pay as it is now) and `stars` (a rating, 1..5): the Jobs app shows them live.
6. **Tiers:** `generate(tier)` makes a job of tier 1 (easy) to 4 (hard). A harder tier should be harder to do and pay more (`pay` is the pay at level 1). Levels, unlocking, the level bonus and the XP come from the core and the server. Every job type levels on its own, by the same rules unless it needs others (see [Job levels](#job-levels)).
7. **An icon** in the Jobs app: `icon` names an icon of `icons.svg` (see [Icons](#icons)); a new one goes there. A name that isn't there is shown as text. Optionally `iconOf(job)` gives a job an icon of its own (towing jobs: the kind of vehicle – `car`, `suv`, `pickup`, `van`, `bus`, `truck`, kept in `job.data.kind`); `nil` falls back to `icon`.
8. **Its card** on the Jobs app's start page comes by itself as soon as Lua sends the job type. Its look (the livery colors and band) is `.scp-jobtype-<id>` in the phone's `app.css`; without one it is blue.
9. **A license** (optional): an entry with its `jobType` in `LICENSES` in the server's `main.lua`; the server then refuses its jobs to players without it.

The server needs no other change for a new job type: each client tells it its job types (`sc_jobsRequest {types}`), the server asks only those clients for jobs of a type, and keeps levels per job type from then on. A client that doesn't know a job's type (an older mod version) lists it but doesn't start it. `server.jobsOpen` counts per job type.

### Job levels

The server is the referee for levels (`main.lua`, "Job levels"): the job list is shared, so who may take which job can't come from a client. A client's save keeps only a copy to show (`career/sharedCareerJobLevels.json`, written with the career).

Every job type levels on its own: towing level 8 doesn't help in a new job type, which starts at level 1. The rules are `LEVEL_RULES`, the same for every job type. A job type that needs other rules (other tiers, faster levels) gets an entry in `LEVEL_RULES_BY_TYPE` with only the values that differ, for example `delivery = {tierLevel = {1, 4, 7}, tierXp = {50, 90, 140}}`; taxi jobs have `taxi = {bonus = 0.03}` (a smaller level bonus: a ride is easier than a tow, and a smooth one earns a tip). They stay on the server, so a client can't change them.

- **progress.json:** per profile and job type `{xp, level, stats = {done, givenUp, earned, deducted, bestTier}, history}` (the last 20 jobs). The level follows from the XP: `xpBase × (level − 1)^1.5` XP for a level (xpBase 100), at most `maxLevel` (10).
- **Tiers:** tier t from level `tierLevel[t]` = 1, 3, 5, 8. A job of a higher tier is listed with `locked = true` and `sc_jobTake` refuses it; a tier a job type doesn't have is refused in `sc_jobOffer`.
- **Pay:** the job's pay (at level 1) + `bonus` (5 %) per level above 1, worked out per player in `sc_jobs` and at the payout.
- **XP:** `tierXp[tier]` (40, 70, 110, 160) × the share earned; `lowTierXp` (half) for a job two or more tiers below the player's highest. Every job in the list carries the XP it gives that player (`xp`, like `pay`), so the Jobs app shows them under the pay. The payout carries the XP; the client adds it to the career's BeamXP and the job type's branch, if the career has them.
- **The Jobs app** opens on a start page with a card per job type (open jobs, your level); a card opens that job type's page: your level in it (a ring), and its jobs in groups by the level they need: yours first, the locked ones at the bottom. The back button in the app bar leads back to the start page.
- **Enough jobs for everyone:** `wantedTiers` lists, per job type a client online has, tier 1 and the highest tier of every player online; the emptiest one is asked for next (`sc_jobGenerate {type, tier}`, every 5 s while one is missing, from a client that has the type), up to `server.jobsOpen` each. A job type and tier that got no job after it was asked for (no place for it on this map) waits 30 s, so the others don't wait for it.

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

### Icons

Every icon of the UI apps is in **one file**, `client/ui/sharedCareer/icons.svg`: a `<symbol id="sc-icon-<name>">` per icon, in a 24×24 box, drawn in `currentColor` (so it takes the color of the text around it). Both apps load it into their page (`ng-include` at the top of their `app.html`; each brings its own copy, so either works alone).

- **Use one:** `<svg><use href="#sc-icon-car"/></svg>`, by a name from Lua: `<use ng-attr-href="{{ '#sc-icon-' + j.icon }}"/>`. The size comes from the CSS of the place it is in (e.g. `.scp-ic svg`).
- **Icon or text:** the phone's `hasIcon(name)` tells whether `icons.svg` has an icon of that name; an app that registered a letter (`icon = "T"`) shows the letter.
- **Add one:** a new `<symbol>` in `icons.svg`, in its group. Never draw an icon inline in `app.html`.
- `tests/ui_test.js` checks it: every name the apps and Lua use is in `icons.svg`, and no icon is drawn inline.

The icons in `docs/icons/` are only for the README and docs on GitHub.

### Regenerating the garage zones

The mod ships a modified copy of a West Coast USA level file (`career_garage/garage_interactions/items.level.json`, only the 4 computer zones and their icons). If BeamNG changes that file in an update, regenerate it: put the new original into `tools/zones/garage_interactions.original.json`, then run `python3 tools/zones/make_garage_zones.py` and `tools/package.sh`.

## Known limitations

- The game interfaces the mod hooks into (`career_career`, `core_vehicles`, BeamMP's `MPVehicleGE`, …) come from BeamNG 0.39/0.40. If BeamNG changes them, the mod needs an update. Errors show up in `beamng.log` under `sharedCareer.*`.
- BeamMP itself only syncs parts that break off, so how a crashed car is bent can look different on each PC. Per-part paint, races and drag strips are not part of SharedCareer.
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
