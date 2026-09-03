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

make_contract_package() {
  local destination="$1"
  fixture_make_package "$destination" split-esm '@cometix/anthropic-cc' 2.1.259
  fixture_add_module "$destination" chunks/alpha.js 'export const alpha="CC_BEFORE_ALPHA"'
  fixture_add_module "$destination" chunks/beta.js 'export const beta="CC_BEFORE_BETA"'
  fixture_add_module "$destination" cli.js '#!/usr/bin/env node
import "./chunks/alpha.js";import "./chunks/beta.js"'
}

root_link="$tmp/root-link"
root_link_outside="$tmp/root-link-outside"
make_contract_package "$root_link"
mkdir -p "$root_link_outside"
ln -s "$root_link_outside" "$root_link/.cc-patch-manager-baseline"
if CC_PATCH_TESTING=1 runtime_exec baseline "$(fixture_entry "$root_link")" __contract__ >/dev/null 2>&1; then
  fail 'symlink baseline root was accepted'
fi
[[ -z "$(find "$root_link_outside" -mindepth 1 -print -quit)" ]] || fail 'baseline root symlink wrote outside package'

parent_link="$tmp/parent-link"
parent_link_outside="$tmp/parent-link-outside"
make_contract_package "$parent_link"
mkdir -p "$parent_link/.cc-patch-manager-baseline/files" "$parent_link_outside"
ln -s "$parent_link_outside" "$parent_link/.cc-patch-manager-baseline/files/chunks"
if CC_PATCH_TESTING=1 runtime_exec baseline "$(fixture_entry "$parent_link")" __contract__ >/dev/null 2>&1; then
  fail 'symlink mirror parent was accepted'
fi
[[ -z "$(find "$parent_link_outside" -mindepth 1 -print -quit)" ]] || fail 'mirror parent symlink wrote outside package'

partial_baseline="$tmp/partial-baseline"
make_contract_package "$partial_baseline"
printf '\n// CC_CONTRACT_RESOURCE:../outside.bin\n' >>"$partial_baseline/cli.js"
partial_before=$(fixture_hash_tree "$partial_baseline")
if CC_PATCH_TESTING=1 runtime_exec baseline "$(fixture_entry "$partial_baseline")" __contract__ >/dev/null 2>&1; then
  fail 'out-of-root resource baseline was accepted'
fi
[[ "$(fixture_hash_tree "$partial_baseline")" == "$partial_before" ]] || fail 'failed baseline creation left partial package state'
[[ ! -e "$tmp/outside.bin" ]] || fail 'failed baseline creation wrote outside package'
sed -i '' '/CC_CONTRACT_RESOURCE/d' "$partial_baseline/cli.js"
CC_PATCH_TESTING=1 runtime_exec baseline "$(fixture_entry "$partial_baseline")" __contract__ >/dev/null 2>&1 || fail 'baseline creation was not retryable after validation failure'

interrupted_baseline="$tmp/interrupted-baseline"
make_contract_package "$interrupted_baseline"
interrupted_before=$(fixture_hash_tree "$interrupted_baseline")
if CC_PATCH_TESTING=1 CC_PATCH_FAIL_BASELINE_AFTER_MIRROR=1 runtime_exec baseline "$(fixture_entry "$interrupted_baseline")" __contract__ >/dev/null 2>&1; then
  fail 'baseline I/O failure injection did not interrupt publication'
fi
[[ "$(fixture_hash_tree "$interrupted_baseline")" == "$interrupted_before" ]] || fail 'interrupted baseline publication left partial package state'
CC_PATCH_TESTING=1 runtime_exec baseline "$(fixture_entry "$interrupted_baseline")" __contract__ >/dev/null 2>&1 || fail 'baseline creation was not retryable after interrupted publication'

package="$tmp/package"
make_contract_package "$package"

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
if (manifest.package.entryPath !== 'cli.js' || !/^[a-f0-9]{64}$/.test(manifest.package.entrySha256)) process.exit(3);
for (const relative of ['cli.js', 'chunks/alpha.js', 'chunks/beta.js']) {
  const item = manifest.files[relative];
  if (!item || item.existed !== true || !Number.isInteger(item.mode) || !item.mirror || !/^[a-f0-9]{64}$/.test(item.sha256)) process.exit(4);
  const mirror = path.join(root, '.cc-patch-manager-baseline', item.mirror);
  const actual = crypto.createHash('sha256').update(fs.readFileSync(mirror)).digest('hex');
  if (actual !== item.sha256) process.exit(5);
}
if (manifest.package.entrySha256 !== manifest.files[manifest.package.entryPath].sha256) process.exit(6);
NODE

absent_resource="$tmp/absent-resource"
make_contract_package "$absent_resource"
printf '\n// CC_CONTRACT_RESOURCE:vendor/cometix-asr/generated.bin\n' >>"$absent_resource/cli.js"
CC_PATCH_TESTING=1 runtime_exec baseline "$(fixture_entry "$absent_resource")" __contract__ >/dev/null
node - "$absent_resource/.cc-patch-manager-baseline/manifest.json" <<'NODE' || fail 'absent resource state was not recorded'
const manifest = require(process.argv[2]);
const item = manifest.files['vendor/cometix-asr/generated.bin'];
if (!item || item.type !== 'file' || item.existed !== false || item.sha256 !== null || item.mirror !== null) process.exit(1);
if (!manifest.createdDirectories.includes('vendor') || !manifest.createdDirectories.includes('vendor/cometix-asr')) process.exit(2);
NODE
[[ ! -e "$absent_resource/vendor/cometix-asr/generated.bin" ]] || fail 'baseline creation created an absent resource destination'
absent_resource_before=$(fixture_hash_tree "$absent_resource")
CC_PATCH_TESTING=1 runtime_exec baseline "$(fixture_entry "$absent_resource")" __contract__ >/dev/null 2>&1 || fail 'unchanged absent resource baseline was not idempotent'
[[ "$(fixture_hash_tree "$absent_resource")" == "$absent_resource_before" ]] || fail 'absent resource baseline recheck changed the package'

existing_resource="$tmp/existing-resource"
make_contract_package "$existing_resource"
fixture_add_module "$existing_resource" assets/model.bin 'original-resource'
printf '\n// CC_CONTRACT_RESOURCE:assets/model.bin\n' >>"$existing_resource/cli.js"
CC_PATCH_TESTING=1 runtime_exec baseline "$(fixture_entry "$existing_resource")" __contract__ >/dev/null
node - "$existing_resource/.cc-patch-manager-baseline/manifest.json" <<'NODE' || fail 'existing resource baseline was not mirrored'
const fs = require('fs');
const path = require('path');
const manifestPath = process.argv[2];
const manifest = require(manifestPath);
const item = manifest.files['assets/model.bin'];
if (!item || item.existed !== true || !item.mirror || !Number.isInteger(item.mode)) process.exit(1);
const mirror = path.join(path.dirname(manifestPath), item.mirror);
if (fs.readFileSync(mirror, 'utf8') !== 'original-resource\n') process.exit(2);
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

unknown_sentinel="$tmp/unknown-sentinel"
make_contract_package "$unknown_sentinel"
printf '\n// CC_UNKNOWN_PATCH\n' >>"$unknown_sentinel/chunks/alpha.js"
unknown_before=$(fixture_hash_tree "$unknown_sentinel")
if CC_PATCH_TESTING=1 runtime_exec baseline "$(fixture_entry "$unknown_sentinel")" __contract__ >/dev/null 2>&1; then
  fail 'unknown manager sentinel without a trusted baseline was accepted'
fi
[[ "$(fixture_hash_tree "$unknown_sentinel")" == "$unknown_before" ]] || fail 'unknown sentinel rejection changed the package'
[[ ! -e "$unknown_sentinel/.cc-patch-manager-baseline" ]] || fail 'unknown sentinel rejection left a baseline directory'

legacy_sentinel="$tmp/legacy-sentinel"
make_contract_package "$legacy_sentinel"
printf '\n// CC_DIALOG_FIX_CHANNEL_FACTORY\n' >>"$legacy_sentinel/chunks/alpha.js"
legacy_before=$(fixture_hash_tree "$legacy_sentinel")
if CC_PATCH_TESTING=1 runtime_exec baseline "$(fixture_entry "$legacy_sentinel")" __contract__ >/dev/null 2>&1; then
  fail 'legacy manager sentinel without a trusted baseline was accepted'
fi
[[ "$(fixture_hash_tree "$legacy_sentinel")" == "$legacy_before" ]] || fail 'legacy sentinel rejection changed the package'
[[ ! -e "$legacy_sentinel/.cc-patch-manager-baseline" ]] || fail 'legacy sentinel rejection left a baseline directory'

known_state="$tmp/known-state"
make_contract_package "$known_state"
CC_PATCH_TESTING=1 runtime_exec baseline "$(fixture_entry "$known_state")" __contract__ >/dev/null
sed -i '' 's/CC_BEFORE_ALPHA/CC_AFTER_ALPHA/' "$known_state/chunks/alpha.js"
sed -i '' 's/CC_BEFORE_BETA/CC_AFTER_BETA/' "$known_state/chunks/beta.js"
CC_PATCH_TESTING=1 runtime_exec baseline "$(fixture_entry "$known_state")" __contract__ >/dev/null || fail 'known analyzer state was not attributable to the baseline'

externally_modified="$tmp/externally-modified"
make_contract_package "$externally_modified"
CC_PATCH_TESTING=1 runtime_exec baseline "$(fixture_entry "$externally_modified")" __contract__ >/dev/null
printf '\n// external modification\n' >>"$externally_modified/chunks/alpha.js"
external_before=$(fixture_hash_tree "$externally_modified")
if CC_PATCH_TESTING=1 runtime_exec baseline "$(fixture_entry "$externally_modified")" __contract__ >/dev/null 2>&1; then
  fail 'externally modified managed file was accepted as attributable'
fi
[[ "$(fixture_hash_tree "$externally_modified")" == "$external_before" ]] || fail 'external modification rejection changed the package'

legacy="$tmp/legacy"
fixture_make_package "$legacy" single-cjs '@cometix/claude-code' 2.1.224
fixture_add_module "$legacy" cli.js '#!/usr/bin/env node
// Version: 2.1.224
const alpha="CC_BEFORE_ALPHA",beta="CC_BEFORE_BETA";module.exports={alpha,beta}'
cp "$(fixture_entry "$legacy")" "$(fixture_entry "$legacy").cc-patch-baseline"
sed -i '' 's/CC_BEFORE_ALPHA/CC_AFTER_ALPHA/;s/CC_BEFORE_BETA/CC_AFTER_BETA/' "$(fixture_entry "$legacy")"
CC_PATCH_TESTING=1 runtime_exec backup "$(fixture_entry "$legacy")" >/dev/null 2>&1 || fail 'compatible single-CJS legacy baseline was not migrated'
legacy_manifest="$legacy/.cc-patch-manager-baseline/manifest.json"
[[ -f "$legacy_manifest" ]] || fail 'legacy migration did not create a package manifest'
[[ -f "$(fixture_entry "$legacy").cc-patch-baseline" ]] || fail 'legacy migration removed the old baseline'
cmp -s "$(fixture_entry "$legacy").cc-patch-baseline" "$legacy/.cc-patch-manager-baseline/files/cli.js" || fail 'legacy migration did not preserve the original entry bytes'
CC_PATCH_TESTING=1 runtime_exec backup "$(fixture_entry "$legacy")" >/dev/null 2>&1 || fail 'legacy migration was not idempotent'

exact_legacy="$tmp/exact-legacy"
fixture_make_package "$exact_legacy" single-cjs '@cometix/claude-code' 2.1.224
cp "$(fixture_entry "$exact_legacy")" "$(fixture_entry "$exact_legacy").cc-patch-baseline"
CC_PATCH_TESTING=1 runtime_exec backup "$(fixture_entry "$exact_legacy")" >/dev/null 2>&1 || fail 'byte-identical headerless legacy baseline was not migrated'

stale_legacy="$tmp/stale-legacy"
fixture_make_package "$stale_legacy" single-cjs '@cometix/claude-code' 2.1.224
fixture_add_module "$stale_legacy" cli.js '#!/usr/bin/env node
// Version: 2.1.224
module.exports={current:true}'
fixture_add_module "$stale_legacy" cli.js.cc-patch-baseline '#!/usr/bin/env node
// Version: 2.1.223
module.exports={old:true}'
if CC_PATCH_TESTING=1 runtime_exec backup "$(fixture_entry "$stale_legacy")" >/dev/null 2>&1; then
  fail 'identity-mismatched legacy baseline was migrated'
fi
[[ ! -e "$stale_legacy/.cc-patch-manager-baseline" ]] || fail 'rejected legacy migration left package baseline state'
[[ -f "$(fixture_entry "$stale_legacy").cc-patch-baseline" ]] || fail 'rejected migration removed the legacy baseline'

split_legacy="$tmp/split-legacy"
make_contract_package "$split_legacy"
cp "$(fixture_entry "$split_legacy")" "$(fixture_entry "$split_legacy").cc-patch-baseline"
if CC_PATCH_TESTING=1 runtime_exec backup "$(fixture_entry "$split_legacy")" >/dev/null 2>&1; then
  fail 'split-ESM legacy single-file baseline was migrated'
fi
[[ ! -e "$split_legacy/.cc-patch-manager-baseline" ]] || fail 'split-ESM legacy rejection left package baseline state'

transaction="$tmp/transaction"
make_contract_package "$transaction"
fixture_add_module "$transaction" assets/model.bin 'voice-resource'
printf '\n// CC_CONTRACT_RESOURCE:assets/model.bin->vendor/cometix-asr/model.bin\n' >>"$transaction/cli.js"
CC_PATCH_TESTING=1 runtime_exec baseline "$(fixture_entry "$transaction")" __contract__ >/dev/null
for fail_after in 1 2 3; do
  transaction_before=$(fixture_hash_tree "$transaction")
  if CC_PATCH_TESTING=1 CC_PATCH_TEST_FAIL_AFTER="$fail_after" runtime_exec apply "$(fixture_entry "$transaction")" __contract__ >/dev/null 2>&1; then
    fail "transaction failure injection $fail_after did not interrupt apply"
  fi
  [[ "$(fixture_hash_tree "$transaction")" == "$transaction_before" ]] || fail "transaction failure $fail_after did not restore the package tree"
  [[ ! -e "$transaction/vendor/cometix-asr/model.bin" ]] || fail "transaction failure $fail_after left a copied resource"
  [[ -z "$(find "$transaction" -maxdepth 1 -name '.cc-patch-manager-transaction-*' -print -quit)" ]] || fail "transaction failure $fail_after left a transaction directory"
done
CC_PATCH_TESTING=1 runtime_exec apply "$(fixture_entry "$transaction")" __contract__ >/dev/null 2>&1 || fail 'multi-file transaction did not commit'
grep -Fq 'CC_AFTER_ALPHA' "$transaction/chunks/alpha.js" || fail 'transaction did not commit alpha replacement'
grep -Fq 'CC_AFTER_BETA' "$transaction/chunks/beta.js" || fail 'transaction did not commit beta replacement'
cmp -s "$transaction/assets/model.bin" "$transaction/vendor/cometix-asr/model.bin" || fail 'transaction did not commit resource copy'

printf 'corrupt\n' >>"$package/.cc-patch-manager-baseline/files/chunks/alpha.js"
if CC_PATCH_TESTING=1 runtime_exec baseline "$(fixture_entry "$package")" __contract__ >/dev/null 2>&1; then
  fail 'corrupt baseline mirror was accepted'
fi

printf 'PASS: package baseline manifest rejects stale and untrusted state\n'
