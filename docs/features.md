# In-game guide

Everything players see and use in the game. All texts in the game are in English.

- [Joining](#joining)
- [The Career-Convoy menu](#the-career-convoy-menu)
- [Welcome dialog](#welcome-dialog)
- [Finding other players](#finding-other-players)
- [Shared fuel prices](#shared-fuel-prices)
- [Traffic](#traffic)
- [Everyone sees the same cars](#everyone-sees-the-same-cars)
- [Time of day](#time-of-day)
- [Garage](#garage)
- [Node grabber](#node-grabber)
- [Moving your vehicles by hand (rope and winch)](#moving-your-vehicles-by-hand-rope-and-winch)
- [Strapping a car down (straps)](#strapping-a-car-down-straps)
- [Towing jobs](#towing-jobs)
- [Taxi jobs](#taxi-jobs)
- [Speed limit sign](#speed-limit-sign)
- [Phone](#phone)
- [Sending money](#sending-money)

## Joining

When you join, the map loads and your career **starts on its own**. It opens your own save, or creates one in *Open World* mode on your first visit. Other players' cars are protected while your career loads. Without Career-Convoy the game would delete them.

Important messages appear as a notification or a dialog in the game, not only in the chat. This includes career loaded, career start failed, version mismatch and money transfers. If the career doesn't load within 60 seconds, the loading screen is released and the server is told what happened, so you never get stuck in a loading screen.

## The Career-Convoy menu

![Career-Convoy menu: Time, Traffic, Options and Players tabs](images/menu.png)

One window for everything you can change in the game. **Every change applies to all players at once**, and everybody sees a short notification about who changed what. If several players have the menu open, all of them see the new values immediately.

- The menu is added to your career UI automatically on your first join, at the right edge below the BeamMP player list.
- The **steering-wheel tab** at the right screen edge opens and closes it. **F7** does the same.
- To use another key, open *Options → Controls → BeamMP*, entry "Career-Convoy: show/hide menu".
- The window remembers whether it is open and which tab you used last.
- If you removed it, you can add it again: UI app menu → *Add app* → category **BeamMP** → **Career-Convoy Menu**.

### Time tab

- The current time, day or night, and how long until the switch
- **−1 h / +1 h**, or jump to **Morning** (7:00), **Noon** (12:00), **Evening** (19:00) or **Night** (23:00)
- Length of the day and the night: − and + go through round values (1, 5, 10, 15 … 60 min, then bigger steps up to 10 h); changes are sent once you stop clicking
- **Clock**: one choice of three, for everyone
  - **Run**: the clock runs at the day and night length above
  - **Pause**: the clock stops at the current time; *Run* lets it go on from there
  - **Real time**: the time follows the real clock, with summer and winter time (time zone: `server.realtimeZone`, otherwise the server's local time). The other time buttons are hidden then. *Run* or *Pause* go on from the real time.

### Traffic tab

- A small table: **driving** and **parked** cars **per player** and the **server max** (∞ = no limit), changed live
- **AI style**: *Careful*, *Normal* or *Fast*
- Below: how many cars you get right now (the server max is shared between all players). "rejoin for more" shows when you would get more than the cars loaded at your join.

### Options tab

- **Collision with other players' cars**, on or off. AI traffic and parked cars **always** collide, no matter who spawned them.
- **Collision with players on foot**. Off by default, so nobody runs over a friend by accident.
- **Synced traffic lights**, on or off
- **Player status on name tags**, on or off

### Players tab

See [Finding other players](#finding-other-players).

### Who may change settings

By default everybody may. A server admin can lock settings with `sc set server.allowPlayerSettings false` (traffic and options) or `sc set server.allowPlayerTimeControl false` (time). The menu then only shows the values. To keep the server calm, each player can change a setting at most every half second, and the time at most once a second. Fast clicks are combined into one change.

## Welcome dialog

![Welcome dialog](images/welcome.png)

A few seconds after your career has loaded, a card in the middle of the screen lists the most important features.

- **Got it** closes it. It comes back on your next join.
- **Don't show again** hides it on this PC for good. The choice is stored in `settings/careerConvoy/state.json` in your BeamNG user folder.
- Click the **steering-wheel logo** in the menu to see it again at any time.
- Server admins can switch it off for everyone with `sc set client.showWelcome false`.

Messages from the server, such as the guest notice, a version mismatch or a failed career start, use the same card.

## Finding other players

The **Players** tab lists everyone on the server with what they are doing right now:

| Button | What it does |
|---|---|
| **Navigate** | Shows a route on the road to that player. It follows them when they drive on. **Stop** ends it, and so does a new route (a towing job, a gas station). |
| **Watch** | Moves your camera to that player. **Back to my car** brings you back. Your traffic stays around your own car while you watch. |
| **Go** | Teleports your current vehicle to that player. This is only available if the server allows it (`sc set server.allowTeleport true`), because in a career it skips driving and fuel costs. |

**Name tags** show what others are doing: `[Mission]`, `[On foot]` or `[Loading]`. You can switch this off in the Options tab.

**Riding along** is built into BeamMP: get into another player's car to become the passenger, and press `C` for the passenger camera.

## Shared fuel prices

A small shared economy that makes delivery jobs matter for everyone:

- **Everybody pays the same price at a station.** Normally the game rolls a random price per player when the map loads. Career-Convoy uses the map's base price without the random part.
- **Deliver gasoline or diesel to a station** with a tanker delivery job, and **that fuel gets cheaper at that station for everyone**: by default 5 % per 1,000 liters, up to 30 %.
- **The discount slowly wears off**, by default 1 percentage point every 5 minutes. A station only stays cheap if people keep delivering.
- The **price signs at the road** show the current price.
- Everybody gets a notification, for example *"Ben delivered 2000 l of diesel to Apex – diesel there is now 10% cheaper"*.
- Discounts are saved on the server and survive a restart.
- Your insurance fuel discount still applies on top.

### Fuel app on the phone

<img src="images/phone-fuel.png" width="240" alt="Fuel app on the phone">

Open the phone (**F4**) and tap **Fuel**:

- All stations of the map with gasoline (**G**) and diesel (**D**) prices, in the map's unit. On West Coast USA that is per gallon, like the signs.
- **Sort** by gasoline or diesel price, cheapest first and highlighted in green, or by distance (**Nearest**).
- A green *−10 %* means that fuel is currently cheaper there because of deliveries.
- Distance to you, and **Go** to set a route to the station. **Stop** ends it. The station's position is the middle of its pumps. The route is the game's own navigation on the map's road network.
- The prices are exactly what you pay at the pump, before your insurance discount.

## Traffic

- Traffic spawns as **simplified vehicles** (`simple_traffic`). They look a bit plainer, but cost much less to sync between all players.
- The **AI drives more carefully** than in single player. These settings do that, and police are not affected by any of them:
  - lower *aggression* (`client.trafficAggression`): more distance to the car ahead, earlier braking behind it
  - a lower *grip estimate* (`client.trafficGrip`): the AI thinks its tires grip less, so it brakes earlier and more gently at intersections and traffic lights and takes corners more slowly
  - a larger *safety gap* (`client.trafficReactionGap`) and a longer *sight range* (`client.trafficSightRange`): the AI notices a slow or standing vehicle on its path earlier and starts braking sooner, which helps when you maneuver a truck on the road. Traffic doesn't drive any slower.
- The server has a **total limit** for driving and parked traffic and splits it across all players, so more players don't mean more lag.
- Other players' cars are never treated as your traffic, so your police won't chase them and your traffic won't take them over.
- Your traffic doesn't show your name tag.

**Changing the amount live:** when you join, you spawn your traffic plus a small hidden **reserve** (default 4 cars). The menu shows or hides cars from that pool, the same way the game does for missions.

- **Lowering** the amount always works immediately.
- **Raising** it works immediately up to the cars loaded at your join. Anything above that applies on your next join ("rejoin for more" in the menu).

Spawning new cars in the middle of the game would make BeamMP build them on every PC at once, which causes stutter. That is why the mod uses a reserve instead.

## Everyone sees the same cars

In BeamMP every car belongs to one player: only that player's PC really drives it, and everyone else sees a copy. Career-Convoy keeps those copies true to the original:

- **Hidden and shown cars:** the game keeps swapping traffic cars in and out, and the career hides cars in the garage. Every player reports what is hidden every second, so nobody bumps into a car only they can see.
- **Spawning:** your traffic and parked cars keep about 40 m away from other players, so they don't appear on top of them or vanish right next to them.
- **Trailers and dollies** stay coupled for everyone, also for players who join later.
- **Pausing:** opening a menu, the big map or a garage computer pauses your game. Other players' cars no longer blow up because of that.
- **Physics glitches:** a car can suddenly blow up ("Instability detected"), often with a loud bang. Career-Convoy blocks broken sync data from other players that causes this. If one of your cars blows up anyway, BeamMP puts it back (in the career: in the garage), and a short message says so and names the other players whose cars blew up at the same moment.
- **Calmer sync of parked cars and traffic:** your parked cars send their position only once a second while they stand still, and traffic far from other players twice a second. Other players' games then let them simply stand instead of pushing them into place all the time, which made cars blow up.

## Time of day

The server runs one clock for everybody. By default a day lasts **50 real minutes** (6:00–20:00) and a night **5 minutes** (20:00–6:00). Every client re-syncs every 30 seconds. With **Real time** on, the game shows the real time instead (in the time zone the server sets). Time, weather, slow motion and traffic in the pause menu are display-only, so nobody changes the world for themselves by accident.

## Garage

- **Use garage computers from a distance.** On West Coast USA the computer zones are enlarged to about 14 × 12 m, roughly the whole room, instead of about 2 × 1.4 m right in front of the screen. On other maps the computers get a smaller boost while you play (`client.computerAccessRange`, default 6 m).
- **No duplicate cars** when you change parts, tune or paint at the garage computer.
- Cars that the career hides or shows (garage, dealership) are hidden and shown for everyone else too.
- Players on foot appear as a visible character for others.

## Node grabber

The normal career only lets you use the node grabber (grab and pull vehicles with the mouse) while walking. On a Career-Convoy server you can also use it in a vehicle and in the free camera, for example to put a flipped car back on its wheels or to help a friend out of a ditch. The vehicle certification test still blocks it, so test results stay fair.

Server admins can switch back to the career's rule with `sc set client.allowNodeGrabber false`. It applies immediately.

**The pull is weaker than in freeroam.** BeamNG limits the grab force in the career inside the game engine; the single-player career is just as weak. A mod can't change that, so in the career the node grabber is good for nudging and turning cars, but not for throwing them around. For heavier work, use Career-Convoy's rope and winch in the Tow app, see below.

## Moving your vehicles by hand (rope and winch)

The game's node grabber is too weak in the career to move a heavy car, so Career-Convoy has a rope with a winch. It's made for vehicles that can't drive anymore: drag one out of a ditch, pull it onto a tow truck, or tow it behind another car. Everything runs in the **Tow** app on the phone, like a remote control.

### Using the Tow app

<img src="images/phone-tow-attach.png" width="200" alt="Tow app: attach a rope"> <img src="images/phone-tow.png" width="200" alt="Tow app: remote control and winch">

1. **Attach the rope:** open the phone (**F4**) → **Tow**, then tap **Attach rope** – it goes where you look, a blue ball shows the spot – or one of **your vehicles** below it.
2. **Place the anchor:** hold the arrows to move it, **Up** / **Down** to raise or lower it, **Fine** for slow, exact moves. The vehicle stays put while the rope just gets longer.
3. **Pull:** **Haul in** winds the rope and pulls the vehicle to the anchor. **Pay out** gives rope, for example to lower a lifted end. **Stop** locks the rope at its length, like a tow rope.

With a rope on, everything is on one screen: at the top the rope itself – your vehicle, the rope with its length and state, the anchor – then the **Winch** panel and the **Anchor** panel with the remote. The rope there sags while it is slack, turns orange and red under a high load, and marks run along it while the winch turns.

**Towing with another vehicle:** the anchor can go onto any of your vehicles, at any point. Move it close to one: a **ring** shows where it would hook on, with a dashed line from the anchor. It is **green** on a tow hitch and **white** elsewhere. Tow hitches within a few meters show as faint green rings, so you can find them. Then tap **Hook on**; nothing hooks on by itself. The anchor now moves with that vehicle: drive off to tow, or stand still and haul in like a tow truck. **Unhook** leaves the anchor where it is, and you can move it again. Drive off gently, because a hard jolt can snap the rope.

**Loading it onto a tow truck:** hook the anchor onto the truck, haul the car up onto it and tap **Stop**. Once the rope is short (3 m or less), a **Strap down** button appears below the anchor. It straps the car down onto that truck, the same as in the Straps app, without aiming. Afterwards the Straps app offers **Remove rope**, so you can take the rope off there.

The ring picks a tow hitch within 0.7 m first, otherwise the nearest sturdy point within 0.5 m. Light parts like mirrors, glass or thin panels are passed over if a sturdy point is in reach, because the rope would only tear them off.

**Pull strength:** pick 30, 60, 100 or 150 % of the vehicle's weight in the app (60 % at first). If the vehicle doesn't follow, it's stuck or the parking brake is on: pick more.

**Flip upright:** shows only while the vehicle lies on its roof or side. It turns it onto its wheels where it is, free of charge, damage included.

**To the road:** for a vehicle the rope can't free, for example one wrapped around a lamp post. It puts the vehicle back on the last road it drove on, free of charge, damage included. The vehicle must stand still, and it doesn't work during a police chase.

<img src="images/rope-towing.jpg" width="320" alt="A truck tows a car on the rope"> <img src="images/rope-hitch.jpg" width="320" alt="The anchor hooked onto a truck's tow hitch, the winch locked"> <img src="images/rope-winch-gauge.jpg" width="240" alt="The winch gauge above the anchor while the winch lifts a car">

### What you see

- **The rope** sags when it's slack and turns **yellow, orange** and finally **red** as it gets close to snapping. Then slow down.
- **The ring above the anchor** shows how hard the winch works, from green to **blinking red** when it's at its limit: too heavy, stuck, or trying to lift too much.
- **Light marks on the rope** move as fast as it is wound in. If they stand still while you haul in, the vehicle is stuck.

### Good to know

- The rope behaves like a real one: it is stiff, only pulls and never pushes, and snaps only on a hard jolt. The winch alone never breaks it.
- The rope comes off by itself when the vehicle is reset or recovered, when the part it's tied to tears off, or when it snaps.
- It works on your own vehicles and your own traffic only. Other players' cars are driven by their PCs. You can't rope the vehicle you are sitting in, but you can hook the anchor onto it to tow.
- Server admins can switch it off (`client.allowRopes`, together with the Straps app), set the winch speed (`client.winchSpeed`) and the highest pull strength (`client.winchStrength`). "To the road" can be switched off on its own (`client.allowTowToRoad`).

## Strapping a car down (straps)

A car on a flatbed or a trailer slides off in the first curve. The **Straps** app on the phone holds it down with ratchet straps, like real tie-down straps: each one runs from the car to the truck or trailer below it and is pulled tight when it goes on.

- **Strap down:** look at the car and tap it. Four straps go on at once, one at each corner of the car, down to the nearest sturdy point of your vehicle below. If a corner has nothing in reach, it is left out ("3 of 4 strapped").
- **Add strap:** one strap by hand. *1.* Look at the car (a blue ball shows where the strap goes) and tap **Here**. *2.* Move the strap's end to the truck or trailer with the same remote as the Tow app's anchor: hold the arrows to move it, **Up** / **Down**, the middle button puts it where you look, **Fine** moves it slowly. It stays within 3 m of the car. A ring shows where it would hook on, with a dashed line to it; tap **Hook on**. **Cancel** takes it off again.
- **Tighten:** pulls all straps tight, like a very weak winch. Each strap is hauled in slowly until it holds firmly, then it locks again. Use it when a strap hangs loose.
- **The list** shows every strap with a dot for its load: green is fine, yellow is high, red is close to snapping, grey is slack. Remove one with its button, or all with **Remove all**.
- **Remove rope:** if the tow rope from the Tow app is still on a strapped car, this button takes it off.
- **Coming from the Tow app:** a car you hauled onto a truck can be strapped down right there, see [Loading it onto a tow truck](#using-the-tow-app).

In the world, straps are a **wide yellow band** with a **ratchet** (a dark block with a yellow lever) at the lower end. Like the rope, they turn orange and red under a high load.

Good to know:

- Drive gently with a load. A strap only snaps on a hard jolt, but a crash can tear it.
- A strap comes off when the car or the truck is reset or removed, when the part it holds tears off, or when it snaps.
- Your own vehicles only, like the rope. You can have the rope and straps at the same time, for example to winch a car onto a flatbed and then strap it down.
- Server admins switch straps on and off together with the rope (`client.allowRopes`).

## Towing jobs

<img src="images/phone-jobs.png" width="240" alt="Jobs app: your job and the open jobs">

Cars break down at the roadside, and somebody has to tow them to a repair shop. There is **one list for everyone** on the server: whoever takes a job first gets it.

**License needed:** towing jobs need the **Towing License** ($5,000). Buy it at the **License Office** (a marker on the map). Without it, the Jobs app shows the jobs grey, with a bar on top: **Route** there leads you to the office. The **Taxi License** ($5,000) is for [taxi jobs](#taxi-jobs).

1. **Find a job:** phone (**F4**) → **Jobs** → **Towing**. The Jobs app opens on a card per kind of job; **‹ Jobs** at the top left leads back. Every job shows the vehicle (its icon tells the kind: car, SUV, pickup, van, bus or truck), what's wrong (engine failure, broken clutch or gearbox, broken radiator, oil leak, broken windshield or taillights, sometimes a flat tire), how far you have to drive to it, the repair shop, the length of the tow (both by road), your pay and the XP you get under it. The jobs are sorted by the level they need, see [Levels](#levels).
2. **Take it:** the route leads you to the breakdown. A marker floats above the car when you are close. It's yours now: the others see the job as taken.
3. **Pick it up:** the car stands beside the road with the hazard lights on. From level 3 on, some jobs are **crashes**: the car is wrecked, sometimes on its roof (**Flip upright** in the Tow app puts it back on its wheels). A crashed car or one with an engine failure won't start (resetting it doesn't help). With a broken clutch or gearbox the engine runs, but the car doesn't drive. A broken radiator leaks its coolant and steams, so you see it from afar (once you are there, the engine slowly cools down), an oil leak leaves the engine dry: the car still drives, but not for long before the engine breaks. It's in neutral with the parking brake on, so it doesn't roll away. Get in and release it to roll it, or tow it as it is: on a flatbed, on a trailer, or with the rope and winch from the Tow app (pick more strength if it doesn't follow). Close to it, the route switches to the repair shop.
4. **Deliver it:** at the shop a ring on the ground shows the drop-off zone. Leave the car standing in it for 3 seconds, with nobody inside. The pay goes to your account and the car is taken away. If you crash or lose the connection right then, the pay arrives on your next join.

- **Pay:** $150 plus $120 per km of the tow, 25 % more with a flat tire, more for harder jobs and for your level (see below). The server can change it (`client.jobPay`).
- **Damage costs:** new damage on the way costs part of the pay, up to half of it. Dragging the car along on the rope is allowed, but it usually costs more than loading it.
- **Your job on the phone:** the Jobs app shows your job with its steps (*Pick up → Tow → Paid*), the distance and **Route** to set the route again. The Tow and Straps apps show it in a small strip at the top.
- **Give up** in the Jobs app removes the car; the job is open again for everyone. If you leave the server or don't finish within 30 minutes, it is open again too.
- New jobs come in by themselves. There are always some for everyone on the server: 3 open jobs for beginners and 3 at the highest level each player has reached. They appear only on normal roads and never right next to a player.

### Levels

Every job you finish gives you **XP**, and with enough XP you reach the next **level** (up to level 10). Every kind of job has its own level. In the Jobs app, a ring above the jobs shows your level and fills up on the way to the next one.

- **Harder jobs:** jobs come in four kinds, each from a level on. The Jobs app groups them by that level, yours at the top. The ones you can't take yet are at the bottom, grey with a lock.

  | From level | Jobs |
  |---|---|
  | 1 | cars only, short tows, rarely a flat tire |
  | 3 | sometimes a pickup or van, longer tows, more flat tires, sometimes a crash (pays 30 % more) |
  | 5 | often heavy vehicles, long tows, often a crash (pays 70 % more) |
  | 8 | mostly heavy vehicles, the longest tows, often a flat tire, mostly bad crashes (pays 120 % more) |

- **More pay:** every level above 1 adds 5 % to your pay. Everyone sees their own pay on a job.
- **XP:** a harder job gives more XP (40, 70, 110, 160). Damage costs XP as it costs pay. A job two or more kinds below your best gives only half the XP, so the easy ones are left for beginners.
- The game's own career XP grows too (BeamXP and the Commercial branch).
- Your level is kept by the server, per server. A new save keeps it; the server owner can reset it (`sc levels reset <name>`).

## Taxi jobs

People wait at the roadside for a ride to a place on the map (a garage, a dealership, a gas station) or, most of them, to a street: *Near Belasco Auto*, *Street in town*, *Country road*. Most rides start or end in town, and most go to a place in town; some go from town out into the country, some the other way, some never touch the town. As with towing jobs, there is **one list for everyone**.

**License needed:** taxi jobs need the **Taxi License** ($5,000) from the **License Office**.

1. **Find a ride:** phone (**F4**) → **Jobs** → **Taxi**. Every ride shows where the passengers want to go, how many they are (a ride for a group shows e.g. *3 people*), how far you have to drive to them, the length of the ride (both by road), your pay and the XP.
2. **Pick them up:** the route leads you to the passengers, figures beside the road with a yellow marker above. Drive there in any vehicle (not on foot) with a seat for each of them and stop next to them for 2 seconds: they get in and sit on the back seats, spread out evenly (the front passenger seat only when the back is full). That vehicle is your taxi now. Too few seats: they don't get in. (Older or modded vehicles without seats for passengers can't be counted: they carry them unseen.)
3. **Drive them:** the route leads to the place. A ring on the ground there shows the drop-off zone. Stop in it for 2 seconds, sitting in your taxi. The pay goes to your account; the message shows the total with one short hint: *Smooth ride bonus* with the tip (e.g. *+$12*), or *Rough ride* when the ride cost pay and earned no tip.

- **Pay:** $60 plus $80 per km of the ride, more for longer rides and for your level. A group pays 15 % more for every passenger after the first (5 passengers: 60 % more). The server can change it (`client.jobPay`). A ride pays less than a tow of the same length: it is quicker and easier, and a smooth one earns a tip.
- **Drive smoothly:** every jolt (hard braking, a crash, a hard landing) costs 5 % of the pay; *Drive smoother!* tells you.
- **Keep to the speed limit:** more than 10 % over the road's speed limit for 2 seconds and your passengers complain (*Slow down, please!*), still free. Still too fast 5 seconds later costs 5 % of the pay (*Too fast! Less pay.*). Staying too fast, they complain again and it costs again every 10 seconds. The [speed limit sign](#speed-limit-sign) shows the limit if you turned it on. Roads without a speed limit in the game don't count.
- New damage to your taxi costs too, and resetting it (**R**) during the ride costs half. All together it never costs more than half.
- **Stars:** the passenger rates the ride with 1 to 5 stars. Every jolt, speeding and damage costs stars. In the Jobs app your ride shows the stars and the pay as it is now (the full pay struck through once it drops).
- **Tip:** 5 stars earn a tip of 15 % on top of the pay, 4 stars 5 %. Below that, no tip.
- **VIPs** pay 50 % more and tip more (25 % for 5 stars, 10 % for 4), but jolts and speeding cost twice as much.
- **Calls (On duty):** on the taxi page of the Jobs app, switch **On duty** on. While you drive, the nearest ride within 2 km that your vehicle has enough seats for then calls you (a vehicle whose seats can't be counted: rides for one only): the phone comes out with how many they are and where they want to go (e.g. *3 people to Belasco Auto*), **Accept** and **Decline**. It rings 15 seconds. You only get calls while you are on duty, sit in a vehicle of your own (not on foot, not in another player's car), have the Taxi License and no job. So it doesn't nag: after a call you didn't take the next one waits 45 seconds (and that ride doesn't call again), after a ride 20 seconds, and after two missed calls in a row you are off duty. Every join starts off duty.
- If you get out, the route leads back to your taxi. If the taxi disappears, the passenger waits at the pickup again.
- Giving up, the 30 minutes and new jobs work as for towing jobs.
- **Levels:** taxi jobs have their own level, by the same rules as towing (see [Levels](#levels)), but every level above 1 adds only 3 % to the pay (towing: 5 %):

  | From level | Rides |
  |---|---|
  | 1 | short rides (about 0.6–2 km), sometimes two passengers |
  | 3 | longer rides, sometimes a VIP (pays 15 % more), up to 3 passengers |
  | 5 | long rides, often a VIP (pays 30 % more), up to 5 passengers |
  | 8 | the longest rides, every second passenger a VIP (pays 50 % more), groups more often |

  Even at the highest level many rides are for one or two passengers.

## Speed limit sign

A road sign at the bottom right shows the speed limit of the road you drive on: a round sign with a red ring in km/h, a US *SPEED LIMIT* sign in mph. The unit is the game's (its setting for units: metric or imperial), or the one you pick in the phone's **Settings** app (**Unit**: BeamNG, km/h or mph). It pulses red while you drive more than 10 % too fast, the point where taxi passengers start to complain.

- It is **off** by default. Turn it on in the phone's **Settings** app: **Taxi rides** (only while you drive a taxi ride) or **Always**.
- It shows only while you drive a vehicle on a road that has a speed limit in the game; on foot, off the road or on a road without one it is hidden.
- It hides while the Career-Convoy menu is open, so it never covers the menu.
- It is a UI app of its own (*Career-Convoy Speed Limit*), added to your career layout once. Move or remove it in the game's UI editor like any other app; once removed, it isn't added again.

## Phone

<img src="images/phone.png" width="240" alt="The Career-Convoy phone">

Press **F4** or click the phone tab at the right screen edge (directly below the Career-Convoy menu's tab) to take out your phone. It shows the server's time, how many players are on the server and whether you're connected. Below the clock it says how long until night (or day), with a bar for how much of the day or night is over.

The phone goes away when you open a game menu (pause menu, map, garage, ...); there, **F4** only puts it away.

Apps:

- **Jobs:** towing and taxi jobs, see [Towing jobs](#towing-jobs) and [Taxi jobs](#taxi-jobs).
- **Tow:** rope and winch as a remote control, see [Moving your vehicles by hand](#moving-your-vehicles-by-hand-rope-and-winch).
- **Straps:** strap a car down on a truck or trailer, see [Strapping a car down](#strapping-a-car-down-straps).
- **Fuel:** gas station prices, see [Fuel app on the phone](#fuel-app-on-the-phone).
- **Settings:** pick a wallpaper, the look of the app icons (BeamNG orange, each app in its own color, dark or glass) and when the [speed limit sign](#speed-limit-sign) shows and in which unit. The choice is kept on your PC.

<img src="images/phone-settings.png" width="240" alt="Settings app: wallpaper and app icons">

- The bar at the bottom goes back to the home screen from an app, or puts the phone away.
- Opening the phone collapses the Career-Convoy menu, and the other way round.
- The key is rebindable under *Options → Controls → BeamMP*, entry "Career-Convoy: phone".
- Server admins can switch it off with `sc set client.phone false`.

## Sending money

```
/pay <name> <amount>
```

Part of the name is enough, and names may contain spaces. The money is taken from your save first and then added to the receiver's save. If the receiver leaves or doesn't confirm within 30 seconds, you get the money back. Limits are set by the server (`server.paymentMax`, `server.paymentCooldownSeconds`).

Other chat commands: `/players` (who is here, who is still loading) and `/schelp` or `/help` (help).
