# Pi field setup - hotspot, boot modes, read-only (RAM OS)

How the Pi Zero W `multimeter` is set up for field use (built 2026-10-17 on a
new SD card after the original card failed). Everything here is installed on
the live Pi; these are the reviewed copies.

## What it does

- **Field mode (default):** at boot the Pi broadcasts its own WiFi hotspot
  `MultimeterNode` at `192.168.225.1` (hostapd + dnsmasq, DHCP
  `.50-.99`). Dashboard: `http://192.168.225.1:5000`.
- **Maintenance mode:** at boot it tries the saved WiFi (FIC, home) for 60 s;
  if none connects it starts the hotspot anyway, so it is never unreachable.
- **Read-only (RAM OS):** the system runs from RAM, so pulling the power
  cannot corrupt it. CSV logs are written to a separate ext4 image
  (`/boot/firmware/mmdata/logs.img`, 64 MB, mounted `sync`) that survives
  power loss. Tested by pulling the plug: the dummy CSV survived and a file
  written to the system area vanished.
- The dashboard (`mm-control.service`) refuses to start unless that log image
  is mounted, so logs can never silently go to RAM.

## Switching modes

```
mm-mode                          # show mode at next boot
sudo mm-mode field && sudo reboot
sudo mm-mode maintenance && sudo reboot
```
No SSH? Put the SD card in a computer: an empty file named `mm-maintenance`
on the `bootfs` partition = maintenance mode; delete it = field mode.

SSH while on the hotspot: `ssh multimeter@192.168.225.1`.

## Changing code or settings (read-only is on)

Changes made while read-only is on are lost at the next reboot. Turn it off,
make the change, turn it back on:

```
# off
sudo mount -o remount,rw /boot/firmware
sudo sed -i 's/^overlayroot=tmpfs:recurse=0 //' /boot/firmware/cmdline.txt
sudo reboot
# ...scp files, sudo systemctl restart mm-control.service, test...
# on again
sudo sed -i 's/^/overlayroot=tmpfs:recurse=0 /' /boot/firmware/cmdline.txt
sudo reboot
```
Or with the SD card in a computer: edit `bootfs/cmdline.txt` and remove /
re-add `overlayroot=tmpfs:recurse=0 ` at the very start of the line.

## Rebuilding on a new SD card

1. Raspberry Pi Imager: Raspberry Pi OS Lite (32-bit), hostname `multimeter`,
   user `multimeter`, SSH on, WiFi FIC. Add your SSH key and any other WiFi
   networks in `user-data` / `network-config` on `bootfs` before first boot.
2. Copy the dashboard to `~/pi_multimeter/` (`app.py`, `thermocouple_k.py`,
   `templates/`, `requirements.txt`, plus the `logs/` folder from a backup),
   then build the venv:
   ```
   cd ~/pi_multimeter && python3 -m venv venv && venv/bin/pip install -r requirements.txt
   ```
3. Copy this `pi-setup/` folder to `~/pi-setup/`. Set the hotspot password in
   `hotspot/hostapd.conf` (`wpa_passphrase=`; the installer refuses
   `CHANGE_ME`). Then, with internet:
   ```
   sudo bash ~/pi-setup/hotspot/install-newpi.sh     # leaves Pi in maintenance mode
   sudo reboot                                       # should rejoin WiFi
   sudo bash ~/pi-setup/readonly/install-ro.sh       # log image + overlayroot package
   sudo reboot                                       # check logs are mounted
   ```
4. Turn read-only on with the `sed` "on again" line above (not raspi-config,
   see gotchas), reboot, then `sudo mm-mode field`.

Rollbacks (read-only must be off first):
`sudo bash /var/backups/mm-ro-<timestamp>/rollback-ro.sh`, then
`sudo bash /var/backups/mm-newpi-<timestamp>/rollback-newpi.sh`.

## Cloning a card for a second Pi (MultimeterNode2)

A straight copy of the card would broadcast the same hotspot name and use the
same hostname, machine-id and SSH host keys as the original. `clone/mm-rename.sh`
fixes that on the clone's first boot, with no SSH needed:

1. Write the backup image to the new card (`gunzip -c <image>.img.gz | sudo dd of=/dev/rdiskN bs=4m`).
2. On the clone's `bootfs`:
   - copy `clone/mm-rename.sh` to `bootfs/mm-rename.sh`
   - copy `cmdline.txt` to `cmdline.final` (the normal read-only boot line)
   - in `cmdline.txt`, remove the leading `overlayroot=tmpfs:recurse=0 ` and
     append `systemd.run=/boot/firmware/mm-rename.sh systemd.run_success_action=reboot systemd.unit=kernel-command-line.target`
3. Boot it. It restores `cmdline.final` first, renames the hotspot to
   `MultimeterNode2` and the host to `multimeter2`, regenerates machine-id and
   SSH host keys, disables cloud-init (which would rename it back), disables
   itself (`mm-rename.sh.done`) and reboots into field mode with read-only on.
   Log: `bootfs/mm-rename.log`. About 5 minutes.

For a third Pi, change `MultimeterNode2` / `multimeter2` in the script.
The hotspot address stays `192.168.225.1` (each Pi is its own network).

## Gotchas found the hard way

- **Use `overlayroot=tmpfs:recurse=0`, not plain `overlayroot=tmpfs`.** The
  default (`recurse=1`) also puts the log image mount under a RAM overlay, so
  new CSVs would be lost at power-off while everything looks normal.
- **`raspi-config nonint do_overlayfs 0` also makes `/boot/firmware`
  read-only** (adds `,ro` in `/etc/fstab`), which breaks `mm-mode` and the
  log image. It also can't turn off the `recurse=0` form. Edit
  `cmdline.txt` directly instead.
- `overlayroot-chroot` fails on this setup (it can't remount the read-only
  log image). To edit the real root while read-only is on:
  `sudo mount -o remount,rw /media/root-ro`, edit under `/media/root-ro/`,
  `sync`, reboot.
- `systemd-remount-fs.service` shows as failed under read-only. Harmless.
- No RTC and no internet in the field: the Pi's clock is wrong, so CSV
  **filenames** have the wrong date/time. Row timestamps come from the
  phone's browser and are correct.
- Pi Zero W's micro-USB "USB" port is data (meter via OTG); "PWR" is power.
- Worn/used SD cards fail silently (writes read back as garbage). The
  installers refuse to run if the kernel has logged storage errors.
