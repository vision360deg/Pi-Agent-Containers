#!/usr/bin/env bash
# bin/pi-state-copy: copying auth, sessions, and extensions between agent-state volumes.
set -euo pipefail

source "$(dirname -- "${BASH_SOURCE[0]}")/lib/common.bash"

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

# Usage and argument validation: errors exit 2.
bash "$ROOT/bin/pi-state-copy" --help > "$TMP_DIR/help" || fail '--help must succeed'
assert_file_has "$TMP_DIR/help" 'usage: pi-state-copy --source PATH --target PATH'
expect_copy_error() {
  local message=$1 status=0
  shift
  bash "$ROOT/bin/pi-state-copy" "$@" </dev/null 2>"$TMP_DIR/usage.err" || status=$?
  assert_eq "$status" 2 "exit status for: $*"
  assert_file_has "$TMP_DIR/usage.err" "pi-state-copy: $message"
}
expect_copy_error 'unsupported option: --bogus' --source "$SOURCE" --target "$TARGET" --bogus
expect_copy_error '--source requires a directory' --target "$TARGET" --source
expect_copy_error '--target requires a directory' --source "$SOURCE" --target
expect_copy_error '--source is required' --target "$TARGET"
expect_copy_error '--target is required' --source "$SOURCE"
expect_copy_error "source is not a directory: $TMP_DIR/missing" --source "$TMP_DIR/missing" --target "$TARGET"
expect_copy_error "target is not a directory: $TMP_DIR/missing" --source "$SOURCE" --target "$TMP_DIR/missing"

# Additive session copy: skip the duplicate, copy the new file.
printf 's' | run_copy --sessions --all
grep -Fqx -- '{"session":"keep","value":"target"}' "$TARGET/sessions/keep.jsonl"
grep -Fqx -- '{"session":"new","value":"new"}' "$TARGET/sessions/new.jsonl"

# Duplicates prompt: replace overwrites one, replace-all stops prompting, and
# end of input cancels with status 3. Destination-only records survive.
printf '%s\n' '{"session":"new","value":"target"}' > "$TARGET/sessions/new.jsonl"
printf '%s\n' '{"session":"target-only"}' > "$TARGET/sessions/target-only.jsonl"
printf 'r\ns\ns\n' | run_copy --sessions --all 2>"$TMP_DIR/duplicates.err"
grep -Fqx -- '{"session":"keep","value":"source"}' "$TARGET/sessions/keep.jsonl"
grep -Fqx -- '{"session":"new","value":"target"}' "$TARGET/sessions/new.jsonl"
assert_file_has "$TMP_DIR/duplicates.err" 'Destination already has session "keep.jsonl": [r]eplace, [s]kip, replace [a]ll, or [q]uit? '
assert_file_has "$TMP_DIR/duplicates.err" 'Destination already has session "new.jsonl"'
printf '%s\n' '{"session":"keep","value":"target"}' > "$TARGET/sessions/keep.jsonl"
printf 'a\n' | run_copy --sessions --all 2>"$TMP_DIR/duplicates.err"
assert_file_count "$TMP_DIR/duplicates.err" 'Destination already has session' 1
grep -Fqx -- '{"session":"keep","value":"source"}' "$TARGET/sessions/keep.jsonl"
grep -Fqx -- '{"session":"new","value":"new"}' "$TARGET/sessions/new.jsonl"
printf '%s\n' '{"session":"keep","value":"target"}' > "$TARGET/sessions/keep.jsonl"
status=0
run_copy --sessions --all </dev/null 2>"$TMP_DIR/duplicates.err" || status=$?
assert_eq "$status" 3 'end of input at a duplicate prompt'
assert_file_has "$TMP_DIR/duplicates.err" 'pi-state-copy: copy cancelled'
grep -Fqx -- '{"session":"keep","value":"target"}' "$TARGET/sessions/keep.jsonl"

# --override replaces a duplicate without prompting.
run_copy --sessions --all --override 2>"$TMP_DIR/override.err"
grep -Fqx -- '{"session":"keep","value":"source"}' "$TARGET/sessions/keep.jsonl"
assert_file_lacks "$TMP_DIR/override.err" 'Destination already has'
grep -Fqx -- '{"session":"target-only"}' "$TARGET/sessions/target-only.jsonl"
rm -f "$TARGET/sessions/target-only.jsonl"

# Without --all, the helper presents an item picker.
rm -f "$TARGET/sessions/picked.jsonl"
printf '3' | run_copy --sessions
grep -Fqx -- '{"session":"picked","value":"picked"}' "$TARGET/sessions/picked.jsonl"

# Item picker: the whole line is one selection. Cancelling (Enter, end of
# input, q, x, Esc) and invalid, out-of-range, or repeated numbers stop before
# the destination changes.
PICK_SOURCE=$TMP_DIR/pick-source
PICK_TARGET=$TMP_DIR/pick-target
mkdir -p "$PICK_SOURCE/sessions"
for name in one two three; do printf '{"session":"%s"}\n' "$name" > "$PICK_SOURCE/sessions/$name.jsonl"; done
pick() {
  local input=$1
  shift
  rm -rf -- "$PICK_TARGET"
  mkdir -p "$PICK_TARGET"
  PICK_STATUS=0
  printf '%b' "$input" | bash "$ROOT/bin/pi-state-copy" --source "$PICK_SOURCE" --target "$PICK_TARGET" "$@" \
    >/dev/null 2>"$TMP_DIR/pick.err" || PICK_STATUS=$?
}
picked() { (cd "$PICK_TARGET" && find . -type f ! -path './.pi-state-copy*' | LC_ALL=C sort | tr '\n' ' '); }
pick '1 3\n' --sessions
assert_eq "$PICK_STATUS" 0 'picker status'
assert_file_has "$TMP_DIR/pick.err" $'Available sessions:\n  1) one.jsonl\n  2) three.jsonl\n  3) two.jsonl\nSelect sessions by number (space or comma separated), all, or q to cancel: '
assert_eq "$(picked)" './sessions/one.jsonl ./sessions/two.jsonl ' 'items 1 and 3'
pick '1,2\n' --sessions
assert_eq "$(picked)" './sessions/one.jsonl ./sessions/three.jsonl ' 'comma-separated items'
pick 'all\n' --sessions
assert_eq "$(picked)" './sessions/one.jsonl ./sessions/three.jsonl ./sessions/two.jsonl ' 'all items'
for input in '\n' '' 'q\n' 'Q\n' 'x\n' 'X\n' '\033\n'; do
  pick "$input" --sessions
  assert_eq "$PICK_STATUS" 3 "picker cancel status for input '$input'"
  assert_file_has "$TMP_DIR/pick.err" 'pi-state-copy: copy cancelled'
  assert_eq "$(ls -A "$PICK_TARGET")" '' "picker cancel must leave the destination unchanged for input '$input'"
done
while IFS='|' read -r input message; do
  pick "$input" --sessions
  assert_eq "$PICK_STATUS" 2 "picker error status for input '$input'"
  assert_file_has "$TMP_DIR/pick.err" "pi-state-copy: $message"
  assert_eq "$(ls -A "$PICK_TARGET")" '' "picker error must leave the destination unchanged for input '$input'"
done <<'EOF'
4\n|invalid sessions selection: 4
0\n|invalid sessions selection: 0
one\n|invalid sessions selection: one
1 x\n|invalid sessions selection: x
1 1\n|duplicate sessions selection: 1
EOF

# A category without items is noted and the other categories still copy.
printf '{"pick":{"token":"t"}}\n' > "$PICK_SOURCE/auth.json"
pick '1\n1\n' --sessions --extensions --auth
assert_eq "$PICK_STATUS" 0 'empty-category status'
assert_file_has "$TMP_DIR/pick.err" 'pi-state-copy: the source state has no extensions to select'
jq -e '.pick.token == "t"' "$PICK_TARGET/auth.json" >/dev/null || fail 'the other categories must still copy'
rm -f "$PICK_SOURCE/auth.json"

# The duplicate prompt asks again after an invalid key; s then skips.
mkdir -p "$PICK_TARGET/sessions"
printf 'target\n' > "$PICK_TARGET/sessions/one.jsonl"
PICK_STATUS=0
printf 'z\ns\n' | bash "$ROOT/bin/pi-state-copy" --source "$PICK_SOURCE" --target "$PICK_TARGET" --session one.jsonl \
  >/dev/null 2>"$TMP_DIR/pick.err" || PICK_STATUS=$?
assert_eq "$PICK_STATUS" 0 'invalid duplicate key status'
assert_file_has "$TMP_DIR/pick.err" 'Please choose r, s, a, or q.'
assert_file_count "$TMP_DIR/pick.err" 'Destination already has session "one.jsonl"' 2
assert_eq "$(cat -- "$PICK_TARGET/sessions/one.jsonl")" target 'skipped duplicate'
for input in 'q' ''; do
  PICK_STATUS=0
  printf '%b' "$input" | bash "$ROOT/bin/pi-state-copy" --source "$PICK_SOURCE" --target "$PICK_TARGET" --session one.jsonl \
    >/dev/null 2>"$TMP_DIR/pick.err" || PICK_STATUS=$?
  assert_eq "$PICK_STATUS" 3 "duplicate cancel status for input '$input'"
  assert_file_has "$TMP_DIR/pick.err" 'pi-state-copy: copy cancelled'
  assert_eq "$(cat -- "$PICK_TARGET/sessions/one.jsonl")" target 'cancelled duplicate'
done

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
  fail 'stale extension was copied into destination settings'
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
    fail 'copy left staging, publication, or backup entries behind'
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
cmp -s "$TMP_DIR/before-cancel" "$TMP_DIR/after-cancel" || fail 'cancelled copy changed the target'
assert_no_copy_leftovers
rm -f "$SOURCE/sessions/a-cancel.jsonl"

# Every duplicate decision is collected before anything is published, so
# quitting after an earlier replace leaves the destination unchanged.
printf '%s\n' '{"session":"keep","value":"target"}' > "$TARGET/sessions/keep.jsonl"
printf '%s\n' '{"session":"new","value":"target"}' > "$TARGET/sessions/new.jsonl"
snapshot_target "$TMP_DIR/before-replace-quit"
status=0
printf 'r\nq\n' | run_copy --sessions --all 2>/dev/null || status=$?
assert_eq "$status" 3 'quitting after a replace'
snapshot_target "$TMP_DIR/after-replace-quit"
cmp -s "$TMP_DIR/before-replace-quit" "$TMP_DIR/after-replace-quit" || fail 'quitting after a replace changed the target'
assert_no_copy_leftovers
run_copy --sessions --all --override

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
    fail 'copy with an unpublishable item unexpectedly succeeded'
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
  fail 'copy through a target symlink unexpectedly succeeded'
fi
grep -Fq 'refusing symlinked state path' "$TMP_DIR/symlink.err"
grep -Fqx 'outside' "$TMP_DIR/outside"
[[ -L "$TARGET/sessions/linked.jsonl" ]]
rm -f "$TARGET/sessions/linked.jsonl" "$SOURCE/sessions/linked.jsonl"

LINKED_SOURCE="$TMP_DIR/linked-source"
mkdir -p "$LINKED_SOURCE"
ln -s "$SOURCE/auth.json" "$LINKED_SOURCE/auth.json"
if bash "$ROOT/bin/pi-state-copy" --source "$LINKED_SOURCE" --target "$TARGET" --auth --all 2>"$TMP_DIR/symlink.err"; then
  fail 'copy from a source symlink unexpectedly succeeded'
fi
grep -Fq 'refusing symlinked state path' "$TMP_DIR/symlink.err"

# Source and target must not overlap.
if bash "$ROOT/bin/pi-state-copy" --source "$TARGET" --target "$TARGET/sessions" --all 2>"$TMP_DIR/overlap.err"; then
  fail 'overlapping source and target unexpectedly succeeded'
fi
grep -Fq 'non-overlapping' "$TMP_DIR/overlap.err"
assert_no_copy_leftovers

# Malformed source auth must fail without changing destination auth.
cp "$TARGET/auth.json" "$TMP_DIR/auth-before.json"
printf '%s\n' '{not-json' > "$SOURCE/auth.json"
if run_copy --auth --all; then
  fail 'malformed source auth unexpectedly succeeded'
fi
cmp -s "$TMP_DIR/auth-before.json" "$TARGET/auth.json"

# Source remains unchanged.
grep -Fqx -- 'source package' "$SOURCE/npm/node_modules/source-package/index.js"
grep -Fqx -- '{"session":"keep","value":"source"}' "$SOURCE/sessions/keep.jsonl"

pass
