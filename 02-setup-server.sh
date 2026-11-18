#!/usr/bin/env bash
# 02-setup-server.sh - build ONE Ubuntu 22.04/24.04 server as:
#   * Samba Active Directory Domain Controller + DNS   (realm AD.ANKINFO.ONLINE)
#   * Landscape Server (quickstart)                     https://<fqdn>        - device management GUI
#   * Cockpit + "AD Users & Groups" page                https://<fqdn>:9443   - server + AD user GUI
#
# Usage:   sudo bash 02-setup-server.sh
# Override any auto-detected value with env vars, e.g.:
#   sudo DC_IP=192.168.10.237 IFACE=br0 UPSTREAM_DNS=192.168.10.1 bash 02-setup-server.sh
set -euo pipefail

REALM_DNS="${REALM_DNS:-ad.ankinfo.online}"     # AD lives in a sub-domain of ankinfo.online (best practice)
NETBIOS_DOMAIN="${NETBIOS_DOMAIN:-AD}"
HOST_SHORT="${HOST_SHORT:-$(hostname -s)}"       # "ankinfo" -> ankinfo.ad.ankinfo.online
LANDSCAPE_PPA="${LANDSCAPE_PPA:-ppa:landscape/self-hosted-24.04}"
COCKPIT_PORT="${COCKPIT_PORT:-9443}"             # 9090 is used by Landscape itself
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

REALM="${REALM_DNS^^}"
FQDN="${HOST_SHORT}.${REALM_DNS}"
export DEBIAN_FRONTEND=noninteractive
APT_OPTS=(-y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)

log() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
die() { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------- pre-flight
[[ $EUID -eq 0 ]] || die "Run with sudo: sudo bash $0"
. /etc/os-release
case "$VERSION_ID" in 22.04|24.04) ;; *) die "Ubuntu $VERSION_ID - Landscape self-hosted needs 22.04 or 24.04";; esac
[[ -e /var/lib/samba/private/sam.ldb ]] && die "An AD database already exists. Run 01-reset-server.sh first."

IFACE="${IFACE:-$(ip -4 route show default | awk '{print $5; exit}')}"
GATEWAY="${GATEWAY:-$(ip -4 route show default | awk '{print $3; exit}')}"
DC_IP="${DC_IP:-$(ip -4 -o addr show dev "$IFACE" scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)}"
UPSTREAM_DNS="${UPSTREAM_DNS:-$GATEWAY}"
[[ -n "$IFACE" && -n "$DC_IP" && -n "$GATEWAY" ]] || die "Could not detect network. Set IFACE, DC_IP and GATEWAY."

if ip -4 addr show dev "$IFACE" | grep -qE "inet $DC_IP/.* dynamic" && [[ "${ALLOW_DHCP:-0}" != 1 ]]; then
  die "$DC_IP is a DHCP address. A DC needs a fixed IP: set a static IP in netplan, or a DHCP reservation and rerun with ALLOW_DHCP=1."
fi
(( ${#HOST_SHORT} <= 15 )) || die "Hostname '$HOST_SHORT' is longer than 15 characters (NetBIOS limit). Set HOST_SHORT=..."
[[ "${HOST_SHORT^^}" != "$NETBIOS_DOMAIN" ]] || die "Hostname must differ from the NetBIOS domain name '$NETBIOS_DOMAIN'."

MEM_GB=$(awk '/MemTotal/ {printf "%d", $2/1024/1024 + 0.5}' /proc/meminfo)
(( MEM_GB >= 4 )) || [[ "${FORCE:-0}" == 1 ]] || die "Only ${MEM_GB} GB RAM. Landscape needs 4 GB minimum (8 GB recommended). FORCE=1 to ignore."

cat <<EOF

  Domain (realm) : $REALM_DNS  ($REALM, NetBIOS $NETBIOS_DOMAIN)
  This server    : $FQDN
  IP / interface : $DC_IP on $IFACE   gateway $GATEWAY
  Upstream DNS   : $UPSTREAM_DNS   (Samba forwards internet lookups here)
  RAM            : ${MEM_GB} GB
  Landscape      : https://$FQDN
  Cockpit        : https://$FQDN:$COCKPIT_PORT
EOF
read -rp "Correct? [y/N] " ok; [[ "$ok" =~ ^[Yy]$ ]] || die "Cancelled. Override values with env vars (see header)."

while :; do
  read -rsp "Choose the AD Administrator password: " ADMIN_PASS; echo
  read -rsp "Repeat it: " ADMIN_PASS2; echo
  [[ "$ADMIN_PASS" == "$ADMIN_PASS2" ]] || { echo "Passwords differ."; continue; }
  classes=0
  [[ "$ADMIN_PASS" =~ [a-z] ]] && ((classes++)) || true
  [[ "$ADMIN_PASS" =~ [A-Z] ]] && ((classes++)) || true
  [[ "$ADMIN_PASS" =~ [0-9] ]] && ((classes++)) || true
  [[ "$ADMIN_PASS" =~ [^a-zA-Z0-9] ]] && ((classes++)) || true
  (( ${#ADMIN_PASS} >= 8 && classes >= 3 )) && break
  echo "Need 8+ characters using 3 of: lowercase, uppercase, digit, symbol."
done

# ---------------------------------------------------------------- 1. hostname
log "1/9 Hostname -> $FQDN"
hostnamectl set-hostname "$HOST_SHORT"
sed -i -E '/^127\.0\.1\.1[[:space:]]/d' /etc/hosts
sed -i -E "/[[:space:]]${HOST_SHORT}([[:space:]]|\$)/d" /etc/hosts
echo "$DC_IP $FQDN $HOST_SHORT" >> /etc/hosts
if [[ -d /etc/cloud/cloud.cfg.d ]]; then
  printf 'preserve_hostname: true\nmanage_etc_hosts: false\n' > /etc/cloud/cloud.cfg.d/99-ad-dc.cfg
fi
[[ "$(hostname -f)" == "$FQDN" ]] || die "hostname -f returns '$(hostname -f)', expected $FQDN"

# ---------------------------------------------------------------- 2. resolver
log "2/9 Resolver (systemd-resolved off; Samba will own port 53)"
systemctl disable --now systemd-resolved 2>/dev/null || true
if systemctl is-active -q NetworkManager 2>/dev/null; then
  printf '[main]\ndns=none\n' > /etc/NetworkManager/conf.d/90-no-dns.conf
  systemctl reload NetworkManager || true
fi
rm -f /etc/resolv.conf
printf 'nameserver %s\nnameserver 1.1.1.1\n' "$UPSTREAM_DNS" > /etc/resolv.conf
getent hosts archive.ubuntu.com >/dev/null || die "Internet DNS not working via $UPSTREAM_DNS"

# ---------------------------------------------------------------- 3. packages
log "3/9 Updating system and installing Samba / Kerberos"
apt-get update
apt-get "${APT_OPTS[@]}" full-upgrade
echo "krb5-config krb5-config/default_realm string $REALM" | debconf-set-selections
echo "krb5-config krb5-config/add_servers boolean false" | debconf-set-selections
SAMBA_PKGS=(chrony acl attr samba winbind libpam-winbind libnss-winbind krb5-user krb5-config
            dnsutils ldb-tools smbclient python3-setproctitle curl openssl)
for p in samba-ad-dc samba-ad-provision samba-dsdb-modules samba-vfs-modules; do
  apt-cache show "$p" >/dev/null 2>&1 && SAMBA_PKGS+=("$p")      # split packages on 24.04+
done
apt-get "${APT_OPTS[@]}" install "${SAMBA_PKGS[@]}"
systemctl enable --now chrony

# ---------------------------------------------------------------- 4. Landscape
log "4/9 Installing Landscape Server quickstart (takes several minutes)"
apt-get "${APT_OPTS[@]}" install software-properties-common
add-apt-repository -y "$LANDSCAPE_PPA"
apt-get update
apt-get "${APT_OPTS[@]}" install landscape-server-quickstart

# ---------------------------------------------------------------- 5. Cockpit
log "5/9 Installing Cockpit on port $COCKPIT_PORT + AD Users page"
apt-get "${APT_OPTS[@]}" install --no-install-recommends cockpit cockpit-ws cockpit-system cockpit-bridge
mkdir -p /etc/systemd/system/cockpit.socket.d
printf '[Socket]\nListenStream=\nListenStream=%s\n' "$COCKPIT_PORT" > /etc/systemd/system/cockpit.socket.d/listen.conf
if [[ -d "$SCRIPT_DIR/cockpit-ad" ]]; then
  rm -rf /usr/share/cockpit/ad-users
  cp -r "$SCRIPT_DIR/cockpit-ad" /usr/share/cockpit/ad-users
  chmod -R a+rX /usr/share/cockpit/ad-users
else
  echo "WARNING: $SCRIPT_DIR/cockpit-ad not found - AD Users page not installed."
fi
systemctl daemon-reload
systemctl enable --now cockpit.socket
systemctl restart cockpit.socket

# ---------------------------------------------------------------- 6. prepare Samba
log "6/9 Preparing Samba for DC role"
systemctl disable --now smbd nmbd winbind 2>/dev/null || true
systemctl mask smbd nmbd winbind
systemctl unmask samba-ad-dc
[[ -f /etc/samba/smb.conf ]] && mv /etc/samba/smb.conf "/etc/samba/smb.conf.orig.$(date +%s)"
[[ -f /etc/krb5.conf ]] && mv /etc/krb5.conf "/etc/krb5.conf.orig.$(date +%s)"

# ---------------------------------------------------------------- 7. provision
log "7/9 Provisioning domain $REALM"
samba-tool domain provision \
  --server-role=dc --use-rfc2307 --dns-backend=SAMBA_INTERNAL \
  --realm="$REALM" --domain="$NETBIOS_DOMAIN" \
  --host-name="$HOST_SHORT" --host-ip="$DC_IP" \
  --adminpass="$ADMIN_PASS" \
  --option="interfaces=lo $IFACE" \
  --option="bind interfaces only=yes" \
  --option="dns forwarder=$UPSTREAM_DNS"
cp /var/lib/samba/private/krb5.conf /etc/krb5.conf
systemctl enable --now samba-ad-dc

# ---------------------------------------------------------------- 8. DNS -> DC
log "8/9 Waiting for Samba DNS, then pointing this server at itself"
for i in $(seq 1 45); do
  host -t SRV "_ldap._tcp.$REALM_DNS" "$DC_IP" >/dev/null 2>&1 && break
  sleep 2
  (( i == 45 )) && die "Samba DNS did not answer. Check: journalctl -u samba-ad-dc -n 50"
done
printf 'search %s\nnameserver %s\n' "$REALM_DNS" "$DC_IP" > /etc/resolv.conf
host "$FQDN" >/dev/null || die "$FQDN does not resolve via Samba DNS"
host ubuntu.com >/dev/null || echo "WARNING: forwarder $UPSTREAM_DNS not resolving internet names"

# ---------------------------------------------------------------- 9. domain objects
log "9/9 Kerberos test, groups, firewall"
printf '%s\n' "$ADMIN_PASS" | kinit "administrator@$REALM" >/dev/null
klist | grep -q "krbtgt/$REALM" && echo "Kerberos OK"
kdestroy || true
samba-tool user setexpiry administrator --noexpiry
samba-tool group add linux-users  --description="May log in to Ubuntu devices"        2>/dev/null || true
samba-tool group add linux-admins --description="May log in + sudo on Ubuntu devices" 2>/dev/null || true
unset ADMIN_PASS ADMIN_PASS2

if command -v ufw >/dev/null && ufw status | grep -q "Status: active"; then
  ufw allow OpenSSH
  ufw allow 53; ufw allow 88; ufw allow 123/udp; ufw allow 135/tcp; ufw allow 137:138/udp
  ufw allow 139/tcp; ufw allow 389; ufw allow 445/tcp; ufw allow 464; ufw allow 636/tcp
  ufw allow 3268:3269/tcp; ufw allow 49152:65535/tcp
  ufw allow 80/tcp; ufw allow 443/tcp; ufw allow "$COCKPIT_PORT/tcp"
fi

# ---------------------------------------------------------------- summary
LS_CODE=$(curl -sk -o /dev/null -w '%{http_code}' "https://$FQDN/" || echo "fail")
FP=$(echo | openssl s_client -connect "$FQDN:443" -servername "$FQDN" 2>/dev/null \
      | openssl x509 -noout -fingerprint -sha256 2>/dev/null | cut -d= -f2)

cat <<EOF

=====================================================================
 DONE
---------------------------------------------------------------------
 Samba AD DC     : $(systemctl is-active samba-ad-dc)   realm $REALM
 Landscape       : https://$FQDN            (HTTP $LS_CODE)
                   First visit -> create the Landscape admin account.
 Cockpit         : https://$FQDN:$COCKPIT_PORT
                   Log in as '${SUDO_USER:-your admin user}', click "Administrative access",
                   then open "AD Users & Groups" in the left menu.
 Landscape cert SHA256 fingerprint (clients will ask you to confirm it):
   $FP

 Your PC must resolve $FQDN. Either use $DC_IP as its DNS
 server, or add to C:\\Windows\\System32\\drivers\\etc\\hosts:
   $DC_IP  $FQDN

 Next: create users (Cockpit page), then on each Ubuntu device run
   sudo bash 03-join-client.sh $DC_IP
=====================================================================
EOF
