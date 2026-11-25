// SharedCareer :: tests for the UI apps (menu and phone), run in node with tests/ui_mock.js.
// They check that the windows tell Lua what is visible (sharedCareer_menu.uiVisible), so the
// state is only built and sent while someone looks – and never missing while a window is open.
// At the end a timeline of random clicks is written; tests/ui_replay.lua plays it against the
// real menu.lua (tools/test.sh runs both).
//
// Run: node tests/ui_test.js <timeline.json>
const H = require('./ui_mock');
const {makeEnv, load, reports, last, check} = H;
const MENU = ['client/ui/modules/apps/SharedCareer-Menu/app.js', 'SharedCareerMenu'];
const PHONE = ['client/ui/modules/apps/SharedCareer-Phone/app.js', 'SharedCareerPhone'];

//== Menu alone ==
{
	const env = makeEnv({sharedCareerMenuCollapsed: '0'});
	const menu = load(...MENU, env);
	check(last(env, 'menu') === true, 'menu built expanded: reports visible');
	check(env.calls.some(c => c.includes('sharedCareer_menu.uiRequest()')), 'menu built: asks for the state');
	let n = reports(env).length;
	env.advance(10000);
	const beats = reports(env).slice(n).filter(r => r[0] === 'menu' && r[1]).length;
	check(beats === 5, 'expanded: reports every 2 s (' + beats + ' in 10 s)');
	menu.toggleCollapsed();
	check(menu.collapsed && last(env, 'menu') === false, 'collapsed by the tab: reports not visible at once');
	n = reports(env).length;
	env.advance(10000);
	check(reports(env).length === n, 'collapsed: no reports');
	menu.emit('SharedCareerToggle');
	check(!menu.collapsed && last(env, 'menu') === true, 'menu key (F7) expands: reports visible at once');
	menu.emit('SharedCareerToggle');
	check(menu.collapsed && last(env, 'menu') === false, 'menu key (F7) collapses: reports not visible');
	menu.toggleCollapsed();
	menu.destroy();
	check(last(env, 'menu') === false, 'window removed: reports not visible');
	n = env.calls.length;
	env.advance(10000);
	check(env.calls.length === n, 'window removed: its timer stops');
}
{
	const env = makeEnv({sharedCareerMenuCollapsed: '1'});
	const menu = load(...MENU, env);
	check(menu.collapsed && last(env, 'menu') === false, 'menu built collapsed: reports not visible');
}
// day/night length: round values, sent once the clicks stop
{
	const env = makeEnv({sharedCareerMenuCollapsed: '0'});
	const menu = load(...MENU, env);
	const sent = () => env.calls.filter(c => c.includes('uiSetLengths'));
	menu.emit('SharedCareerState', {canControl: true, dayMinutes: 1, nightMinutes: 7});
	const days = [];
	for (let i = 0; i < 3; i++) { menu.changeLength('day', 1); days.push(menu.lengths().day); }
	check(days.join(',') === '5,10,15', 'day from 1: 5, 10, 15 (' + days.join(',') + ')');
	check(sent().length === 0, 'nothing sent while clicking');
	env.advance(1000);
	check(sent().length === 1 && sent()[0].includes('uiSetLengths(15,7)'), 'sent once after the clicks: ' + sent());
	menu.changeLength('night', 1);
	const up = menu.lengths().night;
	menu.changeLength('night', -1); menu.changeLength('night', -1); menu.changeLength('night', -1);
	check(up === 10 && menu.lengths().night === 1, 'night 7 (from the config): + goes to 10, − stops at 1');
	for (let i = 0; i < 40; i++) menu.changeLength('day', 1);
	check(menu.lengths().day === 600, 'at most 600 min');
	check(menu.lengthText(50) === '50 min' && menu.lengthText(90) === '1 h 30' && menu.lengthText(600) === '10 h',
		'lengths as text: 50 min, 1 h 30, 10 h');
	menu.emit('SharedCareerState', {canControl: true, dayMinutes: 15, nightMinutes: 7});
	check(menu.lengths().day === 600, 'an older state from the server doesn\'t undo the clicks before they are sent');
	env.advance(1000);
	menu.emit('SharedCareerState', {canControl: true, dayMinutes: 600, nightMinutes: 1});
	check(menu.pending === null && menu.lengths().day === 600, 'confirmed by the server: its values are shown');
}

// clock: one choice of three (Run / Pause / Real time)
{
	const env = makeEnv({sharedCareerMenuCollapsed: '0'});
	const menu = load(...MENU, env);
	const lastTime = () => env.calls.filter(c => c.includes('sharedCareer_env.')).pop();
	menu.emit('SharedCareerState', {canControl: true});
	check(menu.clockMode() === 'run', 'clock running: Run is chosen');
	const before = env.calls.length;
	menu.setClockMode('run');
	check(env.calls.length === before, 'the chosen one again: nothing sent');
	menu.setClockMode('pause');
	check(lastTime().includes('uiSetPaused(true)'), 'Pause pauses the clock');
	menu.emit('SharedCareerState', {canControl: true, paused: true});
	menu.setClockMode('run');
	check(menu.clockMode() === 'pause' && lastTime().includes('uiSetPaused(false)'), 'paused -> Run resumes');
	menu.setClockMode('real');
	check(lastTime().includes('uiSetRealtime(true)'), 'Real time turns it on');
	menu.emit('SharedCareerState', {canControl: true, realtime: true, paused: false});
	menu.setClockMode('run');
	check(menu.clockMode() === 'real' && lastTime().includes('uiSetRealtime(false)'), 'real time -> Run turns it off');
	menu.setClockMode('pause');
	check(lastTime().includes('uiSetPaused(true)'), 'real time -> Pause (the server ends real time)');
	const n = env.calls.length;
	menu.emit('SharedCareerState', {canControl: false});
	menu.setClockMode('pause');
	check(env.calls.length === n, 'no control: nothing sent');
}

// traffic note and option switches
{
	const env = makeEnv({sharedCareerMenuCollapsed: '0'});
	const menu = load(...MENU, env);
	const settings = {canEdit: true, players: 3, shareRoad: 5, shareParked: 8, poolRoad: 10, poolParked: 12,
		remoteVehicleGhost: true, trafficSignalSync: true};
	menu.emit('SharedCareerState', {settings});
	check(menu.trafficNote() === 'You: 5 driving, 8 parked · 3 online', 'traffic note: ' + menu.trafficNote());
	menu.emit('SharedCareerState', {settings: Object.assign({}, settings, {shareRoad: 14})});
	check(menu.trafficNote() === 'You: 10 driving, 8 parked · 3 online · rejoin for more',
		'more than loaded at the join: ' + menu.trafficNote());
	const opt = (key) => menu.OPTIONS.filter(o => o.key === key)[0];
	check(menu.optionOn(opt('client.remoteVehicleGhost')) === false && menu.optionOn(opt('server.trafficSignalSync')) === true,
		'switches: ghost cars = collision off, synced lights on');
	check(menu.trafficKey('parked') === 'client.parkedTraffic' && menu.totalKey('road') === 'server.roadTrafficTotal',
		'traffic table: setting per row and column');
}

//== Phone alone ==
{
	const env = makeEnv({});
	const phone = load(...PHONE, env);
	check(last(env, 'phone') === false && last(env, 'fuel') === false, 'phone built: phone and Fuel app not visible');
	phone.emit('SharedCareerPhone', {enabled: true, apps: [{id: 'tow'}, {id: 'fuel'}]});
	let n = reports(env).length;
	env.advance(6000);
	check(reports(env).length === n, 'phone away: no reports');
	phone.toggle();
	check(phone.open && last(env, 'phone') === true && last(env, 'fuel') === false, 'phone out: reports phone visible');
	phone.openApp({id: 'fuel'});
	check(last(env, 'fuel') === true, 'Fuel app opened: reports fuel visible at once');
	n = reports(env).length;
	env.advance(10000);
	const r = reports(env).slice(n);
	check(r.filter(x => x[0] === 'phone' && x[1]).length === 5 && r.filter(x => x[0] === 'fuel' && x[1]).length === 5,
		'phone out with the Fuel app: both reported every 2 s');
	phone.goHome();
	check(last(env, 'fuel') === false && last(env, 'phone') === true, 'home screen: fuel not visible, phone still');
	phone.openApp({id: 'tow'});
	check(last(env, 'fuel') === false, 'Tow app: fuel not visible');
	phone.openApp({id: 'fuel'});
	check(last(env, 'fuel') === true, 'switching to Fuel: visible');
	phone.homeBar();
	check(last(env, 'fuel') === false && phone.open, 'home bar from an app: back home, fuel not visible');
	phone.openApp({id: 'fuel'});
	phone.toggle();
	check(!phone.open && last(env, 'phone') === false && last(env, 'fuel') === false, 'phone away from the Fuel app: both not visible');
	n = reports(env).length;
	env.advance(6000);
	check(reports(env).length === n, 'phone away: no more reports');
	phone.emit('SharedCareerPhoneToggle');
	check(phone.open && last(env, 'phone') === true, 'phone key (F4): out, reported');
	phone.openApp({id: 'fuel'});
	phone.emit('SharedCareerPhoneAway');
	check(!phone.open && last(env, 'phone') === false && last(env, 'fuel') === false, 'game menu: phone away, not visible');
	phone.emit('SharedCareerPhoneAway');
	check(!phone.open, 'game menu, phone already away: stays away');
	phone.emit('SharedCareerPhoneToggle');
	phone.openApp({id: 'fuel'});
	phone.emit('SharedCareerPhone', {enabled: false, apps: []});
	check(!phone.open && last(env, 'phone') === false && last(env, 'fuel') === false, 'phone switched off by the server: not visible');

	// fuel data: false keeps the list, a table replaces it, missing = no stations
	phone.emit('SharedCareerState', {hour: 10, connected: true, fuel: {stations: [{id: 'a'}]}});
	check(phone.fuel && phone.fuel.stations.length === 1, 'fuel list taken');
	phone.emit('SharedCareerState', {hour: 10, connected: true, fuel: false});
	check(phone.fuel && phone.fuel.stations.length === 1, 'fuel = false (app closed): the last list stays');
	phone.emit('SharedCareerState', {hour: 11, connected: true});
	check(phone.fuel === null && phone.time === 11, 'no fuel (map without stations): empty list; time updated');
	// the hint "Green: cheaper after a delivery" only while a station is cheaper
	check(!phone.fuelDiscounted(), 'no stations: no hint about green prices');
	phone.emit('SharedCareerState', {hour: 11, connected: true, fuel: {stations: [{id: 'a', fuels: {gasoline: {price: 1.6}}}]}});
	const noDiscount = phone.fuelDiscounted();
	phone.emit('SharedCareerState', {hour: 11, connected: true, fuel: {stations: [{id: 'a', fuels: {gasoline: {price: 1.6}}},
		{id: 'b', fuels: {diesel: {price: 1.5, discount: 10}}}]}});
	check(!noDiscount && phone.fuelDiscounted(), 'the hint about green prices only while a station is cheaper after a delivery');
	// home screen: time until day / night with a bar
	phone.emit('SharedCareerPhone', {enabled: true, apps: [{id: 'tow'}, {id: 'fuel'}]});
	phone.emit('SharedCareerState', {hour: 13, isDay: true, secondsToSwitch: 1380, dayStart: 6, nightStart: 20, connected: true,
		players: {list: [{name: 'Me', status: 'driving', me: true}, {name: 'Ben', status: 'mission'}]}});
	check(phone.dayText() === 'Night in 23 min' && Math.abs(phone.phaseProgress() - 0.5) < 1e-9,
		'home screen: "Night in 23 min", half of the day over (' + phone.dayText() + ', ' + phone.phaseProgress() + ')');
	check(phone.playerCount() === 2, 'the number of players in the status bar');
	phone.emit('SharedCareerState', {hour: 2, isDay: false, paused: true, dayStart: 6, nightStart: 20, connected: true});
	check(phone.dayText() === 'Night · paused' && Math.abs(phone.phaseProgress() - 0.6) < 1e-9,
		'night, clock paused: bar over midnight');
	phone.emit('SharedCareerState', {hour: 2, connected: false});
	check(phone.dayText() === 'Not connected' && phone.phaseProgress() === null, 'not connected: no bar');
	// Tow app: one screen; the rope strip sags while slack, marks run while the winch turns
	phone.emit('SharedCareerTow', {allowed: true, attached: true, slack: true, winch: 0, strengths: [30, 60]});
	check(phone.ropePath().includes('Q') && !phone.ropeRunning(), 'slack rope, winch stopped: it sags, no marks');
	phone.emit('SharedCareerTow', {allowed: true, attached: true, slack: false, winch: 1, strain: 0.5});
	check(phone.ropePath().includes('L') && phone.ropeRunning(), 'taut, hauling in: straight, marks run');
	phone.emit('SharedCareerTow', {allowed: true, attached: true, slack: false, winch: 1, strain: 1});
	check(!phone.ropeRunning() && phone.strainText(0.95) === 'At the limit', 'the winch at its limit: the marks stand');
	phone.emit('SharedCareerTow', {allowed: true, attached: true, slack: true, winch: -1});
	check(phone.ropeRunning(), 'paying out: marks run');
	// Tow app: the buttons go to tow.lua
	phone.openApp({id: 'tow'});
	let calls = env.calls.length;
	phone.towCall('uiHookOn()');
	phone.nudge(1, 0, 0);
	phone.nudgeStop();
	phone.remoteToView();
	let sent = env.calls.slice(calls).join(' ');
	check(sent.includes('sharedCareer_tow.uiHookOn()') && sent.includes('sharedCareer_tow.uiNudge(1,0,0)')
		&& sent.includes('sharedCareer_tow.uiNudgeStop()') && sent.includes('sharedCareer_tow.uiToView()'), 'Tow app: calls go to tow.lua');
	// the same remote in the Straps app: its buttons go to straps.lua; a held button is let go where it was pressed
	phone.openApp({id: 'straps'});
	calls = env.calls.length;
	phone.nudge(0, 0, -1);
	phone.remoteToView();
	sent = env.calls.slice(calls).join(' ');
	check(sent.includes('sharedCareer_straps.uiNudge(0,0,-1)') && sent.includes('sharedCareer_straps.uiToView()')
		&& !sent.includes('sharedCareer_tow'), 'the remote in the Straps app: calls go to straps.lua');
	phone.openApp({id: 'fuel'});
	calls = env.calls.length;
	phone.nudgeStop();
	phone.nudgeStop();
	sent = env.calls.slice(calls).filter(c => c.includes('uiNudgeStop'));
	check(sent.length === 1 && sent[0].includes('sharedCareer_straps'), 'let go: told once, to the app it was pressed in');
	// Straps app: the straps' load as dots, calls to straps.lua
	phone.emit('SharedCareerStraps', {allowed: true, step: 2, hookOn: {vehicle: 'Truck', hitch: false}});
	check(Array.isArray(phone.straps.straps) && phone.straps.hookOn.vehicle === 'Truck', 'Straps app: step 2, where it would hook on');
	check(phone.strapDot({slack: true, load: 0.9}) === 'scp-dot-slack' && phone.strapDot({slack: false, load: 0.1}) === 'scp-dot-ok'
		&& phone.strapDot({slack: false, load: 0.5}) === 'scp-dot-high' && phone.strapDot({slack: false, load: 0.8}) === 'scp-dot-critical',
		'a strap\'s load as a dot: grey slack, green, yellow, red');
	calls = env.calls.length;
	phone.strapsCall('uiStrapDown()');
	check(env.calls[calls] && env.calls[calls].includes('sharedCareer_straps.uiStrapDown()'), 'Straps app: calls go to straps.lua');
	// Tow app: the winch's load as segments, the rope's load in words
	phone.emit('SharedCareerTow', {allowed: true, attached: true, slack: false, winch: 1, strain: 0.5, ropeLoad: 0.1});
	check(phone.segStyle(4).background && !phone.segStyle(5).background && phone.ropeState().text === 'OK',
		'winch at half its limit: 5 of 10 segments; rope OK');
	phone.emit('SharedCareerTow', {allowed: true, attached: true, slack: false, winch: 1, strain: 1, ropeLoad: 0.5});
	check(phone.segStyle(9).background === 'var(--scp-danger)' && phone.ropeState().text === 'High load',
		'winch at its limit: all segments red; rope under high load');
	phone.emit('SharedCareerTow', {allowed: true, attached: true, slack: false, winch: 0, strain: 0.2, ropeLoad: 0.8});
	check(phone.ropeState().cls === 'scp-rope-critical', 'rope near breaking: the critical chip');
	phone.emit('SharedCareerTow', {allowed: true, attached: true, slack: false, winch: -1, strain: 0, ropeLoad: 0.2});
	check(phone.winchText() === 'Paying out' && !phone.segStyle(0).background, 'paying out: the winch gives way, no load shown');
	phone.emit('SharedCareerTow', {allowed: true, attached: true, strengths: [50, 100], strength: 100});
	check(phone.tow.strengthOptions.map(o => o.id + ':' + o.name).join() === '50:50%,100:100%',
		'the strengths as options of the segment select');
	phone.emit('SharedCareerTow', {allowed: true, attached: true, slack: true, winch: 0, strain: 0.3, ropeLoad: 0});
	check(!phone.segStyle(0).background && phone.winchText() === 'Locked' && phone.ropeState().text === 'Slack',
		'winch stopped: "Locked", empty segments; rope "Slack"');
	// Jobs app: list, your job, the steps; the strip above the Tow and Straps apps opens it. What a job shows
	// comes from its job type (jobs.lua appState); the window only lays it out.
	phone.emit('SharedCareerPhone', {enabled: true, apps: [{id: 'jobs', title: 'Jobs'}, {id: 'tow'}, {id: 'fuel'}]});
	phone.emit('SharedCareerJobs', {enabled: true, open: 1, sections: [{type: 'tow', name: 'Towing', icon: 'tow', open: 1,
		level: {level: 4, share: 0.25, toGo: 200}, groups: [
			{minLevel: 3, locked: false, open: 1, jobs: [{id: 1, icon: 'tow', title: 'Gavril Grand Marshal',
				tags: [{text: 'Engine failure', kind: 'engine'}, {text: 'Flat tire', kind: 'tire'}],
				dest: 'Belasco Auto', pay: 600, state: 'open', length: 2600, distance: 1200}]},
			{minLevel: 5, locked: true, open: 1, jobs: [{id: 2, icon: 'tow', title: 'Ibishu Covet', dest: 'Firwood', pay: 400,
				state: 'open', locked: true}]}]}]});
	const sec = phone.jobs.sections[0];
	check(phone.jobs.enabled && phone.jobs.open === 1 && sec.groups.length === 2 && phone.money(1234.4) === '$1,234'
		&& phone.jobStep() === 0, 'a section per job type, its jobs by level (one group locked); money formatted, no job of your own');
	check(phone.tagLine(sec.groups[0].jobs[0]) === 'Engine failure · Flat tire' && phone.tagLine(sec.groups[1].jobs[0]) === '',
		'a job\'s tags in one line');
	check(phone.levelRing(sec.level).indexOf('90deg') > 0 && phone.levelRing({share: 2}).indexOf('360deg') > 0
		&& phone.levelRing(null).indexOf('0deg') > 0, 'your level: the ring is a quarter full (never more than full; empty without a level)');
	check(phone.xpText(70) === '+70 XP' && phone.xpText(19.6) === '+20 XP' && phone.xpText(0) === '' && phone.xpText(undefined) === '',
		'the XP of a job in words, nothing without any');
	check(phone.levelText(sec.level) === 'Level 4 · 200 XP to level 5' && phone.levelText({level: 10}) === 'Level 10 · top level'
		&& phone.levelText(null) === '', 'your level in words');
	const jobTypes = phone.jobTypes;
	check(jobTypes.length === 1 && jobTypes[0].id === 'tow', 'start page: a card for towing');
	check(phone.jobTypes === jobTypes && phone.fuelSorts.map(o => o.id).join() === 'gasoline,diesel,distance',
		'the lists get the same arrays until Lua sends new jobs (a new array each time never settles)');
	check(phone.jobTypeText(jobTypes[0]) === '1 open', 'on the cards: the open jobs');
	check(phone.jobTypeLevel('tow').level === 4 && phone.jobTypeLevel('taxi') === null, 'on the cards: your level, none without it');
	phone.openApp({id: 'jobs', title: 'Jobs'});
	check(phone.jobsType === null && !phone.canGoBackInApp() && phone.appTitle() === 'Jobs', 'the Jobs app opens on its start page');
	phone.openJobType(jobTypes[0]);
	check(phone.jobsType === 'tow' && phone.canGoBackInApp() && phone.appTitle() === 'Towing' && phone.jobsOpenIn() === 1,
		'a card opens the page of its job type, the app bar shows its name');
	phone.goBack();
	check(phone.jobsType === null && phone.currentApp && phone.currentApp.id === 'jobs', 'back: to the start page of the app');
	phone.goBack();
	check(phone.currentApp === null, 'back on the start page: to the home screen');
	phone.openApp({id: 'jobs', title: 'Jobs'});
	phone.openJobType(jobTypes[0]);
	phone.goHome();
	phone.openApp({id: 'jobs', title: 'Jobs'});
	check(phone.jobsType === null, 'opened again: the start page');
	phone.emit('SharedCareerJobs', {enabled: true, sections: [{type: 'taxi', name: 'Taxi', icon: 'taxi', open: 2,
		groups: []}, {type: 'x', open: 1}]});
	check(phone.jobTypes.map(t => t.id + ':' + t.name + ':' + t.icon).join() === 'tow:Towing:tow,taxi:Taxi:taxi,x:x:jobs'
		&& phone.jobsOpenIn('tow') === 0 && phone.jobTypeText(phone.jobTypes[1]) === '2 open',
		'every job type Lua sends gets a card, towing first');
	phone.openJobType(phone.jobTypes[1]);
	check(phone.jobsType === 'taxi' && phone.appTitle() === 'Taxi', 'the taxi card opens the taxi jobs');
	phone.goBack();
	check(phone.jobs.sections[0].groups.length === 0 && phone.jobs.open === 0, 'nothing sent: empty lists');
	check(!phone.jobLicenseMissing() && phone.jobs.licenses && !Array.isArray(phone.jobs.licenses),
		'no licenses sent: nothing greyed out');
	phone.emit('SharedCareerJobs', {enabled: true, sections: [], licenses: []});
	check(!phone.jobLicenseMissing(), 'an empty Lua table ([]) counts as no licenses');
	phone.emit('SharedCareerJobs', {enabled: true, sections: [],
		licenses: {tow: {name: 'Towing License', owned: true}, taxi: {name: 'Taxi License', owned: false}}});
	phone.openJobType({id: 'tow'});
	check(!phone.jobLicenseMissing() && phone.jobLicense().name === 'Towing License', 'towing license owned: jobs can be taken');
	check(phone.jobLicenseMissing('taxi') && phone.jobLicense('taxi').name === 'Taxi License',
		'taxi license missing: its jobs are greyed out');
	env.calls.length = 0;
	phone.licenseRoute();
	check(env.calls.some(c => c.indexOf('sharedCareer_licenses.uiRoute()') >= 0), '"Route" leads to the license office');
	const active = function (more) {
		return Object.assign({id: 3, icon: 'tow', title: 'Gavril D-Series', dest: 'Belasco Auto', pay: 820,
			steps: ['Pick up', 'Tow', 'Paid']}, more);
	};
	phone.emit('SharedCareerJobs', {enabled: true, jobs: [], active: active({phase: 'running', step: 0,
		text: 'to the Gavril D-Series', short: 'Drive to the breakdown', distance: 900})});
	check(phone.jobStep() === 0 && phone.jobText() === 'to the Gavril D-Series' && phone.jobStepText() === 'Drive to the breakdown'
		&& phone.jobs.active.tags.length === 0 && !phone.jobPaid(), 'your job, step 1: the texts of its job type');
	phone.emit('SharedCareerJobs', {enabled: true, jobs: [], active: active({phase: 'running', step: 1, short: 'In the ring – wait'})});
	check(phone.jobStep() === 1 && phone.jobStepText() === 'In the ring – wait', 'step 2');
	check(phone.jobPayNow() === 820 && !phone.jobPayDropped() && phone.jobStars() === null,
		'a towing job: its pay, no stars');
	phone.emit('SharedCareerJobs', {enabled: true, jobs: [], active: active({type: 'taxi', phase: 'running', step: 1,
		payNow: 738, stars: 4})});
	check(phone.jobPayNow() === 738 && phone.jobPayDropped() && phone.jobStars() === 4 && phone.STAR_SLOTS.length === 5,
		'a rough taxi ride: the pay as it is now (the old one struck through), 4 of 5 stars');
	phone.emit('SharedCareerJobs', {enabled: true, jobs: [], active: active({type: 'taxi', phase: 'running', step: 1,
		payNow: 820, stars: 5})});
	check(phone.jobPayNow() === 820 && !phone.jobPayDropped() && phone.jobStars() === 5, 'a smooth ride: full pay, 5 stars');
	phone.emit('SharedCareerJobs', {enabled: true, jobs: [], active: active({phase: 'running', step: 1, short: 'In the ring – wait'})});
	phone.openApp({id: 'straps'});
	const inStraps = phone.jobStripShown();
	phone.openApp({id: 'fuel'});
	check(inStraps && !phone.jobStripShown(), 'the job strip: above the Tow and Straps apps, not in Fuel');
	phone.openJobs();
	check(phone.currentApp.id === 'jobs' && phone.jobsType === 'tow', 'the job strip opens the page of your job\'s type');
	phone.goHome();
	phone.emit('SharedCareerJobs', {enabled: true, jobs: [], active: active({phase: 'checking', step: 1})});
	check(phone.jobText() === 'Handing over…', 'handed over: waiting for the server');
	phone.emit('SharedCareerJobs', {enabled: true, jobs: [], active: active({phase: 'paid', step: 2})});
	check(phone.jobStep() === 2 && phone.jobPaid() && phone.jobText().indexOf('Done') === 0, 'step 3: paid');
	phone.openJobs();
	check(phone.currentApp && phone.currentApp.id === 'jobs', 'the job strip opens the Jobs app');
	phone.goHome();
	// the "On duty" switch of a job type (taxi): shown only for a job type that has one
	phone.emit('SharedCareerJobs', {enabled: true, sections: [{type: 'tow', open: 0, groups: []},
		{type: 'taxi', name: 'Taxi', icon: 'taxi', open: 1, duty: false, groups: []}], licenses: {}});
	check(phone.jobDuty('taxi') === false && phone.jobDuty('tow') === null, 'the switch: off for taxi, none for towing');
	phone.openApp({id: 'jobs', title: 'Jobs'});
	phone.openJobType({id: 'taxi'});
	env.calls.length = 0;
	phone.setDuty(true);
	check(env.calls.some(c => c.indexOf('sharedCareer_jobs.uiDuty("taxi", true)') >= 0), '"On duty" goes to Lua');
	phone.goHome();
	// a call: the phone comes out, "Decline" puts it away again
	if (phone.open) phone.toggle();
	check(!phone.open, 'phone away');
	const ride = {id: 'taxi-7', title: 'Ride request', text: 'To Belasco Auto', detail: '600 m away · $300', icon: 'taxi',
		seconds: 15, open: {app: 'jobs', page: 'taxi'}};
	phone.emit('SharedCareerPhoneCall', {call: ride});
	check(phone.open && phone.call && phone.call.title === 'Ride request', 'a call: the phone comes out and shows it');
	env.calls.length = 0;
	phone.answerCall(false);
	check(!phone.open && phone.call === null && env.calls.some(c => c.indexOf('sharedCareer_phone.uiAnswer(false)') >= 0),
		'"Decline": Lua hears it, the phone goes away again');
	phone.emit('SharedCareerPhoneCall', {call: ride});
	phone.emit('SharedCareerPhoneCall', {});
	check(!phone.open && phone.call === null, 'rang out (or hung up): the phone goes away again');
	phone.emit('SharedCareerPhoneCall', {call: ride});
	env.calls.length = 0;
	phone.answerCall(true);
	check(phone.open && phone.currentApp && phone.currentApp.id === 'jobs' && phone.jobsType === 'taxi'
		&& env.calls.some(c => c.indexOf('sharedCareer_phone.uiAnswer(true)') >= 0),
		'"Accept": the phone stays out on the taxi page');
	phone.emit('SharedCareerPhoneCall', {});
	check(phone.open && phone.jobsType === 'taxi', 'Lua ends the call after "Accept": the page stays');
	phone.goHome();
	if (phone.open) phone.toggle();
	phone.destroy();
	check(last(env, 'phone') === false && last(env, 'fuel') === false, 'phone window removed: not visible');
}

//== Menu and phone together (they close each other) ==
{
	const env = makeEnv({sharedCareerMenuCollapsed: '0'});
	const menu = load(...MENU, env);
	const phone = load(...PHONE, env);
	phone.emit('SharedCareerPhone', {enabled: true, apps: [{id: 'fuel'}]});
	phone.toggle();
	check(menu.collapsed && last(env, 'menu') === false && last(env, 'phone') === true,
		'phone out: menu collapses and reports not visible, phone visible');
	phone.openApp({id: 'fuel'});
	menu.toggleCollapsed();
	check(!phone.open && last(env, 'phone') === false && last(env, 'fuel') === false && last(env, 'menu') === true,
		'menu expanded: phone goes away, only the menu is visible');
	// at every moment, the views reported last match what is on screen
	const seq = [() => phone.toggle(), () => phone.openApp({id: 'fuel'}), () => menu.toggleCollapsed(),
		() => menu.emit('SharedCareerToggle'), () => phone.emit('SharedCareerPhoneToggle'), () => phone.homeBar(),
		() => phone.homeBar(), () => menu.toggleCollapsed()];
	let ok = true;
	for (let i = 0; i < 40; i++) {
		seq[(i * 7 + 3) % seq.length]();
		env.advance(700);
		const fuelShown = phone.open && phone.currentApp && phone.currentApp.id === 'fuel';
		if (last(env, 'menu') !== !menu.collapsed || last(env, 'phone') !== phone.open || last(env, 'fuel') !== !!fuelShown) {
			ok = false;
			console.log('  mismatch at step ' + i, {menu: !menu.collapsed, phone: phone.open, fuel: !!fuelShown},
				{menu: last(env, 'menu'), phone: last(env, 'phone'), fuel: last(env, 'fuel')});
			break;
		}
	}
	check(ok, '40 mixed clicks: the last report of every view always matches the screen');
}


//== Timeline for tests/ui_replay.lua ==
// Random clicks on the real menu and phone (waits of 0.3 to 12 s cross the 2 s reports and the
// 5 s lease); every engineLua call with its time and what is on screen after each step.
if (process.argv[2]) {
	const env = makeEnv({sharedCareerMenuCollapsed: '1'});
	const menu = load('client/ui/modules/apps/SharedCareer-Menu/app.js', 'SharedCareerMenu', env);
	const phone = load('client/ui/modules/apps/SharedCareer-Phone/app.js', 'SharedCareerPhone', env);
	phone.emit('SharedCareerPhone', {enabled: true, apps: [{id: 'tow'}, {id: 'fuel'}]});
	const out = [];
	let mark = 0;
	function snap() {
		const calls = env.calls.slice(mark); mark = env.calls.length;
		out.push({t: env.now / 1000, calls, screen: {menu: !menu.collapsed, phone: phone.open,
			fuel: !!(phone.open && phone.currentApp && phone.currentApp.id === 'fuel')}});
	}
	snap();
	let seed = 12345;
	function rnd(n) { seed = (seed * 1103515245 + 12345) % 2147483648; return seed % n; }
	const actions = [() => menu.toggleCollapsed(), () => menu.emit('SharedCareerToggle'), () => phone.toggle(),
		() => phone.emit('SharedCareerPhoneToggle'), () => { if (phone.open) phone.openApp({id: 'fuel'}); },
		() => { if (phone.open) phone.openApp({id: 'tow'}); }, () => { if (phone.open) phone.homeBar(); },
		() => {}, () => {}];
	for (let i = 0; i < 300; i++) {
		// wait 0.3 to 12 s (long waits cross the 2 s reports and the 5 s lease), then click
		const wait = 300 + rnd(11700);
		const end = env.now + wait;
		while (env.now + 100 <= end) { env.advance(100); snap(); }
		env.advance(end - env.now);
		actions[rnd(actions.length)]();
		snap();
	}
	require('fs').writeFileSync(process.argv[2], JSON.stringify(out));
}

//== Icons: all in ui/sharedCareer/icons.svg, used by name ==
{
	const fs = require('fs');
	const read = (f) => fs.readFileSync(require('path').join(__dirname, '..', f), 'utf8');
	const sprite = read('client/ui/sharedCareer/icons.svg');
	const icons = [...sprite.matchAll(/<symbol id="sc-icon-([a-z-]+)" viewBox="0 0 24 24">/g)].map(m => m[1]);
	check(icons.length === (sprite.match(/<symbol/g) || []).length && new Set(icons).size === icons.length,
		'icons.svg: every symbol named sc-icon-<name> in a 24x24 box, each name once');
	const pages = [
		read('client/ui/modules/apps/SharedCareer-Menu/app.html'),
		read('client/ui/modules/apps/SharedCareer-Phone/phone.html'),
	];
	check(pages.every(h => h.includes('ng-include="\'/ui/sharedCareer/icons.svg\'"')), 'both apps load icons.svg');
	// replace: true needs exactly one root element: nothing (not even a comment) before or after it
	check(pages.every(h => /^<div\b/.test(h) && /<\/div>\s*$/.test(h)),
		'menu and phone templates are one root <div>, nothing before or after it');
	// every app screen is loaded into the .scp-appscreen slot, else it is not given a height and cannot scroll
	check((pages[1].match(/ng-include="appScreen\(\)"/g) || []).length === 1
		&& /<div class="scp-appscreen" ng-if="appScreen\(\)" ng-include="appScreen\(\)">/.test(pages[1]),
		'phone.html: the app screens are loaded into one .scp-appscreen slot (so they scroll)');
	// the phone's remote (shared/remote.html), in the Tow and Straps app templates
	const phoneDir = 'client/ui/modules/apps/SharedCareer-Phone/';
	const appTemplates = ['jobs', 'tow', 'straps', 'fuel'].map(name => read(phoneDir + 'apps/' + name + '.html'));
	const phoneScript = read(phoneDir + 'app.js');
	const remote = read(phoneDir + 'shared/remote.html');
	const segmentSelect = read(phoneDir + 'shared/segment-select.html');
	check((appTemplates.join('').match(/ng-include="'\/ui\/modules\/apps\/SharedCareer-Phone\/shared\/remote.html'"/g) || []).length === 2
		&& !appTemplates.join('').includes('scp-pad-key'), 'the Tow and Straps apps share one remote (remote.html)');
	check(!appTemplates[0].includes('<scp-segment-select')
		&& appTemplates[3].includes('<scp-segment-select options="fuelSorts" selected="fuelSort"')
		&& phoneScript.includes("directive('scpSegmentSelect'")
		&& phoneScript.includes('shared/segment-select.html')
		&& segmentSelect.includes('ng-repeat="option in options track by option.id"')
		&& !appTemplates.join('').includes('scp-seg-'),
		'Fuel passes only its options to the shared segment select; it draws the buttons (Jobs has a start page instead)');
	check(appTemplates[0].includes('ng-if="jobs.enabled && jobLicenseMissing()"')
		&& appTemplates[0].includes("'scp-jobsection-nolicense': jobLicenseMissing()")
		&& appTemplates[0].includes("!jobs.active && !jobLicenseMissing()\"")
		&& appTemplates[0].includes('ng-click="licenseRoute()"'),
		'Jobs app without the license: a bar with the route, the jobs greyed out, no "Take job"');
	pages.push(remote, segmentSelect, ...appTemplates, read(phoneDir + 'apps/settings.html'));
	// an icon by its name: <svg><use href="#sc-icon-car"/></svg> in the menu, <scp-icon name="car"> on the phone
	const used = pages.flatMap(h => [...h.matchAll(/href="#sc-icon-([a-z-]+)"|<scp-icon[^>]*\sname="([a-z-]+)"/g)]
		.map(m => m[1] || m[2]));
	const missing = used.filter(n => !icons.includes(n));
	check(used.length > 30 && missing.length === 0, 'every icon the apps use is in icons.svg ' + missing.join(','));
	// no icon drawn inline in an app: an <svg> there only holds a <use> (the rope is a drawing, not an icon)
	const inline = pages.flatMap(h => [...h.matchAll(/<svg[^>]*>([\s\S]*?)<\/svg>/g)].map(m => m[1]))
		.filter(b => !/^<use(?:\s[^>]*)?\/>$/.test(b.trim()) && !b.includes('scp-rope-path'));
	check(inline.length === 0, 'no icon drawn inline in phone or app templates (' + inline.length + ')');
	// the icon names Lua sends: the apps on the phone, the job types, the kinds of vehicle of a towing job
	const lua = ['jobs', 'tow', 'straps', 'fuel', 'towJobs', 'taxiJobs', 'phone'].map(f => read('client/lua/ge/extensions/sharedCareer/' + f + '.lua'));
	const kinds = lua[4].match(/local KINDS = \{([\s\S]*?)\n\}/)[1];
	const names = lua.flatMap(l => [...l.matchAll(/icon = "([a-z-]+)"/g)].map(m => m[1]))
		.concat([...kinds.matchAll(/kind = "([a-z-]+)"/g)].map(m => m[1]), ['car']);
	const unknown = names.filter(n => !icons.includes(n));
	check(names.length >= 11 && unknown.length === 0, 'every icon name from Lua is in icons.svg ' + unknown.join(','));
	// in the window: an icon by name, text for a name without one ("T" of an app)
	const env = makeEnv({});
	const phone = load(...PHONE, env);
	const screenIds = ['jobs', 'tow', 'straps', 'fuel', 'settings'];
	const screens = screenIds.map(id => { phone.openApp({id: id}); return phone.appScreen(); });
	phone.openApp({id: 'radio'});
	check(screens.every((s, i) => s === '/ui/modules/apps/SharedCareer-Phone/apps/' + screenIds[i] + '.html'
		&& fs.existsSync(require('path').join(__dirname, '../client', s))) && phone.appScreen() === null,
		'the built-in apps load their screen (apps/<id>.html); an app without one gets none');
	// Settings: the wallpaper and the app icons, kept on this PC; a stored id that is gone falls back to the first
	const css = read(phoneDir + 'app.css');
	check(phone.WALLPAPERS.every(w => fs.existsSync(require('path').join(__dirname, '../client/ui/sharedCareer/wallpapers', w.id + '.svg')))
		&& phone.ICON_THEMES.every(t => css.includes('.scp-app-icon-' + t.id + ' {')),
		'Settings: every wallpaper is a file in wallpapers/, every icon theme has its style in app.css');
	check(phone.look.wallpaper === 'ember' && phone.look.icons === 'beamng'
		&& phone.wallpaperStyle()['background-image'] === 'url(/ui/sharedCareer/wallpapers/ember.svg)'
		&& phone.appIconClass() === 'scp-app-icon-beamng' && !phone.appIconStyle({color: '#123456'}).background,
		'Settings: by default the Ember wallpaper and BeamNG icons (orange, not the app\'s color)');
	phone.setWallpaper('dusk');
	phone.setIconTheme('colors');
	check(env.storage.sharedCareerPhoneWallpaper === 'dusk' && env.storage.sharedCareerPhoneIcons === 'colors'
		&& phone.appIconStyle({color: '#123456'}).background === '#123456' && phone.appIconClass('dark') === 'scp-app-icon-dark',
		'Settings: the choice is stored; "Colors" shows each app in its own color');
	const again = load(...PHONE, makeEnv({sharedCareerPhoneWallpaper: 'dusk', sharedCareerPhoneIcons: 'neon'}));
	check(again.look.wallpaper === 'dusk' && again.look.icons === 'beamng', 'Settings: read back on start; an unknown theme falls back to BeamNG');
	phone.setWallpaper('nope');
	check(phone.look.wallpaper === 'ember', 'Settings: an unknown wallpaper falls back to the first');
	const icon = env.directives.scpIcon;
	check(icon.template(null, {name: 'car'}) === '<svg class="scp-icon" aria-hidden="true"><use href="#sc-icon-car"/></svg>'
		&& icon.template(null, {name: '{{ j.icon }}'}).includes('<use ng-attr-href="#sc-icon-{{ j.icon }}"/>'),
		'<scp-icon>: an icon by its name, or by a name from Lua');
	check(phone.hasIcon('tow') && phone.hasIcon('car') && !phone.hasIcon('T') && !phone.hasIcon('') && !phone.hasIcon(undefined),
		'hasIcon: true for an icon in icons.svg, false for anything else');
}

//== Speed limit sign (SharedCareer-SpeedLimit, data from speedLimit.lua) ==
{
	const read = (f) => require('fs').readFileSync(require('path').join(__dirname, '..', f), 'utf8');
	const html = read('client/ui/modules/apps/SharedCareer-SpeedLimit/app.html');
	check(/^<div\b/.test(html) && /<\/div>\s*$/.test(html), 'sign template: one root <div>, nothing before or after it');
	const env = makeEnv({});
	const sign = load('client/ui/modules/apps/SharedCareer-SpeedLimit/app.js', 'SharedCareerSpeedLimit', env);
	check(env.calls.some(c => c.indexOf('sharedCareer_speedLimit.uiRequest()') >= 0) && !sign.sign.limit,
		'the sign asks Lua for the limit when it opens; nothing shown before');
	sign.emit('SharedCareerSpeedLimit', {limit: 50, unit: 'km/h', over: false});
	check(sign.sign.limit === 50 && sign.sign.unit === 'km/h', 'a limit: shown in its unit');
	sign.emit('SharedCareerSpeedLimit', {limit: 35, unit: 'mph', over: true});
	check(sign.sign.unit === 'mph' && sign.sign.over === true, 'mph, too fast: the US sign warns');
	sign.emit('SharedCareerSpeedLimit', {});
	check(!sign.sign.limit, 'no limit (off the road, on foot): no sign');
}

process.exit(H.done() ? 1 : 0);
