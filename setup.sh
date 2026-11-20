#!/usr/bin/env bash
# 3AX-UI VPS bootstrap - Ubuntu 22.04 / 24.04
# Run on a NEW VPS from the hosting provider's rescue/web console.
set -Eeuo pipefail
umask 077

readonly SSH_PORT=1335
readonly PANEL_PORT=13350
# Do not publish a personal trusted address in a public GitHub repository.
TRUSTED_IP=''
readonly UPSTREAM_URL='https://raw.githubusercontent.com/coinman-dev/3ax-ui/main/install.sh'

# Own messages are Russian after preparing UTF-8. Vendor questions may be English.
CURRENT_STAGE='Начальная проверка'
UI_READY=0
LAST_ERROR=''
declare -a WARNINGS=()
FINAL_LOGIN=''
FINAL_PASSWORD=''
FINAL_URL=''
BACKUP_DIR=''

msg() {
  if [[ "${SETUP_LANG:-ru}" == en || "$UI_READY" != 1 ]]; then printf '%s' "$2"; else printf '%s' "$1"; fi
}
info() { printf '\n[INFO] %s\n' "$*"; }
warn() { printf '\n[WARN] %s\n' "$*" >&2; WARNINGS+=("$*"); }
fail() { LAST_ERROR="$*"; exit 1; }
on_error() {
  local code="$1" line="$2"
  if [[ -z "$LAST_ERROR" ]]; then LAST_ERROR="${CURRENT_STAGE}: строка ${line} (код ${code})"; fi
}
on_exit() {
  local status="$1"
  trap - ERR EXIT
  printf '\n===============================================\n'
  if ((status == 0)); then
    printf '%s\n' "$(msg 'Установка завершена. Ошибок нет.' 'Installation complete. No errors.')"
  else
    printf '%s\n' "$(msg 'Установка завершилась с ошибкой.' 'Installation failed.')"
    printf '%s\n' "$(msg 'Этап:' 'Step:') ${CURRENT_STAGE}"
    printf '%s\n' "$(msg 'Причина:' 'Reason:') ${LAST_ERROR:-код ${status}}"
  fi
  if ((${#WARNINGS[@]})); then
    printf '%s\n' "$(msg 'Предупреждения:' 'Warnings:')"
    printf ' - %s\n' "${WARNINGS[@]}"
  fi
  if [[ -n "$FINAL_LOGIN" && -n "$FINAL_PASSWORD" && -n "$FINAL_URL" ]]; then
    printf '\n%s\n' "$(msg 'ДАННЫЕ ДЛЯ ВХОДА В 3AX-UI' '3AX-UI PANEL LOGIN')"
    printf '%s %s\n' "$(msg 'Ссылка:' 'URL:')" "$FINAL_URL"
    printf '%s %s\n' "$(msg 'Логин:' 'Username:')" "$FINAL_LOGIN"
    printf '%s %s\n' "$(msg 'Пароль:' 'Password:')" "$FINAL_PASSWORD"
    printf '%s\n' "$(msg 'Сохраните пароль в надёжном месте. Не публикуйте этот экран.' 'Store password securely. Do not share this screen.')"
  fi
  if [[ -n "$BACKUP_DIR" && $status -ne 0 ]]; then
    printf '%s %s\n' "$(msg 'Резервные копии:' 'Backups:')" "$BACKUP_DIR"
  fi
  printf '===============================================\n'
}
trap 'on_error "$?" "$LINENO"' ERR
trap 'on_exit "$?"' EXIT

[[ "$EUID" -eq 0 ]] || fail 'Запускайте через sudo bash setup.sh'
[[ -t 0 ]] || fail 'Нужна интерактивная консоль: 3AX-UI задаёт вопросы.'
[[ -r /etc/os-release ]] || fail 'Не удалось определить ОС.'
# shellcheck source=/dev/null
. /etc/os-release
[[ "${ID:-}" == ubuntu ]] || fail 'Поддерживается только Ubuntu.'
[[ "${VERSION_ID:-}" == '22.04' || "${VERSION_ID:-}" == '24.04' ]] || fail 'Нужна Ubuntu 22.04 или 24.04.'
if [[ -e /usr/bin/x-ui || -e /usr/local/x-ui/x-ui ]]; then
  fail '3AX-UI уже установлена. Скрипт рассчитан на новый VPS.'
fi

BACKUP_DIR="/root/3ax-setup-backup-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BACKUP_DIR"
chmod 700 "$BACKUP_DIR"

# First step: install Cyrillic UTF-8 locale and a Linux console font.
# This cannot change a font embedded in a hosting provider's web terminal.
CURRENT_STAGE='Настройка русского языка и шрифта консоли'
export DEBIAN_FRONTEND=noninteractive
export LANG=C.UTF-8 LC_ALL=C.UTF-8
printf '[INFO] Preparing UTF-8 / Cyrillic console...\n'
apt-get update
apt-get install -y locales console-setup console-setup-linux kbd
if grep -q '^# *ru_RU.UTF-8 UTF-8' /etc/locale.gen; then
  sed -i 's/^# *ru_RU.UTF-8 UTF-8/ru_RU.UTF-8 UTF-8/' /etc/locale.gen
fi
if ! grep -q '^ru_RU.UTF-8 UTF-8' /etc/locale.gen; then
  echo 'ru_RU.UTF-8 UTF-8' >> /etc/locale.gen
fi
locale-gen ru_RU.UTF-8 >/dev/null
update-locale LANG=ru_RU.UTF-8
unset LC_ALL
if [[ "${SETUP_LANG:-ru}" != en ]]; then
  export LANG=ru_RU.UTF-8 LC_MESSAGES=ru_RU.UTF-8 LC_CTYPE=ru_RU.UTF-8
fi
if [[ -f /etc/default/console-setup ]]; then
  cp -a /etc/default/console-setup "$BACKUP_DIR/console-setup.orig"
  for entry in 'CHARMAP="UTF-8"' 'CODESET="Uni2"' 'FONTFACE="Terminus"' 'FONTSIZE="8x16"'; do
    key=${entry%%=*}
    if grep -q "^${key}=" /etc/default/console-setup; then
      sed -i "s/^${key}=.*/${entry}/" /etc/default/console-setup
    else
      printf '%s\n' "$entry" >> /etc/default/console-setup
    fi
  done
  # Only attempt to change the active font on a real Linux virtual console.
  CONSOLE_TTY=$(tty 2>/dev/null || true)
  if [[ -z "${SSH_CONNECTION:-}${SSH_TTY:-}" ]] &&
     [[ "${TERM:-}" == linux || "$CONSOLE_TTY" =~ ^/dev/tty[0-9]+$ ]]; then
    setupcon --force >/dev/null 2>&1 || true
  fi
fi

UI_READY=1
CURRENT_STAGE='Подтверждение и исходные параметры'
info "$(msg "Ubuntu ${VERSION_ID}; резервные копии: ${BACKUP_DIR}" "Ubuntu ${VERSION_ID}; backups: ${BACKUP_DIR}")"
echo "$(msg 'Внимание: скрипт изменяет SSH, UFW, Fail2ban и DNS.' 'WARNING: The script will change SSH, UFW, Fail2ban and DNS.')"
echo "$(msg 'Прежний SSH-порт не закрываем до проверки нового порта 1335.' 'The old SSH port remains open until 1335 is tested.')"
if [[ -n "${SSH_CONNECTION:-}${SSH_TTY:-}" ]]; then
  warn "$(msg 'Запуск через SSH: Netplan изменяться не будет.' 'Running over SSH: Netplan changes will be skipped.')"
fi
if [[ "${SETUP_LANG:-ru}" == en ]]; then
  read -r -p 'Is this a new VPS with provider console access? Type YES: ' CONFIRM
else
  read -r -p 'Это новый VPS и есть доступ к веб-консоли хостинга? Введите ДА или YES: ' CONFIRM
fi
[[ "$CONFIRM" == 'YES' || "$CONFIRM" == 'yes' || "$CONFIRM" == 'ДА' || "$CONFIRM" == 'да' ]] || fail 'Установка отменена.'
if [[ "${SETUP_LANG:-ru}" == en ]]; then
  read -r -p 'Trusted IPv4 for Fail2ban (blank = none): ' TRUSTED_IP
else
  read -r -p 'Доверенный IPv4 для исключения из Fail2ban (Enter — пропустить): ' TRUSTED_IP
fi
if [[ -n "$TRUSTED_IP" ]]; then
  [[ "$TRUSTED_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || fail 'Неверный формат IPv4.'
  IFS=. read -r a b c d <<< "$TRUSTED_IP"
  for octet in "$a" "$b" "$c" "$d"; do
    (( 10#$octet <= 255 )) || fail 'Неверный IPv4.'
  done
fi

# 1 - Update and essential packages.
CURRENT_STAGE='Обновление Ubuntu и установка пакетов'
info "$(msg '1/7 — Обновление Ubuntu и установка пакетов' '1/7 - System updates and packages')"
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get upgrade -y
apt-get install -y ca-certificates curl openssh-server fail2ban python3-systemd ufw nano dkms iproute2
if [[ "$(uname -r)" == *-generic ]]; then
  apt-get install -y linux-generic linux-headers-generic
else
  warn "$(msg "Нестандартное ядро $(uname -r): linux-generic не устанавливаем." "Nonstandard kernel $(uname -r): skipping linux-generic.")"
  apt-get install -y "linux-headers-$(uname -r)" || warn "$(msg 'Заголовки ядра не найдены. Проверьте DKMS.' 'Kernel headers unavailable; check DKMS.')"
fi

# 2 - Open ports BEFORE restarting SSH or enabling UFW.
CURRENT_STAGE='Настройка UFW'
info "$(msg '2/7 — Настройка UFW' '2/7 - UFW firewall rules')"
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

# 3 - Add SSH 1335 while retaining the currently working port(s).
CURRENT_STAGE='Настройка SSH'
info "$(msg '3/7 — SSH 1335, сохраняем старый порт' '3/7 - SSH port 1335; preserving old port')"
cp -a /etc/ssh "$BACKUP_DIR/ssh"
mkdir -p /etc/ssh/sshd_config.d
SSH_DROPIN=/etc/ssh/sshd_config.d/00-3ax-setup.conf
if ! grep -Eq '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config.d/\*' /etc/ssh/sshd_config; then
  warn "$(msg 'В sshd_config нет Include, добавляем.' 'Missing Include in sshd_config; adding it.')"
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
/usr/sbin/sshd -t || fail 'Invalid SSH configuration. Restore /etc/ssh from the backup if needed.'
/usr/sbin/sshd -T | awk -v p="$SSH_PORT" '$1 == "port" && $2 == p {found=1} END {exit !found}' || \
  fail 'sshd does not report port 1335. Check other SSH configuration files.'
if systemctl is-active --quiet ssh.socket; then
  systemctl restart ssh.socket
fi
systemctl restart ssh.service
ss -H -ltn "sport = :${SSH_PORT}" | grep -q . || \
  fail 'Port 1335 is not listening. Check ssh.service and ssh.socket via the provider console.'
info "$(msg 'SSH слушает порт 1335. Старые порты пока открыты.' 'SSH listening on 1335. Old ports remain open.')"

# 4 - Fail2ban (journal backend works with Ubuntu 22.04 and 24.04).
CURRENT_STAGE='Настройка Fail2ban'
info "$(msg '4/7 — Настройка Fail2ban' '4/7 - Fail2ban')"
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
fail2ban-client status sshd >/dev/null || fail 'Fail2ban sshd jail did not become active.'
if [[ -n "$TRUSTED_IP" ]]; then
  fail2ban-client set sshd unbanip "$TRUSTED_IP" >/dev/null 2>&1 || true
fi

# 5 - Cloudflare IPv4+IPv6 with Quad9 fallback.
CURRENT_STAGE='Настройка DNS и Netplan'
info "$(msg '5/7 — DNS Cloudflare и Quad9 (IPv4/IPv6)' '5/7 - Cloudflare and Quad9 DNS (IPv4/IPv6)')"
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
      warn "$(msg 'Netplan-файл уже существует, не изменяем.' 'Netplan override exists; unchanged.')"
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
        warn "$(msg 'Netplan generate завершился ошибкой, отменяем файл.' 'Netplan generate failed; reverting YAML.')"
        rm -f "$NETPLAN_FILE"
        netplan generate || true
      else
        info "$(msg 'Netplan: подтвердите сеть в течение 120 секунд, иначе будет откат.' 'Netplan: confirm within 120 seconds or changes roll back.')"
        if netplan try --timeout 120; then
          info "$(msg 'Netplan подтверждён.' 'Netplan confirmed.')"
        else
          warn "$(msg 'Netplan не подтверждён, отменяем файл.' 'Netplan not confirmed; reverting YAML.')"
          rm -f "$NETPLAN_FILE"
          netplan generate || true
        fi
      fi
    fi
  else
    warn "$(msg 'Netplan без изменений: DHCP-интерфейс не распознан.' 'Netplan unchanged: DHCP interface not recognized.')"
  fi
else
  warn "$(msg 'Netplan пропущен: SSH или Netplan отсутствует.' 'Netplan skipped: SSH session or Netplan unavailable.')"
fi
resolvectl status || true

# 6 - Download and invoke the upstream installer; skip only its nginx step.
CURRENT_STAGE='Установка 3AX-UI'
info "$(msg '6/7 — Установка 3AX-UI' '6/7 - Installing 3AX-UI')"
systemctl disable --now nginx 2>/dev/null || true
if ss -H -ltn 'sport = :80' | grep -q .; then
  fail 'Port 80 is in use. Free this port before requesting a 3AX-UI certificate.'
fi
UPSTREAM_SCRIPT="${BACKUP_DIR}/3ax-upstream-install.sh"
curl -fLsS --retry 3 --connect-timeout 15 "$UPSTREAM_URL" -o "$UPSTREAM_SCRIPT"
[[ -s "$UPSTREAM_SCRIPT" ]] || fail 'Failed to download the 3AX-UI installer.'
# Guard against unexpected upstream changes: do not blindly patch other code.
COUNT=$(grep -Ec '^install_nginx[[:space:]]*$' "$UPSTREAM_SCRIPT" || true)
[[ "$COUNT" -eq 1 ]] || fail 'The 3AX-UI installer structure has changed; manual review is required.'
sed -i -E 's/^install_nginx[[:space:]]*$/# nginx skipped by 3ax-server-setup/' "$UPSTREAM_SCRIPT"
bash -n "$UPSTREAM_SCRIPT" || fail 'Downloaded 3AX-UI installer has a Bash syntax error.'
info "Downloaded installer SHA256: $(sha256sum "$UPSTREAM_SCRIPT" | awk '{print $1}')"
echo "$(msg 'На вопрос Debug mode: N; свой порт: Y; порт: 13350; HTTP-01: 80.' 'Installer choices: Debug=N; Custom panel port=Y; Panel port=13350; HTTP-01=80.')"
echo "$(msg 'Установщик покажет временный пароль. Не публикуйте его.' 'The installer may display temporary credentials. Do not share them.')"
# Do not pipe output to tee/log: the upstream installer may reveal credentials.
bash "$UPSTREAM_SCRIPT"

# 7 - Check the actual panel settings and issue credentials for the final summary.
CURRENT_STAGE='Проверка панели и подготовка реквизитов входа'
info "$(msg '7/7 — Проверка панели' '7/7 - Verifying panel')"
systemctl is-active --quiet x-ui || fail 'Сервис x-ui не запустился: systemctl status x-ui'
fail2ban-client status sshd >/dev/null || fail 'Fail2ban jail sshd не работает.'
LC_ALL=C ufw status | grep -q '^Status: active' || fail 'UFW не активен.'
PANEL_BIN='/usr/local/x-ui/x-ui'
[[ -x "$PANEL_BIN" ]] || fail 'Исполняемый файл панели не найден.'

SETTING_OUTPUT=$("$PANEL_BIN" setting -show true) || fail 'Не удалось получить настройки x-ui.'
CONFIG_PORT=$(printf '%s\n' "$SETTING_OUTPUT" | sed -nE 's/^[[:space:]]*port:[[:space:]]*([0-9]+).*/\1/p' | head -n1)
CONFIG_PATH=$(printf '%s\n' "$SETTING_OUTPUT" | sed -nE 's#^[[:space:]]*webBasePath:[[:space:]]*/?([^[:space:]]+).*#\1#p' | head -n1)
[[ "$CONFIG_PORT" == "$PANEL_PORT" ]] || fail "Панель слушает порт ${CONFIG_PORT:-?}, ожидали ${PANEL_PORT}. Проверьте настройку порта."
[[ -n "$CONFIG_PATH" ]] || fail 'Не удалось определить WebBasePath панели.'
ss -H -ltn "sport = :${PANEL_PORT}" | grep -q . || fail "Панель не слушает ${PANEL_PORT}/tcp."

# Use SSL certificate SAN, not a guessed IP, for a correct clickable HTTPS URL.
CERT_OUTPUT=$("$PANEL_BIN" setting -getCert true) || fail 'Не удалось прочитать настройки SSL.'
CERT_FILE=$(printf '%s\n' "$CERT_OUTPUT" | sed -nE 's/^[[:space:]]*cert:[[:space:]]*(\/[^[:space:]]+).*/\1/p' | head -n1)
[[ -n "$CERT_FILE" && -r "$CERT_FILE" ]] || fail 'SSL-сертификат панели не настроен. Проверьте выпуск сертификата в 3AX-UI.'
command -v openssl >/dev/null 2>&1 || fail 'Не найдена команда openssl.'
openssl x509 -in "$CERT_FILE" -noout -checkend 0 >/dev/null 2>&1 || fail 'SSL-сертификат уже недействителен.'
# Avoid reading password/hash fields into any stored log.
CERT_SAN=$(openssl x509 -in "$CERT_FILE" -noout -ext subjectAltName 2>/dev/null) || fail 'Не удалось проверить сертификат панели.'
PANEL_HOST=$(printf '%s\n' "$CERT_SAN" | grep -oE 'DNS:[[:alnum:]._-]+' | head -n1 | cut -d: -f2 || true)
if [[ -z "$PANEL_HOST" ]]; then
  PANEL_HOST=$(printf '%s\n' "$CERT_SAN" | grep -oE 'IP Address:[0-9.]+' | head -n1 | cut -d: -f2 || true)
fi
if [[ -z "$PANEL_HOST" ]]; then
  PANEL_HOST=$(printf '%s\n' "$CERT_SAN" | grep -oE 'IP Address:[0-9a-fA-F:]+' | head -n1 | sed 's/^IP Address://' || true)
  [[ -z "$PANEL_HOST" ]] || PANEL_HOST="[${PANEL_HOST}]"
fi
[[ -n "$PANEL_HOST" ]] || fail 'Не найден адрес в SSL-сертификате. Проверьте сертификат вручную.'

# Upstream initially prints a password, but only its hash is stored.
# Generate our own strong, one-time credentials and apply them through its CLI.
CURRENT_STAGE='Назначение логина и пароля панели'
NEW_LOGIN="admin_$(python3 -c 'import secrets, string; print("".join(secrets.choice(string.ascii_lowercase+string.digits) for _ in range(8)))')"
NEW_PASSWORD=$(python3 -c 'import secrets, string; print("".join(secrets.choice(string.ascii_letters+string.digits) for _ in range(24)))')
"$PANEL_BIN" setting -username "$NEW_LOGIN" -password "$NEW_PASSWORD" >/dev/null 2>&1 || fail 'Не удалось назначить логин и пароль панели.'
systemctl restart x-ui || fail 'Не удалось перезапустить x-ui после смены логина.'
systemctl is-active --quiet x-ui || fail 'Панель не запустилась после смены логина.'
FINAL_LOGIN="$NEW_LOGIN"
FINAL_PASSWORD="$NEW_PASSWORD"
FINAL_URL="https://${PANEL_HOST}:${CONFIG_PORT}/${CONFIG_PATH#/}"

CURRENT_STAGE='Завершение'
if [[ -f /var/run/reboot-required ]]; then
  warn "$(msg 'После обновления потребуется перезагрузка (не делайте её до проверки нового SSH-порта).' 'Reboot required after checking SSH access.')"
fi
warn "$(msg 'Старые порты SSH пока открыты: закройте их после проверки подключения на 1335.' 'Old SSH port(s) remain open until 1335 is tested.')"
