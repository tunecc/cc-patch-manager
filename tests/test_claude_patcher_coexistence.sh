#!/usr/bin/env bash
# Regression for coexisting with the upstream CometixSpace patcher:
# - Its .claude-patcher/originals/ directory keeps pristine copies of live
#   chunk files inside the package root. Those copies must stay invisible to
#   scanning and module indexing: no AMBIGUOUS_TARGET from double matches and
#   no "relative module ... does not exist" from graph walks into originals/.
# - Its /*@cc:<id>#<site>*/ markers in live code satisfy the equivalent patch
#   targets that were consumed upstream; remaining targets still apply.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

source "$ROOT/tests/lib/dual-layout-fixture.sh"
source "$ROOT/cc-patch-manager.sh"

make_split_package() {
  local root="$1"
  fixture_make_package "$root" split-esm '@cometix/claude-code' 2.1.284
}

assert_state() {
  local root="$1" patch_id="$2" expected="$3" output
  output=$(runtime_exec check "$(fixture_entry "$root")" "$patch_id" 2>&1) ||
    fail "$patch_id check failed: $output"
  grep -Fxq "$expected" <<<"$output" || fail "$patch_id expected $expected: $output"
}

add_ultracode_modules() {
  local root="$1"
  fixture_add_module "$root" chunks/ultra-gates.js 'function capability(model,name){return model[name]}function workflowEnabled(){return!0}function supportsEffort(name,model){return model[name]}function xhighGate(model){let override=capability(model,"xhigh_effort");if(override!==void 0)return override;return!1}function maxGate(model){let override=capability(model,"max_effort");if(override!==void 0)return override;return!1}
export{xhighGate,maxGate}'
  fixture_add_module "$root" chunks/ultra-eligibility.js 'import{xhighGate as canXhigh,maxGate as canMax}from"./ultra-gates.js";function workflowEnabled(){return!0}function supportsEffort(name,model){return model[name]}export function ultracodeEligible(model){return workflowEnabled()&&(model===void 0||canXhigh(model)&&supportsEffort("xhigh",model))}'
  fixture_add_module "$root" chunks/ultra-effort.js 'import{xhighGate as supportsXhigh,maxGate as supportsMax}from"./ultra-gates.js";export function resolveEffort(model,effort){let resolved=effort;if(resolved==="max"&&!supportsMax(model))resolved="high";if(resolved==="xhigh"&&!supportsXhigh(model))resolved="high";return resolved}'
  fixture_add_module "$root" chunks/ultra-activation.js 'import{resolveEffort as effectiveEffort}from"./ultra-effort.js";function workflowEnabled(){return!0}export function ultracodeActive(model,effort,enabled){return enabled===!0&&workflowEnabled()&&effectiveEffort(model,effort)==="xhigh"}'
  fixture_add_module "$root" chunks/ultra-index.js 'export{ultracodeEligible}from"./ultra-eligibility.js";export{resolveEffort}from"./ultra-effort.js";export{ultracodeActive}from"./ultra-activation.js"'
}

# Fixture A: the upstream patcher state directory sits inside the package root
# with pristine copies of the chunk files our analyzers scan. Before the scan
# exclusion this produced AMBIGUOUS_TARGET (marker matched in live file and its
# originals copy) and TARGET_ERROR (module graph walked into an originals copy
# whose relative imports do not exist there).
polluted="$tmp/polluted"
make_split_package "$polluted"
add_ultracode_modules "$polluted"
fixture_add_module "$polluted" chunks/keybindings.js 'function featureFlag(name,enabled){return enabled}export function keybindingsEnabled(){return featureFlag("tengu_keybinding_customization_release",false)}
export const defaultKeybindings=[{context:"Global",bindings:{"ctrl+c":"app:interrupt","ctrl+d":"app:exit"}},{context:"Transcript",bindings:{"ctrl+c":"app:interrupt"}},{context:"HistorySearch",bindings:{"ctrl+c":"app:interrupt"}}]'
mkdir -p "$polluted/.claude-patcher/originals"
cp "$polluted/chunks/ultra-effort.js" "$polluted/.claude-patcher/originals/chunk-ultra-effort.js"
cp "$polluted/chunks/ultra-eligibility.js" "$polluted/.claude-patcher/originals/chunk-ultra-eligibility.js"
cp "$polluted/chunks/keybindings.js" "$polluted/.claude-patcher/originals/chunk-keybindings.js"
printf '{"unlock-ultracode":{"files":["chunk-ultra-effort.js"],"sites":["xhigh-capability"],"at":"2026-09-29T01:43:21.373Z"}}' \
  >"$polluted/.claude-patcher/applied.json"
printf '{"files":{"chunk-ultra-effort.js":{"patches":["unlock-ultracode"],"bytes":123}}}' \
  >"$polluted/.claude-patcher/originals/manifest.json"
originals_hash=$(fixture_hash_tree "$polluted/.claude-patcher")

set +e
polluted_output=$(runtime_exec check "$(fixture_entry "$polluted")" ultracode 2>&1)
polluted_status=$?
set -e
[[ "$polluted_status" -eq 0 ]] || fail "ultracode check failed on polluted package: $polluted_output"
if grep -Eq 'AMBIGUOUS_TARGET|TARGET_ERROR' <<<"$polluted_output"; then
  fail "polluted package produced pre-fix diagnostics: $polluted_output"
fi
grep -Fxq NEEDS_PATCH <<<"$polluted_output" || fail "ultracode did not report NEEDS_PATCH: $polluted_output"

assert_state "$polluted" keybindings NEEDS_PATCH
runtime_exec apply "$(fixture_entry "$polluted")" ultracode >/dev/null || fail 'ultracode apply failed on polluted package'
runtime_exec apply "$(fixture_entry "$polluted")" keybindings >/dev/null || fail 'keybindings apply failed on polluted package'
assert_state "$polluted" ultracode ALREADY_PATCHED
assert_state "$polluted" keybindings ALREADY_PATCHED
[[ "$(fixture_hash_tree "$polluted/.claude-patcher")" == "$originals_hash" ]] ||
  fail 'apply modified the upstream .claude-patcher state directory'
runtime_exec restore "$(fixture_entry "$polluted")" ultracode >/dev/null || fail 'ultracode restore failed on polluted package'
runtime_exec restore "$(fixture_entry "$polluted")" keybindings >/dev/null || fail 'keybindings restore failed on polluted package'
assert_state "$polluted" ultracode NEEDS_PATCH
[[ "$(fixture_hash_tree "$polluted/.claude-patcher")" == "$originals_hash" ]] ||
  fail 'restore modified the upstream .claude-patcher state directory'

# Fixture B: upstream already patched (and consumed) some sites. Its live-code
# markers satisfy the zero-match targets; anything upstream did not cover still
# applies through the normal engine.
consumed="$tmp/consumed"
make_split_package "$consumed"
fixture_add_module "$consumed" chunks/ultra-gates.js 'export function xhighGate(model){return!0}/*@cc:unlock-ultracode#xhigh-capability*/'
fixture_add_module "$consumed" chunks/ultra-effort.js 'import{xhighGate}from"./ultra-gates.js";export function resolveEffort(model,effort){let resolved=effort;if(resolved==="xhigh"&&!xhighGate(model))resolved="high";return resolved}'
fixture_add_module "$consumed" chunks/ultra-index.js 'export{resolveEffort}from"./ultra-effort.js"'
assert_state "$consumed" ultracode ALREADY_PATCHED

schema_props='p01:0,p02:0,p03:0,p04:0,p05:0,p06:0,p07:0,p08:0,p09:0,p10:0,p11:0,p12:0,p13:0,p14:0,p15:0,p16:0,p17:0,p18:0,p19:0,p20:0,p21:0,p22:0,p23:0,p24:0,p25:0,p26:0,p27:0,p28:0,p29:0,p30:0,p31:0,p32:0,p33:0,p34:0,p35:0,p36:0,p37:0,p38:0,p39:0,p40:0,p41:0,p42:0,p43:0,p44:0,p45:0,p46:0,p47:0,p48:0,p49:0,p50:0'
fixture_add_module "$consumed" chunks/computer-schema.js "
function Bool(){return{optional(){return this},describe(){return this}}}
function Obj(shape){return{optional(){return this},describe(){return this}}}
function Enum(values){return{optional(){return this},describe(){return this}}}
export const settingsSchema={workflowSizeGuideline:Enum([\"small\",\"large\"]).optional(),fileSuggestion:Obj({enabled:Bool().optional()}).optional(),$schema_props,autoCompactEnabled:Bool().optional().describe(\"Automatically compact conversation when context fills\")}"
fixture_add_module "$consumed" chunks/computer-env.js 'export function envTruthy(value){return value==="1"||value==="true"}'
fixture_add_module "$consumed" chunks/computer-settings.js 'let values={};export function readSetting(name,fallback){return Object.prototype.hasOwnProperty.call(values,name)?{source:"userSettings",value:values[name]}:{source:"default",value:fallback}}export function setComputerSettings(next){values=next}'
fixture_add_module "$consumed" chunks/computer-helper-consumer.js 'import{envTruthy}from"./computer-env.js";import{readSetting}from"./computer-settings.js";export function readCompactSetting(){return envTruthy(process.env.DISABLE_AUTO_COMPACT)||readSetting("autoCompactEnabled",void 0).value}'
fixture_add_module "$consumed" chunks/computer-config.js 'const computerDefaults={enabled:false,mouseAnimation:true,hideBeforeAction:true,clipboardGuard:true,coordinateMode:"pixels"};function featureConfig(name,defaults){return{}}export function computerConfig(){return{...computerDefaults,...featureConfig("tengu_malort_pedway",computerDefaults)}}'
fixture_add_module "$consumed" chunks/computer-gate.js 'export function computerEnabled(){return!0}/*@cc:computer-use#gate*/'
fixture_add_module "$consumed" chunks/computer-index.js 'export{settingsSchema}from"./computer-schema.js";export{setComputerSettings}from"./computer-settings.js";export{computerConfig}from"./computer-config.js";export{computerEnabled}from"./computer-gate.js"'
assert_state "$consumed" computer-use NEEDS_PATCH
runtime_exec apply "$(fixture_entry "$consumed")" computer-use >/dev/null || fail 'computer-use apply failed on consumed package'
assert_state "$consumed" computer-use ALREADY_PATCHED
rg -Fq 'computerUseEnabled' "$consumed/chunks/computer-schema.js" ||
  fail 'computer-use did not add the settings keys upstream left missing'
if rg -Fq 'CC_COMPUTER' "$consumed/chunks/computer-gate.js"; then
  fail 'computer-use re-patched a gate already satisfied upstream'
fi

# No upstream marker and no match must still fail fast instead of being
# silently treated as satisfied.
set +e
unmarked_output=$(runtime_exec check "$(fixture_entry "$consumed")" voice-mode 2>&1)
unmarked_status=$?
set -e
[[ "$unmarked_status" -ne 0 ]] || fail 'voice-mode must fail without anchors even when other patches are externally satisfied'

printf 'PASS: upstream .claude-patcher coexistence holds\n'
