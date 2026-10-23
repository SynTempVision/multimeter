"""ohms_test.py - button/timer-driven resistance-test state machine.

Simplified 2026-10-22 per "baby steps" direction - the original design voice-
drove this (ported from uPaceInterface); this version drops voice entirely.
Flow: tap element count -> tap Start -> each pair auto-captures after a fixed
stabilization wait, no tap needed -> user can tap "Redo" on any already-
logged reading (not just the most recent one) to re-measure just that pair
without disturbing the rest of the sequence.

Pair sequences are hardcoded per element count (only 1, 2, or 3 are ever
valid), ordered so only ONE probe lead moves between consecutive pairs - see
the 2026-10-22 conversation for how this was derived/confirmed against the
user's own stated 3-element order.
"""

STABILIZE_SECONDS = 5

PAIR_SEQUENCES = {
    1: [
        ("1-1", "1", "1"),
        ("1-GND", "1", "GND"),
    ],
    2: [
        ("1-1", "1", "1"),
        ("1-2", "1", "2"),
        ("1-GND", "1", "GND"),
        ("2-GND", "2", "GND"),
        ("2-2", "2", "2"),
    ],
    3: [
        ("1-1", "1", "1"),
        ("1-2", "1", "2"),
        ("1-3", "1", "3"),
        ("1-GND", "1", "GND"),
        ("2-GND", "2", "GND"),
        ("2-2", "2", "2"),
        ("2-3", "2", "3"),
        ("3-3", "3", "3"),
        ("3-GND", "3", "GND"),
    ],
}


class OhmsTestState:
    """One active test at a time - same single-user assumption the rest of
    this app already makes for the Meter class (one session at a time)."""

    def __init__(self):
        self.active = False
        self.element_count = None
        self.pairs = []            # ordered list of (label, a, b) tuples
        self.current_label = None  # which pair is being measured right now
        self.readings = {}         # label -> reading string, as read from the meter
        self.session_id = None     # the Meter session this test is driving
        self.serial = None         # unit serial, e.g. "SN10482"
        self.saved_filename = None # set once /ohms-save writes the CSV

    def reset(self):
        self.__init__()

    def start(self, n, serial):
        self.reset()
        self.active = True
        self.element_count = n
        self.serial = serial
        self.pairs = PAIR_SEQUENCES[n]
        self.current_label = self.pairs[0][0]

    def _next_unmeasured_label(self):
        for label, _, _ in self.pairs:
            if label not in self.readings:
                return label
        return None

    def capture(self, value):
        """Records a reading for whatever current_label is right now, then
        advances to the next pair that doesn't have a reading yet - this
        naturally resumes the normal sequence correctly whether the just-
        captured pair was the next one in order OR a redo of an earlier
        one (redo overwrites readings[label] but doesn't touch any other
        pair's status, so _next_unmeasured_label() picks up wherever the
        sequence actually still has gaps)."""
        self.readings[self.current_label] = value
        self.current_label = self._next_unmeasured_label()

    def redo(self, label):
        """Jump to re-measure a specific already-logged pair. Valid any
        time - mid-test (resumes the normal sequence afterward) or after
        completion (just touches up that one value, stays complete)."""
        valid_labels = {p[0] for p in self.pairs}
        if label in valid_labels:
            self.current_label = label

    def is_complete(self):
        return self.active and bool(self.pairs) and all(
            label in self.readings for label, _, _ in self.pairs
        )

    def as_dict(self):
        return {
            "active": self.active,
            "element_count": self.element_count,
            "total_pairs": len(self.pairs),
            "pair_labels": [p[0] for p in self.pairs],
            "current_label": self.current_label,
            "readings": self.readings,
            "complete": self.is_complete(),
            "serial": self.serial,
            "saved_filename": self.saved_filename,
            "stabilize_seconds": STABILIZE_SECONDS,
        }
