#!/usr/bin/env bash
# amp-panel-patch: keep the CubeCoders AMP web panel (the ADS instance) alive.
#
#   1. Boot fix: raises ampinstmgr.service's start timeout (stock 180 s) to 30 min. At boot,
#      `ampinstmgr startboot` pulls a Docker image for every "Start on Boot" instance; on a slow
#      link that takes longer than 180 s, systemd kills the unit and the panel dies with it.
#   2. Safety net: restarts the panel every night at 00:15 (root cron). Game instances keep running.
#
# Install:  curl -fsSL https://raw.githubusercontent.com/TheDyXer/amp-panel-patch/main/install.sh | sudo bash
# Status:   curl -fsSL https://raw.githubusercontent.com/TheDyXer/amp-panel-patch/main/install.sh | sudo bash -s -- --status
#           (exit 0 = patched and panel up, 1 = not patched, 2 = patched but panel down)
# Remove:   curl -fsSL https://raw.githubusercontent.com/TheDyXer/amp-panel-patch/main/install.sh | sudo bash -s -- --remove
#
# Optional environment (set on the `sudo` side, e.g. `| sudo AMP_RESTART_CRON='30 4 * * *' bash`):
#   AMP_RESTART_CRON   cron schedule of the nightly restart   (default: "15 0 * * *")
#   AMP_BOOT_TIMEOUT   start timeout for ampinstmgr.service   (default: 30min)
#   AMP_ADS_INSTANCE   ADS instance name passed to ampinstmgr (default: ADS)
#   AMP_USER           user AMP runs as                       (default: amp)
#   AMP_NO_RESTART     set to skip restarting the panel during install
#   NO_COLOR           set to disable colored output
set -euo pipefail

PATCH_VERSION=1.1.0
REPO_RAW=https://raw.githubusercontent.com/TheDyXer/amp-panel-patch/main/install.sh
RESTART_BIN=/usr/local/sbin/amp-panel-restart
LOG=/var/log/amp-panel-restart.log
UNIT=ampinstmgr.service
DROPIN_DIR=/etc/systemd/system/$UNIT.d
DROPIN=$DROPIN_DIR/10-boot-timeout.conf
CRON_SCHEDULE=${AMP_RESTART_CRON:-15 0 * * *}
BOOT_TIMEOUT=${AMP_BOOT_TIMEOUT:-30min}
ADS_INSTANCE=${AMP_ADS_INSTANCE:-ADS}
AMP_USER=${AMP_USER:-amp}

# ---------- output ----------
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  BOLD=$'\e[1m' GREEN=$'\e[32m' YELLOW=$'\e[33m' RED=$'\e[31m' CYAN=$'\e[36m' DIM=$'\e[2m' RESET=$'\e[0m'
else
  BOLD='' GREEN='' YELLOW='' RED='' CYAN='' DIM='' RESET=''
fi
WARNINGS=0
FAILURES=0
banner() { printf '%sAMP panel patch%s v%s  %s(github.com/TheDyXer/amp-panel-patch)%s\n' "$BOLD" "$RESET" "$PATCH_VERSION" "$DIM" "$RESET"; }
step()   { printf '\n%s[%s]%s %s%s%s\n' "$CYAN" "$1" "$RESET" "$BOLD" "$2" "$RESET"; }
ok()     { printf '  %s✓%s %s\n' "$GREEN" "$RESET" "$*"; }
info()   { printf '  %s•%s %s\n' "$DIM" "$RESET" "$*"; }
warn()   { printf '  %s!%s %s\n' "$YELLOW" "$RESET" "$*"; WARNINGS=$((WARNINGS + 1)); }
note()   { printf '  %s!%s %s\n' "$YELLOW" "$RESET" "$*"; }
bad()    { printf '  %s✗%s %s\n' "$RED" "$RESET" "$*"; FAILURES=$((FAILURES + 1)); }
die()    { printf '\n%s✗ %s%s\n' "$RED" "$*" "$RESET" >&2; exit 1; }

# ---------- helpers ----------
have_systemd() { [ -d /run/systemd/system ]; }
unit_timeout() { systemctl show "$UNIT" -p TimeoutStartUSec --value 2>/dev/null || true; }

human_schedule() {
  local m h rest
  read -r m h rest <<<"$1"
  if [[ $m =~ ^[0-9]+$ && $h =~ ^[0-9]+$ && $rest == "* * *" ]]; then
    printf 'every day at %02d:%02d %s' "$((10#$h))" "$((10#$m))" "$(date +%Z)"
  else
    printf 'cron schedule "%s"' "$1"
  fi
}

# Writes stdin to $1 (mode $2) only if the content differs. Returns 1 when it was already identical.
write_file() {
  local tmp
  tmp=$(mktemp)
  cat >"$tmp"
  if [ -f "$1" ] && cmp -s "$tmp" "$1"; then rm -f "$tmp"; return 1; fi
  install -m "$2" "$tmp" "$1"
  rm -f "$tmp"
}

cron_lines_ours() { crontab -l 2>/dev/null | grep -F "$RESTART_BIN" || true; }
cron_has_old()    { crontab -l 2>/dev/null | grep -qE '(^|[[:space:]/])ampfix\.sh([[:space:]]|$)'; }

find_amp() {
  MGR=$(command -v ampinstmgr || true)
  [ -n "$MGR" ] || { [ -x /opt/cubecoders/amp/ampinstmgr ] && MGR=/opt/cubecoders/amp/ampinstmgr; } || true
  [ -n "$MGR" ] || die "ampinstmgr not found - is AMP installed on this server?"
  id "$AMP_USER" >/dev/null 2>&1 || die "user '$AMP_USER' not found (set AMP_USER=<user>)"
  # One listing gives us the AMP version and the panel's URL.
  local list
  list=$(timeout 30 sudo -H -u "$AMP_USER" "$MGR" -l </dev/null 2>/dev/null | sed 's/│/|/g' || true)
  AMP_VERSION=$(grep -oE 'AMP Instance Manager v[0-9.]+' <<<"$list" | head -1 | sed 's/.* v//' || true)
  read -r PANEL_URL PANEL_RUNNING < <(awk -F'|' '
    { k = $1; v = $2; gsub(/^[ \t]+|[ \t]+$/, "", k); gsub(/^[ \t]+|[ \t]+$/, "", v) }
    k == "Module"  { ads = (v == "ADS") }
    k == "URL"     && ads && url == ""     { url = v }
    k == "Running" && ads && running == "" { running = v }
    END { print (url == "" ? "-" : url), (running == "" ? "-" : running) }' <<<"$list")
  [ "$PANEL_URL" != "-" ] || PANEL_URL=http://127.0.0.1:8080/
}

check_server() {
  ok "running as root"
  ok "AMP instance manager: $MGR${AMP_VERSION:+ (v$AMP_VERSION)}"
  ok "AMP user: $AMP_USER"
  command -v crontab >/dev/null || die "crontab not found - install the 'cron' package first"
  ok "cron is available"
  if have_systemd; then
    ok "systemd is running"
    local state timeouts_now timeouts_all
    state=$(systemctl is-active "$UNIT" 2>/dev/null || true)
    timeouts_now=$(timeout 20 journalctl -b -u "$UNIT" -q --no-pager 2>/dev/null | grep -c 'start operation timed out' || true)
    timeouts_all=$(timeout 30 journalctl -u "$UNIT" -q --no-pager 2>/dev/null | grep -c 'start operation timed out' || true)
    if [ "${timeouts_now:-0}" -gt 0 ]; then
      note "this boot, $UNIT timed out and took the panel down with it (state: $state) - this is the bug the patch fixes"
    else
      info "this boot, $UNIT started normally (state: $state)"
    fi
    [ "${timeouts_all:-0}" -gt 0 ] && info "boots in the journal where the boot timeout killed AMP: $timeouts_all"
  else
    warn "systemd is not running (container?) - the boot fix is written but can't take effect here"
  fi
  return 0
}

# HTTP status of the panel URL; empty if nothing answers, "none" if neither curl nor wget exists.
http_code() {
  if command -v curl >/dev/null; then
    curl -s -o /dev/null -m 5 -w '%{http_code}' "$PANEL_URL" 2>/dev/null || true
  elif command -v wget >/dev/null; then
    wget -q -T 5 -S -O /dev/null "$PANEL_URL" 2>&1 | awk '/HTTP\//{c=$2} END{print c}' || true
  else
    echo none
  fi
}

panel_pid() {
  local port
  port=$(sed -E 's#^[a-z]+://[^/:]+:?([0-9]*).*#\1#' <<<"$PANEL_URL")
  command -v ss >/dev/null || return 0
  ss -ltnpH "sport = :${port:-80}" 2>/dev/null | grep -oE 'pid=[0-9]+' | head -1 | cut -d= -f2 || true
}

restart_panel_now() {
  if [ -n "${AMP_NO_RESTART:-}" ]; then
    info "skipped (AMP_NO_RESTART is set); the first restart will be $(human_schedule "$CRON_SCHEDULE")"
    return 0
  fi
  local old new code='' i=0
  old=$(panel_pid)
  info "restarting the panel now - game servers keep running..."
  # In its own systemd scope, so the new panel doesn't belong to this (SSH) session.
  if have_systemd && command -v systemd-run >/dev/null; then
    systemd-run --scope --quiet --collect "$RESTART_BIN" </dev/null || true
  else
    "$RESTART_BIN" </dev/null || true
  fi
  if [ "$(http_code)" = none ]; then
    info "restart done (can't test it: no curl or wget); see $LOG"
    return 0
  fi
  while [ "$i" -lt 45 ]; do
    i=$((i + 1))
    code=$(http_code)
    [[ $code =~ ^[23][0-9][0-9]$ ]] && break
    sleep 2
  done
  new=$(panel_pid)
  if ! [[ $code =~ ^[23][0-9][0-9]$ ]]; then
    bad "panel did not come back within 90 s - see $LOG"
  elif [ -n "$old" ] && [ "$old" = "$new" ]; then
    warn "panel answers HTTP $code, but it is still the same process (pid $old) - the restart may not have happened; see $LOG"
  else
    ok "panel restarted${old:+ (pid $old → ${new:-?})} and answers HTTP $code"
  fi
}

PANEL_OK=unknown
check_panel() {
  local code
  code=$(http_code)
  if [ "$code" = none ]; then
    info "can't test the panel (no curl or wget); open $PANEL_URL in a browser"
    return 0
  fi
  if [[ $code =~ ^[23][0-9][0-9]$ ]]; then
    PANEL_OK=yes
    ok "panel is up: $PANEL_URL answers HTTP $code"
  else
    PANEL_OK=no
    [ "${code:-000}" = 000 ] && code="no answer" || code="HTTP $code"
    warn "panel is not answering at $PANEL_URL ($code) - start it now with: sudo $RESTART_BIN"
  fi
}

verify() {
  if [ -f "$DROPIN" ]; then ok "boot fix file: $DROPIN"; else bad "boot fix file missing: $DROPIN"; fi
  if have_systemd; then
    if systemctl show "$UNIT" -p DropInPaths --value 2>/dev/null | grep -qF "$DROPIN"; then
      ok "systemd uses it: $UNIT start timeout is $(unit_timeout)"
    else
      bad "systemd does not use the boot fix yet (try: systemctl daemon-reload)"
    fi
  fi
  if [ -x "$RESTART_BIN" ] && sh -n "$RESTART_BIN"; then ok "restart script: $RESTART_BIN"; else bad "restart script missing or broken: $RESTART_BIN"; fi
  local lines count
  lines=$(cron_lines_ours)
  count=$(grep -c . <<<"$lines" || true)
  if [ "$count" = 1 ]; then
    ok "cron entry: $lines  ($(human_schedule "${lines% "$RESTART_BIN"}"))"
  else
    bad "expected exactly 1 cron entry for $RESTART_BIN, found $count"
  fi
  if have_systemd; then
    if systemctl is-active --quiet cron 2>/dev/null || systemctl is-active --quiet crond 2>/dev/null; then
      ok "cron daemon is running"
    else
      warn "cron daemon is not running - the nightly restart won't fire"
    fi
  fi
  if [ -s "$LOG" ] && grep -q 'restarting AMP panel' "$LOG"; then
    info "last panel restart: $(grep 'restarting AMP panel' "$LOG" | tail -1 | cut -c1-19) ($(tail -1 "$LOG" | sed 's/^[0-9-]* [0-9:]* //'))"
  else
    info "the panel restart hasn't run yet; its log will be $LOG"
  fi
  check_panel
}

# ---------- actions ----------
do_install() {
  banner
  step 1/5 "Checking this server"
  find_amp
  check_server

  step 2/5 "Boot fix: give $UNIT time to finish at boot"
  local before=''
  have_systemd && before=$(unit_timeout)
  mkdir -p "$DROPIN_DIR"
  if write_file "$DROPIN" 644 <<EOF
# Installed by amp-panel-patch. 'ampinstmgr startboot' pulls Docker images for every
# "Start on Boot" instance; past the stock 180 s systemd kills the unit and the panel with it.
[Service]
TimeoutStartSec=$BOOT_TIMEOUT
EOF
  then ok "wrote $DROPIN"; else ok "already in place: $DROPIN"; fi
  if have_systemd; then
    systemctl daemon-reload
    local after
    after=$(unit_timeout)
    if [ "$before" = "$after" ]; then
      ok "systemd reloaded - start timeout is already $after"
    else
      ok "systemd reloaded - start timeout: ${before:-?} → $after"
    fi
    info "nothing was restarted; this takes effect at the next boot"
  fi

  step 3/5 "Nightly panel restart (safety net)"
  if write_file "$RESTART_BIN" 755 <<EOF
#!/bin/sh
# Installed by amp-panel-patch: restarts the AMP web panel ($ADS_INSTANCE). Game instances keep running.
{
  echo "\$(date '+%F %T') restarting AMP panel"
  sudo -H -u $AMP_USER $MGR restart $ADS_INSTANCE
  echo "\$(date '+%F %T') done, exit \$?"
} >> $LOG 2>&1
EOF
  then ok "wrote $RESTART_BIN"; else ok "already in place: $RESTART_BIN"; fi
  local had_old=no had_ours=no
  cron_has_old && had_old=yes
  [ -n "$(cron_lines_ours)" ] && had_ours=yes
  {
    crontab -l 2>/dev/null | grep -vF "$RESTART_BIN" | grep -vE '(^|[[:space:]/])ampfix\.sh([[:space:]]|$)' || true
    echo "$CRON_SCHEDULE $RESTART_BIN"
  } | crontab -
  if [ "$had_ours" = yes ]; then ok "cron entry refreshed: $(human_schedule "$CRON_SCHEDULE")"; else ok "cron entry added: $(human_schedule "$CRON_SCHEDULE")"; fi
  [ "$had_old" = yes ] && ok "replaced the old ampfix.sh cron line (the ampfix.sh file itself was left in place)"
  info "only the panel restarts; game servers keep running. Log: $LOG"

  step 4/5 "Restarting the web panel"
  restart_panel_now

  step 5/5 "Verifying"
  verify

  echo
  if [ "$FAILURES" -gt 0 ]; then
    die "Something went wrong: $FAILURES check(s) failed above."
  fi
  if [ "$PANEL_OK" = no ]; then
    printf '%s✔ Patched, but the panel is not answering right now.%s\n' "$YELLOW$BOLD" "$RESET"
  else
    printf '%s✔ Patched and verified%s%s' "$GREEN$BOLD" "$([ "$PANEL_OK" = yes ] && echo ' - the panel is up.' || echo '.')" "$RESET"
    [ "$WARNINGS" -gt 0 ] && printf ' %s(%d warning(s) above)%s' "$YELLOW" "$WARNINGS" "$RESET"
    printf '\n'
  fi
  info "At boot, AMP now gets $BOOT_TIMEOUT instead of 180 s before systemd gives up."
  info "The panel restarts $(human_schedule "$CRON_SCHEDULE")."
  info "Check any time:  curl -fsSL $REPO_RAW | sudo bash -s -- --status"
  info "Undo:            curl -fsSL $REPO_RAW | sudo bash -s -- --remove"
}

do_status() {
  banner
  step 1/2 "Checking this server"
  find_amp
  check_server
  step 2/2 "Patch status"
  verify
  echo
  if [ "$FAILURES" -gt 0 ]; then
    printf '%s✗ Not patched (or incomplete): %d check(s) failed.%s\n' "$RED$BOLD" "$FAILURES" "$RESET"
    info "Install:  curl -fsSL $REPO_RAW | sudo bash"
    exit 1
  fi
  if [ "$PANEL_OK" = no ]; then
    printf '%s✔ Patched, but the panel is not answering right now.%s\n' "$YELLOW$BOLD" "$RESET"
    info "Start it:  sudo $RESTART_BIN"
    exit 2
  fi
  printf '%s✔ Patched and working.%s' "$GREEN$BOLD" "$RESET"
  [ "$WARNINGS" -gt 0 ] && printf ' %s(%d warning(s) above)%s' "$YELLOW" "$WARNINGS" "$RESET"
  printf '\n'
}

do_remove() {
  banner
  step 1/1 "Removing the patch"
  if [ -n "$(cron_lines_ours)" ]; then
    { crontab -l 2>/dev/null | grep -vF "$RESTART_BIN" || true; } | crontab -
    ok "removed the cron entry"
  else
    info "no cron entry to remove"
  fi
  if [ -e "$RESTART_BIN" ]; then rm -f "$RESTART_BIN"; ok "removed $RESTART_BIN"; else info "no restart script to remove"; fi
  if [ -e "$DROPIN" ]; then rm -f "$DROPIN"; ok "removed $DROPIN"; else info "no boot fix file to remove"; fi
  rmdir "$DROPIN_DIR" 2>/dev/null || true
  if have_systemd; then
    systemctl daemon-reload
    ok "systemd reloaded - $UNIT start timeout is back to $(unit_timeout)"
  fi
  [ -e "$LOG" ] && info "kept the log: $LOG"
  echo
  printf '%s✔ Removed.%s Nothing was restarted.\n' "$GREEN$BOLD" "$RESET"
}

[ "$(id -u)" -eq 0 ] || die "please run as root (pipe into 'sudo bash')"
command -v sudo >/dev/null || die "sudo not found (the restart script uses 'sudo -u $AMP_USER')"

case "${1:-}" in
  ""|--install) do_install ;;
  --status|-s)  do_status ;;
  --remove|-r)  do_remove ;;
  *) die "unknown option '$1' (use --status, --remove, or nothing to install)" ;;
esac
