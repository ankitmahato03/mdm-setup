#!/usr/bin/env bash
# 03-join-client.sh - run on EVERY Ubuntu device you want to manage.
#   * Points DNS for ad.ankinfo.online at the DC
#   * Joins the AD domain (SSSD) - members of linux-users / linux-admins can log in,
#     linux-admins also get sudo
#   * Registers the device with Landscape (then accept it in the Landscape web UI)
#
# Usage:   sudo bash 03-join-client.sh <DC_IP>
# Options (env): JOIN_USER=administrator  REG_KEY=<landscape registration key>  DC_FQDN=...
set -euo pipefail

DC_IP="${1:-${DC_IP:-}}"
REALM_DNS="${REALM_DNS:-ad.ankinfo.online}"
DC_FQDN="${DC_FQDN:-mdm-server.$REALM_DNS}"
JOIN_USER="${JOIN_USER:-administrator}"
REG_KEY="${REG_KEY:-}"
REALM="${REALM_DNS^^}"
export DEBIAN_FRONTEND=noninteractive

log() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
die() { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Run with sudo"
[[ -n "$DC_IP" ]] || die "Usage: sudo bash $0 <DC_IP>"
if [[ -e /var/lib/samba/private/sam.ldb ]] || systemctl is-active -q samba-ad-dc 2>/dev/null; then
  die "This machine IS the domain controller. Run this script on the Ubuntu devices you want to manage, not on the server."
fi
SHORT=$(hostname -s)
(( ${#SHORT} <= 15 )) || die "Hostname '$SHORT' > 15 chars. Rename first: sudo hostnamectl set-hostname <name>"

log "1/5 DNS: send *.$REALM_DNS queries to $DC_IP"
systemctl is-active -q systemd-resolved || die "systemd-resolved is not running on this device"
mkdir -p /etc/systemd/resolved.conf.d
printf '[Resolve]\nDNS=%s\nDomains=%s\n' "$DC_IP" "$REALM_DNS" > /etc/systemd/resolved.conf.d/ad-domain.conf
systemctl restart systemd-resolved
sleep 2
getent hosts "$DC_FQDN" >/dev/null || die "Cannot resolve $DC_FQDN via $DC_IP (firewall/VLAN between this device and the DC?)"
resolvectl query -t SRV "_ldap._tcp.$REALM_DNS" >/dev/null || die "AD SRV records not found"
timedatectl set-ntp true || true

log "2/5 Installing packages"
echo "krb5-config krb5-config/default_realm string $REALM" | debconf-set-selections
apt-get update
apt-get install -y realmd sssd sssd-tools adcli samba-common-bin packagekit oddjob oddjob-mkhomedir \
  libnss-sss libpam-sss krb5-user landscape-client openssl

log "3/5 Joining $REALM_DNS"
if realm list | grep -q "domain-name: $REALM_DNS"; then
  echo "Already joined."
else
  realm join -v -U "$JOIN_USER" "$REALM_DNS"      # prompts for the AD password
fi
SSSD=/etc/sssd/sssd.conf
sed -i -E 's/^use_fully_qualified_names *=.*/use_fully_qualified_names = False/' "$SSSD"
sed -i -E 's|^fallback_homedir *=.*|fallback_homedir = /home/%u|' "$SSSD"
systemctl restart sssd
pam-auth-update --enable mkhomedir
realm deny --all
realm permit -g linux-users linux-admins
echo '%linux-admins ALL=(ALL:ALL) ALL' > /etc/sudoers.d/ad-linux-admins
chmod 440 /etc/sudoers.d/ad-linux-admins
visudo -cf /etc/sudoers.d/ad-linux-admins >/dev/null || { rm -f /etc/sudoers.d/ad-linux-admins; die "sudoers check failed"; }

log "4/5 Fetching Landscape certificate"
mkdir -p /etc/landscape
echo | openssl s_client -connect "$DC_FQDN:443" -servername "$DC_FQDN" 2>/dev/null \
  | openssl x509 > /etc/landscape/server.pem || die "Could not reach https://$DC_FQDN"
echo "Fingerprint: $(openssl x509 -in /etc/landscape/server.pem -noout -fingerprint -sha256 | cut -d= -f2)"
read -rp "Does it match the one printed at the end of 02-setup-server.sh? [y/N] " ok
[[ "$ok" =~ ^[Yy]$ ]] || { rm -f /etc/landscape/server.pem; die "Certificate not trusted - stopped."; }

log "5/5 Registering with Landscape"
args=(--silent --computer-title "$(hostname)" --account-name standalone
      --url "https://$DC_FQDN/message-system" --ping-url "http://$DC_FQDN/ping"
      --ssl-public-key /etc/landscape/server.pem
      --include-manager-plugins ScriptExecution --script-users ALL)
[[ -n "$REG_KEY" ]] && args+=(--registration-key "$REG_KEY")
landscape-config "${args[@]}"

cat <<EOF

Done: $(hostname) joined $REALM_DNS and registered with Landscape.
 * Accept it: https://$DC_FQDN -> Computers -> pending -> Accept
 * Log in with AD accounts in linux-users / linux-admins, e.g. "alice"
   (desktop login screen: click "Not listed?").
 * Test now:  id <aduser>
EOF
