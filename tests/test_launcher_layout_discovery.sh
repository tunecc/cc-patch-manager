#!/usr/bin/env bash
# Regression for @cometix/anthropic-cc 2.1.296's launcher layout and for
# machines that have two patchable distributions installed side by side.
#
# 2.1.296 moved the real JavaScript out of the npm package: the package's
# cli.js became a 179-byte launcher and the real entry (runtime-entry.js) lives
# in a runtime tree under <versions-root>/<version>/<build-*>/ that the launcher
# generates on first start. find_cli_js() used to return the first installed
# package it recognised, so a machine with @cometix/claude-code AND
# @cometix/anthropic-cc silently patched only the first one — the user's actual
# CLI (anthropic-cc) stayed unpatched while --check reported everything applied.
#
# Covers:
#   A1 single-target behaviour is unchanged (one identity line, no banner)
#   A2 both distributions are discovered and listed, no silent first-wins
#   A3 the launcher resolves to the runtime tree's runtime-entry.js
#   A4 a missing runtime tree yields an actionable note, not an internal error
#   A5 runtimeBuild mismatch means the tree will be rebuilt -> stale note
#   A6 an explicit launcher path redirects to the real entry
#   A7 PATCH_SOURCE lets the shell tell own vs externally-satisfied apart
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

assert_eq() {
  local actual="$1" expected="$2" label="$3"
  [[ "$actual" == "$expected" ]] || fail "$label: expected [$expected], got [$actual]"
}

source "$ROOT/tests/lib/dual-layout-fixture.sh"
source "$ROOT/cc-patch-manager.sh"

# A realistic split-esm package: package/cli.js imports a chunk, exactly like
# the direct-entry distributions (@cometix/claude-code, anthropic-cc <= 2.1.284).
make_direct_package() {
  local root="$1" package_name="$2" version="$3"
  fixture_make_package "$root" split-esm "$package_name" "$version"
}

# The 2.1.296 launcher shape: a tiny package cli.js plus a runtime tree that the
# launcher materialises under <data-root>/anthropic-cc/versions/<version>/<build>.
# The runtime tree keeps the main package's identity (name/version/runtimeBuild)
# and holds the real entry as runtime-entry.js.
make_launcher_package() {
  local main_dir="$1" data_root="$2" version="$3" build="$4" runtime_build="$5"
  mkdir -p "$main_dir"
  printf '{"name":"@cometix/anthropic-cc","version":"%s","runtimeBuild":"%s","type":"module"}\n' \
    "$version" "$runtime_build" >"$main_dir/package.json"
  printf '#!/usr/bin/env node\n(async () => { const { launch } = await import("./runtime.mjs"); await launch(); })().catch(e => { console.error(e); process.exitCode = 1; });\n' \
    >"$main_dir/cli.js"
  printf 'export async function launch(){}\n' >"$main_dir/runtime.mjs"

  local tree="$data_root/versions/$version/$build"
  mkdir -p "$tree"
  printf '{"name":"@cometix/anthropic-cc","version":"%s","runtimeBuild":"%s","type":"module"}\n' \
    "$version" "$runtime_build" >"$tree/package.json"
  printf '#!/usr/bin/env node\nimport{writeFileSync,mkdirSync}from"node:fs";import{dirname,join}from"node:path";import{fileURLToPath}from"node:url";const t=dirname(fileURLToPath(import.meta.url));mkdirSync(join(t,".pids"),{recursive:!0});writeFileSync(join(t,".pids",String(process.pid)),"");import("./runtime-entry.js").catch(e=>{console.error(e);process.exitCode=1});\n' \
    >"$tree/cli.js"
  mkdir -p "$tree/chunks"
  printf '#!/usr/bin/env node\nimport "./chunks/main.js"\n' >"$tree/runtime-entry.js"
  printf 'export const ready = true\n' >"$tree/chunks/main.js"
  printf '{"build":"%s","source":"%s"}\n' "$build" "$runtime_build" \
    >"$data_root/versions/$version/current.json"
  printf '%s\n' "$tree"
}

# ---------------------------------------------------------------- A3 / A6
main_dir="$tmp/global/@cometix/anthropic-cc"
data_root="$tmp/data"
tree=$(make_launcher_package "$main_dir" "$data_root" 2.1.296 'build-1700000000000-aaaa' 'rb-1')
[[ -n "$tree" ]] || fail 'launcher fixture did not report its runtime tree'
assert_eq "$(basename "$tree")" 'build-1700000000000-aaaa' 'runtime tree directory name'

set +e
resolved=$(ANTHROPIC_CC_DATA_DIR="$data_root" \
  resolve_anthropic_cc_runtime_entry "$main_dir" '2.1.296')
resolve_status=$?
set -e
# The resolver reports both fields on one line: "<entry>\t<reason>". Splitting here
# (instead of reading a global) is what the production callers do, so this test
# cannot pass by inheriting a leftover value from an earlier call in the same shell.
resolved_entry="${resolved%%$'\t'*}"
resolved_reason="${resolved#*$'\t'}"
[[ "$resolve_status" -eq 0 ]] || fail "launcher resolution failed (${resolved_reason:-no reason})"
assert_eq "$resolved_entry" "$tree/runtime-entry.js" 'launcher resolves to runtime-entry.js'
assert_eq "$resolved_reason" '' 'successful resolution carries no reason'

set +e
redirected=$(ANTHROPIC_CC_DATA_DIR="$data_root" redirect_launcher_entry "$main_dir/cli.js" 2>/dev/null)
redirect_status=$?
set -e
[[ "$redirect_status" -eq 0 ]] || fail 'explicit launcher path did not redirect'
assert_eq "$redirected" "$tree/runtime-entry.js" 'explicit launcher path redirects to the real entry'

# A non-launcher path must pass through untouched.
set +e
passthrough=$(redirect_launcher_entry "$tree/runtime-entry.js" 2>/dev/null && printf x || printf y)
set -e
assert_eq "$passthrough" 'y' 'runtime-entry.js is not treated as a launcher'

# ---------------------------------------------------------------- A4 / A5
stale_data="$tmp/stale-data"
stale_main="$tmp/stale-global/@cometix/anthropic-cc"
make_launcher_package "$stale_main" "$stale_data" 2.1.296 'build-1700000000000-bbbb' 'rb-old' >/dev/null
# current.json points at a build whose source no longer matches the package's
# runtimeBuild: the launcher will regenerate the tree on next start, so anything
# patched into the old tree is gone.
printf '{"name":"@cometix/anthropic-cc","version":"2.1.296","runtimeBuild":"rb-new","type":"module"}\n' \
  >"$stale_main/package.json"
printf '{"build":"build-1700000000000-bbbb","source":"rb-old"}\n' \
  >"$stale_data/versions/2.1.296/current.json"

# Assert the reason through the SAME path production uses — a command substitution
# inside discover_targets — so a reason lost across the subshell boundary fails here.
stale_line=$(ANTHROPIC_CC_DATA_DIR="$stale_data" \
  resolve_anthropic_cc_runtime_entry "$stale_main" '2.1.296')
assert_eq "${stale_line%%$'\t'*}" '' 'stale runtime tree yields no entry'
assert_eq "${stale_line#*$'\t'}" 'stale-runtime-build' 'stale runtime tree reason'

empty_data="$tmp/empty-data"
mkdir -p "$empty_data"
missing_line=$(ANTHROPIC_CC_DATA_DIR="$empty_data" \
  resolve_anthropic_cc_runtime_entry "$stale_main" '2.1.296')
assert_eq "${missing_line%%$'\t'*}" '' 'missing runtime tree yields no entry'
assert_eq "${missing_line#*$'\t'}" 'missing-current-json' 'missing runtime tree reason'
assert_eq "$(target_note_cn missing-current-json)" '尚未生成运行树（需先启动一次该 CLI）' 'missing tree note'
assert_eq "$(target_note_cn stale-runtime-build)" '运行树已过期（重启该 CLI 后会重建）' 'stale tree note'

# ---------------------------------------------------------------- A1 / A2
single_root="$tmp/single"
make_direct_package "$single_root/@cometix/claude-code" '@cometix/claude-code' 2.1.284
mkdir -p "$tmp/bin" "$tmp/home"
cat >"$tmp/bin/npm" <<'SH'
#!/usr/bin/env bash
[[ "${1:-}" == root && "${2:-}" == -g ]] || exit 2
printf '%s\n' "$TEST_NPM_ROOT"
SH
chmod +x "$tmp/bin/npm"
# The npm stub shadows the real npm (so `npm root -g` is deterministic) while the
# rest of PATH stays intact: the script needs Bash 4+ associative arrays and node.
BASH_BIN=$(command -v bash)

set +e
single_found=$(HOME="$tmp/home" TEST_NPM_ROOT="$single_root" PATH="$tmp/bin:$PATH" find_cli_js)
single_status=$?
set -e
assert_eq "$single_status" 0 'single target is discoverable'
assert_eq "$single_found" "$single_root/@cometix/claude-code/cli.js" 'single target entry'

# Two distributions installed at once: both must show up, and neither may be
# dropped just because the other sorts first.
dual_root="$tmp/dual"
make_direct_package "$dual_root/@cometix/claude-code" '@cometix/claude-code' 2.1.284
dual_main="$dual_root/@cometix/anthropic-cc"
make_launcher_package "$dual_main" "$tmp/dual-data" 2.1.296 'build-1700000000000-cccc' 'rb-dual' >/dev/null

dual_list=$(ANTHROPIC_CC_DATA_DIR="$tmp/dual-data" HOME="$tmp/home" TEST_NPM_ROOT="$dual_root" \
  PATH="$tmp/bin:$PATH" discover_targets)
assert_eq "$(printf '%s\n' "$dual_list" | awk 'END{print NR}')" '2' 'both distributions are discovered'
printf '%s\n' "$dual_list" | cut -f1 | sort | tr '\n' ' ' |
  grep -Fq '@cometix/anthropic-cc @cometix/claude-code' ||
  fail "discovered targets are not the expected pair: $(printf '%s' "$dual_list" | cut -f1 | tr '\n' ' ')"

# The launcher target must resolve to the runtime tree, not the 179-byte stub.
launcher_line=$(printf '%s\n' "$dual_list" | awk -F'\t' '$1=="@cometix/anthropic-cc"')
assert_eq "$(printf '%s' "$launcher_line" | cut -f4)" 'launcher' 'launcher layout kind'
assert_eq "$(printf '%s' "$launcher_line" | cut -f5)" '' 'healthy launcher has no note'
assert_eq "$(printf '%s' "$launcher_line" | cut -f3)" \
  "$tmp/dual-data/versions/2.1.296/build-1700000000000-cccc/runtime-entry.js" \
  'launcher entry points into the runtime tree'
direct_line=$(printf '%s\n' "$dual_list" | awk -F'\t' '$1=="@cometix/claude-code"')
assert_eq "$(printf '%s' "$direct_line" | cut -f4)" 'direct' 'direct layout kind'

# A broken launcher must still be listed — with a note — so --check can explain
# it instead of silently skipping the user's actual CLI.
broken_data="$tmp/broken-data"
mkdir -p "$broken_data"
broken_list=$(ANTHROPIC_CC_DATA_DIR="$broken_data" HOME="$tmp/home" TEST_NPM_ROOT="$dual_root" \
  PATH="$tmp/bin:$PATH" discover_targets)
broken_line=$(printf '%s\n' "$broken_list" | awk -F'\t' '$1=="@cometix/anthropic-cc"')
assert_eq "$(printf '%s' "$broken_line" | cut -f5)" 'missing-current-json' 'broken launcher keeps a note'
assert_eq "$(printf '%s\n' "$broken_list" | awk 'END{print NR}')" '2' 'broken launcher is still listed'

# Regression: the note must survive the command substitution inside
# discover_targets. When it is lost, --check hands the 179-byte launcher to the
# engine and emits the internal error A4 forbids.
set +e
broken_check=$(ANTHROPIC_CC_DATA_DIR="$broken_data" HOME="$tmp/home" TEST_NPM_ROOT="$dual_root" \
  PATH="$tmp/bin:$PATH" "$BASH_BIN" "$ROOT/cc-patch-manager.sh" --check 2>&1)
broken_check_status=$?
set -e
grep -Fq '尚未生成运行树（需先启动一次该 CLI）' <<<"$broken_check" ||
  fail "broken launcher --check lost the actionable note: $broken_check"
grep -Fq '暂不可补丁' <<<"$broken_check" ||
  fail "broken launcher --check did not report the target as un-patchable: $broken_check"
if grep -Fq 'entry has neither split-ESM imports nor a single-CJS shape' <<<"$broken_check"; then
  fail "broken launcher leaked the internal engine error: $broken_check"
fi
if grep -Fq 'cruce 目标结构检查失败' <<<"$broken_check"; then
  fail "broken launcher leaked the cruce structure rejection: $broken_check"
fi
# The healthy sibling target must still be fully reported next to the broken one.
grep -Fq '包: @cometix/claude-code 2.1.284 (split-esm)' <<<"$broken_check" ||
  fail "broken-launcher --check lost the healthy sibling target: $broken_check"

# --check lists every discovered target; a single-target machine keeps the old
# single-table output (no banner, one identity line). These stub packages carry
# no real patch anchors, so --check legitimately reports missing targets and
# exits non-zero; only the shape of the output matters here.
set +e
dual_check=$(ANTHROPIC_CC_DATA_DIR="$tmp/dual-data" HOME="$tmp/home" TEST_NPM_ROOT="$dual_root" \
  PATH="$tmp/bin:$PATH" "$BASH_BIN" "$ROOT/cc-patch-manager.sh" --check 2>&1)
single_check=$(HOME="$tmp/home" TEST_NPM_ROOT="$single_root" \
  PATH="$tmp/bin:$PATH" "$BASH_BIN" "$ROOT/cc-patch-manager.sh" --check 2>&1)
set -e
grep -Fq '包: @cometix/claude-code 2.1.284 (split-esm)' <<<"$single_check" ||
  fail "single-target --check lost its identity line: $single_check"
if grep -Fq '目标 1/' <<<"$single_check"; then
  fail 'single-target --check should not print a multi-target banner'
fi
if grep -Fq '运行树' <<<"$single_check"; then
  fail 'single-target --check should not print the launcher durability note'
fi

grep -Fq '目标 1/2' <<<"$dual_check" || fail "dual --check lacks first target banner: $dual_check"
grep -Fq '目标 2/2' <<<"$dual_check" || fail "dual --check lacks second target banner: $dual_check"
grep -Fq "$tmp/dual-data/versions/2.1.296/build-1700000000000-cccc/runtime-entry.js" \
  <<<"$dual_check" || fail 'dual --check did not list the runtime-tree entry'
grep -Fq '升级（runtimeBuild 变化）后补丁会失效' <<<"$dual_check" ||
  fail 'dual --check lacks the launcher durability note'
# Both distributions' identity lines must appear, in discovery order.
grep -Fq '包: @cometix/claude-code 2.1.284 (split-esm)' <<<"$dual_check" ||
  fail 'dual --check lacks the claude-code identity line'
grep -Fq '包: @cometix/anthropic-cc 2.1.296 (split-esm)' <<<"$dual_check" ||
  fail 'dual --check lacks the anthropic-cc identity line'

# Switching targets must drop the previous target's cached identity, otherwise
# the menu keeps showing the old package name/version over the new target.
load_targets
select_target 0 || fail 'could not select the first dual target'
TARGET_PACKAGE='stale-name'; TARGET_VERSION='stale-version'; TARGET_LAYOUT='stale-layout'
select_target 1 || fail 'could not switch to the second dual target'
assert_eq "$TARGET_PACKAGE" '' 'switching targets must clear the cached package name'
assert_eq "$TARGET_VERSION" '' 'switching targets must clear the cached version'
assert_eq "$TARGET_LAYOUT" '' 'switching targets must clear the cached layout'
assert_eq "$CLI_PATH" "${TARGET_ENTRIES[1]}" 'switching targets must move CLI_PATH'
assert_eq "$SELECTED_TARGET" '1' 'switching targets must update SELECTED_TARGET'

# A destructive --restore-all must never silently pick the first of several
# targets; it has to refuse and ask for an explicit entry.
set +e
restore_all_out=$(HOME="$tmp/home" TEST_NPM_ROOT="$dual_root" ANTHROPIC_CC_DATA_DIR="$tmp/dual-data" \
  PATH="$tmp/bin:$PATH" "$BASH_BIN" "$ROOT/cc-patch-manager.sh" --restore-all 2>&1)
restore_all_status=$?
set -e
[[ "$restore_all_status" -ne 0 ]] || fail '--restore-all must refuse when several targets exist'
grep -Fq '需要显式指定要还原哪一个' <<<"$restore_all_out" ||
  fail "--restore-all refusal lacked guidance: $restore_all_out"

# The interactive picker must still surface an unusable target (with its reason)
# even when it is the only other install, and must not give it a selectable
# number — the user should learn the install exists instead of silently losing it.
# (The script exits 1 when nothing is selected, so guard the assignment.)
set +e
picker_out=$(printf 'q\n' | HOME="$tmp/home" TEST_NPM_ROOT="$dual_root" \
  ANTHROPIC_CC_DATA_DIR="$broken_data" PATH="$tmp/bin:$PATH" \
  "$BASH_BIN" "$ROOT/cc-patch-manager.sh" 2>&1)
set -e
grep -Fq '暂不可补丁：尚未生成运行树（需先启动一次该 CLI）' <<<"$picker_out" ||
  fail "picker hid the unusable launcher's reason: $picker_out"
grep -Fq '请选择 [1-1' <<<"$picker_out" ||
  fail "picker offered a number for the unusable target: $picker_out"

# ---------------------------------------------------------------- A7
# PATCH_SOURCE must let the shell separate "our markers" from "only upstream's".
consumed="$tmp/consumed"
make_direct_package "$consumed" '@cometix/claude-code' 2.1.284
fixture_add_module "$consumed" chunks/ultra-gates.js 'export function xhighGate(model){return!0}/*@cc:unlock-ultracode#xhigh-capability*/'
fixture_add_module "$consumed" chunks/ultra-effort.js 'import{xhighGate}from"./ultra-gates.js";export function resolveEffort(model,effort){let resolved=effort;if(resolved==="xhigh"&&!xhighGate(model))resolved="high";return resolved}'
fixture_add_module "$consumed" chunks/ultra-index.js 'export{resolveEffort}from"./ultra-effort.js"'
set +e
consumed_out=$(runtime_exec check "$(fixture_entry "$consumed")" ultracode 2>&1)
set -e
grep -Fxq ALREADY_PATCHED <<<"$consumed_out" || fail "externally satisfied patch must be ALREADY_PATCHED: $consumed_out"
grep -Fxq 'PATCH_SOURCE:external' <<<"$consumed_out" ||
  fail "externally satisfied patch must report PATCH_SOURCE:external: $consumed_out"

runtime_exec apply "$(fixture_entry "$consumed")" ultracode >/dev/null 2>&1 || true
runtime_exec restore "$(fixture_entry "$consumed")" ultracode >/dev/null 2>&1 || true

# The same patch applied by us must report 'own', not 'external'.
own="$tmp/own"
make_direct_package "$own" '@cometix/claude-code' 2.1.284
fixture_add_module "$own" chunks/keybindings.js 'function featureFlag(name,enabled){return enabled}
export function keybindingsEnabled(){return featureFlag("tengu_keybinding_customization_release",false)}
export const defaultKeybindings=[{context:"Global",bindings:{"ctrl+c":"app:interrupt","ctrl+d":"app:exit"}},{context:"Transcript",bindings:{"ctrl+c":"app:interrupt"}},{context:"HistorySearch",bindings:{"ctrl+c":"app:interrupt"}}]'
set +e
own_before=$(runtime_exec check "$(fixture_entry "$own")" keybindings 2>&1)
set -e
grep -Fxq NEEDS_PATCH <<<"$own_before" || fail "keybindings fixture should start unpatched: $own_before"
runtime_exec apply "$(fixture_entry "$own")" keybindings >/dev/null || fail 'keybindings apply failed on own fixture'
set +e
own_out=$(runtime_exec check "$(fixture_entry "$own")" keybindings 2>&1)
set -e
grep -Fxq 'PATCH_SOURCE:own' <<<"$own_out" ||
  fail "self-applied patch must report PATCH_SOURCE:own: $own_out"

# The shell-side parser must turn PATCH_SOURCE:external into the distinct
# "external" status rather than a plain "applied".
STATUS=(); MSG=()
CLI_PATH="$consumed/cli.js"
parse_and_set_status ultracode check "$consumed_out" 0
assert_eq "${STATUS[ultracode]:-}" 'external' 'external patch source maps to the external status'
STATUS=(); MSG=()
CLI_PATH="$own/cli.js"
parse_and_set_status keybindings check "$own_out" 0
assert_eq "${STATUS[keybindings]:-}" 'applied' 'own patch source maps to the applied status'

printf 'PASS: launcher layout discovery and multi-target selection hold\n'
