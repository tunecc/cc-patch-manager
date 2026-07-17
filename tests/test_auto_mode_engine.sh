#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

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

printf 'PASS: auto-mode retains legacy and flat model-gate detectors\n'
