#!/bin/bash
# Rebuild MultimeterNode on the new SD card. Run: sudo bash ~/pi-setup/hotspot/install-newpi.sh
#   - installs hostapd + dnsmasq (left disabled; the hotspot script starts them)
#   - restores the hotspot config (SSID MultimeterNode, 192.168.225.1) and dashboard service
#   - installs field/maintenance boot modes; starts in MAINTENANCE so the next boot stays on Tripoli
# Does not touch: NetworkManager connections, ~/pi_multimeter code or CSVs.
set -euo pipefail

SRC=$(cd "$(dirname "$0")" && pwd)
BK=/var/backups/mm-newpi-$(date +%Y%m%d-%H%M%S)
fail() { echo "ABORT: $*" >&2; exit 1; }

# 0. Pre-checks.
[ "$(id -u)" -eq 0 ] || fail "run with sudo"
for f in mm-ap-on.sh mm-ap-off.sh mm-netselect.sh mm-netselect.service mm-mode mm-control.service dnsmasq.conf hostapd.conf hostapd.default rollback-newpi.sh; do
  [ -s "$SRC/$f" ] || fail "missing $SRC/$f"
done
grep -q '^wpa_passphrase=CHANGE_ME$' "$SRC/hostapd.conf" && fail "set the hotspot password in $SRC/hostapd.conf (wpa_passphrase=)"
[ -x /home/multimeter/pi_multimeter/venv/bin/python ] || fail "dashboard venv missing"
[ -s /home/multimeter/pi_multimeter/app.py ] || fail "dashboard code missing"
for f in /etc/systemd/system/mm-control.service /etc/systemd/system/mm-netselect.service /usr/local/bin/mm-ap-on.sh; do
  [ -e "$f" ] && fail "$f already exists (installer already run?)"
done
journalctl -k -b --no-pager | grep -qiE 'I/O error|EXT4-fs error' && fail "kernel reports storage errors on this card"
echo "Pre-checks OK."

# 1. Back up anything that already exists and will be replaced.
mkdir -p "$BK"
for f in /etc/dnsmasq.conf /etc/default/hostapd /etc/hostapd/hostapd.conf; do
  [ -e "$f" ] && cp -a "$f" "$BK/$(echo "$f" | tr / _)"
done
cp -a "$SRC/rollback-newpi.sh" "$BK"/
echo "Backup: $BK"

# 2. Packages (internet needed).
apt-get install -y hostapd dnsmasq || { apt-get update && apt-get install -y hostapd dnsmasq; }
for p in hostapd dnsmasq; do dpkg -s $p | grep -q '^Status: install ok installed' || fail "$p install failed"; done
# Hotspot services must not start on their own; mm-ap-on.sh starts them when needed.
systemctl stop dnsmasq hostapd 2>/dev/null || true
systemctl unmask hostapd
systemctl disable hostapd dnsmasq

# 3. Hotspot configuration (same as the old Pi).
[ -e /etc/dnsmasq.conf ] && cp -a /etc/dnsmasq.conf "$BK/dnsmasq.conf.package-default"
install -m 644 -o root -g root "$SRC/dnsmasq.conf" /etc/dnsmasq.conf
install -m 644 -o root -g root "$SRC/hostapd.default" /etc/default/hostapd
install -d -m 755 /etc/hostapd
install -m 600 -o root -g root "$SRC/hostapd.conf" /etc/hostapd/hostapd.conf

# 4. Scripts and services.
install -m 755 -o root -g root "$SRC/mm-ap-on.sh" "$SRC/mm-ap-off.sh" "$SRC/mm-netselect.sh" "$SRC/mm-mode" /usr/local/bin/
install -m 644 -o root -g root "$SRC/mm-control.service" "$SRC/mm-netselect.service" /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now mm-control.service
systemctl enable mm-netselect.service
/usr/local/bin/mm-mode maintenance >/dev/null

# 5. Verify.
echo "--- verify ---"
for f in mm-ap-on.sh mm-ap-off.sh mm-netselect.sh mm-mode; do cmp -s "$SRC/$f" /usr/local/bin/$f && echo "$f: installed" || fail "$f mismatch"; done
grep -q 'systemd-run' /usr/local/bin/mm-ap-on.sh && fail "5-minute failsafe present" || echo "5-minute failsafe: absent"
echo "hostapd.conf: $(stat -c '%U:%G %a' /etc/hostapd/hostapd.conf), ssid=$(grep '^ssid=' /etc/hostapd/hostapd.conf | cut -d= -f2)"
echo "hostapd: $(systemctl is-enabled hostapd) / dnsmasq: $(systemctl is-enabled dnsmasq) (both should be disabled)"
sleep 5
echo "mm-control: $(systemctl is-enabled mm-control) / $(systemctl is-active mm-control)"
echo "dashboard: HTTP $(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:5000/)"
echo "mm-netselect: $(systemctl is-enabled mm-netselect)"
/usr/local/bin/mm-mode
nmcli -f NAME,TYPE,DEVICE connection show
echo "Done. Nothing switches until next boot. Rollback: sudo bash $BK/rollback-newpi.sh"
