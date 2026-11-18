#!/usr/bin/env bash
# SharedCareer :: server control for a BeamMP server (runs it in a tmux session)
#
# Put this file into the server folder (where BeamMP-Server and ServerConfig.toml are),
# make it executable once:   chmod +x server.sh
#
#   ./server.sh start          start the server in the background
#   ./server.sh stop           stop it cleanly (SIGTERM, killed if it hangs)
#   ./server.sh restart        stop + start
#   ./server.sh status         is it running? (with PID and SharedCareer version)
#   ./server.sh console        open the live console  –  leave with Ctrl+B, then D
#                              (NOT Ctrl+C: that stops the server)
#   ./server.sh logs [n]       last n lines of Server.log (default 100)
#   ./server.sh follow         follow Server.log live (Ctrl+C only stops following)
#   ./server.sh cmd "sc time"  send a command to the server console, e.g. "sc get"
#   ./server.sh update         install the newest GitHub release (stop, back up, unpack,
#                              start) – only if it differs from the installed version
#   ./server.sh update --dev   the same with the newest dev build, from whichever branch was
#                              pushed last (version like 0.16.0-dev.ab12cd3) – for a test server
#   ./server.sh update --dev=my-branch   the newest dev build of that branch
#   ./server.sh update --release  the newest release, also where CHANNEL="dev" is set
#   ./server.sh update --force the same, even if that version is already installed
#   ./server.sh update x.zip   install a specific zip from this folder
#   ./server.sh check          show the installed version and the newest release and dev build
#
# Put the GitHub repository into server.conf (same folder):
#   REPO="MrCurby/SharedCareer"
#   CHANNEL="release"          what "update" installs: "release" or "dev" (a test server)
#   BRANCH=""                  with CHANNEL="dev": only dev builds of this branch (empty = any)
#   GITHUB_TOKEN=""            only needed for a private repository (token with read access)
#   BACKUPS_KEEP=5             update backups to keep (sharedcareer-backup-*.tgz); 0 = keep all
# Without REPO, "update" installs the newest SharedCareer-*.zip in this folder.
#
# The tmux session is named after the folder (e.g. "sctest"), so several servers in
# different folders don't get in each other's way.

set -u

# Raise with every change of this script (tools/version_check.sh checks it): an update only
# replaces server.sh with one of a higher revision, so installing an older package (or a release
# built before a fix of this script) never brings back an old server.sh.
SCRIPT_REVISION=2

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DIR" || exit 1
SESSION="${SC_SESSION:-$(basename "$DIR")}"
SESSION="${SESSION//[.:]/_}"   # tmux does not allow "." and ":" in session names
LOG="$DIR/Server.log"
STOP_WAIT=20   # seconds the server gets to shut down cleanly after SIGTERM
REPO="${SC_REPO:-}"
API="${SC_API:-https://api.github.com}"   # only changed for testing
GITHUB_TOKEN="${GITHUB_TOKEN:-}"
CHANNEL="release"
BRANCH=""
DEV_PREFIX="build-"   # tag of a branch's dev build: build-<branch>, a GitHub pre-release (dev-build.yml)
BACKUPS_KEEP=5
# shellcheck disable=SC1091
[ -f "$DIR/server.conf" ] && . "$DIR/server.conf"

red()   { printf '\033[31m%s\033[0m\n' "$*" >&2; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
info()  { printf '\033[36m%s\033[0m\n' "$*"; }

need_tmux() {
	if ! command -v tmux >/dev/null 2>&1; then
		red "tmux is not installed. Install it with:  sudo apt install tmux"
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

# tmux, not screen: BeamMP 3.9 reads no console input when it is started in a
# detached screen session, so neither typed commands nor "cmd" reached it.
running() {
	tmux has-session -t "=$SESSION" 2>/dev/null
}

server_pid() {
	# PID of the server process in this folder
	local p
	# matched by process name and working folder, so other servers on the machine are left alone
	for p in $(pgrep "^BeamMP-Server" 2>/dev/null); do
		if [ "$(readlink -f "/proc/$p/cwd" 2>/dev/null)" = "$DIR" ]; then echo "$p"; return 0; fi
	done
	return 1
}

send() {
	# type text + Enter into the console (-l: the text literally, not as key names)
	tmux send-keys -t "=$SESSION:" -l "$1" && tmux send-keys -t "=$SESSION:" Enter
}

console_text() {
	# everything the console shows, scrollback included, wrapped lines joined
	tmux capture-pane -p -J -S - -t "=$SESSION:"
}

terminate() {
	# SIGTERM: BeamMP shuts down cleanly, like on Ctrl+C, without depending on the console.
	# SIGKILL only if it hangs; SharedCareer writes its data as soon as it changes,
	# so a kill loses nothing.
	local p="$1" i logstart=0
	[ -f "$LOG" ] && logstart="$(wc -c <"$LOG")"
	kill "$p" 2>/dev/null
	for ((i = 0; i < STOP_WAIT; i++)); do
		sleep 1
		kill -0 "$p" 2>/dev/null || return 0
	done
	red "Server did not stop within ${STOP_WAIT}s after SIGTERM – killing it (PID $p)."
	if [ -f "$LOG" ] && [ "$(wc -c <"$LOG")" -gt "$logstart" ]; then
		info "Log since SIGTERM (the last line shows where the shutdown hangs):"
		tail -c +"$((logstart + 1))" "$LOG" | tail -n 15 | sed 's/^/    /'
	fi
	kill -9 "$p" 2>/dev/null
	sleep 1
}

cmd_start() {
	need_tmux
	if running; then info "Already running (session '$SESSION'). Console: ./server.sh console"; return 0; fi
	local p
	if p="$(server_pid)"; then
		red "A server is already running in this folder outside tmux (PID $p). Stop it first: ./server.sh stop"
		exit 1
	fi
	local bin
	if ! bin="$(find_binary)"; then red "No BeamMP-Server program found in $DIR."; exit 1; fi
	if [ ! -f "$DIR/ServerConfig.toml" ]; then info "Note: no ServerConfig.toml yet – BeamMP creates one on the first start."; fi
	# the session ends together with the server; Server.log keeps the reason if it crashes
	tmux new-session -d -s "$SESSION" -c "$DIR" "$(printf '%q' "$bin")"
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
	need_tmux
	if ! running; then
		local p; if p="$(server_pid)"; then
			info "No tmux session, but server process $p is running – stopping it."
			terminate "$p"
		fi
		# a server started by the old screen-based server.sh leaves its screen session behind
		command -v screen >/dev/null 2>&1 && screen -S "$SESSION" -X quit >/dev/null 2>&1
		info "Not running."; return 0
	fi
	info "Stopping server (session '$SESSION') ..."
	local p
	if p="$(server_pid)"; then terminate "$p"; fi
	# normally the session is gone with the server already
	running && tmux kill-session -t "=$SESSION"
	green "Stopped."
}

cmd_status() {
	need_tmux
	local p
	if running; then
		p="$(server_pid || true)"
		green "Running (session '$SESSION'${p:+, PID $p})."
		if [ -f "$LOG" ]; then
			local v; v="$(grep -o 'SharedCareer\] Version [0-9A-Za-z.-]*' "$LOG" | tail -n 1)"
			[ -n "$v" ] && info "${v#*] }"
		fi
	else
		red "Not running."
	fi
}

cmd_console() {
	need_tmux
	if ! running; then red "Server is not running. Start it with: ./server.sh start"; exit 1; fi
	info "Opening the console. Leave with Ctrl+B, then D  (NOT Ctrl+C – that stops the server)"
	sleep 2
	tmux attach -t "=$SESSION"
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
	need_tmux
	if [ -z "${1:-}" ]; then red 'Command missing, for example: ./server.sh cmd "sc time"'; exit 1; fi
	if ! running; then red "Server is not running."; exit 1; fi
	send "$1"
	sleep 1
	# show the answer from the console: BeamMP writes command answers there, not to Server.log.
	# Everything after the last echo of the command, without the empty prompt at the end.
	console_text | awk -v cmd="> $1" '
		$0 == cmd { n = 0; found = 1; next }
		found { lines[++n] = $0 }
		END {
			while (n > 0 && lines[n] ~ /^>? *$/) n--
			for (i = 1; i <= n; i++) print lines[i]
		}'
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

# GET from the GitHub API; prints the JSON (curl's own error message is hidden, the callers say
# what went wrong).
api_get() {
	gh_curl -H "Accept: application/vnd.github+json" "$1" 2>/dev/null
}

# The tag of a branch's dev build: build-<branch>, every character other than A-Z a-z 0-9 . _ -
# replaced by "-" (the same as dev-build.yml does).
dev_tag() {
	printf '%s%s' "$DEV_PREFIX" "$(printf '%s' "$1" | sed 's/[^A-Za-z0-9._-]/-/g')"
}

# Gets the newest package: channel "release" (newest release) or "dev" (the newest dev build of
# branch $2, or of any branch if $2 is empty). Sets REMOTE_VERSION (from the zip's name,
# SharedCareer-<version>.zip), REMOTE_ASSET (API address of the zip) and REMOTE_BRANCH (dev
# builds). With "quiet" ($3), a missing package returns 1 instead of stopping.
fetch_remote() {
	local channel="$1" branch="${2:-}" quiet="${3:-}"
	if ! command -v curl >/dev/null 2>&1; then red "curl is missing. Install it with:  sudo apt install curl"; exit 1; fi
	local url="$API/repos/$REPO/releases/latest" what="release" json
	if [ "$channel" = dev ]; then
		what="dev build"
		local tag
		if [ -n "$branch" ]; then
			tag="$(dev_tag "$branch")"
			what="dev build of branch $branch"
		elif json="$(api_get "$API/repos/$REPO/releases?per_page=50")"; then
			# newest first: the dev build pushed last
			tag="$(printf '%s' "$json" | grep -o "\"tag_name\": *\"$DEV_PREFIX[^\"]*\"" | head -n 1 | sed 's/.*"\([^"]*\)"$/\1/')"
		fi
		if [ -z "${tag:-}" ]; then
			[ -n "$quiet" ] && return 1
			red "No dev build on GitHub ($REPO) – one appears after the next push to a branch other than main."
			exit 1
		fi
		url="$API/repos/$REPO/releases/tags/$tag"
	fi
	if ! json="$(api_get "$url")"; then
		[ -n "$quiet" ] && return 1
		if [ "$channel" = dev ]; then
			red "No $what on GitHub ($REPO). Is the branch name right, and was it pushed since?"
		else
			red "GitHub request failed ($REPO). Is the repository name in server.conf right? A private repository needs GITHUB_TOKEN."
		fi
		exit 1
	fi
	REMOTE_VERSION="$(printf '%s' "$json" | grep -o '"name": *"SharedCareer-[^"]*\.zip"' | head -n 1 | sed 's/.*"SharedCareer-\(.*\)\.zip"$/\1/')"
	REMOTE_ASSET="$(printf '%s' "$json" | grep -o '"url": *"[^"]*/releases/assets/[0-9]*"' | head -n 1 | sed 's/.*"\(http[^"]*\)"$/\1/')"
	# the dev build's title ends with "from <branch>"
	REMOTE_BRANCH="$(printf '%s' "$json" | grep -o '"name": *"SharedCareer dev build [^"]* from [^"]*"' | head -n 1 | sed 's/.* from \([^"]*\)"$/\1/')"
	if [ -z "$REMOTE_VERSION" ] || [ -z "$REMOTE_ASSET" ]; then
		[ -n "$quiet" ] && return 1
		red "The newest $what of $REPO has no zip."; exit 1
	fi
}

cmd_check() {
	local have; have="$(installed_version)"
	info "Installed: ${have:-none}"
	if [ -z "$REPO" ]; then info "No REPO in server.conf – GitHub is not checked."; return 0; fi
	fetch_remote release
	local release="$REMOTE_VERSION" dev=""
	info "Newest release on GitHub ($REPO): $release"
	if fetch_remote dev "$BRANCH" quiet; then
		dev="$REMOTE_VERSION"
		info "Newest dev build: $dev${REMOTE_BRANCH:+ (branch $REMOTE_BRANCH)}"
	fi
	local want="$release"
	[ "$CHANNEL" = dev ] && want="$dev"
	if [ -z "$want" ]; then
		info "No dev build${BRANCH:+ of branch $BRANCH} yet – nothing to update to."
	elif [ "$have" = "$want" ]; then
		green "Up to date ($CHANNEL)."
	else
		green "Update available: ./server.sh update"
	fi
	[ "$CHANNEL" != dev ] && [ -n "$dev" ] && [ "$have" != "$dev" ] && info "Dev build for testing: ./server.sh update --dev"
	return 0
}

# Keeps the newest BACKUPS_KEEP update backups and deletes older ones (0 = keep all).
clean_backups() {
	[ "${BACKUPS_KEEP:-0}" -gt 0 ] 2>/dev/null || return 0
	local old
	old="$(ls -1 "$DIR"/sharedcareer-backup-*.tgz 2>/dev/null | sort | head -n "-$BACKUPS_KEEP")"
	[ -z "$old" ] && return 0
	printf '%s\n' "$old" | xargs -r rm -f
	info "Old backups removed: $(printf '%s\n' "$old" | wc -l) (the newest $BACKUPS_KEEP stay)"
}

# Downloads the newest package of a channel into the folder; prints the file name (empty =
# already up to date).
download_remote() {
	local channel="$1" branch="$2" force="$3"
	fetch_remote "$channel" "$branch"
	local have; have="$(installed_version)"
	if [ "$have" = "$REMOTE_VERSION" ] && [ "$force" != 1 ]; then
		green "Already up to date (version $have). To reinstall anyway: ./server.sh update --force" >&2
		return 0
	fi
	local file="$DIR/SharedCareer-$REMOTE_VERSION.zip"
	info "Downloading SharedCareer $REMOTE_VERSION${REMOTE_BRANCH:+ (branch $REMOTE_BRANCH)} from GitHub ($REPO) ..." >&2
	if ! gh_curl -H "Accept: application/octet-stream" -o "$file.part" "$REMOTE_ASSET" || ! unzip -tq "$file.part" >/dev/null 2>&1; then
		rm -f "$file.part"; red "Download failed." >&2; exit 1
	fi
	mv "$file.part" "$file"
	echo "$file"
}

# The revision of a server.sh file (0 for one from before revisions were counted).
script_revision() {
	local r; r="$(sed -n 's/^SCRIPT_REVISION=\([0-9]*\).*/\1/p' "$1" 2>/dev/null | head -n 1)"
	echo "${r:-0}"
}

# Replaces server.sh with the package's copy, but only if that one has a higher revision. That is
# safe while this script runs: bash has already read it completely (everything sits in functions,
# see main at the very bottom).
update_script() {
	local new="$DIR/server.sh.new"
	unzip -p "$1" server.sh >"$new" 2>/dev/null
	if [ ! -s "$new" ]; then rm -f "$new"; return 0; fi
	local mine theirs
	mine="$(script_revision "$DIR/server.sh")"
	theirs="$(script_revision "$new")"
	if [ "$theirs" -gt "$mine" ]; then
		mv "$new" "$DIR/server.sh" && chmod +x "$DIR/server.sh"
		info "server.sh updated (revision $mine -> $theirs)."
	else
		rm -f "$new"
		[ "$theirs" -lt "$mine" ] && info "server.sh kept: this one (revision $mine) is newer than the package's ($theirs)."
	fi
	return 0
}

cmd_update() {
	if ! command -v unzip >/dev/null 2>&1; then red "unzip is missing. Install it with:  sudo apt install unzip"; exit 1; fi
	local zip="" force=0 channel="$CHANNEL" branch="$BRANCH" a
	for a in "$@"; do
		case "$a" in
			--force|-f) force=1 ;;
			--dev) channel=dev ;;
			--dev=*) channel=dev; branch="${a#--dev=}" ;;
			--release) channel=release ;;
			"") ;;
			*) zip="$a" ;;
		esac
	done
	if [ "$channel" != release ] && [ "$channel" != dev ]; then
		red "CHANNEL in server.conf must be \"release\" or \"dev\" (it is \"$channel\")."; exit 1
	fi
	if [ -z "$zip" ] && [ -n "$REPO" ]; then
		zip="$(download_remote "$channel" "$branch" "$force")" || exit 1
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
	unzip -o -q "$zip" -x server.sh || { red "Unpacking failed."; exit 1; }
	update_script "$zip"
	# clean up old zips (the newest 3 stay)
	ls -1 "$DIR"/SharedCareer-*.zip 2>/dev/null | sort -V | head -n -3 | xargs -r rm -f
	clean_backups
	green "Unpacked (settings in Resources/Server/SharedCareer/config are kept)."
	cmd_start
	sleep 3
	grep -h "SharedCareer\]" "$LOG" 2>/dev/null | tail -n 5
	[ "$was_running" = 0 ] && info "(The server was not running before – it is running now.)"
}

usage() {
	sed -n '2,35p' "$DIR/server.sh" | sed 's/^# \{0,1\}//'
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
