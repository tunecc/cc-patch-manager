#!/usr/bin/env bash
set -euo pipefail
# Real-package acceptance: prove the seven production patches match and apply
# against a trustworthy published package, restore returns managed sources to
# baseline, and the patched CLI still loads.
#
# This is an acceptance test, not a fast-suite unit: it operates on a real
# multi-megabyte bundle and takes minutes. It skips (exit 0) when no package
# source is provided so the fast suite stays green without a real package.
#
#   bash tests/test_real_package_acceptance.sh cometixspace   # needs CC_PATCH_COMETIXSPACE_PACKAGE
#   bash tests/test_real_package_acceptance.sh cruce           # needs CC_PATCH_CRUCE_PACKAGE (default: global install)

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$ROOT/tests/lib/dual-layout-fixture.sh"
source "$ROOT/cc-patch-manager.sh"

target_kind="${1:-}"

if [[ -z "$target_kind" ]]; then
  printf 'SKIP: %s needs a target kind (cometixspace|cruce) and a real package source\n' "${BASH_SOURCE[0]##*/}"
  exit 0
fi

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

# Hash every regular file under root, excluding .cc-patch-manager- tool metadata
# AND node_modules (real global installs ship a large node_modules the patches
# never touch; excluding it keeps the before/after comparison fast and focused
# on managed sources).
fixture_hash_package() {
  node - "$1" <<'NODE'
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const root = fs.realpathSync(process.argv[2]);
const hash = crypto.createHash('sha256');
function visit(directory) {
  for (const entry of fs.readdirSync(directory, {withFileTypes: true}).sort((a, b) => a.name.localeCompare(b.name))) {
    if (entry.name.startsWith('.cc-patch-manager-')) continue;
    if (entry.name === 'node_modules') continue;
    const absolute = path.join(directory, entry.name);
    const relative = path.relative(root, absolute);
    if (entry.isDirectory()) visit(absolute);
    else if (entry.isFile()) hash.update(relative).update('\0').update(fs.readFileSync(absolute));
  }
}
visit(root);
console.log(hash.digest('hex'));
NODE
}

case "$target_kind" in
  cometixspace)
    if [[ -z "${CC_PATCH_COMETIXSPACE_PACKAGE:-}" ]]; then
      printf 'SKIP: set CC_PATCH_COMETIXSPACE_PACKAGE to a trustworthy CometixSpace 2.1.224 package root\n'
      printf '      build one from npm: npm pack @cometix/claude-code@2.1.224 (package.json) +\n'
      printf '      npm pack @cometix/claude-code-darwin-arm64@2.1.224 (cli.js + vendor/), then merge\n'
      exit 0
    fi
    source_root="$CC_PATCH_COMETIXSPACE_PACKAGE"
    expected_name='@cometix/claude-code'
    expected_version='2.1.224'
    # context-limit is documented-inapplicable on 2.1.224 single-cjs: the real
    # bundle exposes applyConfigEnvironmentVariables as a standalone export-map
    # function, not a class MethodDefinition, so the settings-env-refresh anchor
    # the patch resolves is absent. Tracked as a follow-up; the other six
    # patches apply and restore on 2.1.224, and context-limit applies on cruce.
    applicable=(auto-mode keybindings transcript-dialog ultracode voice-mode computer-use)
    inapplicable=(context-limit)
    ;;
  cruce)
    source_root="${CC_PATCH_CRUCE_PACKAGE:-/opt/homebrew/lib/node_modules/@cometix/anthropic-cc}"
    expected_name='@cometix/anthropic-cc'
    expected_version='2.1.259'
    applicable=(auto-mode keybindings transcript-dialog ultracode voice-mode context-limit computer-use)
    inapplicable=()
    ;;
  *)
    fail "usage: ${BASH_SOURCE[0]##*/} {cometixspace|cruce}";;
esac

# Per-patch lifecycle on an existing real package: check NEEDS_PATCH → apply →
# ALREADY_PATCHED (idempotent state) → single-restore → baseline recovered.
fixture_assert_real_lifecycle() {
  local root="$1" entry="$2" patch_id="$3" before output
  before=$(fixture_hash_package "$root")
  output=$(runtime_exec check "$entry" "$patch_id" 2>&1) || fail "$patch_id clean check failed: $output"
  grep -Fxq 'NEEDS_PATCH' <<<"$output" || fail "$patch_id clean check did not report NEEDS_PATCH: $output"
  output=$(runtime_exec apply "$entry" "$patch_id" 2>&1) || fail "$patch_id apply failed: $output"
  output=$(runtime_exec check "$entry" "$patch_id" 2>&1) || fail "$patch_id patched check failed: $output"
  grep -Fxq 'ALREADY_PATCHED' <<<"$output" || fail "$patch_id patched check did not report ALREADY_PATCHED: $output"
  output=$(runtime_exec restore "$entry" "$patch_id" 2>&1) || fail "$patch_id single restore failed: $output"
  fixture_assert_tree_equals "$before" "$(fixture_hash_package "$root")"
}

accept_package() {
  local source="$1" name="$2" version="$3" entry copy before output id source_before source_after
  # Source-protection guard: the acceptance operates on a COPY, so the source
  # package (e.g. the global cruce install) must be byte-for-byte unchanged before
  # vs after. This catches any future refactor that points the entry at the source
  # instead of the copy, or lets runtime_exec write baseline/transaction state
  # into the wrong package root.
  source_before=$(fixture_hash_package "$source")
  copy=$(mktemp -d)/package
  cp -R "$source" "$copy"
  entry="$copy/cli.js"
  before=$(fixture_hash_package "$copy")

  # Identity.
  runtime_exec inspect "$entry" | grep -Fx "TARGET_PACKAGE:$name"
  runtime_exec inspect "$entry" | grep -Fx "TARGET_VERSION:$version"

  # Per-patch matrix (single-restore).
  for id in "${applicable[@]}"; do
    fixture_assert_real_lifecycle "$copy" "$entry" "$id"
  done

  # Documented-inapplicable patches must report MISSING_TARGET (not silently pass).
  for id in "${inapplicable[@]}"; do
    output=$(runtime_exec check "$entry" "$id" 2>&1) || true
    grep -Fq 'MISSING_TARGET:' <<<"$output" ||
      fail "$id was expected to be inapplicable (MISSING_TARGET) on $name $version, got: $output"
  done

  # Full-restore: apply all applicable, smoke the patched CLI, restore-all to baseline.
  # restore-all resets every managed file from the trusted baseline with no reapply —
  # the tractable path on large single-CJS bundles where per-patch restore would
  # re-parse the entry once per retained patch.
  for id in "${applicable[@]}"; do
    runtime_exec apply "$entry" "$id" >/dev/null 2>&1 || fail "$id bulk apply failed"
  done
  output=$(node "$entry" --version </dev/null 2>&1) || fail "patched --version smoke failed: $output"
  [[ -n "$output" ]] || fail 'patched --version smoke produced no output'
  output=$(runtime_exec restore-all "$entry" 2>&1) || fail "restore-all failed: $output"
  grep -Fxq 'RESTORED:all' <<<"$output" || fail "restore-all did not report RESTORED:all: $output"
  fixture_assert_tree_equals "$before" "$(fixture_hash_package "$copy")"
  source_after=$(fixture_hash_package "$source")
  fixture_assert_tree_equals "$source_before" "$source_after"
}

accept_package "$source_root" "$expected_name" "$expected_version"
printf 'PASS: %s %s real-package acceptance (%d applicable, %d documented inapplicable)\n' \
  "$target_kind" "$expected_version" "${#applicable[@]}" "${#inapplicable[@]}"
