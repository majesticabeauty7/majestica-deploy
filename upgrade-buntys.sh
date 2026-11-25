#!/usr/bin/env bash
# Upgrade an already-installed Buntys instance at /opt/buntys.
# Does NOT touch Majestica, Naksha, nginx vhosts other than health-checks, or the marketing site.
#
# As root, after this script and the encrypted bundle are on GitHub:
#   nohup bash -c 'curl -fsSL https://raw.githubusercontent.com/majesticabeauty7/majestica-deploy/<COMMIT>/upgrade-buntys.sh -o /tmp/upgrade-buntys.sh && echo "<SCRIPT_SHA256>  /tmp/upgrade-buntys.sh" | sha256sum -c - && chmod 700 /tmp/upgrade-buntys.sh && BUNDLE_PASS_FILE=/root/.majestica-bundle-pass /tmp/upgrade-buntys.sh' >/var/log/buntys-upgrade.log 2>&1 &
#
# Steps: optional recover from a half-applied run → backup (pg_dump + /opt/buntys) → unpack
# (keep .env) → additive schema (pre-check + allowlisted prisma db push) → owner emails
# → build → restart buntys-app → health check.
# After unpack (step 2), ANY failure (including `die` / exit) rolls the app back from this
# run's backup; the database is restored only if the schema was changed.
# Logs: /var/log/buntys-upgrade.log
set -Eeuo pipefail
[[ $EUID -eq 0 ]] || { echo "run as root" >&2; exit 1; }
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
BK=""
WORK=""
ROLLED=0
ROLLBACK_ON_FAIL=0
SCHEMA_CHANGED=0
PHASE="start"

db_name() {
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

psql_app() {
  # One SQL string in $1; prints the first trimmed line of stdout. Never used to print secrets.
  runuser -u postgres -- psql -d "$DB_NAME" -tAc "$1"
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

column_exists() {
  local n
  n="$(psql_app "SELECT count(*) FROM information_schema.columns WHERE table_schema='public' AND table_name='User' AND column_name='loginId'")"
  [[ "${n// /}" == "1" ]]
}

table_exists() {
  local n
  n="$(psql_app "SELECT count(*) FROM information_schema.tables WHERE table_schema='public' AND table_name='FirstLoginRequest'")"
  [[ "${n// /}" == "1" ]]
}

backup_is_valid() {
  local dir="$1"
  [[ -d "$dir" && -s "$dir/opt-buntys.tar.gz" && -s "$dir/buntys_app.dump" ]] || return 1
  pg_restore --list "$dir/buntys_app.dump" >/dev/null 2>&1
}

latest_valid_backup() {
  local d
  ls -1d /var/backups/buntys-upgrade-[0-9]* 2>/dev/null | sort | while read -r d; do
    backup_is_valid "$d" && echo "$d"
  done | tail -1
}

# Fail-closed: only additive DDL may be applied. FOREIGN KEY / PRIMARY KEY are allowed
# with UNIQUE because FirstLoginRequest needs FKs; any DROP / type change / DML is rejected.
sql_is_additive() {
  python3 - "$1" <<'PY'
import re, sys
raw = open(sys.argv[1], encoding="utf-8", errors="replace").read()
# strip /* */ and -- comments
raw = re.sub(r"/\*.*?\*/", " ", raw, flags=re.S)
lines = []
for line in raw.splitlines():
    lines.append(re.sub(r"--.*$", "", line))
text = "\n".join(lines)
# Prisma prints this when there is nothing to do
if re.search(r"empty migration", text, re.I) and not re.search(r"\b(ALTER|CREATE|DROP|TRUNCATE|DELETE|UPDATE)\b", text, re.I):
    sys.exit(0)
parts = [p.strip() for p in text.split(";") if p.strip()]
allow = [
    r"^ALTER\s+TABLE\s+\S+\s+ADD\s+COLUMN\b",
    r"^ALTER\s+TABLE\s+\S+\s+ADD\s+CONSTRAINT\b.*\b(UNIQUE|FOREIGN\s+KEY|PRIMARY\s+KEY)\b",
    r"^CREATE\s+TABLE\b",
    r"^CREATE\s+(UNIQUE\s+)?INDEX\b",
]
# A single ALTER TABLE may add several columns: "ADD COLUMN a, ADD COLUMN b"
allow_alter_multi = re.compile(
    r"^ALTER\s+TABLE\s+\S+(\s+ADD\s+COLUMN\b[^,;]+,)*\s+ADD\s+COLUMN\b",
    re.I | re.S,
)
deny = re.compile(
    r"\b(DROP\s+TABLE|DROP\s+COLUMN|DROP\s+INDEX|DROP\s+CONSTRAINT|DROP\s+TYPE|TRUNCATE|DELETE\s+FROM|UPDATE\s+\S+\s+SET|ALTER\s+COLUMN|SET\s+DATA\s+TYPE|TYPE\s+)\b",
    re.I,
)
for stmt in parts:
    compact = re.sub(r"\s+", " ", stmt).strip()
    if not compact:
        continue
    if deny.search(compact):
        print("rejected (destructive): " + compact[:240], file=sys.stderr)
        sys.exit(2)
    if allow_alter_multi.match(compact) or any(re.search(p, compact, re.I | re.S) for p in allow):
        continue
    print("rejected (not on allow-list): " + compact[:240], file=sys.stderr)
    sys.exit(3)
sys.exit(0)
PY
}

restore_app_from() {
  local dir="$1"
  [[ -s "$dir/opt-buntys.tar.gz" ]] || { printf 'ERROR: app backup missing in %s\n' "$dir" >&2; return 1; }
  local envbak
  envbak="$(mktemp /var/tmp/buntys-env.XXXXXX)"
  cp -a "$APP_DIR/.env" "$envbak"
  chmod 600 "$envbak"
  tar -xzf "$dir/opt-buntys.tar.gz" -C "$APP_DIR"
  # Keep the live .env (APPROVER_EMAIL and other keys added this run stay).
  cp -a "$envbak" "$APP_DIR/.env"
  rm -f "$envbak"
  chown -R "$APP_USER:$APP_USER" "$APP_DIR"
  chmod 600 "$APP_DIR/.env"
  ok "restored $APP_DIR from $dir (kept live .env)"
}

restore_db_from() {
  local dir="$1"
  [[ -s "$dir/buntys_app.dump" ]] || { printf 'ERROR: database dump missing or empty in %s\n' "$dir" >&2; return 1; }
  [[ "$DB_NAME" == *majestica* ]] && { printf 'ERROR: refusing to restore a Majestica-looking database name\n' >&2; return 1; }
  set +o xtrace
  runuser -u postgres -- pg_restore --clean --if-exists --no-owner --no-privileges --dbname="$DB_NAME" <"$dir/buntys_app.dump" \
    && ok "restored database $DB_NAME from $dir"
}

restore_from_backup() {
  local dir="${1:-$BK}"
  [[ $ROLLED -eq 1 ]] && return 0
  ROLLED=1
  say "ROLLBACK: restoring Buntys from $dir (Majestica untouched)"
  [[ -n "$dir" && -d "$dir" ]] || { printf 'ERROR: no backup directory to restore\n' >&2; return 1; }
  systemctl stop "$UNIT" || true
  restore_app_from "$dir" || true
  if [[ $SCHEMA_CHANGED -eq 1 ]]; then
    restore_db_from "$dir" || printf 'ERROR: database restore failed\n' >&2
  else
    info "schema was not changed; database left as-is"
  fi
  systemctl start "$UNIT" || true
  sleep 3
  systemctl is-active --quiet "$UNIT" && ok "$UNIT is active after rollback" || printf 'ERROR: %s not active after rollback\n' "$UNIT" >&2
  if wait_http /login 30; then
    ok "/login is 200 after rollback"
  else
    printf 'ERROR: /login is not 200 after rollback\n' >&2
  fi
}

on_fail() {
  local rc=$?
  trap - EXIT
  [[ $rc -eq 0 ]] && return 0
  printf '\nERROR: upgrade failed at phase=%s (exit %s)\n' "$PHASE" "$rc" >&2
  if [[ $ROLLBACK_ON_FAIL -eq 1 && $ROLLED -eq 0 ]]; then
    restore_from_backup "$BK" || true
  else
    info "no rollback (not past unpack, or already rolled back)"
  fi
  [[ -n "$WORK" && -d "$WORK" ]] && rm -rf "$WORK"
  exit "$rc"
}
# EXIT catches `die` (explicit exit) as well as ERR. The successful path clears this trap.
trap on_fail EXIT
trap 'exit 1' ERR

say "Buntys upgrade  $(date '+%F %T %Z')"
info "app=$APP_DIR unit=$UNIT host=$HOST  (Majestica will not be changed)"
PHASE="preflight"

DB_NAME="$(db_name)" || die "could not read database name from $APP_DIR/.env"
[[ "$DB_NAME" == "buntys_app" ]] || die "refusing unexpected database name (expected buntys_app)"
ok "target database name is buntys_app"

# Already fully live? Do not downgrade.
if table_exists && column_exists && [[ "$(http_code /first-login)" == "200" ]]; then
  ok "already upgraded: /first-login is 200 and FirstLoginRequest exists"
  trap - EXIT
  exit 0
fi

# Half-applied previous run (new source unpacked, schema maybe not applied, build not live).
# Restore the last *good* (pre-unpack) app tree so a new backup is of a consistent old app,
# then continue. Database is left alone unless new schema objects are already present *and*
# we also need to roll them back — we don't, because additive columns are compatible with the
# old app; a later push will be a no-op or complete the unique index.
PREV_BK="$(latest_valid_backup || true)"
if [[ -n "$PREV_BK" ]] && { [[ -f "$APP_DIR/src/server/services/firstLogin.ts" ]] || grep -q 'model FirstLoginRequest' "$APP_DIR/prisma/schema.prisma" 2>/dev/null; }; then
  if ! table_exists || [[ "$(http_code /first-login)" != "200" ]]; then
    say "Recovering from a half-applied upgrade using $PREV_BK"
    # Don't use the EXIT rollback yet (we are not mid-new-run).
    restore_app_from "$PREV_BK"
    systemctl try-restart "$UNIT" || systemctl start "$UNIT" || true
    wait_http /login 60 || die "after recovering the previous app, /login is not 200"
    ok "half-applied source replaced; /login is healthy. Continuing a clean upgrade."
  fi
fi

# ---- 1. backup
PHASE="backup"
say "1/6  Backup database + $APP_DIR"
BK="/var/backups/buntys-upgrade-${STAMP}"
install -d -m 700 "$BK"
if [[ -x /usr/local/sbin/buntys-backup ]]; then
  /usr/local/sbin/buntys-backup && ok "nightly-style encrypted dump ran" || info "nightly-style backup returned non-zero (continuing with a local dump)"
fi
# postgres cannot create files in a root-owned 0700 directory, so dump to stdout and let root write the file.
set +o xtrace
runuser -u postgres -- pg_dump --format=custom --no-owner --no-privileges "$DB_NAME" >"$BK/buntys_app.dump" \
  || die "pg_dump of buntys_app failed - nothing was changed"
chmod 600 "$BK/buntys_app.dump"
dump_sz="$(stat -c %s "$BK/buntys_app.dump" 2>/dev/null || echo 0)"
[[ "$dump_sz" -gt 0 ]] || die "pg_dump wrote an empty file - nothing was changed"
pg_restore --list "$BK/buntys_app.dump" >/dev/null || die "pg_dump output is not a valid archive - nothing was changed"
ok "database dump ${dump_sz} bytes"
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
# From here, any failure (including die/exit) must roll the app back.
ROLLBACK_ON_FAIL=1

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
# loginId is a NEW nullable unique column (it is not in the live v3.9 schema). Prisma
# treats "add unique constraint" as data loss even when every value is NULL. We add the
# column first if needed, refuse if any non-null loginId is duplicated, allow-list the
# planned SQL (additive only), then db push --accept-data-loss.
if ! column_exists; then
  info "adding nullable User.loginId so it can be checked before the unique index"
  psql_app 'ALTER TABLE "User" ADD COLUMN IF NOT EXISTS "loginId" TEXT' >/dev/null
  SCHEMA_CHANGED=1
  ok "User.loginId column added (nullable, no uniqueness yet)"
fi
dups="$(psql_app 'SELECT count(*) FROM (SELECT "loginId" FROM "User" WHERE "loginId" IS NOT NULL GROUP BY "loginId" HAVING count(*) > 1) d')"
dups="${dups// /}"
[[ "$dups" =~ ^[0-9]+$ ]] || die "could not count duplicate loginId values"
if [[ "$dups" -gt 0 ]]; then
  die "refusing schema change: $dups duplicated non-null loginId value(s). Rolling back."
fi
ok "no duplicate non-null loginId values"

DIFF="$WORK/schema.diff.sql"
DIFFERR="$WORK/schema.diff.err"
set +o xtrace
# Source .env inside the app user only; redact any URL that prisma might print on stderr.
as_app "set -a; . ./.env; set +a; npx prisma migrate diff --from-url \"\$DATABASE_URL\" --to-schema-datamodel prisma/schema.prisma --script" \
  >"$DIFF" 2>"$DIFFERR" || {
  sed -E 's#postgres(ql)?://[^[:space:]]+#postgresql://[redacted]#g' "$DIFFERR" >&2 || true
  die "prisma migrate diff failed"
}
if [[ -s "$DIFFERR" ]]; then
  sed -E 's#postgres(ql)?://[^[:space:]]+#postgresql://[redacted]#g' "$DIFFERR" >&2 || true
fi
if grep -qi 'empty migration' "$DIFF" && ! grep -Eqi 'ALTER|CREATE|DROP' "$DIFF"; then
  ok "schema already matches; skipping db push"
else
  info "planned schema SQL (allow-list check):"
  sed 's/^/    /' "$DIFF"
  if ! sql_is_additive "$DIFF"; then
    die "planned schema change is not purely additive (only ADD COLUMN / CREATE TABLE / CREATE INDEX / ADD CONSTRAINT UNIQUE|FK are allowed). Rolling back."
  fi
  ok "schema diff is additive only"
  as_app "set -a; . ./.env; set +a; npx prisma generate && npx prisma db push --skip-generate --accept-data-loss" \
    || die "prisma db push failed"
  SCHEMA_CHANGED=1
  ok "prisma db push applied (accept-data-loss only after additive allow-list + 0 loginId duplicates)"
fi
table_exists || die "FirstLoginRequest table was not created"
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
trap - EXIT
exit 0
