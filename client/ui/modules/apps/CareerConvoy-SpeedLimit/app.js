// Career-Convoy Speed Limit: the speed limit of the road you drive on, as a road sign.
// Data: guihook "CareerConvoySpeedLimit" {kmh, mph, unit, over, taxi} from speedLimit.lua (only when
// it changes); without a limit the sign is hidden (on foot, off the road, a road without a limit).
// km/h: a round sign with a red ring; mph: a US "SPEED LIMIT" sign. While you are too fast (over)
// it pulses red.
// When it shows is the player's choice in the phone's Settings app: "off" (the default), "taxi"
// (only on a taxi ride) or "always"; the phone keeps it in localStorage (SIGN_KEY) and announces a
// change with the window event "careerConvoySpeedSign". The unit too: "game" (the game's setting,
// the default), "kmh" or "mph" (UNIT_KEY, window event "careerConvoySpeedUnit"). While the
// Career-Convoy menu is open the sign is hidden and its whole frame moved off the screen, so it never
// covers the menu or blocks its buttons: the menu keeps its state in localStorage (MENU_KEY, "1" = collapsed) and
// announces a change with the window event "careerConvoyMenuShown".
//
// Note: only var/function at the top level – the game evaluates app.js again in the same scope
// when the apps are reloaded.

var careerConvoySpeedLimitApp = angular.module('beamng.apps');

careerConvoySpeedLimitApp.directive('careerConvoySpeedLimit', [function () {
	return {
		templateUrl: '/ui/modules/apps/CareerConvoy-SpeedLimit/app.html',
		replace: true,
		restrict: 'EA',
		scope: true
	};
}]);

careerConvoySpeedLimitApp.controller('CareerConvoySpeedLimit', ['$scope', '$element', function ($scope, $element) {
	// BeamNG may throw an app away without ending it (e.g. it rebuilds the UI a few times while
	// joining a server): its scope lives on and still gets every guihook. So an app that is no
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

	// the mod was called SharedCareer: what is kept under the old key names moves over once
	['careerConvoySpeedSign', 'careerConvoySpeedUnit', 'careerConvoyMenuCollapsed'].forEach(function (key) {
		var old = key.replace(/^careerConvoy/, 'sharedCareer');
		try {
			if (window.localStorage.getItem(key) === null && window.localStorage.getItem(old) !== null) {
				window.localStorage.setItem(key, window.localStorage.getItem(old));
			}
			window.localStorage.removeItem(old);
		} catch (e) {}
	});
	var SIGN_KEY = 'careerConvoySpeedSign'; // kept by the phone (CareerConvoy-Phone/app.js)
	var UNIT_KEY = 'careerConvoySpeedUnit'; // kept by the phone
	var MENU_KEY = 'careerConvoyMenuCollapsed'; // kept by the menu (CareerConvoy-Menu/app.js)
	function stored(key) {
		try { return window.localStorage.getItem(key); } catch (e) { return null; }
	}
	$scope.sign = {};
	$scope.mode = stored(SIGN_KEY) || 'off';
	$scope.unitChoice = stored(UNIT_KEY) || 'game';
	$scope.menuOpen = stored(MENU_KEY) !== '1';
	// the sign shows: a limit, the player wants it now (always, or on a taxi ride), the menu is closed
	$scope.shown = function () {
		var s = $scope.sign;
		var wanted = $scope.mode === 'always' || ($scope.mode === 'taxi' && s.taxi === true);
		return !!s.kmh && wanted && !$scope.menuOpen;
	};
	// the unit on the sign: the player's choice, else the game's; and the limit in it
	$scope.unit = function () {
		if ($scope.unitChoice === 'kmh') return 'km/h';
		if ($scope.unitChoice === 'mph') return 'mph';
		return $scope.sign.unit === 'mph' ? 'mph' : 'km/h';
	};
	$scope.limit = function () { return $scope.unit() === 'mph' ? $scope.sign.mph : $scope.sign.kmh; };
	onHook('CareerConvoySpeedLimit', function (event, data) {
		$scope.$evalAsync(function () {
			$scope.sign = data && typeof data.kmh === 'number' ? data : {};
		});
	});
	function onMode(ev) {
		$scope.$evalAsync(function () { $scope.mode = ev && ev.detail ? ev.detail : 'off'; });
	}
	function onUnit(ev) {
		$scope.$evalAsync(function () { $scope.unitChoice = ev && ev.detail ? ev.detail : 'game'; });
	}
	function onMenu(ev) {
		$scope.$evalAsync(function () {
			$scope.menuOpen = !!(ev && ev.detail);
			moveFrame($scope.menuOpen);
		});
	}
	// BeamNG's frame around an app catches clicks over its whole area, even with the sign hidden.
	// So while the menu is open the whole frame is moved off the screen (class scs-frame-away in
	// app.css, with !important so the game's own frame styles can't undo it): a sign placed over
	// the menu then never blocks its buttons. The frame is the part around the sign that stands
	// next to the menu's frame (below the element both share). Checked again every 0.5 s, as the
	// game may rebuild the frame and the menu may load after the sign.
	function frame() {
		var menu = document.querySelector('.scMenu:not(.scm-dialog-host)');
		if (!menu) return null;
		for (var el = $element[0]; el.parentElement; el = el.parentElement) {
			if (el.parentElement.contains(menu)) return el;
		}
		return null;
	}
	function moveFrame(away) {
		try {
			var el = frame();
			if (el && el.classList.contains('scs-frame-away') !== away) el.classList.toggle('scs-frame-away', away);
		} catch (e) {}
	}
	var frameTimer = setInterval(function () { moveFrame($scope.menuOpen); }, 500);
	window.addEventListener('careerConvoySpeedSign', onMode);
	window.addEventListener('careerConvoySpeedUnit', onUnit);
	window.addEventListener('careerConvoyMenuShown', onMenu);
	$scope.$on('$destroy', function () {
		window.removeEventListener('careerConvoySpeedSign', onMode);
		window.removeEventListener('careerConvoySpeedUnit', onUnit);
		window.removeEventListener('careerConvoyMenuShown', onMenu);
		clearInterval(frameTimer);
		moveFrame(false);
	});
	// the sign as it is now (Lua sends it only when it changes)
	bngApi.engineLua('if careerConvoy_speedLimit then careerConvoy_speedLimit.uiRequest() end');
}]);
