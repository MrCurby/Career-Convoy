#!/usr/bin/env bash
# SharedCareer :: server control for a BeamMP server (runs it in a screen session)
#
# Put this file into the server folder (where BeamMP-Server and ServerConfig.toml are),
# make it executable once:   chmod +x server.sh
#
#   ./server.sh start          start the server in the background
#   ./server.sh stop           stop it cleanly ("exit" in the console, killed if needed)
#   ./server.sh restart        stop + start
#   ./server.sh status         is it running? (with PID and SharedCareer version)
#   ./server.sh console        open the live console  –  leave with Ctrl+A, then D
#                              (NOT Ctrl+C: that stops the server)
#   ./server.sh logs [n]       last n lines of Server.log (default 100)
#   ./server.sh follow         follow Server.log live (Ctrl+C only stops following)
#   ./server.sh cmd "sc time"  send a command to the server console, e.g. "sc get"
#   ./server.sh update         install the newest GitHub release (stop, back up, unpack,
#                              start) – only if it is newer than the installed version
#   ./server.sh update --force the same, even if that version is already installed
#   ./server.sh update x.zip   install a specific zip from this folder
#   ./server.sh check          show the installed version and the newest one on GitHub
#
# Put the GitHub repository into server.conf (same folder):
#   REPO="MrCurby/SharedCareer"
#   GITHUB_TOKEN=""            only needed for a private repository (token with read access)
# Without REPO, "update" installs the newest SharedCareer-*.zip in this folder.
#
# The screen session is named after the folder (e.g. "sctest"), so several servers in
# different folders don't get in each other's way.

set -u

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DIR" || exit 1
SESSION="${SC_SESSION:-$(basename "$DIR")}"
LOG="$DIR/Server.log"
STOP_WAIT=20   # seconds the server gets to shut down cleanly
REPO="${SC_REPO:-}"
API="${SC_API:-https://api.github.com}"   # only changed for testing
GITHUB_TOKEN="${GITHUB_TOKEN:-}"
# shellcheck disable=SC1091
[ -f "$DIR/server.conf" ] && . "$DIR/server.conf"

red()   { printf '\033[31m%s\033[0m\n' "$*" >&2; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
info()  { printf '\033[36m%s\033[0m\n' "$*"; }

need_screen() {
	if ! command -v screen >/dev/null 2>&1; then
		red "screen is not installed. Install it with:  sudo apt install screen"
		exit 1
	fi
}

# find the server program in the folder (its name depends on the Linux version)
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
	# PID of the server process in this folder
	local p
	# only the server itself (process name), not the bash wrapper of the screen session
	for p in $(pgrep "^BeamMP-Server" 2>/dev/null); do
		if [ "$(readlink -f "/proc/$p/cwd" 2>/dev/null)" = "$DIR" ]; then echo "$p"; return 0; fi
	done
	return 1
}

send() {
	# type text + Enter into the console
	screen -S "$SESSION" -p 0 -X stuff "$1$(printf '\r')"
}

cmd_start() {
	need_screen
	if running; then info "Already running (session '$SESSION'). Console: ./server.sh console"; return 0; fi
	local bin
	if ! bin="$(find_binary)"; then red "No BeamMP-Server program found in $DIR."; exit 1; fi
	if [ ! -f "$DIR/ServerConfig.toml" ]; then info "Note: no ServerConfig.toml yet – BeamMP creates one on the first start."; fi
	screen -dmS "$SESSION" bash -c "cd '$DIR' && '$bin'; echo; echo 'Server stopped. Press a key...'; read -r -n1"
	sleep 2
	if running; then
		green "Started: $(basename "$bin") in session '$SESSION'."
		info "Console: ./server.sh console   |   Log: ./server.sh follow"
	else
		red "Start failed. Last log lines:"; cmd_logs 30
		exit 1
	fi
}

cmd_stop() {
	need_screen
	if ! running; then
		local p; if p="$(server_pid)"; then
			info "No screen session, but server process $p is running – stopping it."
			kill "$p"; sleep 3; kill -0 "$p" 2>/dev/null && kill -9 "$p"
		fi
		info "Not running."; return 0
	fi
	info "Stopping server (session '$SESSION') ..."
	send "exit"
	local i
	for ((i = 0; i < STOP_WAIT; i++)); do
		sleep 1
		if ! server_pid >/dev/null; then break; fi
	done
	if p="$(server_pid)"; then
		red "Server does not respond – killing it (PID $p)."
		kill "$p"; sleep 3; kill -0 "$p" 2>/dev/null && kill -9 "$p"
	fi
	# the screen session waits for a key press -> close it
	running && screen -S "$SESSION" -X quit
	green "Stopped."
}

cmd_status() {
	need_screen
	local p
	if running; then
		p="$(server_pid || true)"
		green "Running (session '$SESSION'${p:+, PID $p})."
		if [ -f "$LOG" ]; then
			local v; v="$(grep -o 'SharedCareer\] Version [0-9.]*' "$LOG" | tail -n 1)"
			[ -n "$v" ] && info "${v#*] }"
		fi
	else
		red "Not running."
	fi
}

cmd_console() {
	need_screen
	if ! running; then red "Server is not running. Start it with: ./server.sh start"; exit 1; fi
	info "Opening the console. Leave with Ctrl+A, then D  (NOT Ctrl+C – that stops the server)"
	sleep 2
	screen -r "$SESSION"
}

cmd_logs() {
	if [ ! -f "$LOG" ]; then red "No Server.log in $DIR."; exit 1; fi
	tail -n "${1:-100}" "$LOG"
}

cmd_follow() {
	if [ ! -f "$LOG" ]; then red "No Server.log in $DIR."; exit 1; fi
	info "Live log (Ctrl+C only stops following, the server keeps running)"
	tail -n 30 -f "$LOG"
}

cmd_cmd() {
	need_screen
	if [ -z "${1:-}" ]; then red 'Befehl fehlt, z.B.: ./server.sh cmd "sc time"'; exit 1; fi
	if ! running; then red "Server is not running."; exit 1; fi
	local before=0
	[ -f "$LOG" ] && before="$(wc -l < "$LOG")"
	send "$1"
	sleep 1
	# show the answer from the log (everything added since the command)
	[ -f "$LOG" ] && tail -n "+$((before + 1))" "$LOG"
}

#== GitHub ======================================================================

installed_version() {
	sed -n 's/^local VERSION = "\(.*\)"/\1/p' "$DIR/Resources/Server/SharedCareer/main.lua" 2>/dev/null
}

# curl with token (if set)
gh_curl() {
	if [ -n "$GITHUB_TOKEN" ]; then
		curl -fsSL -H "Authorization: Bearer $GITHUB_TOKEN" "$@"
	else
		curl -fsSL "$@"
	fi
}

# Gets the newest release. Sets LATEST_VERSION and LATEST_ASSET (API address of the zip).
fetch_latest() {
	if ! command -v curl >/dev/null 2>&1; then red "curl is missing. Install it with:  sudo apt install curl"; exit 1; fi
	local json
	if ! json="$(gh_curl -H "Accept: application/vnd.github+json" "$API/repos/$REPO/releases/latest")"; then
		red "GitHub request failed ($REPO). Is the repository name in server.conf right? A private repository needs GITHUB_TOKEN."
		exit 1
	fi
	LATEST_VERSION="$(printf '%s' "$json" | grep -o '"tag_name": *"[^"]*"' | head -n 1 | sed 's/.*"v\{0,1\}\([^"]*\)"$/\1/')"
	LATEST_ASSET="$(printf '%s' "$json" | grep -o '"url": *"[^"]*/releases/assets/[0-9]*"' | head -n 1 | sed 's/.*"\(http[^"]*\)"$/\1/')"
	if [ -z "$LATEST_VERSION" ] || [ -z "$LATEST_ASSET" ]; then
		red "The newest release of $REPO has no zip."; exit 1
	fi
}

cmd_check() {
	local have; have="$(installed_version)"
	info "Installed: ${have:-none}"
	if [ -z "$REPO" ]; then info "No REPO in server.conf – GitHub is not checked."; return 0; fi
	fetch_latest
	info "Newest on GitHub ($REPO): $LATEST_VERSION"
	if [ "$have" = "$LATEST_VERSION" ]; then green "Up to date."; else green "Update available: ./server.sh update"; fi
}

# Downloads the newest release into the folder; prints the file name (empty = already up to date).
download_latest() {
	local force="$1"
	fetch_latest
	local have; have="$(installed_version)"
	if [ "$have" = "$LATEST_VERSION" ] && [ "$force" != 1 ]; then
		green "Already up to date (version $have). To reinstall anyway: ./server.sh update --force" >&2
		return 0
	fi
	local file="$DIR/SharedCareer-$LATEST_VERSION.zip"
	info "Downloading SharedCareer $LATEST_VERSION from GitHub ($REPO) ..." >&2
	if ! gh_curl -H "Accept: application/octet-stream" -o "$file.part" "$LATEST_ASSET" || ! unzip -tq "$file.part" >/dev/null 2>&1; then
		rm -f "$file.part"; red "Download failed." >&2; exit 1
	fi
	mv "$file.part" "$file"
	echo "$file"
}

cmd_update() {
	if ! command -v unzip >/dev/null 2>&1; then red "unzip is missing. Install it with:  sudo apt install unzip"; exit 1; fi
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
		if [ -z "$zip" ]; then red "No SharedCareer-*.zip in this folder and no REPO in server.conf."; exit 1; fi
	fi
	if [ ! -f "$zip" ]; then red "File not found: $zip"; exit 1; fi
	info "Updating with $(basename "$zip") (installed before: $(installed_version))"
	local was_running=0
	running && was_running=1
	cmd_stop
	local backup="sharedcareer-backup-$(date +%F-%H%M%S).tgz"
	local what=() f
	for f in Resources/Server/SharedCareer Resources/Client/SharedCareer.zip; do [ -e "$f" ] && what+=("$f"); done
	if [ "${#what[@]}" -gt 0 ]; then
		if tar czf "$backup" "${what[@]}"; then info "Backup: $backup"; else red "Backup failed – aborting."; exit 1; fi
	fi
	# server.sh itself is replaced too; that is safe because bash has already read this script
	# completely (everything sits in functions, see main at the very bottom).
	unzip -o -q "$zip" || { red "Unpacking failed."; exit 1; }
	chmod +x "$DIR/server.sh" 2>/dev/null
	# clean up old zips (the newest 3 stay)
	ls -1 "$DIR"/SharedCareer-*.zip 2>/dev/null | sort -V | head -n -3 | xargs -r rm -f
	green "Unpacked (settings in Resources/Server/SharedCareer/config are kept)."
	cmd_start
	sleep 3
	grep -h "SharedCareer\]" "$LOG" 2>/dev/null | tail -n 5
	[ "$was_running" = 0 ] && info "(The server was not running before – it is running now.)"
}

usage() {
	sed -n '2,28p' "$DIR/server.sh" | sed 's/^# \{0,1\}//'
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

# On one line with exit: bash reads it completely before it starts. If "update" replaces
# this file, the old version still runs to the end cleanly.
main "$@"; exit $?
