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
fixture_add_module "$package" chunks/source.js 'export const policy="deny"'
fixture_add_module "$package" chunks/entry.js 'import fs from "node:fs";import {policy as localPolicy} from "./source.js";export{localPolicy}'
fixture_add_module "$package" chunks/unrelated.js 'export const unrelated="no marker"'
fixture_add_module "$package" node_modules/ignored.js 'export const policy="deny"'
fixture_add_module "$package" vendor/cometix-asr/ignored.js 'export const policy="deny"'
fixture_add_module "$package" .cc-patch-manager-transaction-stale/ignored.js 'export const policy="deny"'
fixture_add_module "$package" cli.js '#!/usr/bin/env node
import {policy as entryPolicy} from "./chunks/source.js"'

set +e
output=$(runtime_exec index "$(fixture_entry "$package")" chunks/entry.js localPolicy deny 2>&1)
status=$?
set -e
[[ "$status" -eq 0 ]] || fail "index alias probe failed: $output"
grep -Fx 'TARGET_FILE:"chunks/source.js"' <<<"$output" >/dev/null || fail 'marker source candidate missing'
grep -Fx 'BINDING_SOURCE:"chunks/source.js":policy' <<<"$output" >/dev/null || fail 'import alias did not resolve to source export'
grep -F 'node_modules/ignored.js' <<<"$output" >/dev/null && fail 'node_modules marker candidate was included'
grep -F 'vendor/cometix-asr/ignored.js' <<<"$output" >/dev/null && fail 'managed vendor marker candidate was included'
grep -F '.cc-patch-manager-transaction-stale/ignored.js' <<<"$output" >/dev/null && fail 'transaction marker candidate was included'
grep -F 'chunks/unrelated.js' <<<"$output" >/dev/null && fail 'unrelated marker candidate was included'
if runtime_exec index "$(fixture_entry "$package")" chunks/entry.js fs deny >/dev/null 2>&1; then
  fail 'external bare-import binding was treated as an internal module binding'
fi

set +e
trace_output=$(CC_PATCH_TRACE_PARSE=1 runtime_exec index "$(fixture_entry "$package")" cli.js entryPolicy '[["allow","deny"],["missing","deny"]]' 2>&1)
trace_status=$?
set -e
[[ "$trace_status" -eq 0 ]] || fail "marker-group cache probe failed: $trace_output"
grep -Fx 'TARGET_FILE:"chunks/source.js"' <<<"$trace_output" >/dev/null || fail 'marker group did not select its OR candidate'
[[ "$(grep -Fc 'PARSE_FILE:"cli.js":module' <<<"$trace_output")" -eq 1 ]] || fail 'entry module AST was not cached by content'
grep -F 'PARSE_FILE:"chunks/unrelated.js"' <<<"$trace_output" >/dev/null && fail 'unrelated chunk entered AST parsing'

fixture_add_module "$package" chunks/external-reexport.js 'export {externalThing} from "external-package";export * from "another-package";import {policy as internalPolicy} from "./source.js";export{internalPolicy}'
set +e
reexport_output=$(runtime_exec index "$(fixture_entry "$package")" chunks/external-reexport.js internalPolicy deny 2>&1)
reexport_status=$?
set -e
[[ "$reexport_status" -eq 0 ]] || fail "bare re-export blocked an independent internal binding: $reexport_output"
grep -Fx 'BINDING_SOURCE:"chunks/source.js":policy' <<<"$reexport_output" >/dev/null || fail 'internal binding beside bare re-export did not resolve'
if runtime_exec index "$(fixture_entry "$package")" chunks/external-reexport.js externalThing deny >/dev/null 2>&1; then
  fail 'bare named re-export was treated as an internal module binding'
fi

fixture_add_module "$package" chunks/star-source.js 'export const throughStar="star-marker"'
fixture_add_module "$package" chunks/star-barrel.js 'export * from "./star-source.js"'
fixture_add_module "$package" chunks/star-consumer.js 'import {throughStar as starAlias} from "./star-barrel.js";export{starAlias}'
set +e
star_output=$(runtime_exec index "$(fixture_entry "$package")" chunks/star-consumer.js starAlias star-marker 2>&1)
star_status=$?
set -e
[[ "$star_status" -eq 0 ]] || fail "export-star probe failed: $star_output"
grep -Fx 'BINDING_SOURCE:"chunks/star-source.js":throughStar' <<<"$star_output" >/dev/null || fail 'export-star alias did not resolve'

fixture_add_module "$package" chunks/default-source.js 'const hidden="default-marker";export {hidden as default}'
fixture_add_module "$package" chunks/default-barrel.js 'export * from "./default-source.js"'
fixture_add_module "$package" chunks/default-consumer.js 'import {default as leakedDefault} from "./default-barrel.js";export{leakedDefault}'
if runtime_exec index "$(fixture_entry "$package")" chunks/default-consumer.js leakedDefault default-marker >/dev/null 2>&1; then
  fail 'export-star incorrectly propagated a default export'
fi

fixture_add_module "$package" chunks/missing.js 'import {absent} from "./source.js";export{absent}'
if runtime_exec index "$(fixture_entry "$package")" chunks/missing.js absent deny >/dev/null 2>&1; then
  fail 'missing export was accepted'
fi

fixture_add_module "$package" chunks/duplicate-a.js 'export const duplicated=1'
fixture_add_module "$package" chunks/duplicate-b.js 'export const duplicated=2'
fixture_add_module "$package" chunks/duplicate.js 'export {duplicated} from "./duplicate-a.js";export {duplicated} from "./duplicate-b.js"'
if runtime_exec index "$(fixture_entry "$package")" chunks/duplicate.js duplicated duplicated >/dev/null 2>&1; then
  fail 'duplicate export was accepted'
fi

fixture_add_module "$package" chunks/cycle-a.js 'export {loop} from "./cycle-b.js"'
fixture_add_module "$package" chunks/cycle-b.js 'export {loop} from "./cycle-a.js"'
if runtime_exec index "$(fixture_entry "$package")" chunks/cycle-a.js loop loop >/dev/null 2>&1; then
  fail 'cyclic re-export was accepted'
fi

printf 'PASS: marker scan and ESM alias index reject ambiguous bindings\n'
