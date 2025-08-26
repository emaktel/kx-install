#!/usr/bin/env bash
set -euo pipefail

[ "$EUID" -eq 0 ] || { echo "Run as root"; exit 1; }

systemctl stop pull-routing.timer pull-routing.service || true
systemctl disable pull-routing.timer || true
rm -f /etc/systemd/system/pull-routing.service
rm -f /etc/systemd/system/pull-routing.timer
systemctl daemon-reload

# Restore previous kamailio.cfg if we created a backup
if [ -f /etc/kamailio/kamailio.cfg.bak ]; then
  cp -a /etc/kamailio/kamailio.cfg.bak /etc/kamailio/kamailio.cfg
fi

# Optional: remove our files
rm -f /usr/local/sbin/pull-routing.sh
rm -f /etc/kamailio/dest.map

echo "Uninstall complete. Kamailio still installed (package not removed)."
