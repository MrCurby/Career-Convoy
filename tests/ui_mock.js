// SharedCareer :: stand-ins for AngularJS, bngApi, timers, localStorage and window events, so the
// menu and phone controllers (ui/modules/apps/…/app.js) run in node, outside the game.
// Used by tests/ui_test.js.
const fs = require('fs');
const path = require('path');
const ROOT = path.join(__dirname, '..');
let failed = 0, passed = 0;
function check(ok, msg) { if (ok) passed++; else { failed++; console.log('FAILED: ' + msg); } }

function makeEnv(storage) {
	const env = {calls: [], timers: [], now: 0, listeners: {}, storage: Object.assign({}, storage || {})};
	env.bngApi = {engineLua: (s) => env.calls.push(s)};
	env.setInterval = (fn, ms) => { const t = {fn, ms, next: env.now + ms, interval: true, alive: true}; env.timers.push(t); return t; };
	env.setTimeout = (fn, ms) => { const t = {fn, ms, next: env.now + (ms || 0), interval: false, alive: true}; env.timers.push(t); return t; };
	env.clearInterval = env.clearTimeout = (t) => { if (t) t.alive = false; };
	env.advance = (ms) => {
		const end = env.now + ms;
		for (;;) {
			const due = env.timers.filter(t => t.alive && t.next <= end).sort((a, b) => a.next - b.next)[0];
			if (!due) break;
			env.now = due.next;
			if (due.interval) due.next += due.ms; else due.alive = false;
			due.fn();
		}
		env.now = end;
	};
	env.window = {
		localStorage: {getItem: (k) => (k in env.storage ? env.storage[k] : null), setItem: (k, v) => { env.storage[k] = String(v); }},
		addEventListener: (n, f) => { (env.listeners[n] = env.listeners[n] || []).push(f); },
		removeEventListener: (n, f) => { env.listeners[n] = (env.listeners[n] || []).filter(x => x !== f); },
		dispatchEvent: (ev) => { (env.listeners[ev.type] || []).slice().forEach(f => f(ev)); return true; },
	};
	env.CustomEvent = function (type, init) { this.type = type; this.detail = init && init.detail; };
	env.icons = ['tow', 'jobs', 'car'];
	env.document = {body: {appendChild: () => {}},
		getElementById: (id) => (env.icons.some(n => id === 'sc-icon-' + n) ? {id} : null)};
	return env;
}

function makeScope() {
	const handlers = {};
	const scope = {
		$on: (n, f) => { (handlers[n] = handlers[n] || []).push(f); },
		$evalAsync: (f) => f(),
		$$destroyed: false,
		emit: (n, data) => (handlers[n] || []).forEach(f => f({}, data)),
		destroy: () => { scope.$$destroyed = true; (handlers.$destroy || []).forEach(f => f()); },
	};
	return scope;
}

function load(file, ctrlName, env, root) {
	let controller = null;
	const angular = {module: () => ({
		directive: () => {},
		controller: (name, arr) => { if (name === ctrlName) controller = arr[arr.length - 1]; },
	})};
	const src = fs.readFileSync(path.join(root || ROOT, file), 'utf8');
	new Function('angular', 'bngApi', 'window', 'setInterval', 'setTimeout', 'clearInterval', 'clearTimeout',
		'CustomEvent', 'document', src)(angular, env.bngApi, env.window, env.setInterval, env.setTimeout,
		env.clearInterval, env.clearTimeout, env.CustomEvent, env.document);
	const scope = makeScope();
	const element = [{querySelector: () => null}];
	controller(scope, element);
	return scope;
}

// all uiVisible reports so far, as [view, bool]
function reports(env, from) {
	return env.calls.slice(from || 0).map(c => c.match(/sharedCareer_menu\.uiVisible\("(\w+)", (true|false)\)/))
		.filter(Boolean).map(m => [m[1], m[2] === 'true']);
}
function last(env, view) {
	const r = reports(env).filter(x => x[0] === view);
	return r.length ? r[r.length - 1][1] : undefined;
}

module.exports = {makeEnv, load, reports, last, check, done: () => {
	console.log(`UI: ${passed} ok, ${failed} failed`);
	return failed;
}};
