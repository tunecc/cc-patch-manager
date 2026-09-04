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
module.exports={modelEligible,decide,classifierModel,keybindingsEnabled,defaultKeybindings,createDialogChannel,ultracodeEligible,resolveEffort,ultracodeActive}"
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

assert_patch_effects() {
  local root="$1" layout="$2" patch_id="$3"
  case "$patch_id" in
    auto-mode) assert_auto_effects "$root" ;;
    keybindings) assert_keybinding_effects "$root" ;;
    transcript-dialog) assert_dialog_effects "$root" "$layout" ;;
    ultracode) assert_ultracode_effects "$root" "$layout" ;;
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

requested=("${@:-auto-mode keybindings}")
for patch_id in ${requested[*]}; do
  case "$patch_id" in
    auto-mode|keybindings|transcript-dialog|ultracode) ;;
    *) fail "unsupported lifecycle patch: $patch_id" ;;
  esac
  fixture_assert_lifecycle single-cjs "$patch_id"
  fixture_assert_lifecycle split-esm "$patch_id"
done

# Preserve the exact original boolean spelling for baseline attribution.
fixture_assert_lifecycle single-cjs keybindings "$KEY_FLAG_FALSE"
assert_patched_body_tamper_rejected transcript-dialog 'CC_DIALOG_FIX_CHANNEL_FACTORY:'
assert_patched_body_tamper_rejected transcript-dialog 'CC_DIALOG_FIX_HOST_CLEANUP:'
assert_patched_body_tamper_rejected ultracode 'CC_ULTRACODE_ELIGIBILITY:'
assert_patched_body_tamper_rejected ultracode 'CC_ULTRACODE_EFFORT_FALLBACK:'
assert_patched_body_tamper_rejected ultracode 'CC_ULTRACODE_ACTIVATION:'
assert_transcript_extra_factory_state_rejected
assert_transcript_extra_request_effect_rejected
assert_ultracode_decoy_ignored
assert_ultracode_disconnected_activation_rejected

printf 'PASS: requested patches complete the same lifecycle on single-CJS and split-ESM layouts\n'
