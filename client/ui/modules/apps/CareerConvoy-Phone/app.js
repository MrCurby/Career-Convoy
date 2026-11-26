// Career-Convoy Phone: a tab at the right screen edge (key F4) that takes the phone out.
// The phone shows the server time, the number of players, the connection and the apps that
// Career-Convoy extensions registered (lua/ge/extensions/careerConvoy/phone.lua). Built-in app
// screens: Jobs (jobs.lua with its job types: towJobs.lua, taxiJobs.lua), Tow (rope and winch, tow.lua), Straps (ratchet straps,
// straps.lua), Fuel (gas station prices, fuel.lua), Apps (install and remove apps, kept by phone.lua)
// and Settings (wallpaper and app icons, kept on this PC).
// The home screen has, below the clock, how long until day or night (with a bar for the part
// of it that is over), and the app icons.
//
// Data: guihook "CareerConvoyPhone" {enabled, apps} from phone.lua, "CareerConvoyState" (time,
// players, connection, fuel prices) from menu.lua every second, "CareerConvoyTow" from tow.lua and
// "CareerConvoyStraps" from straps.lua while their app is open, "CareerConvoyJobs" (jobs and your
// job) from jobs.lua, "CareerConvoyPhoneToggle" from the key, "CareerConvoyPhoneAway" (a game menu
// is open: the phone goes away, the key does not take it out there), "CareerConvoyPhoneCall" (a
// call rings, phone.lua ring: the phone comes out and shows it until it is answered).
// menu.lua only sends "CareerConvoyState" while someone looks: the phone reports "phone" (out)
// and "fuel" (Fuel app open) with careerConvoy_menu.uiVisible on every change and every 2 s.
// Opening the phone collapses the menu and the other way round (window event
// "careerConvoyPanelOpen").
//
// Files: app.json registers the BeamNG UI app; phone.html is the template (the phone's shell),
// apps/<name>.html the screens of the built-in apps, shared/ the parts they share (segment-select.html:
// a row of buttons to pick one, directive scpSegmentSelect below; remote.html: the rope remote),
// app.css the styles. phone.html must have exactly one root element (replace: true below), with
// nothing before it.
//
// Note: only var/function at the top level – the game evaluates app.js again in the same
// scope when the apps are reloaded.

var careerConvoyPhoneApp = angular.module('beamng.apps');

careerConvoyPhoneApp.directive('careerConvoyPhone', [function () {
	return {
		templateUrl: '/ui/modules/apps/CareerConvoy-Phone/phone.html',
		replace: true,
		restrict: 'EA',
		scope: true
	};
}]);

// An icon of ui/careerConvoy/icons.svg (loaded into the page by phone.html), by its name:
// <scp-icon name="car"></scp-icon>, or a name from Lua: <scp-icon name="{{ app.icon }}"></scp-icon>.
// Its size comes from app.css (.scp-icon and the place it is in); it is drawn in the text color.
careerConvoyPhoneApp.directive('scpIcon', [function () {
	return {
		restrict: 'E',
		replace: true,
		template: function (element, attrs) {
			var name = attrs.name || '';
			var href = name.indexOf('{{') >= 0 ? 'ng-attr-href="#sc-icon-' + name + '"' : 'href="#sc-icon-' + name + '"';
			return '<svg class="scp-icon" aria-hidden="true"><use ' + href + '/></svg>';
		}
	};
}]);

// A row of buttons to pick one (Fuel: the order, Tow: the winch's strength); the chosen one is
// orange. <scp-segment-select label="Strength" options="list" selected="id" on-select="set(id)">
//   label      optional, a name in front of the buttons
//   options    [{id, name, icon?}] – keep it the same array between updates (a new array on every
//              call makes AngularJS check again and again until it gives up)
//   selected   the id of the chosen option
//   on-select  called with the id of the button that was clicked
careerConvoyPhoneApp.directive('scpSegmentSelect', [function () {
	return {
		restrict: 'E',
		replace: true,
		templateUrl: '/ui/modules/apps/CareerConvoy-Phone/shared/segment-select.html',
		scope: {
			label: '@',
			options: '=',
			selected: '=',
			onSelect: '&'
		}
	};
}]);

careerConvoyPhoneApp.controller('CareerConvoyPhone', ['$scope', '$element', function ($scope, $element) {
	$scope.enabled = true;
	$scope.open = false;
	$scope.apps = [];
	$scope.homeApps = []; // the installed apps: the ones on the home screen
	$scope.currentApp = null;
	$scope.time = null;
	$scope.connected = false;

	// BeamNG may throw an app away without ending it (e.g. it rebuilds the UI a few times while
	// joining a server): its scope lives on and still gets every guihook, and its phone on <body>
	// stays: F4 opened two phones, and closing one left the other. So an app that is no
	// longer on the page ends itself ($destroy cleans up), at once when a guihook comes (onHook)
	// and every second.
	function alive() {
		try {
			if (document.documentElement.contains($element[0])) return true;
		} catch (e) { return true; }
		if (!$scope.$$destroyed) $scope.$destroy();
		return false;
	}
	var aliveTimer = setInterval(alive, 1000);
	$scope.$on('$destroy', function () { clearInterval(aliveTimer); });
	function onHook(name, fn) {
		$scope.$on(name, function (event, data) { if (alive()) fn(event, data); });
	}

	function lua(cmd) {
		bngApi.engineLua('if careerConvoy_phone then careerConvoy_phone.' + cmd + ' end');
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
		bngApi.engineLua('if careerConvoy_menu then careerConvoy_menu.uiVisible("' + view + '", ' + (visible ? 'true' : 'false') + ') end');
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
		$scope.jobsType = null;
		reportView('fuel', false);
	}
	function setOpen(value) {
		$scope.open = value;
		if (!value) closeApp();
		reportViews();
		if (value) {
			try { window.dispatchEvent(new CustomEvent("careerConvoyPanelOpen", {detail: "phone"})); } catch (e) {}
		}
	}
	$scope.toggle = function () { setOpen(!$scope.open); };
	function onOtherOpened(ev) {
		if (ev && ev.detail !== "phone" && $scope.open) $scope.$evalAsync(function () { setOpen(false); });
	}
	window.addEventListener("careerConvoyPanelOpen", onOtherOpened);
	$scope.$on('$destroy', function () { window.removeEventListener("careerConvoyPanelOpen", onOtherOpened); });

	$scope.openApp = function (app) {
		closeApp();
		$scope.currentApp = app;
		lua('uiOpenApp(' + JSON.stringify(String(app.id)) + ')');
		if (fuelOpen()) reportView('fuel', true);
	};
	$scope.goHome = function () { closeApp(); };
	// the back button in the app bar: from a page inside an app (a job type in Jobs) back to the
	// app's start page, else to the home screen
	$scope.canGoBackInApp = function () { return !!$scope.currentApp && $scope.currentApp.id === 'jobs' && !!$scope.jobsType; };
	$scope.goBack = function () {
		if ($scope.canGoBackInApp()) $scope.jobsType = null; else closeApp();
	};
	// the screen of the open app, if it is a built-in one with its own (apps/<id>.html); else null
	var APP_SCREENS = ['jobs', 'tow', 'straps', 'fuel', 'apps', 'settings'];
	$scope.appScreen = function () {
		var id = $scope.currentApp && $scope.currentApp.id;
		return APP_SCREENS.indexOf(id) >= 0 ? '/ui/modules/apps/CareerConvoy-Phone/apps/' + id + '.html' : null;
	};
	$scope.appTitle = function () {
		if (!$scope.currentApp) return '';
		return $scope.canGoBackInApp() ? $scope.jobTypeName() : $scope.currentApp.title;
	};
	$scope.homeBar = function () {
		if ($scope.currentApp) closeApp(); else setOpen(false);
	};

	//== Tow app (lua/ge/extensions/careerConvoy/tow.lua) ==
	$scope.tow = {allowed: true, attached: false, nearby: []};
	$scope.towCall = function (cmd) {
		bngApi.engineLua('if careerConvoy_tow then careerConvoy_tow.' + cmd + ' end');
	};
	$scope.meters = function (v) { return typeof v === 'number' ? v.toFixed(1) + ' m' : '–'; };
	$scope.strainText = function (s) {
		s = s || 0;
		if (s < 0.6) return 'Easy';
		if (s < 0.9) return 'Working hard';
		return 'At the limit';
	};
	// the winch's load while it hauls in, as 10 segments, green -> amber -> orange, red at the limit;
	// stopped the drum is locked (the rope holds like a tow rope), paying out it gives way
	$scope.winchText = function () {
		var t = $scope.tow;
		if (t.winch === 1) return $scope.strainText(t.strain);
		return t.winch === -1 ? 'Paying out' : 'Locked';
	};
	$scope.winchSegs = new Array(10);
	// the colors are the phone's (app.css)
	$scope.segStyle = function (i) {
		var s = $scope.tow.winch === 1 ? ($scope.tow.strain || 0) : 0;
		if (s * 10 <= i) return {};
		if (s >= 0.95) return {'background': 'var(--scp-danger)'};
		return {'background': i < 5 ? 'var(--scp-ok)' : i < 8 ? 'var(--scp-warn)' : 'var(--scp-accent)'};
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

	//== Straps app (lua/ge/extensions/careerConvoy/straps.lua) ==
	$scope.straps = {allowed: true, step: 0, straps: []};
	$scope.strapsCall = function (cmd) {
		bngApi.engineLua('if careerConvoy_straps then careerConvoy_straps.' + cmd + ' end');
	};
	// a strap's load as a colored dot: green, yellow, red near breaking; grey when slack
	$scope.strapDot = function (s) {
		if (s.slack) return 'scp-dot-slack';
		if (s.load < 0.4) return 'scp-dot-ok';
		return s.load < 0.7 ? 'scp-dot-high' : 'scp-dot-critical';
	};
	onHook('CareerConvoyStraps', function (event, data) {
		$scope.$evalAsync(function () {
			if (!data) return;
			if (!Array.isArray(data.straps)) data.straps = [];
			$scope.straps = data;
		});
	});
	//== The remote for a rope's loose end (shared/remote.html, ropeRemote.lua): in the Tow and Straps apps ==
	// its buttons go to the open app; a held button is let go in the app it was pressed in
	var REMOTE_CALLS = {tow: $scope.towCall, straps: $scope.strapsCall};
	var nudging = null;
	$scope.nudge = function (f, r, u) {
		nudging = $scope.currentApp && REMOTE_CALLS[$scope.currentApp.id];
		if (nudging) nudging('uiNudge(' + f + ',' + r + ',' + u + ')');
	};
	$scope.nudgeStop = function () {
		if (nudging) { nudging('uiNudgeStop()'); nudging = null; }
	};
	$scope.remoteToView = function () {
		var call = $scope.currentApp && REMOTE_CALLS[$scope.currentApp.id];
		if (call) call('uiToView()');
	};

	//== Fuel app (lua/ge/extensions/careerConvoy/fuel.lua, data with "CareerConvoyState") ==
	// the mod was called SharedCareer: what is kept under the old key names moves over once
	['careerConvoyFuelSort', 'careerConvoyPhoneWallpaper', 'careerConvoyPhoneIcons', 'careerConvoySpeedSign', 'careerConvoySpeedUnit'].forEach(function (key) {
		var old = key.replace(/^careerConvoy/, 'sharedCareer');
		try {
			if (window.localStorage.getItem(key) === null && window.localStorage.getItem(old) !== null) {
				window.localStorage.setItem(key, window.localStorage.getItem(old));
			}
			window.localStorage.removeItem(old);
		} catch (e) {}
	});
	var SORT_KEY = "careerConvoyFuelSort";
	$scope.fuel = null;
	$scope.fuelSorts = [{id: 'gasoline', name: 'Gasoline'}, {id: 'diesel', name: 'Diesel'}, {id: 'distance', name: 'Nearest'}];
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
	// whether a station sells fuel cheaper after a delivery (its price is green)
	$scope.fuelDiscounted = function () {
		var f = $scope.fuel;
		return !!f && Array.isArray(f.stations) && f.stations.some(function (st) {
			return ['gasoline', 'diesel'].some(function (k) { return !!st.fuels && !!st.fuels[k] && st.fuels[k].discount > 0; });
		});
	};
	$scope.formatPrice = function (p) { return "$" + Number(p.price).toFixed(2) + "/" + p.unit; };
	$scope.formatDistance = function (m) { return m < 1000 ? Math.round(m) + " m" : (m / 1000).toFixed(1) + " km"; };
	function fuelLua(cmd) { bngApi.engineLua('if careerConvoy_fuel then careerConvoy_fuel.' + cmd + ' end'); }
	$scope.navigate = function (id) { fuelLua('uiNavigate(' + JSON.stringify(String(id)) + ')'); };
	$scope.stopNavigate = function () { fuelLua('uiStopNavigate()'); };

	//== Apps app: install and remove apps (phone.lua uiInstall, kept in state.json) ==
	$scope.setInstalled = function (app, install) {
		lua('uiInstall(' + JSON.stringify(String(app.id)) + ', ' + (install ? 'true' : 'false') + ')');
	};

	//== Settings app: how the phone looks, when the speed limit sign shows and in which unit; kept on this PC (localStorage) ==
	// A wallpaper is a file ui/careerConvoy/wallpapers/<id>.svg; an icon theme is a class
	// scp-app-icon-<id> in app.css ("Colors": each app in the color it registered with). The speed
	// limit sign (CareerConvoy-SpeedLimit/app.js) reads its choices from the same keys and hears a change
	// as a window event (LOOK_EVENTS). The first of each list is the default.
	$scope.WALLPAPERS = [{id: 'ember', name: 'Ember'}, {id: 'dusk', name: 'Dusk'}, {id: 'night-road', name: 'Night road'},
		{id: 'contours', name: 'Contours'}, {id: 'hazard', name: 'Hazard'}, {id: 'carbon', name: 'Carbon'}];
	$scope.ICON_THEMES = [{id: 'beamng', name: 'BeamNG'}, {id: 'colors', name: 'Colors'}, {id: 'dark', name: 'Dark'},
		{id: 'glass', name: 'Glass'}];
	$scope.SIGN_MODES = [{id: 'off', name: 'Off'}, {id: 'taxi', name: 'Taxi rides'}, {id: 'always', name: 'Always'}];
	// "BeamNG": the unit of the game's own settings
	$scope.SPEED_UNITS = [{id: 'game', name: 'BeamNG'}, {id: 'kmh', name: 'km/h'}, {id: 'mph', name: 'mph'}];
	var LOOK_KEYS = {wallpaper: 'careerConvoyPhoneWallpaper', icons: 'careerConvoyPhoneIcons', sign: 'careerConvoySpeedSign',
		unit: 'careerConvoySpeedUnit'};
	var LOOK_LISTS = {wallpaper: $scope.WALLPAPERS, icons: $scope.ICON_THEMES, sign: $scope.SIGN_MODES, unit: $scope.SPEED_UNITS};
	var LOOK_EVENTS = {sign: 'careerConvoySpeedSign', unit: 'careerConvoySpeedUnit'};
	// the id if the list has it, else the list's first (a stored id that is gone, nothing stored)
	function lookId(what, id) {
		var list = LOOK_LISTS[what];
		for (var i = 0; i < list.length; i++) if (list[i].id === id) return id;
		return list[0].id;
	}
	function readLook(what) {
		try { return lookId(what, window.localStorage.getItem(LOOK_KEYS[what])); } catch (e) { return lookId(what, null); }
	}
	function setLook(what, id) {
		$scope.look[what] = lookId(what, id);
		try { window.localStorage.setItem(LOOK_KEYS[what], $scope.look[what]); } catch (e) {}
		if (LOOK_EVENTS[what]) {
			try { window.dispatchEvent(new CustomEvent(LOOK_EVENTS[what], {detail: $scope.look[what]})); } catch (e) {}
		}
	}
	$scope.look = {wallpaper: readLook('wallpaper'), icons: readLook('icons'), sign: readLook('sign'), unit: readLook('unit')};
	$scope.setWallpaper = function (id) { setLook('wallpaper', id); };
	$scope.setIconTheme = function (id) { setLook('icons', id); };
	$scope.setSignMode = function (id) { setLook('sign', id); };
	$scope.setSpeedUnit = function (id) { setLook('unit', id); };
	// a wallpaper as a background (default: the chosen one)
	$scope.wallpaperStyle = function (id) {
		return {'background-image': 'url(/ui/careerConvoy/wallpapers/' + (id || $scope.look.wallpaper) + '.svg)'};
	};
	// an app icon in an icon theme (default: the chosen one): its class, and its own color in "Colors"
	$scope.appIconClass = function (theme) { return 'scp-app-icon-' + (theme || $scope.look.icons); };
	$scope.appIconStyle = function (app, theme) {
		return (theme || $scope.look.icons) === 'colors' && app ? {'background': app.color} : {};
	};

	//== Jobs app (lua/ge/extensions/careerConvoy/jobs.lua) ==
	// What a job shows (icon, tags, steps, the texts of what to do now) comes from its job type
	// (towJobs.lua, taxiJobs.lua); this window only lays it out.
	$scope.jobs = {enabled: false, sections: [], open: 0, active: null, licenses: {}};
	// The app has two pages: its start page, a list with a card per job type, and the page of one
	// job type (its jobs). jobsType is the open job type, null on the start page; the back button
	// in the app bar leads from a job type back to the start page (goBack).
	// The cards: towing first, then one for every other job type, as soon as Lua sends it.
	// Built once per update from Lua, not on every call (ng-repeat).
	function jobTypesOf(sections) {
		var list = [{id: 'tow', name: 'Towing', icon: 'tow'}];
		var added = {tow: true};
		for (var i = 0; i < sections.length; i++) {
			var sec = sections[i];
			if (!sec.type || added[sec.type]) continue;
			if (sec.type === 'tow') { list[0].name = sec.name || list[0].name; continue; }
			list.push({id: sec.type, name: sec.name || sec.type, icon: sec.icon || 'jobs'});
			added[sec.type] = true;
		}
		return list;
	}
	$scope.jobsType = null;
	$scope.jobTypes = jobTypesOf([]);
	$scope.openJobType = function (t) { if (t) $scope.jobsType = t.id; };
	$scope.jobTypeName = function () {
		for (var i = 0; i < $scope.jobTypes.length; i++) {
			if ($scope.jobTypes[i].id === $scope.jobsType) return $scope.jobTypes[i].name;
		}
		return $scope.jobsType || '';
	};
	// whether your job is of this job type (default: the open one)
	$scope.jobsActiveIn = function (type) {
		var active = $scope.jobs.active;
		return !!active && (active.type || 'tow') === (type || $scope.jobsType);
	};
	// the open jobs of a job type (default: the open one)
	$scope.jobsOpenIn = function (type) {
		type = type || $scope.jobsType;
		var open = 0;
		for (var i = 0; i < $scope.jobs.sections.length; i++) {
			var sec = $scope.jobs.sections[i];
			if (sec.type === type) open += Number(sec.open) || 0;
		}
		return open;
	};
	// your level in a job type ({level, share, toGo}), or null
	$scope.jobTypeLevel = function (type) {
		for (var i = 0; i < $scope.jobs.sections.length; i++) {
			var sec = $scope.jobs.sections[i];
			if (sec.type === type) return sec.level || null;
		}
		return null;
	};
	// the line on a job type's card: "Your job", "License needed", "3 open"
	$scope.jobTypeText = function (t) {
		if ($scope.jobsActiveIn(t.id)) return 'Your job';
		if ($scope.jobLicenseMissing(t.id)) return 'License needed';
		var open = $scope.jobsOpenIn(t.id);
		return open ? open + ' open' : 'No jobs';
	};
	// the license a job type's jobs need ({name, owned}), or null when they need none (default: the open one)
	$scope.jobLicense = function (type) { return $scope.jobs.licenses[type || $scope.jobsType] || null; };
	// without it the job type's jobs are greyed out and can't be taken (the server refuses them too)
	$scope.jobLicenseMissing = function (type) { var l = $scope.jobLicense(type); return !!l && !l.owned; };
	// the "On duty" switch of a job type (default: the open one): true/false, null if it has none
	$scope.jobDuty = function (type) {
		type = type || $scope.jobsType;
		for (var i = 0; i < $scope.jobs.sections.length; i++) {
			var sec = $scope.jobs.sections[i];
			if (sec.type === type) return typeof sec.duty === 'boolean' ? sec.duty : null;
		}
		return null;
	};
	$scope.setDuty = function (on) {
		$scope.jobsCall('uiDuty(' + JSON.stringify(String($scope.jobsType)) + ', ' + (on ? 'true' : 'false') + ')');
	};
	$scope.licenseRoute = function () {
		bngApi.engineLua('if careerConvoy_licenses then careerConvoy_licenses.uiRoute() end');
	};
	$scope.jobsCall = function (cmd) {
		bngApi.engineLua('if careerConvoy_jobs then careerConvoy_jobs.' + cmd + ' end');
	};
	// whether icons.svg (ui/careerConvoy/, loaded into the page by phone.html) has this icon; else the
	// name is shown as text (an app that registered a letter, e.g. "T")
	$scope.hasIcon = function (name) {
		return typeof name === 'string' && name !== '' && !!document.getElementById('sc-icon-' + name);
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
		return 'conic-gradient(var(--scp-info) ' + deg + 'deg, var(--scp-control) ' + deg + 'deg)';
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
	// the pay of your job as it is now (less after damage or a rough ride), if the job type says
	$scope.jobPayNow = function () {
		var a = $scope.jobs.active;
		if (!a) return 0;
		return typeof a.payNow === 'number' ? a.payNow : a.pay;
	};
	$scope.jobPayDropped = function () {
		var a = $scope.jobs.active;
		return !!a && typeof a.payNow === 'number' && a.payNow < a.pay;
	};
	// the rating of your job so far (1..5 stars), or null if its job type gives none
	$scope.STAR_SLOTS = [1, 2, 3, 4, 5];
	$scope.jobStars = function () {
		var a = $scope.jobs.active;
		return a && typeof a.stars === 'number' ? a.stars : null;
	};
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
	// the job strip leads to the page of your job's type
	$scope.openJobs = function () {
		var app = appById('jobs');
		if (!app) return;
		$scope.openApp(app);
		if ($scope.jobs.active) $scope.jobsType = $scope.jobs.active.type || 'tow';
	};
	onHook('CareerConvoyJobs', function (event, data) {
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
			// licenses by job type; an empty Lua table arrives as []
			var licenses = data.licenses && typeof data.licenses === 'object' && !Array.isArray(data.licenses) ? data.licenses : {};
			$scope.jobs = {enabled: data.enabled === true, sections: sections, open: Number(data.open) || 0, active: active,
				licenses: licenses};
			$scope.jobTypes = jobTypesOf(sections);
		});
	});

	//== Calls (phone.lua ring): the phone comes out and shows the call until it is answered ==
	$scope.call = null;
	var callTookPhoneOut = false; // the call took the phone out: it goes away again unless accepted
	function endCallView(accepted, c) {
		$scope.call = null;
		var app = accepted && c && c.open ? appById(c.open.app) : null;
		if (app) {
			$scope.openApp(app);
			if (c.open.page) $scope.jobsType = c.open.page;
		} else if (callTookPhoneOut) {
			setOpen(false);
		}
		callTookPhoneOut = false;
	}
	$scope.answerCall = function (accept) {
		var c = $scope.call;
		if (!c) return;
		lua('uiAnswer(' + (accept ? 'true' : 'false') + ')');
		endCallView(accept, c);
	};
	onHook('CareerConvoyPhoneCall', function (event, data) {
		$scope.$evalAsync(function () {
			var c = data && data.call && typeof data.call === 'object' ? data.call : null;
			if (c) {
				if (!$scope.call) {
					callTookPhoneOut = !$scope.open;
					if (!$scope.open) setOpen(true);
				}
				$scope.call = c;
			} else if ($scope.call) {
				endCallView(false, null); // rang out, or the caller hung up
			}
		});
	});

	onHook('CareerConvoyTow', function (event, data) {
		$scope.$evalAsync(function () {
			if (!data) return;
			if (!Array.isArray(data.nearby)) data.nearby = [];
			if (!Array.isArray(data.strengths)) data.strengths = [];
			// the strengths as options of the segment select, built once per update
			data.strengthOptions = data.strengths.map(function (s) { return {id: s, name: s + '%'}; });
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
		if (!t || typeof t.isDay !== 'boolean') return 'Career-Convoy';
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

	onHook('CareerConvoyPhone', function (event, data) {
		$scope.$evalAsync(function () {
			if (!data) return;
			$scope.enabled = data.enabled !== false;
			$scope.apps = Array.isArray(data.apps) ? data.apps : [];
			$scope.homeApps = $scope.apps.filter(function (app) { return app.installed !== false; });
			if (!$scope.enabled) setOpen(false);
		});
	});
	onHook('CareerConvoyPhoneToggle', function () {
		$scope.$evalAsync(function () { if ($scope.enabled) setOpen(!$scope.open); });
	});
	onHook('CareerConvoyPhoneAway', function () {
		$scope.$evalAsync(function () { if ($scope.open) setOpen(false); });
	});
	onHook('CareerConvoyState', function (event, data) {
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
