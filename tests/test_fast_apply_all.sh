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
