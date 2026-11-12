#!/usr/bin/env bash
# bin/pi-shell-rc: resolving host startup files into one generated rc.
set -euo pipefail

source "$(dirname -- "${BASH_SOURCE[0]}")/lib/common.bash"
RESOLVER=$ROOT/bin/pi-shell-rc

assert_order() {
  local file=$1 previous=0 marker line
  for marker in "${@:2}"; do
    line=$(grep -nF -- "$marker" "$file" | head -n1 | cut -d: -f1) || fail "missing marker $marker"
    (( line > previous )) || fail "marker $marker is out of order"
    previous=$line
  done
}

HOME_ROOT=$TMP_DIR/bash-home
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
OUTPUT=$TMP_DIR/bash.rc
bash "$RESOLVER" --shell bash --home "$HOME_ROOT" --output "$OUTPUT"
assert_order "$OUTPUT" FROM_PROFILE FROM_BASHRC "alias ll='ls -la'"
assert_file_count "$OUTPUT" 'export FROM_BASHRC=1' 1
assert_file_count "$OUTPUT" "alias ll='ls -la'" 1
[[ $(stat -f '%Lp' "$OUTPUT") == 644 ]] || fail "generated rc must be mode 0644"

ROOT_CONDITIONAL_HOME=$TMP_DIR/root-conditional-home
ROOT_CONTAINER_HOME=$TMP_DIR/root-container-home
mkdir -p "$ROOT_CONDITIONAL_HOME" "$ROOT_CONTAINER_HOME"
cat > "$ROOT_CONDITIONAL_HOME/.bash_profile" <<'EOF'
if true; then source "$HOME/.bashrc"; fi
EOF
cat > "$ROOT_CONDITIONAL_HOME/.bashrc" <<'EOF'
(( ROOT_RC_COUNT=${ROOT_RC_COUNT:-0} + 1 ))
EOF
ROOT_CONDITIONAL_OUTPUT=$TMP_DIR/root-conditional.rc
bash "$RESOLVER" --shell bash --home "$ROOT_CONDITIONAL_HOME" --output "$ROOT_CONDITIONAL_OUTPUT"
assert_file_count "$ROOT_CONDITIONAL_OUTPUT" '(( ROOT_RC_COUNT=${ROOT_RC_COUNT:-0} + 1 ))' 1
bash -n "$ROOT_CONDITIONAL_OUTPUT" || fail "conditional root RC output must be valid Bash"
ROOT_CONDITIONAL_SHELL_OUTPUT=$(HOME="$ROOT_CONTAINER_HOME" \
  /bin/bash --rcfile "$ROOT_CONDITIONAL_OUTPUT" -i -c \
  'printf "root RC count=%s\n" "$ROOT_RC_COUNT"' 2>/dev/null || true)
[[ "$ROOT_CONDITIONAL_SHELL_OUTPUT" == *'root RC count=1'* ]] ||
  fail "a conditionally included startup root was duplicated"

CONDITIONAL_HOME=$TMP_DIR/conditional-home
CONTAINER_HOME=$TMP_DIR/container-home
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
CONDITIONAL_OUTPUT=$TMP_DIR/conditional-profile.rc
bash "$RESOLVER" --shell bash --home "$CONDITIONAL_HOME" --output "$CONDITIONAL_OUTPUT" 2>"$TMP_DIR/conditional-profile.err"
assert_file_has "$CONDITIONAL_OUTPUT" 'export PI_PROFILE_VAR=profile-loaded'
assert_file_has "$CONDITIONAL_OUTPUT" "alias pi_profile_alias='echo alias-used'"
assert_file_has "$CONDITIONAL_OUTPUT" 'pi_profile_function() { echo function-used; }'
assert_file_has "$CONDITIONAL_OUTPUT" 'export PI_GUARDED_VAR=guarded-loaded'
assert_file_has "$CONDITIONAL_OUTPUT" 'export PI_SAME_LINE_VAR=same-line-loaded'
assert_file_has "$CONDITIONAL_OUTPUT" 'export PI_ZSH_VAR=zsh-loaded'
assert_file_has "$CONDITIONAL_OUTPUT" "alias pi_zsh_alias='echo zsh-alias-used'"
assert_file_has "$CONDITIONAL_OUTPUT" 'pi_orbstack_function() { echo orbstack-function-used; }'
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

QUOTE_HOME=$TMP_DIR/quote-home
mkdir -p "$QUOTE_HOME"
cat > "$QUOTE_HOME/file" <<'EOF'
QUOTED_TARGET=1
EOF
cat > "$QUOTE_HOME/.bashrc" <<'EOF'
source '$HOME/file'
source '~/.file'
source "$HOME/file"
EOF
QUOTE_OUTPUT=$TMP_DIR/quote.rc
bash "$RESOLVER" --shell bash --home "$QUOTE_HOME" --output "$QUOTE_OUTPUT" 2>"$TMP_DIR/quote.err"
assert_file_has "$QUOTE_OUTPUT" "source '\$HOME/file'"
assert_file_has "$QUOTE_OUTPUT" "source '~/.file'"
assert_file_count "$QUOTE_OUTPUT" QUOTED_TARGET=1 1
assert_file_count "$TMP_DIR/quote.err" "unresolved source" 2

MALFORMED_HOME=$TMP_DIR/malformed-home
mkdir -p "$MALFORMED_HOME"
cat > "$MALFORMED_HOME/.bashrc" <<'EOF'
source
.
EOF
MALFORMED_OUTPUT=$TMP_DIR/malformed.rc
bash "$RESOLVER" --shell bash --home "$MALFORMED_HOME" --output "$MALFORMED_OUTPUT" 2>"$TMP_DIR/malformed.err"
assert_file_has "$MALFORMED_OUTPUT" source
assert_file_has "$MALFORMED_OUTPUT" .
assert_file_count "$TMP_DIR/malformed.err" "unresolved source" 2

ROOT_SYMLINK_HOME=$TMP_DIR/root-symlink-home
mkdir -p "$ROOT_SYMLINK_HOME"
cat > "$TMP_DIR/outside-root-symlink" <<'EOF'
ROOT_SYMLINK_ESCAPE=1
EOF
ln -s "$TMP_DIR/outside-root-symlink" "$ROOT_SYMLINK_HOME/.bashrc"
ROOT_SYMLINK_OUTPUT=$TMP_DIR/root-symlink.rc
bash "$RESOLVER" --shell bash --home "$ROOT_SYMLINK_HOME" --output "$ROOT_SYMLINK_OUTPUT" 2>"$TMP_DIR/root-symlink.err"
[[ ! -s "$ROOT_SYMLINK_OUTPUT" ]] || fail "startup-root symlink escape must not be read"
assert_file_has "$TMP_DIR/root-symlink.err" "unresolved startup rc"

ZSH_HOME=$TMP_DIR/zsh-home
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
ZSH_OUTPUT=$TMP_DIR/zsh.rc
bash "$RESOLVER" --shell zsh --home "$ZSH_HOME" --output "$ZSH_OUTPUT"
assert_order "$ZSH_OUTPUT" \
  ZSH_ENV_MARKER ZSH_ENV_NESTED_MARKER \
  ZSH_PROFILE_MARKER ZSH_PROFILE_NESTED_MARKER \
  ZSH_RC_MARKER ZSH_RC_NESTED_MARKER \
  ZSH_LOGIN_MARKER ZSH_LOGIN_NESTED_MARKER
assert_file_count "$ZSH_OUTPUT" ZSH_ENV_NESTED_MARKER 1

ZSH_RUNTIME_HOME=$TMP_DIR/zsh-runtime-home
ZSH_CONTAINER_HOME=$TMP_DIR/zsh-container-home
ZSH_DOTDIR=$TMP_DIR/zsh-dotdir
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
ZSH_RUNTIME_OUTPUT=$TMP_DIR/zsh-runtime.rc
bash "$RESOLVER" --shell zsh --home "$ZSH_RUNTIME_HOME" --output "$ZSH_RUNTIME_OUTPUT" 2>"$TMP_DIR/zsh-runtime.err"
ln -s "$ZSH_RUNTIME_OUTPUT" "$ZSH_DOTDIR/.zshrc"
ZSH_RUNTIME_SHELL_OUTPUT=$(HOME="$ZSH_CONTAINER_HOME" ZDOTDIR="$ZSH_DOTDIR" \
  /bin/zsh -i -c \
  'print -r -- "profile=$PI_ZPROFILE_VAR rc=$PI_ZSHRC_VAR login=$PI_ZLOGIN_VAR"; eval pi_zsh_test_alias; pi_zsh_test_function' 2>/dev/null || true)
[[ "$ZSH_RUNTIME_SHELL_OUTPUT" == *'profile=zprofile-loaded rc=zshrc-loaded login=zlogin-loaded'* ]] ||
  fail "zsh profile, rc, or login variables were not loaded in the container shell"
[[ "$ZSH_RUNTIME_SHELL_OUTPUT" == *'zsh-alias-used'* ]] || fail "zsh alias was not loaded in the container shell"
[[ "$ZSH_RUNTIME_SHELL_OUTPUT" == *'zsh-function-used'* ]] || fail "zsh function was not loaded in the container shell"

MISSING_OUTPUT=$TMP_DIR/missing.rc
MISSING_HOME=$TMP_DIR/missing-home
mkdir -p "$MISSING_HOME"
bash "$RESOLVER" --shell bash --home "$MISSING_HOME" --output "$MISSING_OUTPUT" 2>"$TMP_DIR/missing.err"
[[ ! -s "$MISSING_OUTPUT" ]] || fail "missing roots should produce an empty rc"
assert_file_has "$TMP_DIR/missing.err" "missing startup rc"

CYCLE_HOME=$TMP_DIR/cycle-home
mkdir -p "$CYCLE_HOME"
cat > "$CYCLE_HOME/.bashrc" <<'EOF'
CYCLE_A=1
source ~/.cycle
EOF
cat > "$CYCLE_HOME/.cycle" <<'EOF'
CYCLE_B=1
. ~/.bashrc
EOF
CYCLE_OUTPUT=$TMP_DIR/cycle.rc
bash "$RESOLVER" --shell bash --home "$CYCLE_HOME" --output "$CYCLE_OUTPUT" 2>"$TMP_DIR/cycle.err"
assert_file_count "$CYCLE_OUTPUT" CYCLE_A=1 1
assert_file_count "$CYCLE_OUTPUT" CYCLE_B=1 1
assert_file_has "$TMP_DIR/cycle.err" "cyclic source"

DYNAMIC_HOME=$TMP_DIR/dynamic-home
mkdir -p "$DYNAMIC_HOME"
cat > "$DYNAMIC_HOME/.bashrc" <<'EOF'
. "$HOME/${RC_NAME}"
DYNAMIC_MARKER=1
EOF
DYNAMIC_OUTPUT=$TMP_DIR/dynamic.rc
bash "$RESOLVER" --shell bash --home "$DYNAMIC_HOME" --output "$DYNAMIC_OUTPUT" 2>"$TMP_DIR/dynamic.err"
assert_file_has "$DYNAMIC_OUTPUT" '. "$HOME/${RC_NAME}"'
assert_file_has "$TMP_DIR/dynamic.err" "unresolved source"

UNSET_HOME=$TMP_DIR/unset-home
mkdir -p "$UNSET_HOME/.oh-my-zsh"
cat > "$UNSET_HOME/.bashrc" <<'EOF'
ZSH="$HOME/.oh-my-zsh"
unset ZSH
source "$ZSH/oh-my-zsh.sh"
EOF
cat > "$UNSET_HOME/.oh-my-zsh/oh-my-zsh.sh" <<'EOF'
UNSET_PATH_WAS_INLINED=1
EOF
UNSET_OUTPUT=$TMP_DIR/unset.rc
bash "$RESOLVER" --shell bash --home "$UNSET_HOME" --output "$UNSET_OUTPUT" 2>"$TMP_DIR/unset.err"
assert_file_has "$UNSET_OUTPUT" 'source "$ZSH/oh-my-zsh.sh"'
if grep -Fq 'UNSET_PATH_WAS_INLINED=1' "$UNSET_OUTPUT"; then
  fail "unset variable must not retain a stale source path"
fi
assert_file_has "$TMP_DIR/unset.err" "unresolved source"

TRAVERSAL_HOME=$TMP_DIR/traversal-home
mkdir -p "$TRAVERSAL_HOME"
cat > "$TMP_DIR/outside-traversal" <<'EOF'
TRAVERSAL_ESCAPE=1
EOF
cat > "$TRAVERSAL_HOME/.bashrc" <<'EOF'
source "$HOME/../outside-traversal"
EOF
TRAVERSAL_OUTPUT=$TMP_DIR/traversal.rc
bash "$RESOLVER" --shell bash --home "$TRAVERSAL_HOME" --output "$TRAVERSAL_OUTPUT" 2>"$TMP_DIR/traversal.err"
assert_file_has "$TRAVERSAL_OUTPUT" 'source "$HOME/../outside-traversal"'
if grep -Fq 'TRAVERSAL_ESCAPE=1' "$TRAVERSAL_OUTPUT"; then
  fail "traversal source must not be inlined"
fi
assert_file_has "$TMP_DIR/traversal.err" "unresolved source"

SYMLINK_HOME=$TMP_DIR/symlink-home
mkdir -p "$SYMLINK_HOME"
cat > "$TMP_DIR/outside-symlink" <<'EOF'
SYMLINK_ESCAPE=1
EOF
ln -s "$TMP_DIR/outside-symlink" "$SYMLINK_HOME/.outside-link"
cat > "$SYMLINK_HOME/.bashrc" <<'EOF'
source ~/.outside-link
EOF
SYMLINK_OUTPUT=$TMP_DIR/symlink.rc
bash "$RESOLVER" --shell bash --home "$SYMLINK_HOME" --output "$SYMLINK_OUTPUT" 2>"$TMP_DIR/symlink.err"
assert_file_has "$SYMLINK_OUTPUT" 'source ~/.outside-link'
if grep -Fq 'SYMLINK_ESCAPE=1' "$SYMLINK_OUTPUT"; then
  fail "symlink escape must not be inlined"
fi
assert_file_has "$TMP_DIR/symlink.err" "unresolved source"

EXTRA_ARGS_HOME=$TMP_DIR/extra-args-home
mkdir -p "$EXTRA_ARGS_HOME"
cat > "$EXTRA_ARGS_HOME/.extra" <<'EOF'
EXTRA_ARGS_TARGET=1
EOF
cat > "$EXTRA_ARGS_HOME/.bashrc" <<'EOF'
source ~/.extra unexpected
EOF
EXTRA_ARGS_OUTPUT=$TMP_DIR/extra-args.rc
bash "$RESOLVER" --shell bash --home "$EXTRA_ARGS_HOME" --output "$EXTRA_ARGS_OUTPUT" 2>"$TMP_DIR/extra-args.err"
assert_file_has "$EXTRA_ARGS_OUTPUT" 'source ~/.extra unexpected'
if grep -Fq 'EXTRA_ARGS_TARGET=1' "$EXTRA_ARGS_OUTPUT"; then
  fail "source with extra arguments must not be inlined"
fi
assert_file_has "$TMP_DIR/extra-args.err" "unresolved source"

MULTI_SOURCE_HOME=$TMP_DIR/multi-source-home
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
MULTI_SOURCE_OUTPUT=$TMP_DIR/multi-source.rc
bash "$RESOLVER" --shell bash --home "$MULTI_SOURCE_HOME" --output "$MULTI_SOURCE_OUTPUT" 2>"$TMP_DIR/multi-source.err"
assert_file_has "$MULTI_SOURCE_OUTPUT" 'source "$HOME/.first"; source "$HOME/.second"'
if grep -Fq 'MULTI_SOURCE_FIRST=1' "$MULTI_SOURCE_OUTPUT" ||
  grep -Fq 'MULTI_SOURCE_SECOND=1' "$MULTI_SOURCE_OUTPUT"; then
  fail "a multi-source line must not be partially flattened"
fi
assert_file_has "$TMP_DIR/multi-source.err" "unresolved source"

MULTI_BRANCH_HOME=$TMP_DIR/multi-branch-home
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
MULTI_BRANCH_OUTPUT=$TMP_DIR/multi-branch.rc
bash "$RESOLVER" --shell bash --home "$MULTI_BRANCH_HOME" --output "$MULTI_BRANCH_OUTPUT" 2>"$TMP_DIR/multi-branch.err"
assert_file_has "$MULTI_BRANCH_OUTPUT" 'if false; then source ~/.first; else source ~/.second; fi'
if grep -Fq 'MULTI_BRANCH_FIRST=1' "$MULTI_BRANCH_OUTPUT" ||
  grep -Fq 'MULTI_BRANCH_SECOND=1' "$MULTI_BRANCH_OUTPUT"; then
  fail "a multi-branch source line must not be partially flattened"
fi
assert_file_has "$TMP_DIR/multi-branch.err" "unresolved source"

CONDITIONAL_SOURCE_HOME=$TMP_DIR/conditional-source-home
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
CONDITIONAL_SOURCE_OUTPUT=$TMP_DIR/conditional.rc
bash "$RESOLVER" --shell bash --home "$CONDITIONAL_SOURCE_HOME" --output "$CONDITIONAL_SOURCE_OUTPUT" 2>"$TMP_DIR/conditional.err"
assert_file_has "$CONDITIONAL_SOURCE_OUTPUT" 'if false; then {'
assert_file_count "$CONDITIONAL_SOURCE_OUTPUT" 'source ~/.conditional' 0
assert_file_count "$CONDITIONAL_SOURCE_OUTPUT" 'CONDITIONAL_TARGET=1' 2
assert_file_count "$TMP_DIR/conditional.err" "unresolved source" 0

ONE_LINE_HOME=$TMP_DIR/one-line-home
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
ONE_LINE_OUTPUT=$TMP_DIR/one-line.rc
bash "$RESOLVER" --shell bash --home "$ONE_LINE_HOME" --output "$ONE_LINE_OUTPUT" 2>"$TMP_DIR/one-line.err"
assert_file_has "$ONE_LINE_OUTPUT" 'if false; then {'
assert_file_has "$ONE_LINE_OUTPUT" ONE_LINE_AFTER_TARGET=1
assert_file_count "$ONE_LINE_OUTPUT" ONE_LINE_CONDITIONAL_TARGET=1 1
assert_file_count "$TMP_DIR/one-line.err" "unresolved source" 0

CONDITIONAL_FORMS_HOME=$TMP_DIR/conditional-forms-home
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
CONDITIONAL_FORMS_OUTPUT=$TMP_DIR/conditional-forms.rc
bash "$RESOLVER" --shell bash --home "$CONDITIONAL_FORMS_HOME" --output "$CONDITIONAL_FORMS_OUTPUT" 2>"$TMP_DIR/conditional-forms.err"
assert_file_has "$CONDITIONAL_FORMS_OUTPUT" 'elif true; then {'
assert_file_has "$CONDITIONAL_FORMS_OUTPUT" 'else {'
assert_file_has "$CONDITIONAL_FORMS_OUTPUT" 'if true; then {'
assert_file_has "$CONDITIONAL_FORMS_OUTPUT" 'true && {'
assert_file_has "$CONDITIONAL_FORMS_OUTPUT" 'false || {'
assert_file_count "$CONDITIONAL_FORMS_OUTPUT" 'CONDITIONAL_FORMS_TARGET=$(( ${CONDITIONAL_FORMS_TARGET:-0} + 1 ))' 5
assert_file_count "$TMP_DIR/conditional-forms.err" "unresolved source" 0
bash -n "$CONDITIONAL_FORMS_OUTPUT" || fail "resolved conditional source output must be valid Bash"
CONDITIONAL_FORMS_SHELL_OUTPUT=$(HOME="$CONTAINER_HOME" \
  /bin/bash --rcfile "$CONDITIONAL_FORMS_OUTPUT" -i -c \
  'printf "conditional count=%s\n" "$CONDITIONAL_FORMS_TARGET"' 2>/dev/null || true)
[[ "$CONDITIONAL_FORMS_SHELL_OUTPUT" == *'conditional count=5'* ]] ||
  fail "resolved conditional source forms did not execute in Bash"

OUTSIDE_SOURCE_HOME=$TMP_DIR/outside-source-home
OUTSIDE_SOURCE_FILE=$TMP_DIR/outside-source.sh
mkdir -p "$OUTSIDE_SOURCE_HOME"
cat > "$OUTSIDE_SOURCE_FILE" <<'EOF'
OUTSIDE_HOME_SOURCE=1
EOF
cat > "$OUTSIDE_SOURCE_HOME/.bashrc" <<EOF
OUTSIDE_RC="$OUTSIDE_SOURCE_FILE"
source "\$OUTSIDE_RC"
EOF
OUTSIDE_SOURCE_OUTPUT=$TMP_DIR/outside-source.rc
bash "$RESOLVER" --shell bash --home "$OUTSIDE_SOURCE_HOME" --output "$OUTSIDE_SOURCE_OUTPUT" 2>"$TMP_DIR/outside-source.err"
assert_file_has "$OUTSIDE_SOURCE_OUTPUT" 'source "$OUTSIDE_RC"'
if grep -Fq 'OUTSIDE_HOME_SOURCE=1' "$OUTSIDE_SOURCE_OUTPUT"; then
  fail "source outside host home must not be inlined"
fi
assert_file_has "$TMP_DIR/outside-source.err" "unresolved source"

EMPTY_GUARD_HOME=$TMP_DIR/empty-guard-home
mkdir -p "$EMPTY_GUARD_HOME"
printf '# comment only\n' > "$EMPTY_GUARD_HOME/.empty"
cat > "$EMPTY_GUARD_HOME/.bashrc" <<'EOF'
[ -s "$HOME/.empty" ] && source "$HOME/.empty"
export EMPTY_GUARD_AFTER=1
EOF
EMPTY_GUARD_OUTPUT=$TMP_DIR/empty-guard.rc
bash "$RESOLVER" --shell bash --home "$EMPTY_GUARD_HOME" --output "$EMPTY_GUARD_OUTPUT" 2>"$TMP_DIR/empty-guard.err"
bash -n "$EMPTY_GUARD_OUTPUT" || fail "guarded source of an empty file must produce valid Bash"
assert_file_count "$EMPTY_GUARD_OUTPUT" 'export EMPTY_GUARD_AFTER=1' 1

if bash "$RESOLVER" --shell fish --home "$HOME_ROOT" --output "$TMP_DIR/invalid.rc"; then
  fail "unsupported shell should return status 2"
elif [[ $? -ne 2 ]]; then
  fail "unsupported shell returned unexpected status"
fi

timeout_command=()
if command -v timeout >/dev/null 2>&1; then timeout_command=(timeout 20); elif command -v gtimeout >/dev/null 2>&1; then timeout_command=(gtimeout 20); fi
LOOP_HOME=$TMP_DIR/loop-home
mkdir -p "$LOOP_HOME"
printf 'export LOOP_BEFORE=1\nsource ~/.loop-a\nexport LOOP_AFTER=1\n' > "$LOOP_HOME/.bashrc"
ln -s .loop-b "$LOOP_HOME/.loop-a"
ln -s .loop-a "$LOOP_HOME/.loop-b"
LOOP_STATUS=0
"${timeout_command[@]}" bash "$RESOLVER" --shell bash --home "$LOOP_HOME" --output "$TMP_DIR/loop.rc" 2>"$TMP_DIR/loop.err" || LOOP_STATUS=$?
[[ $LOOP_STATUS -ne 124 ]] || fail "symlink loops must not hang the resolver"
[[ $LOOP_STATUS -eq 0 ]] || fail "symlink loop resolution returned $LOOP_STATUS"
assert_file_has "$TMP_DIR/loop.rc" 'source ~/.loop-a'
assert_file_count "$TMP_DIR/loop.rc" 'export LOOP_AFTER=1' 1
assert_file_count "$TMP_DIR/loop.err" 'unresolved source' 1

BRANCH_HOME=$TMP_DIR/branch-home
mkdir -p "$BRANCH_HOME/.a" "$BRANCH_HOME/.b"
printf 'FROM_A=1\n' > "$BRANCH_HOME/.a/init"
printf 'FROM_B=1\n' > "$BRANCH_HOME/.b/init"
cat > "$BRANCH_HOME/.bashrc" <<'BRC'
RC_DIR="$HOME/.a"
if [ -n "$USE_B" ]; then RC_DIR="$HOME/.b"; fi
source "$RC_DIR/init"
OTHER_DIR="$HOME/.a"
if [ -f x ]; then
  OTHER_DIR="$HOME/.b"
fi
source "$OTHER_DIR/init"
BRC
bash "$RESOLVER" --shell bash --home "$BRANCH_HOME" --output "$TMP_DIR/branch.rc" 2>"$TMP_DIR/branch.err"
assert_file_has "$TMP_DIR/branch.rc" 'source "$RC_DIR/init"'
assert_file_has "$TMP_DIR/branch.rc" 'source "$OTHER_DIR/init"'
if grep -Fq 'FROM_A=1' "$TMP_DIR/branch.rc"; then fail "branch-reassigned path was inlined unconditionally"; fi
assert_file_count "$TMP_DIR/branch.err" 'unresolved source' 2

for form in one-line multi-line; do
  TRUE_HOME=$TMP_DIR/true-$form-home
  mkdir -p "$TRUE_HOME/.omz"
  printf 'export OMZ_LOADED=%s\n' "$form" > "$TRUE_HOME/.omz/init.sh"
  if [[ $form == one-line ]]; then
    printf '%s\n' 'ZSH="$HOME/.omz"' 'if true; then source "$ZSH/init.sh"; fi' > "$TRUE_HOME/.bashrc"
  else
    printf '%s\n' 'ZSH="$HOME/.omz"' 'if true; then' '  source "$ZSH/init.sh"' 'fi' > "$TRUE_HOME/.bashrc"
  fi
  bash "$RESOLVER" --shell bash --home "$TRUE_HOME" --output "$TMP_DIR/true-$form.rc" 2>"$TMP_DIR/true-$form.err"
  assert_file_has "$TMP_DIR/true-$form.rc" "export OMZ_LOADED=$form"
  if grep -Fq 'source "$ZSH/init.sh"' "$TMP_DIR/true-$form.rc"; then fail "static true guard ($form) left source unresolved"; fi
  bash -n "$TMP_DIR/true-$form.rc" || fail "static true guard ($form) output must be valid bash"
done

bash "$RESOLVER" --help > "$TMP_DIR/help" || fail "--help must succeed"
assert_file_has "$TMP_DIR/help" 'usage: pi-shell-rc --shell bash|zsh'
bash "$RESOLVER" -h > "$TMP_DIR/help-h" || fail "-h must succeed"
assert_file_has "$TMP_DIR/help-h" 'usage: pi-shell-rc'
OUTPUT_DIR=$TMP_DIR/output-dir
mkdir -p "$OUTPUT_DIR"
DIR_STATUS=0
bash "$RESOLVER" --shell bash --home "$HOME_ROOT" --output "$OUTPUT_DIR" 2>"$TMP_DIR/output-dir.err" || DIR_STATUS=$?
[[ $DIR_STATUS -eq 2 ]] || fail "directory --output must return status 2, got $DIR_STATUS"
assert_file_has "$TMP_DIR/output-dir.err" "pi-shell-rc: output must be a file path: $OUTPUT_DIR"
[[ -z $(ls -A "$OUTPUT_DIR") ]] || fail "directory --output must not write into the directory"

pass
