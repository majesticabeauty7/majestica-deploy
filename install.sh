#!/usr/bin/env bash
# =====================================================================================================================
# Majestica Digital - VPS bootstrap (Ubuntu 24.04, run as root).  Idempotent: safe to run again.
#
#   bootstrap.sh            install / update the app   (needs BUNDLE_URL; asks for the passphrase if BUNDLE_PASS is unset)
#   bootstrap.sh ssl        get a Let's Encrypt certificate for the domain once DNS points at this server
#   (via curl)              curl -fsSL <url> | bash            |   curl -fsSL <url> | bash -s -- ssl
#   (after first install)   majestica-bootstrap [ssl]          (a copy is kept in /usr/local/sbin)
#
# Environment (all optional except BUNDLE_URL on a first install):
#   BUNDLE_URL      https URL of the encrypted bundle (openssl enc -aes-256-cbc -pbkdf2)
#   BUNDLE_PASS     passphrase (if unset it is read silently from the terminal; BUNDLE_PASS_FILE also works)
#   BUNDLE_SHA256   expected sha256 of the *encrypted* download (integrity check)
#   DOMAIN          default app.majesticadigital.com         LE_EMAIL  default majesticabeauty7@gmail.com
#   SEED_DEMO       true|false (default true on the first install) - EXAMPLE demo salon
#   SWAP_SIZE       default 2G           EXPECTED_IP  default 195.35.7.138 (used by the DNS check in ssl mode)
#   MJ_SKIP         comma list of steps to skip (testing): apt,node,swap,firewall,postgres,user,app,service,nginx
# Secrets are generated on the server, written to /root/majestica-secrets.txt (0600) and never printed.
# =====================================================================================================================
set -Eeuo pipefail
: "${BUNDLE_URL:=https://raw.githubusercontent.com/majesticabeauty7/majestica-deploy/main/majestica-bundle.enc}"; : "${BUNDLE_SHA256:=799d64de13f9b35f27b9b50b84050d138456741edbd9c0a5b6746c5cd455091a}"; export BUNDLE_URL BUNDLE_SHA256

main() {
  # When piped (curl | bash) bash is reading this script from stdin: make sure no child command can swallow it.
  exec </dev/null

  # ---------------------------------------------------------------- configuration
  local MODE="${1:-install}"
  local DOMAIN="${DOMAIN:-app.majesticadigital.com}"
  local LE_EMAIL="${LE_EMAIL:-majesticabeauty7@gmail.com}"
  local EXPECTED_IP="${EXPECTED_IP:-195.35.7.138}"
  local APP_USER="${APP_USER:-majestica}"
  local APP_DIR="${APP_DIR:-/opt/majestica}"
  local APP_HOME="/home/${APP_USER}"
  local APP_PORT=3000
  local DB_NAME="majestica" DB_USER="majestica"
  local SECRETS_FILE="${SECRETS_FILE:-/root/majestica-secrets.txt}"
  local LOG_FILE="${LOG_FILE:-/var/log/majestica-bootstrap.log}"
  local SWAP_SIZE="${SWAP_SIZE:-2G}"
  local NGINX_SITE="${NGINX_SITE:-/etc/nginx/sites-available/majestica.conf}"
  local NGINX_ENABLED="${NGINX_ENABLED:-/etc/nginx/sites-enabled/majestica.conf}"
  local NGINX_SNIPPET="${NGINX_SNIPPET:-/etc/nginx/snippets/majestica-proxy.conf}"
  local UNIT_FILE="${UNIT_FILE:-/etc/systemd/system/majestica.service}"
  local MJ_SKIP="${MJ_SKIP:-}"
  local DB_PASS="" SESSION_SECRET="" PLATFORM_ADMIN_KEY="" COOKIE_SECURE_VAL="false" SEED_DEMO_VAL=""

  # ---------------------------------------------------------------- helpers
  say()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
  info() { printf '    %s\n' "$*"; }
  warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*" >&2; }
  die()  { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; exit 1; }
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
  say "Majestica bootstrap: mode=$MODE  $(date '+%F %T %Z')"
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
    SEED_DEMO_VAL="${SEED_DEMO:-$(envget SEED_DEMO "$envf")}"; SEED_DEMO_VAL="${SEED_DEMO_VAL:-true}"
    [[ -n "$DB_PASS" ]] || DB_PASS="$(rand_hex 32)"
    [[ -n "$SESSION_SECRET" ]] || SESSION_SECRET="$(rand_hex 64)"
    [[ -n "$PLATFORM_ADMIN_KEY" ]] || PLATFORM_ADMIN_KEY="$(rand_hex 40)"
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
MAIL_MODE=stub
NEXT_TELEMETRY_DISABLED=1
EOF
    chown "$APP_USER:$APP_USER" "$tmp"; chmod 600 "$tmp"; mv -f "$tmp" "$APP_DIR/.env"
  }

  write_secrets_file() {
    ( umask 077
      cat >"$SECRETS_FILE" <<EOF
# Majestica Digital - generated $(date '+%F %T %Z') - keep private (chmod 600)
PLATFORM_ADMIN_KEY=${PLATFORM_ADMIN_KEY}
DB_NAME=${DB_NAME}
DB_USER=${DB_USER}
DB_PASSWORD=${DB_PASS}
# SESSION_SECRET and the full DATABASE_URL live in ${APP_DIR}/.env (root + ${APP_USER} only)
# Platform console: https://${DOMAIN}/platform  (enter PLATFORM_ADMIN_KEY)
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
    have_systemd && systemctl restart majestica
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
    echo 'vm.swappiness=20' >/etc/sysctl.d/99-majestica-swap.conf; sysctl -q -p /etc/sysctl.d/99-majestica-swap.conf || true
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
    info "database ready (listens on localhost only)"
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
      local work; work="$(mktemp -d /var/tmp/majestica-bundle.XXXXXX)"
      # shellcheck disable=SC2064
      trap "rm -rf '$work'" EXIT
      info "downloading bundle"
      curl -fL --retry 4 --retry-delay 3 --retry-all-errors --connect-timeout 20 --max-time 600 -A "majestica-bootstrap/1.0" -sS -o "$work/bundle.enc" "$BUNDLE_URL" \
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
      [[ -f "$work/stage/package.json" && -f "$work/stage/prisma/schema.prisma" ]] || die "bundle does not look like the Majestica app"
      grep -q 'provider *= *"postgresql"' "$work/stage/prisma/schema.prisma" || die "bundle schema is not PostgreSQL"
      rsync -a --delete --exclude=/.env --exclude=/node_modules --exclude=/.next --exclude=/.seeded --exclude=/outbox.log "$work/stage"/ "$APP_DIR"/
      chown -R "$APP_USER:$APP_USER" "$APP_DIR"
      app_changed=1
      info "unpacked to ${APP_DIR}"
    elif [[ -f "$APP_DIR/package.json" ]]; then
      info "no BUNDLE_URL given - keeping the app already in ${APP_DIR}"
      [[ "${REBUILD:-0}" == "1" ]] && app_changed=1
      [[ -d "$APP_DIR/.next" ]] || app_changed=1
    else
      die "BUNDLE_URL is required on a first install"
    fi
    # keep a copy of this script for later runs (ssl mode, updates)
    if [[ -f "$APP_DIR/deploy/bootstrap.sh" ]]; then install -m 755 "$APP_DIR/deploy/bootstrap.sh" /usr/local/sbin/majestica-bootstrap; fi

    if [[ $app_changed -eq 1 ]]; then
      say "8/10  npm ci, database schema, seed, build (a few minutes)"
      as_app "npm ci --include=dev --no-audit --no-fund --loglevel=error"
      as_app "set -a; . ./.env; set +a; npx prisma db push --skip-generate"
      if [[ "$SEED_DEMO_VAL" == "true" && ! -f "$APP_DIR/.seeded" ]]; then
        info "seeding EXAMPLE demo salon (SEED_DEMO=true)"
        local seed_out
        seed_out="$(as_app "set -a; . ./.env; set +a; npm run --silent db:seed" 2>&1)" || { printf '%s\n' "$seed_out" | tail -n 20; die "seed failed"; }
        info "$(printf '%s\n' "$seed_out" | head -n 1)"
        date '+%F %T' >"$APP_DIR/.seeded"; chown "$APP_USER:$APP_USER" "$APP_DIR/.seeded"
      else
        info "seed skipped (SEED_DEMO=${SEED_DEMO_VAL}, marker: $([[ -f $APP_DIR/.seeded ]] && echo present || echo absent))"
      fi
      as_app "set -a; . ./.env; set +a; npm run build"
    fi
  fi

  # ---- 9. systemd service
  if ! skip service; then
    say "9/10  systemd service 'majestica' (127.0.0.1:${APP_PORT}, restarts on boot/crash)"
    cat >"$UNIT_FILE" <<EOF
[Unit]
Description=Majestica Digital (Next.js)
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
    systemctl daemon-reload
    systemctl enable majestica >/dev/null 2>&1
    systemctl restart majestica
    for _ in $(seq 1 60); do
      curl -fsS -o /dev/null --max-time 3 "http://127.0.0.1:${APP_PORT}/login" 2>/dev/null && break; sleep 1
    done
    curl -fsS -o /dev/null --max-time 5 "http://127.0.0.1:${APP_PORT}/login" || { journalctl -u majestica -n 30 --no-pager || true; die "app did not come up on 127.0.0.1:${APP_PORT}"; }
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
# Managed by majestica bootstrap - shared by the named server and the IP default server
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
add_header Permissions-Policy "camera=(), microphone=(), geolocation=()" always;
${hsts}

location / {
    proxy_pass http://127.0.0.1:${APP_PORT};
    proxy_http_version 1.1;
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
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
# Managed by majestica bootstrap
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN};
    include ${NGINX_SNIPPET};
}

# Fallback: anything else (raw IP, other host names) is served plain HTTP.
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;
    include ${NGINX_SNIPPET};
}
EOF
    fi
    ln -sf "$NGINX_SITE" "$NGINX_ENABLED"
    rm -f /etc/nginx/sites-enabled/default
    cat >/etc/nginx/conf.d/majestica-global.conf <<'EOF'
server_tokens off;
map $http_upgrade $connection_upgrade { default upgrade; '' close; }
EOF
    nginx -t
    have_systemd && { systemctl enable nginx >/dev/null 2>&1; systemctl reload nginx 2>/dev/null || systemctl restart nginx; }
    local code; code="$(curl -fsS -o /dev/null -w '%{http_code}' --max-time 10 -H "Host: ${DOMAIN}" http://127.0.0.1/login 2>/dev/null || true)"
    info "nginx -> app: HTTP ${code:-no response} (Host: ${DOMAIN})"
    code="$(curl -fsS -o /dev/null -w '%{http_code}' --max-time 10 http://127.0.0.1/login 2>/dev/null || true)"
    info "nginx -> app via IP default server: HTTP ${code:-no response}"
  fi

  # ---------------------------------------------------------------- summary
  local pub; pub="$(curl -4fsS --max-time 6 https://api.ipify.org 2>/dev/null || echo "$EXPECTED_IP")"
  say "DONE"
  cat <<EOF

  App            : ${APP_DIR}   (systemd unit: majestica, runs as '${APP_USER}' on 127.0.0.1:${APP_PORT})
  Try it now     : http://${pub}/login           (raw IP fallback, plain HTTP)
  Domain         : http://${DOMAIN}/login        (once DNS A record -> ${pub})
  Secrets        : ${SECRETS_FILE}  (chmod 600; PLATFORM_ADMIN_KEY + DB password - not shown on screen)
                   read them with:  cat ${SECRETS_FILE}
  Platform console: /platform  (needs PLATFORM_ADMIN_KEY)
  Demo data      : SEED_DEMO=${SEED_DEMO_VAL}$( [[ "$SEED_DEMO_VAL" == "true" ]] && echo " -> EXAMPLE salon: demo@majestica.example / Demo@1234 (public password! change/remove before real use)")
  Logs           : journalctl -u majestica -f      ${LOG_FILE}
  Next step      : point DNS A record ${DOMAIN} -> ${pub}, then run:  majestica-bootstrap ssl
EOF
  [[ -f /var/run/reboot-required ]] && warn "a reboot is recommended (kernel/libs were upgraded): run 'reboot', the app and nginx start automatically."
  return 0
}

main "$@"
