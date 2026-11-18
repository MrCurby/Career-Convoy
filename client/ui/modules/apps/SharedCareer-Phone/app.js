// SharedCareer Phone: a tab at the right screen edge (key F4) that takes the phone out.
// The phone shows the server time, the number of players, the connection and the apps that
// SharedCareer extensions registered (lua/ge/extensions/sharedCareer/phone.lua). Built-in app
// screens: Jobs (towing jobs, beta, jobs.lua), Tow (rope and winch, grab.lua) and Fuel (gas station
// prices, fuel.lua). Apps marked beta get a "BETA" badge on the icon and in the title bar.
// The home screen has, below the clock, how long until day or night (with a bar for the part
// of it that is over), and two widgets below the apps: the other players with what they are
// doing, and the cheapest station per fuel (a tap opens the Fuel app).
//
// Data: guihook "SharedCareerPhone" {enabled, apps} from phone.lua, "SharedCareerState" (time,
// players, connection, fuel prices, cheapest fuel) from menu.lua every second, "SharedCareerTow" from grab.lua,
// "SharedCareerJobs" (jobs and your job) from jobs.lua
// while the Tow app is open, "SharedCareerPhoneToggle" from the key.
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

	//== Tow app (lua/ge/extensions/sharedCareer/grab.lua) ==
	$scope.tow = {allowed: true, attached: false, nearby: []};
	$scope.towCall = function (cmd) {
		bngApi.engineLua('if sharedCareer_grab then sharedCareer_grab.' + cmd + ' end');
	};
	var nudging = false;
	$scope.nudge = function (f, r, u) { nudging = true; $scope.towCall('uiNudge(' + f + ',' + r + ',' + u + ')'); };
	$scope.nudgeStop = function () { if (nudging) { nudging = false; $scope.towCall('uiNudgeStop()'); } };
	$scope.meters = function (v) { return typeof v === 'number' ? v.toFixed(1) + ' m' : '–'; };
	$scope.strainColor = function (s) {
		s = Math.max(0, Math.min(1, s || 0));
		if (s < 0.6) return '#4cd964';
		if (s < 0.9) return '#ffcc00';
		return '#ff3b30';
	};
	$scope.strainText = function (s) {
		s = s || 0;
		if (s < 0.6) return 'easy';
		if (s < 0.9) return 'working hard';
		return 'at the limit';
	};
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
	$scope.jobs = {enabled: false, jobs: [], active: null};
	$scope.jobSteps = ['Pick up', 'Tow', 'Paid'];
	$scope.jobsCall = function (cmd) {
		bngApi.engineLua('if sharedCareer_jobs then sharedCareer_jobs.' + cmd + ' end');
	};
	$scope.money = function (v) { return '$' + Math.round(Number(v) || 0).toLocaleString('en-US'); };
	$scope.openJobCount = function () {
		return $scope.jobs.jobs.filter(function (j) { return j.state === 'open'; }).length;
	};
	// 0 = drive to the vehicle, 1 = tow it (and the check at the shop), 2 = paid
	$scope.jobStep = function () {
		var a = $scope.jobs.active;
		if (!a) return 0;
		if (a.phase === 'paid') return 2;
		return a.phase === 'toVehicle' ? 0 : 1;
	};
	$scope.jobText = function () {
		var a = $scope.jobs.active;
		if (!a) return '';
		if (a.phase === 'paid') return 'Done – the pay is in your account';
		if (a.phase === 'checking') return 'Handing it over at ' + a.dest + '…';
		if (a.phase === 'toVehicle') return 'to the ' + a.vehicle;
		return a.inZone ? 'In the drop-off ring – hold still' : 'to ' + a.dest;
	};
	// short, for the home screen widget and the strip in the Tow app
	$scope.jobStepText = function () {
		var a = $scope.jobs.active;
		if (!a) return '';
		if (a.phase === 'toVehicle') return 'Drive to the breakdown';
		return a.inZone ? 'In the drop-off ring – hold still' : 'Tow to ' + a.dest;
	};
	$scope.openJobs = function () { var app = appById('jobs'); if (app) $scope.openApp(app); };
	$scope.$on('SharedCareerJobs', function (event, data) {
		$scope.$evalAsync(function () {
			if (!data) return;
			$scope.jobs = {enabled: data.enabled === true, jobs: Array.isArray(data.jobs) ? data.jobs : [], active: data.active || null};
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

	//== Home screen widgets ==
	var STATUS = {
		driving: {text: 'Driving', color: '#4cd964'},
		mission: {text: 'Mission', color: '#ff9500'},
		walking: {text: 'On foot', color: '#5ac8fa'},
		loading: {text: 'Loading', color: '#8e8e93'}
	};
	var SHOWN_PLAYERS = 4;
	$scope.others = [];
	$scope.statusOf = function (p) { return STATUS[p.status] || {text: '', color: '#8e8e93'}; };
	$scope.shownOthers = function () { return $scope.others.slice(0, SHOWN_PLAYERS); };
	$scope.moreOthers = function () { return Math.max(0, $scope.others.length - SHOWN_PLAYERS); };
	// the fuel widget's rows, built once per state (new objects on every digest would make
	// ng-repeat loop)
	$scope.cheapestFuels = [];
	function cheapestRows(c) {
		if (!c) return [];
		return ['gasoline', 'diesel'].filter(function (f) { return c[f]; }).map(function (f) {
			var e = c[f];
			return {key: f === 'gasoline' ? 'G' : 'D', name: e.name, price: $scope.formatPrice(e), discount: e.discount,
				distance: typeof e.distance === 'number' ? $scope.formatDistance(e.distance) : null};
		});
	}
	function appById(id) {
		for (var i = 0; i < $scope.apps.length; i++) if ($scope.apps[i].id === id) return $scope.apps[i];
		return null;
	}
	$scope.hasApp = function (id) { return !!appById(id); };
	$scope.openFuel = function () { var app = appById('fuel'); if (app) $scope.openApp(app); };

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
	$scope.$on('SharedCareerState', function (event, data) {
		$scope.$evalAsync(function () {
			if (!data) return;
			$scope.time = typeof data.hour === 'number' ? data.hour : null;
			$scope.timeInfo = {isDay: data.isDay, paused: data.paused === true, secondsToSwitch: data.secondsToSwitch,
				dayStart: data.dayStart, nightStart: data.nightStart};
			$scope.connected = data.connected === true;
			var list = data.players && Array.isArray(data.players.list) ? data.players.list : null;
			$scope.players = list ? list.length : '–';
			$scope.others = list ? list.filter(function (p) { return p && !p.me; }) : [];
			$scope.cheapestFuels = cheapestRows(data.fuelCheapest);
			// fuel is false while the Fuel app is closed: keep the last list until fresh prices arrive
			if (data.fuel !== false) $scope.fuel = data.fuel || null;
		});
	});

	lua('uiRequest()');
	reportViews();
}]);
