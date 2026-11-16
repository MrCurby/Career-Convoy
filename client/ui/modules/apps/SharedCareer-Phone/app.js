// SharedCareer Phone: a tab at the right screen edge (key F4) that takes the phone out.
// The phone shows the server time, the number of players, the connection and the apps that
// SharedCareer extensions registered (lua/ge/extensions/sharedCareer/phone.lua). Built-in app
// screens: Tow (rope and winch, grab.lua) and Fuel (gas station prices, fuel.lua).
//
// Data: guihook "SharedCareerPhone" {enabled, apps} from phone.lua, "SharedCareerState" (time,
// players, connection, fuel prices) from menu.lua every second, "SharedCareerTow" from grab.lua
// while the Tow app is open, "SharedCareerPhoneToggle" from the key.
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

	function closeApp() {
		if ($scope.currentApp) lua('uiCloseApp(' + JSON.stringify(String($scope.currentApp.id)) + ')');
		$scope.currentApp = null;
	}
	function setOpen(value) {
		$scope.open = value;
		if (!value) closeApp();
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
	$scope.dayText = function () {
		if (!$scope.connected) return 'Not connected';
		if ($scope.isDay === true) return 'Day on the server';
		if ($scope.isDay === false) return 'Night on the server';
		return 'SharedCareer';
	};
	$scope.playerCount = function () { return $scope.players; };

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
			$scope.isDay = data.isDay;
			$scope.connected = data.connected === true;
			var list = data.players && Array.isArray(data.players.list) ? data.players.list : null;
			$scope.players = list ? list.length : '–';
			$scope.fuel = data.fuel || null;
		});
	});

	lua('uiRequest()');
}]);
