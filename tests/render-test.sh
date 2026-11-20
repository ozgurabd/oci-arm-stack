#!/usr/bin/env bash
# setup.sh'in ürettiği yapılandırmayı sunucuya dokunmadan doğrular.
#
#   bash tests/render-test.sh [ÇIKTI_KLASÖRÜ]
#
# Root gerekmez. Docker varsa compose.yaml ve nginx yapılandırması da denenir;
# REQUIRE_DOCKER=1 ise (CI) Docker olmaması hata sayılır.
# ÇIKTI_KLASÖRÜ verilirse üretilen dosyalar silinmez (CI örnek imajları oradan derler).
set -Eeuo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

if [[ -n "${1:-}" ]]; then
  mkdir -p "$1"
  WORK=$(cd "$1" && pwd)
  if [[ -n "$(ls -A "$WORK")" ]]; then
    echo "Çıktı klasörü boş olmalı: $WORK" >&2
    exit 1
  fi
else
  WORK=$(mktemp -d)
  trap 'rm -rf "$WORK"' EXIT
fi

export STACK_DIR="$WORK/stack" DOMAIN=example.com
# shellcheck source=SCRIPTDIR/../setup.sh
source "$ROOT/setup.sh"
trap - ERR

pass() { printf '  \033[32m✓\033[0m %s\n' "$*"; }
skip() {
  if [[ "${REQUIRE_DOCKER:-0}" == 1 ]]; then fail "$* (REQUIRE_DOCKER=1)"; fi
  printf '  \033[33m-\033[0m %s\n' "$*"
}
fail() { printf '  \033[31m✗\033[0m %s\n' "$*" >&2; exit 1; }
checksums() { (cd "$STACK_DIR" && find . -type f -print0 | sort -z | xargs -0 sha256sum); }

echo "==> Dosyalar üretiliyor: $STACK_DIR"
write_stack_files >/dev/null
write_sites_conf >/dev/null
pass "$(find "$STACK_DIR" -type f | wc -l | tr -d ' ') dosya üretildi"

echo "==> Tekrar çalıştırma"
before=$(checksums)
write_stack_files >/dev/null
write_sites_conf >/dev/null
[[ "$(checksums)" == "$before" ]] || fail "ikinci çalıştırma dosyaları değiştirdi"
pass "dosyalar ve parolalar korundu"

echo "==> Şablonlar"
if grep -rn '__DOMAIN__\|__STACK_DIR__' "$STACK_DIR"; then
  fail "doldurulmamış yer tutucu var"
fi
grep -q "server_name go.$DOMAIN;" "$STACK_DIR/nginx/conf.d/20-sites.conf" ||
  fail "alan adı nginx yapılandırmasına yazılmadı"
pass "yer tutucular dolduruldu"
bash -n "$STACK_DIR/backup-db.sh" || fail "backup-db.sh sözdizimi hatalı"
pass "backup-db.sh sözdizimi"

echo "==> compose.yaml"
if docker compose version >/dev/null 2>&1; then
  (cd "$STACK_DIR" && docker compose --profile tools config --quiet) || fail "compose.yaml geçersiz"
  pass "docker compose config"
else
  skip "docker compose yok, atlandı"
fi

echo "==> nginx yapılandırması"
if docker info >/dev/null 2>&1; then
  cert="$STACK_DIR/certbot/conf/live/main"
  mkdir -p "$cert"
  openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj "/CN=$DOMAIN" \
    -keyout "$cert/privkey.pem" -out "$cert/fullchain.pem" >/dev/null 2>&1
  image=$(awk '$1 == "image:" && $2 ~ /^nginx:/ {print $2; exit}' "$STACK_DIR/compose.yaml")
  docker run --rm --entrypoint nginx \
    -v "$STACK_DIR/nginx/nginx.conf:/etc/nginx/nginx.conf:ro" \
    -v "$STACK_DIR/nginx/conf.d:/etc/nginx/conf.d:ro" \
    -v "$STACK_DIR/nginx/snippets:/etc/nginx/snippets:ro" \
    -v "$STACK_DIR/certbot/conf:/etc/letsencrypt:ro" \
    -v "$STACK_DIR/certbot/www:/var/www/certbot:ro" \
    "$image" -t || fail "nginx -t başarısız"
  pass "nginx -t ($image)"
else
  skip "Docker çalışmıyor, atlandı"
fi

echo "Tüm kontroller geçti."
