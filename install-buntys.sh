#!/usr/bin/env bash
# =====================================================================================================================
# Buntys salon app - VPS bootstrap (isolated from Majestica Digital) (Ubuntu 24.04, run as root).  Idempotent: safe to run again.
#
#   install-buntys.sh / bootstrap.sh   install / update the Buntys app   (needs BUNDLE_URL; asks for the passphrase if BUNDLE_PASS is unset)
#   bootstrap.sh ssl        get a Let's Encrypt certificate for apps.buntys.in for the domain once DNS points at this server
#   (via curl)              curl -fsSL <url> | bash            |   curl -fsSL <url> | bash -s -- ssl
#   (after first install)   buntys-bootstrap [ssl]          (a copy is kept in /usr/local/sbin)
#
# Environment (all optional except BUNDLE_URL on a first install):
#   BUNDLE_URL      https URL of the encrypted bundle (openssl enc -aes-256-cbc -pbkdf2)
#   BUNDLE_PASS     passphrase (if unset it is read silently from the terminal; BUNDLE_PASS_FILE also works)
#   BUNDLE_SHA256   expected sha256 of the *encrypted* download (integrity check)
#   DOMAIN          default apps.buntys.in         LE_EMAIL  default no-reply@buntys.in
#   SEED_DEMO is ignored; this installer always seeds the Buntys salon (1 Super Admin + 6 empty team slots) once
#   SWAP_SIZE       default 2G           EXPECTED_IP  default 195.35.7.138 (used by the DNS check in ssl mode)
#   MJ_SKIP         comma list of steps to skip (testing): apt,node,swap,firewall,postgres,user,app,service,nginx
# Secrets are generated on the server, written to /root/buntys-secrets.txt (0600) and never printed.
# =====================================================================================================================
set -Eeuo pipefail
: "${BUNDLE_URL:=https://raw.githubusercontent.com/majesticabeauty7/majestica-deploy/main/buntys-app.tar.gz.enc}"; : "${BUNDLE_SHA256:=0ccb4198945125761d886e1b4e77b85af0f7e2ef6e3562a90f4e0d28db94438e}"; export BUNDLE_URL BUNDLE_SHA256

main() {
  # When piped (curl | bash) bash is reading this script from stdin: make sure no child command can swallow it.
  exec </dev/null

  # ---------------------------------------------------------------- configuration
  local MODE="${1:-install}"
  local DOMAIN="${DOMAIN:-apps.buntys.in}"
  local LE_EMAIL="${LE_EMAIL:-no-reply@buntys.in}"
  local EXPECTED_IP="${EXPECTED_IP:-195.35.7.138}"
  local APP_USER="${APP_USER:-buntys}"
  local APP_DIR="${APP_DIR:-/opt/buntys}"
  local APP_HOME="/home/${APP_USER}"
  local APP_PORT=3100
  local DB_NAME="buntys_app" DB_USER="buntys_app"
  local SECRETS_FILE="${SECRETS_FILE:-/root/buntys-secrets.txt}"
  local LOG_FILE="${LOG_FILE:-/var/log/buntys-bootstrap.log}"
  local SWAP_SIZE="${SWAP_SIZE:-2G}"
  local NGINX_SITE="${NGINX_SITE:-/etc/nginx/sites-available/buntys-app.conf}"
  local NGINX_ENABLED="${NGINX_ENABLED:-/etc/nginx/sites-enabled/buntys-app.conf}"
  local NGINX_SNIPPET="${NGINX_SNIPPET:-/etc/nginx/snippets/buntys-proxy.conf}"
  local UNIT_FILE="${UNIT_FILE:-/etc/systemd/system/buntys-app.service}"
  local MJ_SKIP="${MJ_SKIP:-}"
  local DB_PASS="" SESSION_SECRET="" PLATFORM_ADMIN_KEY="" COOKIE_SECURE_VAL="false" SEED_DEMO_VAL=""

  # ---------------------------------------------------------------- helpers
  say()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
  info() { printf '    %s\n' "$*"; }
  warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*" >&2; }
  die()  { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; exit 1; }

  # Isolation: this installer must never touch the live Majestica Digital app, its DB, or Naksha Art.
  assert_isolated() {
    local bad
    for bad in /opt/majestica /var/www/naksha-art /var/www/majestica /root/majestica-secrets.txt; do
      case "$APP_DIR/" in "$bad"|"$bad"/) die "refusing to install into $APP_DIR (Majestica/Naksha path)";; esac
    done
    [[ "$APP_DIR" == *majestica* ]] && die "APP_DIR cannot contain 'majestica' ($APP_DIR)"
    [[ "$APP_USER" == "majestica" || "$APP_USER" == "root" ]] && die "APP_USER must be a dedicated Buntys system user (not $APP_USER)"
    [[ "$APP_PORT" == "3000" ]] && die "APP_PORT 3000 is used by Majestica; Buntys must use another port (default 3100)"
    [[ "$DB_NAME" == "majestica" || "$DB_USER" == "majestica" ]] && die "refusing to use the Majestica database name or role"
    [[ "$UNIT_FILE" == *majestica.service ]] && die "refusing to overwrite the Majestica systemd unit"
    [[ "$NGINX_SITE" == *majestica* ]] && die "refusing to overwrite a Majestica nginx site"
    [[ "$SECRETS_FILE" == *majestica* ]] && die "refusing to overwrite Majestica secrets"
    [[ "$DOMAIN" == "apps.buntys.in" || "${FORCE_DOMAIN:-0}" == "1" ]] || die "DOMAIN must be apps.buntys.in (got ${DOMAIN})"
  }
  assert_isolated

  skip() { [[ ",${MJ_SKIP}," == *",$1,"* ]]; }
  rand_hex() { local s; s="$(openssl rand -hex "$1")"; printf '%s' "${s:0:$1}"; }   # $1 hex chars (alphanumeric, URL-safe)
  envget() { [[ -f "$2" ]] || return 0; sed -n "s/^$1=//p" "$2" | head -n1 | sed -e 's/^"//' -e 's/"$//'; }
  as_app() { ( cd "$APP_DIR" && runuser -u "$APP_USER" -- env HOME="$APP_HOME" NEXT_TELEMETRY_DISABLED=1 NODE_OPTIONS=--max-old-space-size=3072 bash -c "$1" ); }
  apt_get() { DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a apt-get -y -qq -o DPkg::Lock::Timeout=600 -o Dpkg::Options::=--force-confold -o Dpkg::Options::=--force-confdef "$@"; }
  have_systemd() { [[ -d /run/systemd/system ]]; }

  # ---------------------------------------------------------------- preflight
  [[ $EUID -eq 0 ]] || die "run as root"
  case "$MODE" in install|ssl) ;; *) die "unknown mode '$MODE' (use: install | ssl)";; esac
  mkdir -p "$(dirname "$LOG_FILE")"; touch "$LOG_FILE"; chmod 600 "$LOG_FILE"
  exec > >(tee -a "$LOG_FILE") 2>&1
  say "Buntys bootstrap: mode=$MODE  $(date '+%F %T %Z')"
  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    [[ "${ID:-}" == "ubuntu" ]] || warn "this script targets Ubuntu 24.04 (found ${PRETTY_NAME:-unknown})"
    [[ "${VERSION_ID:-}" == "24.04" ]] || warn "tested for Ubuntu 24.04 (found ${VERSION_ID:-unknown})"
  fi

  # ---------------------------------------------------------------- secrets (reuse on re-run, generate on first run)
  load_secrets() {
    local envf="$APP_DIR/.env" url
    url="$(envget DATABASE_URL "$envf")"
    DB_PASS="$(printf '%s' "$url" | sed -n "s#^postgresql://${DB_USER}:\([^@]*\)@.*#\1#p")"
    SESSION_SECRET="$(envget SESSION_SECRET "$envf")"
    PLATFORM_ADMIN_KEY="$(envget PLATFORM_ADMIN_KEY "$envf")"
    COOKIE_SECURE_VAL="$(envget COOKIE_SECURE "$envf")"; COOKIE_SECURE_VAL="${COOKIE_SECURE_VAL:-false}"
    MAIL_MODE_VAL="$(envget MAIL_MODE "$envf")"; MAIL_MODE_VAL="${MAIL_MODE_VAL:-stub}"   # v3.5: keep smtp once it is configured
    SEED_DEMO_VAL="${SEED_DEMO:-$(envget SEED_DEMO "$envf")}"; SEED_DEMO_VAL="${SEED_DEMO_VAL:-false}"
    [[ -n "$DB_PASS" ]] || DB_PASS="$(rand_hex 32)"
    [[ -n "$SESSION_SECRET" ]] || SESSION_SECRET="$(rand_hex 64)"
    [[ -n "$PLATFORM_ADMIN_KEY" ]] || PLATFORM_ADMIN_KEY="$(rand_hex 40)"
    # v3: field-encryption key + backup passphrase. Generated ONCE, then always reused (from .env or the secrets file).
    # NEVER regenerate FIELD_ENC_KEY: encrypted client data can only be read with the key it was written with.
    FIELD_ENC_KEY="$(envget FIELD_ENC_KEY "$envf")"; [[ -n "$FIELD_ENC_KEY" ]] || FIELD_ENC_KEY="$(envget FIELD_ENC_KEY "$SECRETS_FILE")"
    BACKUP_PASS="$(envget BACKUP_PASS "$SECRETS_FILE")"
    if [[ -z "$FIELD_ENC_KEY" ]]; then
      [[ -f "$APP_DIR/.field-key-issued" ]] && die "FIELD_ENC_KEY is missing from ${envf} and ${SECRETS_FILE} but a key was issued before. Restore it from your copy of ${SECRETS_FILE}; a new key would make encrypted data unreadable."
      FIELD_ENC_KEY="$(openssl rand -hex 32)"
    fi
    [[ -n "$BACKUP_PASS" ]] || BACKUP_PASS="$(rand_hex 48)"
    # v3.3 staff app: Web Push (VAPID) keys for shift reminders + secret for the optional external reminder timer. Generated once, reused.
    VAPID_PUBLIC_KEY="$(envget VAPID_PUBLIC_KEY "$envf")"; VAPID_PRIVATE_KEY="$(envget VAPID_PRIVATE_KEY "$envf")"; CRON_SECRET="$(envget CRON_SECRET "$envf")"
    if [[ -z "$VAPID_PUBLIC_KEY" || -z "$VAPID_PRIVATE_KEY" ]]; then
      local kp; kp="$(mktemp)"; openssl ecparam -name prime256v1 -genkey -noout -out "$kp" 2>/dev/null
      b64u() { base64 -w0 | tr '+/' '-_' | tr -d '='; }
      VAPID_PRIVATE_KEY="$(openssl ec -in "$kp" -outform DER 2>/dev/null | tail -c +8 | head -c 32 | b64u)"
      VAPID_PUBLIC_KEY="$(openssl ec -in "$kp" -pubout -outform DER 2>/dev/null | tail -c 65 | b64u)"
      rm -f "$kp"
    fi
    [[ -n "$CRON_SECRET" ]] || CRON_SECRET="$(rand_hex 48)"
  }

  # Decrypt buntys-smtp.env.enc (same bundle passphrase) and merge SMTP into the app .env (0600).
  # Never prints the password. Tests SMTP login only (no message is sent).
  apply_smtp_env() {
    local enc="" cand
    for cand in ${SMTP_ENC_FILE:-} "$APP_DIR/deploy/buntys-smtp.env.enc" /root/buntys-smtp.env.enc /tmp/buntys-smtp.env.enc; do
      [[ -n "$cand" && -f "$cand" ]] && { enc="$cand"; break; }
    done
    if [[ -z "$enc" ]]; then
      info "no buntys-smtp.env.enc found; MAIL_MODE stays as in .env (OTP email will use stub until SMTP is added)"
      return 0
    fi
    local passf="" tmp dec_ok=0
    if [[ -n "${BUNDLE_PASS_FILE:-}" && -s "${BUNDLE_PASS_FILE}" ]]; then passf="$BUNDLE_PASS_FILE"
    elif [[ -s /root/.majestica-bundle-pass ]]; then passf=/root/.majestica-bundle-pass
    fi
    tmp="$(mktemp /tmp/buntys-smtp.XXXXXX)"; chmod 600 "$tmp"
    if [[ -n "$passf" ]]; then
      openssl enc -d -aes-256-cbc -pbkdf2 -pass file:"$passf" -in "$enc" -out "$tmp" 2>/dev/null && dec_ok=1
    fi
    if [[ $dec_ok -eq 0 && -n "${BUNDLE_PASS:-}" ]]; then
      openssl enc -d -aes-256-cbc -pbkdf2 -pass env:BUNDLE_PASS -in "$enc" -out "$tmp" 2>/dev/null && dec_ok=1
    fi
    if [[ $dec_ok -eq 0 ]]; then
      rm -f "$tmp"
      warn "could not decrypt $enc (wrong or missing bundle passphrase). SMTP not applied."
      return 0
    fi
    local envf="$APP_DIR/.env" key val
    [[ -f "$envf" ]] || { rm -f "$tmp"; warn ".env missing; SMTP not applied"; return 0; }
    while IFS= read -r line || [[ -n "$line" ]]; do
      [[ "$line" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] || continue
      key="${line%%=*}"; val="${line#*=}"
      case "$key" in MAIL_MODE|SMTP_HOST|SMTP_PORT|SMTP_SECURE|SMTP_USER|SMTP_PASS|SMTP_PASS_B64|MAIL_FROM) ;; *) continue ;; esac
      if grep -q "^${key}=" "$envf"; then
        sed -i "s|^${key}=.*|${key}=${val}|" "$envf"
      else
        printf '%s\n' "${key}=${val}" >>"$envf"
      fi
    done <"$tmp"
    rm -f "$tmp"
    chown "$APP_USER:$APP_USER" "$envf"; chmod 600 "$envf"
    info "SMTP settings applied from $(basename "$enc") into ${envf} (chmod 600)"
    python3 - "$envf" <<'PY' || warn "SMTP login test could not be run (python3)"
import os, ssl, smtplib, sys, base64
envf = sys.argv[1]
env = {}
for line in open(envf):
    line=line.strip()
    if not line or line.startswith("#") or "=" not in line: continue
    k,v=line.split("=",1)
    env[k]=v.strip().strip('"').strip("'")
host=env.get("SMTP_HOST") or ""
port=int(env.get("SMTP_PORT") or "465")
user=env.get("SMTP_USER") or ""
pw=env.get("SMTP_PASS") or ""
b64=env.get("SMTP_PASS_B64") or ""
if b64 and not pw:
    try: pw=base64.b64decode(b64).decode("utf-8")
    except Exception:
        print("SMTP_AUTH FAIL (could not decode SMTP_PASS_B64)")
        sys.exit(0)
if not (host and user and pw):
    print("SMTP_AUTH SKIP (missing host/user/password after merge)")
    sys.exit(0)
secure=(env.get("SMTP_SECURE") or "true").lower()=="true" or port==465
ctx=ssl.create_default_context()
try:
    if secure or port==465:
        with smtplib.SMTP_SSL(host, port, context=ctx, timeout=20) as s:
            s.login(user, pw)
    else:
        with smtplib.SMTP(host, port, timeout=20) as s:
            s.ehlo(); s.starttls(context=ctx); s.ehlo(); s.login(user, pw)
    print("SMTP_AUTH PASS %s:%s user=%s (no message sent)" % (host, port, user))
except Exception as e:
    name=type(e).__name__
    msg=" ".join(str(a) for a in getattr(e,"args",()) if not isinstance(a,(bytes,bytearray)))
    low=msg.lower()
    if pw and pw.lower() in low: reason="auth error (details redacted)"
    elif any(s in low for s in ("authentication","auth","535","534","invalid login")): reason="authentication failed"
    elif "timed out" in low: reason="timeout"
    else: reason="connection or tls error"
    print("SMTP_AUTH FAIL %s:%s user=%s (%s: %s)" % (host, port, user, name, reason))
PY
  }

  write_env() {
    install -d -o "$APP_USER" -g "$APP_USER" -m 755 "$APP_DIR"
    local tmp; tmp="$(mktemp "$APP_DIR/.env.XXXXXX")"
    cat >"$tmp" <<EOF
NODE_ENV=production
PORT=${APP_PORT}
HOSTNAME=127.0.0.1
DATABASE_URL="postgresql://${DB_USER}:${DB_PASS}@127.0.0.1:5432/${DB_NAME}?schema=public"
SESSION_SECRET="${SESSION_SECRET}"
PLATFORM_ADMIN_KEY="${PLATFORM_ADMIN_KEY}"
COOKIE_SECURE=${COOKIE_SECURE_VAL}
SEED_DEMO=${SEED_DEMO_VAL}
MAIL_MODE=${MAIL_MODE_VAL}
FIELD_ENC_KEY=${FIELD_ENC_KEY}
NEXT_TELEMETRY_DISABLED=1
# v3.3 staff app shift reminders: Web Push keys. The app runs a one-minute reminder tick itself (src/instrumentation.ts).
# With several app processes set REMINDERS_TICK=off and add a systemd timer: curl -fsS -X POST -H "x-cron-secret: \$CRON_SECRET" http://127.0.0.1:${APP_PORT}/api/internal/reminders-tick
VAPID_PUBLIC_KEY=${VAPID_PUBLIC_KEY}
VAPID_PRIVATE_KEY=${VAPID_PRIVATE_KEY}
VAPID_SUBJECT=mailto:no-reply@buntys.in
CRON_SECRET=${CRON_SECRET}
APP_PUBLIC_URL=https://apps.buntys.in
APP_HOST=apps.buntys.in
INSTANCE_MODE=single
PUBLIC_SIGNUP=false
FREE_DEMO=false
SEED_DEMO=false
LOGIN_EMAIL_OTP=true
LOGIN_SMS_OTP=false
IDLE_LOGOUT_MINUTES=30
NEXT_PUBLIC_IDLE_LOGOUT_MINUTES=30
NEXT_PUBLIC_APP_NAME=Buntys
NEXT_PUBLIC_APP_URL=https://apps.buntys.in
BUNTYS_SEED_PASSWORDS_FILE=/root/buntys-user-passwords.json
BUNTYS_OWNER_EMAIL=${BUNTYS_OWNER_EMAIL:-manish8393@gmail.com}
EOF
    # v3.5: keep every OTHER key that was added to .env outside bootstrap (DEMO_SIGNUP_SECRET, APP_PUBLIC_URL, SMTP_*, MSG91_*, ...)
    if [[ -f "$APP_DIR/.env" ]]; then
      local managed=" NODE_ENV PORT HOSTNAME DATABASE_URL SESSION_SECRET PLATFORM_ADMIN_KEY COOKIE_SECURE SEED_DEMO MAIL_MODE FIELD_ENC_KEY NEXT_TELEMETRY_DISABLED VAPID_PUBLIC_KEY VAPID_PRIVATE_KEY VAPID_SUBJECT CRON_SECRET APP_PUBLIC_URL APP_HOST INSTANCE_MODE PUBLIC_SIGNUP FREE_DEMO LOGIN_EMAIL_OTP LOGIN_SMS_OTP IDLE_LOGOUT_MINUTES NEXT_PUBLIC_IDLE_LOGOUT_MINUTES NEXT_PUBLIC_APP_NAME NEXT_PUBLIC_APP_URL BUNTYS_SEED_PASSWORDS_FILE BUNTYS_OWNER_EMAIL " line key kept=0
      while IFS= read -r line; do
        [[ "$line" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] || continue
        key="${line%%=*}"; [[ "$managed" == *" $key "* ]] && continue
        grep -q "^${key}=" "$tmp" && continue
        [[ $kept -eq 0 ]] && printf '# kept from the previous .env (added outside bootstrap)\n' >>"$tmp"; printf '%s\n' "$line" >>"$tmp"; kept=$((kept+1))
      done <"$APP_DIR/.env"
    fi
    chown "$APP_USER:$APP_USER" "$tmp"; chmod 600 "$tmp"; mv -f "$tmp" "$APP_DIR/.env"
    [[ -f "$APP_DIR/.field-key-issued" ]] || { date '+%F %T' >"$APP_DIR/.field-key-issued"; chmod 600 "$APP_DIR/.field-key-issued"; }
  }

  write_secrets_file() {
    ( umask 077
      cat >"$SECRETS_FILE" <<EOF
# Buntys app - generated $(date '+%F %T %Z') - keep private (chmod 600)
PLATFORM_ADMIN_KEY=${PLATFORM_ADMIN_KEY}
DB_NAME=${DB_NAME}
DB_USER=${DB_USER}
DB_PASSWORD=${DB_PASS}
# FIELD_ENC_KEY encrypts client phone/email/address/notes and staff ID numbers. Generated ONCE, never regenerated.
# KEEP AN OFFLINE COPY: without it the encrypted fields cannot be read (also not from backups).
FIELD_ENC_KEY=${FIELD_ENC_KEY}
# BACKUP_PASS decrypts the nightly backups in /var/backups/buntys:
#   openssl enc -d -aes-256-cbc -pbkdf2 -pass pass:<BACKUP_PASS> -in FILE.sql.gz.enc | gunzip > restore.sql
BACKUP_PASS=${BACKUP_PASS}
# SESSION_SECRET and the full DATABASE_URL live in ${APP_DIR}/.env (root + ${APP_USER} only)
# User initial passwords: /root/buntys-user-passwords.json (chmod 600). Do not print them.
EOF
    )
    chmod 600 "$SECRETS_FILE"
  }

  # =====================================================================================================================
  # SSL MODE
  # =====================================================================================================================
  if [[ "$MODE" == "ssl" ]]; then
    [[ -f "$NGINX_SITE" ]] || die "nginx site not found - run the install step first"
    say "Checking DNS for ${DOMAIN}"
    local resolved pub=""
    resolved="$(getent ahostsv4 "$DOMAIN" | awk '{print $1; exit}' || true)"
    pub="$(curl -4fsS --max-time 8 https://api.ipify.org 2>/dev/null || true)"
    info "${DOMAIN} resolves to: ${resolved:-<nothing>}   | this server: ${pub:-unknown} (expected ${EXPECTED_IP})"
    if [[ -z "$resolved" ]]; then
      [[ "${FORCE_SSL:-0}" == "1" ]] || die "${DOMAIN} does not resolve yet. Add an A record  ${DOMAIN} -> ${pub:-$EXPECTED_IP}  and retry in a few minutes."
    elif [[ "$resolved" != "$EXPECTED_IP" && "$resolved" != "$pub" ]]; then
      [[ "${FORCE_SSL:-0}" == "1" ]] || die "${DOMAIN} resolves to ${resolved}, not to this server (${pub:-$EXPECTED_IP}). Fix the A record (DNS can take a while) and retry. FORCE_SSL=1 overrides."
    fi
    if getent ahostsv6 "$DOMAIN" >/dev/null 2>&1; then warn "${DOMAIN} also has an AAAA (IPv6) record; Let's Encrypt will validate over IPv6 too - make sure it points here or remove it."; fi
    nginx -t >/dev/null 2>&1 || die "nginx config is invalid (nginx -t)"
    say "Requesting certificate (certbot --nginx)"
    certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos -m "$LE_EMAIL" --redirect
    say "Switching the app to secure cookies + HSTS"
    load_secrets; COOKIE_SECURE_VAL=true; write_env
    sed -i 's|^\(\s*\)#\?\s*add_header Strict-Transport-Security.*|\1add_header Strict-Transport-Security "max-age=31536000" always;|' "$NGINX_SNIPPET"
    nginx -t && systemctl reload nginx
    have_systemd && systemctl restart buntys-app
    if systemctl is-enabled certbot.timer >/dev/null 2>&1; then info "certbot.timer is enabled (auto-renewal)"; else warn "certbot.timer not enabled - renewal is not scheduled"; fi
    if certbot renew --dry-run >/dev/null 2>&1; then info "certbot renew --dry-run: OK"; else warn "certbot renew --dry-run failed (check: certbot renew --dry-run)"; fi
    sleep 3
    local code; code="$(curl -fsS -o /dev/null -w '%{http_code}' --max-time 15 "https://${DOMAIN}/login" 2>/dev/null || true)"
    say "SSL done"
    info "https://${DOMAIN}/login -> HTTP ${code:-no response}"
    info "Note: with secure cookies, login works on https://${DOMAIN} (not on the plain-HTTP raw-IP fallback)."
    return 0
  fi

  # =====================================================================================================================
  # INSTALL MODE
  # =====================================================================================================================
  # ---- 1. base packages
  if ! skip apt; then
    say "1/10  System packages (apt update/upgrade + basics)"
    apt_get update
    apt_get upgrade
    apt_get install ca-certificates curl gnupg openssl rsync tar gzip ufw nginx postgresql postgresql-client certbot python3-certbot-nginx unzip
  fi

  # ---- 2. Node.js 20 LTS (NodeSource)
  if ! skip node; then
    say "2/10  Node.js 20 LTS"
    if command -v node >/dev/null 2>&1 && [[ "$(node -p 'process.versions.node.split(".")[0]')" == "20" ]]; then
      info "node $(node -v) already installed"
    else
      install -d -m 755 /etc/apt/keyrings
      curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key | gpg --batch --yes --dearmor -o /etc/apt/keyrings/nodesource.gpg
      echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_20.x nodistro main" >/etc/apt/sources.list.d/nodesource.list
      apt_get update
      apt_get install nodejs
      info "installed node $(node -v), npm $(npm -v)"
    fi
  fi

  # ---- 3. swap
  if ! skip swap; then
    say "3/10  Swapfile (${SWAP_SIZE})"
    if [[ -n "$(swapon --noheadings --show 2>/dev/null)" ]]; then
      info "swap already active:"; swapon --show | sed 's/^/      /'
    else
      if [[ ! -f /swapfile ]]; then
        fallocate -l "$SWAP_SIZE" /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=$(( ${SWAP_SIZE%G} * 1024 )) status=none
        chmod 600 /swapfile; mkswap /swapfile >/dev/null
      fi
      swapon /swapfile
      grep -qE '^/swapfile\s' /etc/fstab || echo '/swapfile none swap sw 0 0' >>/etc/fstab
      info "swap enabled"
    fi
    echo 'vm.swappiness=20' >/etc/sysctl.d/99-buntys-swap.conf; sysctl -q -p /etc/sysctl.d/99-buntys-swap.conf || true
  fi

  # ---- 4. firewall (rules are added BEFORE enabling, so an SSH session is never locked out)
  if ! skip firewall; then
    say "4/10  Firewall (ufw: 22, 80, 443)"
    ufw default deny incoming >/dev/null
    ufw default allow outgoing >/dev/null
    ufw allow 22/tcp >/dev/null
    ufw allow 80/tcp >/dev/null
    ufw allow 443/tcp >/dev/null
    ufw --force enable >/dev/null
    ufw status | sed 's/^/      /'
  fi

  # ---- 5. app user + secrets
  if ! skip user; then
    say "5/10  App user '${APP_USER}'"
    id -u "$APP_USER" >/dev/null 2>&1 || useradd --system --create-home --home-dir "$APP_HOME" --shell /usr/sbin/nologin "$APP_USER"
    install -d -o "$APP_USER" -g "$APP_USER" -m 755 "$APP_DIR"
  fi
  load_secrets

  # ---- 6. PostgreSQL role + database
  if ! skip postgres; then
    say "6/10  PostgreSQL database '${DB_NAME}' and user '${DB_USER}'"
    have_systemd && systemctl enable --now postgresql >/dev/null 2>&1 || true
    for _ in $(seq 1 30); do pg_isready -q && break; sleep 1; done
    pg_isready -q || die "PostgreSQL is not accepting connections"
    psql_pg() { runuser -u postgres -- psql -X -v ON_ERROR_STOP=1 "$@"; }
    if [[ "$(psql_pg -tAc "SELECT 1 FROM pg_roles WHERE rolname='${DB_USER}'")" == "1" ]]; then
      info "role exists - syncing its password with .env"
      psql_pg -v pw="$DB_PASS" >/dev/null <<<"ALTER ROLE ${DB_USER} WITH LOGIN PASSWORD :'pw';"
    else
      psql_pg -v pw="$DB_PASS" >/dev/null <<<"CREATE ROLE ${DB_USER} WITH LOGIN PASSWORD :'pw';"
    fi
    if [[ "$(psql_pg -tAc "SELECT 1 FROM pg_database WHERE datname='${DB_NAME}'")" != "1" ]]; then
      psql_pg -c "CREATE DATABASE ${DB_NAME} OWNER ${DB_USER} ENCODING 'UTF8'" >/dev/null
    fi
    # This role may use only its own database. Never grant it access to the Majestica DB.
    psql_pg -v ON_ERROR_STOP=0 -c "REVOKE ALL ON DATABASE postgres FROM ${DB_USER};" >/dev/null 2>&1 || true
    if [[ "$(psql_pg -tAc "SELECT 1 FROM pg_database WHERE datname='majestica'")" == "1" ]]; then
      psql_pg -v ON_ERROR_STOP=0 -c "REVOKE ALL ON DATABASE majestica FROM ${DB_USER};" >/dev/null 2>&1 || true
    fi
    psql_pg -c "GRANT CONNECT, TEMP ON DATABASE ${DB_NAME} TO ${DB_USER};" >/dev/null
    local listen; listen="$(psql_pg -tAc "SHOW listen_addresses" | tr -d '[:space:]')"
    if [[ "$listen" == "localhost" || "$listen" == "127.0.0.1" ]]; then
      info "database ready; PostgreSQL already listens on localhost only"
    else
      warn "PostgreSQL listen_addresses=${listen:-?} (expected localhost). Not changing it automatically because Majestica is also on this server. Set listen_addresses='localhost' in postgresql.conf when you can briefly reload Postgres."
    fi
  fi

  write_env
  write_secrets_file

  # ---- 7. fetch + decrypt + unpack the bundle, build
  local app_changed=0
  if ! skip app; then
    say "7/10  Application bundle"
    if [[ -n "${BUNDLE_URL:-}" ]]; then
      if [[ -z "${BUNDLE_PASS:-}" && -n "${BUNDLE_PASS_FILE:-}" ]]; then BUNDLE_PASS="$(<"$BUNDLE_PASS_FILE")"; fi
      if [[ -z "${BUNDLE_PASS:-}" ]]; then
        if { : </dev/tty; } 2>/dev/null; then
          printf 'Bundle passphrase (input hidden): ' >/dev/tty
          IFS= read -rs BUNDLE_PASS </dev/tty; printf '\n' >/dev/tty
        else
          die "no BUNDLE_PASS and no terminal to ask on"
        fi
      fi
      [[ -n "$BUNDLE_PASS" ]] || die "empty passphrase"
      export BUNDLE_PASS
      local work; work="$(mktemp -d /var/tmp/buntys-bundle.XXXXXX)"
      # shellcheck disable=SC2064
      trap "rm -rf '$work'" EXIT
      info "downloading bundle"
      curl -fL --retry 4 --retry-delay 3 --retry-all-errors --connect-timeout 20 --max-time 600 -A "buntys-bootstrap/1.0" -sS -o "$work/bundle.enc" "$BUNDLE_URL" \
        || die "could not download the bundle (is the temporary link still valid?)"
      info "downloaded $(stat -c %s "$work/bundle.enc") bytes, sha256 $(sha256sum "$work/bundle.enc" | cut -c1-16)..."
      if [[ -n "${BUNDLE_SHA256:-}" ]]; then
        [[ "$(sha256sum "$work/bundle.enc" | cut -d' ' -f1)" == "$BUNDLE_SHA256" ]] || die "bundle checksum mismatch - download corrupted or replaced"
        info "checksum OK"
      fi
      openssl enc -d -aes-256-cbc -pbkdf2 -pass env:BUNDLE_PASS -in "$work/bundle.enc" -out "$work/bundle.tar.gz" 2>/dev/null \
        || die "decryption failed - wrong passphrase?"
      unset BUNDLE_PASS
      tar -tzf "$work/bundle.tar.gz" >/dev/null 2>&1 || die "decrypted data is not a valid archive - wrong passphrase?"
      mkdir -p "$work/stage"; tar -xzf "$work/bundle.tar.gz" -C "$work/stage"
      [[ -f "$work/stage/package.json" && -f "$work/stage/prisma/schema.prisma" ]] || die "bundle does not look like the Buntys app"
      grep -q 'provider *= *"postgresql"' "$work/stage/prisma/schema.prisma" || die "bundle schema is not PostgreSQL"
      rsync -a --delete --exclude=/.env --exclude=/node_modules --exclude=/.next --exclude=/.seeded --exclude=/.field-key-issued --exclude=/outbox.log "$work/stage"/ "$APP_DIR"/
      chown -R "$APP_USER:$APP_USER" "$APP_DIR"
      app_changed=1
      info "unpacked to ${APP_DIR}"
      # v3.5: release env additions shipped INSIDE the encrypted bundle (deploy/release-env.add, KEY=value lines):
      # appended to .env only when the key is missing (existing values always win), then the file is deleted.
      if [[ -f "$APP_DIR/deploy/release-env.add" ]]; then
        local rl rk added=0
        while IFS= read -r rl; do
          [[ "$rl" =~ ^[A-Za-z_][A-Za-z0-9_]*=. ]] || continue; rk="${rl%%=*}"
          grep -q "^${rk}=" "$APP_DIR/.env" || { printf '%s\n' "$rl" >>"$APP_DIR/.env"; added=$((added+1)); info ".env: added ${rk}"; }
        done <"$APP_DIR/deploy/release-env.add"
        rm -f "$APP_DIR/deploy/release-env.add"; chown "$APP_USER:$APP_USER" "$APP_DIR/.env"; chmod 600 "$APP_DIR/.env"
        info "release env: ${added} new key(s)"
      fi
    elif [[ -f "$APP_DIR/package.json" ]]; then
      info "no BUNDLE_URL given - keeping the app already in ${APP_DIR}"
      [[ "${REBUILD:-0}" == "1" ]] && app_changed=1
      [[ -d "$APP_DIR/.next" ]] || app_changed=1
    else
      die "BUNDLE_URL is required on a first install"
    fi
    # keep a copy of this script for later runs (ssl mode, updates)
    if [[ -f "$APP_DIR/deploy/bootstrap.sh" ]]; then install -m 755 "$APP_DIR/deploy/bootstrap.sh" /usr/local/sbin/buntys-bootstrap; fi

    if [[ $app_changed -eq 1 ]]; then
      say "8/10  npm ci, database schema, seed, build (a few minutes)"
      as_app "npm ci --include=dev --no-audit --no-fund --loglevel=error"
      as_app "set -a; . ./.env; set +a; npx prisma db push --skip-generate"
      if [[ ! -f "$APP_DIR/.seeded" ]]; then
        info "seeding the Buntys salon and 7 users (passwords go to /root/buntys-user-passwords.json, not the log)"
        install -d -m 700 /root
        : > /root/buntys-user-passwords.json; chmod 600 /root/buntys-user-passwords.json
        chown "$APP_USER:$APP_USER" /root/buntys-user-passwords.json 2>/dev/null || true
        # The seed file is root-only; the app user cannot write under /root, so seed as root with the app .env.
        set -a; # shellcheck disable=SC1091
        . "$APP_DIR/.env"; set +a
        export BUNTYS_SEED_PASSWORDS_FILE=/root/buntys-user-passwords.json
        ( cd "$APP_DIR" && NODE_OPTIONS=--max-old-space-size=3072 npx tsx prisma/seed-buntys.ts ) >>"$LOG_FILE" 2>&1 \
          || die "Buntys seed failed (see $LOG_FILE). No passwords were printed."
        chmod 600 /root/buntys-user-passwords.json
        printf '\n# Initial user passwords are in /root/buntys-user-passwords.json (chmod 600). Never echo this file.\n' >>"$SECRETS_FILE"
        date '+%F %T' >"$APP_DIR/.seeded"; chown "$APP_USER:$APP_USER" "$APP_DIR/.seeded"
        info "seeded Buntys users; passwords stored in /root/buntys-user-passwords.json"
      else
        info "seed skipped (already marked in $APP_DIR/.seeded)"
      fi
      info "v3 upgrade: new role permissions + encrypt existing sensitive fields (idempotent, deletes nothing)"
      as_app "set -a; . ./.env; set +a; npm run --silent db:upgrade" || die "db upgrade failed (no data was deleted; see the log above)"
      rm -rf "$APP_DIR/.next"   # always a clean build: stale chunks from the previous version must not survive
      as_app "set -a; . ./.env; set +a; npm run build"
    fi
  fi

  apply_smtp_env

  # ---- 9. systemd service
  if ! skip service; then
    say "9/10  systemd service 'buntys-app' (127.0.0.1:${APP_PORT}, restarts on boot/crash)"
    cat >"$UNIT_FILE" <<EOF
[Unit]
Description=Buntys salon app (Next.js)
After=network-online.target postgresql.service
Wants=network-online.target postgresql.service

[Service]
Type=simple
User=${APP_USER}
Group=${APP_USER}
WorkingDirectory=${APP_DIR}
EnvironmentFile=${APP_DIR}/.env
ExecStart=/usr/bin/node ${APP_DIR}/node_modules/next/dist/bin/next start -p ${APP_PORT} -H 127.0.0.1
Restart=always
RestartSec=3
LimitNOFILE=65535
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectHome=true

[Install]
WantedBy=multi-user.target
EOF
    # nightly encrypted database backup (pg_dump | gzip | AES-256), 14 days kept
    install -d -m 700 /var/backups/buntys
    ( umask 077; printf '%s' "$BACKUP_PASS" >/root/.buntys-backup-pass ); chmod 600 /root/.buntys-backup-pass
    cat >/usr/local/sbin/buntys-backup <<BKEOF
#!/usr/bin/env bash
# Buntys nightly backup: encrypted pg_dump, 14 days kept. Decrypt with BACKUP_PASS from ${SECRETS_FILE}.
set -euo pipefail
umask 077
out="/var/backups/buntys/${DB_NAME}-\$(date +%F-%H%M).sql.gz.enc"
runuser -u postgres -- pg_dump --no-owner --no-privileges "${DB_NAME}" | gzip -9 | openssl enc -aes-256-cbc -pbkdf2 -salt -pass file:/root/.buntys-backup-pass -out "\$out.part"
mv -f "\$out.part" "\$out"
find /var/backups/buntys -maxdepth 1 -name '${DB_NAME}-*.sql.gz.enc' -mtime +13 -delete
find /var/backups/buntys -maxdepth 1 -name '*.part' -mmin +120 -delete
BKEOF
    chmod 700 /usr/local/sbin/buntys-backup
    cat >/etc/systemd/system/buntys-backup.service <<BKEOF
[Unit]
Description=Buntys encrypted database backup
After=postgresql.service
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/buntys-backup
BKEOF
    cat >/etc/systemd/system/buntys-backup.timer <<BKEOF
[Unit]
Description=Nightly Buntys database backup (02:30)
[Timer]
OnCalendar=*-*-* 02:30:00
Persistent=true
RandomizedDelaySec=10m
[Install]
WantedBy=timers.target
BKEOF
    systemctl daemon-reload
    systemctl enable --now buntys-backup.timer >/dev/null 2>&1 || warn "could not enable the backup timer"
    systemctl enable buntys-app >/dev/null 2>&1
    systemctl restart buntys-app
    for _ in $(seq 1 60); do
      curl -fsS -o /dev/null --max-time 3 "http://127.0.0.1:${APP_PORT}/login" 2>/dev/null && break; sleep 1
    done
    curl -fsS -o /dev/null --max-time 5 "http://127.0.0.1:${APP_PORT}/login" || { journalctl -u buntys-app -n 30 --no-pager || true; die "app did not come up on 127.0.0.1:${APP_PORT}"; }
    info "app is answering on 127.0.0.1:${APP_PORT}"
  fi

  # ---- 10. nginx
  if ! skip nginx; then
    say "10/10  nginx reverse proxy for ${DOMAIN} (+ raw IP default server)"
    install -d -m 755 "$(dirname "$NGINX_SNIPPET")" "$(dirname "$NGINX_SITE")" "$(dirname "$NGINX_ENABLED")"
    # keep an HSTS line only if SSL was already set up on a previous run
    local hsts='# add_header Strict-Transport-Security "max-age=31536000" always;'
    [[ "$COOKIE_SECURE_VAL" == "true" ]] && hsts='add_header Strict-Transport-Security "max-age=31536000" always;'
    cat >"$NGINX_SNIPPET" <<EOF
# Managed by buntys-bootstrap - apps.buntys.in only (does not change the Majestica vhost)
client_max_body_size 10m;
gzip on;
gzip_comp_level 5;
gzip_min_length 512;
gzip_proxied any;
gzip_vary on;
gzip_types text/plain text/css text/xml application/json application/javascript text/javascript application/xml application/xml+rss image/svg+xml application/manifest+json font/ttf font/otf;

add_header X-Content-Type-Options "nosniff" always;
add_header X-Frame-Options "SAMEORIGIN" always;
add_header Referrer-Policy "strict-origin-when-cross-origin" always;
add_header Permissions-Policy "camera=(self), microphone=(), geolocation=(self)" always; # v3.3: barcode scanner, punch selfie, geo attendance
${hsts}

location / {
    proxy_pass http://127.0.0.1:${APP_PORT};
    proxy_http_version 1.1;
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$remote_addr;   # v3.5: never trust a client-sent X-Forwarded-For (rate limits use it)
    proxy_set_header X-Forwarded-Proto \$scheme;
    proxy_set_header Upgrade \$http_upgrade;
    proxy_set_header Connection \$connection_upgrade;
    proxy_read_timeout 60s;
    proxy_send_timeout 60s;
}
EOF
    # certbot --nginx edits the named server block (adds 443 + redirect); the IP default block stays plain HTTP.
    # (If certbot already rewrote the site file, leave it alone.)
    if [[ -f "$NGINX_SITE" ]] && grep -q 'managed by Certbot' "$NGINX_SITE"; then
      info "site file already managed by certbot - leaving it as is"
    else
      cat >"$NGINX_SITE" <<EOF
# Managed by buntys-bootstrap — only apps.buntys.in. Does not claim default_server.
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN};
    include ${NGINX_SNIPPET};
}
EOF
    fi
    ln -sf "$NGINX_SITE" "$NGINX_ENABLED"
    # Do NOT remove the default site or rewrite Majestica's global nginx conf.
    if [[ ! -f /etc/nginx/conf.d/buntys-map.conf ]] && ! grep -Rqs 'connection_upgrade' /etc/nginx/conf.d/ /etc/nginx/nginx.conf 2>/dev/null; then
      cat >/etc/nginx/conf.d/buntys-map.conf <<'EOF'
# Safe to keep even if Majestica already defined this map elsewhere; only written when missing.
map $http_upgrade $connection_upgrade { default upgrade; '' close; }
EOF
    fi
    nginx -t || die "nginx -t failed; not reloading. The Majestica site was not changed."
    have_systemd && { systemctl enable nginx >/dev/null 2>&1; systemctl reload nginx 2>/dev/null || systemctl restart nginx; }
    local code; code="$(curl -fsS -o /dev/null -w '%{http_code}' --max-time 10 -H "Host: ${DOMAIN}" http://127.0.0.1/login 2>/dev/null || true)"
    info "nginx -> app: HTTP ${code:-no response} (Host: ${DOMAIN})"
    info "Majestica vhost and Naksha were not modified"
  fi

  # ---------------------------------------------------------------- summary
  local pub; pub="$(curl -4fsS --max-time 6 https://api.ipify.org 2>/dev/null || echo "$EXPECTED_IP")"
  say "DONE"
  cat <<EOF

  App            : ${APP_DIR}   (systemd unit: buntys-app, runs as '${APP_USER}' on 127.0.0.1:${APP_PORT})
  Domain         : http://${DOMAIN}/login        (once DNS A record apps -> ${pub})
  Isolated from  : Majestica Digital (unit majestica, :3000, /opt/majestica) and Naksha Art
  Secrets        : ${SECRETS_FILE}  (chmod 600; DB password, FIELD_ENC_KEY, BACKUP_PASS - not shown)
                   User passwords : /root/buntys-user-passwords.json  (chmod 600; never printed)
                   COPY BOTH OFF THE SERVER: FIELD_ENC_KEY is needed to read encrypted client data.
  Backups        : nightly 02:30 -> /var/backups/buntys (encrypted, 14 days kept)   run now: buntys-backup
                   Off-site hook : /usr/local/sbin/buntys-backup-offsite (disabled until you install and enable it)
  Logs           : journalctl -u buntys-app -f      ${LOG_FILE}
  Next step      : point DNS A record apps.buntys.in -> ${pub}, then run:  buntys-bootstrap ssl
EOF
  [[ -f /var/run/reboot-required ]] && warn "a reboot is recommended (kernel/libs were upgraded): run 'reboot', the app and nginx start automatically."
  return 0
}

main "$@"
