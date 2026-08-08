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
