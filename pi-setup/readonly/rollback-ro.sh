#!/bin/bash
# Undo install-ro.sh without losing any logs.
# Read-only mode must be OFF (no "overlayroot=tmpfs" in cmdline.txt).
# Run: sudo bash /var/backups/mm-ro-<timestamp>/rollback-ro.sh
set -euo pipefail
BK=$(cd "$(dirname "$0")" && pwd)
LOGS=/home/multimeter/pi_multimeter/logs
IMG=/boot/firmware/mmdata/logs.img

[ "$(id -u)" -eq 0 ] || { echo "Run with sudo." >&2; exit 1; }
grep -q 'overlayroot=tmpfs' /proc/cmdline && { echo "Read-only mode is active; turn it off first." >&2; exit 1; }
for f in fstab; do
  [ -e "$BK/$f" ] || { echo "Backup $BK/$f missing" >&2; exit 1; }
done

# 1. Stop the dashboard and release the log storage BEFORE changing anything else.
#    If any other process still has files open there, abort with everything left as it was.
systemctl stop mm-control.service
if mountpoint -q "$LOGS"; then
  if fuser -m "$LOGS" >/dev/null 2>&1; then
    echo "ABORT: these processes still use $LOGS (close them, e.g. a shell 'cd'-ed into it):" >&2
    fuser -vm "$LOGS" >&2 || true
    systemctl start mm-control.service
    exit 1
  fi
  sync
  umount "$LOGS" || { echo "ABORT: could not unmount $LOGS" >&2; systemctl start mm-control.service; exit 1; }
fi

# 2. Remove the dashboard's mount requirement.
rm -f /etc/systemd/system/mm-control.service.d/require-logs.conf
rmdir /etc/systemd/system/mm-control.service.d 2>/dev/null || true

# 3. Unlock the folder underneath, then copy back every log saved on the image (never overwrites).
chown -R multimeter:multimeter "$LOGS"
chmod -R u+w "$LOGS"
chmod 775 "$LOGS"   # original permission of the logs folder
if [ -e "$IMG" ]; then
  TMP=$(mktemp -d)
  mount -o loop,ro "$IMG" "$TMP"
  cp -an "$TMP"/. "$LOGS"/
  umount "$TMP"; rmdir "$TMP"
  chown -R multimeter:multimeter "$LOGS"
  echo "Logs from $IMG copied back to $LOGS. Image kept (delete manually if not needed)."
fi

# 4. Restore fstab.
cp -a "$BK/fstab" /etc/fstab
systemctl daemon-reload
systemctl start mm-control.service

echo "Rolled back. CSV files in $LOGS: $(find "$LOGS" -name '*.csv' | wc -l). mm-control: $(systemctl is-active mm-control)"
echo "Hotspot/WiFi setup unchanged. overlayroot package left installed (inactive)."
