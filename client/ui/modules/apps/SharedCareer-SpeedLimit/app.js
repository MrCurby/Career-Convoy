// SharedCareer Speed Limit: the speed limit of the road you drive on, as a road sign.
// Data: guihook "SharedCareerSpeedLimit" {kmh, mph, unit, over, taxi} from speedLimit.lua (only when
// it changes); without a limit the sign is hidden (on foot, off the road, a road without a limit).
// km/h: a round sign with a red ring; mph: a US "SPEED LIMIT" sign. While you are too fast (over)
// it pulses red.
// When it shows is the player's choice in the phone's Settings app: "off" (the default), "taxi"
// (only on a taxi ride) or "always"; the phone keeps it in localStorage (SIGN_KEY) and announces a
// change with the window event "sharedCareerSpeedSign". The unit too: "game" (the game's setting,
// the default), "kmh" or "mph" (UNIT_KEY, window event "sharedCareerSpeedUnit"). While the SharedCareer menu is open the
// sign is hidden, so it never covers the menu: the menu keeps its state in localStorage
// (MENU_KEY, "1" = collapsed) and announces a change with the window event "sharedCareerMenuShown".
//
// Note: only var/function at the top level – the game evaluates app.js again in the same scope
// when the apps are reloaded.

var sharedCareerSpeedLimitApp = angular.module('beamng.apps');

sharedCareerSpeedLimitApp.directive('sharedCareerSpeedLimit', [function () {
	return {
		templateUrl: '/ui/modules/apps/SharedCareer-SpeedLimit/app.html',
		replace: true,
		restrict: 'EA',
		scope: true
	};
}]);

sharedCareerSpeedLimitApp.controller('SharedCareerSpeedLimit', ['$scope', function ($scope) {
	var SIGN_KEY = 'sharedCareerSpeedSign'; // kept by the phone (SharedCareer-Phone/app.js)
	var UNIT_KEY = 'sharedCareerSpeedUnit'; // kept by the phone
	var MENU_KEY = 'sharedCareerMenuCollapsed'; // kept by the menu (SharedCareer-Menu/app.js)
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
	$scope.$on('SharedCareerSpeedLimit', function (event, data) {
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
		$scope.$evalAsync(function () { $scope.menuOpen = !!(ev && ev.detail); });
	}
	window.addEventListener('sharedCareerSpeedSign', onMode);
	window.addEventListener('sharedCareerSpeedUnit', onUnit);
	window.addEventListener('sharedCareerMenuShown', onMenu);
	$scope.$on('$destroy', function () {
		window.removeEventListener('sharedCareerSpeedSign', onMode);
		window.removeEventListener('sharedCareerSpeedUnit', onUnit);
		window.removeEventListener('sharedCareerMenuShown', onMenu);
	});
	// the sign as it is now (Lua sends it only when it changes)
	bngApi.engineLua('if sharedCareer_speedLimit then sharedCareer_speedLimit.uiRequest() end');
}]);
