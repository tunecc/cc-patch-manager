#!/usr/bin/env bash
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
  fixture_make_package "$root" split-esm '@cometix/anthropic-cc' 2.1.273
  printf '{"name":"@cometix/anthropic-cc","version":"2.1.273","type":"module"}\n' >"$root/package.json"
}

assert_state() {
  local root="$1" patch_id="$2" expected="$3" output
  output=$(runtime_exec check "$(fixture_entry "$root")" "$patch_id" 2>&1) ||
    fail "$patch_id check failed: $output"
  grep -Fxq "$expected" <<<"$output" || fail "$patch_id expected $expected: $output"
}

auto="$tmp/auto"
make_split_package "$auto"
fixture_add_module "$auto" chunks/auto-gate.js '
function normalizeModel(model){return model}
function currentProvider(){return "firstParty"}
function denylistedModel(model){return model.includes("claude-3-")||model==="claude-opus-4-0"||model==="claude-opus-4-1"||model==="claude-opus-4-5"||model==="claude-sonnet-4-0"||model==="claude-sonnet-4-5"||model==="claude-haiku-4-5"}
export function modelEligible(model){let normalized=normalizeModel(model),provider=currentProvider();if(denylistedModel(normalized))return!1;if(provider!=="firstParty"&&(normalized==="claude-opus-4-6"||normalized==="claude-sonnet-4-6"||normalized.includes("haiku")))return!1;return!0}
export function autoModeStatus(model){return{supported:modelEligible(model),disableFastModeBreakerFires:!1}}
function autoConfig(name){return name==="tengu_auto_mode_config"?{}:null}
export function verifyAutoMode(model){let status=autoModeStatus(model),config=autoConfig("tengu_auto_mode_config");return status.supported&&!config?.disabled}
function decoyDenylisted(model){return model.includes("claude-3-")||model==="claude-opus-4-0"||model==="claude-sonnet-4-0"}
function decoyEligibility(model){let provider=currentProvider();if(decoyDenylisted(model))return!1;if(provider!=="firstParty"&&model==="claude-opus-4-6")return!1;return!0}'
fixture_add_module "$auto" chunks/auto-decision.js '
function log(message,options){return message}
export function decide(result,canAsk,fallback){if(result.unavailable){if(canAsk)return log("Auto mode classifier unavailable for AskUserQuestion, falling back to the question dialog",{level:"warn"}),fallback;return log("Auto mode classifier unavailable, denying with retry guidance (fail closed)",{level:"warn"}),{behavior:"deny",decisionReason:{type:"classifier",classifier:"auto-mode",reason:"unavailable"},message:"retry"}}}'
fixture_add_module "$auto" chunks/auto-model.js '
function currentModel(){return "main"}
function autoConfig(){return {modelByMainModel:{},model:"classifier"}}
function selectModel(){return undefined}
function validateModel(model){return model}
function fallbackModel(model){return model}
export function classifierModel(){let model=currentModel(),config=autoConfig(),selected=selectModel(config?.modelByMainModel)??validateModel(config?.model);if(selected)return{value:selected,src:"gb"};return{value:fallbackModel(model),src:"default"}}'

assert_state "$auto" auto-mode NEEDS_PATCH
runtime_exec apply "$(fixture_entry "$auto")" auto-mode >/dev/null || fail 'auto-mode apply failed'
assert_state "$auto" auto-mode ALREADY_PATCHED
grep -Fq 'CC_AUTO_MODE_MODEL_ELIGIBILITY' "$auto/chunks/auto-gate.js" ||
  fail 'helper-extracted auto gate was not patched'

ultra="$tmp/ultra"
make_split_package "$ultra"
fixture_add_module "$ultra" chunks/ultra-gates.js '
function capability(model,name){return model[name]}
export function xhighGate(model){let value=capability(model,"xhigh_effort");if(value!==void 0)return value;return!1}
export function maxGate(model){let value=capability(model,"max_effort");if(value!==void 0)return value;return!1}'
fixture_add_module "$ultra" chunks/ultra-eligibility.js '
import{xhighGate,maxGate}from"./ultra-gates.js";
function workflowEnabled(){return!0}
function supportsEffort(name,model){return model[name]}
export function ultracodeEligible(model){return workflowEnabled()&&(model===void 0||xhighGate(model)&&supportsEffort("xhigh",model))}'
fixture_add_module "$ultra" chunks/ultra-effort.js '
import{xhighGate,maxGate}from"./ultra-gates.js";
export function resolveEffort(model,effort){let resolved=effort;if(resolved==="max"&&!maxGate(model))resolved="high";if(resolved==="xhigh"&&!xhighGate(model))resolved="high";return resolved}'
fixture_add_module "$ultra" chunks/ultra-activation.js '
import{resolveEffort}from"./ultra-effort.js";
function workflowEnabled(){return!0}
export function ultracodeActive(model,effort,enabled,turnEffort){return enabled===!0&&workflowEnabled()&&resolveEffort(model,effort,{turnEffort})==="xhigh"}'

assert_state "$ultra" ultracode NEEDS_PATCH
runtime_exec apply "$(fixture_entry "$ultra")" ultracode >/dev/null || fail 'ultracode apply failed'
assert_state "$ultra" ultracode ALREADY_PATCHED
grep -Fq '{turnEffort}' "$ultra/chunks/ultra-activation.js" || fail 'turnEffort path was not preserved'
node - "$ultra/chunks/ultra-eligibility.js" "$ultra/chunks/ultra-effort.js" "$ultra/chunks/ultra-activation.js" <<'NODE' || fail 'four-parameter ultracode behavior failed'
const {pathToFileURL} = require('url');
(async () => {
  const [eligible, effort, active] = await Promise.all(process.argv.slice(2).map(file => import(pathToFileURL(file))));
  const model = {xhigh_effort: false, max_effort: true, xhigh: false, max: true};
  if (!eligible.ultracodeEligible(model)) process.exit(1);
  if (effort.resolveEffort(model, 'xhigh') !== 'max') process.exit(1);
  if (!active.ultracodeActive(model, 'xhigh', true, 'max')) process.exit(1);
})().catch(error => { console.error(error); process.exit(1); });
NODE

voice="$tmp/voice"
make_split_package "$voice"
fixture_add_module "$voice" chunks/voice-command.js '
function hasAccount(){return!0}function tokenProbe(){return!0}function featureFlag(){return!0}
function voiceAuthProbe(){try{if(!hasAccount())return!1;return tokenProbe()}catch{return!1}}
function voiceFeatureFlag(){return featureFlag("allow_voice_mode")}
function voiceEntryGate(){return voiceAuthProbe()&&voiceFeatureFlag()}
export const voiceCommand={type:"local",name:"voice",description:"Toggle voice mode",argumentHint:"[hold|tap|off]",availability:["claude-ai"],get isHidden(){return!voiceEntryGate()},supportsNonInteractive:!1}'
fixture_add_module "$voice" chunks/voice-capability.js '
function hasAccount(){return!0}function currentSession(){return{accessToken:"token"}}
export function voiceStreamAvailable(){if(!hasAccount())return!1;let session=currentSession();return session!==null&&session.accessToken!==null}
export const voiceRuntime={isVoiceStreamAvailable:()=>voiceStreamAvailable()}'
fixture_add_module "$voice" chunks/voice-connection.js '
export async function connectVoiceStream(callbacks,options){let query=new URLSearchParams({encoding:"linear16",stt_provider:"deepgram-nova3"}),endpoint="/api/ws/speech_to_text/voice_stream";callbacks.onReady();callbacks.onTranscript("hello",!0);return{endpoint,query}}'
fixture_add_module "$voice" chunks/voice-settings.js '
function writeUserSettings(kind,value){return Promise.resolve({kind,value})}
export function voiceSettings(input){let{settingsData,setAppState,setSettingsData,changeLog}=input;function write(value){return writeUserSettings("userSettings",value)}let settings=[{id:"autoCompact",onChange(value){changeLog.record("autoCompact",value)}},{id:"language"},{id:"editor"}];return{settings}}'

assert_state "$voice" voice-mode NEEDS_PATCH
runtime_exec apply "$(fixture_entry "$voice")" voice-mode >/dev/null || fail 'voice-mode apply failed'
assert_state "$voice" voice-mode ALREADY_PATCHED
node - "$voice/chunks/voice-settings.js" <<'NODE' || fail 'changeLog voice setting behavior failed'
const {pathToFileURL} = require('url');
(async () => {
  const {voiceSettings} = await import(pathToFileURL(process.argv[2]));
  const records = [];
  let settingsData = {}, appState = {settings: {}};
  const result = voiceSettings({
    settingsData,
    setSettingsData(update) { settingsData = update(settingsData); },
    setAppState(update) { appState = update(appState); },
    changeLog: {record(key, value) { records.push([key, value]); }},
  });
  const voice = result.settings.find(setting => setting.id === 'voiceMode');
  if (!voice) process.exit(1);
  await voice.onChange('tap');
  if (settingsData.voice?.mode !== 'tap' || appState.settings.voice?.mode !== 'tap') process.exit(1);
  if (records.length !== 1 || records[0][1] !== 'tap') process.exit(1);
})().catch(error => { console.error(error); process.exit(1); });
NODE

voice_decoy="$tmp/voice-decoy"
make_split_package "$voice_decoy"
fixture_add_module "$voice_decoy" chunks/voice-command.js "$(cat "$voice/chunks/voice-command.js")"
fixture_add_module "$voice_decoy" chunks/voice-capability.js "$(cat "$voice/chunks/voice-capability.js")"
fixture_add_module "$voice_decoy" chunks/voice-connection.js "$(cat "$voice/chunks/voice-connection.js")"
fixture_add_module "$voice_decoy" chunks/voice-settings.js '
function writeUserSettings(kind,value){return Promise.resolve({kind,value})}
export function voiceSettings(input){let{settingsData,setAppState,setSettingsData,changeLog}=input;function write(value){return writeUserSettings("userSettings",value)}function shadowed(changeLog){changeLog.record("decoy","value")}changeLog.toString();let settings=[{id:"autoCompact"},{id:"language"},{id:"editor"}];return{settings}}'
set +e
voice_decoy_output=$(runtime_exec check "$(fixture_entry "$voice_decoy")" voice-mode 2>&1)
voice_decoy_status=$?
set -e
[[ "$voice_decoy_status" -ne 0 ]] || fail 'voice-mode accepted changeLog without a record interface'
grep -Fq 'MISSING_TARGET:settings-ui-schema' <<<"$voice_decoy_output" ||
  fail "voice-mode changeLog decoy produced the wrong diagnostic: $voice_decoy_output"

printf 'PASS: Claude Code 2.1.273 semantic shapes remain patchable\n'
