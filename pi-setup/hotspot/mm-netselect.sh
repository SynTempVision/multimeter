#!/bin/bash
# Boot-time network choice for MultimeterNode.
#   Field mode (default):      start the MultimeterNode hotspot immediately.
#   Maintenance mode (flag):   try saved WiFi (Tripoli, FIC) for 60 s; if none connects, start the hotspot anyway.
# Switch with: sudo mm-mode field | sudo mm-mode maintenance   (takes effect at next boot)
# Or from a Mac: create/delete an empty file named "mm-maintenance" on the SD card's bootfs.
set -u
FLAG=/boot/firmware/mm-maintenance

if [ -e "$FLAG" ]; then
  WAIT=60
  echo "Maintenance mode: waiting up to ${WAIT}s for saved WiFi."
else
  WAIT=0
  echo "Field mode: starting hotspot."
fi

for ((t = 0; t < WAIT; t += 3)); do
  if nmcli -t -f DEVICE,STATE device 2>/dev/null | grep -qx 'wlan0:connected'; then
    echo "Connected to saved WiFi '$(nmcli -t -f GENERAL.CONNECTION device show wlan0 | cut -d: -f2)'; hotspot not needed."
    exit 0
  fi
  sleep 3
done

[ "$WAIT" -gt 0 ] && echo "No saved WiFi connected after ${WAIT}s; starting hotspot."
exec /usr/local/bin/mm-ap-on.sh
