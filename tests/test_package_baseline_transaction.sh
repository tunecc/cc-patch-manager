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

expanded_baseline="$tmp/expanded-baseline"
make_contract_package "$expanded_baseline"
fixture_add_module "$expanded_baseline" assets/source.bin 'new-resource'
fixture_add_module "$expanded_baseline" assets/existing.bin 'old-resource'
printf '\n// CC_CONTRACT_RESOURCE:assets/source.bin->assets/existing.bin\n' >>"$expanded_baseline/cli.js"
CC_PATCH_TESTING=1 runtime_exec baseline "$(fixture_entry "$expanded_baseline")" __contract__ >/dev/null
node - "$expanded_baseline" <<'NODE'
const fs = require('fs');
const path = require('path');
const root = process.argv[2];
const manifestPath = path.join(root, '.cc-patch-manager-baseline', 'manifest.json');
const manifest = JSON.parse(fs.readFileSync(manifestPath, 'utf8'));
const item = manifest.files['assets/existing.bin'];
fs.unlinkSync(path.join(root, '.cc-patch-manager-baseline', item.mirror));
delete manifest.files['assets/existing.bin'];
fs.writeFileSync(manifestPath, JSON.stringify(manifest, null, 2) + '\n');
NODE
expanded_before=$(fixture_hash_tree "$expanded_baseline")
if CC_PATCH_TESTING=1 CC_PATCH_FAIL_BASELINE_AFTER_MIRROR=1 runtime_exec apply "$(fixture_entry "$expanded_baseline")" __contract__ >/dev/null 2>&1; then
  fail 'existing baseline expansion failure injection did not interrupt apply'
fi
[[ "$(fixture_hash_tree "$expanded_baseline")" == "$expanded_before" ]] || fail 'failed existing baseline expansion changed package state'
if CC_PATCH_TESTING=1 CC_PATCH_TEST_LEAVE_BASELINE_ORPHAN=1 runtime_exec apply "$(fixture_entry "$expanded_baseline")" __contract__ >/dev/null 2>&1; then
  fail 'baseline orphan crash injection did not interrupt manifest publication'
fi
[[ -f "$expanded_baseline/.cc-patch-manager-baseline/files/assets/existing.bin" ]] || fail 'baseline orphan crash did not leave the published mirror fixture'
node - "$expanded_baseline/.cc-patch-manager-baseline/manifest.json" <<'NODE' || fail 'baseline orphan crash published the manifest too early'
const manifest = require(process.argv[2]);
if (manifest.files['assets/existing.bin']) process.exit(1);
NODE
CC_PATCH_TESTING=1 runtime_exec apply "$(fixture_entry "$expanded_baseline")" __contract__ >/dev/null 2>&1 || fail 'apply was not retryable after baseline expansion failure'
cmp -s "$expanded_baseline/assets/source.bin" "$expanded_baseline/assets/existing.bin" || fail 'resource copy did not commit after baseline expansion retry'
[[ -z "$(find "$expanded_baseline" -maxdepth 1 -name '.cc-patch-manager-baseline.stage-*' -print -quit)" ]] || fail 'baseline expansion retry left staging state'

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
chmod 0666 "$existing_resource/assets/model.bin"
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
if (item.mode !== 0o666 || (fs.statSync(mirror).mode & 0o777) !== item.mode) process.exit(3);
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

rename_failure="$tmp/rename-failure"
make_contract_package "$rename_failure"
CC_PATCH_TESTING=1 runtime_exec baseline "$(fixture_entry "$rename_failure")" __contract__ >/dev/null
rename_before=$(fixture_hash_tree "$rename_failure")
if CC_PATCH_TESTING=1 CC_PATCH_TEST_FAIL_AFTER_RENAME=1 runtime_exec apply "$(fixture_entry "$rename_failure")" __contract__ >/dev/null 2>&1; then
  fail 'post-rename failure injection did not interrupt apply'
fi
[[ "$(fixture_hash_tree "$rename_failure")" == "$rename_before" ]] || fail 'post-rename failure did not restore the package tree'

snapshot_race="$tmp/snapshot-race"
make_contract_package "$snapshot_race"
CC_PATCH_TESTING=1 runtime_exec baseline "$(fixture_entry "$snapshot_race")" __contract__ >/dev/null
if CC_PATCH_TESTING=1 CC_PATCH_TEST_MUTATE_AFTER_SNAPSHOT=chunks/alpha.js runtime_exec apply "$(fixture_entry "$snapshot_race")" __contract__ >/dev/null 2>&1; then
  fail 'snapshot-race failure injection did not interrupt apply'
fi
grep -Fq 'CC_TEST_EXTERNAL_MUTATION' "$snapshot_race/chunks/alpha.js" || fail 'rollback overwrote an external change made after the snapshot'
grep -Fq 'CC_BEFORE_BETA' "$snapshot_race/chunks/beta.js" || fail 'snapshot-race apply changed an untouched destination'
[[ -n "$(find "$snapshot_race" -maxdepth 1 -name '.cc-patch-manager-transaction-*' -print -quit)" ]] || fail 'snapshot-race failure removed the recovery journal'

rename_race="$tmp/rename-race"
make_contract_package "$rename_race"
CC_PATCH_TESTING=1 runtime_exec baseline "$(fixture_entry "$rename_race")" __contract__ >/dev/null
if CC_PATCH_TESTING=1 CC_PATCH_TEST_MUTATE_BEFORE_RENAME=chunks/alpha.js runtime_exec apply "$(fixture_entry "$rename_race")" __contract__ >/dev/null 2>&1; then
  fail 'apply accepted a destination change between snapshot and rename'
fi
grep -Fq 'CC_TEST_EXTERNAL_MUTATION' "$rename_race/chunks/alpha.js" || fail 'rename-race apply overwrote the external change'
grep -Fq 'CC_BEFORE_BETA' "$rename_race/chunks/beta.js" || fail 'rename-race apply changed an untouched destination'
[[ -n "$(find "$rename_race" -maxdepth 1 -name '.cc-patch-manager-transaction-*' -print -quit)" ]] || fail 'rename-race failure removed the recovery journal'

source_race="$tmp/source-race"
make_contract_package "$source_race"
CC_PATCH_TESTING=1 runtime_exec baseline "$(fixture_entry "$source_race")" __contract__ >/dev/null
if CC_PATCH_TESTING=1 CC_PATCH_TEST_MUTATE_AFTER_ANALYSIS=chunks/alpha.js runtime_exec apply "$(fixture_entry "$source_race")" __contract__ >/dev/null 2>&1; then
  fail 'apply accepted a source change after analysis'
fi
grep -Fq 'CC_TEST_EXTERNAL_MUTATION' "$source_race/chunks/alpha.js" || fail 'source-race fixture did not perform the external mutation'
grep -Fq 'CC_BEFORE_ALPHA' "$source_race/chunks/alpha.js" || fail 'source-race apply overwrote externally changed alpha'
grep -Fq 'CC_BEFORE_BETA' "$source_race/chunks/beta.js" || fail 'source-race apply changed beta'
[[ -z "$(find "$source_race" -maxdepth 1 -name '.cc-patch-manager-transaction-*' -print -quit)" ]] || fail 'source-race rejection left a transaction directory'

resource_source_race="$tmp/resource-source-race"
make_contract_package "$resource_source_race"
fixture_add_module "$resource_source_race" assets/model.bin 'voice-resource'
printf '\n// CC_CONTRACT_RESOURCE:assets/model.bin->assets/copied.bin\n' >>"$resource_source_race/cli.js"
CC_PATCH_TESTING=1 runtime_exec baseline "$(fixture_entry "$resource_source_race")" __contract__ >/dev/null
if CC_PATCH_TESTING=1 CC_PATCH_TEST_MUTATE_AFTER_ANALYSIS=assets/model.bin runtime_exec apply "$(fixture_entry "$resource_source_race")" __contract__ >/dev/null 2>&1; then
  fail 'apply accepted a resource source content change after analysis'
fi
grep -Fq 'CC_TEST_EXTERNAL_MUTATION' "$resource_source_race/assets/model.bin" || fail 'resource-source-race fixture did not perform the external mutation'
[[ ! -e "$resource_source_race/assets/copied.bin" ]] || fail 'resource-source-race apply copied stale bytes'
[[ -z "$(find "$resource_source_race" -maxdepth 1 -name '.cc-patch-manager-transaction-*' -print -quit)" ]] || fail 'resource-source-race rejection left a transaction directory'

resource_source_snapshot_race="$tmp/resource-source-snapshot-race"
make_contract_package "$resource_source_snapshot_race"
fixture_add_module "$resource_source_snapshot_race" assets/model.bin 'voice-resource'
printf '\n// CC_CONTRACT_RESOURCE:assets/model.bin->assets/copied.bin\n' >>"$resource_source_snapshot_race/cli.js"
CC_PATCH_TESTING=1 runtime_exec baseline "$(fixture_entry "$resource_source_snapshot_race")" __contract__ >/dev/null
if CC_PATCH_TESTING=1 CC_PATCH_TEST_MUTATE_AFTER_PREFLIGHT=assets/model.bin runtime_exec apply "$(fixture_entry "$resource_source_snapshot_race")" __contract__ >/dev/null 2>&1; then
  fail 'apply accepted a resource source change between preflight and snapshot'
fi
grep -Fq 'CC_TEST_EXTERNAL_MUTATION' "$resource_source_snapshot_race/assets/model.bin" || fail 'resource-source-snapshot-race fixture did not perform the external mutation'
[[ ! -e "$resource_source_snapshot_race/assets/copied.bin" ]] || fail 'resource-source-snapshot-race apply copied stale bytes'
[[ -z "$(find "$resource_source_snapshot_race" -maxdepth 1 -name '.cc-patch-manager-transaction-*' -print -quit)" ]] || fail 'resource-source-snapshot-race rejection left a transaction directory'

resource_source_mode_race="$tmp/resource-source-mode-race"
make_contract_package "$resource_source_mode_race"
fixture_add_module "$resource_source_mode_race" assets/model.bin 'voice-resource'
printf '\n// CC_CONTRACT_RESOURCE:assets/model.bin->assets/copied.bin\n' >>"$resource_source_mode_race/cli.js"
CC_PATCH_TESTING=1 runtime_exec baseline "$(fixture_entry "$resource_source_mode_race")" __contract__ >/dev/null
if CC_PATCH_TESTING=1 CC_PATCH_TEST_CHMOD_AFTER_ANALYSIS=assets/model.bin runtime_exec apply "$(fixture_entry "$resource_source_mode_race")" __contract__ >/dev/null 2>&1; then
  fail 'apply accepted a resource source mode change after analysis'
fi
[[ "$(stat -f '%Lp' "$resource_source_mode_race/assets/model.bin")" == '600' ]] || fail 'resource-source-mode-race fixture did not change the source mode'
[[ ! -e "$resource_source_mode_race/assets/copied.bin" ]] || fail 'resource-source-mode-race apply copied stale metadata'
[[ -z "$(find "$resource_source_mode_race" -maxdepth 1 -name '.cc-patch-manager-transaction-*' -print -quit)" ]] || fail 'resource-source-mode-race rejection left a transaction directory'

resource_destination_race="$tmp/resource-destination-race"
make_contract_package "$resource_destination_race"
fixture_add_module "$resource_destination_race" assets/source.bin 'new-resource'
fixture_add_module "$resource_destination_race" assets/destination.bin 'original-destination'
printf '\n// CC_CONTRACT_RESOURCE:assets/source.bin->assets/destination.bin\n' >>"$resource_destination_race/cli.js"
CC_PATCH_TESTING=1 runtime_exec baseline "$(fixture_entry "$resource_destination_race")" __contract__ >/dev/null
if CC_PATCH_TESTING=1 CC_PATCH_TEST_MUTATE_AFTER_ANALYSIS=assets/destination.bin runtime_exec apply "$(fixture_entry "$resource_destination_race")" __contract__ >/dev/null 2>&1; then
  fail 'apply accepted a resource destination content change after analysis'
fi
grep -Fq 'CC_TEST_EXTERNAL_MUTATION' "$resource_destination_race/assets/destination.bin" || fail 'resource-destination-race apply overwrote the external change'
grep -Fq 'original-destination' "$resource_destination_race/assets/destination.bin" || fail 'resource-destination-race lost the original destination bytes'
[[ -z "$(find "$resource_destination_race" -maxdepth 1 -name '.cc-patch-manager-transaction-*' -print -quit)" ]] || fail 'resource-destination-race rejection left a transaction directory'

resource_destination_snapshot_race="$tmp/resource-destination-snapshot-race"
make_contract_package "$resource_destination_snapshot_race"
fixture_add_module "$resource_destination_snapshot_race" assets/source.bin 'new-resource'
fixture_add_module "$resource_destination_snapshot_race" assets/destination.bin 'original-destination'
printf '\n// CC_CONTRACT_RESOURCE:assets/source.bin->assets/destination.bin\n' >>"$resource_destination_snapshot_race/cli.js"
CC_PATCH_TESTING=1 runtime_exec baseline "$(fixture_entry "$resource_destination_snapshot_race")" __contract__ >/dev/null
if CC_PATCH_TESTING=1 CC_PATCH_TEST_MUTATE_AFTER_PREFLIGHT=assets/destination.bin runtime_exec apply "$(fixture_entry "$resource_destination_snapshot_race")" __contract__ >/dev/null 2>&1; then
  fail 'apply accepted a resource destination change between preflight and snapshot'
fi
grep -Fq 'CC_TEST_EXTERNAL_MUTATION' "$resource_destination_snapshot_race/assets/destination.bin" || fail 'resource-destination-snapshot-race apply overwrote the external change'
grep -Fq 'original-destination' "$resource_destination_snapshot_race/assets/destination.bin" || fail 'resource-destination-snapshot-race lost the original bytes'
[[ -z "$(find "$resource_destination_snapshot_race" -maxdepth 1 -name '.cc-patch-manager-transaction-*' -print -quit)" ]] || fail 'resource-destination-snapshot-race rejection left a transaction directory'

resource_destination_created="$tmp/resource-destination-created"
make_contract_package "$resource_destination_created"
fixture_add_module "$resource_destination_created" assets/source.bin 'new-resource'
printf '\n// CC_CONTRACT_RESOURCE:assets/source.bin->assets/destination.bin\n' >>"$resource_destination_created/cli.js"
CC_PATCH_TESTING=1 runtime_exec baseline "$(fixture_entry "$resource_destination_created")" __contract__ >/dev/null
if CC_PATCH_TESTING=1 CC_PATCH_TEST_MUTATE_AFTER_ANALYSIS=assets/destination.bin runtime_exec apply "$(fixture_entry "$resource_destination_created")" __contract__ >/dev/null 2>&1; then
  fail 'apply accepted a resource destination created after analysis'
fi
grep -Fq 'CC_TEST_EXTERNAL_MUTATION' "$resource_destination_created/assets/destination.bin" || fail 'resource destination creation was overwritten'
[[ -z "$(find "$resource_destination_created" -maxdepth 1 -name '.cc-patch-manager-transaction-*' -print -quit)" ]] || fail 'resource-destination-created rejection left a transaction directory'

resource_destination_mode_race="$tmp/resource-destination-mode-race"
make_contract_package "$resource_destination_mode_race"
fixture_add_module "$resource_destination_mode_race" assets/source.bin 'new-resource'
fixture_add_module "$resource_destination_mode_race" assets/destination.bin 'original-destination'
printf '\n// CC_CONTRACT_RESOURCE:assets/source.bin->assets/destination.bin\n' >>"$resource_destination_mode_race/cli.js"
CC_PATCH_TESTING=1 runtime_exec baseline "$(fixture_entry "$resource_destination_mode_race")" __contract__ >/dev/null
if CC_PATCH_TESTING=1 CC_PATCH_TEST_CHMOD_AFTER_ANALYSIS=assets/destination.bin runtime_exec apply "$(fixture_entry "$resource_destination_mode_race")" __contract__ >/dev/null 2>&1; then
  fail 'apply accepted a resource destination mode change after analysis'
fi
[[ "$(stat -f '%Lp' "$resource_destination_mode_race/assets/destination.bin")" == '600' ]] || fail 'resource-destination-mode-race fixture did not change the destination mode'
grep -Fq 'original-destination' "$resource_destination_mode_race/assets/destination.bin" || fail 'resource-destination-mode-race apply overwrote the destination'
[[ -z "$(find "$resource_destination_mode_race" -maxdepth 1 -name '.cc-patch-manager-transaction-*' -print -quit)" ]] || fail 'resource-destination-mode-race rejection left a transaction directory'

CC_PATCH_TESTING=1 runtime_exec apply "$(fixture_entry "$transaction")" __contract__ >/dev/null 2>&1 || fail 'multi-file transaction did not commit'
grep -Fq 'CC_AFTER_ALPHA' "$transaction/chunks/alpha.js" || fail 'transaction did not commit alpha replacement'
grep -Fq 'CC_AFTER_BETA' "$transaction/chunks/beta.js" || fail 'transaction did not commit beta replacement'
cmp -s "$transaction/assets/model.bin" "$transaction/vendor/cometix-asr/model.bin" || fail 'transaction did not commit resource copy'

recovery_race="$tmp/recovery-race"
make_contract_package "$recovery_race"
CC_PATCH_TESTING=1 runtime_exec baseline "$(fixture_entry "$recovery_race")" __contract__ >/dev/null
if CC_PATCH_TESTING=1 CC_PATCH_TEST_LEAVE_TRANSACTION=1 runtime_exec apply "$(fixture_entry "$recovery_race")" __contract__ >/dev/null 2>&1; then
  fail 'recovery-race setup did not leave a prepared transaction'
fi
if CC_PATCH_TESTING=1 CC_PATCH_TEST_MUTATE_AFTER_RECOVERY_CLASSIFICATION=chunks/alpha.js runtime_exec apply "$(fixture_entry "$recovery_race")" __contract__ >/dev/null 2>&1; then
  fail 'recovery-race invocation unexpectedly continued'
fi
grep -Fq 'CC_TEST_EXTERNAL_MUTATION' "$recovery_race/chunks/alpha.js" || fail 'recovery overwrote an external change made after classification'
[[ -n "$(find "$recovery_race" -maxdepth 1 -name '.cc-patch-manager-transaction-*' -print -quit)" ]] || fail 'recovery-race failure removed the journal'

crash_recovery="$tmp/crash-recovery"
make_contract_package "$crash_recovery"
CC_PATCH_TESTING=1 runtime_exec baseline "$(fixture_entry "$crash_recovery")" __contract__ >/dev/null
crash_before=$(fixture_hash_tree "$crash_recovery")
if CC_PATCH_TESTING=1 CC_PATCH_TEST_LEAVE_TRANSACTION=1 runtime_exec apply "$(fixture_entry "$crash_recovery")" __contract__ >/dev/null 2>&1; then
  fail 'crash injection did not interrupt the transaction'
fi
[[ "$(fixture_hash_tree "$crash_recovery")" != "$crash_before" ]] || fail 'crash injection did not leave an interrupted state to recover'
[[ -n "$(find "$crash_recovery" -maxdepth 1 -name '.cc-patch-manager-transaction-*' -print -quit)" ]] || fail 'crash injection did not leave a recovery journal'
partial_crash_hash=$(fixture_hash_tree "$crash_recovery")
if CC_PATCH_TESTING=1 runtime_exec check "$(fixture_entry "$crash_recovery")" __contract__ >/dev/null 2>&1; then
  fail 'check reported patch state from an interrupted transaction tree'
fi
[[ "$(fixture_hash_tree "$crash_recovery")" == "$partial_crash_hash" ]] || fail 'read-only check mutated an interrupted transaction'
[[ -n "$(find "$crash_recovery" -maxdepth 1 -name '.cc-patch-manager-transaction-*' -print -quit)" ]] || fail 'read-only check removed the recovery journal'
if CC_PATCH_TESTING=1 runtime_exec apply "$(fixture_entry "$crash_recovery")" __contract__ >/dev/null 2>&1; then
  fail 'write continued in the same invocation after recovering an interrupted transaction'
fi
[[ "$(fixture_hash_tree "$crash_recovery")" == "$crash_before" ]] || fail 'interrupted transaction was not restored before re-analysis'
[[ -z "$(find "$crash_recovery" -maxdepth 1 -name '.cc-patch-manager-transaction-*' -print -quit)" ]] || fail 'recovered transaction journal was not removed'
CC_PATCH_TESTING=1 runtime_exec apply "$(fixture_entry "$crash_recovery")" __contract__ >/dev/null 2>&1 || fail 'apply was not retryable after recovery'

committed_crash="$tmp/committed-crash"
make_contract_package "$committed_crash"
CC_PATCH_TESTING=1 runtime_exec baseline "$(fixture_entry "$committed_crash")" __contract__ >/dev/null
if CC_PATCH_TESTING=1 CC_PATCH_TEST_LEAVE_COMMITTED_TRANSACTION=1 runtime_exec apply "$(fixture_entry "$committed_crash")" __contract__ >/dev/null 2>&1; then
  fail 'committed crash injection did not interrupt cleanup'
fi
grep -Fq 'CC_AFTER_ALPHA' "$committed_crash/chunks/alpha.js" || fail 'committed crash lost alpha replacement'
grep -Fq 'CC_AFTER_BETA' "$committed_crash/chunks/beta.js" || fail 'committed crash lost beta replacement'
[[ -n "$(find "$committed_crash" -maxdepth 1 -name '.cc-patch-manager-transaction-*' -print -quit)" ]] || fail 'committed crash did not leave a journal'
if CC_PATCH_TESTING=1 runtime_exec baseline "$(fixture_entry "$committed_crash")" __contract__ >/dev/null 2>&1; then
  fail 'write continued in the same invocation after cleaning a committed journal'
fi
grep -Fq 'CC_AFTER_ALPHA' "$committed_crash/chunks/alpha.js" || fail 'committed journal cleanup rolled back alpha'
grep -Fq 'CC_AFTER_BETA' "$committed_crash/chunks/beta.js" || fail 'committed journal cleanup rolled back beta'
[[ -z "$(find "$committed_crash" -maxdepth 1 -name '.cc-patch-manager-transaction-*' -print -quit)" ]] || fail 'committed journal cleanup left transaction state'

unrecoverable="$tmp/unrecoverable"
make_contract_package "$unrecoverable"
CC_PATCH_TESTING=1 runtime_exec baseline "$(fixture_entry "$unrecoverable")" __contract__ >/dev/null
mkdir "$unrecoverable/.cc-patch-manager-transaction-corrupt"
printf '{not-json\n' >"$unrecoverable/.cc-patch-manager-transaction-corrupt/transaction.json"
unrecoverable_before=$(fixture_hash_tree "$unrecoverable")
if CC_PATCH_TESTING=1 runtime_exec apply "$(fixture_entry "$unrecoverable")" __contract__ >/dev/null 2>&1; then
  fail 'apply continued with an unrecoverable transaction journal'
fi
[[ "$(fixture_hash_tree "$unrecoverable")" == "$unrecoverable_before" ]] || fail 'failed recovery mutated the package'
[[ -d "$unrecoverable/.cc-patch-manager-transaction-corrupt" ]] || fail 'failed recovery removed forensic transaction state'

foreign_journal="$tmp/foreign-journal"
make_contract_package "$foreign_journal"
CC_PATCH_TESTING=1 runtime_exec baseline "$(fixture_entry "$foreign_journal")" __contract__ >/dev/null
mkdir -p "$foreign_journal/.cc-patch-manager-transaction-foreign/before"
node - "$foreign_journal" <<'NODE'
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const root = process.argv[2];
const tx = path.join(root, '.cc-patch-manager-transaction-foreign');
const bytes = Buffer.from('#!/usr/bin/env node\nimport "./chunks/main.js"\n// foreign snapshot\n');
fs.writeFileSync(path.join(tx, 'before', '0'), bytes);
const hash = crypto.createHash('sha256').update(bytes).digest('hex');
fs.writeFileSync(path.join(tx, 'transaction.json'), JSON.stringify({
  schemaVersion: 1,
  state: 'prepared',
  target: {name: '@cometix/anthropic-cc', version: '0.0.0', layout: 'split-esm', identityFingerprint: 'foreign', entrySha256: hash},
  operations: [{relativePath: 'cli.js', existed: true, mode: 0o644, sha256: hash, afterMode: 0o644, afterSha256: hash}],
  createdDirectories: [],
}, null, 2));
NODE
foreign_before=$(fixture_hash_tree "$foreign_journal")
if CC_PATCH_TESTING=1 runtime_exec apply "$(fixture_entry "$foreign_journal")" __contract__ >/dev/null 2>&1; then
  fail 'apply continued with a foreign transaction journal'
fi
[[ "$(fixture_hash_tree "$foreign_journal")" == "$foreign_before" ]] || fail 'foreign transaction journal mutated the package'
[[ -d "$foreign_journal/.cc-patch-manager-transaction-foreign" ]] || fail 'foreign transaction journal was removed'

unmanaged_journal="$tmp/unmanaged-journal"
make_contract_package "$unmanaged_journal"
CC_PATCH_TESTING=1 runtime_exec baseline "$(fixture_entry "$unmanaged_journal")" __contract__ >/dev/null
mkdir -p "$unmanaged_journal/.cc-patch-manager-transaction-unmanaged/before"
node - "$unmanaged_journal" <<'NODE'
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const root = process.argv[2];
const tx = path.join(root, '.cc-patch-manager-transaction-unmanaged');
const manifest = JSON.parse(fs.readFileSync(path.join(root, '.cc-patch-manager-baseline', 'manifest.json')));
const bytes = Buffer.from('{"name":"@cometix/anthropic-cc","version":"0.0.0"}\n');
fs.writeFileSync(path.join(tx, 'before', '0'), bytes);
const hash = crypto.createHash('sha256').update(bytes).digest('hex');
fs.writeFileSync(path.join(tx, 'transaction.json'), JSON.stringify({
  schemaVersion: 1,
  state: 'prepared',
  target: {name: manifest.package.name, version: manifest.package.version, layout: manifest.package.layout,
    identityFingerprint: manifest.package.identityFingerprint, entrySha256: manifest.package.entrySha256},
  operations: [{relativePath: 'package.json', existed: true, mode: 0o644, sha256: hash, afterMode: 0o644, afterSha256: hash}],
  createdDirectories: [],
}, null, 2));
NODE
unmanaged_before=$(fixture_hash_tree "$unmanaged_journal")
if CC_PATCH_TESTING=1 runtime_exec apply "$(fixture_entry "$unmanaged_journal")" __contract__ >/dev/null 2>&1; then
  fail 'apply continued with an unmanaged transaction operation'
fi
[[ "$(fixture_hash_tree "$unmanaged_journal")" == "$unmanaged_before" ]] || fail 'unmanaged transaction operation mutated the package'
[[ -d "$unmanaged_journal/.cc-patch-manager-transaction-unmanaged" ]] || fail 'unmanaged transaction journal was removed'

printf 'corrupt\n' >>"$package/.cc-patch-manager-baseline/files/chunks/alpha.js"
if CC_PATCH_TESTING=1 runtime_exec baseline "$(fixture_entry "$package")" __contract__ >/dev/null 2>&1; then
  fail 'corrupt baseline mirror was accepted'
fi

printf 'PASS: package baseline manifest rejects stale and untrusted state\n'
