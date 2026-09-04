#!/usr/bin/env bash
set -euo pipefail
# Restoring one patch must not abort when an UNRELATED patch's semantic target is
# absent in the layout. Real 2.1.224 single-CJS exposes applyConfigEnvironmentVariables
# as a standalone export-map function, not a class MethodDefinition, so context-limit's
# analyzer reports MISSING_TARGET. restorePatchFromBaseline re-analyzes every registered
# patch to discover which are retained; a missing target on a patch that was never
# applied must be treated as "skip, not retained" — not a hard failure that aborts the
# restore of the patch actually being removed.
#
# This fast synthetic reproduces that cascade without the real-package run: only
# auto-mode's anchors are present, so the other six patches (including context-limit)
# are MISSING_TARGET. Applying and restoring auto-mode must succeed end-to-end.

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

source "$ROOT/tests/lib/dual-layout-fixture.sh"
source "$ROOT/cc-patch-manager.sh"

AUTO_GATE='function modelEligible(e){let n=normalizeModel(e),r=currentProvider();if(!providerEnabled(r))return!1;if(n.includes("claude-3-")||n==="claude-opus-4-0"||n==="claude-sonnet-4-0")return!1;if(r!=="firstParty"&&n.includes("haiku"))return!1;return!0}'
AUTO_DECISION='function decide(ft,Ye,C){if(ft.unavailable){if(Ye)return log("Auto mode classifier unavailable for AskUserQuestion, falling back to the question dialog",{level:"warn"}),C;return log("Auto mode classifier unavailable, denying with retry guidance (fail closed)",{level:"warn"}),{behavior:"deny",decisionReason:{type:"classifier",classifier:"auto-mode",reason:"unavailable"},message:"retry"}}}'
AUTO_MODEL='function classifierModel(){let e=currentModel(),n=autoConfig(),r=selectModel(n?.modelByMainModel)??validateModel(n?.model);if(r)return{value:r,src:"gb"};if(probeState()!=="demoted"){let o=externalDefault(e);if(o)return{value:o,src:"default",externalDefault:!0}}return{value:fallbackModel(e),src:"default"}}'

root="$tmp/auto-only"
fixture_make_package "$root" single-cjs '@cometix/claude-code' 2.1.224
fixture_add_module "$root" cli.js "#!/usr/bin/env node
$AUTO_GATE
$AUTO_DECISION
$AUTO_MODEL
module.exports={}
"
entry=$(fixture_entry "$root")
before=$(fixture_hash_sources "$root")

# auto-mode applies; the other six patches (incl. context-limit) are MISSING_TARGET.
output=$(runtime_exec check "$entry" auto-mode 2>&1) || fail "auto-mode check failed: $output"
grep -Fxq 'NEEDS_PATCH' <<<"$output" || fail "auto-mode clean check did not report NEEDS_PATCH: $output"
runtime_exec apply "$entry" auto-mode >/dev/null 2>&1 || fail 'auto-mode apply failed'
output=$(runtime_exec check "$entry" auto-mode 2>&1) || fail "auto-mode patched check failed: $output"
grep -Fxq 'ALREADY_PATCHED' <<<"$output" || fail "auto-mode patched check did not report ALREADY_PATCHED: $output"

# The restore re-analyzes every registered patch; the six absent anchors (including
# context-limit) must be skipped, not abort the restore of auto-mode.
output=$(runtime_exec restore "$entry" auto-mode 2>&1) ||
  fail "auto-mode restore aborted on unrelated MISSING_TARGET: $output"
fixture_assert_tree_equals "$before" "$(fixture_hash_sources "$root")"
output=$(runtime_exec check "$entry" auto-mode 2>&1) || fail "auto-mode post-restore check failed: $output"
grep -Fxq 'NEEDS_PATCH' <<<"$output" || fail "auto-mode not NEEDS_PATCH after restore: $output"

printf 'PASS: restore tolerates unrelated missing-target patches\n'
