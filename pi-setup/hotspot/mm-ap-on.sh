#!/bin/bash
# Switch wlan0 to the MultimeterNode hotspot (hostapd + dnsmasq). Stays on until mm-ap-off.sh or reboot.
# Must run as root. Saved WiFi connections (Tripoli, FIC) are not modified.
set -u

if [ "$(id -u)" -ne 0 ]; then
  echo "Run as root: sudo $0" >&2
  exit 1
fi

echo "Switching wlan0 to MultimeterNode hotspot (192.168.225.1)."
nmcli device disconnect wlan0 2>/dev/null || true
nmcli device set wlan0 managed no
sleep 2
ip addr flush dev wlan0
ip addr add 192.168.225.1/24 dev wlan0
ip link set wlan0 up
iw dev wlan0 set power_save off 2>/dev/null || true
sleep 2

ok=1
systemctl start hostapd
sleep 2
if systemctl is-active --quiet hostapd; then echo "hostapd: OK"; else echo "hostapd: FAILED (journalctl -u hostapd -n 30)"; ok=0; fi
systemctl start dnsmasq
sleep 1
if systemctl is-active --quiet dnsmasq; then echo "dnsmasq: OK"; else echo "dnsmasq: FAILED (journalctl -u dnsmasq -n 30)"; ok=0; fi

if [ "$ok" -eq 1 ]; then
  echo "Hotspot is up: join WiFi 'MultimeterNode', open http://192.168.225.1:5000"
  exit 0
fi
echo "Hotspot failed to start; returning wlan0 to NetworkManager."
/usr/local/bin/mm-ap-off.sh
exit 1
