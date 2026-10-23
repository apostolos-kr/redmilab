# Manual bootstrap

One-time manual steps run **before** handing hosts over to Ansible / GitHub CI/CD.
Ansible assumes: user `admin` exists, passwordless privilege escalation works, host is on the network, and Tailscale (+ SSH) is up.

## 1. postmarketOS phones (`xiaomi-whyred`, `xiaomi-mido`)

### 1.1 Install + USB SSH

1. Flash with `pmbootstrap install`, boot the phone.
2. SSH over USB (default `admin` user).

### 1.2 Passwordless sudo

```sh
sudo --version          # sudo-rs 0.2.15
sudo sh -c 'echo "admin ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/admin'
sudo chmod 440 /etc/sudoers.d/admin
sudo id                 # verify no password prompt
```

### 1.3 Wi-Fi (NetworkManager)

```sh
sudo nmcli device wifi list ifname wlan0
sudo nmcli device wifi connect "$SSID" password "$PASSWORD" ifname wlan0
```

Disable Wi-Fi power saving on the connection (`2` = disable; `0` = default, `1` = ignore, `3` = enable), then reactivate so it takes effect:

```sh
sudo nmcli connection modify "$SSID" wifi.powersave 2
sudo nmcli connection down "$SSID"
sudo nmcli connection up "$SSID"
```

### 1.4 DNS check (before first Tailscale start)

Tailscale expects DNS via openresolv:

```sh
sudo resolvconf -u
cat /etc/resolv.conf
nmcli networking connectivity
```

Expected: connectivity `full` after 1-2 minutes, `/etc/resolv.conf` populated.

### 1.5 Tailscale

```sh
sudo apk update
sudo apk add tailscale tailscale-openrc
sudo rc-update add tailscale default
sudo rc-service tailscale start
sudo tailscale up --ssh
```

Then approve / set tags in the Tailscale admin console.

### 1.6 Battery voltage cap

Cap the charge voltage at 3.9 V per `battery-voltage-limit.md` (whyred:
rebuild + flash `boot.img`; mido: replace the dtb in `/boot`), then verify:

```sh
cat /sys/class/power_supply/qcom-battery/voltage_max_design   # 3900000
```

Do this before the hand-off so the phones never sit at full voltage.

## 2. Netbook (`netbook`, Alpine, `doas`)

### 2.1 Passwordless doas

```sh
doas sh -c 'echo "permit nopass admin" > /etc/doas.d/admin.conf'
doas chmod 440 /etc/doas.d/admin.conf
doas -C /etc/doas.d/admin.conf   # verify config
doas id                          # verify no password prompt
```

Ansible uses `ansible_become_method: community.general.doas` for this host (see `ansible/inventory.yaml`).

### 2.2 Community repos + python3

```sh
doas sed -i 's/^#\(.*\/community\)/\1/' /etc/apk/repositories
doas apk update
doas apk add python3
python3 --version
which python3
```

Python is required for Ansible.

### 2.3 Tailscale

```sh
doas apk update
doas apk add tailscale tailscale-openrc
doas rc-update add tailscale default
doas rc-service tailscale start
doas tailscale up --ssh
```

Then add tags/settings in the Tailscale console.

## 3. Hand-off to Ansible

Once the above is done and secrets have been added to infisical, everything else is automated. Merging to `main`
triggers the `Deploy` workflow (`.github/workflows/deploy.yaml`), which runs
`ansible/site.yaml`. Ansible configures the machines, creates the k3s
cluster, and installs Argo CD. From that point Argo CD manages everything
under `k3s/`.
