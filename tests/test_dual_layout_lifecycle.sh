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

AUTO_GATE='function modelEligible(e){let n=normalizeModel(e),r=currentProvider();if(!providerEnabled(r))return!1;if(n.includes("claude-3-")||n==="claude-opus-4-0"||n==="claude-sonnet-4-0")return!1;if(r!=="firstParty"&&n.includes("haiku"))return!1;return!0}'
AUTO_DECISION='function decide(ft,Ye,C){if(ft.unavailable){if(Ye)return log("Auto mode classifier unavailable for AskUserQuestion, falling back to the question dialog",{level:"warn"}),C;return log("Auto mode classifier unavailable, denying with retry guidance (fail closed)",{level:"warn"}),{behavior:"deny",decisionReason:{type:"classifier",classifier:"auto-mode",reason:"unavailable"},message:"retry"}}}'
AUTO_MODEL='function classifierModel(){let e=currentModel(),n=autoConfig(),r=selectModel(n?.modelByMainModel)??validateModel(n?.model);if(r)return{value:r,src:"gb"};if(probeState()!=="demoted"){let o=externalDefault(e);if(o)return{value:o,src:"default",externalDefault:!0}}return{value:fallbackModel(e),src:"default"}}'
KEY_FLAG_OLD='function keybindingsEnabled(){return featureFlag("tengu_keybinding_customization_release",!1)}'
KEY_FLAG_FALSE='function keybindingsEnabled(){return featureFlag("tengu_keybinding_customization_release",false)}'
KEY_FLAG_NEW='function keybindingsEnabled(){return featureFlag("tengu_keybinding_customization_release",!0)}'
KEYMAP='export const defaultKeybindings=[{context:"Global",bindings:{"ctrl+c":"app:interrupt","ctrl+d":"app:exit"}},{context:"Transcript",bindings:{"ctrl+c":"app:interrupt"}},{context:"HistorySearch",bindings:{"ctrl+c":"app:interrupt"}}]'
SIGNAL_HELPERS='function makeSignal(){let listeners=new Set;return{subscribe(listener){listeners.add(listener);return()=>listeners.delete(listener)},emit(value){for(const listener of listeners)listener(value)}}}function deferred(){let resolve;let promise=new Promise(done=>resolve=done);return{promise,resolve}}'
DIALOG_CHANNEL_OLD='function createDialogChannel(){let events=makeSignal(),cancels=makeSignal(),updates=makeSignal(),pending=new Map,counter=0;return{subscribe:events.subscribe,onCancel:cancels.subscribe,onUpdate:updates.subscribe,reply(reply){let resolver=pending.get(reply.id);if(!resolver)return;pending.delete(reply.id),resolver(reply)},request({kind,payload},options){counter+=1;let id=`dialog-${counter}`,{promise,resolve}=deferred(),signal=options?.signal;if(signal?.aborted)return queueMicrotask(()=>resolve({id,cancelled:!0})),{id,replied:promise,update:()=>{}};let onAbort;if(pending.set(id,value=>{if(signal&&onAbort)signal.removeEventListener("abort",onAbort);resolve(value)}),signal)onAbort=()=>{if(pending.delete(id))resolve({id,cancelled:!0}),cancels.emit(id)},signal.addEventListener("abort",onAbort,{once:!0});return events.emit({id,kind,payload}),{id,replied:promise,update:value=>{if(pending.has(id))updates.emit({id,payload:value})}}}}}'
DIALOG_CHANNEL_CRUCE='function createDialogChannel(){let events=makeSignal(),cancels=makeSignal(),updates=makeSignal(),pending=new Map,counter=0,subscribers=0;return{subscribe(listener){subscribers+=1;let unsubscribe=events.subscribe(listener),closed=!1;return()=>{if(closed)return;closed=!0,subscribers-=1,unsubscribe()}},onCancel:cancels.subscribe,onUpdate:updates.subscribe,reply(reply){let resolver=pending.get(reply.id);if(!resolver)return;pending.delete(reply.id),resolver(reply)},request({kind,payload,userInvoked,hideWhile,holdsTop},options){counter+=1;let id=`dialog-${counter}`,{promise,resolve}=deferred(),signal=options?.signal;if(signal?.aborted||subscribers===0)return queueMicrotask(()=>resolve({id,cancelled:!0})),{id,replied:promise,update:()=>{}};let onAbort;if(pending.set(id,value=>{if(signal&&onAbort)signal.removeEventListener("abort",onAbort);resolve(value)}),signal)onAbort=()=>{if(pending.delete(id))resolve({id,cancelled:!0}),cancels.emit(id)},signal.addEventListener("abort",onAbort,{once:!0});return events.emit({id,kind,payload,userInvoked,hideWhile,holdsTop}),{id,replied:promise,update:value=>{if(pending.has(id))updates.emit({id,payload:value})}}}}}'
DIALOG_HOST_MEMBER='function useDialogHost(channel){let manager=dialogManager();React.useEffect(()=>{if(!channel)return;let ids=new Set,unsubscribe=channel.subscribe(event=>{ids.add(event.id),manager.open(event)}),cancel=channel.onCancel(id=>manager.dismiss(id)),closed=manager.onClosed(reply=>{if(!ids.delete(reply.id))return;channel.reply(reply)});return()=>{unsubscribe(),cancel(),closed();for(const id of ids)manager.dismiss(id),channel.reply({id,cancelled:!0});ids.clear()}},[channel,manager])}'
DIALOG_HOST_DIRECT='function useDialogHost(channel){let manager=dialogManager();useEffect(()=>{if(!channel)return;let ids=new Set,unsubscribe=channel.subscribe(event=>{ids.add(event.id),manager.open(event)}),cancel=channel.onCancel(id=>manager.dismiss(id)),closed=manager.onClosed(reply=>{if(!ids.delete(reply.id))return;channel.reply(reply)});return()=>{unsubscribe(),cancel(),closed();for(const id of ids)manager.dismiss(id),channel.reply({id,cancelled:!0});ids.clear()}},[channel,manager])}'
ULTRA_SUPPORT='function capability(model,name){return model[name]}function workflowEnabled(){return!0}function supportsEffort(name,model){return model[name]}function xhighGate(model){let override=capability(model,"xhigh_effort");if(override!==void 0)return override;return!1}function maxGate(model){let override=capability(model,"max_effort");if(override!==void 0)return override;return!1}'
ULTRA_ELIGIBILITY='function ultracodeEligible(model){return workflowEnabled()&&(model===void 0||xhighGate(model)&&supportsEffort("xhigh",model))}'
ULTRA_FALLBACK='function resolveEffort(model,effort){let resolved=effort;if(resolved==="max"&&!maxGate(model))resolved="high";if(resolved==="xhigh"&&!xhighGate(model))resolved="high";return resolved}'
ULTRA_ACTIVATION='function sessionEffort(model,effort){return resolveEffort(model,effort)}function ultracodeActive(model,effort,enabled){return enabled===!0&&workflowEnabled()&&sessionEffort(model,effort)==="xhigh"}'
VOICE_COMMAND='function voiceAuthProbe(){try{if(!hasAccount())return!1;return tokenProbe()}catch{return!1}}function voiceFeatureFlag(){return featureFlag("allow_voice_mode")}function voiceEntryGate(){return voiceAuthProbe()&&voiceFeatureFlag()}const voiceCommand={type:"local",name:"voice",description:"Toggle voice mode",argumentHint:"[hold|tap|off]",availability:["claude-ai"],get isHidden(){return!voiceEntryGate()},supportsNonInteractive:!1}'
VOICE_CAPABILITY='function voiceStreamAvailable(){if(!hasAccount())return!1;let session=currentSession();return session!==null&&session.accessToken!==null}const voiceRuntime={isVoiceStreamAvailable:()=>voiceStreamAvailable()}'
VOICE_CONNECTION='async function connectVoiceStream(callbacks,options){let query=new URLSearchParams({encoding:"linear16",stt_provider:"deepgram-nova3"}),endpoint="/api/ws/speech_to_text/voice_stream";callbacks.onReady();callbacks.onTranscript("hello",!0);return{endpoint,query}}'
VOICE_SETTINGS='function writeUserSettings(kind,value){return{kind,value}}function voiceSettings({settingsData,setAppState,setSettingsData,setChanges}){writeUserSettings("userSettings",{});let settings=[{id:"autoCompact"},{id:"language"},{id:"editor"}];return{settings}}'
CONTEXT_LIMIT='var contextWindow=200000,compactWindow=200000,outputLimit=32000;function contextDisabled(){return process.env.CLAUDE_CODE_DISABLE_1M_CONTEXT}function configuredMaximum(){let configured=process.env.CLAUDE_CODE_MAX_CONTEXT_TOKENS;return configured||contextWindow}function compactBoundary(){return configuredMaximum()>compactWindow?compactWindow:configuredMaximum()}function readContextWindow(){return contextWindow}function readCompactWindow(){return compactWindow}'
CONTEXT_SETTINGS='class SettingsLoader{applyConfigEnvironmentVariables(env){Object.assign(process.env,env)}}'
COMPUTER_SCHEMA_PROPERTIES='p01:0,p02:0,p03:0,p04:0,p05:0,p06:0,p07:0,p08:0,p09:0,p10:0,p11:0,p12:0,p13:0,p14:0,p15:0,p16:0,p17:0,p18:0,p19:0,p20:0,p21:0,p22:0,p23:0,p24:0,p25:0,p26:0,p27:0,p28:0,p29:0,p30:0,p31:0,p32:0,p33:0,p34:0,p35:0,p36:0,p37:0,p38:0,p39:0,p40:0,p41:0,p42:0,p43:0,p44:0,p45:0,p46:0,p47:0,p48:0,p49:0,p50:0'
COMPUTER_CJS_SCHEMA="const z={boolean(){return this},optional(){return this},describe(){return this},object(){return this},enum(){return this}};const settingsSchema={$COMPUTER_SCHEMA_PROPERTIES,autoCompactEnabled:z.boolean().optional().describe(\"compact conversation setting\")};"
COMPUTER_HELPERS='let computerSettings={};function envTruthy(value){return value==="1"||value==="true"}function readSetting(name,fallback){return Object.prototype.hasOwnProperty.call(computerSettings,name)?{source:"userSettings",value:computerSettings[name]}:{source:"default",value:fallback}}function setComputerSettings(value){computerSettings=value}function readCompactSetting(){return envTruthy(process.env.DISABLE_AUTO_COMPACT)||readSetting("autoCompactEnabled",void 0).value}'
COMPUTER_CONFIG='const computerDefaults={enabled:false,mouseAnimation:true,hideBeforeAction:true,clipboardGuard:true,coordinateMode:"pixels"};function featureConfig(name,defaults){return{}}function computerConfig(){return{...computerDefaults,...featureConfig("tengu_malort_pedway",computerDefaults)}}'
COMPUTER_GATE='function hasSubscription(){return true}function isHipaa(flag){return flag==="hipaa"&&process.env.TEST_HIPAA==="1"}function computerEnabled(){if(isHipaa("hipaa"))return!1;return hasSubscription()&&computerConfig().enabled}'

fixture_make_dual_patch_package() {
  local root="$1" layout="$2" key_flag="${3:-}"
  if [[ "$layout" == "single-cjs" ]]; then
    key_flag="${key_flag:-$KEY_FLAG_OLD}"
    fixture_make_package "$root" "$layout" '@cometix/claude-code' 2.1.224
    fixture_add_module "$root" cli.js "#!/usr/bin/env node
$AUTO_GATE
$AUTO_DECISION
$AUTO_MODEL
$key_flag
${KEYMAP/export const/const}
$SIGNAL_HELPERS
$DIALOG_CHANNEL_OLD
$DIALOG_HOST_MEMBER
$ULTRA_SUPPORT
$ULTRA_ELIGIBILITY
$ULTRA_FALLBACK
$ULTRA_ACTIVATION
$VOICE_COMMAND
$VOICE_CAPABILITY
$VOICE_CONNECTION
$VOICE_SETTINGS
$CONTEXT_LIMIT
$CONTEXT_SETTINGS
$COMPUTER_CJS_SCHEMA
$COMPUTER_HELPERS
$COMPUTER_CONFIG
$COMPUTER_GATE
module.exports={modelEligible,decide,classifierModel,keybindingsEnabled,defaultKeybindings,createDialogChannel,ultracodeEligible,resolveEffort,ultracodeActive,voiceCommand,voiceStreamAvailable,connectVoiceStream,voiceSettings,readContextWindow,readCompactWindow,SettingsLoader,settingsSchema,setComputerSettings,computerConfig,computerEnabled}"
  else
    fixture_make_package "$root" "$layout" '@cometix/anthropic-cc' 2.1.259
    printf '{"name":"@cometix/anthropic-cc","version":"2.1.259","type":"module"}\n' >"$root/package.json"
    fixture_add_module "$root" chunks/auto-gate.js "export $AUTO_GATE"
    fixture_add_module "$root" chunks/auto-decision.js "export $AUTO_DECISION"
    fixture_add_module "$root" chunks/auto-model.js "export $AUTO_MODEL"
    fixture_add_module "$root" chunks/keybindings.js "$KEY_FLAG_NEW
$KEYMAP"
    fixture_add_module "$root" chunks/dialog-channel.js "$SIGNAL_HELPERS
export $DIALOG_CHANNEL_CRUCE"
    fixture_add_module "$root" chunks/dialog-host.js "export $DIALOG_HOST_DIRECT"
    fixture_add_module "$root" chunks/ultra-gates.js "$ULTRA_SUPPORT
export{xhighGate,maxGate}"
    fixture_add_module "$root" chunks/ultra-eligibility.js 'import{xhighGate as canXhigh,maxGate as canMax}from"./ultra-gates.js";function workflowEnabled(){return!0}function supportsEffort(name,model){return model[name]}export function ultracodeEligible(model){return workflowEnabled()&&(model===void 0||canXhigh(model)&&supportsEffort("xhigh",model))}'
    fixture_add_module "$root" chunks/ultra-effort.js 'import{xhighGate as supportsXhigh,maxGate as supportsMax}from"./ultra-gates.js";export function resolveEffort(model,effort){let resolved=effort;if(resolved==="max"&&!supportsMax(model))resolved="high";if(resolved==="xhigh"&&!supportsXhigh(model))resolved="high";return resolved}'
    fixture_add_module "$root" chunks/ultra-activation.js 'import{resolveEffort as effectiveEffort}from"./ultra-effort.js";function workflowEnabled(){return!0}export function ultracodeActive(model,effort,enabled){return enabled===!0&&workflowEnabled()&&effectiveEffort(model,effort)==="xhigh"}'
    fixture_add_module "$root" chunks/ultra-index.js 'export{ultracodeEligible}from"./ultra-eligibility.js";export{resolveEffort}from"./ultra-effort.js";export{ultracodeActive}from"./ultra-activation.js"'
    fixture_add_module "$root" chunks/voice-command.js "$VOICE_COMMAND
export{voiceCommand,voiceEntryGate,voiceAuthProbe,voiceFeatureFlag}"
    fixture_add_module "$root" chunks/voice-capability.js "$VOICE_CAPABILITY
export{voiceStreamAvailable}"
    fixture_add_module "$root" chunks/voice-connection.js "$VOICE_CONNECTION
export{connectVoiceStream}"
    fixture_add_module "$root" chunks/voice-settings.js "$VOICE_SETTINGS
export{voiceSettings}"
    fixture_add_module "$root" chunks/context-limit.js "$CONTEXT_LIMIT
export{readContextWindow,readCompactWindow}"
    fixture_add_module "$root" chunks/context-settings.js "import{readContextWindow,readCompactWindow}from\"./context-limit.js\";$CONTEXT_SETTINGS
export{SettingsLoader,readContextWindow,readCompactWindow}"
    fixture_add_module "$root" chunks/computer-schema.js "function Bool(){return{optional(){return this},describe(){return this}}}function Obj(shape){return{optional(){return this},describe(){return this}}}function Enum(values){return{optional(){return this},describe(){return this}}}export const settingsSchema={$COMPUTER_SCHEMA_PROPERTIES,workflowSizeGuideline:Enum([\"small\",\"large\"]).optional(),fileSuggestion:Obj({enabled:Bool().optional()}).optional(),autoCompactEnabled:Bool().optional().describe(\"Automatically compact conversation when context fills\")}"
    fixture_add_module "$root" chunks/computer-env.js 'export function envTruthy(value){return value==="1"||value==="true"}'
    fixture_add_module "$root" chunks/computer-settings.js 'let values={};export function readSetting(name,fallback){return Object.prototype.hasOwnProperty.call(values,name)?{source:"userSettings",value:values[name]}:{source:"default",value:fallback}}export function setComputerSettings(next){values=next}'
    fixture_add_module "$root" chunks/computer-helper-consumer.js 'import{envTruthy}from"./computer-env.js";import{readSetting}from"./computer-settings.js";export function readCompactSetting(){return envTruthy(process.env.DISABLE_AUTO_COMPACT)||readSetting("autoCompactEnabled",void 0).value}'
    fixture_add_module "$root" chunks/computer-config.js 'const computerDefaults={enabled:false,mouseAnimation:true,hideBeforeAction:true,clipboardGuard:true,coordinateMode:"pixels"};function featureConfig(name,defaults){return{}}export function computerConfig(){return{...computerDefaults,...featureConfig("tengu_malort_pedway",computerDefaults)}}'
    fixture_add_module "$root" chunks/computer-gate.js 'import{computerConfig}from"./computer-config.js";function hasSubscription(){return true}function isHipaa(flag){return flag==="hipaa"&&process.env.TEST_HIPAA==="1"}export function computerEnabled(){if(isHipaa("hipaa"))return!1;return hasSubscription()&&computerConfig().enabled}'
    fixture_add_module "$root" chunks/computer-index.js 'export{settingsSchema}from"./computer-schema.js";export{setComputerSettings}from"./computer-settings.js";export{computerConfig}from"./computer-config.js";export{computerEnabled}from"./computer-gate.js"'
  fi
}

fixture_hash_sources() {
  node - "$1" <<'NODE'
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const root = fs.realpathSync(process.argv[2]);
const hash = crypto.createHash('sha256');
function visit(directory) {
  for (const entry of fs.readdirSync(directory, {withFileTypes: true}).sort((a, b) => a.name.localeCompare(b.name))) {
    if (entry.name.startsWith('.cc-patch-manager-')) continue;
    const absolute = path.join(directory, entry.name);
    const relative = path.relative(root, absolute);
    if (entry.isDirectory()) visit(absolute);
    else if (entry.isFile()) hash.update(relative).update('\0').update(fs.readFileSync(absolute));
  }
}
visit(root);
console.log(hash.digest('hex'));
NODE
}

assert_auto_effects() {
  local root="$1"
  rg -l 'CC_AUTO_MODE_MODEL_ELIGIBILITY' "$root" --glob '*.js' >/dev/null || fail 'model eligibility gate was not unlocked'
  rg -l 'behavior:"ask"' "$root" --glob '*.js' >/dev/null || fail 'classifier fail-closed decision was not changed to ask'
  rg -l 'CLAUDE_CLASSIFIER_MODEL' "$root" --glob '*.js' >/dev/null || fail 'classifier model environment override was not injected'
  rg -l 'falling back to the question dialog' "$root" --glob '*.js' >/dev/null || fail 'AskUserQuestion fallback path was not preserved'
}

assert_keybinding_effects() {
  local root="$1" joined
  joined=$(rg -o 'context:"[^"]+",bindings:\{"ctrl\+c":"[^"]+"' "$root" --glob '*.js' | sort)
  [[ "$joined" == *'context:"Global",bindings:{"ctrl+c":"app:exit"'* ]] || fail 'Global ctrl+c was not changed to app:exit'
  [[ "$joined" == *'context:"Transcript",bindings:{"ctrl+c":"app:interrupt"'* ]] || fail 'Transcript ctrl+c was changed'
  [[ "$joined" == *'context:"HistorySearch",bindings:{"ctrl+c":"app:interrupt"'* ]] || fail 'HistorySearch ctrl+c was changed'
  rg -l 'tengu_keybinding_customization_release",(!0|true)' "$root" --glob '*.js' >/dev/null || fail 'custom keybindings feature flag is not enabled'
}

assert_dialog_effects() {
  local root="$1" layout="$2" module
  if [[ "$layout" == 'single-cjs' ]]; then module="$root/cli.js"; else module="$root/chunks/dialog-channel.js"; fi
  node - "$layout" "$module" <<'NODE' || fail "$layout transcript dialog replay behavior failed"
const path = require('path');
const {pathToFileURL} = require('url');
(async () => {
  const layout = process.argv[2], modulePath = process.argv[3];
  const loaded = layout === 'single-cjs' ? require(modulePath) : await import(pathToFileURL(modulePath));
  const channel = loaded.createDialogChannel();
  const request = channel.request({kind: 'confirm', payload: {value: 7}}, {});
  request.update({value: 8});
  let replayed;
  const unsubscribe = channel.subscribe(event => { replayed = event; });
  await new Promise(resolve => setImmediate(resolve));
  if (!replayed || replayed.id !== request.id || replayed.payload.value !== 8) process.exit(1);
  channel.reply({id: request.id, result: 'accepted'});
  const reply = await request.replied;
  if (reply.result !== 'accepted') process.exit(1);
  unsubscribe();

  const late = channel.request({kind: 'confirm', payload: {value: 9}, userInvoked: true}, {});
  let settled = false, lateEvent;
  late.replied.then(() => { settled = true; });
  await new Promise(resolve => setImmediate(resolve));
  if (settled) process.exit(1);
  channel.subscribe(event => { lateEvent = event; });
  await new Promise(resolve => setImmediate(resolve));
  if (!lateEvent || lateEvent.id !== late.id || (layout === 'split-esm' && lateEvent.userInvoked !== true)) process.exit(1);
  channel.reply({id: late.id, result: 'late'});
  if ((await late.replied).result !== 'late') process.exit(1);

  const controller = new AbortController();
  let cancelledId;
  channel.onCancel(id => { cancelledId = id; });
  const aborted = channel.request({kind: 'confirm', payload: {}}, {signal: controller.signal});
  controller.abort();
  const cancelled = await aborted.replied;
  if (!cancelled.cancelled || cancelledId !== aborted.id) process.exit(1);
})().catch(error => { console.error(error); process.exit(1); });
NODE
  rg -l 'CC_DIALOG_FIX_HOST_CLEANUP' "$root" --glob '*.js' >/dev/null || fail 'dialog host cleanup was not made non-destructive'
}

assert_ultracode_effects() {
  local root="$1" layout="$2" module
  if [[ "$layout" == 'single-cjs' ]]; then module="$root/cli.js"; else module="$root/chunks/ultra-index.js"; fi
  node - "$layout" "$module" <<'NODE' || fail "$layout ultracode max-only behavior failed"
const {pathToFileURL} = require('url');
(async () => {
  const layout = process.argv[2], modulePath = process.argv[3];
  const loaded = layout === 'single-cjs' ? require(modulePath) : await import(pathToFileURL(modulePath));
  const model = {xhigh_effort: false, max_effort: true, xhigh: false, max: true};
  if (loaded.ultracodeEligible(model) !== true) process.exit(1);
  if (loaded.resolveEffort(model, 'xhigh') !== 'max') process.exit(1);
  if (loaded.ultracodeActive(model, 'xhigh', true) !== true) process.exit(1);
})().catch(error => { console.error(error); process.exit(1); });
NODE
}

assert_voice_effects() {
  local root="$1" marker asset
  for marker in COMETIX_VOICE_GATE COMETIX_VOICE_STREAM_AVAIL COMETIX_VOICE_AVAIL \
      COMETIX_VOICE_SETTING COMETIX_ASR_VOICE_STREAM COMETIX_VOICE_AUTH COMETIX_VOICE_FLAG; do
    rg -l "$marker" "$root" --glob '*.js' --glob '!vendor/**' >/dev/null || fail "voice-mode marker missing: $marker"
  done
  for asset in index.js index.d.ts package.json libcometix-asr.darwin-arm64.node; do
    [[ -f "$root/vendor/cometix-asr/$asset" ]] || fail "voice-mode resource missing: $asset"
  done
}

assert_voice_adapter_behavior() {
  local layout="$1" root="$tmp/voice-adapter-behavior-$1" assets="$tmp/voice-adapter-assets-$1" output module
  fixture_make_dual_patch_package "$root" "$layout"
  mkdir -p "$assets"
  printf '%s\n' 'module.exports={startSession(config,callback){queueMicrotask(()=>{callback(null,JSON.stringify({type:"ready",session_id:"test"}));callback(null,JSON.stringify({type:"transcript",stage:"interim",display:"hello"}));callback(null,JSON.stringify({type:"transcript",stage:"stable",display:"hello world"}));callback(null,JSON.stringify({type:"transcript",stage:"session_final",display:"hello world"}));callback(null,JSON.stringify({type:"processed",text:"duplicate final"}));callback(null,JSON.stringify({type:"close"}))});return 1},feedPcm(){},finalizeSession(){},closeSession(){}}' >"$assets/index.js"
  printf '%s\n' 'export function startSession(): number' >"$assets/index.d.ts"
  printf '%s\n' '{"name":"cometix-asr","main":"index.js"}' >"$assets/package.json"
  printf '%s\n' 'test native placeholder' >"$assets/libcometix-asr.darwin-arm64.node"

  output=$(CC_PATCH_VOICE_ASSET_SOURCE="$assets" runtime_exec apply "$(fixture_entry "$root")" voice-mode 2>&1) ||
    fail "$layout voice adapter behavior apply failed: $output"
  if [[ "$layout" == 'single-cjs' ]]; then module="$root/cli.js"; else module="$root/chunks/voice-connection.js"; fi
  node - "$layout" "$module" <<'NODE' || fail "$layout voice adapter behavior changed"
const {pathToFileURL} = require('url');
(async () => {
  const layout = process.argv[2], modulePath = process.argv[3];
  const loaded = layout === 'single-cjs' ? require(modulePath) : await import(pathToFileURL(modulePath));
  const transcripts = [];
  let ready = 0, closed = 0;
  const api = await loaded.connectVoiceStream({
    onReady() { ready += 1; },
    onTranscript(text, final) { transcripts.push({text, final}); },
    onError(error) { throw new Error(String(error)); },
    onClose() { closed += 1; },
  }, {});
  await new Promise(resolve => setImmediate(resolve));
  const interim = transcripts.filter(item => !item.final);
  const finals = transcripts.filter(item => item.final);
  if (!api || ready !== 1 || closed !== 1) process.exit(1);
  if (interim.length !== 2 || interim[0].text !== 'hello' || interim[1].text !== 'hello world') process.exit(1);
  if (finals.length !== 1 || finals[0].text !== 'hello world') process.exit(1);
})().catch(error => { console.error(error); process.exit(1); });
NODE
}

assert_voice_facade_lifecycle() {
  local layout="$1" root="$tmp/voice-facade-$1" output
  fixture_make_dual_patch_package "$root" "$layout"
  CLI_PATH=$(fixture_entry "$root")
  run_node_patch voice-mode check || fail "$layout facade check failed: ${LAST_OUTPUT:-}"
  [[ "${STATUS[voice-mode]:-}" == 'idle' ]] || fail "$layout facade clean state was not idle"
  run_node_patch voice-mode apply || fail "$layout facade apply failed: ${LAST_OUTPUT:-}"
  [[ "${STATUS[voice-mode]:-}" == 'applied' ]] || fail "$layout facade patched state was not applied"
  restore_patch voice-mode || fail "$layout facade restore failed"
  run_node_patch voice-mode check || fail "$layout facade restored check failed: ${LAST_OUTPUT:-}"
  [[ "${STATUS[voice-mode]:-}" == 'idle' ]] || fail "$layout facade restored state was not idle"
  [[ ! -e "$root/vendor/cometix-asr" ]] || fail "$layout facade restore retained VoiceMode resources"
}

assert_voice_restore_without_source() {
  local root="$tmp/voice-restore-without-source" assets="$tmp/voice-restore-assets" moved="$tmp/voice-restore-assets-away" before output
  fixture_make_dual_patch_package "$root" split-esm
  mkdir -p "$assets"
  cp "$ROOT/original-scripts/claude-code-enable-voice-mode-darwin-arm64/cometix-asr/"{index.js,index.d.ts,package.json,libcometix-asr.darwin-arm64.node} "$assets/"
  before=$(fixture_hash_sources "$root")
  CC_PATCH_VOICE_ASSET_SOURCE="$assets" runtime_exec apply "$(fixture_entry "$root")" voice-mode >/dev/null 2>&1 ||
    fail 'voice-mode source-loss fixture apply failed'
  mv "$assets" "$moved"
  output=$(CC_PATCH_VOICE_ASSET_SOURCE="$assets" runtime_exec restore "$(fixture_entry "$root")" voice-mode 2>&1) ||
    fail "voice-mode restore depended on missing external resources: $output"
  [[ "$(fixture_hash_sources "$root")" == "$before" ]] || fail 'voice-mode source-loss restore did not recover original sources'
}

assert_voice_source_symlink_race_rejected() {
  local root="$tmp/voice-source-symlink-race" assets="$tmp/voice-source-symlink-assets" before output
  fixture_make_dual_patch_package "$root" split-esm
  mkdir -p "$assets"
  cp "$ROOT/original-scripts/claude-code-enable-voice-mode-darwin-arm64/cometix-asr/"{index.js,index.d.ts,package.json,libcometix-asr.darwin-arm64.node} "$assets/"
  before=$(fixture_hash_tree "$root")
  output=$(CC_PATCH_VOICE_ASSET_SOURCE="$assets" CC_PATCH_TESTING=1 \
    CC_PATCH_TEST_SWAP_VOICE_SOURCE_AFTER_ANALYSIS='index.js:package.json' \
    runtime_exec apply "$(fixture_entry "$root")" voice-mode 2>&1) || true
  [[ "$output" == *'VoiceMode resource source'* ]] || fail "voice-mode symlink race lacked context: $output"
  [[ "$(fixture_hash_tree "$root")" == "$before" ]] || fail 'voice-mode source symlink race changed the package'
}

assert_context_effects() {
  local root="$1"
  rg -l 'CC_CONTEXT_DEFAULT' "$root" --glob '*.js' >/dev/null || fail 'context-limit default marker missing'
  rg -l 'CC_CONTEXT_SETTINGS_REFRESH' "$root" --glob '*.js' >/dev/null || fail 'context-limit settings refresh marker missing'
}

assert_context_behavior() {
  local layout="$1" root="$tmp/context-behavior-$1" module
  fixture_make_dual_patch_package "$root" "$layout"
  runtime_exec apply "$(fixture_entry "$root")" context-limit >/dev/null 2>&1 || fail "$layout context-limit behavior apply failed"
  if [[ "$layout" == single-cjs ]]; then module="$root/cli.js"; else module="$root/chunks/context-settings.js"; fi
  node - "$layout" "$module" <<'NODE' || fail "$layout context-limit environment behavior changed"
const {pathToFileURL} = require('url');
(async () => {
  delete process.env.CLAUDE_CODE_CONTEXT_LIMIT;
  const layout = process.argv[2], modulePath = process.argv[3];
  const loaded = layout === 'single-cjs' ? require(modulePath) : await import(pathToFileURL(modulePath));
  if (loaded.readContextWindow() !== 200000 || loaded.readCompactWindow() !== 200000) process.exit(1);
  new loaded.SettingsLoader().applyConfigEnvironmentVariables({CLAUDE_CODE_CONTEXT_LIMIT: '345678'});
  if (loaded.readContextWindow() !== 345678 || loaded.readCompactWindow() !== 345678) process.exit(2);
  new loaded.SettingsLoader().applyConfigEnvironmentVariables({CLAUDE_CODE_CONTEXT_LIMIT: '0'});
  if (loaded.readContextWindow() !== 200000 || loaded.readCompactWindow() !== 200000) process.exit(3);
})().catch(error => { console.error(error); process.exit(1); });
NODE
}

assert_context_missing_import_rejected() {
  local root="$tmp/context-missing-import" output
  fixture_make_dual_patch_package "$root" split-esm
  runtime_exec apply "$(fixture_entry "$root")" context-limit >/dev/null 2>&1 || fail 'context missing-import fixture apply failed'
  node - "$root/chunks/context-settings.js" <<'NODE'
const fs = require('fs'), file = process.argv[2], source = fs.readFileSync(file, 'utf8');
fs.writeFileSync(file, source.replace(/import\{__ccRefreshContextLimit as __ccPatchRefreshContextLimit\}from[^;]+;/, ''));
NODE
  output=$(runtime_exec check "$(fixture_entry "$root")" context-limit 2>&1) || true
  grep -Fq 'MISSING_TARGET:settings-env-refresh' <<<"$output" || fail "context-limit accepted a missing setter import: $output"
}

assert_context_negative_shapes_rejected() {
  local kind root output before
  for kind in no-import unrelated-default alias-collision wrong-source; do
    root="$tmp/context-negative-$kind"
    fixture_make_dual_patch_package "$root" split-esm
    case "$kind" in
      no-import)
        fixture_add_module "$root" chunks/context-settings.js "$CONTEXT_SETTINGS
export{SettingsLoader}"
        ;;
      unrelated-default)
        fixture_add_module "$root" chunks/context-limit.js 'var unrelatedA=200000,unrelatedB=200000;function contextDisabled(){return process.env.CLAUDE_CODE_DISABLE_1M_CONTEXT}function configuredMaximum(){return process.env.CLAUDE_CODE_MAX_CONTEXT_TOKENS}export{unrelatedA,unrelatedB}'
        ;;
      alias-collision)
        sed -i '' 's/applyConfigEnvironmentVariables(env)/applyConfigEnvironmentVariables(env,__ccPatchRefreshContextLimit)/' "$root/chunks/context-settings.js"
        ;;
      wrong-source)
        runtime_exec apply "$(fixture_entry "$root")" context-limit >/dev/null 2>&1 || fail 'wrong-source fixture apply failed'
        fixture_add_module "$root" chunks/wrong-context.js 'export function __ccRefreshContextLimit(){}'
        sed -i '' 's#./context-limit.js#./wrong-context.js#' "$root/chunks/context-settings.js"
        ;;
    esac
    before=$(fixture_hash_tree "$root")
    output=$(runtime_exec apply "$(fixture_entry "$root")" context-limit 2>&1) || true
    [[ "$output" == *'MISSING_TARGET:'* || "$output" == *'AMBIGUOUS_TARGET:'* ]] || fail "context-limit accepted $kind: $output"
    [[ "$(fixture_hash_tree "$root")" == "$before" ]] || fail "context-limit apply mutated $kind"
  done
}

assert_computer_effects() {
  local root="$1" layout="$2"
  if [[ "$layout" == single-cjs ]]; then
    rg -q 'computerUseEnabled:' "$root/cli.js" || fail 'computer-use schema setting missing'
    rg -q 'CLAUDE_CODE_COMPUTER_USE' "$root/cli.js" || fail 'computer-use environment gate missing'
    rg -q 'readSetting\("computerUseConfig"' "$root/cli.js" || fail 'computer-use config merge missing'
  else
    rg -l 'CC_COMPUTER_SCHEMA' "$root" --glob '*.js' >/dev/null || fail 'computer-use schema marker missing'
    rg -l 'CC_COMPUTER_ENABLE' "$root" --glob '*.js' >/dev/null || fail 'computer-use enable marker missing'
    rg -l 'CC_COMPUTER_CONFIG' "$root" --glob '*.js' >/dev/null || fail 'computer-use config marker missing'
  fi
}

assert_computer_behavior() {
  local layout="$1" root="$tmp/computer-behavior-$1" module
  fixture_make_dual_patch_package "$root" "$layout"
  runtime_exec apply "$(fixture_entry "$root")" computer-use >/dev/null 2>&1 || fail "$layout computer-use behavior apply failed"
  if [[ "$layout" == single-cjs ]]; then module="$root/cli.js"; else module="$root/chunks/computer-index.js"; fi
  node - "$layout" "$module" <<'NODE' || fail "$layout computer-use behavior changed"
const {pathToFileURL} = require('url');
(async () => {
  delete process.env.CLAUDE_CODE_COMPUTER_USE;
  delete process.env.TEST_HIPAA;
  const layout = process.argv[2], modulePath = process.argv[3];
  const loaded = layout === 'single-cjs' ? require(modulePath) : await import(pathToFileURL(modulePath));
  loaded.setComputerSettings({});
  if (loaded.computerEnabled() !== false) process.exit(1);
  process.env.CLAUDE_CODE_COMPUTER_USE = '1';
  if (loaded.computerEnabled() !== true) process.exit(2);
  delete process.env.CLAUDE_CODE_COMPUTER_USE;
  loaded.setComputerSettings({computerUseEnabled: true, computerUseConfig: {mouseAnimation: false, coordinateMode: 'normalized_0_100'}});
  if (loaded.computerEnabled() !== true) process.exit(3);
  const config = loaded.computerConfig();
  if (config.mouseAnimation !== false || config.coordinateMode !== 'normalized_0_100' || config.clipboardGuard !== true) process.exit(4);
  loaded.setComputerSettings({computerUseEnabled: false});
  if (loaded.computerEnabled() !== false) process.exit(5);
})().catch(error => { console.error(error); process.exit(1); });
NODE
}

assert_computer_missing_helper_rejected() {
  local root="$tmp/computer-missing-helper" before output
  fixture_make_dual_patch_package "$root" split-esm
  fixture_add_module "$root" chunks/computer-helper-consumer.js 'export function readCompactSetting(){return false}'
  before=$(fixture_hash_tree "$root")
  output=$(runtime_exec apply "$(fixture_entry "$root")" computer-use 2>&1) || true
  [[ "$output" == *'MISSING_TARGET:'* ]] || fail "computer-use accepted missing settings helpers: $output"
  [[ "$(fixture_hash_tree "$root")" == "$before" ]] || fail 'computer-use missing-helper apply changed package'
}

assert_computer_facade_lifecycle() {
  local root="$tmp/computer-facade" output
  fixture_make_dual_patch_package "$root" split-esm
  CLI_PATH=$(fixture_entry "$root")
  run_node_patch computer-use check || fail "computer-use facade check failed: ${LAST_OUTPUT:-}"
  [[ "${STATUS[computer-use]:-}" == idle ]] || fail 'computer-use facade clean state was not idle'
  run_node_patch computer-use apply || fail "computer-use facade apply failed: ${LAST_OUTPUT:-}"
  [[ "${STATUS[computer-use]:-}" == applied ]] || fail 'computer-use facade apply state was not applied'
  restore_patch computer-use || fail 'computer-use facade restore failed'
  run_node_patch computer-use check || fail "computer-use facade restored check failed: ${LAST_OUTPUT:-}"
  [[ "${STATUS[computer-use]:-}" == idle ]] || fail 'computer-use facade restored state was not idle'
}

assert_computer_partial_state_repaired() {
  local root="$tmp/computer-partial-state" original_gate="$tmp/computer-original-gate.js" before output enabled_count config_count
  fixture_make_dual_patch_package "$root" split-esm
  before=$(fixture_hash_sources "$root")
  cp "$root/chunks/computer-gate.js" "$original_gate"
  output=$(runtime_exec apply "$(fixture_entry "$root")" computer-use 2>&1) || fail "partial-state setup apply failed: $output"
  cp "$original_gate" "$root/chunks/computer-gate.js"
  output=$(runtime_exec apply "$(fixture_entry "$root")" computer-use 2>&1) || fail "partial-state repair apply failed: $output"
  enabled_count=$(rg -o 'computerUseEnabled:' "$root/chunks/computer-schema.js" | wc -l | tr -d ' ')
  config_count=$(rg -o 'computerUseConfig:' "$root/chunks/computer-schema.js" | wc -l | tr -d ' ')
  [[ "$enabled_count" == 1 && "$config_count" == 1 ]] || fail 'partial-state repair duplicated schema keys'
  runtime_exec check "$(fixture_entry "$root")" computer-use | grep -Fxq ALREADY_PATCHED || fail 'partial-state repair remained incomplete'
  runtime_exec restore "$(fixture_entry "$root")" computer-use >/dev/null 2>&1 || fail 'partial-state restore failed'
  [[ "$(fixture_hash_sources "$root")" == "$before" ]] || fail 'partial-state restore did not recover original sources'
}

assert_computer_untrusted_config_only_rejected() {
  local root="$tmp/computer-untrusted-config-only" before output
  fixture_make_dual_patch_package "$root" split-esm
  sed -i '' 's/,autoCompactEnabled:/,computerUseConfig:Obj({mouseAnimation:Bool().optional()}).optional(),autoCompactEnabled:/' \
    "$root/chunks/computer-schema.js"
  before=$(fixture_hash_tree "$root")
  output=$(runtime_exec apply "$(fixture_entry "$root")" computer-use 2>&1) || true
  [[ "$output" == *'untrusted patch sentinel computerUseConfig'* ]] || \
    fail "computer-use accepted untrusted config-only schema: $output"
  [[ "$(fixture_hash_tree "$root")" == "$before" ]] || \
    fail 'computer-use config-only apply changed package'
}

assert_computer_shadowed_bindings_rejected() {
  local kind root before output
  for kind in helper-params helper-local helper-catch gate-param; do
    root="$tmp/computer-shadowed-$kind"
    fixture_make_dual_patch_package "$root" split-esm
    case "$kind" in
      helper-params)
        sed -i '' 's/readCompactSetting()/readCompactSetting(envTruthy,readSetting)/' \
          "$root/chunks/computer-helper-consumer.js"
        ;;
      helper-local)
        sed -i '' 's/readCompactSetting(){/readCompactSetting(){let envTruthy=value=>value;/' \
          "$root/chunks/computer-helper-consumer.js"
        ;;
      helper-catch)
        fixture_add_module "$root" chunks/computer-helper-consumer.js \
          'import{envTruthy}from"./computer-env.js";import{readSetting}from"./computer-settings.js";export function readCompactSetting(){try{throw 0}catch(envTruthy){return envTruthy(process.env.DISABLE_AUTO_COMPACT)||readSetting("autoCompactEnabled",void 0).value}}'
        ;;
      gate-param)
        sed -i '' 's/computerEnabled()/computerEnabled(computerConfig)/' \
          "$root/chunks/computer-gate.js"
        ;;
    esac
    before=$(fixture_hash_tree "$root")
    output=$(runtime_exec apply "$(fixture_entry "$root")" computer-use 2>&1) || true
    [[ "$output" == *'MISSING_TARGET:'* || "$output" == *'AMBIGUOUS_TARGET:'* ]] || \
      fail "computer-use accepted shadowed $kind binding: $output"
    [[ "$(fixture_hash_tree "$root")" == "$before" ]] || \
      fail "computer-use apply mutated shadowed $kind binding"
  done
}

assert_computer_negative_bindings_rejected() {
  local kind root before output
  for kind in alias-collision wrong-source; do
    root="$tmp/computer-negative-$kind"
    fixture_make_dual_patch_package "$root" split-esm
    case "$kind" in
      alias-collision)
        sed -i '' 's/computerEnabled()/computerEnabled(__ccComputerEnvTruthy)/' "$root/chunks/computer-gate.js"
        ;;
      wrong-source)
        runtime_exec apply "$(fixture_entry "$root")" computer-use >/dev/null 2>&1 || fail 'wrong-source fixture apply failed'
        fixture_add_module "$root" chunks/computer-fake-env.js 'export function envTruthy(){return true}'
        sed -i '' 's#./computer-env.js#./computer-fake-env.js#' "$root/chunks/computer-gate.js"
        ;;
    esac
    before=$(fixture_hash_tree "$root")
    output=$(runtime_exec apply "$(fixture_entry "$root")" computer-use 2>&1) || true
    [[ "$output" == *'MISSING_TARGET:'* || "$output" == *'AMBIGUOUS_TARGET:'* ]] || fail "computer-use accepted $kind: $output"
    [[ "$(fixture_hash_tree "$root")" == "$before" ]] || fail "computer-use apply mutated $kind"
  done
}

assert_patch_effects() {
  local root="$1" layout="$2" patch_id="$3"
  case "$patch_id" in
    auto-mode) assert_auto_effects "$root" ;;
    keybindings) assert_keybinding_effects "$root" ;;
    transcript-dialog) assert_dialog_effects "$root" "$layout" ;;
    ultracode) assert_ultracode_effects "$root" "$layout" ;;
    voice-mode) assert_voice_effects "$root" ;;
    context-limit) assert_context_effects "$root" ;;
    computer-use) assert_computer_effects "$root" "$layout" ;;
    *) fail "unsupported lifecycle effects: $patch_id" ;;
  esac
}

fixture_assert_lifecycle() {
  local layout="$1" patch_id="$2" key_flag="${3:-}" root before after_apply after_second restored output
  root="$tmp/$layout-$patch_id${key_flag:+-literal-false}"
  fixture_make_dual_patch_package "$root" "$layout" "$key_flag"
  before=$(fixture_hash_sources "$root")

  output=$(runtime_exec check "$(fixture_entry "$root")" "$patch_id" 2>&1) || fail "$layout $patch_id clean check failed: $output"
  grep -Fxq 'NEEDS_PATCH' <<<"$output" || fail "$layout $patch_id clean check did not report NEEDS_PATCH"

  output=$(runtime_exec apply "$(fixture_entry "$root")" "$patch_id" 2>&1) || fail "$layout $patch_id apply failed: $output"
  assert_patch_effects "$root" "$layout" "$patch_id"
  after_apply=$(fixture_hash_sources "$root")
  [[ "$after_apply" != "$before" ]] || fail "$layout $patch_id apply did not change managed sources"

  output=$(runtime_exec check "$(fixture_entry "$root")" "$patch_id" 2>&1) || fail "$layout $patch_id patched check failed: $output"
  grep -Fxq 'ALREADY_PATCHED' <<<"$output" || fail "$layout $patch_id patched check did not report ALREADY_PATCHED"

  output=$(runtime_exec apply "$(fixture_entry "$root")" "$patch_id" 2>&1) || fail "$layout $patch_id second apply failed: $output"
  after_second=$(fixture_hash_sources "$root")
  [[ "$after_second" == "$after_apply" ]] || fail "$layout $patch_id second apply changed managed sources"

  output=$(runtime_exec restore "$(fixture_entry "$root")" "$patch_id" 2>&1) || fail "$layout $patch_id restore failed: $output"
  restored=$(fixture_hash_sources "$root")
  [[ "$restored" == "$before" ]] || fail "$layout $patch_id restore did not recover original managed sources"
  if [[ "$patch_id" == 'voice-mode' && -e "$root/vendor/cometix-asr" ]]; then
    fail "$layout voice-mode restore retained originally absent resources"
  fi

  output=$(runtime_exec check "$(fixture_entry "$root")" "$patch_id" 2>&1) || fail "$layout $patch_id restored check failed: $output"
  grep -Fxq 'NEEDS_PATCH' <<<"$output" || fail "$layout $patch_id restored check did not report NEEDS_PATCH"
}

assert_patched_body_tamper_rejected() {
  local patch_id="$1" marker="$2" root output
  root="$tmp/tampered-$patch_id-${marker%:}"
  fixture_make_dual_patch_package "$root" single-cjs
  runtime_exec apply "$(fixture_entry "$root")" "$patch_id" >/dev/null 2>&1 || fail "$patch_id tamper fixture apply failed"
  node - "$root" "$marker" "$ACORN_PATH" <<'NODE'
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const root = process.argv[2], marker = process.argv[3], acorn = require(process.argv[4]);
for (const name of fs.readdirSync(root)) {
  if (!name.endsWith('.js')) continue;
  const file = path.join(root, name), source = fs.readFileSync(file, 'utf8');
  const offset = source.startsWith('#!') ? source.indexOf('\n') + 1 : 0;
  const code = source.slice(offset);
  const markerId = code.indexOf(marker);
  const markerStart = markerId < 0 ? -1 : code.lastIndexOf('/*', markerId);
  const markerEnd = markerStart < 0 ? -1 : code.indexOf('*/', markerId);
  if (markerEnd < 0) continue;
  const ast = acorn.parse(code, {ecmaVersion: 'latest', sourceType: 'script'});
  function find(node) {
    if (!node || typeof node !== 'object') return null;
    if (node.type === 'BlockStatement' && node.start <= markerStart && markerEnd < node.end) return node;
    for (const [key, value] of Object.entries(node)) {
      if (key === 'start' || key === 'end') continue;
      if (Array.isArray(value)) { for (const child of value) { const found = find(child); if (found) return found; } }
      else { const found = find(value); if (found) return found; }
    }
    return null;
  }
  const body = find(ast);
  if (!body) process.exit(1);
  let bodySource = code.slice(body.start, body.end);
  const markerText = code.slice(markerStart, markerEnd + 2);
  bodySource = bodySource.replace(markerText, markerText + 'void 0;');
  const unmarked = bodySource.replace(markerText, '');
  const digest = crypto.createHash('sha256').update(unmarked).digest('hex');
  const forgedMarker = markerText.replace(/[a-f0-9]{64}\*\/$/, digest + '*/');
  bodySource = bodySource.replace(markerText, forgedMarker);
  const forgedBody = bodySource.replace(forgedMarker, '');
  if (crypto.createHash('sha256').update(forgedBody).digest('hex') !== digest) process.exit(1);
  fs.writeFileSync(file, source.slice(0, offset + body.start) + bodySource + source.slice(offset + body.end));
  process.exit(0);
}
process.exit(1);
NODE
  output=$(runtime_exec check "$(fixture_entry "$root")" "$patch_id" 2>&1) || true
  grep -Fq 'MISSING_TARGET:' <<<"$output" || fail "$patch_id accepted a modified manager-produced body: $output"
}

assert_transcript_extra_factory_state_rejected() {
  local root="$tmp/transcript-extra-state" output
  fixture_make_dual_patch_package "$root" split-esm
  node - "$root/chunks/dialog-channel.js" <<'NODE'
const fs = require('fs'), file = process.argv[2], source = fs.readFileSync(file, 'utf8');
fs.writeFileSync(file, source.replace('subscribers=0;return', 'subscribers=0,telemetry=startTelemetry();return'));
NODE
  output=$(runtime_exec check "$(fixture_entry "$root")" transcript-dialog 2>&1) || true
  grep -Fq 'MISSING_TARGET:dialog-channel-factory' <<<"$output" || fail "transcript accepted extra factory state: $output"
}

assert_transcript_extra_request_effect_rejected() {
  local root="$tmp/transcript-extra-request" output
  fixture_make_dual_patch_package "$root" split-esm
  node - "$root/chunks/dialog-channel.js" <<'NODE'
const fs = require('fs'), file = process.argv[2], source = fs.readFileSync(file, 'utf8');
fs.writeFileSync(file, source.replace('request({kind,payload,userInvoked,hideWhile,holdsTop},options){counter+=1;',
  'request({kind,payload,userInvoked,hideWhile,holdsTop},options){recordTelemetry();counter+=1;'));
NODE
  output=$(runtime_exec check "$(fixture_entry "$root")" transcript-dialog 2>&1) || true
  grep -Fq 'MISSING_TARGET:dialog-channel-factory' <<<"$output" || fail "transcript accepted an extra request side effect: $output"
}

assert_ultracode_decoy_ignored() {
  local root="$tmp/ultracode-decoy" output
  fixture_make_dual_patch_package "$root" split-esm
  fixture_add_module "$root" chunks/unrelated-effort.js 'function unrelatedEffort(){return"xhigh"}export function unrelatedActivation(model,effort,enabled){return enabled===!0&&unrelatedEffort(model,effort)==="xhigh"}'
  output=$(runtime_exec check "$(fixture_entry "$root")" ultracode 2>&1) || true
  grep -Fxq 'NEEDS_PATCH' <<<"$output" || fail "ultracode decoy disrupted the confirmed activation target: $output"
  if grep -Fq 'AMBIGUOUS_TARGET:ultracode-activation' <<<"$output"; then
    fail 'ultracode accepted an unrelated activation decoy'
  fi
}

assert_ultracode_disconnected_activation_rejected() {
  local root="$tmp/ultracode-disconnected" output
  fixture_make_dual_patch_package "$root" split-esm
  node - "$root/chunks/ultra-activation.js" <<'NODE'
const fs = require('fs'), file = process.argv[2], source = fs.readFileSync(file, 'utf8');
fs.writeFileSync(file, source.replace('effectiveEffort(model,effort)', 'unrelatedEffort(model,effort)') + '\nfunction unrelatedEffort(){return"xhigh"}\n');
NODE
  output=$(runtime_exec check "$(fixture_entry "$root")" ultracode 2>&1) || true
  grep -Fq 'MISSING_TARGET:ultracode-activation' <<<"$output" || fail "ultracode accepted a disconnected activation target: $output"
}

assert_voice_settings_ambiguity_rejected() {
  local root="$tmp/voice-settings-ambiguous" output
  fixture_make_dual_patch_package "$root" split-esm
  node - "$root/chunks/voice-settings.js" <<'NODE'
const fs = require('fs'), file = process.argv[2], source = fs.readFileSync(file, 'utf8');
fs.writeFileSync(file, source.replace('return{settings}',
  'let duplicateSettings=[{id:"autoCompact"},{id:"language"},{id:"editor"}];return{settings,duplicateSettings}'));
NODE
  output=$(runtime_exec check "$(fixture_entry "$root")" voice-mode 2>&1) || true
  grep -Fq 'AMBIGUOUS_TARGET:settings-ui-schema:2' <<<"$output" ||
    fail "voice-mode accepted ambiguous settings arrays: $output"
}

assert_voice_gate_non_call_leaf_rejected() {
  local root="$tmp/voice-gate-non-call-leaf" output
  fixture_make_dual_patch_package "$root" split-esm
  node - "$root/chunks/voice-command.js" <<'NODE'
const fs = require('fs'), file = process.argv[2], source = fs.readFileSync(file, 'utf8');
fs.writeFileSync(file, source.replace('voiceAuthProbe()&&voiceFeatureFlag()',
  'voiceAuthProbe()&&voiceFeatureFlag()&&voiceEnabled'));
NODE
  output=$(runtime_exec check "$(fixture_entry "$root")" voice-mode 2>&1) || true
  grep -Fq 'MISSING_TARGET:entry-gate' <<<"$output" || fail "voice-mode accepted a gate with a non-call leaf: $output"
}

requested=("${@:-auto-mode keybindings}")
for patch_id in ${requested[*]}; do
  case "$patch_id" in
    auto-mode|keybindings|transcript-dialog|ultracode|voice-mode|context-limit|computer-use) ;;
    *) fail "unsupported lifecycle patch: $patch_id" ;;
  esac
  fixture_assert_lifecycle single-cjs "$patch_id"
  fixture_assert_lifecycle split-esm "$patch_id"
done

if [[ " ${requested[*]} " == *' voice-mode '* ]]; then
  missing_voice="$tmp/voice-missing-assets"
  fixture_make_dual_patch_package "$missing_voice" split-esm
  missing_before=$(fixture_hash_tree "$missing_voice")
  output=$(CC_PATCH_VOICE_ASSET_SOURCE="$tmp/does-not-exist" runtime_exec apply "$(fixture_entry "$missing_voice")" voice-mode 2>&1) || true
  [[ "$output" == *'VoiceMode resource'* ]] || fail "voice-mode missing resource error lacked context: $output"
  [[ "$(fixture_hash_tree "$missing_voice")" == "$missing_before" ]] || fail 'voice-mode missing resources changed the package'
  assert_voice_adapter_behavior single-cjs
  assert_voice_adapter_behavior split-esm
  assert_voice_facade_lifecycle single-cjs
  assert_voice_facade_lifecycle split-esm
  assert_voice_restore_without_source
  assert_voice_source_symlink_race_rejected
  assert_voice_settings_ambiguity_rejected
  assert_voice_gate_non_call_leaf_rejected
fi
if [[ " ${requested[*]} " == *' context-limit '* ]]; then
  assert_context_behavior single-cjs
  assert_context_behavior split-esm
  assert_context_missing_import_rejected
  assert_context_negative_shapes_rejected
fi
if [[ " ${requested[*]} " == *' computer-use '* ]]; then
  assert_computer_behavior single-cjs
  assert_computer_behavior split-esm
  assert_computer_missing_helper_rejected
  assert_computer_facade_lifecycle
  assert_computer_partial_state_repaired
  assert_computer_untrusted_config_only_rejected
  assert_computer_shadowed_bindings_rejected
  assert_computer_negative_bindings_rejected
fi

# Preserve the exact original boolean spelling for baseline attribution.
fixture_assert_lifecycle single-cjs keybindings "$KEY_FLAG_FALSE"
assert_patched_body_tamper_rejected transcript-dialog 'CC_DIALOG_FIX_CHANNEL_FACTORY:'
assert_patched_body_tamper_rejected transcript-dialog 'CC_DIALOG_FIX_HOST_CLEANUP:'
assert_patched_body_tamper_rejected ultracode 'CC_ULTRACODE_ELIGIBILITY:'
assert_patched_body_tamper_rejected ultracode 'CC_ULTRACODE_EFFORT_FALLBACK:'
assert_patched_body_tamper_rejected ultracode 'CC_ULTRACODE_ACTIVATION:'
assert_patched_body_tamper_rejected voice-mode 'CC_COMETIX_VOICE_GATE:'
assert_patched_body_tamper_rejected voice-mode 'CC_COMETIX_ASR_VOICE_STREAM:'
assert_transcript_extra_factory_state_rejected
assert_transcript_extra_request_effect_rejected
assert_ultracode_decoy_ignored
assert_ultracode_disconnected_activation_rejected

printf 'PASS: requested patches complete the same lifecycle on single-CJS and split-ESM layouts\n'
