#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
RESOLVER=$ROOT/bin/pi-shell-rc
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert_contains() { grep -Fq -- "$2" "$1" || fail "$1 does not contain $2"; }
assert_once() { [[ $(grep -Fc -- "$2" "$1") -eq 1 ]] || fail "$2 is not included once"; }
assert_order() {
  local file=$1 previous=0 marker line
  for marker in "${@:2}"; do
    line=$(grep -nF -- "$marker" "$file" | head -n1 | cut -d: -f1) || fail "missing marker $marker"
    (( line > previous )) || fail "marker $marker is out of order"
    previous=$line
  done
}

HOME_ROOT=$TMP/bash-home
mkdir -p "$HOME_ROOT"
cat > "$HOME_ROOT/.bash_profile" <<'EOF'
export FROM_PROFILE=1
source "$HOME/.bashrc"
EOF
cat > "$HOME_ROOT/.bashrc" <<'EOF'
export FROM_BASHRC=1
. ~/.aliases
EOF
cat > "$HOME_ROOT/.aliases" <<'EOF'
alias ll='ls -la'
EOF
OUTPUT=$TMP/bash.rc
bash "$RESOLVER" --shell bash --home "$HOME_ROOT" --output "$OUTPUT"
assert_order "$OUTPUT" FROM_PROFILE FROM_BASHRC "alias ll='ls -la'"

ZSH_HOME=$TMP/zsh-home
mkdir -p "$ZSH_HOME"
cat > "$ZSH_HOME/.zshenv" <<'EOF'
ZSH_ENV_MARKER=1
source ~/.zshenv-nested
EOF
cat > "$ZSH_HOME/.zshenv-nested" <<'EOF'
ZSH_ENV_NESTED_MARKER=1
EOF
cat > "$ZSH_HOME/.zprofile" <<'EOF'
ZSH_PROFILE_MARKER=1
. "$HOME/.zprofile-nested"
EOF
cat > "$ZSH_HOME/.zprofile-nested" <<'EOF'
ZSH_PROFILE_NESTED_MARKER=1
EOF
cat > "$ZSH_HOME/.zshrc" <<'EOF'
ZSH_RC_MARKER=1
source ~/.zshrc-nested
EOF
cat > "$ZSH_HOME/.zshrc-nested" <<'EOF'
ZSH_RC_NESTED_MARKER=1
EOF
cat > "$ZSH_HOME/.zlogin" <<'EOF'
ZSH_LOGIN_MARKER=1
. ~/.zlogin-nested
EOF
cat > "$ZSH_HOME/.zlogin-nested" <<'EOF'
ZSH_LOGIN_NESTED_MARKER=1
EOF
ZSH_OUTPUT=$TMP/zsh.rc
bash "$RESOLVER" --shell zsh --home "$ZSH_HOME" --output "$ZSH_OUTPUT"
assert_order "$ZSH_OUTPUT" \
  ZSH_ENV_MARKER ZSH_ENV_NESTED_MARKER \
  ZSH_PROFILE_MARKER ZSH_PROFILE_NESTED_MARKER \
  ZSH_RC_MARKER ZSH_RC_NESTED_MARKER \
  ZSH_LOGIN_MARKER ZSH_LOGIN_NESTED_MARKER
assert_once "$ZSH_OUTPUT" ZSH_ENV_NESTED_MARKER

MISSING_OUTPUT=$TMP/missing.rc
MISSING_HOME=$TMP/missing-home
mkdir -p "$MISSING_HOME"
bash "$RESOLVER" --shell bash --home "$MISSING_HOME" --output "$MISSING_OUTPUT" 2>"$TMP/missing.err"
[[ ! -s "$MISSING_OUTPUT" ]] || fail "missing roots should produce an empty rc"
assert_contains "$TMP/missing.err" "missing startup rc"

CYCLE_HOME=$TMP/cycle-home
mkdir -p "$CYCLE_HOME"
cat > "$CYCLE_HOME/.bashrc" <<'EOF'
CYCLE_A=1
source ~/.cycle
EOF
cat > "$CYCLE_HOME/.cycle" <<'EOF'
CYCLE_B=1
. ~/.bashrc
EOF
CYCLE_OUTPUT=$TMP/cycle.rc
bash "$RESOLVER" --shell bash --home "$CYCLE_HOME" --output "$CYCLE_OUTPUT" 2>"$TMP/cycle.err"
assert_once "$CYCLE_OUTPUT" CYCLE_A=1
assert_once "$CYCLE_OUTPUT" CYCLE_B=1
assert_contains "$TMP/cycle.err" "cyclic source"

DYNAMIC_HOME=$TMP/dynamic-home
mkdir -p "$DYNAMIC_HOME"
cat > "$DYNAMIC_HOME/.bashrc" <<'EOF'
. "$HOME/${RC_NAME}"
DYNAMIC_MARKER=1
EOF
DYNAMIC_OUTPUT=$TMP/dynamic.rc
bash "$RESOLVER" --shell bash --home "$DYNAMIC_HOME" --output "$DYNAMIC_OUTPUT" 2>"$TMP/dynamic.err"
assert_contains "$DYNAMIC_OUTPUT" '. "$HOME/${RC_NAME}"'
assert_contains "$TMP/dynamic.err" "unresolved source"

TRAVERSAL_HOME=$TMP/traversal-home
mkdir -p "$TRAVERSAL_HOME"
cat > "$TMP/outside-traversal" <<'EOF'
TRAVERSAL_ESCAPE=1
EOF
cat > "$TRAVERSAL_HOME/.bashrc" <<'EOF'
source "$HOME/../outside-traversal"
EOF
TRAVERSAL_OUTPUT=$TMP/traversal.rc
bash "$RESOLVER" --shell bash --home "$TRAVERSAL_HOME" --output "$TRAVERSAL_OUTPUT" 2>"$TMP/traversal.err"
assert_contains "$TRAVERSAL_OUTPUT" 'source "$HOME/../outside-traversal"'
if grep -Fq 'TRAVERSAL_ESCAPE=1' "$TRAVERSAL_OUTPUT"; then
  fail "traversal source must not be inlined"
fi
assert_contains "$TMP/traversal.err" "unresolved source"

SYMLINK_HOME=$TMP/symlink-home
mkdir -p "$SYMLINK_HOME"
cat > "$TMP/outside-symlink" <<'EOF'
SYMLINK_ESCAPE=1
EOF
ln -s "$TMP/outside-symlink" "$SYMLINK_HOME/.outside-link"
cat > "$SYMLINK_HOME/.bashrc" <<'EOF'
source ~/.outside-link
EOF
SYMLINK_OUTPUT=$TMP/symlink.rc
bash "$RESOLVER" --shell bash --home "$SYMLINK_HOME" --output "$SYMLINK_OUTPUT" 2>"$TMP/symlink.err"
assert_contains "$SYMLINK_OUTPUT" 'source ~/.outside-link'
if grep -Fq 'SYMLINK_ESCAPE=1' "$SYMLINK_OUTPUT"; then
  fail "symlink escape must not be inlined"
fi
assert_contains "$TMP/symlink.err" "unresolved source"

EXTRA_ARGS_HOME=$TMP/extra-args-home
mkdir -p "$EXTRA_ARGS_HOME"
cat > "$EXTRA_ARGS_HOME/.extra" <<'EOF'
EXTRA_ARGS_TARGET=1
EOF
cat > "$EXTRA_ARGS_HOME/.bashrc" <<'EOF'
source ~/.extra unexpected
EOF
EXTRA_ARGS_OUTPUT=$TMP/extra-args.rc
bash "$RESOLVER" --shell bash --home "$EXTRA_ARGS_HOME" --output "$EXTRA_ARGS_OUTPUT" 2>"$TMP/extra-args.err"
assert_contains "$EXTRA_ARGS_OUTPUT" 'source ~/.extra unexpected'
if grep -Fq 'EXTRA_ARGS_TARGET=1' "$EXTRA_ARGS_OUTPUT"; then
  fail "source with extra arguments must not be inlined"
fi
assert_contains "$TMP/extra-args.err" "unresolved source"

CONDITIONAL_HOME=$TMP/conditional-home
mkdir -p "$CONDITIONAL_HOME"
cat > "$CONDITIONAL_HOME/.conditional" <<'EOF'
CONDITIONAL_TARGET=1
EOF
cat > "$CONDITIONAL_HOME/.bashrc" <<'EOF'
if false; then source ~/.conditional; fi
if false; then
  source ~/.conditional
fi
EOF
CONDITIONAL_OUTPUT=$TMP/conditional.rc
bash "$RESOLVER" --shell bash --home "$CONDITIONAL_HOME" --output "$CONDITIONAL_OUTPUT" 2>"$TMP/conditional.err"
assert_contains "$CONDITIONAL_OUTPUT" 'if false; then source ~/.conditional; fi'
assert_contains "$CONDITIONAL_OUTPUT" '  source ~/.conditional'
if grep -Fq 'CONDITIONAL_TARGET=1' "$CONDITIONAL_OUTPUT"; then
  fail "conditional source must not be inlined"
fi
assert_contains "$TMP/conditional.err" "unresolved source"

if bash "$RESOLVER" --shell fish --home "$HOME_ROOT" --output "$TMP/invalid.rc"; then
  fail "unsupported shell should return status 2"
elif [[ $? -ne 2 ]]; then
  fail "unsupported shell returned unexpected status"
fi

printf 'PASS: pi-shell-rc\n'
