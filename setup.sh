#!/usr/bin/env bash
# 3AX-UI VPS bootstrap — Ubuntu 22.04 / 24.04
# Run on a NEW VPS from the hosting provider's rescue/web console.
set -Eeuo pipefail
umask 077

readonly SSH_PORT=1335
readonly PANEL_PORT=13350
# Do not publish a personal trusted address in a public GitHub repository.
TRUSTED_IP=''
readonly UPSTREAM_URL='https://raw.githubusercontent.com/coinman-dev/3ax-ui/main/install.sh'

fail() { printf '\n[ERROR] %s\n' "$*" >&2; exit 1; }
info() { printf '\n[INFO] %s\n' "$*"; }
warn() { printf '\n[WARN] %s\n' "$*" >&2; }
trap 'warn "Ошибка на строке $LINENO (код $?). Настройки не были автоматически откатаны. Используй веб-консоль и резервные копии."' ERR

[[ "$EUID" -eq 0 ]] || fail 'Запусти: sudo bash setup.sh'
[[ -t 0 ]] || fail 'Нужна интерактивная консоль: установщик 3AX-UI задаёт вопросы.'
[[ -r /etc/os-release ]] || fail 'Не удалось определить ОС.'
# shellcheck source=/dev/null
. /etc/os-release
[[ "${ID:-}" == ubuntu ]] || fail 'Поддерживается только Ubuntu.'
[[ "${VERSION_ID:-}" == '22.04' || "${VERSION_ID:-}" == '24.04' ]] || fail 'Нужна Ubuntu 22.04 или 24.04.'

if [[ -e /usr/bin/x-ui || -e /usr/local/x-ui/x-ui ]]; then
  fail '3AX-UI уже установлена. Скрипт предназначен для нового сервера и не переустанавливает панель.'
fi

BACKUP_DIR="/root/3ax-setup-backup-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BACKUP_DIR"
chmod 700 "$BACKUP_DIR"
info "ОС: Ubuntu ${VERSION_ID}; каталог копий: ${BACKUP_DIR}"
echo 'Внимание: скрипт изменит SSH, UFW, Fail2ban и DNS.'
echo 'Для безопасности старый SSH-порт будет сохранён до проверки входа на 1335.'
echo 'На нестандартных сетевых схемах изменение Netplan пропускается.'
if [[ -n "${SSH_CONNECTION:-}${SSH_TTY:-}" ]]; then
  warn 'Запуск через SSH: предпочтительнее веб-консоль хостинга; Netplan применяться НЕ будет.'
fi
read -r -p 'Это новый VPS и есть доступ к веб-консоли хостинга? Введи YES: ' CONFIRM
[[ "$CONFIRM" == 'YES' ]] || fail 'Отменено.'
read -r -p 'Доверенный IPv4 для Fail2ban ignoreip (можно пусто): ' TRUSTED_IP
if [[ -n "$TRUSTED_IP" ]]; then
  [[ "$TRUSTED_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || fail 'Некорректный формат IPv4.'
  IFS=. read -r a b c d <<< "$TRUSTED_IP"
  for octet in "$a" "$b" "$c" "$d"; do
    (( 10#$octet <= 255 )) || fail 'Некорректный IPv4.'
  done
fi

# 1 — Update and essential packages.
info '1/7 — обновление и пакеты'
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get upgrade -y
apt-get install -y ca-certificates curl openssh-server fail2ban python3-systemd ufw nano dkms iproute2
if [[ "$(uname -r)" == *-generic ]]; then
  apt-get install -y linux-generic linux-headers-generic
else
  warn "Текущее ядро $(uname -r) нестандартное. Пакет linux-generic принудительно не устанавливаем."
  apt-get install -y "linux-headers-$(uname -r)" || warn 'Заголовки текущего ядра не найдены; проверь поддержку DKMS.'
fi

# 2 — Open ports BEFORE restarting SSH or enabling UFW.
info '2/7 — правила UFW'
cp -a /etc/default/ufw "$BACKUP_DIR/ufw-default"
sed -i -E 's/^IPV6=.*/IPV6=yes/' /etc/default/ufw
# Keep existing SSH listeners reachable for safety, even on a nonstandard VPS.
mapfile -t OLD_SSH_PORTS < <(/usr/sbin/sshd -T | awk '$1 == "port" && $2 ~ /^[0-9]+$/ {print $2}' | sort -un)
(( ${#OLD_SSH_PORTS[@]} > 0 )) || OLD_SSH_PORTS=(22)
for port in "${OLD_SSH_PORTS[@]}"; do
  ufw allow "${port}/tcp"
done
ufw allow "${SSH_PORT}/tcp"
ufw allow "${PANEL_PORT}/tcp"
ufw allow 13133/tcp
ufw allow 13133/udp
ufw allow 20304/udp
ufw allow 13131/udp
ufw allow 80/tcp
# Port 443 is intentionally NOT opened.
ufw default deny incoming
ufw default allow outgoing
ufw --force enable
ufw status verbose

# 3 — Add SSH 1335 while retaining the currently working port(s).
info '3/7 — SSH: добавляем порт 1335 без отключения старых'
cp -a /etc/ssh "$BACKUP_DIR/ssh"
mkdir -p /etc/ssh/sshd_config.d
SSH_DROPIN=/etc/ssh/sshd_config.d/00-3ax-setup.conf
if ! grep -Eq '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config.d/\*' /etc/ssh/sshd_config; then
  warn 'В sshd_config нет стандартного Include. Добавляем его в начало файла.'
  { echo 'Include /etc/ssh/sshd_config.d/*.conf'; cat /etc/ssh/sshd_config; } > "$BACKUP_DIR/sshd_config.new"
  cp "$BACKUP_DIR/sshd_config.new" /etc/ssh/sshd_config
fi
{
  echo '# Managed by 3ax-server-setup. Keep old port(s) until external SSH is verified.'
  printf 'Port %s\n' "${OLD_SSH_PORTS[@]}" "$SSH_PORT" | sort -u
} > "$SSH_DROPIN"
chmod 600 "$SSH_DROPIN"

# Ubuntu 24.04 may use ssh.socket; ensure every requested SSH port is listening.
if systemctl is-active --quiet ssh.socket || systemctl is-enabled --quiet ssh.socket; then
  mkdir -p /etc/systemd/system/ssh.socket.d
  {
    echo '[Socket]'
    echo 'ListenStream='
    printf 'ListenStream=%s\n' "${OLD_SSH_PORTS[@]}" "$SSH_PORT" | sort -u
  } > /etc/systemd/system/ssh.socket.d/90-3ax-setup.conf
  systemctl daemon-reload
fi
/usr/sbin/sshd -t || fail 'Конфигурация SSH некорректна: восстанови каталог /etc/ssh из резервной копии.'
/usr/sbin/sshd -T | awk -v p="$SSH_PORT" '$1 == "port" && $2 == p {found=1} END {exit !found}' || \
  fail 'sshd не принимает порт 1335; смотри другие файлы конфигурации SSH.'
if systemctl is-active --quiet ssh.socket; then
  systemctl restart ssh.socket
fi
systemctl restart ssh.service
ss -H -ltn "sport = :${SSH_PORT}" | grep -q . || \
  fail 'Порт 1335 не слушается. Проверь ssh.service и ssh.socket в веб-консоли.'
info 'SSH слушает 1335; старый порт пока остаётся доступен.'

# 4 — Fail2ban (journal backend works with Ubuntu 22.04 and 24.04).
info '4/7 — Fail2ban'
mkdir -p /etc/fail2ban/jail.d
F2B_FILE=/etc/fail2ban/jail.d/99-3ax-sshd.local
[[ ! -f "$F2B_FILE" ]] || cp -a "$F2B_FILE" "$BACKUP_DIR/fail2ban-previous.local"
cat > "$F2B_FILE" <<F2B
[sshd]
enabled = true
port = ${SSH_PORT}
filter = sshd
backend = systemd
findtime = 600
maxretry = 3
bantime = 43200
ignoreip = 127.0.0.1/8 ::1${TRUSTED_IP:+ ${TRUSTED_IP}}
F2B
systemctl enable --now fail2ban
systemctl restart fail2ban
# Service startup may take a short moment.
for _ in 1 2 3 4 5; do
  if fail2ban-client status sshd; then break; fi
  sleep 2
done
fail2ban-client status sshd >/dev/null || fail 'Не активировался Fail2ban jail sshd.'
if [[ -n "$TRUSTED_IP" ]]; then
  fail2ban-client set sshd unbanip "$TRUSTED_IP" >/dev/null 2>&1 || true
fi

# 5 — Cloudflare IPv4+IPv6 with Quad9 fallback.
info '5/7 — DNS Cloudflare + Quad9 (IPv4 и IPv6)'
mkdir -p /etc/systemd/resolved.conf.d
RESOLVED_FILE=/etc/systemd/resolved.conf.d/90-3ax-dns.conf
[[ ! -f "$RESOLVED_FILE" ]] || cp -a "$RESOLVED_FILE" "$BACKUP_DIR/resolved-previous.conf"
cat > "$RESOLVED_FILE" <<'DNS'
[Resolve]
DNS=1.1.1.1 1.0.0.1 2606:4700:4700::1111 2606:4700:4700::1001
FallbackDNS=
FallbackDNS=9.9.9.9 149.112.112.112 2620:fe::fe 2620:fe::9
DNS
systemctl restart systemd-resolved

# DHCP-provided DNS may take precedence until use-dns:false is set in Netplan.
# We only apply Netplan on an interactive LOCAL console with a recognized DHCP iface.
if [[ -z "${SSH_CONNECTION:-}${SSH_TTY:-}" ]] && command -v netplan >/dev/null 2>&1; then
  DEFAULT_IFACE=$(ip -4 route show default | awk '$1 == "default" {for (i=1;i<=NF;i++) if ($i=="dev") {print $(i+1); exit}}')
  if [[ "$DEFAULT_IFACE" =~ ^[a-zA-Z0-9_-]+$ ]] && \
     netplan get "network.ethernets.${DEFAULT_IFACE}.dhcp4" 2>/dev/null | grep -qx true; then
    mkdir -p "$BACKUP_DIR/netplan"
    cp -a /etc/netplan/. "$BACKUP_DIR/netplan/"
    NETPLAN_FILE=/etc/netplan/99-3ax-cloudflare-dns.yaml
    if [[ -f "$NETPLAN_FILE" ]]; then
      warn 'Netplan-файл уже существует: оставляем текущий без изменений.'
    else
      cat > "$NETPLAN_FILE" <<NETPLAN
network:
  version: 2
  ethernets:
    ${DEFAULT_IFACE}:
      dhcp4-overrides:
        use-dns: false
      dhcp6-overrides:
        use-dns: false
      nameservers:
        addresses:
          - 1.1.1.1
          - 1.0.0.1
          - 2606:4700:4700::1111
          - 2606:4700:4700::1001
NETPLAN
      chmod 600 "$NETPLAN_FILE"
      if ! netplan generate; then
        warn 'Netplan generate не прошёл; дополнительный YAML удалён.'
        rm -f "$NETPLAN_FILE"
        netplan generate || true
      else
        info 'Netplan попробует изменения и откатит их через 120 секунд без подтверждения.'
        if netplan try --timeout 120; then
          info 'Netplan подтверждён.'
        else
          warn 'Netplan не подтверждён — отменяем дополнительный файл.'
          rm -f "$NETPLAN_FILE"
          netplan generate || true
        fi
      fi
    fi
  else
    warn 'Netplan автоматически не изменён: DHCP-интерфейс не распознан.'
  fi
else
  warn 'Netplan не меняем: запуск через SSH или netplan отсутствует.'
fi
resolvectl status || true

# 6 — Download and invoke the upstream installer; skip only its nginx step.
info '6/7 — установка 3AX-UI'
systemctl disable --now nginx 2>/dev/null || true
if ss -H -ltn 'sport = :80' | grep -q .; then
  fail 'Порт 80 занят. Освободи его перед получением сертификата 3AX-UI.'
fi
UPSTREAM_SCRIPT="${BACKUP_DIR}/3ax-upstream-install.sh"
curl -fLsS --retry 3 --connect-timeout 15 "$UPSTREAM_URL" -o "$UPSTREAM_SCRIPT"
[[ -s "$UPSTREAM_SCRIPT" ]] || fail 'Не удалось скачать установщик панели.'
# Guard against unexpected upstream changes: do not blindly patch other code.
COUNT=$(grep -Ec '^install_nginx[[:space:]]*$' "$UPSTREAM_SCRIPT" || true)
[[ "$COUNT" -eq 1 ]] || fail 'Структура установщика 3AX-UI изменилась; нужна ручная проверка.'
sed -i -E 's/^install_nginx[[:space:]]*$/# nginx skipped by 3ax-server-setup/' "$UPSTREAM_SCRIPT"
bash -n "$UPSTREAM_SCRIPT" || fail 'Ошибка синтаксиса скачанного установщика.'
info "SHA256 проверяемого экземпляра: $(sha256sum "$UPSTREAM_SCRIPT" | awk '{print $1}')"
echo 'При запросах установщика: Debug mode = N; пользовательский порт панели = Y, порт = 13350; HTTP-01 = 80.'
echo 'Ниже появятся логин и пароль панели: НЕ публикуй их и не отправляй скриншоты с ними.'
# Do not pipe output to tee/log: the upstream installer may reveal credentials.
bash "$UPSTREAM_SCRIPT"

# 7 — Checks and next steps.
info '7/7 — проверка'
if systemctl is-active --quiet x-ui; then
  echo '3AX-UI: service active'
else
  warn '3AX-UI: проверь systemctl status x-ui и журнал установки.'
fi
fail2ban-client status sshd || true
ufw status verbose
ss -tuln
resolvectl status || true
printf '\n======================================\n'
echo 'Готово. Проверь SSH с другого терминала: ssh -p 1335 root@IP_СЕРВЕРА'
echo 'Пока НЕ закрывай текущую консоль; старый SSH-порт сохранён намеренно.'
echo 'После проверки SSH на 1335 старый порт необходимо отключить в sshd, ssh.socket и UFW.'
echo 'Проверь, что порт панели фактически установлен на 13350.'
echo '443/tcp намеренно не добавлен.'
echo "Бэкапы: ${BACKUP_DIR}"
if [[ -f /var/run/reboot-required ]]; then
  warn 'Системе требуется перезагрузка. Запланируй её после проверки доступа; DKMS может зависеть от нового ядра.'
fi
