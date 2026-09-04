#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

assert_eq() {
  local actual="$1" expected="$2" label="$3"
  [[ "$actual" == "$expected" ]] || fail "$label: expected [$expected], got [$actual]"
}

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# --- Static contract on apply_all_patches body ---
# Extract the function text between its definition and the next top-level function.
fn_body=$(awk '
  /^apply_all_patches\(\)/ {grab=1}
  grab {print}
  grab && /^[a-zA-Z_][a-zA-Z0-9_]*\(\)/ && !/^apply_all_patches\(\)/ {exit}
' "$ROOT/cc-patch-manager.sh")

[[ -n "$fn_body" ]] || fail "could not extract apply_all_patches"

# Must not pre-detect or post-recheck via refresh_all
if printf '%s\n' "$fn_body" | grep -Fq 'refresh_all'; then
  fail "apply_all_patches must not call refresh_all (pre or post)"
fi
if printf '%s\n' "$fn_body" | grep -Fq 'refresh_one'; then
  fail "apply_all_patches must not call refresh_one"
fi
if printf '%s\n' "$fn_body" | grep -Fq '尚未检测，先刷新状态'; then
  fail "apply_all_patches must not print pre-detect copy"
fi
if printf '%s\n' "$fn_body" | grep -Fq '正在复检全部补丁'; then
  fail "apply_all_patches must not print post-recheck copy"
fi

# Must always walk PATCH_IDS (not a filtered need= list of only non-applied)
printf '%s\n' "$fn_body" | grep -Fq 'for id in "${PATCH_IDS[@]}"' \
  || fail "apply_all_patches must iterate PATCH_IDS"

# Confirm copy requirements from design
printf '%s\n' "$fn_body" | grep -Fq '已应用的补丁会自动跳过' \
  || fail "confirm must state engines skip already-applied patches"
printf '%s\n' "$fn_body" | grep -Fq '确认执行？ [Y/n]' \
  || fail "must keep single [Y/n] confirm"

# Must print summary helper (or inline 一键应用结束) after applies
if ! printf '%s\n' "$fn_body" | grep -Eq 'print_apply_all_summary|一键应用结束'; then
  fail "apply_all_patches must print batch summary after applies"
fi

# --- Unit: print_apply_all_summary classification ---
source "$ROOT/cc-patch-manager.sh"

# Stub registry to three ids so the test does not depend on full seven-name list length in output counts only.
# Do NOT replace PATCH_IDS if the function always reads global PATCH_IDS — instead set STATUS for all real ids
# to applied/skip/fail mix and only assert counts via captured output.

for id in "${PATCH_IDS[@]}"; do
  STATUS[$id]=applied
  MSG[$id]="已打补丁"
done
# First id = fresh success, second = skip already, last = error (if ≥3 patches)
ids=("${PATCH_IDS[@]}")
STATUS[${ids[0]}]=applied
MSG[${ids[0]}]="已修补 3 处"
if [[ ${#ids[@]} -ge 2 ]]; then
  STATUS[${ids[1]}]=applied
  MSG[${ids[1]}]="已打补丁"
fi
if [[ ${#ids[@]} -ge 3 ]]; then
  STATUS[${ids[2]}]=error
  MSG[${ids[2]}]="校验失败: demo"
fi
# Remaining stay 已打补丁 / applied → all count as 跳过

# Expected: 1 success (ids[0]), 1 fail (ids[2] if present), rest skip
n=${#ids[@]}
exp_success=1
exp_fail=0
exp_skip=$((n - 1))
if [[ $n -ge 3 ]]; then
  exp_fail=1
  exp_skip=$((n - 2))
fi

if ! declare -F print_apply_all_summary >/dev/null 2>&1; then
  fail "print_apply_all_summary function is missing"
fi

summary=$(print_apply_all_summary)
printf '%s\n' "$summary" | grep -Fq "一键应用结束：${exp_success} 成功 · ${exp_skip} 跳过 · ${exp_fail} 失败" \
  || fail "summary header counts wrong. got:
$summary
expected header fragment: 一键应用结束：${exp_success} 成功 · ${exp_skip} 跳过 · ${exp_fail} 失败"

printf '%s\n' "$summary" | grep -Fq "${MSG[${ids[0]}]}" \
  || fail "summary must list success message"

if [[ $n -ge 3 ]]; then
  printf '%s\n' "$summary" | grep -Fq "校验失败: demo" \
    || fail "summary must list failure message"
fi

printf 'PASS: fast apply-all contract + summary classification\n'

# --- Task 4.2: apply-all continues past an isolated per-patch transaction failure ---
# A single shared.js contract fixture under CC_PATCH_TEST_PRODUCTION_IDS=1 maps the
# production patch ids: auto-mode→alpha, keybindings→gamma, transcript-dialog→delta,
# ultracode→epsilon, voice-mode→beta marker plus a resource copy. context-limit and
# computer-use have no contract mapping, so they fail at the analysis stage
# (unsupported patch id) — distinct from the injected transcript-dialog failure,
# which fails at the transaction stage. The batch must keep going past all three
# failing ids and still apply ultracode, proving per-patch continue-on-failure.
source "$ROOT/tests/lib/dual-layout-fixture.sh"

fail_cont="$tmp/fail-continue"
fixture_make_package "$fail_cont" split-esm '@cometix/anthropic-cc' 2.1.259
fixture_add_module "$fail_cont" chunks/shared.js 'export const alpha="CC_BEFORE_ALPHA",beta="CC_BEFORE_BETA",gamma="CC_BEFORE_GAMMA",delta="CC_BEFORE_DELTA",epsilon="CC_BEFORE_EPSILON"'
fixture_add_module "$fail_cont" cli.js '#!/usr/bin/env node
import "./chunks/shared.js"'
fixture_add_module "$fail_cont" assets/model.bin 'voice-resource'
printf '\n// CC_CONTRACT_RESOURCE:assets/model.bin->vendor/cometix-asr/model.bin\n' >>"$fail_cont/cli.js"

CLI_PATH=$(fixture_entry "$fail_cont")
STATUS=()
MSG=()

set +e
CC_PATCH_TESTING=1 CC_PATCH_TEST_PRODUCTION_IDS=1 CC_PATCH_TEST_FAIL_PATCH=transcript-dialog \
  apply_all_patches <<< $'\n' >"$tmp/apply-all.log" 2>&1
apply_ec=$?
set -e
# apply_all_patches returns 0 even when individual patches fail (continue-on-failure).
[[ "$apply_ec" -eq 0 ]] || fail "apply_all_patches exited $apply_ec: $(cat "$tmp/apply-all.log")"

assert_eq "${STATUS[transcript-dialog]:-}" error 'failing transaction reported'
assert_eq "${STATUS[ultracode]:-}" applied 'next transaction continued'

# context-limit and computer-use have no contract mapping under PRODUCTION_IDS=1, so
# they fail at the analysis stage (unsupported patch id) — assert explicitly so the
# "multiple failing ids" claim is verifiable and won't silently pass if a future
# contract mapping is added for them.
assert_eq "${STATUS[context-limit]:-}" error 'context-limit analysis failure reported'
assert_eq "${STATUS[computer-use]:-}" error 'computer-use analysis failure reported'

# Summary counts must reflect the actual STATUS distribution so continue-on-failure is visible.
exp_ok=0; exp_skip=0; exp_fail=0
for id in "${PATCH_IDS[@]}"; do
  st="${STATUS[$id]:-}"; msg="${MSG[$id]:-}"
  if [[ "$st" == "applied" && "$msg" == "已打补丁" ]]; then exp_skip=$((exp_skip+1))
  elif [[ "$st" == "applied" ]]; then exp_ok=$((exp_ok+1))
  else exp_fail=$((exp_fail+1)); fi
done
grep -Fq "一键应用结束：${exp_ok} 成功 · ${exp_skip} 跳过 · ${exp_fail} 失败" "$tmp/apply-all.log" \
  || fail "summary header missing or wrong; log: $(cat "$tmp/apply-all.log")"

printf 'PASS: apply-all continues past an isolated transaction failure\n'
