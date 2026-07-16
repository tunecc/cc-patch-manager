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

uname() {
  case "${1:-}" in
    -s) printf 'Darwin\n' ;;
    -m) printf 'arm64\n' ;;
    *) command uname "$@" ;;
  esac
}

real_voice_mode_source_dir=$(declare -f voice_mode_source_dir)
voice_mode_source_dir() { printf '%s\n' "$tmp/missing-cometix-asr"; }
before="$tmp/cli-before.js"
cp "$CLI_PATH" "$before"
STATUS[voice-mode]=""
MSG[voice-mode]=""

run_node_patch voice-mode apply || true

[[ "${STATUS[voice-mode]:-}" == "error" ]]
[[ "${MSG[voice-mode]:-}" == *"缺少 VoiceMode 资源"* ]]
cmp -s "$before" "$CLI_PATH"
[[ ! -e "$tmp/vendor/cometix-asr" ]]
printf 'PASS: voice-mode blocks missing assets before mutation\n'

eval "$real_voice_mode_source_dir"
script=$(write_patch_script voice-mode)
grep -Fq 'COMETIX_ASR_VOICE_STREAM' "$script"
rm -f "$script"
printf 'PASS: voice-mode selects its AST engine\n'
