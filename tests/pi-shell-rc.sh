#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
RESOLVER=$ROOT/bin/pi-shell-rc
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert_contains() { grep -Fq -- "$2" "$1" || fail "$1 does not contain $2"; }
assert_once() { [[ $(grep -Fc -- "$2" "$1") -eq 1 ]] || fail "$2 is not included once"; }
assert_count() { [[ $(grep -Fc -- "$2" "$1") -eq "$3" ]] || fail "$2 does not occur $3 times"; }
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
assert_once "$OUTPUT" 'export FROM_BASHRC=1'
assert_once "$OUTPUT" "alias ll='ls -la'"
[[ $(stat -f '%Lp' "$OUTPUT") == 644 ]] || fail "generated rc must be mode 0644"

ROOT_CONDITIONAL_HOME=$TMP/root-conditional-home
ROOT_CONTAINER_HOME=$TMP/root-container-home
mkdir -p "$ROOT_CONDITIONAL_HOME" "$ROOT_CONTAINER_HOME"
cat > "$ROOT_CONDITIONAL_HOME/.bash_profile" <<'EOF'
if true; then source "$HOME/.bashrc"; fi
EOF
cat > "$ROOT_CONDITIONAL_HOME/.bashrc" <<'EOF'
(( ROOT_RC_COUNT=${ROOT_RC_COUNT:-0} + 1 ))
EOF
ROOT_CONDITIONAL_OUTPUT=$TMP/root-conditional.rc
bash "$RESOLVER" --shell bash --home "$ROOT_CONDITIONAL_HOME" --output "$ROOT_CONDITIONAL_OUTPUT"
assert_once "$ROOT_CONDITIONAL_OUTPUT" '(( ROOT_RC_COUNT=${ROOT_RC_COUNT:-0} + 1 ))'
bash -n "$ROOT_CONDITIONAL_OUTPUT" || fail "conditional root RC output must be valid Bash"
ROOT_CONDITIONAL_SHELL_OUTPUT=$(HOME="$ROOT_CONTAINER_HOME" \
  /bin/bash --rcfile "$ROOT_CONDITIONAL_OUTPUT" -i -c \
  'printf "root RC count=%s\n" "$ROOT_RC_COUNT"' 2>/dev/null || true)
[[ "$ROOT_CONDITIONAL_SHELL_OUTPUT" == *'root RC count=1'* ]] ||
  fail "a conditionally included startup root was duplicated"

CONDITIONAL_HOME=$TMP/conditional-home
CONTAINER_HOME=$TMP/container-home
mkdir -p "$CONDITIONAL_HOME" "$CONTAINER_HOME"
cat > "$CONDITIONAL_HOME/.bash_profile" <<'EOF'
if [ -f "$HOME/.profile" ]; then
  . "$HOME/.profile"
fi
if [ "${PI_TEST_SKIP_BASHRC:-}" = 1 ]; then # fi is only a comment
  source "$HOME/.bashrc"
fi
EOF
cat > "$CONDITIONAL_HOME/.bashrc" <<'EOF'
[[ -s "$HOME/.guarded-profile" ]] && source "$HOME/.guarded-profile"
if [ -f "$HOME/.same-line-profile" ]; then source "$HOME/.same-line-profile"; fi
ZSH="$HOME/.oh-my-zsh"
source "$ZSH/oh-my-zsh.sh"
source "$HOME/.orbstack/shell/init.zsh" 2>/dev/null || :
EOF
cat > "$CONDITIONAL_HOME/.profile" <<'EOF'
. "$HOME/.profile-nested"
EOF
cat > "$CONDITIONAL_HOME/.profile-nested" <<'EOF'
export PI_PROFILE_VAR=profile-loaded
alias pi_profile_alias='echo alias-used'
pi_profile_function() { echo function-used; }
EOF
cat > "$CONDITIONAL_HOME/.guarded-profile" <<'EOF'
export PI_GUARDED_VAR=guarded-loaded
EOF
cat > "$CONDITIONAL_HOME/.same-line-profile" <<'EOF'
export PI_SAME_LINE_VAR=same-line-loaded
EOF
mkdir -p "$CONDITIONAL_HOME/.oh-my-zsh" "$CONDITIONAL_HOME/.orbstack/shell"
cat > "$CONDITIONAL_HOME/.oh-my-zsh/oh-my-zsh.sh" <<'EOF'
export PI_ZSH_VAR=zsh-loaded
alias pi_zsh_alias='echo zsh-alias-used'
EOF
cat > "$CONDITIONAL_HOME/.orbstack/shell/init.zsh" <<'EOF'
pi_orbstack_function() { echo orbstack-function-used; }
EOF
CONDITIONAL_OUTPUT=$TMP/conditional-profile.rc
bash "$RESOLVER" --shell bash --home "$CONDITIONAL_HOME" --output "$CONDITIONAL_OUTPUT" 2>"$TMP/conditional-profile.err"
assert_contains "$CONDITIONAL_OUTPUT" 'export PI_PROFILE_VAR=profile-loaded'
assert_contains "$CONDITIONAL_OUTPUT" "alias pi_profile_alias='echo alias-used'"
assert_contains "$CONDITIONAL_OUTPUT" 'pi_profile_function() { echo function-used; }'
assert_contains "$CONDITIONAL_OUTPUT" 'export PI_GUARDED_VAR=guarded-loaded'
assert_contains "$CONDITIONAL_OUTPUT" 'export PI_SAME_LINE_VAR=same-line-loaded'
assert_contains "$CONDITIONAL_OUTPUT" 'export PI_ZSH_VAR=zsh-loaded'
assert_contains "$CONDITIONAL_OUTPUT" "alias pi_zsh_alias='echo zsh-alias-used'"
assert_contains "$CONDITIONAL_OUTPUT" 'pi_orbstack_function() { echo orbstack-function-used; }'
if grep -Fq 'source ~/.profile' "$CONDITIONAL_OUTPUT" ||
  grep -Fq '. "$HOME/.profile"' "$CONDITIONAL_OUTPUT" ||
  grep -Fq 'source "$ZSH/oh-my-zsh.sh"' "$CONDITIONAL_OUTPUT" ||
  grep -Fq '.same-line-profile"; fi' "$CONDITIONAL_OUTPUT" ||
  grep -Fq '.orbstack/shell/init.zsh" 2>/dev/null' "$CONDITIONAL_OUTPUT" ||
  grep -Fq '.guarded-profile" ]] && source' "$CONDITIONAL_OUTPUT"; then
  fail "conditional profile source should be flattened"
fi
CONDITIONAL_SHELL_OUTPUT=$(HOME="$CONTAINER_HOME" \
  /bin/bash --rcfile "$CONDITIONAL_OUTPUT" -i -c \
  'printf "variable=%s guarded=%s same-line=%s zsh=%s\n" "${PI_PROFILE_VAR:-missing}" "${PI_GUARDED_VAR:-missing}" "${PI_SAME_LINE_VAR:-missing}" "${PI_ZSH_VAR:-missing}"; pi_profile_alias; pi_profile_function; pi_zsh_alias; pi_orbstack_function' 2>/dev/null || true)
[[ "$CONDITIONAL_SHELL_OUTPUT" == *'variable=profile-loaded'* ]] || fail "profile variable was not loaded in the container shell"
[[ "$CONDITIONAL_SHELL_OUTPUT" == *'guarded=guarded-loaded'* ]] || fail "guarded profile was not loaded in the container shell"
[[ "$CONDITIONAL_SHELL_OUTPUT" == *'same-line=same-line-loaded'* ]] || fail "same-line guarded profile was not loaded in the container shell"
[[ "$CONDITIONAL_SHELL_OUTPUT" == *'zsh=zsh-loaded'* ]] || fail "variable-based profile was not loaded in the container shell"
[[ "$CONDITIONAL_SHELL_OUTPUT" == *'alias-used'* ]] || fail "profile alias was not loaded in the container shell"
[[ "$CONDITIONAL_SHELL_OUTPUT" == *'function-used'* ]] || fail "profile function was not loaded in the container shell"
[[ "$CONDITIONAL_SHELL_OUTPUT" == *'zsh-alias-used'* ]] || fail "variable-based alias was not loaded in the container shell"
[[ "$CONDITIONAL_SHELL_OUTPUT" == *'orbstack-function-used'* ]] || fail "suffixed source function was not loaded in the container shell"

QUOTE_HOME=$TMP/quote-home
mkdir -p "$QUOTE_HOME"
cat > "$QUOTE_HOME/file" <<'EOF'
QUOTED_TARGET=1
EOF
cat > "$QUOTE_HOME/.bashrc" <<'EOF'
source '$HOME/file'
source '~/.file'
source "$HOME/file"
EOF
QUOTE_OUTPUT=$TMP/quote.rc
bash "$RESOLVER" --shell bash --home "$QUOTE_HOME" --output "$QUOTE_OUTPUT" 2>"$TMP/quote.err"
assert_contains "$QUOTE_OUTPUT" "source '\$HOME/file'"
assert_contains "$QUOTE_OUTPUT" "source '~/.file'"
assert_once "$QUOTE_OUTPUT" QUOTED_TARGET=1
assert_count "$TMP/quote.err" "unresolved source" 2

MALFORMED_HOME=$TMP/malformed-home
mkdir -p "$MALFORMED_HOME"
cat > "$MALFORMED_HOME/.bashrc" <<'EOF'
source
.
EOF
MALFORMED_OUTPUT=$TMP/malformed.rc
bash "$RESOLVER" --shell bash --home "$MALFORMED_HOME" --output "$MALFORMED_OUTPUT" 2>"$TMP/malformed.err"
assert_contains "$MALFORMED_OUTPUT" source
assert_contains "$MALFORMED_OUTPUT" .
assert_count "$TMP/malformed.err" "unresolved source" 2

ROOT_SYMLINK_HOME=$TMP/root-symlink-home
mkdir -p "$ROOT_SYMLINK_HOME"
cat > "$TMP/outside-root-symlink" <<'EOF'
ROOT_SYMLINK_ESCAPE=1
EOF
ln -s "$TMP/outside-root-symlink" "$ROOT_SYMLINK_HOME/.bashrc"
ROOT_SYMLINK_OUTPUT=$TMP/root-symlink.rc
bash "$RESOLVER" --shell bash --home "$ROOT_SYMLINK_HOME" --output "$ROOT_SYMLINK_OUTPUT" 2>"$TMP/root-symlink.err"
[[ ! -s "$ROOT_SYMLINK_OUTPUT" ]] || fail "startup-root symlink escape must not be read"
assert_contains "$TMP/root-symlink.err" "unresolved startup rc"

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

ZSH_RUNTIME_HOME=$TMP/zsh-runtime-home
ZSH_CONTAINER_HOME=$TMP/zsh-container-home
ZSH_DOTDIR=$TMP/zsh-dotdir
mkdir -p "$ZSH_RUNTIME_HOME/.oh-my-zsh" "$ZSH_RUNTIME_HOME/.zshrc-fragments" \
  "$ZSH_CONTAINER_HOME" "$ZSH_DOTDIR"
cat > "$ZSH_RUNTIME_HOME/.zprofile" <<'EOF'
if [ -f "$HOME/.zprofile-fragment" ]; then
  source "$HOME/.zprofile-fragment"
fi
EOF
cat > "$ZSH_RUNTIME_HOME/.zprofile-fragment" <<'EOF'
export PI_ZPROFILE_VAR=zprofile-loaded
EOF
cat > "$ZSH_RUNTIME_HOME/.zshrc" <<'EOF'
ZSH="$HOME/.oh-my-zsh"
source "$ZSH/oh-my-zsh.sh"
[[ -s "$HOME/.zshrc-fragments/aliases.zsh" ]] && source "$HOME/.zshrc-fragments/aliases.zsh"
EOF
cat > "$ZSH_RUNTIME_HOME/.oh-my-zsh/oh-my-zsh.sh" <<'EOF'
export PI_ZSHRC_VAR=zshrc-loaded
pi_zsh_test_function() { print -r -- zsh-function-used; }
EOF
cat > "$ZSH_RUNTIME_HOME/.zshrc-fragments/aliases.zsh" <<'EOF'
alias pi_zsh_test_alias='print -r -- zsh-alias-used'
EOF
cat > "$ZSH_RUNTIME_HOME/.zlogin" <<'EOF'
. "$HOME/.zlogin-fragment"
EOF
cat > "$ZSH_RUNTIME_HOME/.zlogin-fragment" <<'EOF'
export PI_ZLOGIN_VAR=zlogin-loaded
EOF
ZSH_RUNTIME_OUTPUT=$TMP/zsh-runtime.rc
bash "$RESOLVER" --shell zsh --home "$ZSH_RUNTIME_HOME" --output "$ZSH_RUNTIME_OUTPUT" 2>"$TMP/zsh-runtime.err"
ln -s "$ZSH_RUNTIME_OUTPUT" "$ZSH_DOTDIR/.zshrc"
ZSH_RUNTIME_SHELL_OUTPUT=$(HOME="$ZSH_CONTAINER_HOME" ZDOTDIR="$ZSH_DOTDIR" \
  /bin/zsh -i -c \
  'print -r -- "profile=$PI_ZPROFILE_VAR rc=$PI_ZSHRC_VAR login=$PI_ZLOGIN_VAR"; eval pi_zsh_test_alias; pi_zsh_test_function' 2>/dev/null || true)
[[ "$ZSH_RUNTIME_SHELL_OUTPUT" == *'profile=zprofile-loaded rc=zshrc-loaded login=zlogin-loaded'* ]] ||
  fail "zsh profile, rc, or login variables were not loaded in the container shell"
[[ "$ZSH_RUNTIME_SHELL_OUTPUT" == *'zsh-alias-used'* ]] || fail "zsh alias was not loaded in the container shell"
[[ "$ZSH_RUNTIME_SHELL_OUTPUT" == *'zsh-function-used'* ]] || fail "zsh function was not loaded in the container shell"

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

UNSET_HOME=$TMP/unset-home
mkdir -p "$UNSET_HOME/.oh-my-zsh"
cat > "$UNSET_HOME/.bashrc" <<'EOF'
ZSH="$HOME/.oh-my-zsh"
unset ZSH
source "$ZSH/oh-my-zsh.sh"
EOF
cat > "$UNSET_HOME/.oh-my-zsh/oh-my-zsh.sh" <<'EOF'
UNSET_PATH_WAS_INLINED=1
EOF
UNSET_OUTPUT=$TMP/unset.rc
bash "$RESOLVER" --shell bash --home "$UNSET_HOME" --output "$UNSET_OUTPUT" 2>"$TMP/unset.err"
assert_contains "$UNSET_OUTPUT" 'source "$ZSH/oh-my-zsh.sh"'
if grep -Fq 'UNSET_PATH_WAS_INLINED=1' "$UNSET_OUTPUT"; then
  fail "unset variable must not retain a stale source path"
fi
assert_contains "$TMP/unset.err" "unresolved source"

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

MULTI_SOURCE_HOME=$TMP/multi-source-home
mkdir -p "$MULTI_SOURCE_HOME"
cat > "$MULTI_SOURCE_HOME/.first" <<'EOF'
MULTI_SOURCE_FIRST=1
EOF
cat > "$MULTI_SOURCE_HOME/.second" <<'EOF'
MULTI_SOURCE_SECOND=1
EOF
cat > "$MULTI_SOURCE_HOME/.bashrc" <<'EOF'
source "$HOME/.first"; source "$HOME/.second"
EOF
MULTI_SOURCE_OUTPUT=$TMP/multi-source.rc
bash "$RESOLVER" --shell bash --home "$MULTI_SOURCE_HOME" --output "$MULTI_SOURCE_OUTPUT" 2>"$TMP/multi-source.err"
assert_contains "$MULTI_SOURCE_OUTPUT" 'source "$HOME/.first"; source "$HOME/.second"'
if grep -Fq 'MULTI_SOURCE_FIRST=1' "$MULTI_SOURCE_OUTPUT" ||
  grep -Fq 'MULTI_SOURCE_SECOND=1' "$MULTI_SOURCE_OUTPUT"; then
  fail "a multi-source line must not be partially flattened"
fi
assert_contains "$TMP/multi-source.err" "unresolved source"

MULTI_BRANCH_HOME=$TMP/multi-branch-home
mkdir -p "$MULTI_BRANCH_HOME"
cat > "$MULTI_BRANCH_HOME/.first" <<'EOF'
MULTI_BRANCH_FIRST=1
EOF
cat > "$MULTI_BRANCH_HOME/.second" <<'EOF'
MULTI_BRANCH_SECOND=1
EOF
cat > "$MULTI_BRANCH_HOME/.bashrc" <<'EOF'
if false; then source ~/.first; else source ~/.second; fi
EOF
MULTI_BRANCH_OUTPUT=$TMP/multi-branch.rc
bash "$RESOLVER" --shell bash --home "$MULTI_BRANCH_HOME" --output "$MULTI_BRANCH_OUTPUT" 2>"$TMP/multi-branch.err"
assert_contains "$MULTI_BRANCH_OUTPUT" 'if false; then source ~/.first; else source ~/.second; fi'
if grep -Fq 'MULTI_BRANCH_FIRST=1' "$MULTI_BRANCH_OUTPUT" ||
  grep -Fq 'MULTI_BRANCH_SECOND=1' "$MULTI_BRANCH_OUTPUT"; then
  fail "a multi-branch source line must not be partially flattened"
fi
assert_contains "$TMP/multi-branch.err" "unresolved source"

CONDITIONAL_SOURCE_HOME=$TMP/conditional-source-home
mkdir -p "$CONDITIONAL_SOURCE_HOME"
cat > "$CONDITIONAL_SOURCE_HOME/.conditional" <<'EOF'
CONDITIONAL_TARGET=1
EOF
cat > "$CONDITIONAL_SOURCE_HOME/.bashrc" <<'EOF'
if false; then source ~/.conditional; fi
if false; then
  source ~/.conditional
fi
EOF
CONDITIONAL_SOURCE_OUTPUT=$TMP/conditional.rc
bash "$RESOLVER" --shell bash --home "$CONDITIONAL_SOURCE_HOME" --output "$CONDITIONAL_SOURCE_OUTPUT" 2>"$TMP/conditional.err"
assert_contains "$CONDITIONAL_SOURCE_OUTPUT" 'if false; then {'
assert_count "$CONDITIONAL_SOURCE_OUTPUT" 'source ~/.conditional' 0
assert_count "$CONDITIONAL_SOURCE_OUTPUT" 'CONDITIONAL_TARGET=1' 2
assert_count "$TMP/conditional.err" "unresolved source" 0

ONE_LINE_HOME=$TMP/one-line-home
mkdir -p "$ONE_LINE_HOME"
cat > "$ONE_LINE_HOME/.conditional" <<'EOF'
ONE_LINE_CONDITIONAL_TARGET=1
EOF
cat > "$ONE_LINE_HOME/.after" <<'EOF'
ONE_LINE_AFTER_TARGET=1
EOF
cat > "$ONE_LINE_HOME/.bashrc" <<'EOF'
if false; then source ~/.conditional; fi
source ~/.after
EOF
ONE_LINE_OUTPUT=$TMP/one-line.rc
bash "$RESOLVER" --shell bash --home "$ONE_LINE_HOME" --output "$ONE_LINE_OUTPUT" 2>"$TMP/one-line.err"
assert_contains "$ONE_LINE_OUTPUT" 'if false; then {'
assert_contains "$ONE_LINE_OUTPUT" ONE_LINE_AFTER_TARGET=1
assert_once "$ONE_LINE_OUTPUT" ONE_LINE_CONDITIONAL_TARGET=1
assert_count "$TMP/one-line.err" "unresolved source" 0

CONDITIONAL_FORMS_HOME=$TMP/conditional-forms-home
mkdir -p "$CONDITIONAL_FORMS_HOME"
cat > "$CONDITIONAL_FORMS_HOME/.conditional" <<'EOF'
CONDITIONAL_FORMS_TARGET=$(( ${CONDITIONAL_FORMS_TARGET:-0} + 1 ))
EOF
cat > "$CONDITIONAL_FORMS_HOME/.bashrc" <<'EOF'
if false; then
  :
elif true; then source ~/.conditional; fi
if false; then
  :
else source ~/.conditional; fi
if true; then source ~/.conditional; fi
true && source ~/.conditional
false || source ~/.conditional
EOF
CONDITIONAL_FORMS_OUTPUT=$TMP/conditional-forms.rc
bash "$RESOLVER" --shell bash --home "$CONDITIONAL_FORMS_HOME" --output "$CONDITIONAL_FORMS_OUTPUT" 2>"$TMP/conditional-forms.err"
assert_contains "$CONDITIONAL_FORMS_OUTPUT" 'elif true; then {'
assert_contains "$CONDITIONAL_FORMS_OUTPUT" 'else {'
assert_contains "$CONDITIONAL_FORMS_OUTPUT" 'if true; then {'
assert_contains "$CONDITIONAL_FORMS_OUTPUT" 'true && {'
assert_contains "$CONDITIONAL_FORMS_OUTPUT" 'false || {'
assert_count "$CONDITIONAL_FORMS_OUTPUT" 'CONDITIONAL_FORMS_TARGET=$(( ${CONDITIONAL_FORMS_TARGET:-0} + 1 ))' 5
assert_count "$TMP/conditional-forms.err" "unresolved source" 0
bash -n "$CONDITIONAL_FORMS_OUTPUT" || fail "resolved conditional source output must be valid Bash"
CONDITIONAL_FORMS_SHELL_OUTPUT=$(HOME="$CONTAINER_HOME" \
  /bin/bash --rcfile "$CONDITIONAL_FORMS_OUTPUT" -i -c \
  'printf "conditional count=%s\n" "$CONDITIONAL_FORMS_TARGET"' 2>/dev/null || true)
[[ "$CONDITIONAL_FORMS_SHELL_OUTPUT" == *'conditional count=5'* ]] ||
  fail "resolved conditional source forms did not execute in Bash"

OUTSIDE_SOURCE_HOME=$TMP/outside-source-home
OUTSIDE_SOURCE_FILE=$TMP/outside-source.sh
mkdir -p "$OUTSIDE_SOURCE_HOME"
cat > "$OUTSIDE_SOURCE_FILE" <<'EOF'
OUTSIDE_HOME_SOURCE=1
EOF
cat > "$OUTSIDE_SOURCE_HOME/.bashrc" <<EOF
OUTSIDE_RC="$OUTSIDE_SOURCE_FILE"
source "\$OUTSIDE_RC"
EOF
OUTSIDE_SOURCE_OUTPUT=$TMP/outside-source.rc
bash "$RESOLVER" --shell bash --home "$OUTSIDE_SOURCE_HOME" --output "$OUTSIDE_SOURCE_OUTPUT" 2>"$TMP/outside-source.err"
assert_contains "$OUTSIDE_SOURCE_OUTPUT" 'source "$OUTSIDE_RC"'
if grep -Fq 'OUTSIDE_HOME_SOURCE=1' "$OUTSIDE_SOURCE_OUTPUT"; then
  fail "source outside host home must not be inlined"
fi
assert_contains "$TMP/outside-source.err" "unresolved source"

if bash "$RESOLVER" --shell fish --home "$HOME_ROOT" --output "$TMP/invalid.rc"; then
  fail "unsupported shell should return status 2"
elif [[ $? -ne 2 ]]; then
  fail "unsupported shell returned unexpected status"
fi

printf 'PASS: pi-shell-rc\n'
