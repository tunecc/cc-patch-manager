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
  "auto-mode keybindings transcript-dialog ultracode voice-mode context-limit" \
  "context-limit must be appended as patch six"
assert_eq "$(patch_name context-limit)" "上下文上限配置" "context-limit name"
assert_eq "$(patch_note context-limit)" \
  "通过 CLAUDE_CODE_CONTEXT_LIMIT 覆盖默认 200K 上限" \
  "context-limit note"
assert_eq "$(patch_suffix context-limit)" "backup-ctxlimit" "context-limit suffix"

purpose=$(patch_purpose context-limit)
[[ "$purpose" == *"CLAUDE_CODE_CONTEXT_LIMIT"* ]] || fail "purpose must document the env var"
[[ "$purpose" == *"默认仍为 200000"* ]] || fail "purpose must document the unchanged default"
[[ "$purpose" == *"服务端"* ]] || fail "purpose must document the server-side limit risk"

help=$("$ROOT/cc-patch-manager.sh" --help)
[[ "$help" == *"打印六个补丁状态后退出"* ]] || fail "help must report six patch statuses"
grep -Fq "[1-6] 选择补丁" "$ROOT/cc-patch-manager.sh" || fail "menu hint must accept 1-6"
grep -Fq '1|2|3|4|5|6)' "$ROOT/cc-patch-manager.sh" || fail "menu dispatch must accept choice 6"

printf 'PASS: context-limit registry and UI contract\n'
