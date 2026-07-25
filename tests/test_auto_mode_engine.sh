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

printf 'PASS: auto-mode retains legacy and flat model-gate detectors\n'
