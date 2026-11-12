#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

SOURCE="$TMP_DIR/source"
TARGET="$TMP_DIR/target"
mkdir -p "$SOURCE/sessions" "$TARGET/sessions" \
  "$SOURCE/npm/node_modules/source-package" "$SOURCE/npm/node_modules/duplicate-package" \
  "$TARGET/npm/node_modules/target-package" "$TARGET/npm/node_modules/duplicate-package"

printf '%s\n' '{"session":"keep","value":"source"}' > "$SOURCE/sessions/keep.jsonl"
printf '%s\n' '{"session":"new","value":"new"}' > "$SOURCE/sessions/new.jsonl"
printf '%s\n' '{"session":"picked","value":"picked"}' > "$SOURCE/sessions/picked.jsonl"
printf '%s\n' '{"session":"keep","value":"target"}' > "$TARGET/sessions/keep.jsonl"

cat > "$SOURCE/auth.json" <<'EOF'
{"openai":{"token":"source-token"},"anthropic":{"token":"anthropic-token"}}
EOF
cat > "$TARGET/auth.json" <<'EOF'
{"openai":{"token":"target-token"},"google":{"token":"google-token"}}
EOF

cat > "$SOURCE/settings.json" <<'EOF'
{"packages":["npm:source-package","npm:duplicate-package"]}
EOF
cat > "$TARGET/settings.json" <<'EOF'
{"packages":["npm:target-package","npm:duplicate-package"]}
EOF
printf 'source package\n' > "$SOURCE/npm/node_modules/source-package/index.js"
printf 'duplicate source\n' > "$SOURCE/npm/node_modules/duplicate-package/index.js"
printf 'target package\n' > "$TARGET/npm/node_modules/target-package/index.js"
printf 'duplicate target\n' > "$TARGET/npm/node_modules/duplicate-package/index.js"

run_copy() {
  bash "$ROOT/bin/pi-state-copy" --source "$SOURCE" --target "$TARGET" "$@"
}

# Additive session copy: skip the duplicate, copy the new file.
printf 's' | run_copy --sessions --all
grep -Fqx -- '{"session":"keep","value":"target"}' "$TARGET/sessions/keep.jsonl"
grep -Fqx -- '{"session":"new","value":"new"}' "$TARGET/sessions/new.jsonl"

# --override replaces a duplicate without prompting.
run_copy --sessions --all --override
grep -Fqx -- '{"session":"keep","value":"source"}' "$TARGET/sessions/keep.jsonl"

# Without --all, the helper presents an item picker.
rm -f "$TARGET/sessions/picked.jsonl"
printf '3' | run_copy --sessions
grep -Fqx -- '{"session":"picked","value":"picked"}' "$TARGET/sessions/picked.jsonl"

# Auth merge is provider-level and preserves unrelated target providers.
printf 's' | run_copy --auth --all
jq -e '.openai.token == "target-token" and .anthropic.token == "anthropic-token" and .google.token == "google-token"' "$TARGET/auth.json" >/dev/null
run_copy --auth --all --override
jq -e '.openai.token == "source-token" and .anthropic.token == "anthropic-token" and .google.token == "google-token"' "$TARGET/auth.json" >/dev/null

# Extension copy includes the selected package directory and settings entry.
run_copy --extensions --all --override
grep -Fqx -- 'source package' "$TARGET/npm/node_modules/source-package/index.js"
jq -e '.packages | index("npm:source-package") and index("npm:target-package") and index("npm:duplicate-package")' "$TARGET/settings.json" >/dev/null
grep -Fqx -- 'duplicate source' "$TARGET/npm/node_modules/duplicate-package/index.js"

# Stale settings entries are skipped without aborting the copy.
printf '%s\n' '{"packages":["npm:source-package","npm:missing-package"]}' > "$SOURCE/settings.json"
run_copy --extensions --all --override
if jq -e '.packages | index("npm:missing-package")' "$TARGET/settings.json" >/dev/null; then
  printf 'stale extension was copied into destination settings\n' >&2
  exit 1
fi

# Make a directory impossible to rename into a backup: macOS honours the
# user-immutable flag, Linux refuses to move a directory lacking write access.
lock_directory() {
  if command -v chflags >/dev/null 2>&1; then chflags uchg "$1"; else chmod 0555 "$1"; fi
}
unlock_directory() {
  if command -v chflags >/dev/null 2>&1; then chflags nouchg "$1"; else chmod 0755 "$1"; fi
}

snapshot_target() {
  (cd "$TARGET" && find . -print | LC_ALL=C sort && find . -type f -exec cat {} +) > "$1"
}
assert_no_copy_leftovers() {
  if find "$TARGET" -name '.pi-state-copy*' -print | grep -q .; then
    printf 'copy left staging, publication, or backup entries behind\n' >&2
    exit 1
  fi
}

# Cancelling at a duplicate prompt exits 3 before the target changes, even
# when earlier items were already staged.
printf '%s\n' '{"session":"cancel","value":"cancel"}' > "$SOURCE/sessions/a-cancel.jsonl"
snapshot_target "$TMP_DIR/before-cancel"
set +e
printf 'q' | run_copy --sessions --all
status=$?
set -e
[[ $status -eq 3 ]] || { printf 'cancel exited %s, expected 3\n' "$status" >&2; exit 1; }
snapshot_target "$TMP_DIR/after-cancel"
cmp -s "$TMP_DIR/before-cancel" "$TMP_DIR/after-cancel" || { printf 'cancelled copy changed the target\n' >&2; exit 1; }
assert_no_copy_leftovers
rm -f "$SOURCE/sessions/a-cancel.jsonl"

# A publish failure part-way through restores every item already published.
# Renaming a directory into the backup needs write access to the directory
# itself, so a read-only extension directory fails after sessions and auth.
if [[ $(id -u) -ne 0 ]]; then
  printf '%s\n' '{"session":"rollback"}' > "$SOURCE/sessions/rollback.jsonl"
  jq '.rollback = {"token":"rollback-token"}' "$SOURCE/auth.json" > "$TMP_DIR/auth.next"
  mv "$TMP_DIR/auth.next" "$SOURCE/auth.json"
  snapshot_target "$TMP_DIR/before-rollback"
  lock_directory "$TARGET/npm/node_modules/source-package"
  if run_copy --all --override 2>"$TMP_DIR/rollback.err"; then
    unlock_directory "$TARGET/npm/node_modules/source-package"
    printf 'copy with an unpublishable item unexpectedly succeeded\n' >&2
    exit 1
  fi
  unlock_directory "$TARGET/npm/node_modules/source-package"
  grep -Fq 'restoring the previous destination items' "$TMP_DIR/rollback.err"
  snapshot_target "$TMP_DIR/after-rollback"
  cmp -s "$TMP_DIR/before-rollback" "$TMP_DIR/after-rollback" || {
    printf 'rollback did not restore the target:\n%s\n' "$(diff "$TMP_DIR/before-rollback" "$TMP_DIR/after-rollback")" >&2
    exit 1
  }
  [[ ! -e "$TARGET/sessions/rollback.jsonl" ]]
  assert_no_copy_leftovers
  rm -f "$SOURCE/sessions/rollback.jsonl"
fi

# Symlinked state paths are refused on either side, and nothing is written
# through them.
printf 'outside\n' > "$TMP_DIR/outside"
printf '%s\n' '{"session":"linked"}' > "$SOURCE/sessions/linked.jsonl"
ln -s "$TMP_DIR/outside" "$TARGET/sessions/linked.jsonl"
if run_copy --session linked.jsonl --override 2>"$TMP_DIR/symlink.err"; then
  printf 'copy through a target symlink unexpectedly succeeded\n' >&2
  exit 1
fi
grep -Fq 'refusing symlinked state path' "$TMP_DIR/symlink.err"
grep -Fqx 'outside' "$TMP_DIR/outside"
[[ -L "$TARGET/sessions/linked.jsonl" ]]
rm -f "$TARGET/sessions/linked.jsonl" "$SOURCE/sessions/linked.jsonl"

LINKED_SOURCE="$TMP_DIR/linked-source"
mkdir -p "$LINKED_SOURCE"
ln -s "$SOURCE/auth.json" "$LINKED_SOURCE/auth.json"
if bash "$ROOT/bin/pi-state-copy" --source "$LINKED_SOURCE" --target "$TARGET" --auth --all 2>"$TMP_DIR/symlink.err"; then
  printf 'copy from a source symlink unexpectedly succeeded\n' >&2
  exit 1
fi
grep -Fq 'refusing symlinked state path' "$TMP_DIR/symlink.err"

# Source and target must not overlap.
if bash "$ROOT/bin/pi-state-copy" --source "$TARGET" --target "$TARGET/sessions" --all 2>"$TMP_DIR/overlap.err"; then
  printf 'overlapping source and target unexpectedly succeeded\n' >&2
  exit 1
fi
grep -Fq 'non-overlapping' "$TMP_DIR/overlap.err"
assert_no_copy_leftovers

# Malformed source auth must fail without changing destination auth.
cp "$TARGET/auth.json" "$TMP_DIR/auth-before.json"
printf '%s\n' '{not-json' > "$SOURCE/auth.json"
if run_copy --auth --all; then
  printf 'malformed source auth unexpectedly succeeded\n' >&2
  exit 1
fi
cmp -s "$TMP_DIR/auth-before.json" "$TARGET/auth.json"

# Source remains unchanged.
grep -Fqx -- 'source package' "$SOURCE/npm/node_modules/source-package/index.js"
grep -Fqx -- '{"session":"keep","value":"source"}' "$SOURCE/sessions/keep.jsonl"

printf 'pi state-copy helper tests passed\n'
