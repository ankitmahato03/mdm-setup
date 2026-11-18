#!/usr/bin/env bash
# 01-reset-server.sh - wipe the previous Samba AD / Landscape / libvirt build from this server.
#
# Removes: Samba + Kerberos, Landscape (server/client), PostgreSQL, RabbitMQ, Apache, libvirt/QEMU
# and ALL their VMs, Cockpit, SSSD/realmd, dnsmasq, bind9, Docker - packages, config and data.
# Keeps:   the OS, your user accounts and home directories, SSH, and the network config (netplan).
#
# Usage:   sudo bash 01-reset-server.sh
set -euo pipefail

die() { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }
log() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }

[[ $EUID -eq 0 ]] || die "Run with sudo: sudo bash $0"

PKG_RE='^(samba|samba-.*|winbind|libpam-winbind|libnss-winbind|libpam-krb5|krb5-user|krb5-config|krb5-kdc|krb5-admin-server|landscape-.*|postgresql|postgresql-.*|rabbitmq-server|apache2|apache2-.*|libapache2-mod-.*|libvirt-daemon.*|libvirt-clients|qemu-system.*|qemu-kvm|qemu-utils|virtinst|virt-manager|cockpit|cockpit-.*|sssd|sssd-.*|realmd|adcli|bind9|dnsmasq|isc-dhcp-server|nginx|nginx-.*|haproxy|docker.io|docker-ce|docker-ce-cli|containerd|containerd.io)$'

mapfile -t PKGS < <(dpkg-query -W -f='${db:Status-Abbrev} ${Package}\n' 2>/dev/null \
  | awk '$1 ~ /^(ii|rc|iU|iF|iH)$/ {print $2}' | sed 's/:.*//' | grep -E "$PKG_RE" | sort -u || true)

VMS=()
if command -v virsh >/dev/null 2>&1; then
  mapfile -t VMS < <(virsh list --all --name 2>/dev/null | sed '/^$/d' || true)
fi

log "This will be DELETED"
echo "Virtual machines (with their disks): ${VMS[*]:-none}"
echo "Packages to purge (${#PKGS[@]}):"
printf '  %s\n' "${PKGS[@]:-none}"

if ((${#PKGS[@]})); then
  echo
  echo "apt will also remove these dependants:"
  SIM=$(apt-get -s purge "${PKGS[@]}" 2>/dev/null | awk '/^Purg|^Remv/ {print $2}' | sort -u)
  comm -13 <(printf '%s\n' "${PKGS[@]}") <(printf '%s\n' "$SIM") | sed 's/^/  /'
  # Safety net: never take out the OS, SSH or networking.
  if grep -qE '^(openssh-server|sudo|systemd|netplan.io|ubuntu-minimal|ubuntu-server|linux-image-.*)$' <<<"$SIM"; then
    die "Purge would remove a core package (see list above). Aborting - nothing was changed."
  fi
fi

echo
echo "Kept: OS, user accounts + home directories, SSH, netplan network config."
read -rp "Type WIPE to continue: " ans
[[ "$ans" == "WIPE" ]] || die "Cancelled - nothing was changed."

if ((${#VMS[@]})); then
  log "Destroying VMs"
  for vm in "${VMS[@]}"; do
    virsh destroy "$vm" 2>/dev/null || true
    virsh undefine "$vm" --remove-all-storage --nvram 2>/dev/null \
      || virsh undefine "$vm" --remove-all-storage 2>/dev/null || true
    echo "  removed $vm"
  done
  virsh net-destroy default 2>/dev/null || true
fi

log "Stopping services"
for s in samba-ad-dc smbd nmbd winbind sssd landscape-client apache2 rabbitmq-server postgresql \
         libvirtd virtqemud dnsmasq bind9 named cockpit.socket docker containerd; do
  systemctl disable --now "$s" 2>/dev/null || true
done
pkill -f '^/usr/bin/landscape' 2>/dev/null || true

if ((${#PKGS[@]})); then
  log "Purging packages"
  DEBIAN_FRONTEND=noninteractive apt-get purge -y "${PKGS[@]}"
  DEBIAN_FRONTEND=noninteractive apt-get autoremove --purge -y
fi

log "Removing snaps"
for s in landscape-outbox landscape-client landscape-server; do
  snap list "$s" >/dev/null 2>&1 && snap remove --purge "$s" || true
done

log "Deleting leftover config and data"
rm -rf /etc/samba /var/lib/samba /var/cache/samba /var/log/samba /run/samba \
       /etc/krb5.conf /etc/krb5.keytab \
       /etc/landscape /var/lib/landscape /var/log/landscape /opt/canonical/landscape \
       /etc/postgresql /var/lib/postgresql /var/log/postgresql \
       /etc/rabbitmq /var/lib/rabbitmq /var/log/rabbitmq \
       /etc/apache2 /var/log/apache2 \
       /etc/libvirt /var/lib/libvirt /var/log/libvirt \
       /etc/sssd /var/lib/sss /etc/realmd.conf \
       /etc/cockpit /usr/share/cockpit/ad-users /etc/systemd/system/cockpit.socket.d \
       /var/lib/docker /var/lib/containerd \
       /etc/ssl/certs/landscape_server* /etc/ssl/private/landscape_server*
rm -f /etc/apt/sources.list.d/landscape-*  /etc/apt/sources.list.d/*landscape*
systemctl daemon-reload

# The old netplan config may point DNS at this server itself (old Samba). That is gone now,
# so use the default gateway until 02-setup-server.sh configures DNS properly.
log "Setting temporary DNS"
GW=$(ip -4 route show default | awk '{print $3; exit}')
systemctl disable --now systemd-resolved 2>/dev/null || true
rm -f /etc/resolv.conf
printf 'nameserver %s\nnameserver 1.1.1.1\n' "${GW:-1.1.1.1}" > /etc/resolv.conf
getent hosts archive.ubuntu.com >/dev/null && echo "DNS OK" || echo "WARNING: DNS lookups failing - check network"

log "Reset complete. Manually installed packages still on the system (review if you want):"
apt-mark showmanual | column -c 120 || true
echo
echo "Next: sudo bash 02-setup-server.sh   (a reboot first is fine but not required)"
