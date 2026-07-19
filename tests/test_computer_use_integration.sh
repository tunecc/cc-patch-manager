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

engine=$(write_patch_script computer-use)
grep -Fq 'CLAUDE_CODE_COMPUTER_USE' "$engine" || fail "generated engine lost its env marker"
grep -Fq 'computerUseEnabled' "$engine" || fail "generated engine lost its settings marker"
grep -Fq 'computerUseConfig' "$engine" || fail "generated engine lost its config marker"
grep -Fq 'ALREADY_PATCHED' "$engine" || fail "generated engine lacks idempotence marker"
grep -Fq 'CC_PATCH_SKIP_BACKUP' "$engine" || fail "generated engine lacks baseline adapter"
rm -f "$engine"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
CLI_PATH="$tmp/cli.js"
ACORN_PATH="$tmp/acorn.js"

cat >"$CLI_PATH" <<'JS'
#!/usr/bin/env node
const z={boolean(){return this},optional(){return this},describe(){return this},object(){return this},enum(){return this}};
const settingsSchema={
  p01:0,p02:0,p03:0,p04:0,p05:0,p06:0,p07:0,p08:0,p09:0,p10:0,
  p11:0,p12:0,p13:0,p14:0,p15:0,p16:0,p17:0,p18:0,p19:0,p20:0,
  p21:0,p22:0,p23:0,p24:0,p25:0,p26:0,p27:0,p28:0,p29:0,p30:0,
  p31:0,p32:0,p33:0,p34:0,p35:0,p36:0,p37:0,p38:0,p39:0,p40:0,
  p41:0,p42:0,p43:0,p44:0,p45:0,p46:0,p47:0,p48:0,p49:0,p50:0,
  autoCompactEnabled:z.boolean().optional().describe("compact conversation setting")
};
function envTruthy(value){return value==="1"}
function readSetting(name,fallback){return{source:"default",value:fallback}}
function readCompact(){return envTruthy(process.env.DISABLE_AUTO_COMPACT)||readSetting("autoCompactEnabled",void 0).value}
const computerDefaults={enabled:false,mouseAnimation:true};
function featureConfig(name,defaults){return{}}
function computerConfig(){return{...computerDefaults,...featureConfig("tengu_malort_pedway",computerDefaults)}}
function hasSubscription(){return true}
function computerEnabled(){return hasSubscription()&&computerConfig().enabled}
console.log(settingsSchema,readCompact(),computerEnabled());
JS

before="$tmp/cli-before.js"
cp "$CLI_PATH" "$before"

run_node_patch computer-use check
assert_eq "${STATUS[computer-use]:-}" "idle" "initial computer-use status"
assert_eq "${MSG[computer-use]:-}" "需修补 3 处" "initial computer-use patch count"

run_node_patch computer-use apply
assert_eq "${STATUS[computer-use]:-}" "applied" "status after computer-use apply"
assert_eq "${MSG[computer-use]:-}" "已修补 3 处" "computer-use apply count"

baseline="$CLI_PATH.cc-patch-baseline"
[[ -f "$baseline" ]] || fail "manager baseline was not created"
cmp -s "$baseline" "$before" || fail "baseline must preserve the unpatched fixture"
if compgen -G "$CLI_PATH.backup-computer-use-*" >/dev/null; then
  fail "manager must not create timestamp computer-use backups"
fi

grep -Fq 'CLAUDE_CODE_COMPUTER_USE' "$CLI_PATH" || fail "patched cli lost env gate"
grep -Fq 'computerUseEnabled' "$CLI_PATH" || fail "patched cli lost settings gate"
grep -Fq 'computerUseConfig' "$CLI_PATH" || fail "patched cli lost config merge"

node - "$ACORN_PATH" "$CLI_PATH" <<'NODE'
const fs = require('fs');
const acorn = require(process.argv[2]);
const code = fs.readFileSync(process.argv[3], 'utf8').replace(/^#![^\n]*\n/, '');
acorn.parse(code, { ecmaVersion: 'latest', sourceType: 'module' });
NODE

run_node_patch computer-use check
assert_eq "${STATUS[computer-use]:-}" "applied" "status after second computer-use check"
[[ "$LAST_OUTPUT" == *"ALREADY_PATCHED"* ]] || fail "second check must report ALREADY_PATCHED"

after_first_apply="$tmp/cli-after-first-apply.js"
cp "$CLI_PATH" "$after_first_apply"
run_node_patch computer-use apply
assert_eq "${STATUS[computer-use]:-}" "applied" "status after second computer-use apply"
cmp -s "$CLI_PATH" "$after_first_apply" || fail "second apply must not mutate the file"

restore_patch computer-use
cmp -s "$CLI_PATH" "$baseline" || fail "restore must return to the shared baseline"

printf 'PASS: computer-use check/apply/idempotence/restore lifecycle\n'
