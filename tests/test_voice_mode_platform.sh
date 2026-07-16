#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# 管理器被 source 时不会启动 TUI。
source "$ROOT/cc-patch-manager.sh"

uname() {
  case "${1:-}" in
    -s) printf 'Linux\n' ;;
    -m) printf 'x86_64\n' ;;
    *) command uname "$@" ;;
  esac
}

CLI_PATH="$tmp/cli.js"
printf '#!/usr/bin/env node\nconsole.log("fixture");\n' >"$CLI_PATH"

run_node_patch voice-mode check || true

[[ "${STATUS[voice-mode]:-}" == "error" ]]
[[ "${MSG[voice-mode]:-}" == "当前平台不支持（仅支持 macOS Apple Silicon）" ]]
[[ ! -e "$tmp/vendor/cometix-asr" ]]
printf 'PASS: voice-mode blocks unsupported platforms before mutation\n'
