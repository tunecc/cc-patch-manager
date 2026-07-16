# VoiceMode / Cometix ASR 集成 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 将仅支持 macOS Apple Silicon 的 VoiceMode / Cometix ASR 补丁作为第五个内置补丁接入 `cc-patch-manager.sh`。

**Architecture:** 管理器继续使用现有的 `PATCH_IDS` 注册表、基线备份和临时 Node + Acorn 引擎。`voice-mode` 在进入 Node 引擎前完成平台与随附资源预检；应用时将本地 ASR 文件复制到目标 `vendor/cometix-asr`，随后执行从独立脚本迁入的 AST 改写。测试通过 source 管理器、替换 `uname` 的 Bash 函数来验证非支持平台绝不进入复制或 Node 路径。

**Tech Stack:** Bash、Node.js、Acorn 8.16.0、现有 `cometix-asr` Node-API 原生模块。

## Global Constraints

- 仅允许 `uname -s` 为 `Darwin` 且 `uname -m` 为 `arm64` 时检测或应用 `voice-mode`。
- 非支持平台的 `voice-mode` 状态必须是 `error`，消息固定为“当前平台不支持（仅支持 macOS Apple Silicon）”，且不复制资源、不修改 `cli.js`。
- `voice-mode` 复用 `cli.js.cc-patch-baseline`；不得创建独立时间戳备份。
- 资源来源固定为 `claude-code-enable-voice-mode-darwin-arm64/cometix-asr/`，应用前必须要求 `.node` 文件和 `index.js` 存在。
- 不引入新的运行时依赖，不调用独立脚本，也不改变现有四个 AST 引擎的规则。
- 新增补丁 ID 为 `voice-mode`，显示名称为“语音模式解锁”。

---

### Task 1: 建立可 source 的管理器与平台门禁回归测试

**Files:**

- Create: `tests/test_voice_mode_platform.sh`
- Modify: `cc-patch-manager.sh:2688`

**Interfaces:**

- Consumes: `cc-patch-manager.sh` 的全局 `CLI_PATH`、`STATUS`、`MSG` 和 `run_node_patch id mode`。
- Produces: `voice_mode_supported()`，返回 `0` 表示 Darwin/arm64，返回 `1` 表示其它平台；脚本仅直接执行时调用 `main "$@"`。

- [ ] **Step 1: 写出失败的非支持平台测试**

创建 `tests/test_voice_mode_platform.sh`：

```bash
#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

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
```

- [ ] **Step 2: 运行测试，确认其因接口尚不存在而失败**

Run: `bash tests/test_voice_mode_platform.sh`

Expected: 非零退出；输出包含 `未知补丁 id: voice-mode`，或 `STATUS[voice-mode]` 断言失败。

- [ ] **Step 3: 让管理器可被测试 source，并添加最小平台函数**

在 `cc-patch-manager.sh` 的 `require_target_writable` 后加入：

```bash
voice_mode_supported() {
  [[ "$(uname -s)" == "Darwin" && "$(uname -m)" == "arm64" ]]
}

voice_mode_platform_error() {
  STATUS[voice-mode]=error
  MSG[voice-mode]="当前平台不支持（仅支持 macOS Apple Silicon）"
}
```

将文件最后一行从：

```bash
main "$@"
```

改为：

```bash
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
```

这只改变 source 时不进入 TUI 的行为，直接执行的 CLI 行为保持不变。

- [ ] **Step 4: 在 `run_node_patch` 的依赖检查前实现门禁**

在读取 `id` 与 `mode` 后、`require_target_readable` 之前加入：

```bash
if [[ "$id" == "voice-mode" && ! voice_mode_supported ]]; then
  voice_mode_platform_error
  return 1
fi
```

这确保不支持平台不会下载 Acorn、加载 Node、复制模块或写入目标文件。

- [ ] **Step 5: 运行测试，确认其通过**

Run: `bash tests/test_voice_mode_platform.sh`

Expected: 退出码 `0`，输出 `PASS: voice-mode blocks unsupported platforms before mutation`。

- [ ] **Step 6: 提交测试门禁基础**

```bash
git add cc-patch-manager.sh tests/test_voice_mode_platform.sh
git commit -m "test: cover unsupported voice mode platform"
```

### Task 2: 接入注册表、资源预检与复制

**Files:**

- Modify: `cc-patch-manager.sh:29-107, 2221-2256, 2389-2405, 2625-2627`
- Test: `tests/test_voice_mode_platform.sh`

**Interfaces:**

- Consumes: `voice_mode_supported()`、全局 `CLI_PATH`，以及仓库固定资源目录。
- Produces: `voice_mode_source_dir()`、`voice_mode_assets_ready()`、`install_voice_mode_vendor()`；`run_node_patch voice-mode apply` 在 Node 写入前已安装并验证 `vendor/cometix-asr`。

- [ ] **Step 1: 扩充失败测试，覆盖缺失资源不写入**

在 `tests/test_voice_mode_platform.sh` 末尾增加一个 Darwin/arm64 分支：先覆盖测试进程内的 `voice_mode_source_dir`，使其指向 `$tmp/missing-asr`（该目录不放任何文件），再执行 `run_node_patch voice-mode apply || true`，断言：

```bash
[[ "${STATUS[voice-mode]:-}" == "error" ]]
[[ "${MSG[voice-mode]:-}" == *"缺少 VoiceMode 资源"* ]]
cmp -s "$before" "$CLI_PATH"
```

该测试不改动仓库内的原生模块。此步骤预期在预检函数尚未实现时失败。

- [ ] **Step 2: 注册第五个补丁与中文内容**

将注册表改为：

```bash
PATCH_IDS=(auto-mode keybindings transcript-dialog ultracode voice-mode)
```

并在 `patch_name`、`patch_note`、`patch_suffix`、`patch_purpose` 中分别增加：

```bash
voice-mode) echo "语音模式解锁" ;;
voice-mode) echo "解锁 VoiceMode，语音识别改用本地 Cometix ASR" ;;
voice-mode) echo "backup-cometix-asr" ;;
```

`patch_purpose` 使用以下正文：

```text
现象：VoiceMode 原本受 Claude.ai 登录与订阅门槛限制；部分环境没有入口，
且官方流式语音识别依赖远端服务。

改动：
  (1) 解锁 VoiceMode 的入口、可用性与设置项
  (2) 流式语音识别改用本地 Cometix ASR

限制：仅支持 macOS Apple Silicon（Darwin/arm64）。应用后请重启 Claude Code。
```

- [ ] **Step 3: 添加资源检查和安装函数**

在平台函数后加入：

```bash
voice_mode_source_dir() {
  printf '%s/claude-code-enable-voice-mode-darwin-arm64/cometix-asr\n' \
    "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
}

voice_mode_assets_ready() {
  local source="${1:-$(voice_mode_source_dir)}"
  [[ -f "$source/index.js" ]] && compgen -G "$source/libcometix-asr*.node" >/dev/null
}

install_voice_mode_vendor() {
  local source vendor native
  source=$(voice_mode_source_dir)
  vendor="$(dirname "$CLI_PATH")/vendor/cometix-asr"
  if ! voice_mode_assets_ready; then
    STATUS[voice-mode]=error
    MSG[voice-mode]="缺少 VoiceMode 资源（需要 cometix-asr/index.js 和 libcometix-asr*.node）"
    return 1
  fi
  mkdir -p "$vendor" || return 1
  rm -f "$vendor"/*.node
  for native in "$source"/libcometix-asr*.node; do cp -f "$native" "$vendor/"; done
  cp -f "$source/index.js" "$vendor/index.js"
  [[ -f "$source/index.d.ts" ]] && cp -f "$source/index.d.ts" "$vendor/"
  [[ -f "$source/package.json" ]] && cp -f "$source/package.json" "$vendor/"
  node -e 'const m=require(process.argv[1]);if(typeof m.startSession!=="function")process.exit(2)' "$vendor/index.js"
}
```

若 `mkdir`、`cp` 或 Node-API 验证失败，包装失败分支写入 `STATUS[voice-mode]=error` 和明确 `MSG`；不得继续创建临时 Node AST 脚本。

- [ ] **Step 4: 在应用路径安装资源，并让检测路径只预检**

在 Task 1 的平台门禁之后加入：

```bash
if [[ "$id" == "voice-mode" ]] && ! voice_mode_assets_ready; then
  STATUS[voice-mode]=error
  MSG[voice-mode]="缺少 VoiceMode 资源（需要 cometix-asr/index.js 和 libcometix-asr*.node）"
  return 1
fi
if [[ "$id" == "voice-mode" && "$mode" == "apply" ]] && ! install_voice_mode_vendor; then
  MSG[voice-mode]="${MSG[voice-mode]:-安装 Cometix ASR 资源失败}"
  return 1
fi
```

保留现有 `ensure_baseline`/`CC_PATCH_SKIP_BACKUP` 流程；首次真正 AST 写入才创建基线。

- [ ] **Step 5: 让菜单识别第五项**

将主屏提示改为 `[1-5] 选择补丁`，并将 `menu_loop` 的选择分支改为：

```bash
1|2|3|4|5)
  id="${PATCH_IDS[$((choice - 1))]}"
  show_detail "$id"
  ;;
```

- [ ] **Step 6: 运行资源与平台测试**

Run: `bash tests/test_voice_mode_platform.sh`

Expected: 平台不支持和资源缺失两个场景均退出码 `0`；任何场景均不改变 fixture 的 `cli.js`。

- [ ] **Step 7: 提交注册表和资源逻辑**

```bash
git add cc-patch-manager.sh tests/test_voice_mode_platform.sh
git commit -m "feat: register voice mode patch assets"
```

### Task 3: 迁入 VoiceMode AST 引擎并接入统一状态协议

**Files:**

- Modify: `cc-patch-manager.sh:460-472, 2221-2256`
- Reference: `claude-code-enable-voice-mode-darwin-arm64/apply-claude-code-enable-voice-mode.sh:263-1483`
- Test: `tests/test_voice_mode_platform.sh`

**Interfaces:**

- Consumes: `node "$script" "$ACORN_PATH" "$CLI_PATH" [--check]`、`BACKUP_SUFFIX`、`CC_PATCH_SKIP_BACKUP`、`CC_PATCH_BASELINE`。
- Produces: `write_patch_script_voice_mode out`，输出既有机器标记：`ALREADY_PATCHED`、`NEEDS_PATCH`、`PATCH_COUNT:n`、`NOT_FOUND:...`、`VERIFY_FAILED:...`、`SUCCESS:n`。

- [ ] **Step 1: 写出失败的 AST 引擎选择测试**

在 `tests/test_voice_mode_platform.sh` 增加支持平台的测试桩（`uname -s` 返回 `Darwin`、`uname -m` 返回 `arm64`）。将 `write_patch_script` 的目标行为断言为：

```bash
script=$(write_patch_script voice-mode)
grep -Fq 'COMETIX_ASR_VOICE_STREAM' "$script"
rm -f "$script"
```

在引擎分支不存在时，`write_patch_script voice-mode` 应非零，测试必须失败。

- [ ] **Step 2: 接入引擎选择分支**

在 `write_patch_script` 的 case 中追加 `voice-mode` 分支，并在同一提交中新增完整的 `write_patch_script_voice_mode`：

```bash
voice-mode) write_patch_script_voice_mode "$tmp" ;;
```

该函数必须在本步骤一次性写入第 3 步描述的完整 Node 代码；在 `--check` 模式下绝不写入 `cli.js`。

- [ ] **Step 3: 将独立脚本的 AST 内容完整迁入 heredoc，并改用基线备份**

以 `apply-claude-code-enable-voice-mode.sh` 中 `PATCH_EOF` 的内容为唯一迁移来源，复制其 Node 部分（原第 263–1483 行）到 `write_patch_script_voice_mode` 的 heredoc，保留所有 AST 定位、`COMETIX_*` marker、end-to-start replacement 和写后 marker 校验。

将原时间戳备份块：

```js
const timestamp = new Date().toISOString().replace(/[:.]/g, '-').slice(0, 19);
const backupPath = cliPath + '.' + backupSuffix + '-' + timestamp;
fs.copyFileSync(cliPath, backupPath);
console.log('BACKUP:' + backupPath);
```

替换为管理器其它引擎使用的基线块：

```js
let backupPath = '';
if (process.env.CC_PATCH_SKIP_BACKUP === '1') {
  backupPath = process.env.CC_PATCH_BASELINE || (cliPath + '.cc-patch-baseline');
  if (!fs.existsSync(backupPath)) {
    fs.copyFileSync(cliPath, backupPath);
    console.log('BASELINE_CREATED:' + backupPath);
  }
  console.log('BACKUP:' + backupPath);
} else {
  const timestamp = new Date().toISOString().replace(/[:.]/g, '-').slice(0, 19);
  backupPath = cliPath + '.' + backupSuffix + '-' + timestamp;
  fs.copyFileSync(cliPath, backupPath);
  console.log('BACKUP:' + backupPath);
}
```

`parse_and_set_status` 已能解析上述输出，不要新增独立的 VoiceMode 状态格式。

- [ ] **Step 4: 运行引擎选择测试，确认绿色**

Run: `bash tests/test_voice_mode_platform.sh`

Expected: 退出码 `0`；引擎临时文件包含 `COMETIX_ASR_VOICE_STREAM`，非支持平台仍不会创建 vendor 目录。

- [ ] **Step 5: 对受支持平台执行无副作用检测冒烟**

Run: `tmp=$(mktemp -d); printf '#!/usr/bin/env node\nconsole.log("fixture");\n' > "$tmp/cli.js"; CLAUDE_CLI_PATH="$tmp/cli.js" ./cc-patch-manager.sh --check; rc=$?; rm -rf "$tmp"; exit "$rc"`

Expected: `voice-mode` 显示“未找到: AST miss: ...”而非“已应用”；临时 `cli.js` 不变；整条命令因 fixture 不包含真实 Claude Code AST 而以 `1` 退出。

- [ ] **Step 6: 提交 AST 引擎迁移**

```bash
git add cc-patch-manager.sh tests/test_voice_mode_platform.sh
git commit -m "feat: integrate voice mode ast patch"
```

### Task 4: 全量验证与交付复核

**Files:**

- Modify: `cc-patch-manager.sh`（只在下列验证发现缺陷时修复）
- Test: `tests/test_voice_mode_platform.sh`

**Interfaces:**

- Consumes: 第 1–3 任务产出的所有函数与脚本。
- Produces: 有证据支持的交付结论；不改变公开 CLI 参数。

- [ ] **Step 1: 运行静态语法检查**

Run: `bash -n cc-patch-manager.sh && bash -n tests/test_voice_mode_platform.sh`

Expected: 退出码 `0`，无输出。

- [ ] **Step 2: 运行平台回归测试**

Run: `bash tests/test_voice_mode_platform.sh`

Expected: 退出码 `0`，每个断言场景输出 `PASS`。

- [ ] **Step 3: 验证帮助和第五项注册**

Run: `./cc-patch-manager.sh --help`

Expected: 退出码 `0`；帮助中的“补丁状态”数量更新为“五个”。

若第 2 任务尚未更新该文案，在 `usage()` 的简介行将“**四个**社区常用 Claude Code 本地补丁”改为“**五个**社区常用 Claude Code 本地补丁”。

Run: `rg -n 'PATCH_IDS=|voice-mode|\[1-5\]' cc-patch-manager.sh`

Expected: 输出唯一的 `PATCH_IDS` 注册行、`voice-mode` 元数据/引擎分支和第五项菜单提示。

- [ ] **Step 4: 验证无无意工作树改动**

Run: `git diff --check && git status --short`

Expected: `git diff --check` 无输出；除任务文件和用户原有 `claude-code-enable-voice-mode-darwin-arm64/` 外，不出现无关文件。

- [ ] **Step 5: 提交验证后的最终改动**

```bash
git add cc-patch-manager.sh tests/test_voice_mode_platform.sh
git commit -m "test: verify voice mode integration"
```

若没有新改动，该命令不执行；交付时报告第 1–4 步的实际输出以及真实 Claude Code 版本的 AST 匹配仍需用户环境验证这一风险。
