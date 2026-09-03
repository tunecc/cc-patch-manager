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

printf 'PASS: target resolution preserves priority and discovers both packages\n'
