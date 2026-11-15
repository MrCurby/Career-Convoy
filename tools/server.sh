#!/usr/bin/env bash
# SharedCareer :: Server-Steuerung für einen BeamMP-Server (läuft in einer screen-Sitzung)
#
# Diese Datei in den Server-Ordner legen (dort, wo BeamMP-Server und ServerConfig.toml liegen),
# einmal ausführbar machen:   chmod +x server.sh
#
#   ./server.sh start          Server im Hintergrund starten
#   ./server.sh stop           Server sauber beenden ("exit" in der Konsole, notfalls hart)
#   ./server.sh restart        stop + start
#   ./server.sh status         läuft er? (mit PID)
#   ./server.sh console        Live-Konsole öffnen  –  verlassen mit Strg+A, dann D
#                              (NICHT Strg+C: das beendet den Server)
#   ./server.sh logs [n]       letzte n Zeilen der Server.log (Standard 100)
#   ./server.sh follow         Server.log live mitlesen (Strg+C beendet nur das Mitlesen)
#   ./server.sh cmd "sc time"  einen Befehl in die Server-Konsole schicken, z.B. "sc get"
#   ./server.sh update         neuestes Release von GitHub holen und einspielen (stoppen,
#                              sichern, entpacken, starten) – nur wenn es neuer ist
#   ./server.sh update --force dasselbe, auch wenn die Version schon installiert ist
#   ./server.sh update x.zip   eine bestimmte zip aus dem Ordner einspielen
#   ./server.sh check          installierte Version und neueste auf GitHub anzeigen
#
# GitHub-Repository in server.conf (im selben Ordner) eintragen:
#   REPO="dein-name/SharedCareer"
#   GITHUB_TOKEN=""            nur für ein privates Repository nötig (Token mit Lesezugriff)
# Ohne REPO nimmt "update" die neueste SharedCareer-*.zip im Ordner.
#
# Name der screen-Sitzung = Ordnername (z.B. "sctest"). Mehrere Server in verschiedenen
# Ordnern stören sich dadurch nicht.

set -u

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DIR" || exit 1
SESSION="${SC_SESSION:-$(basename "$DIR")}"
LOG="$DIR/Server.log"
STOP_WAIT=20   # Sekunden, die der Server zum sauberen Beenden bekommt
REPO="${SC_REPO:-}"
API="${SC_API:-https://api.github.com}"   # nur zum Testen änderbar
GITHUB_TOKEN="${GITHUB_TOKEN:-}"
# shellcheck disable=SC1091
[ -f "$DIR/server.conf" ] && . "$DIR/server.conf"

red()   { printf '\033[31m%s\033[0m\n' "$*" >&2; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
info()  { printf '\033[36m%s\033[0m\n' "$*"; }

need_screen() {
	if ! command -v screen >/dev/null 2>&1; then
		red "screen ist nicht installiert. Installieren mit:  sudo apt install screen"
		exit 1
	fi
}

# Server-Programm im Ordner finden (Name hängt von der Linux-Version ab)
find_binary() {
	local f
	for f in "$DIR"/BeamMP-Server*; do
		if [ -f "$f" ] && [ -x "$f" ]; then echo "$f"; return 0; fi
	done
	for f in "$DIR"/BeamMP-Server*; do
		if [ -f "$f" ]; then chmod +x "$f" && echo "$f" && return 0; fi
	done
	return 1
}

running() {
	screen -ls 2>/dev/null | grep -qE "[0-9]+\.${SESSION}[[:space:]]"
}

server_pid() {
	# PID des Server-Prozesses in diesem Ordner
	local p
	# Nur der Server selbst (Prozessname), nicht die bash-Hülle der screen-Sitzung
	for p in $(pgrep "^BeamMP-Server" 2>/dev/null); do
		if [ "$(readlink -f "/proc/$p/cwd" 2>/dev/null)" = "$DIR" ]; then echo "$p"; return 0; fi
	done
	return 1
}

send() {
	# Text + Enter in die Konsole tippen
	screen -S "$SESSION" -p 0 -X stuff "$1$(printf '\r')"
}

cmd_start() {
	need_screen
	if running; then info "Läuft schon (Sitzung '$SESSION'). Konsole: ./server.sh console"; return 0; fi
	local bin
	if ! bin="$(find_binary)"; then red "Kein BeamMP-Server-Programm in $DIR gefunden."; exit 1; fi
	if [ ! -f "$DIR/ServerConfig.toml" ]; then info "Hinweis: keine ServerConfig.toml – BeamMP legt beim ersten Start eine an."; fi
	screen -dmS "$SESSION" bash -c "cd '$DIR' && '$bin'; echo; echo 'Server beendet. Taste drücken...'; read -r -n1"
	sleep 2
	if running; then
		green "Gestartet: $(basename "$bin") in Sitzung '$SESSION'."
		info "Konsole: ./server.sh console   |   Log: ./server.sh follow"
	else
		red "Start fehlgeschlagen. Letzte Logzeilen:"; cmd_logs 30
		exit 1
	fi
}

cmd_stop() {
	need_screen
	if ! running; then
		local p; if p="$(server_pid)"; then
			info "Keine screen-Sitzung, aber Server-Prozess $p läuft – wird beendet."
			kill "$p"; sleep 3; kill -0 "$p" 2>/dev/null && kill -9 "$p"
		fi
		info "Läuft nicht."; return 0
	fi
	info "Stoppe Server (Sitzung '$SESSION') ..."
	send "exit"
	local i
	for ((i = 0; i < STOP_WAIT; i++)); do
		sleep 1
		if ! server_pid >/dev/null; then break; fi
	done
	if p="$(server_pid)"; then
		red "Server reagiert nicht – wird hart beendet (PID $p)."
		kill "$p"; sleep 3; kill -0 "$p" 2>/dev/null && kill -9 "$p"
	fi
	# screen-Sitzung wartet auf Tastendruck -> schließen
	running && screen -S "$SESSION" -X quit
	green "Gestoppt."
}

cmd_status() {
	need_screen
	local p
	if running; then
		p="$(server_pid || true)"
		green "Läuft (Sitzung '$SESSION'${p:+, PID $p})."
		if [ -f "$LOG" ]; then
			local v; v="$(grep -o 'SharedCareer\] Version [0-9.]*' "$LOG" | tail -n 1)"
			[ -n "$v" ] && info "${v#*] }"
		fi
	else
		red "Läuft nicht."
	fi
}

cmd_console() {
	need_screen
	if ! running; then red "Server läuft nicht. Starten: ./server.sh start"; exit 1; fi
	info "Konsole öffnet sich. Verlassen: Strg+A, dann D  (NICHT Strg+C – das beendet den Server)"
	sleep 2
	screen -r "$SESSION"
}

cmd_logs() {
	if [ ! -f "$LOG" ]; then red "Keine Server.log in $DIR."; exit 1; fi
	tail -n "${1:-100}" "$LOG"
}

cmd_follow() {
	if [ ! -f "$LOG" ]; then red "Keine Server.log in $DIR."; exit 1; fi
	info "Live-Log (Strg+C beendet nur das Mitlesen, der Server läuft weiter)"
	tail -n 30 -f "$LOG"
}

cmd_cmd() {
	need_screen
	if [ -z "${1:-}" ]; then red 'Befehl fehlt, z.B.: ./server.sh cmd "sc time"'; exit 1; fi
	if ! running; then red "Server läuft nicht."; exit 1; fi
	local before=0
	[ -f "$LOG" ] && before="$(wc -l < "$LOG")"
	send "$1"
	sleep 1
	# Antwort aus dem Log zeigen (alles, was seit dem Befehl dazugekommen ist)
	[ -f "$LOG" ] && tail -n "+$((before + 1))" "$LOG"
}

#== GitHub ======================================================================

installed_version() {
	sed -n 's/^local VERSION = "\(.*\)"/\1/p' "$DIR/Resources/Server/SharedCareer/main.lua" 2>/dev/null
}

# curl mit Token (falls gesetzt)
gh_curl() {
	if [ -n "$GITHUB_TOKEN" ]; then
		curl -fsSL -H "Authorization: Bearer $GITHUB_TOKEN" "$@"
	else
		curl -fsSL "$@"
	fi
}

# Holt das neueste Release. Setzt LATEST_VERSION und LATEST_ASSET (API-Adresse der zip).
fetch_latest() {
	if ! command -v curl >/dev/null 2>&1; then red "curl fehlt. Installieren mit:  sudo apt install curl"; exit 1; fi
	local json
	if ! json="$(gh_curl -H "Accept: application/vnd.github+json" "$API/repos/$REPO/releases/latest")"; then
		red "GitHub-Abfrage fehlgeschlagen ($REPO). Repository-Name in server.conf richtig? Privat -> GITHUB_TOKEN nötig."
		exit 1
	fi
	LATEST_VERSION="$(printf '%s' "$json" | grep -o '"tag_name": *"[^"]*"' | head -n 1 | sed 's/.*"v\{0,1\}\([^"]*\)"$/\1/')"
	LATEST_ASSET="$(printf '%s' "$json" | grep -o '"url": *"[^"]*/releases/assets/[0-9]*"' | head -n 1 | sed 's/.*"\(http[^"]*\)"$/\1/')"
	if [ -z "$LATEST_VERSION" ] || [ -z "$LATEST_ASSET" ]; then
		red "Neuestes Release von $REPO hat keine zip."; exit 1
	fi
}

cmd_check() {
	local have; have="$(installed_version)"
	info "Installiert: ${have:-keine}"
	if [ -z "$REPO" ]; then info "Kein REPO in server.conf – GitHub wird nicht abgefragt."; return 0; fi
	fetch_latest
	info "Neueste auf GitHub ($REPO): $LATEST_VERSION"
	if [ "$have" = "$LATEST_VERSION" ]; then green "Aktuell."; else green "Update verfügbar: ./server.sh update"; fi
}

# Lädt das neueste Release in den Ordner; gibt den Dateinamen aus (leer = schon aktuell).
download_latest() {
	local force="$1"
	fetch_latest
	local have; have="$(installed_version)"
	if [ "$have" = "$LATEST_VERSION" ] && [ "$force" != 1 ]; then
		green "Schon aktuell (Version $have). Neu einspielen trotzdem: ./server.sh update --force" >&2
		return 0
	fi
	local file="$DIR/SharedCareer-$LATEST_VERSION.zip"
	info "Lade SharedCareer $LATEST_VERSION von GitHub ($REPO) ..." >&2
	if ! gh_curl -H "Accept: application/octet-stream" -o "$file.part" "$LATEST_ASSET" || ! unzip -tq "$file.part" >/dev/null 2>&1; then
		rm -f "$file.part"; red "Download fehlgeschlagen." >&2; exit 1
	fi
	mv "$file.part" "$file"
	echo "$file"
}

cmd_update() {
	if ! command -v unzip >/dev/null 2>&1; then red "unzip fehlt. Installieren mit:  sudo apt install unzip"; exit 1; fi
	local zip="" force=0 a
	for a in "$@"; do
		case "$a" in
			--force|-f) force=1 ;;
			"") ;;
			*) zip="$a" ;;
		esac
	done
	if [ -z "$zip" ] && [ -n "$REPO" ]; then
		zip="$(download_latest "$force")" || exit 1
		[ -z "$zip" ] && return 0
	elif [ -z "$zip" ]; then
		zip="$(ls -1 "$DIR"/SharedCareer-*.zip 2>/dev/null | sort -V | tail -n 1)"
		if [ -z "$zip" ]; then red "Keine SharedCareer-*.zip im Ordner und kein REPO in server.conf."; exit 1; fi
	fi
	if [ ! -f "$zip" ]; then red "Datei nicht gefunden: $zip"; exit 1; fi
	info "Update mit $(basename "$zip") (vorher: $(installed_version))"
	local was_running=0
	running && was_running=1
	cmd_stop
	local backup="sharedcareer-backup-$(date +%F-%H%M%S).tgz"
	local what=() f
	for f in Resources/Server/SharedCareer Resources/Client/SharedCareer.zip; do [ -e "$f" ] && what+=("$f"); done
	if [ "${#what[@]}" -gt 0 ]; then
		if tar czf "$backup" "${what[@]}"; then info "Sicherung: $backup"; else red "Sicherung fehlgeschlagen – Abbruch."; exit 1; fi
	fi
	# server.sh selbst wird mit ersetzt; das ist sicher, weil bash dieses Skript schon komplett
	# gelesen hat (alles steckt in Funktionen, siehe main ganz unten).
	unzip -o -q "$zip" || { red "Entpacken fehlgeschlagen."; exit 1; }
	chmod +x "$DIR/server.sh" 2>/dev/null
	# alte zips aufräumen (die neuesten 3 bleiben)
	ls -1 "$DIR"/SharedCareer-*.zip 2>/dev/null | sort -V | head -n -3 | xargs -r rm -f
	green "Entpackt (Einstellungen in Resources/Server/SharedCareer/config bleiben erhalten)."
	cmd_start
	sleep 3
	grep -h "SharedCareer\]" "$LOG" 2>/dev/null | tail -n 5
	[ "$was_running" = 0 ] && info "(Server lief vorher nicht – jetzt gestartet.)"
}

usage() {
	sed -n '2,31p' "$DIR/server.sh" | sed 's/^# \{0,1\}//'
}

main() {
	case "${1:-}" in
		start)   cmd_start ;;
		stop)    cmd_stop ;;
		restart) cmd_stop; sleep 1; cmd_start ;;
		status)  cmd_status ;;
		console) cmd_console ;;
		logs)    cmd_logs "${2:-100}" ;;
		follow)  cmd_follow ;;
		cmd)     shift; cmd_cmd "$*" ;;
		update)  shift; cmd_update "$@" ;;
		check)   cmd_check ;;
		*)       usage ;;
	esac
}

# In einer Zeile mit exit: bash liest sie komplett, bevor es loslegt. Ersetzt "update" diese
# Datei, läuft trotzdem die alte Fassung sauber zu Ende.
main "$@"; exit $?
