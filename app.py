"""app.py - standalone Flask webserver + direct serial control for the
OWON XDM1241, running locally on the Pi this meter is physically plugged
into. Replaces svhelp's multimeter.php + mm_bridge.py, which existed only
because the meter used to be plugged into a laptop and the web page had
to reach it over the network via a serial<->TCP bridge - now that the Pi
itself is directly attached to the meter, that whole relay layer is gone.

Session-based exclusivity: a whole "configure mode X, take N readings"
sequence from one browser page load holds the meter via a session token,
so a second browser can't sneak a conflicting configure in between two of
the first browser's readings - the exact race found in the old svhelp
version's code review (2026-10-15): each configure/measure there was an
independent HTTP request with the lock released in between, so another
user's configure could silently land mid-sequence with no error, just
wrong data. A session auto-expires if idle too long (crashed/closed tab),
so the meter never stays locked out forever.

Run with: python app.py   (listens on 0.0.0.0:5000)
"""
import csv
import re
import secrets
import threading
import time
from pathlib import Path

from flask import Flask, jsonify, render_template, request
import serial
from serial.tools import list_ports

app = Flask(__name__)

BAUD = 115200
CH340_VID, CH340_PID = 0x1A86, 0x7523   # USB-serial chip inside the XDM1241
SESSION_IDLE_TIMEOUT = 10                # seconds - auto-release if idle this long

# Where "Commit to File" saves a snapshot of whatever's been logged in the
# browser so far (2026-10-15: "log as much as you want and when ready can
# commit to a file"). Filename is Name_date_time_iteration - iteration
# counts existing files already in that run's folder rather than an
# in-memory counter, so it stays correct across server restarts instead of
# resetting to 1 and colliding. Each run goes in its own subfolder (e.g.
# TC1/TC2/TC3/TC4, 2026-10-16: "Folder names to commit it to a folder") so
# separate thermocouple elements' logs don't land in one flat pile.
LOGS_DIR = Path(__file__).resolve().parent / "logs"
LOGS_DIR.mkdir(exist_ok=True)

# Folder names come straight from a browser text field, so this can't trust
# them - stripped to a safe charset before ever touching the filesystem,
# otherwise something like "../../etc" in that field could escape LOGS_DIR
# entirely. Keep only letters/digits/dash/underscore; anything else becomes
# "_", and an empty/all-stripped result falls back to "log".
def safe_folder_name(name):
    cleaned = re.sub(r"[^A-Za-z0-9_-]", "_", (name or "").strip())[:40]
    return cleaned or "log"

# Same mode table as mm_bridge.py / multimeter.php / xdm1241ModeRead.py
MODES = {
    'vdc':  ('DC Voltage',    'CONFigure:VOLT:DC', 'V',  True),
    'vac':  ('AC Voltage',    'CONFigure:VOLT:AC', 'V',  True),
    'idc':  ('DC Current',    'CONFigure:CURR:DC', 'A',  False),
    'iac':  ('AC Current',    'CONFigure:CURR:AC', 'A',  False),
    'res':  ('Ohms (2-wire)', 'CONFigure:RES',     'Ω',  False),
    'fres': ('Ohms (4-wire)', 'CONFigure:FRES',    'Ω',  False),
    'cap':  ('Capacitance',   'CONFigure:CAP',     'F',  False),
    'freq': ('Frequency',     'CONFigure:FREQ',    'Hz', False),
    'diod': ('Diode',         'CONFigure:DIOD',    'V',  True),
    'cont': ('Continuity',    'CONFigure:CONT',    'Ω',  False),
}

# Reverse lookup: FUNC? reply -> our mode key. Confirmed empirically against
# the real meter (2026-10-15) by cycling every CONFigure command and reading
# FUNC? right after. Note: RES and FRES (2-wire/4-wire resistance) both
# reply "RES" - genuinely indistinguishable from this query alone, not a
# parsing bug. A "RES" reply defaults to 'res' (2-wire); there is no way to
# tell from the meter's own reply whether it's actually in 4-wire mode.
FUNC_REPLY_TO_MODE = {
    'VOLT': 'vdc',
    'VOLT AC': 'vac',
    'CURR': 'idc',
    'CURR AC': 'iac',
    'RES': 'res',
    'CAP': 'cap',
    'FREQ': 'freq',
    'DIOD': 'diod',
    'CONT': 'cont',
}


def probe(port_name):
    """Open a port, send *IDN?, return the reply if it looks like the meter."""
    try:
        with serial.Serial(port_name, BAUD, timeout=1.5) as s:
            time.sleep(0.2)
            s.reset_input_buffer()
            s.write(b"*IDN?\n")
            reply = s.readline().decode(errors="replace").strip()
    except (serial.SerialException, OSError):
        return None
    if "OWON" in reply.upper() or "XDM" in reply.upper():
        return reply
    return None


def find_meter():
    """Try CH340 ports first, then everything else. Returns (port, idn) or (None, None)."""
    ports = list(list_ports.comports())
    ports.sort(key=lambda p: 0 if (p.vid, p.pid) == (CH340_VID, CH340_PID) else 1)
    for p in ports:
        idn = probe(p.device)
        if idn:
            return p.device, idn
    return None, None


class Meter:
    """Owns the one serial connection and the one active session. Every
    method takes self.lock for its whole body, so identify()/
    start_session()/measure() from different requests never interleave on
    the wire - only one of them is ever actually talking to the meter at
    a time, regardless of how many browser tabs are open."""

    def __init__(self):
        self.lock = threading.Lock()
        self.ser = None
        self.session_id = None
        self.session_mode = None
        self.last_activity = 0

    def _ensure_open(self):
        if self.ser and self.ser.is_open:
            return True
        port, idn = find_meter()
        if not port:
            return False
        self.ser = serial.Serial(port, BAUD, timeout=2)
        return True

    def close_meter(self):
        try:
            if self.ser:
                self.ser.close()
        except Exception:
            pass
        self.ser = None

    def _session_alive(self):
        return (
            self.session_id is not None
            and (time.time() - self.last_activity) < SESSION_IDLE_TIMEOUT
        )

    def _io_failed(self):
        # A physical disconnect can raise all sorts of things depending on
        # exactly when it happens mid-syscall - serial.SerialException,
        # plain OSError, or a raw termios.error that pyserial doesn't wrap
        # (confirmed 2026-10-15: unplugging the meter mid-request raised an
        # uncaught termios.error and crashed the whole HTTP request with a
        # 500). Caught broadly here on purpose - any failure talking to
        # hardware that can be yanked at any moment should degrade to the
        # same message, never a crash. Also drop the handle so the NEXT
        # call re-discovers the port instead of reusing a dead one forever -
        # self.ser.is_open stays True after an I/O error even though the
        # port is actually dead, so without this, "No meter connected"
        # would persist even after the meter is plugged back in.
        self.close_meter()

    def identify(self):
        # Deliberately NOT gated by _session_alive() - *IDN? is read-only,
        # same reasoning as current_mode()'s FUNC? below. Used to be gated,
        # which was harmless back when a reading session was short-lived,
        # but now that the live "video" loop holds a session continuously
        # for as long as the page is open (2026-10-16 redesign), this check
        # would make /idn - and therefore the connection banner - report
        # "busy" forever after the very first reading. Still goes through
        # self.lock, so it just waits its turn rather than racing a
        # measure() call.
        with self.lock:
            if not self._ensure_open():
                return {"ok": False, "error": "No meter connected."}
            try:
                self.ser.reset_input_buffer()
                self.ser.write(b"*IDN?\n")
                reply = self.ser.readline().decode(errors="replace").strip()
            except Exception:
                self._io_failed()
                return {"ok": False, "error": "No meter connected."}
            if not reply:
                self._io_failed()
                return {"ok": False, "error": "No meter connected."}
            return {"ok": True, "reply": reply}

    def current_mode(self):
        # Deliberately NOT gated by _session_alive() like identify()/
        # start_session() are - this is a read-only query (FUNC?), it never
        # sends a SET command, so it can't corrupt an in-progress reading
        # sequence. It still goes through self.lock like everything else,
        # so it just waits its turn rather than racing a measure() call.
        with self.lock:
            if not self._ensure_open():
                return {"ok": False, "error": "No meter connected."}
            try:
                self.ser.reset_input_buffer()
                self.ser.write(b"FUNC?\n")
                reply = self.ser.readline().decode(errors="replace").strip()
            except Exception:
                self._io_failed()
                return {"ok": False, "error": "No meter connected."}
            if not reply:
                self._io_failed()
                return {"ok": False, "error": "No meter connected."}
            func = reply.strip('"')
            mode_key = FUNC_REPLY_TO_MODE.get(func)
            return {"ok": True, "mode": mode_key, "raw": func}

    def read_internal_cjc(self):
        # "the user shorts the leads and it grabs a new reading and updates
        # the CJC Ref value" (2026-10-16). With the probe tips shorted
        # together there's no real thermocouple EMF, so the meter's own
        # internal KITS90 cold-junction-compensated reading is just its own
        # terminal temperature - validated empirically 2026-10-15 (shorted
        # leads in KITS90 gave 27.05-28.64C, a plausible room-temp read).
        # Always restores VOLT:DC afterward, since that's this project's
        # only real mode - otherwise the live loop's next tick would read
        # a temperature value and report it mislabeled as a voltage.
        with self.lock:
            if not self._ensure_open():
                return {"ok": False, "error": "No meter connected."}
            try:
                self.ser.reset_input_buffer()
                self.ser.write(b"CONFigure:TEMP:RTD KITS90\n")
                time.sleep(1.2)   # mode-switch settle time - 0.5s was too fast, meter was still mid-transition (returned 0.00)
                self.ser.reset_input_buffer()   # discard any transitional noise bytes from the mode switch itself
                self.ser.write(b"MEAS1?\n")
                reply = self.ser.readline().decode(errors="replace").strip()
                self.ser.write(b"CONFigure:VOLT:DC\n")
                time.sleep(0.3)
            except Exception:
                self._io_failed()
                return {"ok": False, "error": "No meter connected."}
            if not reply:
                self._io_failed()
                return {"ok": False, "error": "No meter connected."}
            try:
                temp_c = float(reply)
            except ValueError:
                return {"ok": False, "error": "Unexpected meter reply: " + reply}
            return {"ok": True, "temp_c": temp_c}

    def start_session(self, mode_key):
        with self.lock:
            if self._session_alive():
                return {"ok": False, "error": "Meter is busy - someone else is taking readings right now."}
            if mode_key not in MODES:
                return {"ok": False, "error": "Unknown mode."}
            if not self._ensure_open():
                return {"ok": False, "error": "No meter connected."}
            _, cmd, _, _ = MODES[mode_key]
            try:
                self.ser.reset_input_buffer()
                self.ser.write((cmd + "\n").encode())
            except Exception:
                self._io_failed()
                return {"ok": False, "error": "No meter connected."}
            time.sleep(0.5)  # give the meter time to switch modes
            self.session_id = secrets.token_hex(8)
            self.session_mode = mode_key
            self.last_activity = time.time()
            return {"ok": True, "session": self.session_id}

    def measure(self, session_id):
        with self.lock:
            if self.session_id != session_id or not self._session_alive():
                return {"ok": False, "error": "Session expired, or taken over by another reading sequence."}
            try:
                self.ser.write(b"MEAS1?\n")
                reply = self.ser.readline().decode(errors="replace").strip()
            except Exception:
                self._io_failed()
                return {"ok": False, "error": "No meter connected."}
            if not reply:
                self._io_failed()
                return {"ok": False, "error": "No meter connected."}
            self.last_activity = time.time()
            return {"ok": True, "reply": reply}

    def end_session(self, session_id):
        with self.lock:
            if self.session_id == session_id:
                self.session_id = None
                self.session_mode = None


meter = Meter()


# This page gets edited and redeployed constantly during development, and a
# phone/browser silently serving a stale cached copy after a fix looks
# exactly like the fix "not working" (2026-10-16 - the CJC reset button was
# actually fine; an old cached page just didn't have it yet). Never cache
# the page itself, so every load is guaranteed current.
@app.after_request
def no_cache(response):
    response.headers["Cache-Control"] = "no-store"
    return response


@app.route("/")
def index():
    modes_for_js = {k: {"label": v[0], "unit": v[2], "mv": v[3]} for k, v in MODES.items()}
    return render_template("index.html", modes=MODES, modes_json=modes_for_js)


@app.route("/idn", methods=["POST"])
def idn():
    return jsonify(meter.identify())


@app.route("/current-mode", methods=["POST"])
def current_mode():
    return jsonify(meter.current_mode())


@app.route("/calibrate-cjc", methods=["POST"])
def calibrate_cjc():
    return jsonify(meter.read_internal_cjc())


@app.route("/configure", methods=["POST"])
def configure():
    return jsonify(meter.start_session(request.form.get("mode", "")))


@app.route("/measure", methods=["POST"])
def measure():
    return jsonify(meter.measure(request.form.get("session", "")))


@app.route("/stop", methods=["POST"])
def stop():
    meter.end_session(request.form.get("session", ""))
    return jsonify({"ok": True})


@app.route("/folder-count")
def folder_count():
    # Lets the page show "N saved" for whichever TC folder is currently
    # selected, so the user can see how many files already exist there
    # before (and after) saving, not just in the one-off success banner
    # (2026-10-16: "see how many log files have been saved for that TC").
    folder = safe_folder_name(request.args.get("folder", ""))
    target_dir = LOGS_DIR / folder
    count = len(list(target_dir.glob("*.csv"))) if target_dir.is_dir() else 0
    return jsonify({"ok": True, "folder": folder, "count": count})


@app.route("/commit", methods=["POST"])
def commit():
    data = request.get_json(silent=True) or {}
    readings = data.get("readings", [])
    if not readings:
        return jsonify({"ok": False, "error": "Nothing to commit - no readings logged yet."})
    folder = safe_folder_name(data.get("folder", ""))
    target_dir = LOGS_DIR / folder
    target_dir.mkdir(parents=True, exist_ok=True)
    iteration = len(list(target_dir.glob("*.csv"))) + 1
    filename = f"{folder}_{time.strftime('%Y%m%d_%H%M%S')}_{iteration}.csv"
    with open(target_dir / filename, "w", newline="") as f:
        writer = csv.writer(f)
        writer.writerow(["Timestamp", "Mode", "Reading (mV)", "Reading (V)", "Temp (C)", "Temp (F)"])
        for r in readings:
            writer.writerow([r.get("time", ""), r.get("mode", ""), r.get("mv", ""), r.get("raw", ""), r.get("tempC", ""), r.get("tempF", "")])
    return jsonify({"ok": True, "filename": filename, "path": f"{folder}/{filename}", "count": len(readings)})


if __name__ == "__main__":
    # /measure is polled continuously (~6/sec) by the live display - werkzeug's
    # default access log would otherwise write one line per request forever.
    # Keep actual errors visible, drop the routine 200 OK noise.
    import logging
    logging.getLogger("werkzeug").setLevel(logging.WARNING)
    app.run(host="0.0.0.0", port=5000, threaded=True)
