// SharedCareer Fuel: all stations with gasoline/diesel prices, cheapest first (or nearest).
// Separate app with its own tab (fuel pump) to collapse/expand; collapsed by default.
//
// Data: guihook "SharedCareerTime" (field "fuel", from lua/ge/extensions/sharedCareer/fuel.lua
// overview), every second. "Go" sets a route to the station (sharedCareer_fuel.uiNavigate).
//
// Note: only var/function at the top level – the game evaluates app.js again in the same
// scope when the apps are reloaded.

var sharedCareerFuelApp = angular.module('beamng.apps');

sharedCareerFuelApp.directive('sharedCareerFuel', [function () {
	return {
		templateUrl: '/ui/modules/apps/SharedCareer-Fuel/app.html',
		replace: true,
		restrict: 'EA',
		scope: true
	};
}]);

sharedCareerFuelApp.controller('SharedCareerFuel', ['$scope', function ($scope) {
	var COLLAPSED_KEY = "sharedCareerFuelCollapsed";
	var SORT_KEY = "sharedCareerFuelSort";

	$scope.fuel = null;
	$scope.connected = false;
	// default: collapsed (only the tab with the fuel pump)
	$scope.collapsed = true;
	try { var c = window.localStorage.getItem(COLLAPSED_KEY); if (c !== null) $scope.collapsed = c === "1"; } catch (e) {}
	$scope.sort = "gasoline";
	try { $scope.sort = window.localStorage.getItem(SORT_KEY) || "gasoline"; } catch (e) {}

	// Menu and fuel window sit at the right edge: when one opens, the other one collapses
	// (window event "sharedCareerPanelOpen").
	function setCollapsed(value) {
		$scope.collapsed = value;
		try { window.localStorage.setItem(COLLAPSED_KEY, value ? "1" : "0"); } catch (e) {}
		if (!value) {
			try { window.dispatchEvent(new CustomEvent("sharedCareerPanelOpen", {detail: "fuel"})); } catch (e) {}
		}
	}
	$scope.toggleCollapsed = function () { setCollapsed(!$scope.collapsed); };
	function onOtherOpened(ev) {
		if (ev && ev.detail !== "fuel" && !$scope.collapsed) {
			$scope.$evalAsync(function () { setCollapsed(true); });
		}
	}
	window.addEventListener("sharedCareerPanelOpen", onOtherOpened);
	$scope.$on('$destroy', function () { window.removeEventListener("sharedCareerPanelOpen", onOtherOpened); });
	$scope.setSort = function (s) {
		$scope.sort = s;
		try { window.localStorage.setItem(SORT_KEY, s); } catch (e) {}
	};
	// fuel type whose price is highlighted (gasoline for "Nearest")
	$scope.mainFuel = function () { return $scope.sort === 'diesel' ? 'diesel' : 'gasoline'; };

	$scope.stations = function () {
		var f = $scope.fuel;
		if (!f || !f.stations) return [];
		var list = f.stations.slice();
		var sort = $scope.sort;
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

	function engine(cmd) { bngApi.engineLua('if sharedCareer_fuel then sharedCareer_fuel.' + cmd + ' end'); }
	$scope.navigate = function (id) { engine('uiNavigate(' + JSON.stringify(String(id)) + ')'); };
	$scope.stopNavigate = function () { engine('uiStopNavigate()'); };

	$scope.$on('SharedCareerTime', function (event, data) {
		$scope.$evalAsync(function () {
			$scope.connected = !!(data && data.connected);
			$scope.fuel = (data && data.fuel) || null;
		});
	});

	if (!$scope.collapsed) {
		setTimeout(function () {
			try { window.dispatchEvent(new CustomEvent("sharedCareerPanelOpen", {detail: "fuel"})); } catch (e) {}
		}, 0);
	}

	bngApi.engineLua('if sharedCareer_env then sharedCareer_env.uiRequest() end');
}]);
