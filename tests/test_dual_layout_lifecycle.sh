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
module.exports={modelEligible,decide,classifierModel,keybindingsEnabled,defaultKeybindings}"
  else
    fixture_make_package "$root" "$layout" '@cometix/anthropic-cc' 2.1.259
    fixture_add_module "$root" chunks/auto-gate.js "export $AUTO_GATE"
    fixture_add_module "$root" chunks/auto-decision.js "export $AUTO_DECISION"
    fixture_add_module "$root" chunks/auto-model.js "export $AUTO_MODEL"
    fixture_add_module "$root" chunks/keybindings.js "$KEY_FLAG_NEW
$KEYMAP"
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

fixture_assert_lifecycle() {
  local layout="$1" patch_id="$2" key_flag="${3:-}" root before after_apply after_second restored output
  root="$tmp/$layout-$patch_id${key_flag:+-literal-false}"
  fixture_make_dual_patch_package "$root" "$layout" "$key_flag"
  before=$(fixture_hash_sources "$root")

  output=$(runtime_exec check "$(fixture_entry "$root")" "$patch_id" 2>&1) || fail "$layout $patch_id clean check failed: $output"
  grep -Fxq 'NEEDS_PATCH' <<<"$output" || fail "$layout $patch_id clean check did not report NEEDS_PATCH"

  output=$(runtime_exec apply "$(fixture_entry "$root")" "$patch_id" 2>&1) || fail "$layout $patch_id apply failed: $output"
  if [[ "$patch_id" == 'auto-mode' ]]; then assert_auto_effects "$root"; else assert_keybinding_effects "$root"; fi
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

requested=("${@:-auto-mode keybindings}")
for patch_id in ${requested[*]}; do
  case "$patch_id" in
    auto-mode|keybindings) ;;
    *) fail "unsupported lifecycle patch: $patch_id" ;;
  esac
  fixture_assert_lifecycle single-cjs "$patch_id"
  fixture_assert_lifecycle split-esm "$patch_id"
done

# Preserve the exact original boolean spelling for baseline attribution.
fixture_assert_lifecycle single-cjs keybindings "$KEY_FLAG_FALSE"

printf 'PASS: Auto Mode and Keybindings complete the same lifecycle on single-CJS and split-ESM layouts\n'
