// SharedCareer menu (the window with the steering wheel): Time, Traffic, Options and Players tabs.
// Everything set here goes to the server and applies to ALL players immediately.
//
// Time tab: the server's time and whether it is day or night.
// Every player can change the time (±1 h, morning/noon/evening/night) and the length of
// day and night; the server applies that for everyone immediately. − and + walk through the same
// round values for day and night (LENGTHS: 1, 5, 10, ... 600 min), in bigger steps the longer it
// gets; a length between two of them (set in the config) goes to the next one.
// "Clock" is one group of three: Run, Pause (stops the clock for everyone at the current time) and
// Real time (the time follows the real clock in the server's time zone; the other time buttons are hidden then, they
// would work against it).
// Traffic tab: a small table – driving/parked cars per player and the server's limit – and the AI
// driving style; below it what this player gets.
// Options tab: switches for collision with cars/players on foot, synced traffic lights, status on
// name tags.
// Players tab: Navigate (route to the player), Watch (camera), Go (teleport, only if the
// server allows it). Player names are passed to Lua as JSON strings.
// Fuel prices are an app on the phone (SharedCareer-Phone, same data and styles).
// Key F7 (can be changed under Options → Controls → BeamMP) collapses/expands the menu.
// Numbers (settings and lengths) are only sent once you stop clicking for a moment (SEND_DELAY),
// so that not every click triggers a notification for everyone (and the server, which takes one
// time change per second and player, doesn't drop the clicks in between).
// The tab at the right edge collapses and expands the window (like the BeamMP player
// list); the state is remembered in the game's browser storage.
//
// Data arrives every second via the guihook "SharedCareerState" from
// lua/ge/extensions/sharedCareer/menu.lua (state) – only while someone looks: the window reports
// "menu" visible with sharedCareer_menu.uiVisible on every expand/collapse and every 2 s while
// expanded (see menu.lua). Clicks go via bngApi.engineLua to
// sharedCareer_env (time: uiSetHour / uiShiftHour / uiSetPaused / uiSetRealtime / uiSetLengths),
// sharedCareer_menu (settings) and sharedCareer_players (Players tab).
//
// Note: only var/function at the top level – the game evaluates app.js again in the same
// scope when the apps are reloaded.

var sharedCareerMenuApp = angular.module('beamng.apps');

sharedCareerMenuApp.directive('sharedCareerMenu', [function () {
	return {
		templateUrl: '/ui/modules/apps/SharedCareer-Menu/app.html',
		replace: true,
		restrict: 'EA',
		scope: true
	};
}]);

sharedCareerMenuApp.controller('SharedCareerMenu', ['$scope', '$element', function ($scope, $element) {
	// the day/night lengths − and + step through (minutes; the server allows 1..600)
	var LENGTHS = [1, 5, 10, 15, 20, 25, 30, 40, 50, 60, 75, 90, 105, 120, 150, 180, 210, 240,
		300, 360, 420, 480, 540, 600];

	var STORAGE_KEY = "sharedCareerMenuCollapsed";

	$scope.state = null;
	// Collapsed (only the tab at the edge visible)? Remembered per player.
	$scope.collapsed = false;
	try { $scope.collapsed = window.localStorage.getItem(STORAGE_KEY) === "1"; } catch (e) {}

	// Tells Lua whether the expanded menu is visible (it only sends the state while someone looks).
	function reportVisible(visible) {
		bngApi.engineLua('if sharedCareer_menu then sharedCareer_menu.uiVisible("menu", ' + (visible ? 'true' : 'false') + ') end');
	}

	// Menu and phone sit at the right edge: when one opens, the other one closes
	// (window event "sharedCareerPanelOpen"). Every change is announced (window event
	// "sharedCareerMenuShown", true = open): the speed limit sign hides while the menu is open.
	function setCollapsed(value) {
		$scope.collapsed = value;
		try { window.localStorage.setItem(STORAGE_KEY, value ? "1" : "0"); } catch (e) {}
		reportVisible(!value);
		try { window.dispatchEvent(new CustomEvent("sharedCareerMenuShown", {detail: !value})); } catch (e) {}
		if (!value) {
			try { window.dispatchEvent(new CustomEvent("sharedCareerPanelOpen", {detail: "menu"})); } catch (e) {}
		}
	}
	$scope.toggleCollapsed = function () { setCollapsed(!$scope.collapsed); };
	function onOtherOpened(ev) {
		if (ev && ev.detail !== "menu" && !$scope.collapsed) {
			$scope.$evalAsync(function () { setCollapsed(true); });
		}
	}
	window.addEventListener("sharedCareerPanelOpen", onOtherOpened);
	$scope.$on('$destroy', function () { window.removeEventListener("sharedCareerPanelOpen", onOtherOpened); });

	// active tab, remembered as well
	var TAB_KEY = "sharedCareerMenuTab";
	$scope.tab = "time";
	try { $scope.tab = window.localStorage.getItem(TAB_KEY) || "time"; } catch (e) {}
	if (["time", "traffic", "options", "players"].indexOf($scope.tab) < 0) $scope.tab = "time";
	$scope.setTab = function (tab) {
		$scope.tab = tab;
		try { window.localStorage.setItem(TAB_KEY, tab); } catch (e) {}
	};

	// Dialog (guihook "SharedCareerDialog" from welcome.lua): welcome or a message from the server
	$scope.dialog = null;
	// Attach the dialog host to <body> (Angular bindings are kept) and remove it again when the
	// window closes. If that fails, it stays in the window – then it works as before.
	// Move it only after linking (otherwise it messes up Angular's node list).
	var dialogHost = null;
	setTimeout(function () {
		try {
			var host = $element[0].querySelector('.scm-dialog-host');
			if (!host || $scope.$$destroyed) return;
			document.body.appendChild(host);
			dialogHost = host;
		} catch (e) {}
	}, 0);
	$scope.$on('$destroy', function () {
		if (dialogHost && dialogHost.parentNode) dialogHost.parentNode.removeChild(dialogHost);
	});
	$scope.$on('SharedCareerDialog', function (event, data) {
		$scope.$evalAsync(function () { $scope.dialog = data || null; });
	});
	$scope.dialogButton = function (b) {
		var d = $scope.dialog;
		$scope.dialog = null;
		if (!d || !b) return;
		bngApi.engineLua('if sharedCareer_welcome then sharedCareer_welcome.uiDialogButton(' +
			JSON.stringify(String(d.kind || "")) + ', ' + JSON.stringify(String(b.action || "")) + ') end');
	};

	// license shop (licenses.lua): "Buy" next to a license; the dialog stays open and Lua updates it
	$scope.buy = function (it) {
		bngApi.engineLua('if sharedCareer_licenses then sharedCareer_licenses.uiBuy(' +
			JSON.stringify(String(it.buy)) + ') end');
	};

	// click on the steering-wheel logo: show the welcome dialog again
	$scope.showWelcome = function () {
		bngApi.engineLua('if sharedCareer_welcome then sharedCareer_welcome.show(true) end');
	};

	//== Players tab ==
	var STATUS_TEXT = {mission: "Mission", walking: "On foot", loading: "Loading"};
	$scope.statusText = function (status) { return STATUS_TEXT[status] || ""; };
	function players(cmd) {
		bngApi.engineLua('if sharedCareer_players then sharedCareer_players.' + cmd + ' end');
	}
	function quote(name) { return JSON.stringify(String(name)); }
	$scope.navigate = function (name) { players('uiNavigate(' + quote(name) + ')'); };
	$scope.stopNavigate = function () { players('uiStopNavigate()'); };
	$scope.watch = function (name) { players('uiWatch(' + quote(name) + ')'); };
	$scope.back = function () { players('uiBack()'); };
	$scope.teleport = function (name) { players('uiTeleport(' + quote(name) + ')'); };

	// menu key (default F7, see menu.lua): collapse/expand
	$scope.$on('SharedCareerToggle', function () {
		$scope.$evalAsync(function () { $scope.toggleCollapsed(); });
	});

	//== Settings (Traffic / Options tabs) ==
	var SEND_DELAY = 600;   // ms of quiet after the last click, then send
	var PENDING_MAX = 4;    // s: afterwards show the server value again if nothing came back
	var pending = {};       // key -> {value, age, timer}

	function field(key) { return key.split('.')[1]; }

	$scope.canEdit = function () {
		return !!($scope.state && $scope.state.settings && $scope.state.settings.canEdit);
	};

	$scope.val = function (key) {
		if (pending[key]) return pending[key].value;
		var s = ($scope.state && $scope.state.settings) || {};
		return s[field(key)];
	};

	function sendSetting(key, value) {
		var v = (typeof value === "boolean") ? (value ? "true" : "false") : Number(value);
		bngApi.engineLua('if sharedCareer_menu then sharedCareer_menu.uiSetSetting("' + key + '", ' + v + ') end');
	}

	function setPending(key, value, delay) {
		var p = pending[key] || {};
		if (p.timer) clearTimeout(p.timer);
		p.value = value; p.age = 0;
		p.timer = setTimeout(function () { p.timer = null; sendSetting(key, p.value); }, delay);
		pending[key] = p;
	}

	$scope.step = function (key, delta, min, max) {
		if (!$scope.canEdit()) return;
		var v = Number($scope.val(key)) || 0;
		setPending(key, Math.max(min, Math.min(max, v + delta)), SEND_DELAY);
	};

	// Options tab: one switch each. `invert`: the setting says the opposite of the label
	// (ghost = no collision).
	$scope.OPTIONS = [
		{key: 'client.remoteVehicleGhost', label: "Collision with other players' cars", invert: true},
		{key: 'client.remoteUnicycleGhost', label: 'Collision with players on foot', invert: true},
		{key: 'server.trafficSignalSync', label: 'Synced traffic lights'},
		{key: 'client.showPlayerStatus', label: 'Player status on name tags'},
	];
	$scope.optionOn = function (o) { return o.invert ? !$scope.val(o.key) : !!$scope.val(o.key); };

	$scope.toggle = function (key) {
		if (!$scope.canEdit()) return;
		setPending(key, !$scope.val(key), 0);
	};

	$scope.setAggression = function (v) {
		if (!$scope.canEdit()) return;
		setPending('client.trafficAggression', v, 0);
	};

	$scope.aggression = function () {
		var a = Number($scope.val('client.trafficAggression'));
		if (!a) return "game";
		if (a < 0.22) return "careful";
		if (a < 0.4) return "normal";
		return "fast";
	};

	// Traffic table: the setting per player and the server's limit for a row ('road' / 'parked')
	$scope.trafficKey = function (kind) { return kind === 'road' ? 'client.roadTraffic' : 'client.parkedTraffic'; };
	$scope.totalKey = function (kind) { return kind === 'road' ? 'server.roadTrafficTotal' : 'server.parkedTrafficTotal'; };

	// "You: 5 driving, 8 parked · 3 online" – what this player gets now (the server limit shared,
	// at most the cars loaded at the join); "· rejoin for more" only when the share is bigger
	$scope.trafficNote = function () {
		var s = ($scope.state && $scope.state.settings) || {};
		var more = false;
		function gets(share, pool) {
			if (typeof share !== "number") return "?";
			if (typeof pool !== "number") return share;
			if (share > pool) more = true;
			return Math.min(share, pool);
		}
		var text = "You: " + gets(s.shareRoad, s.poolRoad) + " driving, " + gets(s.shareParked, s.poolParked) +
			" parked · " + (s.players || 1) + " online";
		return more ? text + " · rejoin for more" : text;
	};
	// lengths that were just set but not confirmed by the server yet: {day, night, age, timer}
	$scope.pending = null;

	// the next value of LENGTHS above (direction 1) or below (-1) `minutes`; at the ends it stays
	function nextLength(minutes, direction) {
		var i;
		if (direction > 0) {
			for (i = 0; i < LENGTHS.length; i++) if (LENGTHS[i] > minutes) return LENGTHS[i];
			return LENGTHS[LENGTHS.length - 1];
		}
		for (i = LENGTHS.length - 1; i >= 0; i--) if (LENGTHS[i] < minutes) return LENGTHS[i];
		return LENGTHS[0];
	}

	// 50 -> "50 min", 90 -> "1 h 30", 120 -> "2 h"
	$scope.lengthText = function (minutes) {
		if (minutes < 60) return minutes + " min";
		var h = Math.floor(minutes / 60), m = minutes % 60;
		return h + " h" + (m ? " " + pad(m) : "");
	};

	function pad(n) { return (n < 10 ? "0" : "") + n; }

	$scope.clock = function () {
		var s = $scope.state;
		if (!s || typeof s.hour !== "number") return "--:--";
		var total = Math.floor(s.hour * 60 + 0.5) % (24 * 60);
		return pad(Math.floor(total / 60)) + ":" + pad(total % 60);
	};

	$scope.phaseText = function () {
		var s = $scope.state;
		if (!s || typeof s.hour !== "number") return "";
		var phase = s.isDay ? "Day" : "Night";
		if (s.paused) return phase + " · paused";
		if (s.realtime) return phase + " · real time";
		if (!s.running) return phase + " · stopped";
		if (typeof s.secondsToSwitch !== "number") return phase;
		var min = Math.max(0, Math.round(s.secondsToSwitch / 60));
		return phase + " · " + (s.isDay ? "night" : "day") + " in " + (min < 1 ? "< 1" : min) + " min";
	};

	$scope.lengths = function () {
		var s = $scope.state || {};
		var p = $scope.pending;
		return {
			day: p ? p.day : (s.dayMinutes || 0),
			night: p ? p.night : (s.nightMinutes || 0)
		};
	};

	// time controls: lua/ge/extensions/sharedCareer/env.lua
	function timeControl(cmd) {
		bngApi.engineLua('if sharedCareer_env then sharedCareer_env.' + cmd + ' end');
	}

	$scope.shift = function (delta) {
		if (!$scope.state || !$scope.state.canControl) return;
		timeControl('uiShiftHour(' + Number(delta) + ')');
	};

	$scope.setHour = function (hour) {
		if (!$scope.state || !$scope.state.canControl) return;
		timeControl('uiSetHour(' + Number(hour) + ')');
	};

	// "run", "pause" or "real" (real time)
	$scope.clockMode = function () {
		var s = $scope.state || {};
		if (s.realtime) return "real";
		return s.paused ? "pause" : "run";
	};

	// Pause also ends real time (the server stops the clock at the real time).
	$scope.setClockMode = function (mode) {
		if (!$scope.state || !$scope.state.canControl) return;
		var current = $scope.clockMode();
		if (mode === current) return;
		if (mode === "real") timeControl('uiSetRealtime(true)');
		else if (mode === "pause") timeControl('uiSetPaused(true)');
		else if (current === "real") timeControl('uiSetRealtime(false)');
		else timeControl('uiSetPaused(false)');
	};

	// direction 1 (+) or -1 (−); sent once the clicks stop (SEND_DELAY)
	$scope.changeLength = function (which, direction) {
		if (!$scope.state || !$scope.state.canControl) return;
		var l = $scope.lengths();
		var p = $scope.pending || {day: l.day, night: l.night};
		if (p.timer) clearTimeout(p.timer);
		p[which] = nextLength(Number(p[which]) || 0, direction);
		p.age = 0;
		p.timer = setTimeout(function () {
			p.timer = null;
			timeControl('uiSetLengths(' + p.day + ',' + p.night + ')');
		}, SEND_DELAY);
		$scope.pending = p;
	};

	$scope.$on('SharedCareerState', function (event, data) {
		$scope.$evalAsync(function () {
			$scope.state = data || null;
			// the server confirmed settings: remove pending values that are correct now
			var s = (data && data.settings) || {};
			Object.keys(pending).forEach(function (key) {
				var p = pending[key];
				if (!p.timer && s[field(key)] === p.value) delete pending[key];
			});
			// the server confirmed (or rejected) the new lengths: show the server's values again
			if ($scope.pending && !$scope.pending.timer && data && data.dayMinutes === $scope.pending.day && data.nightMinutes === $scope.pending.night) {
				$scope.pending = null;
			}
		});
	});

	// if the server doesn't apply a change, show the real value again after 3 s;
	// every 2 s: still visible (keeps the state coming, see reportVisible)
	var ticks = 0;
	var pendingTimer = setInterval(function () {
		ticks++;
		if (ticks % 2 === 0 && !$scope.collapsed) reportVisible(true);
		if ($scope.pending && !$scope.pending.timer) {
			$scope.pending.age = ($scope.pending.age || 0) + 1;
			if ($scope.pending.age > 3) $scope.$evalAsync(function () { $scope.pending = null; });
		}
		Object.keys(pending).forEach(function (key) {
			var p = pending[key];
			if (p.timer) return;
			p.age = (p.age || 0) + 1;
			if (p.age > PENDING_MAX) $scope.$evalAsync(function () { delete pending[key]; });
		});
	}, 1000);
	$scope.$on('$destroy', function () { clearInterval(pendingTimer); reportVisible(false); });

	reportVisible(!$scope.collapsed);
	bngApi.engineLua('if sharedCareer_menu then sharedCareer_menu.uiRequest() end');
	// fetch an open dialog (e.g. if it arrived while the main menu had hidden the apps)
	bngApi.engineLua('if sharedCareer_welcome then sharedCareer_welcome.uiRequestDialog() end');
}]);
