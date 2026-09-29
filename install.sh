#!/usr/bin/env bash
# amp-panel-patch: keep the CubeCoders AMP web panel (the ADS instance) alive.
#
#   1. Boot fix: raises ampinstmgr.service's start timeout (stock 180 s) to 30 min. At boot,
#      `ampinstmgr startboot` pulls a Docker image for every "Start on Boot" instance; on a slow
#      link that takes longer than 180 s, systemd kills the unit and the panel dies with it.
#   2. Safety net: restarts the panel every night at 00:15 (root cron). Game instances keep running.
#
# Install:  curl -fsSL https://raw.githubusercontent.com/TheDyXer/amp-panel-patch/main/install.sh | sudo bash
# Remove:   curl -fsSL https://raw.githubusercontent.com/TheDyXer/amp-panel-patch/main/install.sh | sudo bash -s -- --remove
#
# Optional environment (set on the `sudo` side, e.g. `| sudo AMP_RESTART_CRON='30 4 * * *' bash`):
#   AMP_RESTART_CRON   cron schedule of the nightly restart   (default: "15 0 * * *")
#   AMP_BOOT_TIMEOUT   start timeout for ampinstmgr.service   (default: 30min)
#   AMP_ADS_INSTANCE   ADS instance name passed to ampinstmgr (default: ADS)
#   AMP_USER           user AMP runs as                       (default: amp)
set -euo pipefail

RESTART_BIN=/usr/local/sbin/amp-panel-restart
LOG=/var/log/amp-panel-restart.log
DROPIN_DIR=/etc/systemd/system/ampinstmgr.service.d
DROPIN=$DROPIN_DIR/10-boot-timeout.conf
CRON_SCHEDULE=${AMP_RESTART_CRON:-15 0 * * *}
BOOT_TIMEOUT=${AMP_BOOT_TIMEOUT:-30min}
ADS_INSTANCE=${AMP_ADS_INSTANCE:-ADS}
AMP_USER=${AMP_USER:-amp}

say() { echo "amp-panel-patch: $*"; }
die() { echo "amp-panel-patch: ERROR: $*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "run as root (pipe into 'sudo bash')"
command -v crontab >/dev/null || die "crontab not found (install the cron package)"

have_systemd() { [ -d /run/systemd/system ]; }

# Root's crontab minus our line and minus an older hand-made ampfix.sh line (which this replaces).
cron_without_ours() {
  crontab -l 2>/dev/null | grep -vF "$RESTART_BIN" | grep -vE '(^|[[:space:]/])ampfix\.sh([[:space:]]|$)' || true
}

remove() {
  cron_without_ours | crontab -
  rm -f "$RESTART_BIN" "$DROPIN"
  rmdir "$DROPIN_DIR" 2>/dev/null || true
  have_systemd && systemctl daemon-reload
  say "removed (the log $LOG was kept)"
}

install() {
  local mgr
  mgr=$(command -v ampinstmgr || true)
  [ -n "$mgr" ] || { [ -x /opt/cubecoders/amp/ampinstmgr ] && mgr=/opt/cubecoders/amp/ampinstmgr; }
  [ -n "$mgr" ] || die "ampinstmgr not found - is AMP installed?"
  id "$AMP_USER" >/dev/null 2>&1 || die "user '$AMP_USER' not found (set AMP_USER)"

  # 1. Boot fix: a drop-in survives AMP rewriting its own unit file. Nothing is restarted now.
  mkdir -p "$DROPIN_DIR"
  cat > "$DROPIN" <<EOF
# Installed by amp-panel-patch. 'ampinstmgr startboot' pulls Docker images for every
# "Start on Boot" instance; past the stock 180 s systemd kills the unit and the panel with it.
[Service]
TimeoutStartSec=$BOOT_TIMEOUT
EOF
  have_systemd && systemctl daemon-reload

  # 2. Nightly panel restart (same command as a hand-made ampfix.sh, plus a log).
  cat > "$RESTART_BIN" <<EOF
#!/bin/sh
# Installed by amp-panel-patch: restarts the AMP web panel ($ADS_INSTANCE). Game instances keep running.
{
  echo "\$(date '+%F %T') restarting AMP panel"
  sudo -H -u $AMP_USER $mgr restart $ADS_INSTANCE
  echo "\$(date '+%F %T') done, exit \$?"
} >> $LOG 2>&1
EOF
  chmod 755 "$RESTART_BIN"

  local had_old=no
  crontab -l 2>/dev/null | grep -qE '(^|[[:space:]/])ampfix\.sh([[:space:]]|$)' && had_old=yes
  { cron_without_ours; echo "$CRON_SCHEDULE $RESTART_BIN"; } | crontab -

  say "installed"
  say "  boot fix : $DROPIN (TimeoutStartSec=$BOOT_TIMEOUT)"
  have_systemd && say "             systemd now reports: $(systemctl show ampinstmgr.service -p TimeoutStartUSec --value 2>/dev/null)"
  say "  restart  : '$CRON_SCHEDULE' -> $RESTART_BIN (log: $LOG)"
  [ "$had_old" = yes ] && say "  replaced : the old ampfix.sh cron line (the ampfix.sh file itself was left in place)"
  return 0
}

case "${1:-}" in
  --remove|-r) remove ;;
  ""|--install) install ;;
  *) die "unknown option '$1' (use --remove, or nothing to install)" ;;
esac
