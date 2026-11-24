#!/usr/bin/env bash
# Upgrade an already-installed Buntys instance. Does not touch Majestica, Naksha, or the marketing site.
# Usage (as root, after a new encrypted bundle is on GitHub):
#   BUNDLE_URL=... BUNDLE_SHA256=... BUNDLE_PASS_FILE=/root/.majestica-bundle-pass \
#     nohup /opt/buntys/deploy/upgrade-buntys.sh >/var/log/buntys-upgrade.log 2>&1 &
set -Eeuo pipefail
[[ $EUID -eq 0 ]] || { echo "run as root" >&2; exit 1; }
APP_DIR="${APP_DIR:-/opt/buntys}"
UNIT="${UNIT:-buntys-app}"
[[ "$APP_DIR" == *majestica* || "$UNIT" == *majestica* ]] && { echo "refusing Majestica paths" >&2; exit 1; }
[[ -f "$APP_DIR/deploy/bootstrap.sh" ]] || { echo "Buntys is not installed in $APP_DIR" >&2; exit 1; }
# Take a fresh encrypted dump first.
if [[ -x /usr/local/sbin/buntys-backup ]]; then
  /usr/local/sbin/buntys-backup || echo "[warn] pre-upgrade backup failed" >&2
fi
# Same installer is idempotent: unpacks the new bundle, prisma db push, build, restart buntys-app only.
exec /usr/local/sbin/buntys-bootstrap install
