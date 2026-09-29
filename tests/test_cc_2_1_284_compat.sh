#!/usr/bin/env bash
# Regression for @cometix 2.1.284 semantic shapes:
# - ultracode: eligibility now delegates to the staged xhigh gate through a
#   same-module wrapper with no xhigh/max literal (ZT/Q shape), and "active"
#   is derived from the {ultracode:"xhigh"} alias mapping instead of a
#   resolved-effort comparison, so the activation target is vacuous there.
# - computer-use settings schema: property values are lazy zero-argument
#   arrow functions (()=>Bool().optional()...); inserted keys must keep the
#   same thunk form because the schema host calls each field value.
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
  fixture_make_package "$root" split-esm '@cometix/anthropic-cc' 2.1.284
  printf '{"name":"@cometix/anthropic-cc","version":"2.1.284","type":"module"}\n' >"$root/package.json"
}

assert_state() {
  local root="$1" patch_id="$2" expected="$3" output
  output=$(runtime_exec check "$(fixture_entry "$root")" "$patch_id" 2>&1) ||
    fail "$patch_id check failed: $output"
  grep -Fxq "$expected" <<<"$output" || fail "$patch_id expected $expected: $output"
}

# 2.1.284 ultracode shape: staged capability gates, wrapper-based eligibility
# (void-0 comparison, no xhigh/max literal), dual downgrade fallback, and the
# alias-mapping activation. A decoy eligibility function with a void-0
# comparison whose call never reaches the xhigh gate must not match.
ultra="$tmp/ultra"
make_split_package "$ultra"
fixture_add_module "$ultra" chunks/effort-gates.js '
function statGate(model,name){return void 0}
function overrideGate(model,name){return!1}
export function xhighGate(model){let s=statGate(model,"xhigh_effort");if(s!==void 0)return s;if(model.name==="claude-opus-4-6"||model.name==="claude-sonnet-4-6"||model.name.includes("haiku"))return!1;if(overrideGate(model,"xhigh_effort"))return!0;return!!model.xhigh}
export function maxGate(model){let s=statGate(model,"max_effort");if(s!==void 0)return s;return!!model.max}'
fixture_add_module "$ultra" chunks/effort-core.js '
import{xhighGate as canXhigh,maxGate as canMax}from"./effort-gates.js";
function workflowsEnabled(){return!0}
function gate(model){return canXhigh(model)}
function unrelatedGate(model){return!!model.other}
function settings(){return{}}
const ULTRA_ALIAS={ultracode:"xhigh"};
function aliasOf(value){if(typeof value!=="string")return;let name=value.trim().toLowerCase();return Object.hasOwn(ULTRA_ALIAS,name)?name:void 0}
export function ultracodeAvailable(model){return workflowsEnabled()&&(model===void 0||gate(model))}
export function resolveEffort(model,effort){let resolved=effort;if(resolved==="max"&&!canMax(model))resolved="high";if(resolved==="xhigh"&&!canXhigh(model))resolved="high";return resolved}
export function ultracodeActive(request){return settings().ultracode===!0||aliasOf(request)==="ultracode"}
export function unrelatedEligibility(model){return model===void 0||unrelatedGate(model)}'
fixture_add_module "$ultra" chunks/effort-index.js 'export{ultracodeAvailable,resolveEffort,ultracodeActive,unrelatedEligibility}from"./effort-core.js"'

assert_state "$ultra" ultracode NEEDS_PATCH
runtime_exec apply "$(fixture_entry "$ultra")" ultracode >/dev/null || fail '2.1.284 ultracode apply failed'
assert_state "$ultra" ultracode ALREADY_PATCHED
node - "$ultra/chunks/effort-index.js" <<'NODE' || fail '2.1.284 ultracode max-only behavior failed'
const {pathToFileURL} = require('url');
(async () => {
  const loaded = await import(pathToFileURL(process.argv[2]));
  const model = {name: 'claude-test-max', xhigh: false, max: true};
  if (loaded.ultracodeAvailable(model) !== true) process.exit(1);
  if (loaded.resolveEffort(model, 'xhigh') !== 'max') process.exit(1);
  if (loaded.ultracodeActive('ultracode') !== true) process.exit(1);
  if (loaded.unrelatedEligibility === undefined) process.exit(1);
})().catch(error => { console.error(error); process.exit(1); });
NODE
runtime_exec restore "$(fixture_entry "$ultra")" ultracode >/dev/null || fail '2.1.284 ultracode restore failed'
assert_state "$ultra" ultracode NEEDS_PATCH

# Decoy: identical staged shape without the alias mapping. The activation
# target keeps cardinality 1, so the plan must fail fast with a missing
# activation target instead of silently skipping it.
ultra_noalias="$tmp/ultra-noalias"
make_split_package "$ultra_noalias"
fixture_add_module "$ultra_noalias" chunks/effort-gates.js "$(cat "$ultra/chunks/effort-gates.js")"
fixture_add_module "$ultra_noalias" chunks/effort-core.js '
import{xhighGate as canXhigh,maxGate as canMax}from"./effort-gates.js";
function workflowsEnabled(){return!0}
function gate(model){return canXhigh(model)}
export function ultracodeAvailable(model){return workflowsEnabled()&&(model===void 0||gate(model))}
export function resolveEffort(model,effort){let resolved=effort;if(resolved==="max"&&!canMax(model))resolved="high";if(resolved==="xhigh"&&!canXhigh(model))resolved="high";return resolved}'
fixture_add_module "$ultra_noalias" chunks/effort-index.js 'export{ultracodeAvailable,resolveEffort}from"./effort-core.js"'
set +e
noalias_output=$(runtime_exec check "$(fixture_entry "$ultra_noalias")" ultracode 2>&1)
noalias_status=$?
set -e
[[ "$noalias_status" -ne 0 ]] || fail 'staged shape without alias mapping must require an activation target'
grep -Fxq 'MISSING_TARGET:ultracode-activation' <<<"$noalias_output" ||
  fail "no-alias decoy produced the wrong diagnostic: $noalias_output"

# 2.1.284 computer-use settings schema: lazy arrow property values. Inserted
# keys must stay thunk-shaped; the sibling classification must unwrap arrows
# before counting object/enum schema constructors.
computer="$tmp/computer"
make_split_package "$computer"
schema_props='p01:()=>0,p02:()=>0,p03:()=>0,p04:()=>0,p05:()=>0,p06:()=>0,p07:()=>0,p08:()=>0,p09:()=>0,p10:()=>0,p11:()=>0,p12:()=>0,p13:()=>0,p14:()=>0,p15:()=>0,p16:()=>0,p17:()=>0,p18:()=>0,p19:()=>0,p20:()=>0,p21:()=>0,p22:()=>0,p23:()=>0,p24:()=>0,p25:()=>0,p26:()=>0,p27:()=>0,p28:()=>0,p29:()=>0,p30:()=>0,p31:()=>0,p32:()=>0,p33:()=>0,p34:()=>0,p35:()=>0,p36:()=>0,p37:()=>0,p38:()=>0,p39:()=>0,p40:()=>0,p41:()=>0,p42:()=>0,p43:()=>0,p44:()=>0,p45:()=>0,p46:()=>0,p47:()=>0,p48:()=>0,p49:()=>0,p50:()=>0'
fixture_add_module "$computer" chunks/computer-schema.js "
function Bool(){return{optional(){return this},describe(){return this}}}
function Obj(shape){return{optional(){return this},describe(){return this}}}
function Enum(values){return{optional(){return this},describe(){return this}}}
export const settingsSchema={jsonSchema:()=>Obj({ref:()=>Bool().optional()}),flavor:()=>Enum([\"small\",\"large\"]).optional(),$schema_props,autoCompactEnabled:()=>Bool().optional().describe(\"Automatically compact conversation when context fills\")}"
fixture_add_module "$computer" chunks/computer-env.js 'export function envTruthy(value){return value==="1"||value==="true"}'
fixture_add_module "$computer" chunks/computer-settings.js 'let values={};export function readSetting(name,fallback){return Object.prototype.hasOwnProperty.call(values,name)?{source:"userSettings",value:values[name]}:{source:"default",value:fallback}}export function setComputerSettings(next){values=next}'
fixture_add_module "$computer" chunks/computer-helper-consumer.js 'import{envTruthy}from"./computer-env.js";import{readSetting}from"./computer-settings.js";export function readCompactSetting(){return envTruthy(process.env.DISABLE_AUTO_COMPACT)||readSetting("autoCompactEnabled",void 0).value}'
fixture_add_module "$computer" chunks/computer-config.js 'const computerDefaults={enabled:false,mouseAnimation:true,hideBeforeAction:true,clipboardGuard:true,coordinateMode:"pixels"};function featureConfig(name,defaults){return{}}export function computerConfig(){return{...computerDefaults,...featureConfig("tengu_malort_pedway",computerDefaults)}}'
fixture_add_module "$computer" chunks/computer-gate.js 'import{computerConfig}from"./computer-config.js";function hasSubscription(){return true}function isHipaa(flag){return flag==="hipaa"&&process.env.TEST_HIPAA==="1"}export function computerEnabled(){if(isHipaa("hipaa"))return!1;return hasSubscription()&&computerConfig().enabled}'
fixture_add_module "$computer" chunks/computer-index.js 'export{settingsSchema}from"./computer-schema.js";export{setComputerSettings}from"./computer-settings.js";export{computerConfig}from"./computer-config.js";export{computerEnabled}from"./computer-gate.js"'

assert_state "$computer" computer-use NEEDS_PATCH
runtime_exec apply "$(fixture_entry "$computer")" computer-use >/dev/null || fail 'lazy schema apply failed'
assert_state "$computer" computer-use ALREADY_PATCHED
rg -Fq 'computerUseEnabled:()=>Bool().optional().describe(' "$computer/chunks/computer-schema.js" ||
  fail 'inserted computerUseEnabled is not a lazy thunk'
rg -Fq 'computerUseConfig:()=>Obj({' "$computer/chunks/computer-schema.js" ||
  fail 'inserted computerUseConfig is not a lazy thunk'
runtime_exec restore "$(fixture_entry "$computer")" computer-use >/dev/null || fail 'lazy schema restore failed'
assert_state "$computer" computer-use NEEDS_PATCH
if rg -Fq 'computerUseEnabled' "$computer/chunks/computer-schema.js"; then
  fail 'restored schema still contains inserted keys'
fi

# Old direct-call schema form keeps matching (no arrows involved).
computer_direct="$tmp/computer-direct"
make_split_package "$computer_direct"
fixture_add_module "$computer_direct" chunks/computer-schema.js "
function Bool(){return{optional(){return this},describe(){return this}}}
function Obj(shape){return{optional(){return this},describe(){return this}}}
function Enum(values){return{optional(){return this},describe(){return this}}}
export const settingsSchema={$schema_props,workflowSizeGuideline:Enum([\"small\",\"large\"]).optional(),fileSuggestion:Obj({enabled:Bool().optional()}).optional(),autoCompactEnabled:Bool().optional().describe(\"Automatically compact conversation when context fills\")}"
for m in computer-env computer-settings computer-helper-consumer computer-config computer-gate computer-index; do
  cp "$computer/chunks/$m.js" "$computer_direct/chunks/$m.js"
done
assert_state "$computer_direct" computer-use NEEDS_PATCH
runtime_exec apply "$(fixture_entry "$computer_direct")" computer-use >/dev/null || fail 'direct schema apply failed'
assert_state "$computer_direct" computer-use ALREADY_PATCHED
rg -Fq 'computerUseEnabled:Bool().optional().describe(' "$computer_direct/chunks/computer-schema.js" ||
  fail 'direct schema insertion changed form'

printf 'PASS: Claude Code 2.1.284 semantic shapes remain patchable\n'
