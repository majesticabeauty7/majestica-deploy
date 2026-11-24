#!/bin/bash
# Apply a new buntys-smtp-v2.env.enc to /opt/buntys/.env and restart the app.
# Run as root (nohup). Never prints mailbox passwords or .env values.
set -euo pipefail

LOG=/var/log/buntys-smtp-apply.log
ENC_URL="https://raw.githubusercontent.com/majesticabeauty7/majestica-deploy/main/buntys-smtp-v2.env.enc"
ENC_SHA256="e3f5dc2ebe26da8105f72dc76d35b9331ef6f6dbd0fc5222f2f9267e504bd7ef"
APP_DIR=/opt/buntys
ENVF="$APP_DIR/.env"
PASSF=/root/.majestica-bundle-pass
UNIT=buntys-app
APP_URL="https://apps.buntys.in/login"
ENC_LOCAL=/tmp/buntys-smtp-v2.env.enc

umask 077
touch "$LOG"
chmod 600 "$LOG"
# All output goes only to the log (watch with: tail -f /var/log/buntys-smtp-apply.log)
exec >>"$LOG" 2>&1

log() { echo "[$(date -Is)] $*"; }

WORKDEC=""
cleanup() {
  rm -f "$ENC_LOCAL" "$WORKDEC" 2>/dev/null || true
}
trap cleanup EXIT

if [[ "$(id -u)" -ne 0 ]]; then
  log "must run as root"
  exit 1
fi

log "starting SMTP apply"

if ! curl -fsSL --retry 3 --retry-delay 2 -o "$ENC_LOCAL" "$ENC_URL"; then
  log "DOWNLOAD FAIL"
  exit 1
fi
got="$(sha256sum "$ENC_LOCAL" | awk '{print $1}')"
if [[ "$got" != "$ENC_SHA256" ]]; then
  log "SHA256 FAIL expected=${ENC_SHA256} got=${got}"
  exit 1
fi
log "download ok sha256 match"

if [[ ! -s "$PASSF" ]]; then
  log "MISSING passphrase file"
  exit 1
fi
if [[ ! -f "$ENVF" ]]; then
  log "MISSING app env"
  exit 1
fi

OWNER="$(stat -c '%U:%G' "$ENVF")"
log "env owner ${OWNER}"

STAMP="$(date +%Y%m%d%H%M%S)"
BAK="/root/buntys-env.bak.${STAMP}"
cp -a "$ENVF" "$BAK"
chown root:root "$BAK"
chmod 600 "$BAK"
log "backed up env to ${BAK}"

WORKDEC="$(mktemp /tmp/buntys-smtp-dec.XXXXXX)"
chmod 600 "$WORKDEC"
if ! openssl enc -d -aes-256-cbc -pbkdf2 -pass file:"$PASSF" -in "$ENC_LOCAL" -out "$WORKDEC" 2>/dev/null; then
  log "DECRYPT FAIL"
  exit 1
fi
log "decrypt ok"

# Merge SMTP keys only. Never print values. Drop a stale SMTP_PASS when B64 is supplied
# (the app prefers SMTP_PASS_B64; other tools might still read SMTP_PASS).
python3 - "$ENVF" "$WORKDEC" <<'PY'
import os, sys, tempfile
envf, src = sys.argv[1], sys.argv[2]
ALLOWED = {"MAIL_MODE", "SMTP_HOST", "SMTP_PORT", "SMTP_SECURE", "SMTP_USER", "SMTP_PASS", "SMTP_PASS_B64", "MAIL_FROM"}
new = {}
for line in open(src, encoding="utf-8"):
    line = line.strip()
    if not line or line.startswith("#") or "=" not in line:
        continue
    k, v = line.split("=", 1)
    if k in ALLOWED:
        new[k] = v
if not new.get("SMTP_PASS_B64") and not new.get("SMTP_PASS"):
    print("MERGE FAIL missing password key")
    sys.exit(1)
drop_pass = "SMTP_PASS_B64" in new and "SMTP_PASS" not in new
out_lines = []
seen = set()
for line in open(envf, encoding="utf-8"):
    raw = line.rstrip("\n")
    if (not raw) or raw.startswith("#") or "=" not in raw:
        out_lines.append(raw)
        continue
    k = raw.split("=", 1)[0]
    if drop_pass and k == "SMTP_PASS":
        continue
    if k in ALLOWED and k in new:
        out_lines.append(f"{k}={new[k]}")
        seen.add(k)
    else:
        out_lines.append(raw)
for k, v in new.items():
    if k not in seen:
        out_lines.append(f"{k}={v}")
        seen.add(k)
text = "\n".join(out_lines)
if not text.endswith("\n"):
    text += "\n"
fd, tmp = tempfile.mkstemp(prefix=".env.", dir=os.path.dirname(os.path.abspath(envf)))
try:
    os.chmod(fd, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        f.write(text)
        fd = None
    os.replace(tmp, envf)
except Exception:
    if fd is not None:
        try:
            os.close(fd)
        except OSError:
            pass
    try:
        os.unlink(tmp)
    except OSError:
        pass
    raise
print("MERGE OK keys=" + ",".join(sorted(seen)))
PY

chown "$OWNER" "$ENVF"
chmod 600 "$ENVF"
log "env updated chmod 600 owner ${OWNER}"

log "restarting ${UNIT}"
systemctl restart "$UNIT"
ok=0
for _ in $(seq 1 25); do
  sleep 1
  if systemctl is-active --quiet "$UNIT"; then
    ok=1
    break
  fi
done
if [[ "$ok" -eq 0 ]]; then
  log "UNIT FAIL not active"
else
  log "unit active"
fi

# SMTP login test only (no message sent). Print only OK or FAIL <error class>.
python3 - "$ENVF" <<'PY'
import ssl, smtplib, sys, base64
envf = sys.argv[1]
env = {}
for line in open(envf, encoding="utf-8"):
    line = line.strip()
    if not line or line.startswith("#") or "=" not in line:
        continue
    k, v = line.split("=", 1)
    env[k] = v.strip().strip('"').strip("'")
host = env.get("SMTP_HOST") or "smtp.hostinger.com"
port = int(env.get("SMTP_PORT") or "465")
user = env.get("SMTP_USER") or ""
pw = ""
b64 = env.get("SMTP_PASS_B64") or ""
if b64:
    try:
        pw = base64.b64decode(b64).decode("utf-8")
    except Exception:
        print("SMTP_AUTH FAIL DecodeError")
        sys.exit(0)
elif env.get("SMTP_PASS"):
    pw = env.get("SMTP_PASS") or ""
if not (host and user and pw):
    print("SMTP_AUTH FAIL MissingConfig")
    sys.exit(0)
secure = (env.get("SMTP_SECURE") or "true").lower() == "true" or port == 465
ctx = ssl.create_default_context()
try:
    if secure or port == 465:
        with smtplib.SMTP_SSL(host, port, context=ctx, timeout=25) as s:
            s.login(user, pw)
    else:
        with smtplib.SMTP(host, port, timeout=25) as s:
            s.ehlo()
            s.starttls(context=ctx)
            s.ehlo()
            s.login(user, pw)
    print("SMTP_AUTH OK")
except Exception as e:
    print("SMTP_AUTH FAIL %s" % type(e).__name__)
PY

code="$(curl -sS -o /dev/null -w "%{http_code}" --max-time 25 "$APP_URL" || echo 000)"
if [[ "$code" == "200" ]]; then
  log "APP 200"
else
  log "APP ${code}"
fi

log "done"
exit 0
