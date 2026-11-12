# Shared helpers for Pi-Agents tests. Source this file from tests/*.sh.
# shellcheck shell=bash

# The launcher and helpers require Bash 4. They run through `env bash`, so the
# bash on PATH decides; re-run under it when this shell is older.
PI_TEST_BASH=$(command -v bash || true)
if [[ -z $PI_TEST_BASH ]] || ! "$PI_TEST_BASH" -c '(( BASH_VERSINFO[0] >= 4 ))' 2>/dev/null; then
  printf 'SKIP: %s requires Bash 4 or newer on PATH (found: %s)\n' "$(basename -- "$0")" \
    "$("${PI_TEST_BASH:-false}" -c 'printf %s "$BASH_VERSION"' 2>/dev/null || printf none)"
  exit 0
fi
if (( BASH_VERSINFO[0] < 4 )); then exec "$PI_TEST_BASH" "$0" "$@"; fi

TEST_NAME=$(basename -- "$0" .sh)
ROOT=$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)
TMP_DIR=$(mktemp -d)
TMP_DIR=$(cd -P -- "$TMP_DIR" && pwd -P)
trap 'rm -rf -- "$TMP_DIR"' EXIT

fail() {
  printf 'FAIL [%s]: %s\n' "$TEST_NAME" "$*" >&2
  exit 1
}

assert_eq() {
  [[ $1 == "$2" ]] || fail "${3:-value mismatch}"$'\n'"expected: $2"$'\n'"actual:   $1"
}

assert_file_has() {
  grep -Fq -- "$2" "$1" || fail "$1 lacks: $2"$'\n'"--- content ---"$'\n'"$(cat -- "$1" 2>/dev/null)"
}

assert_file_lacks() {
  ! grep -Fq -- "$2" "$1" || fail "$1 unexpectedly has: $2"$'\n'"--- content ---"$'\n'"$(cat -- "$1" 2>/dev/null)"
}

assert_file_count() {
  local count
  count=$(grep -Fc -- "$2" "$1" || true)
  [[ $count -eq $3 ]] || fail "$1 has $count occurrences of '$2', expected $3"$'\n'"--- content ---"$'\n'"$(cat -- "$1")"
}

pass() {
  printf 'PASS: %s\n' "$TEST_NAME"
}
