#!/usr/bin/env bash
# 3AX-UI VPS bootstrap v0.5 - Ubuntu 22.04 / 24.04
# Run on a NEW VPS from the hosting provider's rescue/web console.
set -Eeuo pipefail
umask 077

readonly SSH_PORT=1335
readonly PANEL_PORT=13350
# Do not publish a personal trusted address in a public GitHub repository.
TRUSTED_IP=''
readonly UPSTREAM_URL='https://raw.githubusercontent.com/coinman-dev/3ax-ui/main/install.sh'

# Own messages use UTF-8 Russian without changing the global OS locale.
CURRENT_STAGE='Начальная проверка'
UI_READY=0
LAST_ERROR=''
declare -a WARNINGS=()
FINAL_LOGIN=''
FINAL_PASSWORD=''
FINAL_URL=''
BACKUP_DIR=''
SSH_USER=''
SSH_PUBLIC_KEY=''
SSH_PASSWORD=''
SSH_PASSWORD_REPEAT=''
COLORS=0
if [[ -t 1 && "${TERM:-dumb}" != dumb && -z "${NO_COLOR:-}" ]]; then COLORS=1; fi

msg() {
  if [[ "${SETUP_LANG:-ru}" == en || "$UI_READY" != 1 ]]; then printf '%s' "$2"; else printf '%s' "$1"; fi
}
color() {
  local code="$1"; shift
  if ((COLORS)); then printf '\033[%sm%s\033[0m' "$code" "$*"; else printf '%s' "$*"; fi
}
info() { printf '\n%s %s\n' "$(color '1;36' '[INFO]')" "$*"; }
step() {
  printf '\n\n%s\n' "$(color '1;36' '==================================================')"
  printf '%s\n' "$(color '1;36' " $*")"
  printf '%s\n\n' "$(color '1;36' '==================================================')"
}
warn() { printf '\n%s %s\n' "$(color '1;33' '[WARN]')" "$*" >&2; WARNINGS+=("$*"); }
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
    printf '%s\n' "$(color '1;32' "$(msg 'Установка завершена. Ошибок нет.' 'Installation complete. No errors.')")"
  else
    printf '%s\n' "$(color '1;31' "$(msg 'Установка завершилась с ошибкой.' 'Installation failed.')")"
    printf '%s\n' "$(msg 'Этап:' 'Step:') ${CURRENT_STAGE}"
    printf '%s\n' "$(msg 'Причина:' 'Reason:') ${LAST_ERROR:-код ${status}}"
  fi
  if ((${#WARNINGS[@]})); then
    printf '%s\n' "$(msg 'Предупреждения:' 'Warnings:')"
    printf ' - %s\n' "${WARNINGS[@]}"
  fi
  if ((status == 0)) && [[ -n "$FINAL_LOGIN" && -n "$FINAL_PASSWORD" && -n "$FINAL_URL" ]]; then
    printf '\n%s\n' "$(msg 'ДАННЫЕ ДЛЯ ВХОДА В 3AX-UI' '3AX-UI PANEL LOGIN')"
    printf '%s %s\n' "$(msg 'Ссылка:' 'URL:')" "$FINAL_URL"
    printf '%s %s\n' "$(msg 'Логин:' 'Username:')" "$FINAL_LOGIN"
    printf '%s %s\n' "$(msg 'Пароль:' 'Password:')" "$FINAL_PASSWORD"
    printf '%s\n' "$(msg 'Сохраните пароль в надёжном месте. Не публикуйте этот экран.' 'Store password securely. Do not share this screen.')"
    if [[ -n "$SSH_USER" ]]; then
      printf '\n%s %s\n' "$(msg 'Пользователь SSH:' 'SSH user:')" "$SSH_USER"
      printf '%s\n' "$(msg "Подключение: ssh -p ${SSH_PORT} ${SSH_USER}@IP_СЕРВЕРА" "Connect: ssh -p ${SSH_PORT} ${SSH_USER}@SERVER_IP")"
      printf '%s\n' "$(msg 'Для SSH используется только ваш приватный ключ.' 'SSH accepts only the matching private key.')"
    fi
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

# Use UTF-8 only for this setup process. DO NOT change the OS default locale.
# Cyrillic font settings affect a Linux virtual console, not the entire OS language.
CURRENT_STAGE='Настройка шрифта консоли'
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
export UCF_FORCE_CONFFOLD=1
export LANG=C.UTF-8 LC_ALL=C.UTF-8

# Automate APT / dpkg prompts without overwriting hoster-customized conffiles.
# -y handles regular APT confirmations, --force-confold handles modified
# configuration files such as /etc/cloud/cloud.cfg. This applies only here,
# and does not create system-wide APT configuration.
apt_auto() {
  apt-get -y -o 'Dpkg::Options::=--force-confold' "$@"
}

# Keep a copy of the cloud-init configuration before any package changes.
if [[ -f /etc/cloud/cloud.cfg ]]; then
  cp -a /etc/cloud/cloud.cfg "$BACKUP_DIR/cloud.cfg.before-upgrade"
fi
printf '[INFO] Preparing Cyrillic console font (keeping OS language unchanged)...\n'
apt_auto update
apt_auto install console-setup console-setup-linux kbd openssh-client
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
echo "$(msg 'SSH: сначала проверим ключ на 1335, затем отключим root, пароль и порт 22.' 'SSH: test the key on 1335 first, then disable root, passwords and port 22.')"
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

# The user account and public SSH key are requested on the provider console.
# Never store passwords or private keys in this public GitHub repository.
read -r -p "$(msg 'Имя нового пользователя SSH: ' 'New SSH username: ')" SSH_USER
[[ "$SSH_USER" =~ ^[a-z_][a-z0-9_-]{0,30}$ ]] || fail 'Недопустимое имя пользователя.'
[[ "$SSH_USER" != root ]] || fail 'Для SSH нужен отдельный пользователь, не root.'
if getent passwd "$SSH_USER" >/dev/null; then
  fail 'Пользователь уже существует. Используйте новый VPS или проверьте систему.'
fi

read -r -s -p "$(msg 'Пароль пользователя для sudo (ввод скрыт): ' 'User password for sudo (hidden): ')" SSH_PASSWORD
printf '\n'
read -r -s -p "$(msg 'Повторите пароль: ' 'Repeat password: ')" SSH_PASSWORD_REPEAT
printf '\n'
[[ "$SSH_PASSWORD" == "$SSH_PASSWORD_REPEAT" && ${#SSH_PASSWORD} -ge 12 ]] || fail 'Пароли не совпадают или содержат менее 12 символов.'
unset SSH_PASSWORD_REPEAT

printf '%s\n' "$(msg 'Вставьте ПУБЛИЧНЫЙ SSH-ключ одной строкой (ssh-ed25519 AAAA...):' 'Paste the PUBLIC SSH key on one line (ssh-ed25519 AAAA...):')"
IFS= read -r SSH_PUBLIC_KEY
[[ "$SSH_PUBLIC_KEY" =~ ^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521|sk-ssh-ed25519@openssh.com|sk-ecdsa-sha2-nistp256@openssh.com)[[:space:]]+[A-Za-z0-9+/]+={0,2}([[:space:]].*)?$ ]] || fail 'Неверный формат публичного SSH-ключа. Приватный ключ вставлять нельзя.'
KEYCHECK_FILE=$(mktemp)
printf '%s\n' "$SSH_PUBLIC_KEY" > "$KEYCHECK_FILE"
if ! ssh-keygen -l -f "$KEYCHECK_FILE" >/dev/null 2>&1; then
  rm -f "$KEYCHECK_FILE"
  fail 'Не удалось проверить публичный SSH-ключ.'
fi
rm -f "$KEYCHECK_FILE"

# 1 - Update and essential packages.
CURRENT_STAGE='Обновление Ubuntu и установка пакетов'
step "$(msg '1/8 — Обновление Ubuntu и установка пакетов' '1/8 - System updates and packages')"
export DEBIAN_FRONTEND=noninteractive
apt_auto update
apt_auto upgrade
apt_auto install ca-certificates curl openssh-server sudo fail2ban python3-systemd ufw nano dkms iproute2
if [[ "$(uname -r)" == *-generic ]]; then
  apt_auto install linux-generic linux-headers-generic
else
  warn "$(msg "Нестандартное ядро $(uname -r): linux-generic не устанавливаем." "Nonstandard kernel $(uname -r): skipping linux-generic.")"
  apt_auto install "linux-headers-$(uname -r)" || warn "$(msg 'Заголовки ядра не найдены. Проверьте DKMS.' 'Kernel headers unavailable; check DKMS.')"
fi

# 2 - Create a sudo user and authorize their public key.
CURRENT_STAGE='Создание пользователя и установка SSH-ключа'
step "$(msg '2/8 — Создание пользователя и установка SSH-ключа' '2/8 - Creating user and installing SSH public key')"
adduser --disabled-password --gecos '' "$SSH_USER"
printf '%s:%s\n' "$SSH_USER" "$SSH_PASSWORD" | chpasswd
unset SSH_PASSWORD
usermod -aG sudo "$SSH_USER"
SSH_HOME=$(getent passwd "$SSH_USER" | cut -d: -f6)
[[ -n "$SSH_HOME" && -d "$SSH_HOME" ]] || fail 'Не удалось найти домашний каталог пользователя.'
install -d -m 700 -o "$SSH_USER" -g "$SSH_USER" "$SSH_HOME/.ssh"
printf '%s\n' "$SSH_PUBLIC_KEY" > "$SSH_HOME/.ssh/authorized_keys"
chown "$SSH_USER:$SSH_USER" "$SSH_HOME/.ssh/authorized_keys"
chmod 600 "$SSH_HOME/.ssh/authorized_keys"
unset SSH_PUBLIC_KEY
id -nG "$SSH_USER" | tr ' ' '\n' | grep -qx sudo || fail 'Пользователь не добавлен в sudo.'

CURRENT_STAGE='Настройка UFW'
step "$(msg '3/8 — Настройка UFW' '3/8 - UFW firewall rules')"
cp -a /etc/default/ufw "$BACKUP_DIR/ufw-default"
sed -i -E 's/^IPV6=.*/IPV6=yes/' /etc/default/ufw
# Keep the old access port until the NEW account has been verified remotely.
ufw allow 22/tcp
ufw allow "${SSH_PORT}/tcp"
ufw allow "${PANEL_PORT}/tcp"
ufw allow 13133/tcp
ufw allow 13133/udp
ufw allow 20304/udp
ufw allow 13131/udp
ufw allow 80/tcp
ufw default deny incoming
ufw default allow outgoing
ufw --force enable

# 4 - TWO-PHASE SSH hardening. Never remove the original access path before
# verifying an authenticated connection using the NEW key and sudo account.
CURRENT_STAGE='Проверка нового SSH-доступа'
step "$(msg '4/8 — Проверка SSH-ключа на порту 1335' '4/8 - Verify SSH key on port 1335')"
cp -a /etc/ssh "$BACKUP_DIR/ssh"
mkdir -p /etc/ssh/sshd_config.d
SSH_DROPIN=/etc/ssh/sshd_config.d/00-3ax-setup.conf
if ! grep -Eq '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config.d/\*' /etc/ssh/sshd_config; then
  { echo 'Include /etc/ssh/sshd_config.d/*.conf'; cat /etc/ssh/sshd_config; } > "$BACKUP_DIR/sshd_config.new"
  cp "$BACKUP_DIR/sshd_config.new" /etc/ssh/sshd_config
fi
# Transitional state: both the old and new ports stay open, and existing
# authentication remains available. New account can already use its key.
cat > "$SSH_DROPIN" <<SSHCONF
# Managed by 3ax-server-setup. Temporary verification phase.
Port 22
Port ${SSH_PORT}
PubkeyAuthentication yes
# Keep existing authentication available until new key-based access is tested.
# The test command below explicitly forbids password/interactive fallbacks.
SSHCONF
chmod 600 "$SSH_DROPIN"

# Ubuntu 24.04 may use systemd SSH socket activation.
SSH_SOCKET_ACTIVE=0
if systemctl is-active --quiet ssh.socket || systemctl is-enabled --quiet ssh.socket; then
  SSH_SOCKET_ACTIVE=1
  mkdir -p /etc/systemd/system/ssh.socket.d
  cat > /etc/systemd/system/ssh.socket.d/90-3ax-setup.conf <<SSHUNIT
[Socket]
ListenStream=
ListenStream=22
ListenStream=${SSH_PORT}
SSHUNIT
  systemctl daemon-reload
fi
/usr/sbin/sshd -t || fail 'Неверная временная конфигурация SSH.'
if ((SSH_SOCKET_ACTIVE)) && systemctl is-active --quiet ssh.socket; then
  systemctl restart ssh.socket
fi
systemctl restart ssh.service
ss -H -ltn "sport = :${SSH_PORT}" | grep -q . || fail 'SSH не слушает порт 1335.'

# The backup directory already exists and persists across reboots.
# Avoid ephemeral /run/ markers or paths that the second SSH session cannot find.
VERIFY_MARKER="$BACKUP_DIR/ssh-verified"
[[ -d "$BACKUP_DIR" ]] || fail 'Missing verification directory (backup directory).'
rm -f -- "$VERIFY_MARKER"
printf '\n%s\n' "$(msg 'ПРОВЕРКА: откройте ВТОРОЙ терминал на своём компьютере, НЕ закрывая консоль хостинга.' 'VERIFICATION: open a SECOND terminal on your computer. Keep this console open.')"
printf 'ssh -o PreferredAuthentications=publickey -o PasswordAuthentication=no -o KbdInteractiveAuthentication=no -p %s %s@%s\n' "$SSH_PORT" "$SSH_USER" 'SERVER_IP'
printf '%s\n' "$(msg 'Убедитесь, что вход выполнен по вашему ПРИВАТНОМУ ключу.' 'Confirm login uses YOUR private SSH key.')"
printf '%s\n' "$(msg 'На сервере в новом SSH-сеансе выполните:' 'In the NEW SSH session, run:')"
printf 'sudo touch %s\n' "$VERIFY_MARKER"
printf '%s\n' "$(msg 'Введите пароль sudo, затем вернитесь в эту веб-консоль.' 'Enter the sudo password, then return to this provider console.')"
while true; do
  read -r -p "$(msg 'Если команда успешно выполнена, нажмите Enter (Ctrl+C — отменить): ' 'After the command succeeds, press Enter (Ctrl+C to abort): ')" _
  if [[ -f "$VERIFY_MARKER" && "$(stat -c %u "$VERIFY_MARKER")" == 0 ]]; then break; fi
  warn "$(msg 'Подтверждение не найдено. Проверьте SSH-ключ и sudo, затем повторите.' 'No verified marker; test SSH key and sudo, then retry.')"
done

# Now—and only now—close the legacy port and disable root/password logins.
CURRENT_STAGE='Окончательное усиление безопасности SSH'
cat > "$SSH_DROPIN" <<SSHCONF
# Managed by 3ax-server-setup. Verified key-only access.
Port ${SSH_PORT}
PermitRootLogin no
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
AuthenticationMethods publickey
PermitEmptyPasswords no
SSHCONF
if ((SSH_SOCKET_ACTIVE)); then
  cat > /etc/systemd/system/ssh.socket.d/90-3ax-setup.conf <<SSHUNIT
[Socket]
ListenStream=
ListenStream=${SSH_PORT}
SSHUNIT
  systemctl daemon-reload
fi
/usr/sbin/sshd -t || fail 'Неверная защищённая конфигурация SSH.'
SSH_EFFECTIVE=$(/usr/sbin/sshd -T -C "user=${SSH_USER},host=localhost,addr=127.0.0.1")
ROOT_EFFECTIVE=$(/usr/sbin/sshd -T -C 'user=root,host=localhost,addr=127.0.0.1')
[[ "$(printf '%s\n' "$SSH_EFFECTIVE" | awk '$1=="port" {print $2}' | sort -u)" == "$SSH_PORT" ]] || fail 'Обнаружен лишний SSH-порт.'
for expected in \
    'pubkeyauthentication yes' \
    'passwordauthentication no' \
    'kbdinteractiveauthentication no' \
    'authenticationmethods publickey'; do
  printf '%s\n' "$SSH_EFFECTIVE" | grep -qx "$expected" || fail "SSH не применил параметр: $expected"
done
printf '%s\n' "$ROOT_EFFECTIVE" | grep -qx 'permitrootlogin no' || fail 'SSH по-прежнему разрешает вход root.'
if ((SSH_SOCKET_ACTIVE)) && systemctl is-active --quiet ssh.socket; then
  systemctl restart ssh.socket
fi
systemctl restart ssh.service
ss -H -ltn "sport = :${SSH_PORT}" | grep -q . || fail 'SSH не слушает порт 1335 после изменений.'
ufw --force delete allow OpenSSH >/dev/null 2>&1 || true
ufw --force delete allow 22/tcp >/dev/null 2>&1 || true
ufw insert 1 deny 22/tcp
rm -f -- "$VERIFY_MARKER"
info "$(msg 'SSH проверен: пользователь с ключом на 1335; root и вход по паролю отключены.' 'SSH verified: key-only user on 1335; root and password login disabled.')"

# 5 - Fail2ban (journal backend works with Ubuntu 22.04 and 24.04).
CURRENT_STAGE='Настройка Fail2ban'
step "$(msg '5/8 — Настройка Fail2ban' '5/8 - Fail2ban')"
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

# 6 - Cloudflare IPv4+IPv6 with Quad9 fallback.
CURRENT_STAGE='Настройка DNS и Netplan'
step "$(msg '6/8 — DNS Cloudflare и Quad9 (IPv4/IPv6)' '6/8 - Cloudflare and Quad9 DNS (IPv4/IPv6)')"
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

# 7 - Download and invoke the upstream installer; skip only its nginx step.
CURRENT_STAGE='Установка 3AX-UI'
step "$(msg '7/8 — Установка 3AX-UI' '7/8 - Installing 3AX-UI')"
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

# 8 - Check the actual panel settings and issue credentials for the final summary.
CURRENT_STAGE='Проверка панели и подготовка реквизитов входа'
step "$(msg '8/8 — Проверка панели' '8/8 - Verifying panel')"
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

# The upstream installer prints one-time credentials, but stores only the
# password hash. Ask for the FINAL credentials and URL path, then apply them.
# None of these secrets goes to GitHub, files, or the installer log.
CURRENT_STAGE='Настройка итоговых реквизитов панели'
step "$(msg 'Данные панели: свои или случайные' 'Panel login: custom or randomly generated')"
info "$(msg 'Выберите способ задания для каждого параметра отдельно.' 'Choose generation or custom entry for each field.')"

random_alnum() {
  python3 - "$1" <<'PY_RANDOM'
import secrets
import string
import sys
alphabet = string.ascii_letters + string.digits
print(''.join(secrets.choice(alphabet) for _ in range(int(sys.argv[1]))))
PY_RANDOM
}

ask_choice() {
  local label_ru="$1" label_en="$2" answer
  while true; do
    read -r -p "$(msg "$label_ru" "$label_en") [1/2, Enter=1]: " answer
    case "$answer" in
      ''|1) CHOICE=1; return 0 ;;
      2) CHOICE=2; return 0 ;;
      *) warn "$(msg 'Введите 1 или 2.' 'Enter 1 or 2.')" ;;
    esac
  done
}

# The username is not an OS account. Restrict input to a predictable safe set.
ask_choice 'Логин панели: 1 = сгенерировать, 2 = свой' 'Panel username: 1 = generate, 2 = custom'
if [[ "$CHOICE" == 1 ]]; then
  NEW_LOGIN="admin_$(random_alnum 10)"
else
  read -r -p "$(msg 'Введите логин (4-32 символа, латиница/цифры/_/-): ' 'Panel username (4-32 ASCII letters/digits/_/-): ')" NEW_LOGIN
  [[ "$NEW_LOGIN" =~ ^[A-Za-z][A-Za-z0-9_-]{3,31}$ ]] || fail 'Некорректный логин панели.'
fi

ask_choice 'Пароль панели: 1 = сгенерировать, 2 = свой' 'Panel password: 1 = generate, 2 = custom'
if [[ "$CHOICE" == 1 ]]; then
  NEW_PASSWORD=$(random_alnum 30)
else
  read -r -s -p "$(msg 'Введите пароль панели (минимум 12 символов, ввод скрыт): ' 'Panel password (at least 12 characters, hidden): ')" NEW_PASSWORD
  printf '\n'
  read -r -s -p "$(msg 'Повторите пароль панели: ' 'Repeat panel password: ')" CONFIRM_PANEL_PASSWORD
  printf '\n'
  [[ "$NEW_PASSWORD" == "$CONFIRM_PANEL_PASSWORD" ]] || fail 'Пароли панели не совпадают.'
  unset CONFIRM_PANEL_PASSWORD
  [[ ${#NEW_PASSWORD} -ge 12 && ${#NEW_PASSWORD} -le 128 ]] || fail 'Пароль панели должен содержать от 12 до 128 символов.'
  # Avoid control characters. Whitespace is allowed but not leading/trailing.
  [[ "$NEW_PASSWORD" != *[$'\001'-$'\037']* ]] || fail 'Пароль панели содержит управляющие символы.'
fi

ask_choice 'Корневой путь URL: 1 = сгенерировать, 2 = свой' 'Panel URL base path: 1 = generate, 2 = custom'
if [[ "$CHOICE" == 1 ]]; then
  NEW_WEB_BASE_PATH=$(random_alnum 24)
else
  read -r -p "$(msg 'Введите путь, например mySecretPanel (можно с /): ' 'URL path, e.g. mySecretPanel (optional /): ')" NEW_WEB_BASE_PATH
  NEW_WEB_BASE_PATH="${NEW_WEB_BASE_PATH#/}"
  NEW_WEB_BASE_PATH="${NEW_WEB_BASE_PATH%/}"
  [[ "$NEW_WEB_BASE_PATH" =~ ^[A-Za-z0-9_-]{6,64}$ ]] || fail 'Корневой путь: от 6 до 64 символов, только латиница/цифры/_/- и без вложенных /.'
fi

info "$(msg 'Реквизиты выбраны, применяем через штатную команду 3AX-UI.' 'Credentials chosen; applying via the official 3AX-UI command.')"
# Do not enable set -x or tee around these calls: -password is an argument.
"$PANEL_BIN" setting -username "$NEW_LOGIN" -password "$NEW_PASSWORD" -webBasePath "$NEW_WEB_BASE_PATH" >/dev/null 2>&1 || fail 'Не удалось сохранить логин, пароль или путь панели.'
# These values are intentionally kept in memory and printed only in the final status.
FINAL_LOGIN="$NEW_LOGIN"
FINAL_PASSWORD="$NEW_PASSWORD"
systemctl restart x-ui || fail 'Не удалось перезапустить панель после изменения реквизитов.'
systemctl is-active --quiet x-ui || fail 'Сервис x-ui не запустился после изменения реквизитов.'

VERIFY_SETTINGS=$("$PANEL_BIN" setting -show true) || fail 'Не удалось проверить итоговые настройки панели.'
VERIFY_PORT=$(printf '%s\n' "$VERIFY_SETTINGS" | sed -nE 's/^[[:space:]]*port:[[:space:]]*([0-9]+).*/\1/p' | head -n1)
VERIFY_PATH=$(printf '%s\n' "$VERIFY_SETTINGS" | sed -nE 's#^[[:space:]]*webBasePath:[[:space:]]*/?([^[:space:]]+).*#\1#p' | head -n1)
# x-ui may normalize WebBasePath to /name/ rather than name.
VERIFY_PATH="${VERIFY_PATH#/}"
VERIFY_PATH="${VERIFY_PATH%/}"
[[ "$VERIFY_PORT" == "$PANEL_PORT" && "$VERIFY_PATH" == "$NEW_WEB_BASE_PATH" ]] || fail 'Итоговые порт или URL-путь панели не совпали с заданными.'
ss -H -ltn "sport = :${PANEL_PORT}" | grep -q . || fail 'После смены реквизитов панель не слушает порт 13350.'
FINAL_URL="https://${PANEL_HOST}:${PANEL_PORT}/${NEW_WEB_BASE_PATH}/"

CURRENT_STAGE='Завершение'
if [[ -f /var/run/reboot-required ]]; then
  warn "$(msg 'После обновления потребуется перезагрузка (не делайте её до проверки нового SSH-порта).' 'Reboot required after checking SSH access.')"
fi
warn "$(msg 'Проверьте вход по SSH-ключу на 1335 после установки. Веб-консоль пока не закрывайте.' 'Test key-based SSH on 1335 after setup. Keep provider console available.')"
