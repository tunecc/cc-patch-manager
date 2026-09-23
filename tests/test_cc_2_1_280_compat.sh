#!/usr/bin/env bash
# Regression for @cometix/anthropic-cc 2.1.280 semantic shapes:
# - auto-mode model-eligibility: provider gate extracted into a same-module
#   zero-argument helper, and the legacy claude-3- denylist removed in favor
#   of the opus-4-6/sonnet-4-6/haiku triple.
# - voice-mode entry-gate: the voice command object and the gate function it
#   calls live in different chunks, so the gate must be resolved across the
#   import binding.
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
  fixture_make_package "$root" split-esm '@cometix/anthropic-cc' 2.1.280
}

assert_state() {
  local root="$1" patch_id="$2" expected="$3" output
  output=$(runtime_exec check "$(fixture_entry "$root")" "$patch_id" 2>&1) ||
    fail "$patch_id check failed: $output"
  grep -Fxq "$expected" <<<"$output" || fail "$patch_id expected $expected: $output"
}

# 2.1.280 auto-mode shape: the firstParty comparison lives in a zero-argument
# helper the eligibility function calls, and the denylist is the triple shared
# with the 2.1.273 second condition. The consumption chain (supported property
# -> eligibility -> tengu_auto_mode_config consumer) is unchanged.
auto="$tmp/auto"
make_split_package "$auto"
fixture_add_module "$auto" chunks/auto-gate.js '
function normalizeModel(model){return model}
function currentProvider(){return "firstParty"}
function providerIsThirdParty(){let provider=currentProvider();return provider!=="firstParty"&&!provider.startsWith("anthropic")}
export function modelEligible(model){let normalized=normalizeModel(model);if(normalized==="claude-opus-4-6")return!1;if(providerIsThirdParty()&&(normalized==="claude-opus-4-6"||normalized==="claude-sonnet-4-6"||normalized.includes("haiku")))return!1;return!0}
export function autoModeStatus(model){return{supported:modelEligible(model),disableFastModeBreakerFires:!1}}
function autoConfig(name){return name==="tengu_auto_mode_config"?{}:null}
export function verifyAutoMode(model){let status=autoModeStatus(model),config=autoConfig("tengu_auto_mode_config");return status.supported&&!config?.disabled}'
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
runtime_exec apply "$(fixture_entry "$auto")" auto-mode >/dev/null || fail '2.1.280 auto-mode apply failed'
assert_state "$auto" auto-mode ALREADY_PATCHED
grep -Fq 'CC_AUTO_MODE_MODEL_ELIGIBILITY' "$auto/chunks/auto-gate.js" ||
  fail 'helper-based provider gate was not patched'

# Decoy: the provider helper and the triple are present, but nothing consumes
# the eligibility function through a supported property. Must not match.
auto_decoy="$tmp/auto-decoy"
make_split_package "$auto_decoy"
fixture_add_module "$auto_decoy" chunks/auto-gate.js '
function currentProvider(){return "firstParty"}
function providerIsThirdParty(){let provider=currentProvider();return provider!=="firstParty"&&!provider.startsWith("anthropic")}
export function modelEligible(model){if(model==="claude-opus-4-6")return!1;if(providerIsThirdParty()&&(model==="claude-opus-4-6"||model==="claude-sonnet-4-6"||model.includes("haiku")))return!1;return!0}'
fixture_add_module "$auto_decoy" chunks/auto-decision.js "$(cat "$auto/chunks/auto-decision.js")"
fixture_add_module "$auto_decoy" chunks/auto-model.js "$(cat "$auto/chunks/auto-model.js")"
set +e
auto_decoy_output=$(runtime_exec check "$(fixture_entry "$auto_decoy")" auto-mode 2>&1)
auto_decoy_status=$?
set -e
[[ "$auto_decoy_status" -ne 0 ]] || fail 'auto-mode matched an eligibility function with no consumer'
grep -Fq 'MISSING_TARGET:model-eligibility' <<<"$auto_decoy_output" ||
  fail "auto-mode decoy produced the wrong diagnostic: $auto_decoy_output"

# 2.1.280 voice-mode shape: the command object calls a gate defined in another
# chunk. The gate, its auth probe and its feature flag keep the 2.1.273 shapes.
voice="$tmp/voice"
make_split_package "$voice"
fixture_add_module "$voice" chunks/voice-gate.js '
function hasAccount(){return!0}function tokenProbe(){return!0}function featureFlag(){return!0}
export function voiceAuthProbe(){try{if(!hasAccount())return!1;return tokenProbe()}catch{return!1}}
export function voiceFeatureFlag(){return featureFlag("allow_voice_mode")}
export function voiceEntryGate(){return voiceAuthProbe()&&voiceFeatureFlag()}'
fixture_add_module "$voice" chunks/voice-command.js '
import{voiceEntryGate}from"./voice-gate.js";
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
runtime_exec apply "$(fixture_entry "$voice")" voice-mode >/dev/null || fail '2.1.280 voice-mode apply failed'
assert_state "$voice" voice-mode ALREADY_PATCHED
grep -Fq 'COMETIX_VOICE_GATE' "$voice/chunks/voice-gate.js" ||
  fail 'cross-chunk entry gate was not patched in its defining chunk'
if grep -Fq 'COMETIX_VOICE_GATE' "$voice/chunks/voice-command.js"; then
  fail 'entry gate patch leaked into the command chunk'
fi

printf 'PASS: Claude Code 2.1.280 semantic shapes remain patchable\n'
