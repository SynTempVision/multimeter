# OWON XDM1241 - Pi Zero W standalone control

Replaces svhelp's `multimeter.php` + `mm_bridge.py`. That setup existed because
the meter used to be plugged into whichever laptop happened to be nearby, so
the web page had to reach it over the network via a serial<->TCP bridge. Now
the meter is plugged directly into this Pi, so the Pi can just talk to it over
serial itself - no bridge, no laptop in the middle.

Real use case: K-type thermocouple probes clipped onto bare wire on actual
elements, NOT a dedicated thermocouple-probe plug. That means the real cold
junction is at the probe clips, not the meter's own input terminals - so the
meter's built-in KITS90 compensation (which only knows its own terminal
temperature) is the wrong tool for the main measurement. See "Thermocouple
math" below.

## Hardware

- Pi Zero **W** (original, ARMv6) - runs Raspberry Pi OS Lite (32-bit),
  Debian 13 "Trixie" based. There's no 64-bit build for this board.
- The meter's rear port is USB-B; the Pi Zero has no USB-A port at all - you
  need a **Micro-USB OTG adapter** (Micro-USB male -> USB-A female) plugged
  into the port labeled **"USB"** (not "PWR IN" - that one's power-only and
  carries no data).
- The Pi still needs its own separate power into "PWR IN" - the OTG/data port
  does not supply power while acting as a USB host.
- CH340 USB-serial chip inside the meter (VID/PID `0x1A86`/`0x7523`), 115200
  baud. `find_meter()` in `app.py` probes CH340-matching ports first, then
  falls back to every other serial port, sending `*IDN?` and checking for
  "OWON"/"XDM" in the reply.

## Network

- Host: `multimeter@172.17.17.130` (hostname `multimeter`) on the "FIC"
  WiFi, NetworkManager-managed (`netplan-wlan0-FIC` connection profile).
  A home WiFi profile is also saved for maintenance.
- **Field use:** the Pi broadcasts its own hotspot `MultimeterNode`
  (WPA2, static `192.168.225.1/24`, DHCP from dnsmasq) at every boot by
  default - dashboard at `http://192.168.225.1:5000`. Hotspot and client
  WiFi are exclusive (one `wlan0` radio).
- Boot behavior is switched with `sudo mm-mode field|maintenance` + reboot
  (maintenance = join FIC/home WiFi if in range, else hotspot). The root
  filesystem is **read-only (RAM OS)** so the Pi can be unplugged at any
  time; CSV logs go to a separate persistent image. Full details, rebuild
  steps and gotchas: [`pi-setup/README.md`](pi-setup/README.md).

## Running it

Deployed files live at `~/pi_multimeter/` on the Pi. **Read-only mode is
on**, so turn it off first or the change is lost at the next reboot (see
[`pi-setup/README.md`](pi-setup/README.md#changing-code-or-settings-read-only-is-on)).
After editing locally, push with `scp` and restart the service:
```
scp "C:\Users\synte\sandbox\OWON-XDM1241\pi_multimeter\templates\index.html" multimeter@172.17.17.130:~/pi_multimeter/templates/index.html
scp "C:\Users\synte\sandbox\OWON-XDM1241\pi_multimeter\app.py" multimeter@172.17.17.130:~/pi_multimeter/app.py
```
```
ssh multimeter@172.17.17.130
sudo systemctl restart mm-control.service
```

Runs as a systemd service (`mm-control.service`, `/etc/systemd/system/`) -
starts on boot, restarts on crash (`Restart=always`), survives the SSH
session that started it closing:
```ini
[Unit]
Description=OWON XDM1241 multimeter control
After=network.target

[Service]
ExecStart=/home/multimeter/pi_multimeter/venv/bin/python /home/multimeter/pi_multimeter/app.py
WorkingDirectory=/home/multimeter/pi_multimeter
Restart=always
RestartSec=2
User=multimeter

[Install]
WantedBy=multi-user.target
```
```
sudo systemctl daemon-reload
sudo systemctl enable --now mm-control.service
systemctl status mm-control.service          # check it's up
journalctl -u mm-control.service -f          # tail logs
```

Open `http://172.17.17.130:5000/` from any browser on the LAN (or
`http://192.168.225.1:5000` on the `MultimeterNode` hotspot).

The page sends `Cache-Control: no-store` on every response - it gets edited
and redeployed constantly during development, and a stale cached page after
a fix looks exactly like the fix "not working."

## Architecture

**`app.py`** (Flask) - owns the one serial connection to the meter via a
`Meter` class with a single `threading.Lock` around every method, so no two
requests ever talk to the hardware at once. Routes:
- `GET /` - serves `templates/index.html`
- `POST /idn` - `*IDN?`, read-only, not session-gated
- `POST /current-mode` - `FUNC?`, read-only, not session-gated
- `POST /calibrate-cjc` - briefly switches the meter to its own internal
  KITS90 mode, takes one reading, switches back to `VOLT:DC`. Only valid
  with the probe tips shorted together (see "Thermocouple math")
- `POST /configure` - starts a session, sends the mode's `CONFigure:...`
  command
- `POST /measure` - `MEAS1?`, requires the caller's session token
- `POST /stop` - releases a session
- `GET /folder-count?folder=X` - how many `.csv` files already exist in that
  log folder
- `POST /commit` - writes the browser's buffered readings to a CSV under
  `~/pi_multimeter/logs/<folder>/`, folder name sanitized server-side
  (`safe_folder_name()`) against path traversal

**Session-based exclusivity** - the reason this isn't a straight port of the
old PHP page. In the old version, every configure/measure click was an
independent HTTP request with the bridge's lock released in between - a
second user's configure could silently land mid-sequence, with the first
user's next measurement succeeding but reporting the wrong mode's reading
under the original label. No error, just wrong data (found in a 2026-10-15
code review of `multimeter.php`/`mm_bridge.py`).

Here, `/configure` creates a session token and holds it; `/measure` requires
that exact token. A session auto-expires after `SESSION_IDLE_TIMEOUT` (10s)
of no activity.

**The live display runs continuously** ("video" model, 2026-10-16) - once
the meter's found, the frontend's `livePollLoop()` polls `/measure` forever
at the meter's fastest rate, updating the live mV/temp display every tick.
Start Log/Stop Log don't start or stop this loop - they just flip a
`logging` flag that gates whether a given tick's reading also gets
snapshotted into the table/chart/CSV buffer ("Interval (s)" controls only
*that* snapshot cadence, not the display's own polling rate). Save writes
the buffered snapshots to a CSV and clears the buffer, so the next reading
starts a fresh log rather than appending forever.

**SCPI commands** (all found by live empirical testing against the real
meter, none documented for this exact model elsewhere):
- `*IDN?`, `MEAS1?`, `CONFigure:<mode>` (no reply) all work as expected.
- `FUNC?` reports current mode as a quoted string (`"VOLT"`, `"CURR"`,
  `"RES"`, `"CAP"`, `"FREQ"`, `"DIOD"`, `"CONT"`, `"TEMP"`, etc). `RES` is
  returned for both 2-wire and 4-wire resistance - genuinely
  indistinguishable from this query alone.
- `MEASure:<anything>?` is a firmware red herring - always just echoes
  `MEAS1?` for the current mode, ignoring the subcommand text entirely.
- `CONFigure:TEMP:RTD KITS90` (fuller form:
  `CONFigure:TEMPerature:RTD KITS90` / `TEMPerature:RTD:UNIT C`) is a real
  internal K-type-with-cold-junction-compensation mode. With the probe tips
  shorted (no real thermocouple EMF), it reports the meter's own terminal
  temperature - validated differentially against `PT100` mode (which
  correctly overloads on a 0ohm short, since that's invalid for a real RTD
  curve, while KITS90 gives a plausible room-temp reading).

## Thermocouple math

`thermocouple_k.py` (ported to JS as `ThermocoupleK` inside `index.html`) -
real NIST ITS-90 Type K forward (C->mV) and inverse (mV->C) polynomials,
pulled from `its90.nist.gov` and cross-validated digit-for-digit against the
independent `thermocouples_reference_devel` package. Not typed from memory -
a transcription error here would silently produce a wrong temperature every
time.

`compensated_temp_c(measured_mv, reference_junction_temp_c)` is the actual
cold-junction compensation: `measured_mv` comes straight off the probes
(`CONFigure:VOLT:DC`), `reference_junction_temp_c` is the real temperature
at the probe clips - NOT read from the meter's built-in KITS90 mode during
normal operation, because that mode only knows the meter's own terminal
temperature, which is the wrong physical location once probes are clipped
onto bare wire elsewhere. The meter's internal KITS90 reading is only used
for the "Read CJC from meter" (circular-arrow) button, and even then, only
validly, with the leads **shorted together right at the clips** at that
moment - it's a stand-in for "what's the temperature right here, right
now," not a continuous automatic reference.

**Known gap:** the CJC reference temp is still either that one-shot shorted
read or hand-typed - there's no continuous automatic reference yet. The
original plan was a DS18B20 (one-wire, ~$2-5) taped to the probe clip,
feeding the reference field automatically; **not yet acquired or wired up.**

## UI summary (`templates/index.html`)

Single condensed panel: connection banner, live display (mV left half /
K-type temp right half, split permanently visible, solid-green mV line and
solid-blue temp line on the trend chart (these can trace near-identical
shapes since temp is close to a linear transform of mV - distinguished by
color only, not line style)), Mode dropdown, Log interval (s, logging cadence only),
CJC ref field + calibrate button, Log-for duration dropdown (Until stopped /
1 / 5 / 10 min), Start(/Stop) (symbol buttons), Save, Log folder dropdown
(`TE-1162A` through `TE-1162J`, 9 total, skipping I), a live "(N saved)"
counter next to it. Below: a single table row that overwrites in place per
logged snapshot (not one row per reading - the full history lives in
`loggedReadings` in memory, backing the CSV and the chart, not the DOM), and
a canvas trend chart (~5 min visible at a time, the rest reachable by
scroll/drag, a "Live" button/auto-follow to jump back to the newest point).

Plain `<canvas>`, no charting library - deliberately, for a small embedded
utility page. Canvas backing-store resolution is scaled to
`devicePixelRatio` so text renders crisp on high-DPI phone screens.

## Open items

- **DS18B20 reference-junction sensor** - not yet acquired/wired. Until
  then, the CJC ref field is either hand-typed or filled via the one-shot
  "shorted leads" calibrate button.
- No real multi-TC-channel support - one meter, one set of probes, logs
  organized by folder name only (manual context-switch between elements).
- MultimeterNode hotspot password is intentionally weak
  - single-purpose LAN/field tool, matches this whole project's "no auth"
    threat model (deliberate, 2026-10-15/16).
- Pi has no RTC: in the field (no internet) its clock is wrong, so CSV
  filenames carry the wrong date/time. Row timestamps come from the
  browser and are correct.
