#!/bin/bash
# Stop the MultimeterNode hotspot and rejoin a saved WiFi network (Tripoli, FIC, ...) without rebooting.
# Every step is logged to /var/log/mm-ap-off.log so a failure can be diagnosed afterwards.
# Must run as root. The reboot-based switch (sudo mm-mode maintenance && sudo reboot) is the reliable fallback.
set -u
LOG=/var/log/mm-ap-off.log
exec > >(tee -a "$LOG") 2>&1

if [ "$(id -u)" -ne 0 ]; then
  echo "Run as root: sudo $0"
  exit 1
fi

state() { nmcli -t -f DEVICE,TYPE,STATE device 2>/dev/null | grep '^wlan0:' ; iw dev wlan0 info 2>/dev/null | grep -E 'type' ; }

echo "=== mm-ap-off $(date) ==="
echo "before: $(state | tr '\n' ' ')"

systemctl stop dnsmasq 2>/dev/null || true
systemctl stop hostapd 2>/dev/null || true
ip addr flush dev wlan0
# hostapd can leave the interface in AP mode; put it back in station mode before NM takes over.
ip link set wlan0 down
iw dev wlan0 set type managed 2>/dev/null || true
ip link set wlan0 up
nmcli device set wlan0 managed yes

# Wait for NetworkManager to see wlan0 as usable again.
for i in $(seq 1 30); do
  s=$(nmcli -t -f DEVICE,STATE device | awk -F: '$1=="wlan0"{print $2}')
  case "$s" in disconnected|connected) break ;; esac
  sleep 1
done
echo "after handover (${i}s): $(state | tr '\n' ' ')"

nmcli device wifi rescan ifname wlan0 2>/dev/null || true
sleep 6

# Try every saved WiFi connection explicitly (Tripoli, FIC, ...).
mapfile -t CONNS < <(nmcli -t -f NAME,TYPE connection show | awk -F: '$2=="802-11-wireless"{print $1}')
echo "saved WiFi connections: ${CONNS[*]}"
for attempt in 1 2 3; do
  for c in "${CONNS[@]}"; do
    if nmcli -w 30 connection up "$c" ifname wlan0 >/dev/null 2>&1; then
      echo "WiFi restored: $c (attempt $attempt)"
      exit 0
    fi
    echo "attempt $attempt: '$c' not available"
  done
  nmcli device wifi rescan ifname wlan0 2>/dev/null || true
  sleep 5
done

echo "ERROR: no saved WiFi network could be joined. State: $(state | tr '\n' ' ')"
exit 1
