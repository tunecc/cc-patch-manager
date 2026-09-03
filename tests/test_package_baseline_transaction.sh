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

package="$tmp/package"
fixture_make_package "$package" split-esm '@cometix/anthropic-cc' 2.1.259
fixture_add_module "$package" chunks/alpha.js 'export const alpha="CC_BEFORE_ALPHA"'
fixture_add_module "$package" chunks/beta.js 'export const beta="CC_BEFORE_BETA"'
fixture_add_module "$package" cli.js '#!/usr/bin/env node
import "./chunks/alpha.js";import "./chunks/beta.js"'

set +e
baseline_output=$(CC_PATCH_TESTING=1 runtime_exec baseline "$(fixture_entry "$package")" __contract__ 2>&1)
baseline_status=$?
set -e
[[ "$baseline_status" -eq 0 ]] || fail "baseline creation failed: $baseline_output"
manifest="$package/.cc-patch-manager-baseline/manifest.json"
[[ -f "$manifest" ]] || fail 'baseline manifest was not created'

node - "$manifest" <<'NODE' || fail 'baseline manifest contract is incomplete'
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const manifestPath = process.argv[2];
const root = path.dirname(path.dirname(manifestPath));
const manifest = JSON.parse(fs.readFileSync(manifestPath, 'utf8'));
if (manifest.schemaVersion !== 1) process.exit(1);
if (manifest.package.name !== '@cometix/anthropic-cc' || manifest.package.version !== '2.1.259' || manifest.package.layout !== 'split-esm') process.exit(2);
for (const relative of ['chunks/alpha.js', 'chunks/beta.js']) {
  const item = manifest.files[relative];
  if (!item || item.existed !== true || !Number.isInteger(item.mode) || !item.mirror || !/^[a-f0-9]{64}$/.test(item.sha256)) process.exit(3);
  const mirror = path.join(root, '.cc-patch-manager-baseline', item.mirror);
  const actual = crypto.createHash('sha256').update(fs.readFileSync(mirror)).digest('hex');
  if (actual !== item.sha256) process.exit(4);
}
NODE

stale="$tmp/stale"
cp -R "$package" "$stale"
printf '{"name":"@cometix/anthropic-cc","version":"2.1.260"}\n' >"$stale/package.json"
if CC_PATCH_TESTING=1 runtime_exec baseline "$(fixture_entry "$stale")" __contract__ >/dev/null 2>&1; then
  fail 'stale package identity was accepted'
fi

fresh="$tmp/fresh"
fixture_make_package "$fresh" split-esm '@cometix/anthropic-cc' 2.1.259
fixture_add_module "$fresh" chunks/alpha.js 'export const alpha="CC_AFTER_ALPHA"'
fixture_add_module "$fresh" chunks/beta.js 'export const beta="CC_AFTER_BETA"'
if CC_PATCH_TESTING=1 runtime_exec baseline "$(fixture_entry "$fresh")" __contract__ >/dev/null 2>&1; then
  fail 'already-patched package without a trusted baseline was accepted'
fi

printf 'corrupt\n' >>"$package/.cc-patch-manager-baseline/files/chunks/alpha.js"
if CC_PATCH_TESTING=1 runtime_exec baseline "$(fixture_entry "$package")" __contract__ >/dev/null 2>&1; then
  fail 'corrupt baseline mirror was accepted'
fi

printf 'PASS: package baseline manifest rejects stale and untrusted state\n'
