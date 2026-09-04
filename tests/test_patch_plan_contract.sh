#!/usr/bin/env bash
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

complete="$tmp/complete"
fixture_make_package "$complete" split-esm '@cometix/anthropic-cc' 2.1.259
fixture_add_module "$complete" chunks/alpha.js 'export const alpha="CC_BEFORE_ALPHA"'
fixture_add_module "$complete" chunks/beta.js 'export const beta="CC_BEFORE_BETA"'
fixture_add_module "$complete" cli.js '#!/usr/bin/env node
import "./chunks/alpha.js";import "./chunks/beta.js"'

before=$(fixture_hash_tree "$complete")
set +e
check_output=$(CC_PATCH_TESTING=1 runtime_exec check "$(fixture_entry "$complete")" __contract__ 2>&1)
check_status=$?
set -e
[[ "$check_status" -eq 0 ]] || fail "contract check failed: $check_output"
grep -Fx NEEDS_PATCH <<<"$check_output" >/dev/null || fail 'complete contract plan was not patchable'
grep -Fx 'PATCH_COUNT:2' <<<"$check_output" >/dev/null || fail 'contract plan did not contain two replacements'
check_hash=$(sed -n 's/^ANALYSIS_HASH://p' <<<"$check_output")
[[ -n "$check_hash" ]] || fail 'check did not report analysis hash'

apply_output=$(CC_PATCH_TESTING=1 CC_PATCH_VALIDATE_ONLY=1 runtime_exec apply "$(fixture_entry "$complete")" __contract__)
apply_hash=$(sed -n 's/^ANALYSIS_HASH://p' <<<"$apply_output")
[[ "$apply_hash" == "$check_hash" ]] || fail 'check and apply did not share the analyzer result'
grep -Fx PLAN_VALID <<<"$apply_output" >/dev/null || fail 'valid plan did not pass pre-write validation'
[[ "$(fixture_hash_tree "$complete")" == "$before" ]] || fail 'validate-only apply changed the package'

missing="$tmp/missing"
fixture_make_package "$missing" split-esm '@cometix/anthropic-cc' 2.1.259
fixture_add_module "$missing" chunks/alpha.js 'export const alpha="CC_BEFORE_ALPHA"'
fixture_add_module "$missing" cli.js '#!/usr/bin/env node
import "./chunks/alpha.js"'
before=$(fixture_hash_tree "$missing")
set +e
missing_output=$(CC_PATCH_TESTING=1 runtime_exec apply "$(fixture_entry "$missing")" __contract__ 2>&1)
missing_status=$?
set -e
[[ "$missing_status" -ne 0 ]] || fail 'plan missing beta target was accepted'
grep -Fx 'MISSING_TARGET:beta' <<<"$missing_output" >/dev/null || fail 'missing target diagnostic was not structured'
[[ "$(fixture_hash_tree "$missing")" == "$before" ]] || fail 'invalid missing-target plan changed the package'

ambiguous="$tmp/ambiguous"
fixture_make_package "$ambiguous" split-esm '@cometix/anthropic-cc' 2.1.259
fixture_add_module "$ambiguous" chunks/alpha-a.js 'export const alpha="CC_BEFORE_ALPHA"'
fixture_add_module "$ambiguous" chunks/alpha-b.js 'export const alpha="CC_BEFORE_ALPHA"'
fixture_add_module "$ambiguous" chunks/beta.js 'export const beta="CC_BEFORE_BETA"'
set +e
ambiguous_output=$(CC_PATCH_TESTING=1 runtime_exec check "$(fixture_entry "$ambiguous")" __contract__ 2>&1)
ambiguous_status=$?
set -e
[[ "$ambiguous_status" -ne 0 ]] || fail 'ambiguous alpha target was accepted'
grep -Fx 'AMBIGUOUS_TARGET:alpha:2' <<<"$ambiguous_output" >/dev/null || fail 'ambiguous target diagnostic was not structured'
grep -Fq 'AMBIGUOUS_FILE:"chunks/alpha-a.js"' <<<"$ambiguous_output" ||
  fail 'ambiguous target diagnostic did not list candidate files'
grep -Fq 'AMBIGUOUS_FILE:"chunks/alpha-b.js"' <<<"$ambiguous_output" ||
  fail 'ambiguous target diagnostic listed only one candidate file'

# Task 4.1: facade 状态映射必须把结构化诊断翻译成含补丁 ID、阶段与候选文件的中文错误
STATUS=()
MSG=()
TARGET_PACKAGE="" TARGET_VERSION="" TARGET_LAYOUT=""
parse_and_set_status transcript-dialog check "$missing_output" "$missing_status" || true
[[ "${STATUS[transcript-dialog]:-}" == error ]] || fail 'missing target did not map to error status'
[[ "${MSG[transcript-dialog]:-}" == *'缺失目标: beta'* ]] ||
  fail "missing target diagnostic was not translated: ${MSG[transcript-dialog]:-}"
[[ "${MSG[transcript-dialog]:-}" == *'transcript-dialog'* && "${MSG[transcript-dialog]:-}" == *'检测'* ]] ||
  fail "missing target diagnostic lacked patch id or stage: ${MSG[transcript-dialog]:-}"
assert_eq "${TARGET_PACKAGE:-}" '@cometix/anthropic-cc' 'check/apply output must carry package identity'
assert_eq "${TARGET_VERSION:-}" '2.1.259' 'check/apply output must carry package version'
assert_eq "${TARGET_LAYOUT:-}" 'split-esm' 'check/apply output must carry package layout'

STATUS=()
MSG=()
TARGET_PACKAGE="" TARGET_VERSION="" TARGET_LAYOUT=""
parse_and_set_status ultracode apply "$ambiguous_output" "$ambiguous_status" || true
[[ "${STATUS[ultracode]:-}" == error ]] || fail 'ambiguous target did not map to error status'
[[ "${MSG[ultracode]:-}" == *'目标歧义: alpha:2'* ]] ||
  fail "ambiguous target diagnostic was not translated: ${MSG[ultracode]:-}"
[[ "${MSG[ultracode]:-}" == *'ultracode'* && "${MSG[ultracode]:-}" == *'应用'* &&
  "${MSG[ultracode]:-}" == *'候选'* &&
  "${MSG[ultracode]:-}" == *'chunks/alpha-a.js'* &&
  "${MSG[ultracode]:-}" == *'chunks/alpha-b.js'* ]] ||
  fail "ambiguous target diagnostic lacked patch id, stage or candidate files: ${MSG[ultracode]:-}"

overlap="$tmp/overlap"
fixture_make_package "$overlap" split-esm '@cometix/anthropic-cc' 2.1.259
fixture_add_module "$overlap" chunks/targets.js 'export const alpha="CC_BEFORE_ALPHA";export const beta="CC_BEFORE_BETA";/*CC_CONTRACT_OVERLAP*/'
before=$(fixture_hash_tree "$overlap")
if CC_PATCH_TESTING=1 CC_PATCH_VALIDATE_ONLY=1 runtime_exec apply "$(fixture_entry "$overlap")" __contract__ >/dev/null 2>&1; then
  fail 'overlapping replacements were accepted'
fi
[[ "$(fixture_hash_tree "$overlap")" == "$before" ]] || fail 'overlap validation changed the package'

invalid_ast="$tmp/invalid-ast"
fixture_make_package "$invalid_ast" split-esm '@cometix/anthropic-cc' 2.1.259
fixture_add_module "$invalid_ast" chunks/targets.js 'export const alpha="CC_BEFORE_ALPHA";export const beta="CC_BEFORE_BETA";/*CC_CONTRACT_INVALID_AST*/'
before=$(fixture_hash_tree "$invalid_ast")
if CC_PATCH_TESTING=1 CC_PATCH_VALIDATE_ONLY=1 runtime_exec apply "$(fixture_entry "$invalid_ast")" __contract__ >/dev/null 2>&1; then
  fail 'post-patch syntax failure was accepted'
fi
[[ "$(fixture_hash_tree "$invalid_ast")" == "$before" ]] || fail 'post-patch syntax validation changed the package'

printf 'PASS: PatchPlan check/apply analysis and cardinality validation are shared\n'
