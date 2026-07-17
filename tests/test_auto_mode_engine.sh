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
  "bodySrc.includes('anthropicAws')"
do
  grep -Fq "$marker" "$engine" || {
    printf 'FAIL: auto-mode engine lost marker: %s\n' "$marker" >&2
    exit 1
  }
done

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

assert_detector() {
  local fixture="$1" expected_marker="$2" generated output ec
  generated=$(write_patch_script auto-mode)
  set +e
  output=$(node "$generated" "$ACORN_PATH" "$fixture" --check 2>&1)
  ec=$?
  set -e
  rm -f "$generated"

  [[ "$ec" -eq 1 ]] || fail "detector check must exit 1 for a patchable fixture, got $ec"
  [[ "$output" == *"$expected_marker"* ]] || fail "detector output missing: $expected_marker"
  [[ "$output" == *"NEEDS_PATCH"* ]] || fail "detector check must report NEEDS_PATCH"
}

assert_detector "$tmp/legacy.js" "FOUND:using legacy nested-block model eligibility detector"
assert_detector "$tmp/flat.js" "FOUND:using flat TBe-style model eligibility detector"

printf 'PASS: auto-mode retains legacy and flat model-gate detectors\n'
