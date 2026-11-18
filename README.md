# Ubuntu-only device management: Samba AD + Landscape + Cockpit (one server)

| What | Where | Used for |
|---|---|---|
| Samba AD DC + DNS | `mdm-server.ad.ankinfo.online` | Who can log in to Ubuntu devices (users, groups, sudo) |
| Landscape (web GUI) | `https://mdm-server.ad.ankinfo.online` | Devices: inventory, updates, packages, run scripts, alerts |
| Cockpit (web GUI) | `https://mdm-server.ad.ankinfo.online:9443` | Server health + **AD Users & Groups** page (create/disable users, reset passwords, groups, joined computers) |

Realm: `AD.ANKINFO.ONLINE` (AD in the `ad.` sub-domain so it never clashes with the public `ankinfo.online` website/DNS).

## 1. Copy to the server (from Windows PowerShell)

```powershell
cd "$env:USERPROFILE\OneDrive - Optimus Information Inc\Desktop\mdm"
scp -r .\ubuntu-ad-landscape ankinfo@<SERVER_IP>:~/
```

## 2. On the server (`ankinfo@ankinfo:~$`)

```bash
cd ~/ubuntu-ad-landscape
sed -i 's/\r$//' *.sh cockpit-ad/*      # strip Windows line endings, just in case
sudo bash 01-reset-server.sh            # shows what will be wiped, type WIPE to confirm
sudo bash 02-setup-server.sh            # ~15-30 min; asks for the AD Administrator password
```

The server needs a **fixed IP**, Ubuntu **22.04 or 24.04**, and 8 GB RAM recommended (4 GB min).
Auto-detected values can be overridden: `sudo DC_IP=192.168.10.237 IFACE=br0 UPSTREAM_DNS=192.168.10.1 bash 02-setup-server.sh`

Save the **certificate fingerprint** printed at the end.

## 3. First login to the GUIs

Your PC must resolve the server name: set its DNS to the server IP, or add a hosts entry
(`C:\Windows\System32\drivers\etc\hosts`, as admin): `<SERVER_IP>  mdm-server.ad.ankinfo.online`

1. **Landscape** - `https://mdm-server.ad.ankinfo.online` - accept the self-signed cert, create the Landscape admin account.
2. **Cockpit** - `https://mdm-server.ad.ankinfo.online:9443` - log in as `optimus`, click **Limited access -> Administrative access**, open **AD Users & Groups**. Create users there and put them in:
   - `linux-users` - can log in to Ubuntu devices
   - `linux-admins` - can log in + `sudo`

## 4. On every Ubuntu device

```bash
scp ankinfo@<SERVER_IP>:~/ubuntu-ad-landscape/03-join-client.sh .
sudo bash 03-join-client.sh <SERVER_IP>
```

It asks for the AD `administrator` password and to confirm the certificate fingerprint. Then in
Landscape: **Computers -> pending -> Accept**. Device hostnames must be unique and 15 characters max.

## Day-to-day

| Task | Where |
|---|---|
| New employee / leaver / password reset | Cockpit -> AD Users & Groups |
| Give or remove sudo | Add/remove user in `linux-admins` |
| Patch all devices, install software, run a script on many devices | Landscape (use tags to group devices) |
| Remove a device | Landscape (remove computer) + Cockpit -> Computers -> Remove from domain |

## Notes

- Windows PCs are not part of this setup; only Ubuntu devices are joined/managed.
- Group-policy-style settings for Ubuntu (adsys) need Ubuntu Pro; not configured here.
- Running Landscape on the DC is fine for a small org; for growth move Landscape to its own VM and add a second DC.
- Backups: `sudo samba-tool domain backup offline --targetdir=/root/ad-backups` (schedule it with cron).
