# Ohms Test v2 - plan (user feedback 2026-10-23)

Mock: `ohms_test_v2_mock.html` (open in a browser). Nothing below is built yet.

## Phase 1
- Single screen - no separate setup step. SN picker + 1/2/3 + Start sit above
  the head; locked (greyed) while a test runs, unlocked after Next.
- SN picker: `◂ [SN | digits ▼] ▸` - arrows step SN -1/+1, ▼ lists recent SNs,
  last-used SN pre-filled. Recent list comes from the Pi's saved tests, not
  per-phone storage.
- Head enlarged to ~300px; live reading + pair + countdown in the centre of
  the ring. GND terminals labelled GND1 (top) / GND2 (bottom).
- Completion: small green "DONE" prompt, buttons `[Save] [Next ▸]`. Next is
  disabled until Save; Next clears the table and advances the SN by 1.
- Master log: append one JSON line per saved test to `logs/ohms_tests.jsonl`
  (test_id, timestamp, serial, element_count, recipe, readings). Per-test
  CSVs still written. Write in one go + fsync; readers skip a torn last line.
- History tab: same SN picker; table = pairs down the side, tests across
  (3 newest, Newer/Older paging) so it fits a phone without scrolling;
  Download CSV for that SN.

## Phase 2
- Pass/fail: cross + ground pairs pass if >= 1 MΩ (OL = pass). Self pairs:
  no limit yet - show value only, make the limit a setting later.
- Recipes = saved custom pair order (name, element count, ordered pairs),
  load from a dropdown.

## Later
- Real DB design (MySQL/MariaDB on the user's server, lowercase table names
  so Linux -> Windows moves cleanly); import from the JSONL; Pi syncs when on
  the network. PO -> customer -> SN linking.
