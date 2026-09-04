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

engine=$(write_patch_script auto-mode)
mv "$engine" "$tmp/auto-mode-engine.js"
engine="$tmp/auto-mode-engine.js"

for marker in \
  'oQqCandidatesLegacy' \
  'oQqCandidatesFlat' \
  'rankFlat' \
  "bodySrc.includes('claude-3-')" \
  "bodySrc.includes('firstParty')" \
  'anthropicAws is optional'
do
  grep -Fq "$marker" "$engine" || {
    printf 'FAIL: auto-mode engine lost marker: %s\n' "$marker" >&2
    exit 1
  }
done

# anthropicAws must no longer be a hard filter (2.1.213 w6e lacks it).
if grep -Fq "if (!bodySrc.includes('anthropicAws')) return false;" "$engine"; then
  fail "flat detector still hard-requires anthropicAws"
fi

grep -Fq 'if (oQqCandidatesFlat.length > 0)' "$engine"
grep -Fq 'else if (oQqCandidatesLegacy.length > 0)' "$engine"
grep -Fq 'FOUND:using flat TBe-style model eligibility detector' "$engine"
grep -Fq 'FOUND:using legacy nested-block model eligibility detector' "$engine"

ACORN_PATH="$tmp/acorn.js"
ensure_acorn

cat >"$tmp/legacy.js" <<'JS'
function legacyGate(e){{if(e===1)return!1;if(e===2)return!1;if(e===3)return!1}return!0}
JS

cat >"$tmp/flat.js" <<'JS'
function flatGate(e){let provider="firstParty",aws="anthropicAws",model=e;if(!provider)return!1;if(model.includes("claude-3-")||model.includes("claude-opus-4-0"))return!1;return!0}
JS

# Claude Code 2.1.213+: still firstParty + denylist, but no anthropicAws token in body.
# Mirrors w6e() which drives supportsAutoMode / verifyAutoModeGateAccess.modelSupported.
cat >"$tmp/flat-no-aws.js" <<'JS'
function w6e(e){let t=so(e),r=En();if(!D7t(r))return!1;if(t.includes("claude-3-")||t==="claude-opus-4-0"||t==="claude-opus-4-1"||t==="claude-opus-4-5"||t==="claude-sonnet-4-0"||t==="claude-sonnet-4-5"||t==="claude-haiku-4-5")return!1;if(r!=="firstParty"&&!d6(r)&&(t==="claude-opus-4-6"||t==="claude-sonnet-4-6"||t.includes("haiku")))return!1;return!0}
JS

assert_detector() {
  local fixture="$1" expected_marker="$2" generated output ec
  generated=$(write_patch_script auto-mode)
  set +e
  output=$(node "$generated" "$ACORN_PATH" "$fixture" --check 2>&1)
  ec=$?
  set -e
  rm -f "$generated"

  [[ "$ec" -eq 1 ]] || fail "detector check must exit 1 for a patchable fixture, got $ec (output: $output)"
  [[ "$output" == *"$expected_marker"* ]] || fail "detector output missing: $expected_marker (output: $output)"
  [[ "$output" == *"NEEDS_PATCH"* ]] || fail "detector check must report NEEDS_PATCH (output: $output)"
}

assert_detector "$tmp/legacy.js" "FOUND:using legacy nested-block model eligibility detector"
assert_detector "$tmp/flat.js" "FOUND:using flat TBe-style model eligibility detector"
assert_detector "$tmp/flat-no-aws.js" "FOUND:using flat TBe-style model eligibility detector"

# Claude Code 2.1.224 emits two "classifier unavailable" anchors, but only the
# "denying with retry guidance" path is fail-closed (behavior:"deny"). The sibling
# "falling back to the question dialog" path returns the question-dialog object with
# no behavior property. The engine must patch only the deny object — patching the
# wrong comma (the old +300-char heuristic reached the NEXT function's deny objects)
# corrupted the file. This locks the structural ReturnStatement/SequenceExpression
# decision-object lookup.
cat >"$tmp/failclosed.js" <<'JS'
function so(e){return e}
function En(){return "firstParty"}
function D7t(r){return true}
function w6e(e){let t=so(e),r=En();if(!D7t(r))return!1;if(t.includes("claude-3-")||t==="claude-opus-4-0"||t==="claude-sonnet-4-0")return!1;if(r!=="firstParty")return!1;return!0}
function E(m,o){return m}
function L(n,o){return n}
function run(U,H,a){
  if(U.unavailable){
    if(H)return E("Auto mode classifier unavailable for AskUserQuestion, falling back to the question dialog",{level:"warn"}),L("tengu_auto_mode_fallback_to_ask",{reason:"x"}),a;
    return E("Auto mode classifier unavailable, denying with retry guidance (fail closed)",{level:"warn"}),{behavior:"deny",decisionReason:{type:"classifier",classifier:"auto-mode",reason:"l1t"},message:"m"}
  }
  return w6e("model")
}
JS

generated=$(write_patch_script auto-mode)
set +e
CC_PATCH_SKIP_BACKUP=1 CC_PATCH_BASELINE="$tmp/failclosed.js.cc-patch-baseline" \
  node "$generated" "$ACORN_PATH" "$tmp/failclosed.js" >/tmp/failclosed-out.txt 2>&1
ec=$?
set -e
rm -f "$generated"

[[ $ec -eq 0 ]] || fail "fail-closed apply must exit 0 (output: $(cat /tmp/failclosed-out.txt))"
[[ "$(grep -c 'behavior:"deny"' "$tmp/failclosed.js")" -eq 0 ]] || \
  fail "fail-closed apply must convert the deny object to ask"
grep -Fq 'behavior:"ask"' "$tmp/failclosed.js" || fail "fail-closed apply must insert ask"
grep -Fq 'falling back to the question dialog' "$tmp/failclosed.js" || \
  fail "fail-closed apply must preserve the fall-back path"
node - "$ACORN_PATH" "$tmp/failclosed.js" <<'NODE' || fail "fail-closed patched file must parse"
const fs = require('fs');
const acorn = require(process.argv[2]);
const code = fs.readFileSync(process.argv[3], 'utf8');
acorn.parse(code, { ecmaVersion: 'latest', sourceType: 'module' });
NODE

# Recheck: model gate + deny both handled, classifier model absent → ALREADY_PATCHED.
generated=$(write_patch_script auto-mode)
set +e
node "$generated" "$ACORN_PATH" "$tmp/failclosed.js" --check >/tmp/failclosed-recheck.txt 2>&1
ec=$?
set -e
rm -f "$generated"
[[ "$(cat /tmp/failclosed-recheck.txt)" == *"ALREADY_PATCHED"* ]] || \
  fail "fail-closed recheck must report ALREADY_PATCHED (output: $(cat /tmp/failclosed-recheck.txt))"

# cruce 2.1.259 moved classifier selection to a richer function that supports
# modelByMainModel and returns {value,src}. The environment override must retain
# that return shape so downstream callers can continue reading `.value`.
cat >"$tmp/modern-classifier.js" <<'JS'
function normalizeModel(e){return e}
function currentProvider(){return "firstParty"}
function providerEnabled(){return true}
function modelEligible(e){let n=normalizeModel(e),r=currentProvider();if(!providerEnabled(r))return!1;if(n.includes("claude-3-")||n==="claude-opus-4-0"||n==="claude-sonnet-4-0")return!1;if(r!=="firstParty"&&n.includes("haiku"))return!1;return!0}
function log(m,o){return m}
function decide(ft,Ye,C){if(ft.unavailable){if(Ye)return log("Auto mode classifier unavailable for AskUserQuestion, falling back to the question dialog",{level:"warn"}),C;return log("Auto mode classifier unavailable, denying with retry guidance (fail closed)",{level:"warn"}),{behavior:"deny",decisionReason:{type:"classifier",classifier:"auto-mode",reason:"unavailable"},message:"retry"}}}
function currentModel(){return "main"}
function autoConfig(){return {modelByMainModel:{},model:"classifier"}}
function selectModel(){return undefined}
function validateModel(e){return e}
function probeState(){return "demoted"}
function externalDefault(){return undefined}
function fallbackModel(e){return e}
function classifierModel(){let e=currentModel(),n=autoConfig(),r=selectModel(n?.modelByMainModel)??validateModel(n?.model);if(r)return{value:r,src:"gb"};if(probeState()!=="demoted"){let o=externalDefault(e);if(o)return{value:o,src:"default",externalDefault:!0}}return{value:fallbackModel(e),src:"default"}}
JS

generated=$(write_patch_script auto-mode)
CC_PATCH_SKIP_BACKUP=1 CC_PATCH_BASELINE="$tmp/modern-classifier.js.cc-patch-baseline" \
  node "$generated" "$ACORN_PATH" "$tmp/modern-classifier.js" >/tmp/modern-classifier-out.txt 2>&1 || \
  fail "modern classifier apply failed: $(cat /tmp/modern-classifier-out.txt)"
rm -f "$generated"
grep -Fq 'if(process.env.CLAUDE_CLASSIFIER_MODEL)return{value:process.env.CLAUDE_CLASSIFIER_MODEL,src:"env"}' \
  "$tmp/modern-classifier.js" || fail 'modern classifier selector did not gain a shape-preserving env override'

printf 'PASS: auto-mode retains legacy and flat model-gate detectors\n'
printf 'PASS: auto-mode patches only the fail-closed deny path, never the fall-back\n'
printf 'PASS: auto-mode supports the cruce modelByMainModel classifier selector\n'
