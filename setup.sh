#!/usr/bin/env bash
# =============================================================================
#  oci-arm-stack: Oracle Cloud ARM sunucusunu (Ubuntu 26.04) tek komutla kurar
#  https://github.com/KULLANICI_ADI/oci-arm-stack
#
#  nginx + Let's Encrypt, PostgreSQL 18, Valkey 9.1, SILO (S3), Deno / .NET /
#  Go API'leri, otomatik güvenlik güncellemeleri, gecelik yedek ve sertifika
#  yenileme. Sunucu ve tüm konteynerler UTC saatiyle çalışır.
#
#  Kullanım :  sudo bash setup.sh example.com sen@example.com
#  Yardım   :  bash setup.sh --help
#
#  Tekrar çalıştırılabilir: var olan dosyalara ve parolalara dokunmaz, yalnızca
#  eksik adımları tamamlar. Log: /var/log/oci-setup.log
#
#  SPDX-License-Identifier: MIT
# =============================================================================
if [ -z "${BASH_VERSION:-}" ]; then
  echo "Bu betik bash ile çalışır: sudo bash setup.sh ALAN_ADI [E-POSTA]" >&2
  exit 1
fi
set -Eeuo pipefail

SCRIPT_VERSION="1.0.0"
REPO_URL="https://github.com/KULLANICI_ADI/oci-arm-stack"

# ---- Ayarlar ------------------------------------------------------------------
# Alan adı ve e-posta normalde argümanla verilir. Argüman veremediğin
# durumlarda (ör. cloud-init) boş değerleri burada doldurabilirsin:
#   DOMAIN="${DOMAIN:-example.com}"
DOMAIN="${DOMAIN:-}"
EMAIL="${EMAIL:-}"
ADMIN_USER="${ADMIN_USER:-${SUDO_USER:-ubuntu}}"
SSH_ALLOW_USERS="${SSH_ALLOW_USERS:-$ADMIN_USER}"
SERVER_HOSTNAME="${SERVER_HOSTNAME:-}"
SWAP_SIZE_GB="${SWAP_SIZE_GB:-4}"
DATA_DEVICE="${DATA_DEVICE:-}"
FORMAT_DATA_DEVICE="${FORMAT_DATA_DEVICE:-no}"
AUTO_REBOOT_TIME="${AUTO_REBOOT_TIME:-04:00}"   # UTC
SAMPLE_APPS="${SAMPLE_APPS:-1}"
SKIP_CERT="${SKIP_CERT:-0}"
SKIP_DNS_CHECK="${SKIP_DNS_CHECK:-0}"
FORCE_CONFIG="${FORCE_CONFIG:-0}"
STACK_DIR="${STACK_DIR:-/srv/stack}"
LOG_FILE="${LOG_FILE:-/var/log/oci-setup.log}"

DATA_DIR=/srv/data
BACKUP_DIR=/srv/backups
APIS=(deno dotnet go)
SUBDOMAINS=(deno dotnet go s3)
declare -A API_PORT=([deno]=8000 [dotnet]=8080 [go]=8081)
declare -A API_MAIN=([deno]=main.ts [dotnet]=Program.cs [go]=main.go)

export DEBIAN_FRONTEND=noninteractive NEEDRESTART_SUSPEND=1
APT=(apt-get -y -q -o DPkg::Lock::Timeout=600
     -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)
STEP=0
TOTAL_STEPS=15

usage() {
  cat <<EOF
oci-arm-stack ${SCRIPT_VERSION}: Oracle Cloud ARM sunucusunu tek komutla kurar

Kullanım:
  sudo bash setup.sh ALAN_ADI [E-POSTA]
  bash setup.sh --help | --version

  Örnek: sudo bash setup.sh example.com sen@example.com

  Alt alan adları: deno., dotnet., go. ve s3.ALAN_ADI (DNS A kayıtları bu
  sunucuyu göstermeli). E-posta isteğe bağlı; Let's Encrypt hesabı içindir.

İsteğe bağlı ayarlar (sudo env AYAR=değer bash setup.sh ... şeklinde ver):
  DATA_DEVICE=/dev/sdb       Ayrı block volume'u /srv'ye bağlar
  FORMAT_DATA_DEVICE=yes     DATA_DEVICE boşsa ext4 ile biçimlendirir
  SERVER_HOSTNAME=app-01     Sunucu adı
  ADMIN_USER=ubuntu          Dosyaların sahibi ve docker grubuna eklenecek kullanıcı
  SSH_ALLOW_USERS="ubuntu"   SSH ile girebilecek kullanıcılar (boşlukla ayır)
  SWAP_SIZE_GB=4             Swap boyutu (GB)
  AUTO_REBOOT_TIME=04:00     Güncelleme sonrası gerekirse yeniden başlatma saati (UTC)
  SAMPLE_APPS=0              Kod yoksa örnek API uygulamalarını oluşturma
  SKIP_CERT=1                Let's Encrypt adımını atla
  SKIP_DNS_CHECK=1           DNS kontrolünü atla (ör. Cloudflare proxy açıksa)
  FORCE_CONFIG=1             Yapılandırma dosyalarını yeniden yaz (eskiler .bak-*)

Betik tekrar çalıştırılabilir: var olan dosyalara ve parolalara dokunmaz,
yalnızca eksik adımları tamamlar. Log: /var/log/oci-setup.log
Belgeler: ${REPO_URL}
EOF
}

# ---- Yardımcılar --------------------------------------------------------------
log()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
step() { STEP=$((STEP + 1)); log "${STEP}/${TOTAL_STEPS} $*"; }
ok()   { printf '    \033[32m✓\033[0m %s\n' "$*"; }
warn() { printf '    \033[33m!\033[0m %s\n' "$*"; }
die()  { printf '\n\033[1;31mHATA:\033[0m %s\n' "$*" >&2; exit 1; }
on_error() {
  printf '\n\033[1;31mHATA:\033[0m %s. satırdaki komut başarısız oldu: %s\n' "$1" "$2" >&2
  printf 'Ayrıntı: %s. Sorunu giderip betiği aynı komutla tekrar çalıştırabilirsin.\n' \
    "$LOG_FILE" >&2
}
trap 'on_error "$LINENO" "$BASH_COMMAND"' ERR

# docker compose'u stack klasöründe çalıştırır
dc() { (cd "$STACK_DIR" && docker compose "$@"); }

# Şablondaki yer tutucuları doldurur
render() { sed -e "s|__DOMAIN__|${DOMAIN}|g" -e "s|__STACK_DIR__|${STACK_DIR}|g"; }

# stdin'i dosyaya yazar. Dosya varsa dokunmaz; FORCE_CONFIG=1 ise önce yedekler.
put() {
  local path="$1" mode="${2:-0644}"
  if [[ -e "$path" ]]; then
    if [[ "$FORCE_CONFIG" != 1 ]]; then
      cat >/dev/null
      ok "$path zaten var, korunuyor"
      return 0
    fi
    cp -p "$path" "$path.bak-$(date -u +%Y%m%d%H%M%S)"
  fi
  mkdir -p "$(dirname "$path")"
  cat >"$path"
  chmod "$mode" "$path"
  ok "$path yazıldı"
}

# Komut başarılı olana kadar dener: wait_for "Ad" saniye komut...
wait_for() {
  local desc="$1" timeout="$2" waited=0
  shift 2
  until "$@" >/dev/null 2>&1; do
    if ((waited >= timeout)); then
      warn "$desc ${timeout} sn içinde hazır olmadı"
      return 1
    fi
    sleep 5
    waited=$((waited + 5))
  done
  ok "$desc hazır"
}

# Başka bir apt işlemi (ör. açılıştaki otomatik güncelleme) bitene kadar bekler
wait_apt() {
  local i=0
  while fuser /var/lib/dpkg/lock-frontend /var/lib/apt/lists/lock >/dev/null 2>&1; do
    if ((i == 0)); then warn "Başka bir apt işlemi sürüyor, bitmesi bekleniyor…"; fi
    i=$((i + 1))
    if ((i > 120)); then break; fi
    sleep 5
  done
}

secret_for() { local var="${1^^}_DB_PASSWORD"; printf '%s' "${!var}"; }

is_running() { dc ps --status running --services 2>/dev/null | grep -x "$1" >/dev/null; }

# apps/<api>-api klasöründe derlenecek kod var mı?
has_code() {
  local dir="$STACK_DIR/apps/$1-api"
  case "$1" in
    go)     [[ -f "$dir/go.mod" ]] ;;
    deno)   [[ -f "$dir/main.ts" ]] ;;
    dotnet) compgen -G "$dir/*.csproj" >/dev/null ;;
    *)      return 1 ;;
  esac
}

# ---- 0. Ön kontroller -----------------------------------------------------------
preflight() {
  [[ $EUID -eq 0 ]] || die "Root yetkisi gerekli: sudo bash setup.sh ALAN_ADI [E-POSTA]"
  if [[ -z "$DOMAIN" ]]; then
    usage >&2
    die "Alan adı verilmedi."
  fi
  DOMAIN="${DOMAIN,,}"
  [[ "$DOMAIN" =~ ^([a-z0-9]([a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,}$ ]] ||
    die "Geçersiz alan adı: $DOMAIN"
  if [[ -n "$EMAIL" && ! "$EMAIL" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]]; then
    die "Geçersiz e-posta: $EMAIL"
  fi
  id "$ADMIN_USER" >/dev/null 2>&1 ||
    die "Kullanıcı bulunamadı: $ADMIN_USER (ADMIN_USER=... ile belirt)"
  # shellcheck source=/dev/null
  . /etc/os-release
  if [[ "${ID:-}" != ubuntu || "${VERSION_ID:-}" != 26.04 ]]; then
    warn "Betik Ubuntu 26.04 için hazırlandı; bu sistem: ${PRETTY_NAME:-bilinmiyor}"
  fi
  if [[ "$(uname -m)" != aarch64 ]]; then
    warn "Betik arm64 için hazırlandı; bu sistem: $(uname -m)"
  fi
}

# ---- 1. Sistem ------------------------------------------------------------------
phase_system() {
  step "Sistem güncellemesi, UTC saat dilimi ve temel paketler"
  wait_apt
  apt-get -q -o DPkg::Lock::Timeout=600 update
  "${APT[@]}" full-upgrade
  "${APT[@]}" install ca-certificates curl gnupg git jq htop ncdu unzip tmux openssl \
    psmisc iptables fail2ban python3-systemd unattended-upgrades
  "${APT[@]}" autoremove --purge
  timedatectl set-timezone Etc/UTC
  if [[ -n "$SERVER_HOSTNAME" ]]; then
    hostnamectl set-hostname "$SERVER_HOSTNAME"
    # cloud-init açılışta adı geri değiştirmesin
    if [[ -d /etc/cloud/cloud.cfg.d ]]; then
      echo 'preserve_hostname: true' >/etc/cloud/cloud.cfg.d/99-keep-hostname.cfg
    fi
  fi
  ok "Saat dilimi: $(timedatectl show -p Timezone --value)"
}

# ---- 2. Otomatik güvenlik güncellemeleri ---------------------------------------
phase_autoupdate() {
  step "Otomatik güvenlik güncellemeleri"
  cat >/etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
  cat >/etc/apt/apt.conf.d/52unattended-upgrades-local <<EOF
Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-Time "${AUTO_REBOOT_TIME}";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
EOF
  systemctl enable --now unattended-upgrades >/dev/null 2>&1 || true
  ok "Gerekirse her gece ${AUTO_REBOOT_TIME} (UTC) yeniden başlatılır"
}

# ---- 3. SSH ---------------------------------------------------------------------
phase_ssh() {
  step "SSH sertleştirme"
  local home keys conf=/etc/ssh/sshd_config.d/00-hardening.conf
  home=$(getent passwd "$ADMIN_USER" | cut -d: -f6)
  keys="$home/.ssh/authorized_keys"
  if ! grep -qE '(ssh-(rsa|ed25519|dss)|ecdsa-sha2|sk-(ssh|ecdsa))' "$keys" 2>/dev/null; then
    warn "$keys içinde SSH anahtarı yok; kilitlenmemek için bu adım atlandı"
    return 0
  fi
  cat >"$conf" <<EOF
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
MaxAuthTries 3
LoginGraceTime 30
X11Forwarding no
AllowAgentForwarding no
AllowTcpForwarding local
ClientAliveInterval 300
ClientAliveCountMax 2
AllowUsers ${SSH_ALLOW_USERS}
EOF
  if ! sshd -t; then
    rm -f "$conf"
    die "sshd yapılandırması geçersiz; değişiklik geri alındı"
  fi
  systemctl reload ssh 2>/dev/null || systemctl restart ssh
  ok "Yalnızca anahtarla giriş; izinli kullanıcılar: ${SSH_ALLOW_USERS}"
}

# ---- 4. fail2ban ----------------------------------------------------------------
phase_fail2ban() {
  step "fail2ban"
  cat >/etc/fail2ban/jail.local <<'EOF'
[DEFAULT]
bantime  = 1h
findtime = 10m
maxretry = 5
backend  = systemd

[sshd]
enabled = true
EOF
  systemctl enable fail2ban >/dev/null 2>&1 || true
  if systemctl restart fail2ban; then
    ok "SSH için 1 saatlik yasaklama etkin"
  else
    warn "fail2ban başlatılamadı ('journalctl -u fail2ban' ile bak); kuruluma devam ediliyor"
  fi
}

# ---- 5. Host güvenlik duvarı (OCI iptables) -------------------------------------
phase_firewall() {
  step "Host güvenlik duvarı (iptables): 80/443"
  local rules=/etc/iptables/rules.v4 tmp
  if [[ ! -f "$rules" ]]; then
    warn "$rules yok (OCI dışı imaj?); bu adım atlandı"
    return 0
  fi
  if grep -qE -- '^-A INPUT .*--dport 443 .*-j ACCEPT' "$rules"; then
    ok "80/443 kuralları zaten var"
    return 0
  fi
  tmp=$(mktemp)
  awk '
    { print }
    !done && /^-A INPUT / && /--dport 22 / && /-j ACCEPT/ {
      print "-A INPUT -p tcp -m state --state NEW -m tcp --dport 80 -j ACCEPT"
      print "-A INPUT -p tcp -m state --state NEW -m tcp --dport 443 -j ACCEPT"
      done = 1
    }' "$rules" >"$tmp"
  if ! grep -q -- '--dport 443' "$tmp"; then
    rm -f "$tmp"
    warn "$rules içinde SSH kuralı bulunamadı; 80/443'ü elle ekle (README → Sorun giderme)"
    return 0
  fi
  if ! iptables-restore --test <"$tmp"; then
    rm -f "$tmp"
    die "Yeni iptables kuralları geçersiz; hiçbir şey değiştirilmedi"
  fi
  [[ -f "$rules.orig" ]] || cp -p "$rules" "$rules.orig"
  cat "$tmp" >"$rules"
  rm -f "$tmp"
  iptables-restore <"$rules"
  # iptables-restore Docker'ın kurallarını siler; Docker yeniden yazsın
  if systemctl is-active --quiet docker; then systemctl restart docker; fi
  ok "80 ve 443 açıldı (eski kurallar: $rules.orig)"
}

# ---- 6. Swap ----------------------------------------------------------------------
phase_swap() {
  step "Swap (${SWAP_SIZE_GB} GB)"
  if [[ -n "$(swapon --show --noheadings)" ]]; then
    ok "Swap zaten açık"
    return 0
  fi
  if [[ ! -f /swapfile ]]; then
    fallocate -l "${SWAP_SIZE_GB}G" /swapfile 2>/dev/null ||
      dd if=/dev/zero of=/swapfile bs=1M count=$((SWAP_SIZE_GB * 1024)) status=none
    chmod 600 /swapfile
    mkswap /swapfile >/dev/null
  fi
  swapon /swapfile
  grep -q '^/swapfile ' /etc/fstab || echo '/swapfile none swap sw 0 0' >>/etc/fstab
  ok "Swap etkin"
}

# ---- 7. Kernel ayarları -----------------------------------------------------------
phase_sysctl() {
  step "Kernel ayarları (BBR, bellek, ağ güvenliği)"
  cat >/etc/sysctl.d/99-server.conf <<'EOF'
# Ağ: BBR tıkanıklık kontrolü
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# Bellek (Valkey arka plan kaydı için overcommit)
vm.swappiness = 10
vm.overcommit_memory = 1

# Dosya izleme limitleri
fs.inotify.max_user_watches = 524288
fs.inotify.max_user_instances = 1024

# Host ağ güvenliği
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
kernel.kptr_restrict = 2
kernel.dmesg_restrict = 1
EOF
  echo tcp_bbr >/etc/modules-load.d/bbr.conf
  modprobe tcp_bbr || warn "tcp_bbr modülü yüklenemedi"
  sysctl --system >/dev/null || warn "Bazı sysctl ayarları uygulanamadı ('sysctl --system' ile bak)"
  local thp=/sys/kernel/mm/transparent_hugepage/enabled
  if grep -q '\[always\]' "$thp" 2>/dev/null; then
    echo "w $thp - - - - madvise" >/etc/tmpfiles.d/thp-madvise.conf
    echo madvise >"$thp"
    ok "Transparent Huge Pages: madvise"
  fi
  ok "TCP tıkanıklık kontrolü: $(sysctl -n net.ipv4.tcp_congestion_control)"
}

# ---- 8. Veri diski (isteğe bağlı) -------------------------------------------------
phase_data_disk() {
  step "Veri diski"
  if mountpoint -q /srv; then
    ok "/srv zaten ayrı bir diske bağlı"
    return 0
  fi
  if [[ -z "$DATA_DEVICE" ]]; then
    ok "DATA_DEVICE verilmedi; veriler boot diskinde (/srv) tutulacak"
    return 0
  fi
  [[ -b "$DATA_DEVICE" ]] || die "$DATA_DEVICE bir disk değil ('lsblk' ile kontrol et)"
  if [[ -n "$(ls -A /srv 2>/dev/null)" ]]; then
    die "/srv boş değil; veri diskini bağlamadan önce içeriğini başka yere taşı"
  fi
  if ! blkid "$DATA_DEVICE" >/dev/null 2>&1; then
    [[ "$FORMAT_DATA_DEVICE" == yes ]] ||
      die "$DATA_DEVICE boş. Biçimlendirmek için FORMAT_DATA_DEVICE=yes ekle (diskteki her şey silinir)"
    mkfs.ext4 -q -L data "$DATA_DEVICE"
  fi
  local uuid fstype
  uuid=$(blkid -s UUID -o value "$DATA_DEVICE" || true)
  fstype=$(blkid -s TYPE -o value "$DATA_DEVICE" || true)
  [[ -n "$uuid" && -n "$fstype" ]] ||
    die "$DATA_DEVICE üzerinde dosya sistemi yok (bölümlenmişse bölümü ver, ör. ${DATA_DEVICE}1)"
  mkdir -p /srv
  if ! grep -q "UUID=$uuid" /etc/fstab; then
    echo "UUID=$uuid /srv $fstype defaults,noatime,nofail 0 2" >>/etc/fstab
  fi
  systemctl daemon-reload
  mount /srv
  ok "$DATA_DEVICE → /srv bağlandı"
}

# ---- 9. Docker ------------------------------------------------------------------
phase_docker() {
  step "Docker Engine (resmi depo)"
  local changed=0 dropin=/etc/systemd/system/docker.service.d/10-srv.conf
  if ! dpkg -s docker-ce >/dev/null 2>&1; then
    local -a conflicts=()
    # shellcheck disable=SC2016
    mapfile -t conflicts < <(dpkg-query -W -f='${db:Status-Abbrev} ${Package}\n' \
      docker.io docker-compose docker-compose-v2 docker-doc docker-buildx podman-docker \
      containerd runc 2>/dev/null | awk '$1 ~ /^ii/ {print $2}' || true)
    if ((${#conflicts[@]})); then "${APT[@]}" remove "${conflicts[@]}"; fi
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc
    # shellcheck source=/dev/null
    . /etc/os-release
    cat >/etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: ${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
EOF
    wait_apt
    apt-get -q -o DPkg::Lock::Timeout=600 update
    "${APT[@]}" install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    changed=1
  fi
  if [[ ! -f /etc/docker/daemon.json ]]; then
    mkdir -p /etc/docker
    cat >/etc/docker/daemon.json <<'EOF'
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "5" },
  "live-restore": true,
  "userland-proxy": false
}
EOF
    changed=1
  fi
  if [[ ! -f "$dropin" ]]; then
    mkdir -p "$(dirname "$dropin")"
    # Veri diski bağlanmadan Docker başlamasın
    printf '[Unit]\nRequiresMountsFor=/srv\n' >"$dropin"
    systemctl daemon-reload
    changed=1
  fi
  systemctl enable docker >/dev/null 2>&1
  if ((changed)); then systemctl restart docker; fi
  usermod -aG docker "$ADMIN_USER"
  ok "Docker $(docker version --format '{{.Server.Version}}') çalışıyor"
}

# ---- 10. Stack dosyaları --------------------------------------------------------------
write_env() {
  local env="$STACK_DIR/.env"
  if [[ -f "$env" ]]; then
    ok "$env zaten var, parolalar korunuyor"
    return 0
  fi
  (
    umask 077
    cat >"$env" <<EOF
POSTGRES_PASSWORD=$(openssl rand -hex 32)
VALKEY_PASSWORD=$(openssl rand -hex 32)
SILO_ROOT_USER=siloadmin
SILO_ROOT_PASSWORD=$(openssl rand -hex 24)
EOF
  )
  ok "$env yazıldı (parolalar üretildi)"
}

write_compose() {
  put "$STACK_DIR/compose.yaml" <<'EOF'
name: app

x-common: &common
  restart: unless-stopped
  security_opt: ["no-new-privileges:true"]
  logging:
    driver: json-file
    options: { max-size: "10m", max-file: "5" }

x-api: &api
  <<: *common
  cap_drop: [ALL]
  networks: [edge, backend]
  depends_on:
    postgres: { condition: service_healthy }
    valkey: { condition: service_healthy }

networks:
  edge: {}
  backend:
    internal: true          # internete çıkış yok, dışarıdan erişim yok

services:
  nginx:
    <<: *common
    image: nginx:1.30-alpine
    ports: ["80:80", "443:443"]
    volumes:
      - ./nginx/nginx.conf:/etc/nginx/nginx.conf:ro
      - ./nginx/conf.d:/etc/nginx/conf.d:ro
      - ./nginx/snippets:/etc/nginx/snippets:ro
      - ./certbot/conf:/etc/letsencrypt:ro
      - ./certbot/www:/var/www/certbot:ro
    networks: [edge]
    deploy: { resources: { limits: { cpus: "1.0", memory: 256M } } }

  certbot:
    image: certbot/certbot:latest
    profiles: ["tools"]     # yalnızca elle veya zamanlayıcıyla çalışır
    volumes:
      - ./certbot/conf:/etc/letsencrypt
      - ./certbot/www:/var/www/certbot

  deno-api:
    <<: *api
    build: ./apps/deno-api
    image: local/deno-api
    env_file: ./apps/deno-api/.env
    deploy: { resources: { limits: { cpus: "1.0", memory: 768M } } }

  dotnet-api:
    <<: *api
    build: ./apps/dotnet-api
    image: local/dotnet-api
    env_file: ./apps/dotnet-api/.env
    environment:
      ASPNETCORE_FORWARDEDHEADERS_ENABLED: "true"
    deploy: { resources: { limits: { cpus: "1.0", memory: 1G } } }

  go-api:
    <<: *api
    build: ./apps/go-api
    image: local/go-api
    env_file: ./apps/go-api/.env
    environment:
      GOMEMLIMIT: 450MiB      # 512M limitin altında tut
    deploy: { resources: { limits: { cpus: "1.0", memory: 512M } } }

  postgres:
    <<: *common
    image: postgres:18
    shm_size: 512m
    environment:
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
    volumes:
      - /srv/data/postgres:/var/lib/postgresql     # 18+ için doğru yol
    command: >
      postgres
      -c shared_buffers=1GB
      -c effective_cache_size=3GB
      -c work_mem=16MB
      -c maintenance_work_mem=256MB
      -c max_connections=100
      -c random_page_cost=1.1
      -c log_min_duration_statement=500ms
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -h 127.0.0.1 -U postgres"]
      interval: 10s
      timeout: 5s
      retries: 5
    networks: [backend]
    deploy: { resources: { limits: { cpus: "1.5", memory: 4G } } }

  valkey:
    <<: *common
    image: valkey/valkey:9.1-alpine
    command: ["valkey-server", "/usr/local/etc/valkey/valkey.conf", "--requirepass", "${VALKEY_PASSWORD}"]
    environment:
      VALKEY_PASSWORD: ${VALKEY_PASSWORD}
    volumes:
      - ./valkey/valkey.conf:/usr/local/etc/valkey/valkey.conf:ro
      - /srv/data/valkey:/data
    healthcheck:
      test: ["CMD-SHELL", "valkey-cli -a \"$$VALKEY_PASSWORD\" --no-auth-warning ping | grep -q PONG"]
      interval: 10s
      timeout: 5s
      retries: 5
    networks: [backend]
    deploy: { resources: { limits: { cpus: "0.5", memory: 768M } } }

  silo:
    <<: *common
    image: pgsty/silo:RELEASE.2026-10-26T00-00-00Z
    command: ["server", "/data", "--console-address", ":9001"]
    environment:
      MINIO_ROOT_USER: ${SILO_ROOT_USER}
      MINIO_ROOT_PASSWORD: ${SILO_ROOT_PASSWORD}
    volumes:
      - /srv/data/silo:/data
    ports: ["127.0.0.1:9001:9001"]   # konsol: yalnızca SSH tüneliyle
    healthcheck:
      test: ["CMD", "silo", "healthcheck", "ready"]
      interval: 30s
      timeout: 10s
      start_period: 2m
      retries: 3
    networks: [edge, backend]
    deploy: { resources: { limits: { cpus: "1.0", memory: 1G } } }
EOF
}

write_nginx() {
  put "$STACK_DIR/nginx/nginx.conf" <<'EOF'
user nginx;
worker_processes auto;
worker_rlimit_nofile 65535;
error_log /var/log/nginx/error.log warn;
pid /run/nginx.pid;

events { worker_connections 4096; }

http {
    include       /etc/nginx/mime.types;
    default_type  application/octet-stream;
    server_tokens off;
    sendfile on;
    tcp_nopush on;
    keepalive_timeout 65;
    client_max_body_size 20m;

    log_format main '$remote_addr [$time_local] "$request" $status $body_bytes_sent '
                    '"$http_user_agent" rt=$request_time urt=$upstream_response_time';
    access_log /var/log/nginx/access.log main;

    gzip on;
    gzip_comp_level 5;
    gzip_min_length 1024;
    gzip_proxied any;
    gzip_vary on;
    gzip_types application/json application/javascript text/css text/plain application/xml image/svg+xml;

    # TLS (ssl_stapling ekleme: Let's Encrypt sertifikalarında OCSP adresi yok)
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305;
    ssl_prefer_server_ciphers off;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 1d;
    ssl_session_tickets off;

    # Docker'ın iç DNS'i
    resolver 127.0.0.11 valid=10s ipv6=off;

    limit_req_zone $binary_remote_addr zone=api:10m rate=20r/s;

    map $http_upgrade $connection_upgrade {
        default upgrade;
        ''      '';
    }

    include /etc/nginx/conf.d/*.conf;
}
EOF

  put "$STACK_DIR/nginx/snippets/proxy.conf" <<'EOF'
proxy_http_version 1.1;
proxy_set_header Host              $host;
proxy_set_header X-Real-IP         $remote_addr;
proxy_set_header X-Forwarded-For   $remote_addr;
proxy_set_header X-Forwarded-Proto $scheme;
proxy_set_header X-Forwarded-Host  $host;
proxy_set_header Upgrade           $http_upgrade;
proxy_set_header Connection        $connection_upgrade;
proxy_connect_timeout 5s;
proxy_read_timeout    60s;
proxy_send_timeout    60s;
EOF

  put "$STACK_DIR/nginx/snippets/headers.conf" <<'EOF'
add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
add_header X-Content-Type-Options "nosniff" always;
add_header X-Frame-Options "DENY" always;
add_header Referrer-Policy "strict-origin-when-cross-origin" always;
EOF

  put "$STACK_DIR/nginx/conf.d/00-http.conf" <<'EOF'
server {
    listen 80 default_server;
    server_name _;

    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }
    location / {
        return 301 https://$host$request_uri;
    }
}
EOF

  # resolve: API konteynerleri henüz yokken de nginx başlar, sonra kendini günceller
  put "$STACK_DIR/nginx/conf.d/10-upstreams.conf" <<'EOF'
upstream deno_api   { zone deno_api 64k;   server deno-api:8000 resolve;   keepalive 16; }
upstream dotnet_api { zone dotnet_api 64k; server dotnet-api:8080 resolve; keepalive 16; }
upstream go_api     { zone go_api 64k;     server go-api:8081 resolve;     keepalive 16; }
upstream s3_api     { zone s3_api 64k;     server silo:9000 resolve;       keepalive 16; }
EOF
}

write_sites_conf() {
  render <<'EOF' | put "$STACK_DIR/nginx/conf.d/20-sites.conf"
# Tanımsız host adlarına (ör. IP ile gelen tarayıcılar) sertifika gösterme
server {
    listen 443 ssl default_server;
    ssl_reject_handshake on;
}

server {
    listen 443 ssl;
    http2 on;
    server_name deno.__DOMAIN__;
    ssl_certificate     /etc/letsencrypt/live/main/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/main/privkey.pem;
    include /etc/nginx/snippets/headers.conf;
    location / {
        limit_req zone=api burst=40 nodelay;
        proxy_pass http://deno_api;
        include /etc/nginx/snippets/proxy.conf;
    }
}

server {
    listen 443 ssl;
    http2 on;
    server_name dotnet.__DOMAIN__;
    ssl_certificate     /etc/letsencrypt/live/main/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/main/privkey.pem;
    include /etc/nginx/snippets/headers.conf;
    location / {
        limit_req zone=api burst=40 nodelay;
        proxy_pass http://dotnet_api;
        include /etc/nginx/snippets/proxy.conf;
    }
}

server {
    listen 443 ssl;
    http2 on;
    server_name go.__DOMAIN__;
    ssl_certificate     /etc/letsencrypt/live/main/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/main/privkey.pem;
    include /etc/nginx/snippets/headers.conf;
    location / {
        limit_req zone=api burst=40 nodelay;
        proxy_pass http://go_api;
        include /etc/nginx/snippets/proxy.conf;
    }
}

server {
    listen 443 ssl;
    http2 on;
    server_name s3.__DOMAIN__;
    ssl_certificate     /etc/letsencrypt/live/main/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/main/privkey.pem;
    client_max_body_size 0;          # büyük dosya yüklemeleri
    proxy_buffering off;
    proxy_request_buffering off;
    location / {
        proxy_pass http://s3_api;
        include /etc/nginx/snippets/proxy.conf;
    }
}
EOF
}

write_valkey() {
  put "$STACK_DIR/valkey/valkey.conf" <<'EOF'
bind 0.0.0.0
port 6379
protected-mode yes
maxmemory 512mb
maxmemory-policy allkeys-lru
appendonly yes
appendfsync everysec
save 900 1 300 100
EOF
}

write_apps() {
  put "$STACK_DIR/apps/deno-api/Dockerfile" <<'EOF'
FROM denoland/deno:2.9.7
WORKDIR /app
RUN chown deno:deno /app
USER deno
COPY --chown=deno:deno . .
RUN deno install --entrypoint main.ts
EXPOSE 8000
CMD ["run", "--allow-net", "--allow-env", "--allow-read=/app", "main.ts"]
EOF
  printf '.env\n.git\nnode_modules/\n' | put "$STACK_DIR/apps/deno-api/.dockerignore"

  put "$STACK_DIR/apps/dotnet-api/Dockerfile" <<'EOF'
FROM mcr.microsoft.com/dotnet/sdk:10.0 AS build
WORKDIR /src
COPY *.csproj ./
RUN dotnet restore
COPY . .
RUN dotnet publish -c Release -o /app --no-restore

FROM mcr.microsoft.com/dotnet/aspnet:10.0-noble-chiseled-extra
WORKDIR /app
COPY --from=build /app .
EXPOSE 8080
# Api.dll yerine kendi proje adını yaz
ENTRYPOINT ["dotnet", "Api.dll"]
EOF
  printf '.env\n.git\nbin/\nobj/\n' | put "$STACK_DIR/apps/dotnet-api/.dockerignore"

  put "$STACK_DIR/apps/go-api/Dockerfile" <<'EOF'
FROM golang:1.27-alpine AS build
WORKDIR /src
COPY go.* ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/api .

FROM gcr.io/distroless/static-debian13:nonroot
COPY --from=build /out/api /api
EXPOSE 8081
ENTRYPOINT ["/api"]
EOF
  printf '.env\n.git\n' | put "$STACK_DIR/apps/go-api/.dockerignore"

  local api
  for api in "${APIS[@]}"; do
    touch "$STACK_DIR/apps/${api}-api/.env"
    chmod 600 "$STACK_DIR/apps/${api}-api/.env"
  done
}

# Klasörde kod yoksa /health uç noktalı küçük örnek uygulamalar yazar
write_samples() {
  [[ "$SAMPLE_APPS" == 1 ]] || return 0
  local d="$STACK_DIR/apps"

  if ! has_code go; then
    put "$d/go-api/go.mod" <<'EOF'
module example.com/go-api

go 1.27
EOF
    put "$d/go-api/main.go" <<'EOF'
// SAMPLE-APP: setup.sh'in oluşturduğu örnek uygulama. Kendi kodunla değiştir.
package main

import (
	"context"
	"encoding/json"
	"errors"
	"log"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"
)

func main() {
	addr := ":" + getenv("PORT", "8081")

	mux := http.NewServeMux()
	mux.HandleFunc("GET /health", func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(map[string]string{
			"status":  "ok",
			"service": "go-api",
			"time":    time.Now().UTC().Format(time.RFC3339),
		})
	})
	mux.HandleFunc("GET /{$}", func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte("go-api çalışıyor\n"))
	})

	srv := &http.Server{Addr: addr, Handler: mux, ReadHeaderTimeout: 10 * time.Second}

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	go func() {
		log.Printf("go-api %s adresinde dinliyor", addr)
		if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			log.Fatal(err)
		}
	}()

	<-ctx.Done()
	shutdownCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	if err := srv.Shutdown(shutdownCtx); err != nil {
		log.Printf("kapatma hatası: %v", err)
	}
}

func getenv(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}
EOF
  fi

  if ! has_code deno; then
    put "$d/deno-api/main.ts" <<'EOF'
// SAMPLE-APP: setup.sh'in oluşturduğu örnek uygulama. Kendi kodunla değiştir.
const port = Number(Deno.env.get("PORT") ?? "8000");

Deno.serve({ hostname: "0.0.0.0", port }, (req) => {
  const { pathname } = new URL(req.url);
  if (pathname === "/health") {
    return Response.json({
      status: "ok",
      service: "deno-api",
      time: new Date().toISOString(),
    });
  }
  return new Response("deno-api çalışıyor\n");
});
EOF
  fi

  if ! has_code dotnet; then
    put "$d/dotnet-api/Api.csproj" <<'EOF'
<Project Sdk="Microsoft.NET.Sdk.Web">
  <!-- SAMPLE-APP: setup.sh'in oluşturduğu örnek proje. Kendi projenle değiştir. -->
  <PropertyGroup>
    <TargetFramework>net10.0</TargetFramework>
    <Nullable>enable</Nullable>
    <ImplicitUsings>enable</ImplicitUsings>
  </PropertyGroup>
</Project>
EOF
    put "$d/dotnet-api/Program.cs" <<'EOF'
// SAMPLE-APP: setup.sh'in oluşturduğu örnek uygulama. Kendi kodunla değiştir.
var builder = WebApplication.CreateBuilder(args);
var app = builder.Build();

app.MapGet("/health", () => Results.Ok(new
{
    status = "ok",
    service = "dotnet-api",
    time = DateTime.UtcNow,
}));
app.MapGet("/", () => "dotnet-api çalışıyor");

app.Run();
EOF
  fi
}

write_backup_script() {
  render <<'EOF' | put "$STACK_DIR/backup-db.sh" 0700
#!/usr/bin/env bash
set -euo pipefail
cd __STACK_DIR__
TS=$(date +%F_%H%M)
DEST=/srv/backups/postgres
mkdir -p "$DEST"
for DB in deno_db dotnet_db go_db; do
  docker compose exec -T postgres pg_dump -U postgres -Fc "$DB" > "$DEST/${DB}_${TS}.dump"
done
find "$DEST" -name '*.dump' -mtime +14 -delete
EOF
}

# Stack klasörünün bütün dosyalarını üretir (tests/render-test.sh de bunu kullanır)
write_stack_files() {
  mkdir -p "$STACK_DIR"/{nginx/conf.d,nginx/snippets,certbot/conf,certbot/www,valkey,apps,.state}
  chmod 700 "$STACK_DIR/.state"
  write_env
  write_compose
  write_nginx
  write_valkey
  write_apps
  write_samples
  write_backup_script
}

phase_stack_files() {
  step "Stack dosyaları ve parolalar ($STACK_DIR)"
  mkdir -p "$DATA_DIR"/{postgres,valkey,silo} "$BACKUP_DIR/postgres"
  write_stack_files
  # Düzenleyeceğin dosyalar senin; sertifikalar ve .state root'ta kalır
  chown "$ADMIN_USER:$ADMIN_USER" "$STACK_DIR" "$STACK_DIR/compose.yaml" "$STACK_DIR/.env" \
    "$STACK_DIR/backup-db.sh"
  chown -R "$ADMIN_USER:$ADMIN_USER" "$STACK_DIR/nginx" "$STACK_DIR/valkey" "$STACK_DIR/apps" \
    "$BACKUP_DIR"
}

# ---- 11. Altyapı servisleri -------------------------------------------------------
phase_start() {
  step "nginx, PostgreSQL, Valkey ve SILO başlatılıyor"
  dc up -d nginx postgres valkey silo
  wait_for "PostgreSQL" 180 dc exec -T postgres pg_isready -h 127.0.0.1 -U postgres ||
    die "PostgreSQL başlamadı: cd $STACK_DIR && docker compose logs postgres"
  # shellcheck disable=SC2016
  wait_for "Valkey" 90 dc exec -T valkey sh -c \
    'valkey-cli -a "$VALKEY_PASSWORD" --no-auth-warning ping | grep -q PONG' ||
    die "Valkey başlamadı: cd $STACK_DIR && docker compose logs valkey"
  wait_for "SILO" 180 dc exec -T silo silo healthcheck ready ||
    die "SILO başlamadı: cd $STACK_DIR && docker compose logs silo"
  wait_for "nginx" 60 dc exec -T nginx nginx -t ||
    die "nginx başlamadı: cd $STACK_DIR && docker compose logs nginx"
}

# ---- 12. Veritabanları, SILO ve API .env dosyaları -----------------------------------
load_secrets() {
  local f="$STACK_DIR/.state/app-secrets.env" api
  if [[ ! -f "$f" ]]; then
    (
      umask 077
      {
        for api in "${APIS[@]}"; do
          printf '%s_DB_PASSWORD=%s\n' "${api^^}" "$(openssl rand -hex 24)"
        done
        printf 'S3_APP_ACCESS_KEY=app-user\nS3_APP_SECRET_KEY=%s\n' "$(openssl rand -hex 20)"
      } >"$f"
    )
  fi
  set -a
  # shellcheck source=/dev/null
  . "$STACK_DIR/.env"
  # shellcheck source=/dev/null
  . "$f"
  set +a
}

phase_databases() {
  step "Veritabanları, SILO bucket'ı ve API .env dosyaları"
  load_secrets
  local api pw sql=""
  for api in "${APIS[@]}"; do
    pw=$(secret_for "$api")
    sql+="SELECT format('CREATE ROLE %I LOGIN', '${api}_app') WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '${api}_app')\\gexec
ALTER ROLE ${api}_app PASSWORD '${pw}';
SELECT format('CREATE DATABASE %I OWNER %I', '${api}_db', '${api}_app') WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = '${api}_db')\\gexec
REVOKE CONNECT ON DATABASE ${api}_db FROM PUBLIC;
"
  done
  printf '%s' "$sql" | dc exec -T postgres psql -U postgres -v ON_ERROR_STOP=1 -q >/dev/null
  ok "deno_db, dotnet_db, go_db ve kullanıcıları hazır"

  # shellcheck disable=SC2016
  dc exec -T silo sh -c \
    'mcli alias set local http://localhost:9000 "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" >/dev/null'
  dc exec -T silo mcli mb --ignore-existing local/uploads >/dev/null
  dc exec -T silo mcli admin user add local "$S3_APP_ACCESS_KEY" "$S3_APP_SECRET_KEY" >/dev/null
  # Politika zaten bağlıysa hata döner; sorun değil
  dc exec -T silo mcli admin policy attach local readwrite --user "$S3_APP_ACCESS_KEY" \
    >/dev/null 2>&1 || true
  ok "SILO: 'uploads' bucket'ı ve '$S3_APP_ACCESS_KEY' kullanıcısı hazır"

  local env extra
  for api in deno go; do
    env="$STACK_DIR/apps/${api}-api/.env"
    if grep -q '^DATABASE_URL=' "$env" 2>/dev/null; then continue; fi
    extra=""
    if [[ $api == go ]]; then extra="?pool_max_conns=25"; fi
    cat >>"$env" <<EOF
DATABASE_URL=postgres://${api}_app:$(secret_for "$api")@postgres:5432/${api}_db${extra}
VALKEY_URL=redis://:${VALKEY_PASSWORD}@valkey:6379/0
S3_ENDPOINT=http://silo:9000
S3_PUBLIC_ENDPOINT=https://s3.${DOMAIN}
S3_BUCKET=uploads
S3_ACCESS_KEY=${S3_APP_ACCESS_KEY}
S3_SECRET_KEY=${S3_APP_SECRET_KEY}
EOF
  done
  env="$STACK_DIR/apps/dotnet-api/.env"
  if ! grep -q '^ConnectionStrings__Default=' "$env" 2>/dev/null; then
    cat >>"$env" <<EOF
ConnectionStrings__Default="Host=postgres;Database=dotnet_db;Username=dotnet_app;Password=$(secret_for dotnet);Maximum Pool Size=25"
ConnectionStrings__Valkey="valkey:6379,password=${VALKEY_PASSWORD}"
S3__Endpoint=http://silo:9000
S3__PublicEndpoint=https://s3.${DOMAIN}
S3__Bucket=uploads
S3__AccessKey=${S3_APP_ACCESS_KEY}
S3__SecretKey=${S3_APP_SECRET_KEY}
EOF
  fi
  chmod 600 "$STACK_DIR"/apps/*/.env
  chown "$ADMIN_USER:$ADMIN_USER" "$STACK_DIR"/apps/*/.env
  ok "API .env dosyaları hazır"
}

# ---- 13. SSL ----------------------------------------------------------------------------
# Alt alan adları bu sunucunun IP'sini gösteriyor mu?
dns_points_here() {
  local ip h resolved rc=0
  resolvectl flush-caches >/dev/null 2>&1 || true
  ip=$(curl -fs4 --max-time 5 https://api.ipify.org || curl -fs4 --max-time 5 https://ifconfig.me || true)
  for h in "$@"; do
    resolved=$(getent ahostsv4 "$h" | awk 'NR == 1 {print $1}' || true)
    if [[ -z "$resolved" ]]; then
      warn "$h çözülemedi (A kaydı yok)"
      rc=1
    elif [[ -n "$ip" && "$resolved" != "$ip" ]]; then
      warn "$h → $resolved, bu sunucu: $ip (Cloudflare proxy açıksa SKIP_DNS_CHECK=1)"
      rc=1
    fi
  done
  return "$rc"
}

phase_certs() {
  step "SSL sertifikası (Let's Encrypt)"
  local -a hosts=() args=()
  local h sites="$STACK_DIR/nginx/conf.d/20-sites.conf"
  for h in "${SUBDOMAINS[@]}"; do hosts+=("$h.$DOMAIN"); done

  if [[ ! -f "$STACK_DIR/certbot/conf/live/main/fullchain.pem" ]]; then
    if [[ "$SKIP_CERT" == 1 ]]; then
      warn "SKIP_CERT=1: sertifika adımı atlandı"
      return 0
    fi
    if [[ "$SKIP_DNS_CHECK" != 1 ]] && ! dns_points_here "${hosts[@]}"; then
      warn "DNS kayıtları henüz bu sunucuyu göstermiyor; sertifika atlandı."
      warn "A kayıtlarını ekleyip betiği aynı komutla tekrar çalıştır."
      return 0
    fi
    args=(certonly --webroot -w /var/www/certbot --cert-name main
          --non-interactive --agree-tos --no-eff-email)
    for h in "${hosts[@]}"; do args+=(-d "$h"); done
    if [[ -n "$EMAIL" ]]; then args+=(-m "$EMAIL"); else args+=(--register-unsafely-without-email); fi

    # Önce staging'de dene: hata olursa gerçek limitler harcanmaz
    if ! dc run --rm -T certbot "${args[@]}" --dry-run; then
      warn "Deneme başarısız. OCI Security List'te 80 ve 443 açık mı, DNS doğru mu?"
      warn "Sorunu giderip betiği aynı komutla tekrar çalıştır."
      return 0
    fi
    if ! dc run --rm -T certbot "${args[@]}"; then
      warn "Sertifika alınamadı; yukarıdaki çıktıya bakıp betiği tekrar çalıştır."
      return 0
    fi
  fi

  write_sites_conf
  chown "$ADMIN_USER:$ADMIN_USER" "$sites"
  if ! dc exec -T nginx nginx -t; then
    mv "$sites" "$sites.bad"
    die "nginx yapılandırması geçersiz; 20-sites.conf, 20-sites.conf.bad olarak kenara alındı"
  fi
  dc exec -T nginx nginx -s reload
  ok "HTTPS etkin: ${hosts[*]}"
}

# ---- 14. API'ler ----------------------------------------------------------------------
phase_apps() {
  step "API'ler derleniyor ve başlatılıyor (Deno, .NET, Go)"
  local api svc
  for api in "${APIS[@]}"; do
    svc="${api}-api"
    if ! has_code "$api"; then
      warn "$svc: apps/$svc içinde kod yok, atlandı"
      continue
    fi
    if ! dc up -d --build "$svc"; then
      warn "$svc derlenemedi veya başlatılamadı; yukarıdaki çıktıya bak"
      continue
    fi
    if grep -qsF 'SAMPLE-APP' "$STACK_DIR/apps/$svc/${API_MAIN[$api]}"; then
      wait_for "$svc (/health)" 120 \
        dc exec -T nginx wget -qO- "http://$svc:${API_PORT[$api]}/health" || true
    else
      sleep 5
      if is_running "$svc"; then
        ok "$svc çalışıyor"
      else
        warn "$svc çalışmıyor: cd $STACK_DIR && docker compose logs $svc"
      fi
    fi
  done
}

# ---- 15. Zamanlayıcılar -------------------------------------------------------------
phase_timers() {
  step "Zamanlayıcılar: sertifika yenileme ve gecelik yedek (UTC)"
  put /etc/systemd/system/certbot-renew.service <<EOF
[Unit]
Description=Certbot yenileme (Docker)
Requires=docker.service
After=docker.service

[Service]
Type=oneshot
WorkingDirectory=${STACK_DIR}
ExecStart=/usr/bin/docker compose run --rm -T certbot renew --quiet
ExecStartPost=/usr/bin/docker compose exec -T nginx nginx -s reload
EOF
  put /etc/systemd/system/certbot-renew.timer <<'EOF'
[Unit]
Description=Certbot yenileme, günde iki kez

[Timer]
OnCalendar=*-*-* 03,15:17:00
RandomizedDelaySec=30m
Persistent=true

[Install]
WantedBy=timers.target
EOF
  put /etc/systemd/system/db-backup.service <<EOF
[Unit]
Description=PostgreSQL yedegi
Requires=docker.service
After=docker.service

[Service]
Type=oneshot
ExecStart=${STACK_DIR}/backup-db.sh
EOF
  put /etc/systemd/system/db-backup.timer <<'EOF'
[Unit]
Description=Gecelik PostgreSQL yedegi

[Timer]
OnCalendar=*-*-* 02:30:00
Persistent=true

[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload
  systemctl enable --now certbot-renew.timer db-backup.timer >/dev/null 2>&1
  ok "Sertifika yenileme 03:17 ve 15:17, yedek 02:30 (UTC)"
}

# ---- Özet -------------------------------------------------------------------------------
phase_finish() {
  local cert="YOK: DNS ve Security List'i kontrol edip betiği tekrar çalıştır"
  if [[ -f "$STACK_DIR/certbot/conf/live/main/fullchain.pem" ]]; then cert="var"; fi
  log "Kurulum tamamlandı ($((SECONDS / 60)) dk $((SECONDS % 60)) sn)"
  echo
  dc ps --format 'table {{.Service}}\t{{.Status}}' || true
  cat <<EOF

  Adresler     : https://deno.$DOMAIN  https://dotnet.$DOMAIN
                 https://go.$DOMAIN  https://s3.$DOMAIN
  Sertifika    : $cert
  Parolalar    : $STACK_DIR/.env ve $STACK_DIR/apps/*/.env
  Log          : $LOG_FILE
  Belgeler     : $REPO_URL

  Sıradaki adımlar:
   1. Test:  curl -s https://go.$DOMAIN/health
   2. Kendi kodunu apps/deno-api, apps/dotnet-api, apps/go-api klasörlerine koy
      (örnek dosyaları sil), sonra:  cd $STACK_DIR && docker compose up -d --build
   3. SILO konsolu için kendi bilgisayarında:
        ssh -L 9001:127.0.0.1:9001 $ADMIN_USER@SUNUCU_IP   →   http://localhost:9001
   4. docker komutlarını sudo'suz kullanmak için oturumu kapatıp yeniden aç.
EOF
  if [[ -f /var/run/reboot-required ]]; then
    warn "Çekirdek güncellendi: uygun bir anda 'sudo reboot' yap (servisler kendiliğinden açılır)."
  fi
}

main() {
  case "${1:-}" in
    -h | --help) usage; exit 0 ;;
    --version) echo "oci-arm-stack $SCRIPT_VERSION"; exit 0 ;;
  esac
  if (($# > 2)); then
    usage >&2
    die "En fazla iki argüman alır: ALAN_ADI [E-POSTA]"
  fi
  if (($# >= 1)); then DOMAIN="$1"; fi
  if (($# >= 2)); then EMAIL="$2"; fi

  preflight
  touch "$LOG_FILE"
  chmod 600 "$LOG_FILE"
  exec > >(tee -a "$LOG_FILE") 2>&1
  log "oci-arm-stack $SCRIPT_VERSION kurulumu başlıyor: $(date -u '+%F %T') UTC, alan adı: $DOMAIN"
  phase_system
  phase_autoupdate
  phase_ssh
  phase_fail2ban
  phase_firewall
  phase_swap
  phase_sysctl
  phase_data_disk
  phase_docker
  phase_stack_files
  phase_start
  phase_databases
  phase_certs
  phase_apps
  phase_timers
  phase_finish
}

# Doğrudan çalıştırılınca (curl | bash dahil) kurar; source edilince yalnızca fonksiyonları yükler
if [[ "${BASH_SOURCE[0]:-$0}" == "$0" ]]; then
  main "$@"
fi
