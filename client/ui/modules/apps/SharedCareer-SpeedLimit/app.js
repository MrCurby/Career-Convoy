// SharedCareer Speed Limit: the speed limit of the road you drive on, as a road sign.
// Data: guihook "SharedCareerSpeedLimit" {limit, unit, over} from speedLimit.lua (only when it
// changes); without limit the sign is hidden (on foot, off the road, a road without a limit).
// km/h: a round sign with a red ring; mph: a US "SPEED LIMIT" sign. While you are too fast (over)
// it pulses red.
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
	$scope.sign = {};
	$scope.$on('SharedCareerSpeedLimit', function (event, data) {
		$scope.$evalAsync(function () {
			$scope.sign = data && typeof data.limit === 'number' ? data : {};
		});
	});
	// the sign as it is now (Lua sends it only when it changes)
	bngApi.engineLua('if sharedCareer_speedLimit then sharedCareer_speedLimit.uiRequest() end');
}]);
