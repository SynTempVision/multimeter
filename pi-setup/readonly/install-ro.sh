#!/bin/bash
# Persistent log storage for read-only (RAM OS) mode. Run: sudo bash ~/pi-setup/readonly/install-ro.sh
#   - persistent log storage: ext4 image on the boot partition, mounted over the logs folder
#   - mm-control may only run while that storage is mounted (drop-in; unit file and code unchanged)
#   - installs the overlayroot package but does NOT enable read-only mode
# Does not touch: hotspot/WiFi setup, NetworkManager connections, mm-control.service unit file, dashboard code, existing CSVs.
set -euo pipefail

SRC=$(cd "$(dirname "$0")" && pwd)
BK=/var/backups/mm-ro-$(date +%Y%m%d-%H%M%S)
LOGS=/home/multimeter/pi_multimeter/logs
IMGDIR=/boot/firmware/mmdata
IMG=$IMGDIR/logs.img
IMG_MB=64
DROPIN_DIR=/etc/systemd/system/mm-control.service.d
FSTAB_LINE="$IMG  $LOGS  ext4  loop,sync,noatime,nofail,x-systemd.requires-mounts-for=/boot/firmware  0  0"

fail() { echo "ABORT: $*" >&2; exit 1; }

# 0. Pre-checks (nothing is changed if any of these fail).
[ "$(id -u)" -eq 0 ] || fail "run with sudo"
for f in require-logs.conf rollback-ro.sh; do
  [ -s "$SRC/$f" ] || fail "missing $SRC/$f"
done
grep -q 'overlayroot=tmpfs' /proc/cmdline && fail "read-only mode is active"
journalctl -k -b --no-pager | grep -qiE 'I/O error|EXT4-fs error' && fail "kernel reports storage errors on this card"
[ -d "$LOGS" ] || fail "missing $LOGS"
mountpoint -q "$LOGS" && fail "$LOGS is already a mount point"
[ -e "$IMG" ] && fail "$IMG already exists"
grep -q "$IMG" /etc/fstab && fail "fstab already has a logs.img entry"
[ -e "$DROPIN_DIR/require-logs.conf" ] && fail "drop-in already installed"
BOOT_FREE_MB=$(df -m --output=avail /boot/firmware | tail -1 | tr -d ' ')
[ "$BOOT_FREE_MB" -ge $((IMG_MB + 100)) ] || fail "boot partition has ${BOOT_FREE_MB} MB free; need $((IMG_MB + 100))"
ROOT_FREE_MB=$(df -m --output=avail / | tail -1 | tr -d ' ')
[ "$ROOT_FREE_MB" -ge 500 ] || fail "root partition has ${ROOT_FREE_MB} MB free; need 500 for overlayroot install"
LOGS_KB=$(du -sk "$LOGS" | cut -f1)
[ "$LOGS_KB" -lt $((IMG_MB * 1024 / 2)) ] || fail "existing logs (${LOGS_KB} KB) too large for a ${IMG_MB} MB image"
echo "Space OK: boot ${BOOT_FREE_MB} MB free, root ${ROOT_FREE_MB} MB free, logs ${LOGS_KB} KB"

# 1. Backups.
mkdir -p "$BK"
cp -a /etc/fstab "$BK"/
tar -C /home/multimeter/pi_multimeter -czf "$BK/logs-before.tgz" logs
cp -a "$SRC/rollback-ro.sh" "$BK"/
CSV_BEFORE=$(find "$LOGS" -name '*.csv' | wc -l)
echo "Backup: $BK ($(tar -tzf "$BK/logs-before.tgz" | grep -c '\.csv$') of $CSV_BEFORE CSV files archived)"

# 2. overlayroot package (internet needed; first, so a failure leaves everything else unchanged).
if ! dpkg -s overlayroot >/dev/null 2>&1; then
  echo "Installing overlayroot (rebuilds initramfs; several minutes on a Pi Zero)..."
  apt-get install -y overlayroot || { apt-get update && apt-get install -y overlayroot; }
fi
dpkg -s overlayroot | grep -q '^Status: install ok installed' || fail "overlayroot install failed"
grep -q 'overlayroot=tmpfs' /boot/firmware/cmdline.txt && fail "cmdline.txt unexpectedly has overlayroot=tmpfs"
echo "overlayroot: installed; read-only mode NOT enabled"

# 3. Log image: create, copy existing logs, verify.
mkdir -p "$IMGDIR"
dd if=/dev/zero of="$IMG" bs=1M count=$IMG_MB status=none
sync
mkfs.ext4 -q -F -L mmlogs -m 0 "$IMG"
TMP=$(mktemp -d)
mount -o loop "$IMG" "$TMP"
cp -a "$LOGS"/. "$TMP"/
chown multimeter:multimeter "$TMP"
chmod 775 "$TMP"
diff -r -x lost+found "$LOGS" "$TMP" >/dev/null || { umount "$TMP"; fail "copy verification failed"; }
umount "$TMP"; rmdir "$TMP"
echo "Existing logs copied into $IMG and verified."

# 4. Lock the folder underneath the mount (belt and braces): if the image is ever not mounted,
#    nothing can be written there. Original files stay in place, readable, as a fallback copy.
chown -R root:root "$LOGS"
chmod -R a-w "$LOGS"

# 5. Mount at boot; dashboard requires it.
echo "$FSTAB_LINE" >> /etc/fstab
install -d -m 755 "$DROPIN_DIR"
install -m 644 "$SRC/require-logs.conf" "$DROPIN_DIR/require-logs.conf"
systemctl daemon-reload
mount "$LOGS"
systemctl restart mm-control.service   # picks up the new requirement; code unchanged

# 6. Verify.
echo "--- verify ---"
findmnt -n -o SOURCE,TARGET,FSTYPE,OPTIONS "$LOGS" || fail "logs not mounted"
CSV_AFTER=$(find "$LOGS" -name '*.csv' | wc -l)
[ "$CSV_AFTER" -eq "$CSV_BEFORE" ] || fail "CSV count changed: $CSV_BEFORE -> $CSV_AFTER"
echo "CSV files on persistent storage: $CSV_AFTER (same as before)"
sudo -u multimeter sh -c "echo test > '$LOGS/.write-test' && rm '$LOGS/.write-test'" && echo "dashboard user can write to mounted storage: OK"
echo "log image free: $(df -h --output=avail "$LOGS" | tail -1 | tr -d ' ')"
echo "mm-control requires: $(systemctl show mm-control -p RequiresMountsFor --value)"
echo "mm-control: $(systemctl is-active mm-control)"
echo "$(/usr/local/bin/mm-mode)"
nmcli -f NAME,TYPE,DEVICE connection show
echo "Done. Read-only mode NOT enabled. Nothing switches until next boot."
echo "Rollback: sudo bash $BK/rollback-ro.sh"
