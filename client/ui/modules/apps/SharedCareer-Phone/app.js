// SharedCareer Phone: a tab at the right screen edge (key F4) that takes the phone out.
// The phone shows the server time, the number of players, the connection and the apps that
// SharedCareer extensions registered (lua/ge/extensions/sharedCareer/phone.lua). Built-in app
// screens: Jobs (beta, jobs.lua with its job types, for now towJobs.lua), Tow (rope and winch, tow.lua), Straps (ratchet straps,
// straps.lua) and Fuel (gas station prices, fuel.lua). Apps marked beta get a "BETA" badge on the icon and in the title bar.
// The home screen has, below the clock, how long until day or night (with a bar for the part
// of it that is over), and the app icons.
//
// Data: guihook "SharedCareerPhone" {enabled, apps} from phone.lua, "SharedCareerState" (time,
// players, connection, fuel prices) from menu.lua every second, "SharedCareerTow" from tow.lua and
// "SharedCareerStraps" from straps.lua while their app is open, "SharedCareerJobs" (jobs and your
// job) from jobs.lua, "SharedCareerPhoneToggle" from the key, "SharedCareerPhoneAway" (a game menu
// is open: the phone goes away, the key does not take it out there).
// menu.lua only sends "SharedCareerState" while someone looks: the phone reports "phone" (out)
// and "fuel" (Fuel app open) with sharedCareer_menu.uiVisible on every change and every 2 s.
// Opening the phone collapses the menu and the other way round (window event
// "sharedCareerPanelOpen").
//
// Note: only var/function at the top level – the game evaluates app.js again in the same
// scope when the apps are reloaded.

var sharedCareerPhoneApp = angular.module('beamng.apps');

sharedCareerPhoneApp.directive('sharedCareerPhone', [function () {
	return {
		templateUrl: '/ui/modules/apps/SharedCareer-Phone/app.html',
		replace: true,
		restrict: 'EA',
		scope: true
	};
}]);

sharedCareerPhoneApp.controller('SharedCareerPhone', ['$scope', '$element', function ($scope, $element) {
	$scope.enabled = true;
	$scope.open = false;
	$scope.apps = [];
	$scope.currentApp = null;
	$scope.time = null;
	$scope.connected = false;

	function lua(cmd) {
		bngApi.engineLua('if sharedCareer_phone then sharedCareer_phone.' + cmd + ' end');
	}

	// attach the phone to <body> after linking (like the menu's dialog host), remove it on close
	var host = null;
	setTimeout(function () {
		try {
			host = $element[0].querySelector('.scp-host');
			if (host && !$scope.$$destroyed) document.body.appendChild(host);
		} catch (e) {}
	}, 0);
	$scope.$on('$destroy', function () {
		if (host && host.parentNode) host.parentNode.removeChild(host);
	});

	// Tells Lua what is visible: the phone, and the Fuel app on it (see menu.lua uiVisible).
	function reportView(view, visible) {
		bngApi.engineLua('if sharedCareer_menu then sharedCareer_menu.uiVisible("' + view + '", ' + (visible ? 'true' : 'false') + ') end');
	}
	function fuelOpen() { return $scope.open && !!$scope.currentApp && $scope.currentApp.id === 'fuel'; }
	function reportViews() {
		reportView('phone', $scope.open);
		reportView('fuel', fuelOpen());
	}
	var viewTimer = setInterval(function () { if ($scope.open) reportViews(); }, 2000);
	$scope.$on('$destroy', function () {
		clearInterval(viewTimer);
		reportView('phone', false);
		reportView('fuel', false);
	});

	function closeApp() {
		if ($scope.currentApp) lua('uiCloseApp(' + JSON.stringify(String($scope.currentApp.id)) + ')');
		$scope.currentApp = null;
		reportView('fuel', false);
	}
	function setOpen(value) {
		$scope.open = value;
		if (!value) closeApp();
		reportViews();
		if (value) {
			try { window.dispatchEvent(new CustomEvent("sharedCareerPanelOpen", {detail: "phone"})); } catch (e) {}
		}
	}
	$scope.toggle = function () { setOpen(!$scope.open); };
	function onOtherOpened(ev) {
		if (ev && ev.detail !== "phone" && $scope.open) $scope.$evalAsync(function () { setOpen(false); });
	}
	window.addEventListener("sharedCareerPanelOpen", onOtherOpened);
	$scope.$on('$destroy', function () { window.removeEventListener("sharedCareerPanelOpen", onOtherOpened); });

	$scope.openApp = function (app) {
		closeApp();
		$scope.currentApp = app;
		lua('uiOpenApp(' + JSON.stringify(String(app.id)) + ')');
		if (fuelOpen()) reportView('fuel', true);
	};
	$scope.goHome = function () { closeApp(); };
	$scope.homeBar = function () {
		if ($scope.currentApp) closeApp(); else setOpen(false);
	};

	//== Tow app (lua/ge/extensions/sharedCareer/tow.lua) ==
	$scope.tow = {allowed: true, attached: false, nearby: []};
	$scope.towCall = function (cmd) {
		bngApi.engineLua('if sharedCareer_tow then sharedCareer_tow.' + cmd + ' end');
	};
	var nudging = false;
	$scope.nudge = function (f, r, u) {
		nudging = true;
		$scope.towCall('uiNudge(' + f + ',' + r + ',' + u + ')');
	};
	$scope.nudgeStop = function () {
		if (nudging) { nudging = false; $scope.towCall('uiNudgeStop()'); }
	};
	$scope.meters = function (v) { return typeof v === 'number' ? v.toFixed(1) + ' m' : '–'; };
	$scope.strainText = function (s) {
		s = s || 0;
		if (s < 0.6) return 'Easy';
		if (s < 0.9) return 'Working hard';
		return 'At the limit';
	};
	// the winch's load while it hauls in, as 10 segments, green -> yellow -> orange, red at the limit;
	// stopped the drum is locked (the rope holds like a tow rope), paying out it gives way
	$scope.winchText = function () {
		var t = $scope.tow;
		if (t.winch === 1) return $scope.strainText(t.strain);
		return t.winch === -1 ? 'Paying out' : 'Locked';
	};
	$scope.winchSegs = new Array(10);
	var SEG_COLORS = ['#4cd964', '#4cd964', '#4cd964', '#8fdc4a', '#c8d93a', '#ffcc00', '#ffcc00', '#ffa020', '#ff8a20', '#ff6a1a'];
	$scope.segStyle = function (i) {
		var s = $scope.tow.winch === 1 ? ($scope.tow.strain || 0) : 0;
		if (s * 10 <= i) return {};
		return {'background': s >= 0.95 ? '#ff3b30' : SEG_COLORS[i]};
	};
	// the rope's load (share of its breaking load), in words
	$scope.ropeState = function () {
		var t = $scope.tow;
		if (t.slack) return {text: 'Slack', cls: 'scp-rope-slack'};
		var l = t.ropeLoad || 0;
		if (l < 0.4) return {text: 'OK', cls: 'scp-rope-ok'};
		if (l < 0.7) return {text: 'High load', cls: 'scp-rope-high'};
		return {text: 'Near breaking!', cls: 'scp-rope-critical'};
	};
	// the rope strip at the top: the rope sags while slack and is straight when taut
	$scope.ropePath = function () {
		return $scope.tow.slack ? 'M0 13 Q50 29 100 13' : 'M0 13 L100 13';
	};
	// marks run along the rope while the winch turns (not while it is stuck at its limit)
	$scope.ropeRunning = function () {
		var t = $scope.tow;
		return t.winch === -1 || (t.winch === 1 && !(t.strain >= 0.95));
	};

	//== Straps app (lua/ge/extensions/sharedCareer/straps.lua) ==
	$scope.straps = {allowed: true, step: 0, straps: []};
	$scope.strapsCall = function (cmd) {
		bngApi.engineLua('if sharedCareer_straps then sharedCareer_straps.' + cmd + ' end');
	};
	// adding a strap by hand: what to aim at
	$scope.strapStepText = function () {
		return $scope.straps.step === 2 ? '2. Aim at the truck or trailer' : '1. Aim at the car';
	};
	// a strap's load as a colored dot: green, yellow, red near breaking; grey when slack
	$scope.strapDot = function (s) {
		if (s.slack) return 'scp-dot-slack';
		if (s.load < 0.4) return 'scp-dot-ok';
		return s.load < 0.7 ? 'scp-dot-high' : 'scp-dot-critical';
	};
	$scope.$on('SharedCareerStraps', function (event, data) {
		$scope.$evalAsync(function () {
			if (!data) return;
			if (!Array.isArray(data.straps)) data.straps = [];
			$scope.straps = data;
		});
	});
	//== Fuel app (lua/ge/extensions/sharedCareer/fuel.lua, data with "SharedCareerState") ==
	var SORT_KEY = "sharedCareerFuelSort";
	$scope.fuel = null;
	$scope.fuelSort = "gasoline";
	try { $scope.fuelSort = window.localStorage.getItem(SORT_KEY) || "gasoline"; } catch (e) {}
	$scope.setFuelSort = function (s) {
		$scope.fuelSort = s;
		try { window.localStorage.setItem(SORT_KEY, s); } catch (e) {}
	};
	// fuel type whose price is highlighted (gasoline for "Nearest")
	$scope.mainFuel = function () { return $scope.fuelSort === 'diesel' ? 'diesel' : 'gasoline'; };
	$scope.stations = function () {
		var f = $scope.fuel;
		if (!f || !f.stations) return [];
		var list = f.stations.slice();
		var sort = $scope.fuelSort;
		list.sort(function (a, b) {
			if (sort === 'distance') {
				return (a.distance === undefined ? 1e12 : a.distance) - (b.distance === undefined ? 1e12 : b.distance);
			}
			var pa = a.fuels[sort] ? a.fuels[sort].price : 1e12, pb = b.fuels[sort] ? b.fuels[sort].price : 1e12;
			return pa - pb;
		});
		return list;
	};
	$scope.formatPrice = function (p) { return "$" + Number(p.price).toFixed(2) + "/" + p.unit; };
	$scope.formatDistance = function (m) { return m < 1000 ? Math.round(m) + " m" : (m / 1000).toFixed(1) + " km"; };
	function fuelLua(cmd) { bngApi.engineLua('if sharedCareer_fuel then sharedCareer_fuel.' + cmd + ' end'); }
	$scope.navigate = function (id) { fuelLua('uiNavigate(' + JSON.stringify(String(id)) + ')'); };
	$scope.stopNavigate = function () { fuelLua('uiStopNavigate()'); };

	//== Jobs app (lua/ge/extensions/sharedCareer/jobs.lua) ==
	// What a job shows (icon, tags, steps, the texts of what to do now) comes from its job type
	// (towJobs.lua: towing jobs); this window only lays it out.
	$scope.jobs = {enabled: false, sections: [], open: 0, active: null};
	$scope.jobsCall = function (cmd) {
		bngApi.engineLua('if sharedCareer_jobs then sharedCareer_jobs.' + cmd + ' end');
	};
	$scope.money = function (v) { return '$' + Math.round(Number(v) || 0).toLocaleString('en-US'); };
	// the XP a job gives, under its pay ('' without any)
	$scope.xpText = function (v) { var xp = Math.round(Number(v) || 0); return xp > 0 ? '+' + xp + ' XP' : ''; };
	// your level in a job type, in words ("Level 4 · 200 XP to level 5")
	$scope.levelText = function (l) {
		if (!l) return '';
		if (l.toGo === undefined || l.toGo === null) return 'Level ' + l.level + ' · top level';
		return 'Level ' + l.level + ' · ' + l.toGo + ' XP to level ' + (l.level + 1);
	};
	// your level as a ring: the part that is filled shows the way to the next level
	$scope.levelRing = function (l) {
		var deg = Math.round(360 * Math.max(0, Math.min(1, Number(l && l.share) || 0)));
		return 'conic-gradient(#4f8cff ' + deg + 'deg, rgba(255, 255, 255, 0.12) ' + deg + 'deg)';
	};
	// a job's tags in one line, for the list ("Engine failure · Flat tire")
	$scope.tagLine = function (j) {
		return (j.tags || []).map(function (t) { return t.text; }).join(' · ');
	};
	// the step of your job (0-based, into its steps); the last one is "paid"
	$scope.jobStep = function () {
		var a = $scope.jobs.active;
		return a ? (a.step || 0) : 0;
	};
	$scope.jobPaid = function () { return !!$scope.jobs.active && $scope.jobs.active.phase === 'paid'; };
	$scope.jobText = function () {
		var a = $scope.jobs.active;
		if (!a) return '';
		if (a.phase === 'paid') return 'Done – paid';
		if (a.phase === 'checking') return 'Handing over…';
		return a.text || '';
	};
	// short, for the job strip above the Tow and Straps apps
	$scope.jobStepText = function () {
		var a = $scope.jobs.active;
		return a ? (a.short || '') : '';
	};
	// the job strip above the Tow and Straps apps, while you are on the way to the shop
	$scope.jobStripShown = function () {
		var id = $scope.currentApp && $scope.currentApp.id;
		return (id === 'tow' || id === 'straps') && !!$scope.jobs.active && !$scope.jobPaid();
	};
	$scope.openJobs = function () { var app = appById('jobs'); if (app) $scope.openApp(app); };
	$scope.$on('SharedCareerJobs', function (event, data) {
		$scope.$evalAsync(function () {
			if (!data) return;
			var active = data.active || null;
			if (active) {
				if (!Array.isArray(active.steps)) active.steps = [];
				if (!Array.isArray(active.tags)) active.tags = [];
			}
			var sections = Array.isArray(data.sections) ? data.sections : [];
			sections.forEach(function (sec) {
				if (!Array.isArray(sec.groups)) sec.groups = [];
				sec.groups.forEach(function (g) { if (!Array.isArray(g.jobs)) g.jobs = []; });
			});
			$scope.jobs = {enabled: data.enabled === true, sections: sections, open: Number(data.open) || 0, active: active};
		});
	});

	$scope.$on('SharedCareerTow', function (event, data) {
		$scope.$evalAsync(function () {
			if (!data) return;
			if (!Array.isArray(data.nearby)) data.nearby = [];
			if (!Array.isArray(data.strengths)) data.strengths = [];
			$scope.tow = data;
		});
	});

	function pad(n) { return (n < 10 ? '0' : '') + n; }
	$scope.clock = function () {
		var h = $scope.time;
		if (typeof h !== 'number' || isNaN(h)) return '--:--';
		var total = Math.floor(((h % 24) + 24) % 24 * 60);
		return pad(Math.floor(total / 60)) + ':' + pad(total % 60);
	};
	// below the big clock: "Night in 23 min", "Day · paused", ...
	$scope.dayText = function () {
		var t = $scope.timeInfo;
		if (!$scope.connected) return 'Not connected';
		if (!t || typeof t.isDay !== 'boolean') return 'SharedCareer';
		var phase = t.isDay ? 'Day' : 'Night';
		if (t.paused) return phase + ' · paused';
		if (typeof t.secondsToSwitch !== 'number') return phase + ' on the server';
		var min = Math.max(0, Math.round(t.secondsToSwitch / 60));
		return (t.isDay ? 'Night' : 'Day') + ' in ' + (min < 1 ? '< 1' : min) + ' min';
	};
	// share of the current day or night that is over (0..1), or null
	$scope.phaseProgress = function () {
		var t = $scope.timeInfo;
		if (!$scope.connected || !t || typeof t.isDay !== 'boolean' || typeof $scope.time !== 'number'
			|| typeof t.dayStart !== 'number' || typeof t.nightStart !== 'number') return null;
		var start = t.isDay ? t.dayStart : t.nightStart, end = t.isDay ? t.nightStart : t.dayStart;
		var length = ((end - start) % 24 + 24) % 24;
		if (length <= 0) return null;
		return Math.max(0, Math.min(1, ((($scope.time - start) % 24 + 24) % 24) / length));
	};
	$scope.playerCount = function () { return $scope.players; };

	function appById(id) {
		for (var i = 0; i < $scope.apps.length; i++) if ($scope.apps[i].id === id) return $scope.apps[i];
		return null;
	}

	$scope.$on('SharedCareerPhone', function (event, data) {
		$scope.$evalAsync(function () {
			if (!data) return;
			$scope.enabled = data.enabled !== false;
			$scope.apps = Array.isArray(data.apps) ? data.apps : [];
			if (!$scope.enabled) setOpen(false);
		});
	});
	$scope.$on('SharedCareerPhoneToggle', function () {
		$scope.$evalAsync(function () { if ($scope.enabled) setOpen(!$scope.open); });
	});
	$scope.$on('SharedCareerPhoneAway', function () {
		$scope.$evalAsync(function () { if ($scope.open) setOpen(false); });
	});
	$scope.$on('SharedCareerState', function (event, data) {
		$scope.$evalAsync(function () {
			if (!data) return;
			$scope.time = typeof data.hour === 'number' ? data.hour : null;
			$scope.timeInfo = {isDay: data.isDay, paused: data.paused === true, secondsToSwitch: data.secondsToSwitch,
				dayStart: data.dayStart, nightStart: data.nightStart};
			$scope.connected = data.connected === true;
			var list = data.players && Array.isArray(data.players.list) ? data.players.list : null;
			$scope.players = list ? list.length : '–';
			// fuel is false while the Fuel app is closed: keep the last list until fresh prices arrive
			if (data.fuel !== false) $scope.fuel = data.fuel || null;
		});
	});

	lua('uiRequest()');
	reportViews();
}]);
