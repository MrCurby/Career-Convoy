// SharedCareer-Menü (ehemals "Tageszeit"): Reiter Zeit, Traffic und Optionen.
// Alles, was hier eingestellt wird, geht an den Server und gilt sofort für ALLE Spieler.
//
// Reiter Zeit: Uhrzeit des Servers und ob Tag oder Nacht ist.
// Jeder Spieler kann die Uhrzeit (±1 Std., Morgen/Mittag/Abend/Nacht) und die Länge von
// Tag und Nacht verstellen; der Server übernimmt das sofort für alle.
// "Stopp" hält die Uhr für alle bei der aktuellen Uhrzeit an, "Weiter" lässt sie ab dort laufen.
// Reiter Traffic: fahrende/geparkte Autos pro Spieler, KI-Fahrstil.
// Reiter Optionen: Kollision mit Autos/Fußgängern, Ampeln synchron, Status am Namensschild,
// Server-Limit.
// Reiter Players: Navigate (Wegmarkierung zum Spieler), Watch (Kamera), Go (Teleport, nur wenn
// der Server es erlaubt). Spielernamen werden als JSON-String an Lua übergeben.
// Tankstellen-Preise: eigene App SharedCareer-Fuel (nutzt dieselben Daten und Stile).
// Taste F7 (änderbar unter Optionen → Steuerung → BeamMP) klappt das Menü ein/aus.
// Zahlen werden erst gesendet, wenn man kurz nicht mehr klickt (SEND_DELAY), damit nicht jeder
// Klick bei allen eine Einblendung auslöst.
// Über die Lasche am rechten Rand lässt sich das Fenster ein- und ausklappen (wie die
// BeamMP-Spielerliste); der Zustand wird im Browser-Speicher des Spiels gemerkt.
//
// Daten kommen jede Sekunde per guihook "SharedCareerTime" aus
// lua/ge/extensions/sharedCareer/env.lua (uiState); Klicks gehen per bngApi.engineLua an
// sharedCareer_env.uiSetHour / uiShiftHour / uiSetLengths.
//
// Hinweis: Oberste Ebene nur mit var/function – das Spiel wertet app.js beim Neuladen der
// Apps erneut im selben Bereich aus.

var sharedCareerTimeApp = angular.module('beamng.apps');

sharedCareerTimeApp.directive('sharedCareerTime', [function () {
	return {
		templateUrl: '/ui/modules/apps/SharedCareer-Time/app.html',
		replace: true,
		restrict: 'EA',
		scope: true
	};
}]);

sharedCareerTimeApp.controller('SharedCareerTime', ['$scope', '$element', function ($scope, $element) {
	var LENGTH_STEP = 5;       // Minuten pro Klick bei Tag/Nacht-Länge
	var LENGTH_MIN = 1, LENGTH_MAX = 600;

	var STORAGE_KEY = "sharedCareerTimeCollapsed";

	$scope.state = null;
	// Eingeklappt (nur die Lasche am Rand sichtbar)? Wird pro Spieler gemerkt.
	$scope.collapsed = false;
	try { $scope.collapsed = window.localStorage.getItem(STORAGE_KEY) === "1"; } catch (e) {}

	// Menü und Fuel-Fenster liegen an derselben Stelle am rechten Rand: öffnet sich eins, klappt
	// das andere zu (Fenster-Ereignis "sharedCareerPanelOpen").
	function setCollapsed(value) {
		$scope.collapsed = value;
		try { window.localStorage.setItem(STORAGE_KEY, value ? "1" : "0"); } catch (e) {}
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

	// Aktiver Reiter, ebenfalls gemerkt
	var TAB_KEY = "sharedCareerMenuTab";
	$scope.tab = "time";
	try { $scope.tab = window.localStorage.getItem(TAB_KEY) || "time"; } catch (e) {}
	if (["time", "traffic", "options", "players"].indexOf($scope.tab) < 0) $scope.tab = "time";
	$scope.setTab = function (tab) {
		$scope.tab = tab;
		try { window.localStorage.setItem(TAB_KEY, tab); } catch (e) {}
	};

	// Dialog (guihook "SharedCareerDialog" aus welcome.lua): Willkommen oder Meldung des Servers
	$scope.dialog = null;
	// Dialog-Host an <body> hängen (Angular-Bindungen bleiben erhalten), beim Schließen des
	// Fensters wieder entfernen. Klappt das nicht, bleibt er im Fenster – funktioniert dann wie vorher.
	// Erst nach dem Verknüpfen verschieben (sonst bringt es Angulars Knotenliste durcheinander).
	var dialogHost = null;
	setTimeout(function () {
		try {
			var host = $element[0].querySelector('.sct-dialog-host');
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

	// Klick aufs Lenkrad-Logo: Willkommensdialog wieder anzeigen
	$scope.showWelcome = function () {
		bngApi.engineLua('if sharedCareer_welcome then sharedCareer_welcome.show(true) end');
	};

	//== Reiter Players ==
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

	// Menü-Taste (Standard F7, siehe players.lua): ein-/ausklappen
	$scope.$on('SharedCareerToggle', function () {
		$scope.$evalAsync(function () { $scope.toggleCollapsed(); });
	});

	//== Einstellungen (Reiter Traffic / Optionen) ==
	var SEND_DELAY = 600;   // ms Ruhe nach dem letzten Klick, dann senden
	var PENDING_MAX = 4;    // s: danach wieder den Server-Wert zeigen, falls nichts zurückkam
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

	// "du: 5 · live bis 10" – was dieser Spieler bekommt und bis wohin es ohne Neu-Join geht
	$scope.trafficHint = function (kind) {
		var s = ($scope.state && $scope.state.settings) || {};
		var share = kind === 'road' ? s.shareRoad : s.shareParked;
		var pool = kind === 'road' ? s.poolRoad : s.poolParked;
		var parts = [];
		if (typeof share === "number") parts.push("you: " + Math.min(share, typeof pool === "number" ? pool : share));
		if (typeof pool === "number") parts.push("live up to " + pool);
		return parts.join(" · ");
	};
	// Längen, die gerade eingestellt, aber noch nicht vom Server bestätigt sind
	$scope.pending = null;

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

	function engine(cmd) {
		bngApi.engineLua('if sharedCareer_env then sharedCareer_env.' + cmd + ' end');
	}

	$scope.shift = function (delta) {
		if (!$scope.state || !$scope.state.canControl) return;
		engine('uiShiftHour(' + Number(delta) + ')');
	};

	$scope.setHour = function (hour) {
		if (!$scope.state || !$scope.state.canControl) return;
		engine('uiSetHour(' + Number(hour) + ')');
	};

	$scope.togglePause = function () {
		if (!$scope.state || !$scope.state.canControl) return;
		engine('uiSetPaused(' + ($scope.state.paused ? 'false' : 'true') + ')');
	};

	$scope.changeLength = function (which, delta) {
		if (!$scope.state || !$scope.state.canControl) return;
		var l = $scope.lengths();
		var next = {day: l.day, night: l.night};
		next[which] = Math.max(LENGTH_MIN, Math.min(LENGTH_MAX, (Number(next[which]) || 0) + delta));
		$scope.pending = next;
		engine('uiSetLengths(' + next.day + ',' + next.night + ')');
	};

	$scope.$on('SharedCareerTime', function (event, data) {
		$scope.$evalAsync(function () {
			$scope.state = data || null;
			// Server hat Einstellungen bestätigt: wartende Werte, die jetzt stimmen, entfernen
			var s = (data && data.settings) || {};
			Object.keys(pending).forEach(function (key) {
				var p = pending[key];
				if (!p.timer && s[field(key)] === p.value) delete pending[key];
			});
			// Server hat die neuen Längen bestätigt (oder abgelehnt): Anzeige wieder vom Server
			if ($scope.pending && data && data.dayMinutes === $scope.pending.day && data.nightMinutes === $scope.pending.night) {
				$scope.pending = null;
			}
		});
	});

	// Falls der Server eine Änderung nicht übernimmt, nach 3 s wieder den echten Wert zeigen
	var pendingTimer = setInterval(function () {
		if ($scope.pending) {
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
	$scope.$on('$destroy', function () { clearInterval(pendingTimer); });

	engine('uiRequest()');
	// Offenen Dialog abholen (z.B. wenn er kam, während das Hauptmenü die Apps ausgeblendet hatte)
	bngApi.engineLua('if sharedCareer_welcome then sharedCareer_welcome.uiRequestDialog() end');
}]);
