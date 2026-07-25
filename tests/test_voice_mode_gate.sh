#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

source "$ROOT/cc-patch-manager.sh"

# Force supported platform for this detector test.
uname() {
  case "${1:-}" in
    -s) printf 'Darwin\n' ;;
    -m) printf 'arm64\n' ;;
    *) command uname "$@" ;;
  esac
}

ACORN_PATH="$tmp/acorn.js"
ensure_acorn

# Minimal 2.1.217-shaped voice unlock surface:
# gate is Wpr(){return UDo()&&qDo()} (2 zero-arg calls), not the older 3-call chain.
cat >"$tmp/voice-2call.js" <<'JS'
function Auth(){return!0}
function TokenProbe(){return!0}
function Sess(){return{accessToken:"t"}}
function Ji(k){return k==="allow_voice_mode"}
function UDo(){try{if(!Auth())return!1;return TokenProbe()}catch{return!1}}
function qDo(){return Ji("allow_voice_mode")}
function Wpr(){return UDo()&&qDo()}
function V1s(){if(!Auth())return!1;let e=Sess();return e!==null&&e.accessToken!==null}
const NFd={isVoiceStreamAvailable:()=>V1s};
async function GDo(e,t){
  const q=new URLSearchParams({encoding:"linear16",stt_provider:"deepgram-nova3"});
  const path="/api/ws/speech_to_text/voice_stream";
  e.onReady();e.onTranscript("hi",!0);return{path,q}
}
function writeUserSettings(k,v){return{ok:!0}}
function settingsUi({settingsData,setAppState,setSettingsData,setChanges}){
  writeUserSettings("userSettings",{});
  return{settings:[{id:"autoCompact"},{id:"language"},{id:"editor"}]}
}
const Iry={type:"local",name:"voice",description:"Toggle voice mode",argumentHint:"[hold|tap|off]",availability:["claude-ai"],get isHidden(){return!Wpr()},supportsNonInteractive:!1};
JS

# Older 3-call gate must still match.
cat >"$tmp/voice-3call.js" <<'JS'
function Auth(){return!0}
function TokenProbe(){return!0}
function Feature(){return Ji("allow_voice_mode")}
function Extra(){return!0}
function Ji(k){return k==="allow_voice_mode"}
function UDo(){try{if(!Auth())return!1;return TokenProbe()}catch{return!1}}
function Wpr(){return UDo()&&Feature()&&Extra()}
function Sess(){return{accessToken:"t"}}
function V1s(){if(!Auth())return!1;let e=Sess();return e!==null&&e.accessToken!==null}
const NFd={isVoiceStreamAvailable:()=>V1s};
async function GDo(e,t){
  const q=new URLSearchParams({encoding:"linear16",stt_provider:"deepgram-nova3"});
  const path="/api/ws/speech_to_text/voice_stream";
  e.onReady();e.onTranscript("hi",!0);return{path,q}
}
function writeUserSettings(k,v){return{ok:!0}}
function settingsUi({settingsData,setAppState,setSettingsData,setChanges}){
  writeUserSettings("userSettings",{});
  return{settings:[{id:"autoCompact"},{id:"language"},{id:"editor"}]}
}
const Iry={type:"local",name:"voice",description:"Toggle voice mode",argumentHint:"[hold|tap|off]",availability:["claude-ai"],get isHidden(){return!Wpr()},supportsNonInteractive:!1};
JS

assert_voice_check() {
  local fixture="$1" expected_gate_marker="$2" generated output ec
  generated=$(write_patch_script voice-mode)
  set +e
  output=$(node "$generated" "$ACORN_PATH" "$fixture" --check 2>&1)
  ec=$?
  set -e
  rm -f "$generated"

  [[ "$ec" -eq 1 ]] || fail "voice-mode check must exit 1 (NEEDS_PATCH) for $fixture, got $ec (output: $output)"
  [[ "$output" == *"$expected_gate_marker"* ]] || fail "missing gate marker for $fixture: $expected_gate_marker (output: $output)"
  [[ "$output" != *"AST miss: voiceGate"* ]] || fail "voiceGate still missing for $fixture (output: $output)"
  [[ "$output" == *"NEEDS_PATCH"* ]] || fail "expected NEEDS_PATCH for $fixture (output: $output)"
}

assert_voice_check "$tmp/voice-2call.js" "FOUND:voiceGateVmr"
assert_voice_check "$tmp/voice-3call.js" "FOUND:voiceGateVmr"

# Source engine must document 2-call support and not hard-require exactly 3 calls only.
engine=$(write_patch_script voice-mode)
grep -Fq 'calls.length === 2' "$engine" || grep -Eq 'calls\.length (===|==) 2|calls\.length >= 2' "$engine" || fail "engine must accept 2-call voice gates"
if grep -Fq 'if (calls.length === 3)' "$engine" && ! grep -Eq 'calls\.length === 2|calls\.length >= 2|calls\.length == 2' "$engine"; then
  fail "engine still only accepts exactly 3-call voice gates"
fi
rm -f "$engine"

printf 'PASS: voice-mode gate detector accepts 2-call and 3-call shapes\n'
