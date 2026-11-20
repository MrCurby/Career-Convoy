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
	phone.emit('SharedCareerPhone', {enabled: false, apps: []});
	check(!phone.open && last(env, 'phone') === false && last(env, 'fuel') === false, 'phone switched off by the server: not visible');

	// fuel data: false keeps the list, a table replaces it, missing = no stations
	phone.emit('SharedCareerState', {hour: 10, connected: true, fuel: {stations: [{id: 'a'}]}});
	check(phone.fuel && phone.fuel.stations.length === 1, 'fuel list taken');
	phone.emit('SharedCareerState', {hour: 10, connected: true, fuel: false});
	check(phone.fuel && phone.fuel.stations.length === 1, 'fuel = false (app closed): the last list stays');
	phone.emit('SharedCareerState', {hour: 11, connected: true});
	check(phone.fuel === null && phone.time === 11, 'no fuel (map without stations): empty list; time updated');
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
	let calls = env.calls.length;
	phone.towCall('uiHookOn()');
	phone.nudge(1, 0, 0);
	phone.nudgeStop();
	check(env.calls.slice(calls).join(' ').includes('sharedCareer_tow.uiHookOn()')
		&& env.calls.slice(calls).join(' ').includes('sharedCareer_tow.uiNudgeStop()'), 'Tow app: calls go to tow.lua');
	// Straps app: steps by hand, the straps' load as dots, calls to straps.lua
	phone.emit('SharedCareerStraps', {allowed: true, step: 1});
	check(Array.isArray(phone.straps.straps) && phone.strapStepText() === '1. Aim at the car', 'Straps app: step 1, aim at the car');
	phone.emit('SharedCareerStraps', {allowed: true, step: 2, aimed: true, tooFar: true, straps: []});
	check(phone.strapStepText() === '2. Aim at the truck or trailer' && phone.straps.tooFar, 'step 2: aim at the truck; too far');
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
	check(phone.segStyle(9).background === '#ff3b30' && phone.ropeState().text === 'High load',
		'winch at its limit: all segments red; rope under high load');
	phone.emit('SharedCareerTow', {allowed: true, attached: true, slack: false, winch: 0, strain: 0.2, ropeLoad: 0.8});
	check(phone.ropeState().cls === 'scp-rope-critical', 'rope near breaking: the critical chip');
	phone.emit('SharedCareerTow', {allowed: true, attached: true, slack: false, winch: -1, strain: 0, ropeLoad: 0.2});
	check(phone.winchText() === 'Paying out' && !phone.segStyle(0).background, 'paying out: the winch gives way, no load shown');
	phone.emit('SharedCareerTow', {allowed: true, attached: true, slack: true, winch: 0, strain: 0.3, ropeLoad: 0});
	check(!phone.segStyle(0).background && phone.winchText() === 'Locked' && phone.ropeState().text === 'Slack',
		'winch stopped: "Locked", empty segments; rope "Slack"');
	// Jobs app (beta): list, your job, the steps; the strip above the Tow and Straps apps opens it. What a job shows
	// comes from its job type (jobs.lua appState); the window only lays it out.
	phone.emit('SharedCareerPhone', {enabled: true, apps: [{id: 'jobs', title: 'Jobs', beta: true}, {id: 'tow'}, {id: 'fuel'}]});
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
	phone.emit('SharedCareerJobs', {enabled: true, sections: [{type: 'x'}]});
	check(phone.jobs.sections[0].groups.length === 0 && phone.jobs.open === 0, 'nothing sent: empty lists');
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
	phone.openApp({id: 'straps'});
	const inStraps = phone.jobStripShown();
	phone.openApp({id: 'fuel'});
	check(inStraps && !phone.jobStripShown(), 'the job strip: above the Tow and Straps apps, not in Fuel');
	phone.goHome();
	phone.emit('SharedCareerJobs', {enabled: true, jobs: [], active: active({phase: 'checking', step: 1})});
	check(phone.jobText() === 'Handing over…', 'handed over: waiting for the server');
	phone.emit('SharedCareerJobs', {enabled: true, jobs: [], active: active({phase: 'paid', step: 2})});
	check(phone.jobStep() === 2 && phone.jobPaid() && phone.jobText().indexOf('Done') === 0, 'step 3: paid');
	phone.openJobs();
	check(phone.currentApp && phone.currentApp.id === 'jobs' && phone.currentApp.beta === true, 'the job strip opens the Jobs app (beta)');
	phone.goHome();
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

process.exit(H.done() ? 1 : 0);
