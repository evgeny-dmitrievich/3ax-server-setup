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

fail() { printf '\n[ERROR] %s\n' "$*" >&2; exit 1; }
info() { printf '\n[INFO] %s\n' "$*"; }
warn() { printf '\n[WARN] %s\n' "$*" >&2; }
trap 'warn "Error at line $LINENO (exit code $?). Changes were not automatically rolled back. Use the provider web console and backups."' ERR

[[ "$EUID" -eq 0 ]] || fail 'Run: sudo bash setup.sh'
[[ -t 0 ]] || fail 'An interactive terminal is required: the 3AX-UI installer asks questions.'
[[ -r /etc/os-release ]] || fail 'Could not detect the operating system.'
# shellcheck source=/dev/null
. /etc/os-release
[[ "${ID:-}" == ubuntu ]] || fail 'Only Ubuntu is supported.'
[[ "${VERSION_ID:-}" == '22.04' || "${VERSION_ID:-}" == '24.04' ]] || fail 'Ubuntu 22.04 or 24.04 is required.'

if [[ -e /usr/bin/x-ui || -e /usr/local/x-ui/x-ui ]]; then
  fail '3AX-UI appears to be installed already. This script is intended for a fresh server.'
fi

BACKUP_DIR="/root/3ax-setup-backup-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BACKUP_DIR"
chmod 700 "$BACKUP_DIR"
info "OS: Ubuntu ${VERSION_ID}; backup directory: ${BACKUP_DIR}"
echo 'WARNING: This script will change SSH, UFW, Fail2ban, and DNS settings.'
echo 'Existing SSH port(s) will remain open until you verify access on port 1335.'
echo 'Netplan changes will be skipped for unrecognized network configurations.'
if [[ -n "${SSH_CONNECTION:-}${SSH_TTY:-}" ]]; then
  warn 'Running over SSH. Provider web console is preferred; Netplan changes will be skipped.'
fi
read -r -p 'Is this a fresh VPS with provider web console access? Type YES to continue: ' CONFIRM
[[ "$CONFIRM" == 'YES' ]] || fail 'Cancelled.'
read -r -p 'Trusted IPv4 address for Fail2ban ignoreip (leave blank to skip): ' TRUSTED_IP
if [[ -n "$TRUSTED_IP" ]]; then
  [[ "$TRUSTED_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || fail 'Invalid IPv4 address format.'
  IFS=. read -r a b c d <<< "$TRUSTED_IP"
  for octet in "$a" "$b" "$c" "$d"; do
    (( 10#$octet <= 255 )) || fail 'Invalid IPv4 address.'
  done
fi

# 1 - Update and essential packages.
info '1/7 - System updates and packages'
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get upgrade -y
apt-get install -y ca-certificates curl openssh-server fail2ban python3-systemd ufw nano dkms iproute2
if [[ "$(uname -r)" == *-generic ]]; then
  apt-get install -y linux-generic linux-headers-generic
else
  warn "Nonstandard kernel: $(uname -r). Skipping forced installation of linux-generic."
  apt-get install -y "linux-headers-$(uname -r)" || warn 'Kernel headers not found; check DKMS support.'
fi

# 2 - Open ports BEFORE restarting SSH or enabling UFW.
info '2/7 - UFW firewall rules'
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
info '3/7 - SSH: add port 1335 without closing existing ports'
cp -a /etc/ssh "$BACKUP_DIR/ssh"
mkdir -p /etc/ssh/sshd_config.d
SSH_DROPIN=/etc/ssh/sshd_config.d/00-3ax-setup.conf
if ! grep -Eq '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config.d/\*' /etc/ssh/sshd_config; then
  warn 'Standard Include is missing in sshd_config; adding it at the top.'
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
info 'SSH is listening on port 1335; existing SSH ports remain open for now.'

# 4 - Fail2ban (journal backend works with Ubuntu 22.04 and 24.04).
info '4/7 - Fail2ban'
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
info '5/7 - Cloudflare + Quad9 DNS (IPv4 and IPv6)'
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
      warn 'The Netplan override file already exists; leaving it unchanged.'
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
        warn 'Netplan generate failed; removing the added YAML file.'
        rm -f "$NETPLAN_FILE"
        netplan generate || true
      else
        info 'Netplan will try the changes and roll back after 120 seconds unless confirmed.'
        if netplan try --timeout 120; then
          info 'Netplan configuration confirmed.'
        else
          warn 'Netplan was not confirmed; removing the added YAML file.'
          rm -f "$NETPLAN_FILE"
          netplan generate || true
        fi
      fi
    fi
  else
    warn 'Netplan left unchanged: no recognized DHCP interface.'
  fi
else
  warn 'Netplan skipped: running over SSH or netplan is not installed.'
fi
resolvectl status || true

# 6 - Download and invoke the upstream installer; skip only its nginx step.
info '6/7 - Installing 3AX-UI'
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
echo 'Installer choices: Debug mode = N; Custom panel port = Y; Panel port = 13350; HTTP-01 = 80.'
echo 'The installer may display panel credentials below. Do NOT publish or share them.'
# Do not pipe output to tee/log: the upstream installer may reveal credentials.
bash "$UPSTREAM_SCRIPT"

# 7 - Checks and next steps.
info '7/7 - Verification'
if systemctl is-active --quiet x-ui; then
  echo '3AX-UI: service active'
else
  warn '3AX-UI: check systemctl status x-ui and the installation output.'
fi
fail2ban-client status sshd || true
ufw status verbose
ss -tuln
resolvectl status || true
printf '\n======================================\n'
echo 'Finished. Test SSH from another terminal: ssh -p 1335 root@SERVER_IP'
echo 'Do NOT close this console yet; the old SSH port remains open intentionally.'
echo 'After verifying SSH on port 1335, remove the old port from sshd, ssh.socket, and UFW.'
echo 'Confirm that the panel is actually configured to use port 13350.'
echo '443/tcp was intentionally not opened.'
echo "Backups: ${BACKUP_DIR}"
if [[ -f /var/run/reboot-required ]]; then
  warn 'Reboot required. Schedule it after verifying access; DKMS may depend on the new kernel.'
fi
