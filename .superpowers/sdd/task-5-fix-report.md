# Task 5 regression fix

## Status

Complete.

## Change

Created each test's temporary `HOME` directory before invoking `bin/pi`:

- `tests/bin-pi-lineage.sh`
- `tests/bin-pi-state.sh`

Production code and the host rc resolver were unchanged.

## Verification

- `bash tests/bin-pi-lineage.sh` — passed
- `bash tests/bin-pi-state.sh` — passed
- `for test_file in tests/*.sh; do bash "$test_file"; done` — passed through all shell tests
- `git diff --check` — passed
