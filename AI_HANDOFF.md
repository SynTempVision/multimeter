# AI handoff prompt - OWON XDM1241 Pi Zero W multimeter project

Paste this whole file to a fresh AI assistant (with filesystem/SSH access to this
project) to pick up exactly where this session left off.

---

## What this project is

A standalone Flask webserver on a Raspberry Pi Zero W, running locally on the
Pi that's physically plugged into an OWON XDM1241 bench multimeter via USB
(Micro-USB OTG adapter -> the meter's USB-B port). It replaces an older
design (`svhelp`'s `multimeter.php` + `mm_bridge.py`) that used a laptop as a
serial<->TCP bridge - now the Pi itself talks to the meter over serial
directly, no bridge needed.

**Real purpose:** logging K-type thermocouple temperature readings, where the
thermocouple is formed by clipping the meter's standard test-lead probes onto
bare wire on an actual heated element - NOT a dedicated thermocouple plug
into the meter's own jacks. That detail matters a lot (see "Thermocouple
math" below) - it's the whole reason the project does its own NIST-curve math
client-side instead of trusting the meter's built-in temperature mode for
the real measurement.

**Source**: `C:\Users\synte\sandbox\OWON-XDM1241\pi_multimeter\`
**Deployed to**: `multimeter@172.17.17.130:~/pi_multimeter/` (Pi Zero W,
hostname `multimeter`, Raspberry Pi OS Lite 32-bit / Debian 13 Trixie),
running as systemd service `mm-control.service`.

Read `README.md` in this same directory first - it has the full technical
reference (routes, SCPI commands, architecture, deploy commands). This file
is about *how to keep working on it*, not what it does.

## How to deploy a change

1. Edit `app.py` and/or `templates/index.html` locally.
2. `scp` the changed file(s) to the Pi:
   ```
   scp "C:\Users\synte\sandbox\OWON-XDM1241\pi_multimeter\templates\index.html" multimeter@172.17.17.130:~/pi_multimeter/templates/index.html
   scp "C:\Users\synte\sandbox\OWON-XDM1241\pi_multimeter\app.py" multimeter@172.17.17.130:~/pi_multimeter/app.py
   ```
3. Restart the service so it's picked up:
   ```
   ssh multimeter@172.17.17.130
   sudo systemctl restart mm-control.service
   ```
4. **`scp` needs a password typed interactively** - the assistant running
   this can't type it, so hand the exact `scp`/`ssh` commands back to the
   user every single time a file changes, without waiting to be asked. This
   was explicit, repeated feedback in the prior session ("i need scp
   comamnds. you awlays leave those out").
5. The page sends `Cache-Control: no-store`, so there's no browser-caching
   confusion after a redeploy - if something "doesn't work" right after a
   push, suspect a missed `scp`/restart step before suspecting the code.

## Collaboration style that worked well (follow this)

- **Work fast, narrate less.** This user explicitly asked to speed up mid-session.
  For small UI tweaks: make the edit, give the deploy command, 1-3 lines of
  explanation max. Save longer explanations for when something is genuinely
  non-obvious or safety/correctness-relevant (e.g. the NIST coefficients, the
  KITS90-vs-clip-location distinction).
- **Never type scientific/safety-critical constants from memory.** The NIST
  Type K coefficients in `thermocouple_k.py` were pulled from
  `its90.nist.gov` via WebFetch and cross-validated digit-for-digit against
  an independent open-source package before trusting them. If this math
  needs to change or extend (e.g. a different thermocouple type), repeat
  that verify-don't-guess process.
- **Never assume SCPI commands - verify empirically against the real meter.**
  Every command in the README's "SCPI commands" section was found by writing
  one-off test scripts run over SSH against the actual hardware, not by
  guessing from similar meters' documented command sets. If a new mode/query
  is needed, test it live the same way before relying on it.
- **This user builds fast and iterates live, under time pressure.** Short
  messages, frequent typos, expects rapid back-and-forth. Give a one-line
  recommendation with the main tradeoff for open design questions (not an
  exhaustive options survey), and wait for her steer before big
  architecture changes - but don't over-ask on small, clearly-scoped UI
  tweaks the way a long Q&A would slow her down.
- **Discuss before code** (her global CLAUDE.md rule) - for anything with a
  real design decision (not a one-line tweak), state the plan/tradeoff
  briefly before implementing, especially for anything risky (e.g. the WiFi
  hotspot work almost certainly drops the active SSH session when switched -
  that was flagged explicitly before running it).

## Current state / open items (as of this handoff)

1. **DS18B20 reference-junction sensor - not yet acquired or wired up.**
   This is the biggest real gap. The CJC (cold junction) reference
   temperature - the actual temperature at the probe clips, which the NIST
   math needs - is currently either hand-typed into a field, or filled via a
   one-shot "short the leads, read the meter's own internal KITS90 value"
   button (`/calibrate-cjc` route). Neither is continuous/automatic. The
   plan is a DS18B20 one-wire sensor (~$2-5) taped to the probe clip, read
   over GPIO, auto-filling the reference field - not yet started.
2. **WiFi**: a second NetworkManager connection profile, `MultimeterNode`
   (AP mode, password `password`, static `192.168.225.1/24`), was just
   created for field use without the lab's "FIC" WiFi available. It's
   switch-only (not concurrent with FIC) - deliberate, see README's Network
   section for why concurrent AP+STA wasn't worth the added fragility for
   this project's actual use case. Switch commands are in the README.
3. **No real multi-channel support** - one physical meter/probe set. If this
   project ever needs multiple thermocouples logged simultaneously, that's
   a real hardware limitation (would need multiple meters or a different
   DAQ approach), not a software gap.
4. The whole UI underwent heavy rapid iteration this session (condensed
   layout, live/logging decoupling, duration dropdown, folder dropdown with
   9 real test-element names `TE-1162A`-`TE-1162J`, dual-axis trend chart,
   dark-mode contrast fixes, mobile compactness). All of it is live-deployed
   and working as of this handoff - `README.md`'s "UI summary" section
   describes the current state accurately. Don't assume anything about the
   UI beyond what's in that file and the actual current `index.html` - a lot
   changed fast.

## If rebuilding from scratch

Everything needed to rebuild this is in `README.md` (routes, SCPI commands,
hardware wiring, systemd unit, architecture rationale) plus the actual
source files (`app.py`, `templates/index.html`, `thermocouple_k.py`). The
NIST coefficients and the empirically-discovered SCPI command set are the
two things that took real, hard-won verification work - don't regenerate
those from a language model's memory; re-derive them the same way (WebFetch
+ cross-validation for the math, live testing against the real meter for the
commands) if they're ever in doubt.
