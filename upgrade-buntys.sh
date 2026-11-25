#!/usr/bin/env bash
# Upgrade an already-installed Buntys instance at /opt/buntys.
# Does NOT touch Majestica, Naksha, nginx vhosts other than health-checks, or the marketing site.
#
# As root, after the encrypted bundle and this script are on GitHub main:
#   nohup bash -c 'curl -fsSL https://raw.githubusercontent.com/majesticabeauty7/majestica-deploy/main/upgrade-buntys.sh -o /tmp/upgrade-buntys.sh && echo "<SCRIPT_SHA256>  /tmp/upgrade-buntys.sh" | sha256sum -c - && chmod 700 /tmp/upgrade-buntys.sh && BUNDLE_PASS_FILE=/root/.majestica-bundle-pass /tmp/upgrade-buntys.sh' >/var/log/buntys-upgrade.log 2>&1 &
#
# Steps: backup (pg_dump of buntys_app + /opt/buntys) → unpack new code (keep .env) → additive schema
# → set missing owner/approver emails → build → restart buntys-app → health check.
# On failure: restore app + database from this run's backup and restart. Logs: /var/log/buntys-upgrade.log
set -Eeuo pipefail
[[ $EUID -eq 0 ]] || { echo "run as root" >&2; exit 1; }
# Never leak a passphrase if this script is invoked under bash -x.
set +o xtrace
export BUNDLE_PASS=""

APP_DIR="${APP_DIR:-/opt/buntys}"
APP_USER="${APP_USER:-buntys}"
APP_HOME="/home/${APP_USER}"
UNIT="${UNIT:-buntys-app}"
PORT="${APP_PORT:-3100}"
HOST="${APP_HOST:-apps.buntys.in}"
LOG_FILE="${LOG_FILE:-/var/log/buntys-upgrade.log}"
BUNDLE_URL="${BUNDLE_URL:-https://raw.githubusercontent.com/majesticabeauty7/majestica-deploy/main/buntys-app.tar.gz.enc}"
# Stamped in the standalone GitHub copy after the bundle is encrypted. Override with BUNDLE_SHA256=... if needed.
BUNDLE_SHA256="${BUNDLE_SHA256:-4c21035688e2366d75527eafbad3bd3aad8140c89ec47b1a1b6232c2c94be57c}"
PASSF="${BUNDLE_PASS_FILE:-/root/.majestica-bundle-pass}"
OWNER_EMAIL="manish8393@gmail.com"
APPROVER_DEFAULT="manish8393@gmail.com"

[[ "$APP_DIR" == *majestica* || "$UNIT" == *majestica* ]] && { echo "refusing Majestica paths" >&2; exit 1; }
[[ "$APP_DIR" == /opt/buntys ]] || { echo "refusing unexpected APP_DIR=$APP_DIR" >&2; exit 1; }
[[ -f "$APP_DIR/.env" && -f "$APP_DIR/package.json" ]] || { echo "Buntys is not installed in $APP_DIR" >&2; exit 1; }
[[ -s "$PASSF" ]] || { echo "bundle passphrase file missing: $PASSF" >&2; exit 1; }
[[ "$BUNDLE_SHA256" != __* && ${#BUNDLE_SHA256} -eq 64 ]] || { echo "this upgrade script was not stamped with BUNDLE_SHA256 (or pass BUNDLE_SHA256=...)" >&2; exit 1; }

mkdir -p "$(dirname "$LOG_FILE")"
touch "$LOG_FILE"
chmod 600 "$LOG_FILE"
exec > >(tee -a "$LOG_FILE") 2>&1

say() { printf '\n==> %s\n' "$*"; }
info() { printf '    %s\n' "$*"; }
ok() { printf '    OK  %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

STAMP="$(date +%Y%m%d%H%M%S)"
BK="/var/backups/buntys-upgrade-${STAMP}"
WORK=""
ROLLED=0
PHASE="start"

db_name() {
  # Print only the database name from DATABASE_URL; never print the URL itself.
  python3 - "$APP_DIR/.env" <<'PY'
import sys, re
name = ""
with open(sys.argv[1], "r", encoding="utf-8") as f:
    for line in f:
        if line.startswith("DATABASE_URL="):
            raw = line.split("=", 1)[1].strip().strip('"').strip("'")
            raw = raw.split("?", 1)[0]
            name = raw.rsplit("/", 1)[-1]
            break
if not name or not re.fullmatch(r"[A-Za-z0-9_]+", name):
    sys.exit(1)
print(name)
PY
}

ensure_env_key() {
  local key="$1" val="$2"
  if grep -q "^${key}=" "$APP_DIR/.env"; then
    info ".env already has $key"
  else
    printf '%s=%s\n' "$key" "$val" >>"$APP_DIR/.env"
    info "added $key to .env (was missing)"
  fi
}

as_app() {
  ( cd "$APP_DIR" && runuser -u "$APP_USER" -- env HOME="$APP_HOME" NEXT_TELEMETRY_DISABLED=1 NODE_OPTIONS=--max-old-space-size=3072 bash -c "$1" )
}

http_code() {
  local path="$1"
  curl -sS -o /dev/null -w '%{http_code}' --max-time 8 -H "Host: ${HOST}" "http://127.0.0.1${path}" 2>/dev/null || echo 000
}

wait_http() {
  local path="$1" seconds="$2" i code
  for i in $(seq 1 "$seconds"); do
    code="$(http_code "$path")"
    if [[ "$code" == "200" ]]; then
      ok "$path returned 200 (via nginx Host ${HOST})"
      return 0
    fi
    sleep 1
  done
  # Direct app port as a second opinion (still Buntys only).
  for i in $(seq 1 10); do
    code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:${PORT}${path}" 2>/dev/null || echo 000)"
    if [[ "$code" == "200" ]]; then
      ok "$path returned 200 (via 127.0.0.1:${PORT})"
      return 0
    fi
    sleep 1
  done
  return 1
}

restore_from_backup() {
  [[ $ROLLED -eq 1 ]] && return 0
  ROLLED=1
  say "ROLLBACK: restoring Buntys app + database from $BK (Majestica untouched)"
  systemctl stop "$UNIT" || true
  if [[ -f "$BK/opt-buntys.tar.gz" ]]; then
    tar -xzf "$BK/opt-buntys.tar.gz" -C "$APP_DIR"
    chown -R "$APP_USER:$APP_USER" "$APP_DIR"
    chmod 600 "$APP_DIR/.env" 2>/dev/null || true
    ok "restored $APP_DIR from backup"
  else
    printf 'ERROR: app backup missing, cannot restore files\n' >&2
  fi
  if [[ -f "$BK/buntys_app.dump" ]]; then
    local db
    db="$(db_name || true)"
    db="${db:-buntys_app}"
    if [[ "$db" == *majestica* ]]; then
      printf 'ERROR: refusing to restore a Majestica-looking database name\n' >&2
    else
      runuser -u postgres -- pg_restore --clean --if-exists --no-owner --no-privileges --dbname="$db" "$BK/buntys_app.dump" \
        && ok "restored database $db" \
        || printf 'ERROR: database restore failed\n' >&2
    fi
  fi
  systemctl start "$UNIT" || true
  sleep 3
  systemctl is-active --quiet "$UNIT" && ok "$UNIT is active after rollback" || printf 'ERROR: %s not active after rollback\n' "$UNIT" >&2
}

on_err() {
  local rc=$?
  printf '\nERROR: upgrade failed at phase=%s (exit %s)\n' "$PHASE" "$rc" >&2
  if [[ -d "$BK" && $ROLLED -eq 0 ]]; then
    restore_from_backup || true
  fi
  [[ -n "$WORK" && -d "$WORK" ]] && rm -rf "$WORK"
  exit "$rc"
}
trap on_err ERR

say "Buntys upgrade  $(date '+%F %T %Z')"
info "app=$APP_DIR unit=$UNIT host=$HOST  (Majestica will not be changed)"
PHASE="preflight"

DB_NAME="$(db_name)" || die "could not read database name from $APP_DIR/.env"
[[ "$DB_NAME" == "buntys_app" ]] || die "refusing unexpected database name (expected buntys_app)"
ok "target database name is buntys_app"

# ---- 1. backup
PHASE="backup"
say "1/6  Backup database + $APP_DIR"
install -d -m 700 "$BK"
if [[ -x /usr/local/sbin/buntys-backup ]]; then
  /usr/local/sbin/buntys-backup && ok "nightly-style encrypted dump ran" || info "nightly-style backup returned non-zero (continuing with a local dump)"
fi
runuser -u postgres -- pg_dump --format=custom --no-owner --no-privileges --file="$BK/buntys_app.dump" "$DB_NAME" \
  || die "pg_dump of buntys_app failed - nothing was changed"
chmod 600 "$BK/buntys_app.dump"
# Keep .env and built assets so rollback can restart without a rebuild if possible.
tar --exclude=node_modules -C "$APP_DIR" -czf "$BK/opt-buntys.tar.gz" .
chmod 600 "$BK/opt-buntys.tar.gz"
ok "backup at $BK"
info "rollback folder kept even if the upgrade succeeds"

# ---- 2. download + decrypt + unpack (keep .env)
PHASE="download"
say "2/6  Download and unpack the new bundle (keeping .env)"
WORK="$(mktemp -d /var/tmp/buntys-upgrade.XXXXXX)"
info "downloading bundle"
curl -fL --retry 4 --retry-delay 3 --retry-all-errors --connect-timeout 20 --max-time 600 -A "buntys-upgrade/1.0" -sS -o "$WORK/bundle.enc" "$BUNDLE_URL" \
  || die "could not download the bundle"
GOT="$(sha256sum "$WORK/bundle.enc" | cut -d' ' -f1)"
[[ "$GOT" == "$BUNDLE_SHA256" ]] || die "bundle checksum mismatch - download corrupted or replaced"
ok "bundle checksum OK ($(stat -c %s "$WORK/bundle.enc") bytes)"

PHASE="decrypt"
set +o xtrace
openssl enc -d -aes-256-cbc -pbkdf2 -pass file:"$PASSF" -in "$WORK/bundle.enc" -out "$WORK/bundle.tar.gz" 2>/dev/null \
  || die "decryption failed - wrong passphrase?"
tar -tzf "$WORK/bundle.tar.gz" >/dev/null 2>&1 || die "decrypted data is not a valid archive - wrong passphrase?"
mkdir -p "$WORK/stage"
tar -xzf "$WORK/bundle.tar.gz" -C "$WORK/stage"
[[ -f "$WORK/stage/package.json" && -f "$WORK/stage/prisma/schema.prisma" ]] || die "bundle does not look like the Buntys app"
grep -q 'provider *= *"postgresql"' "$WORK/stage/prisma/schema.prisma" || die "bundle schema is not PostgreSQL"
grep -q 'model FirstLoginRequest' "$WORK/stage/prisma/schema.prisma" || die "bundle is missing FirstLoginRequest"

PHASE="install"
# Keep live secrets, data files, installed modules and the current build until we replace the build after a successful compile.
rsync -a --delete \
  --exclude=/.env \
  --exclude=/node_modules \
  --exclude=/.next \
  --exclude=/.seeded \
  --exclude=/.field-key-issued \
  --exclude=/outbox.log \
  "$WORK/stage"/ "$APP_DIR"/
chown -R "$APP_USER:$APP_USER" "$APP_DIR"
chmod 600 "$APP_DIR/.env"
ok "new code unpacked; .env and data kept"

# ---- 3. env keys (only if missing)
PHASE="env"
say "3/6  Owner / approver emails (add only if missing)"
ensure_env_key BUNTYS_OWNER_EMAIL "$OWNER_EMAIL"
ensure_env_key APPROVER_EMAIL "$APPROVER_DEFAULT"
chown "$APP_USER:$APP_USER" "$APP_DIR/.env"
chmod 600 "$APP_DIR/.env"

# ---- 4. schema + build
PHASE="deps"
say "4/6  npm ci, additive schema, build"
as_app "npm ci --include=dev --no-audit --no-fund --loglevel=error" || die "npm ci failed"

PHASE="schema"
# This instance has no Prisma migration history (it was installed with db push). Additive db push
# applies FirstLoginRequest + loginId/claimedAt without deleting data. --accept-data-loss is NOT used.
as_app "set -a; . ./.env; set +a; npx prisma generate && npx prisma db push --skip-generate" \
  || die "prisma schema apply failed (no --accept-data-loss; data should be unchanged)"
# Confirm the new table exists (additive FirstLoginRequest).
reg="$(runuser -u postgres -- psql -d "$DB_NAME" -tAc "SELECT to_regclass('public.\"FirstLoginRequest\"')")"
[[ "${reg// /}" == *FirstLoginRequest* ]] || die "FirstLoginRequest table was not created"
ok "FirstLoginRequest table is present"
as_app "set -a; . ./.env; set +a; npm run --silent db:upgrade" || die "db upgrade failed (no data was deleted)"

PHASE="build"
rm -rf "$APP_DIR/.next"
chown -R "$APP_USER:$APP_USER" "$APP_DIR"
as_app "set -a; . ./.env; set +a; npm run build" || die "app build failed"
ok "build finished"

# ---- 5. restart (Buntys only)
PHASE="restart"
say "5/6  Restart $UNIT only"
systemctl restart "$UNIT"
sleep 2
systemctl is-active --quiet "$UNIT" || die "$UNIT is not active after restart"
ok "$UNIT is active"
if systemctl is-active --quiet majestica; then
  ok "majestica is still active (untouched)"
else
  info "warning: majestica is not active — this upgrade did not change it; please check separately"
fi

# ---- 6. health
PHASE="health"
say "6/6  Health checks"
wait_http /login 90 || die "/login did not return 200"
wait_http /first-login 90 || die "/first-login did not return 200"
ok "Buntys upgrade complete"
info "backup kept at $BK"
[[ -n "$WORK" && -d "$WORK" ]] && rm -rf "$WORK"
trap - ERR
exit 0
