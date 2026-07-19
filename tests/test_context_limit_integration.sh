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
  "context-limit must remain patch six and computer-use must be patch seven"
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
[[ "$help" == *"打印七个补丁状态后退出"* ]] || fail "help must report seven patch statuses"
grep -Fq "[1-7] 选择补丁" "$ROOT/cc-patch-manager.sh" || fail "menu hint must accept 1-7"
grep -Fq '1|2|3|4|5|6|7)' "$ROOT/cc-patch-manager.sh" || fail "menu dispatch must accept choice 7"

source_script="$ROOT/original-scripts/apply-claude-code-context-limit-patch.sh"
[[ -f "$source_script" ]] || fail "archived context-limit source is missing"
grep -Fq 'CLAUDE_CODE_CONTEXT_LIMIT' "$source_script" || fail "archived source lost its env marker"
if command -v shasum >/dev/null 2>&1; then
  source_hash=$(shasum -a 256 "$source_script" | awk '{print $1}')
elif command -v sha256sum >/dev/null 2>&1; then
  source_hash=$(sha256sum "$source_script" | awk '{print $1}')
else
  fail "no SHA-256 command available"
fi
assert_eq "$source_hash" \
  "3bd475fb9241704bfffc71523268fa7ab7afb7906abdd7d62ac03a19d41be9bc" \
  "archived context-limit source hash"
[[ ! -e "$ROOT/original-scripts/apply-claude-code-context-limit-patch.ps1" ]] || \
  fail "PowerShell source must not be archived"

engine=$(write_patch_script context-limit)
grep -Fq 'CLAUDE_CODE_CONTEXT_LIMIT' "$engine" || fail "generated engine lost its env marker"
grep -Fq 'ALREADY_PATCHED' "$engine" || fail "generated engine lacks idempotence marker"
grep -Fq 'CC_PATCH_SKIP_BACKUP' "$engine" || fail "generated engine lacks baseline adapter"
rm -f "$engine"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
CLI_PATH="$tmp/cli.js"
ACORN_PATH="$tmp/acorn.js"

cat >"$CLI_PATH" <<'JS'
#!/usr/bin/env node
let hookLimit=200000,toolLimit=200000;
function loadProjectEnv(env){for(const item of [])void item;Object.assign(process.env,env)}
function loadFlagEnv(env){Object.assign(process.env,env)}
function isLargeMessage(tokens){return tokens>200000}
console.log(hookLimit,toolLimit,isLargeMessage(1));
JS

before="$tmp/cli-before.js"
cp "$CLI_PATH" "$before"

run_node_patch context-limit check
assert_eq "${STATUS[context-limit]:-}" "idle" "initial context-limit status"
assert_eq "${MSG[context-limit]:-}" "需修补 3 处" "initial patch count"

run_node_patch context-limit apply
assert_eq "${STATUS[context-limit]:-}" "applied" "status after apply"
assert_eq "${MSG[context-limit]:-}" "已修补 5 处" "apply count includes two env loaders"

baseline="$CLI_PATH.cc-patch-baseline"
[[ -f "$baseline" ]] || fail "manager baseline was not created"
cmp -s "$baseline" "$before" || fail "baseline must preserve the unpatched fixture"
if compgen -G "$CLI_PATH.backup-ctxlimit-*" >/dev/null; then
  fail "manager must not create timestamp context-limit backups"
fi

env_ref_count=$(grep -o 'process.env.CLAUDE_CODE_CONTEXT_LIMIT' "$CLI_PATH" | wc -l | tr -d ' ')
assert_eq "$env_ref_count" "7" "patched env reference count"

node - "$ACORN_PATH" "$CLI_PATH" <<'NODE'
const fs = require('fs');
const acorn = require(process.argv[2]);
const code = fs.readFileSync(process.argv[3], 'utf8').replace(/^#![^\n]*\n/, '');
acorn.parse(code, { ecmaVersion: 'latest', sourceType: 'module' });
NODE

run_node_patch context-limit check
assert_eq "${STATUS[context-limit]:-}" "applied" "status after second check"
[[ "$LAST_OUTPUT" == *"ALREADY_PATCHED"* ]] || fail "second check must report ALREADY_PATCHED"
[[ "$LAST_OUTPUT" != *"NOT_FOUND"* ]] || fail "second check must not report NOT_FOUND"

after_first_apply="$tmp/cli-after-first-apply.js"
cp "$CLI_PATH" "$after_first_apply"
run_node_patch context-limit apply
assert_eq "${STATUS[context-limit]:-}" "applied" "status after second apply"
cmp -s "$CLI_PATH" "$after_first_apply" || fail "second apply must not mutate the file"

restore_patch context-limit
cmp -s "$CLI_PATH" "$baseline" || fail "restore must return to the shared baseline"

printf 'PASS: context-limit registry and UI contract\n'
printf 'PASS: context-limit check/apply/idempotence/restore lifecycle\n'
