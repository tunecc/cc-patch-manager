#!/usr/bin/env bash
set -euo pipefail
# restore-all: a fast baseline reset that restores every managed file from the
# trusted baseline and removes patch-created directories WITHOUT re-applying any
# retained patch (there are none — everything is being removed). This is the tractable
# path for "全还原" on large single-CJS bundles where per-patch restore would
# re-apply every other patch (15 reapply parses of a 23 MB file on 2.1.224).

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

source "$ROOT/tests/lib/dual-layout-fixture.sh"
source "$ROOT/cc-patch-manager.sh"

AUTO_GATE='function modelEligible(e){let n=normalizeModel(e),r=currentProvider();if(!providerEnabled(r))return!1;if(n.includes("claude-3-")||n==="claude-opus-4-0"||n==="claude-sonnet-4-0")return!1;if(r!=="firstParty"&&n.includes("haiku"))return!1;return!0}'
AUTO_DECISION='function decide(ft,Ye,C){if(ft.unavailable){if(Ye)return log("Auto mode classifier unavailable for AskUserQuestion, falling back to the question dialog",{level:"warn"}),C;return log("Auto mode classifier unavailable, denying with retry guidance (fail closed)",{level:"warn"}),{behavior:"deny",decisionReason:{type:"classifier",classifier:"auto-mode",reason:"unavailable"},message:"retry"}}}'
AUTO_MODEL='function classifierModel(){let e=currentModel(),n=autoConfig(),r=selectModel(n?.modelByMainModel)??validateModel(n?.model);if(r)return{value:r,src:"gb"};if(probeState()!=="demoted"){let o=externalDefault(e);if(o)return{value:o,src:"default",externalDefault:!0}}return{value:fallbackModel(e),src:"default"}}'
KEY_FLAG_OLD='function keybindingsEnabled(){return featureFlag("tengu_keybinding_customization_release",!1)}'
KEYMAP='export const defaultKeybindings=[{context:"Global",bindings:{"ctrl+c":"app:interrupt","ctrl+d":"app:exit"}},{context:"Transcript",bindings:{"ctrl+c":"app:interrupt"}},{context:"HistorySearch",bindings:{"ctrl+c":"app:interrupt"}}]'

root="$tmp/pkg"
fixture_make_package "$root" single-cjs '@cometix/claude-code' 2.1.224
fixture_add_module "$root" cli.js "#!/usr/bin/env node
$AUTO_GATE
$AUTO_DECISION
$AUTO_MODEL
$KEY_FLAG_OLD
${KEYMAP/export const/const}
module.exports={}
"
entry=$(fixture_entry "$root")
before=$(fixture_hash_sources "$root")

runtime_exec apply "$entry" auto-mode >/dev/null 2>&1 || fail 'auto-mode apply failed'
runtime_exec apply "$entry" keybindings >/dev/null 2>&1 || fail 'keybindings apply failed'
runtime_exec check "$entry" auto-mode >/dev/null 2>&1 || fail 'auto-mode post-apply check failed'
runtime_exec check "$entry" keybindings >/dev/null 2>&1 || fail 'keybindings post-apply check failed'
[[ "$(fixture_hash_sources "$root")" != "$before" ]] || fail 'apply did not change sources'

output=$(runtime_exec restore-all "$entry" 2>&1) || fail "restore-all failed: $output"
grep -Fxq 'RESTORED:all' <<<"$output" || fail "restore-all did not report RESTORED:all: $output"
fixture_assert_tree_equals "$before" "$(fixture_hash_sources "$root")"
output=$(runtime_exec check "$entry" auto-mode 2>&1) || fail "auto-mode post-restore check failed: $output"
grep -Fxq 'NEEDS_PATCH' <<<"$output" || fail "auto-mode not NEEDS_PATCH after restore-all: $output"
output=$(runtime_exec check "$entry" keybindings 2>&1) || fail "keybindings post-restore check failed: $output"
grep -Fxq 'NEEDS_PATCH' <<<"$output" || fail "keybindings not NEEDS_PATCH after restore-all: $output"

printf 'PASS: restore-all resets managed sources to baseline without reapply\n'
