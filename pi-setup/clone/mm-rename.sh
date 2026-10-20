#!/bin/bash
# One-time first-boot rename of the cloned card: MultimeterNode -> MultimeterNode2, multimeter -> multimeter2.
# Started by systemd.run= in cmdline.txt (RAM OS temporarily off). On success the Pi reboots
# into the normal setup (RAM OS on, field mode). Log: /boot/firmware/mm-rename.log
set -u
B=/boot/firmware
exec >>"$B/mm-rename.log" 2>&1
echo "=== $(date) mm-rename start"
fail() { echo "FAILED: $*"; sync; exit 1; }

# 1. Put the normal boot line back FIRST, so the next boot is normal whatever happens below.
cp "$B/cmdline.final" "$B/cmdline.txt" && sync
cmp -s "$B/cmdline.final" "$B/cmdline.txt" || fail "could not restore cmdline.txt"
grep -q systemd.run "$B/cmdline.txt" && fail "cmdline.txt still has systemd.run"
echo "cmdline.txt restored: $(cat "$B/cmdline.txt")"

# 2. Hotspot name (only if not already renamed, so a re-run can't make MultimeterNode22).
if grep -qx 'ssid=MultimeterNode' /etc/hostapd/hostapd.conf; then
  sed -i 's/^ssid=MultimeterNode$/ssid=MultimeterNode2/' /etc/hostapd/hostapd.conf
  # Messages in the helper scripts that name the hotspot
  sed -i 's/MultimeterNode\b/MultimeterNode2/g' \
    /usr/local/bin/mm-ap-on.sh /usr/local/bin/mm-ap-off.sh /usr/local/bin/mm-netselect.sh \
    /usr/local/bin/mm-mode /etc/systemd/system/mm-netselect.service
fi
grep -qx 'ssid=MultimeterNode2' /etc/hostapd/hostapd.conf || fail "hotspot name not changed"
echo "hotspot: $(grep '^ssid=' /etc/hostapd/hostapd.conf)"

# 3. Hostname (cloud-init is turned off below so it can't set it back to "multimeter").
echo multimeter2 > /etc/hostname
sed -i -E 's/^(127\.0\.1\.1\s+)multimeter(\s|$)/\1multimeter2\2/' /etc/hosts
grep -qE '^127\.0\.1\.1\s+multimeter2(\s|$)' /etc/hosts || echo "127.0.1.1 multimeter2" >> /etc/hosts
[ -e "$B/user-data" ] && sed -i 's/^hostname: "multimeter"$/hostname: "multimeter2"/' "$B/user-data"
touch /etc/cloud/cloud-init.disabled
echo "hostname: $(cat /etc/hostname); hosts: $(grep '^127.0.1.1' /etc/hosts)"

# 4. New identity so the two Pis don't look like the same machine on FIC/home WiFi.
tr -d '-' < /proc/sys/kernel/random/uuid > /etc/machine-id
[ -f /var/lib/dbus/machine-id ] && [ ! -L /var/lib/dbus/machine-id ] && cp /etc/machine-id /var/lib/dbus/machine-id
rm -f /etc/ssh/ssh_host_*
ssh-keygen -A || fail "ssh host keys not regenerated"
echo "machine-id: $(cat /etc/machine-id); ssh keys: $(ls /etc/ssh/ssh_host_*_key | wc -l)"

# 5. Done: disable this script so it can never run again, then reboot (systemd.run_success_action).
mv "$B/mm-rename.sh" "$B/mm-rename.sh.done"
sync
echo "=== $(date) mm-rename DONE, rebooting into MultimeterNode2 (RAM OS on, field mode)"
sync
exit 0
