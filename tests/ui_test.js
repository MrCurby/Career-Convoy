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
