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

source "$ROOT/cc-patch-manager.sh"

assert_eq "${PATCH_IDS[*]}" \
  "auto-mode keybindings transcript-dialog ultracode voice-mode context-limit computer-use" \
  "computer-use must be appended as patch seven"
assert_eq "$(patch_name computer-use)" "Computer Use 解锁" "computer-use name"
assert_eq "$(patch_note computer-use)" \
  "通过设置或环境变量启用 Computer Use MCP，默认关闭" \
  "computer-use note"
assert_eq "$(patch_suffix computer-use)" "backup-computer-use" "computer-use suffix"

purpose=$(patch_purpose computer-use)
[[ "$purpose" == *"computerUseEnabled"* ]] || fail "purpose must document settings enablement"
[[ "$purpose" == *"CLAUDE_CODE_COMPUTER_USE"* ]] || fail "purpose must document env enablement"
[[ "$purpose" == *"computerUseConfig"* ]] || fail "purpose must document sub-config"
[[ "$purpose" == *"默认关闭"* ]] || fail "purpose must preserve default-off behavior"

help=$("$ROOT/cc-patch-manager.sh" --help)
[[ "$help" == *"打印七个补丁状态后退出"* ]] || fail "help must report seven patch statuses"
grep -Fq "[1-7] 选择补丁" "$ROOT/cc-patch-manager.sh" || fail "menu hint must accept 1-7"
grep -Fq '1|2|3|4|5|6|7)' "$ROOT/cc-patch-manager.sh" || fail "menu dispatch must accept choice 7"

source_script="$ROOT/original-scripts/apply-claude-code-computer-use-fix.sh"
[[ -f "$source_script" ]] || fail "archived computer-use source is missing"
if command -v shasum >/dev/null 2>&1; then
  source_hash=$(shasum -a 256 "$source_script" | awk '{print $1}')
elif command -v sha256sum >/dev/null 2>&1; then
  source_hash=$(sha256sum "$source_script" | awk '{print $1}')
else
  fail "no SHA-256 command available"
fi
assert_eq "$source_hash" \
  "ea146c487fa094bc4ec3cb06f6fb9b0ddab1b60abd2525f7eb524df57706ab9b" \
  "archived computer-use source hash"

printf 'PASS: computer-use registry, UI contract, and source archive\n'
