// SharedCareer Phone: a tab at the right screen edge (key F4) that takes the phone out.
// The phone shows the server time, the number of players, the connection and the apps that
// SharedCareer extensions registered (lua/ge/extensions/sharedCareer/phone.lua). No apps yet.
//
// Data: guihook "SharedCareerPhone" {enabled, apps} from phone.lua, "SharedCareerTime" (time,
// players, connection) from env.lua every second, "SharedCareerPhoneToggle" from the key.
// Like the menu and the fuel app, opening the phone collapses the other SharedCareer windows
// (window event "sharedCareerPanelOpen").
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

	function setOpen(value) {
		$scope.open = value;
		if (!value) $scope.currentApp = null;
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
		$scope.currentApp = app;
		lua('uiOpenApp(' + JSON.stringify(String(app.id)) + ')');
	};
	$scope.goHome = function () { $scope.currentApp = null; };
	$scope.homeBar = function () {
		if ($scope.currentApp) $scope.currentApp = null; else setOpen(false);
	};

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
	$scope.$on('SharedCareerTime', function (event, data) {
		$scope.$evalAsync(function () {
			if (!data) return;
			$scope.time = typeof data.hour === 'number' ? data.hour : null;
			$scope.isDay = data.isDay;
			$scope.connected = data.connected === true;
			var list = data.players && Array.isArray(data.players.list) ? data.players.list : null;
			$scope.players = list ? list.length : '–';
		});
	});

	lua('uiRequest()');
}]);
