#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

assert_eq() {
  local actual="$1" expected="$2" label="$3"
  [[ "$actual" == "$expected" ]] || fail "$label: expected [$expected], got [$actual]"
}

source "$ROOT/tests/lib/dual-layout-fixture.sh"
source "$ROOT/cc-patch-manager.sh"

old_root="$tmp/old/@cometix/claude-code"
new_root="$tmp/global/@cometix/anthropic-cc"
fixture_make_package "$old_root" single-cjs '@cometix/claude-code' 2.1.224
fixture_make_package "$new_root" split-esm '@cometix/anthropic-cc' 2.1.259

CLAUDE_CLI_PATH=$(fixture_entry "$old_root")
resolve_target "$(fixture_entry "$new_root")"
assert_eq "$CLI_PATH" "$(fixture_entry "$new_root")" 'explicit path wins over CLAUDE_CLI_PATH'

resolve_target
assert_eq "$CLI_PATH" "$(fixture_entry "$old_root")" 'CLAUDE_CLI_PATH wins over discovery'

unset CLAUDE_CLI_PATH
mkdir -p "$tmp/bin" "$tmp/home"
cat >"$tmp/bin/npm" <<'SH'
#!/usr/bin/env bash
[[ "${1:-}" == root && "${2:-}" == -g ]] || exit 2
printf '%s\n' "$TEST_NPM_ROOT"
SH
chmod +x "$tmp/bin/npm"

set +e
found=$(HOME="$tmp/home" TEST_NPM_ROOT="$tmp/global" PATH="$tmp/bin:/usr/bin:/bin" find_cli_js)
find_status=$?
set -e
[[ "$find_status" -eq 0 ]] || fail 'cruce global package is not discovered'
assert_eq "$found" "$(fixture_entry "$new_root")" 'cruce global package is discovered'

legacy_global="$tmp/legacy-global/@cometix/claude-code"
fixture_make_package "$legacy_global" single-cjs '@cometix/claude-code' 2.1.224
found=$(HOME="$tmp/home" TEST_NPM_ROOT="$tmp/legacy-global" PATH="$tmp/bin:/usr/bin:/bin" find_cli_js)
assert_eq "$found" "$(fixture_entry "$legacy_global")" 'legacy CometixSpace package remains discoverable'

if resolve_target "$tmp/missing/cli.js"; then
  fail 'missing explicit target was accepted'
fi
[[ -z "$CLI_PATH" ]] || fail 'failed explicit target must clear CLI_PATH'

set +e
new_inspect=$(runtime_exec inspect "$(fixture_entry "$new_root")" 2>&1)
new_status=$?
set -e
[[ "$new_status" -eq 0 ]] || fail "split-esm inspect failed: $new_inspect"
grep -Fx 'TARGET_PACKAGE:@cometix/anthropic-cc' <<<"$new_inspect" >/dev/null || fail 'split package name missing'
grep -Fx 'TARGET_VERSION:2.1.259' <<<"$new_inspect" >/dev/null || fail 'split package version missing'
grep -Fx 'TARGET_LAYOUT:split-esm' <<<"$new_inspect" >/dev/null || fail 'split layout missing'
identity_before=$(sed -n 's/^TARGET_IDENTITY://p' <<<"$new_inspect")
fixture_add_module "$new_root" vendor/cometix-asr/index.js 'export const managedResource=true'
fixture_add_module "$new_root" .cc-patch-manager-transaction-stale/snapshot.js 'export const transactionSnapshot=true'
identity_after=$(runtime_exec inspect "$(fixture_entry "$new_root")" | sed -n 's/^TARGET_IDENTITY://p')
assert_eq "$identity_after" "$identity_before" 'manager resources must not change package identity'

old_inspect=$(runtime_exec inspect "$(fixture_entry "$old_root")")
grep -Fx 'TARGET_PACKAGE:@cometix/claude-code' <<<"$old_inspect" >/dev/null || fail 'single package name missing'
grep -Fx 'TARGET_LAYOUT:single-cjs' <<<"$old_inspect" >/dev/null || fail 'single layout missing'

unsupported_root="$tmp/unsupported"
fixture_make_package "$unsupported_root" single-cjs '@example/not-claude-code' 1.0.0
if runtime_exec inspect "$(fixture_entry "$unsupported_root")" >/dev/null 2>&1; then
  fail 'unsupported package was accepted'
fi

broken_root="$tmp/broken/@cometix/anthropic-cc"
fixture_make_package "$broken_root" split-esm '@cometix/anthropic-cc' 2.1.259
printf '#!/usr/bin/env node\nimport "./chunks/missing.js"\n' >"$broken_root/cli.js"
if runtime_exec inspect "$(fixture_entry "$broken_root")" >/dev/null 2>&1; then
  fail 'split entry with a missing relative module was accepted'
fi

mixed_root="$tmp/mixed/@cometix/anthropic-cc"
fixture_make_package "$mixed_root" split-esm '@cometix/anthropic-cc' 2.1.259
printf 'module.exports = {}\n' >>"$mixed_root/cli.js"
if runtime_exec inspect "$(fixture_entry "$mixed_root")" >/dev/null 2>&1; then
  fail 'entry with conflicting CJS and split-ESM evidence was accepted'
fi

json_root="$tmp/json/@cometix/anthropic-cc"
fixture_make_package "$json_root" split-esm '@cometix/anthropic-cc' 2.1.259
printf '{"enabled":true}\n' >"$json_root/config.json"
printf '#!/usr/bin/env node\nimport "./config.json"\n' >"$json_root/cli.js"
if runtime_exec inspect "$(fixture_entry "$json_root")" >/dev/null 2>&1; then
  fail 'non-JavaScript relative import was treated as split-ESM evidence'
fi

resource_root="$tmp/resource/@cometix/anthropic-cc"
fixture_make_package "$resource_root" split-esm '@cometix/anthropic-cc' 2.1.259
printf '{"enabled":true}\n' >"$resource_root/config.json"
printf '#!/usr/bin/env node\nimport "./chunks/main.js"\nimport "./config.json"\n' >"$resource_root/cli.js"
resource_inspect=$(runtime_exec inspect "$(fixture_entry "$resource_root")" 2>&1) || fail 'split entry with an additional resource import was rejected'
grep -Fx 'TARGET_LAYOUT:split-esm' <<<"$resource_inspect" >/dev/null || fail 'JS plus resource imports did not identify split-esm'

escape_root="$tmp/escape/@cometix/anthropic-cc"
fixture_make_package "$escape_root" split-esm '@cometix/anthropic-cc' 2.1.259
printf 'export const outside=true\n' >"$tmp/outside.js"
ln -s "$tmp/outside.js" "$escape_root/chunks/escape.js"
printf '#!/usr/bin/env node\nimport "./chunks/escape.js"\n' >"$escape_root/cli.js"
if runtime_exec inspect "$(fixture_entry "$escape_root")" >/dev/null 2>&1; then
  fail 'relative module symlink escaped the package root'
fi

if voice_mode_supported; then
  safety_root="$tmp/safety/@cometix/anthropic-cc"
  fixture_make_package "$safety_root" split-esm '@cometix/anthropic-cc' 2.1.259
  CLI_PATH=$(fixture_entry "$safety_root")
  if run_node_patch voice-mode apply >/dev/null 2>&1; then
    fail 'split package was sent through the legacy VoiceMode engine'
  fi
  [[ ! -e "$safety_root/vendor/cometix-asr" ]] || fail 'rejected split package was mutated before analysis'
  [[ "${MSG[voice-mode]:-}" == *'split-esm'* ]] || fail 'split rejection did not explain the incompatible engine path'
fi

printf 'PASS: target resolution and structural layout inspection support both packages\n'
