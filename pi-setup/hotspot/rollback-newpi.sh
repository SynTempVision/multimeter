#!/bin/bash
# Undo install-newpi.sh. Leaves ~/pi_multimeter (code + CSVs) and WiFi connections untouched.
# Run: sudo bash /var/backups/mm-newpi-<timestamp>/rollback-newpi.sh
set -uo pipefail
BK=$(cd "$(dirname "$0")" && pwd)
[ "$(id -u)" -eq 0 ] || { echo "Run with sudo." >&2; exit 1; }

systemctl disable --now mm-netselect.service mm-control.service 2>/dev/null
systemctl stop hostapd dnsmasq 2>/dev/null
nmcli device set wlan0 managed yes 2>/dev/null
rm -f /etc/systemd/system/mm-netselect.service /etc/systemd/system/mm-control.service
rm -f /usr/local/bin/mm-ap-on.sh /usr/local/bin/mm-ap-off.sh /usr/local/bin/mm-netselect.sh /usr/local/bin/mm-mode
rm -f /boot/firmware/mm-maintenance /etc/hostapd/hostapd.conf
[ -e "$BK/dnsmasq.conf.package-default" ] && cp -a "$BK/dnsmasq.conf.package-default" /etc/dnsmasq.conf
[ -e "$BK/_etc_default_hostapd" ] && cp -a "$BK/_etc_default_hostapd" /etc/default/hostapd
systemctl daemon-reload
echo "Rolled back. hostapd/dnsmasq packages left installed (disabled). Code and CSVs untouched."
nmcli -f NAME,TYPE,DEVICE connection show
