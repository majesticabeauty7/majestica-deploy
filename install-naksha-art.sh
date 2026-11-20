#!/usr/bin/env bash
# Install Naksha static PWA at https://majesticadigital.com/naksha-art/ (nginx alias, nothing else changed)
set -Eeuo pipefail
ZIP_URL="$1"; ZIP_SHA="$2"
CONF=/etc/nginx/sites-available/majestica-site.conf
DEST=/var/www/naksha-art
TS=$(date +%F-%H%M%S)
command -v unzip >/dev/null || apt-get install -y unzip >/dev/null
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
curl -fsSL --retry 4 -o "$W/n.zip" "$ZIP_URL"
[[ "$(sha256sum "$W/n.zip" | cut -d' ' -f1)" == "$ZIP_SHA" ]] || { echo "checksum mismatch"; exit 1; }
echo "ok checksum"
mkdir -p "$W/x" && unzip -q "$W/n.zip" -d "$W/x"
[[ -f "$W/x/index.html" ]] || { echo "index.html missing"; exit 1; }
[[ -f "$W/x/dl/NakshaArt.apk" && ! -f "$W/x/NakshaArt.apk" ]] && cp "$W/x/dl/NakshaArt.apk" "$W/x/NakshaArt.apk"
[[ -d $DEST ]] && tar -czf /var/backups/naksha-art-before-$TS.tgz -C /var/www naksha-art
rm -rf "$DEST.new" && cp -a "$W/x" "$DEST.new" && chown -R root:root "$DEST.new" && find "$DEST.new" -type d -exec chmod 755 {} + && find "$DEST.new" -type f -exec chmod 644 {} +
rm -rf "$DEST" && mv "$DEST.new" "$DEST"
echo "ok files in $DEST"
cat > /etc/nginx/snippets/naksha-art.conf <<'NG'
# Naksha house-plan PWA (static) at /naksha-art/
location = /naksha-art { return 301 /naksha-art/; }
location ^~ /naksha-art/ {
    alias /var/www/naksha-art/;
    index index.html;
    try_files $uri $uri/ /naksha-art/index.html;
}
location = /naksha-art/NakshaArt.apk { alias /var/www/naksha-art/NakshaArt.apk; types { } default_type application/vnd.android.package-archive; add_header Content-Disposition "attachment; filename=NakshaArt.apk" always; }
location = /naksha-art/dl/NakshaArt.apk { alias /var/www/naksha-art/dl/NakshaArt.apk; types { } default_type application/vnd.android.package-archive; add_header Content-Disposition "attachment; filename=NakshaArt.apk" always; }
location = /naksha-art/sw.js { alias /var/www/naksha-art/sw.js; add_header Cache-Control "no-cache" always; }
NG
if ! grep -q "snippets/naksha-art.conf" "$CONF"; then
  cp -a "$CONF" /var/backups/majestica-site.conf.before-naksha-art-$TS
  # add include before every "location / {" (proxy block) in the vhost
  sed -i 's#^\(\s*\)location / {#\1include snippets/naksha-art.conf;\n\1location / {#' "$CONF"
  if ! nginx -t 2>/tmp/naksha-art-nginx.err; then cat /tmp/naksha-art-nginx.err; cp -a /var/backups/majestica-site.conf.before-naksha-art-$TS "$CONF"; nginx -t; echo "FAILED: nginx config restored"; exit 1; fi
fi
grep -c "snippets/naksha-art.conf" "$CONF" | sed 's/^/includes: /'
nginx -t && systemctl reload nginx && echo "ok nginx reloaded"
sleep 1
for p in /naksha-art/ /naksha-art/js/app.js /naksha-art/manifest.json /naksha-art/NakshaArt.apk /naksha-art/dl/NakshaArt.apk /naksha-art /; do echo "$p $(curl -s -o /dev/null -w '%{http_code}' https://majesticadigital.com$p)"; done
curl -sI https://majesticadigital.com/naksha-art/NakshaArt.apk | grep -i content-type
echo "==> naksha done"
