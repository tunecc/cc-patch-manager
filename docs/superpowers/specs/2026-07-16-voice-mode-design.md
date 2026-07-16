# Claude Code 补丁管理器 — VoiceMode / Cometix ASR 集成 Design Spec

**Date:** 2026-07-16  
**Status:** 已确认，待规格复核  
**Scope:** `cc-patch-manager.sh` 与仓库内 `claude-code-enable-voice-mode-darwin-arm64/` 资源

## 1. Problem

仓库新增了独立脚本 `claude-code-enable-voice-mode-darwin-arm64/apply-claude-code-enable-voice-mode.sh`。它会解锁 Claude Code VoiceMode，并把语音识别实现替换为本地 Cometix ASR 原生模块。

若继续单独运行该脚本，会维护一套独立的检测、时间戳备份和还原逻辑，与补丁管理器现有的单一基线备份策略冲突，也无法在统一 TUI 中查看状态和操作。

## 2. Goal

将 VoiceMode 作为管理器的第五个内置补丁 `voice-mode`，使其与现有补丁共享：

1. 状态检测、详情页、单项应用/还原和“一键应用全部”。
2. 基线备份：`cli.js.cc-patch-baseline`。
3. 还原语义：恢复基线后，重打其它仍显示已应用的补丁。
4. macOS Apple Silicon 运行限制：非 `Darwin/arm64` 平台明确报“当前平台不支持”，且禁止应用。

## 3. Non-Goals

- 不在本次支持 Linux、Intel macOS 或其它 CPU 架构。
- 不保留或调用独立脚本的时间戳备份与 `--restore` 流程。
- 不新增环境变量、安装程序、外部依赖或第二个管理脚本。
- 不修改现有四个补丁的 AST 规则或备份行为。

## 4. Chosen Approach

采用原生集成，而非由管理器包装调用独立脚本。

管理器新增 `write_patch_script_voice_mode`，将独立脚本中的 Node + Acorn AST 检测和修改逻辑迁入其临时 Node 脚本。补丁应用成功前会把仓库随附的 `cometix-asr` 文件复制到目标 `cli.js` 同级的 `vendor/cometix-asr/`，再对 `cli.js` 执行 AST 改写。

这样 `restore_patch voice-mode` 无需特殊分支：它恢复基线，再通过现有 `run_node_patch` 逐一重打其它保留补丁。重打 VoiceMode 时同样会重新安装所需原生模块。

## 5. Registry and UI

`PATCH_IDS` 在 `ultracode` 后追加 `voice-mode`。新增元数据：

| id | 名称 | 主列表说明 | 旧备份兼容后缀 |
|---|---|---|---|
| `voice-mode` | 语音模式解锁 | 解锁 VoiceMode，语音识别改用本地 Cometix ASR | `backup-cometix-asr` |

详情页说明面向用户：VoiceMode 原本受 Claude.ai 登录/订阅门槛限制；此补丁解锁入口并将流式语音识别改用本地 Cometix ASR。提示运行平台仅支持 macOS Apple Silicon，并说明应用后应重启 Claude Code。

所有由 `PATCH_IDS` 驱动的界面和 `--check` 输出会自动覆盖第五项。主菜单的选择提示和数字匹配须由固定 `[1-4]` / `1|2|3|4` 改为按数组长度支持 `1-5`，不改变其它按键。

## 6. Platform Guard

新增共享函数判断当前平台是否为：

```
uname -s == Darwin
uname -m == arm64
```

对 `voice-mode`：

- 检测时：不满足条件则状态为 `error`，详情为“当前平台不支持（仅支持 macOS Apple Silicon）”。
- 单项应用和“一键应用”：不满足条件时不得复制模块或修改 `cli.js`；一键应用可继续处理其余支持的补丁。
- 单项还原：不设置平台阻断，因为基线恢复与其它补丁重打仍应可用；但 VoiceMode 不会被重打。

原生模块来源固定为仓库的 `claude-code-enable-voice-mode-darwin-arm64/cometix-asr/`。应用前必须检查所需 `.node` 文件和 `index.js` 存在；缺失时视为错误，绝不修改目标 `cli.js`。

## 7. Application Flow

1. `run_node_patch voice-mode check` 先执行平台与资源预检，再运行 AST 检测。
2. `run_node_patch voice-mode apply` 先执行相同预检；创建（或复用）基线备份后，将原生模块安装至 `vendor/cometix-asr`，随后执行 AST 改写与内置验证。
3. AST 修改覆盖语音入口门禁、流式语音可用性、voice provider 可用范围、`/config` 语音设置、鉴权探针、VoiceMode 功能开关和 `connectVoiceStream` 的 Cometix ASR 适配器。
4. 若复制或 AST 验证失败，命令返回错误，状态显示具体原因。基线备份保留，供用户还原。

## 8. Validation

实施时须至少验证：

1. `bash -n cc-patch-manager.sh` 通过。
2. 通过 shell 测试桩验证 `voice-mode` 在非 `Darwin/arm64` 上检测为错误，且不会调用复制或 AST 修改路径。
3. 在受支持平台、临时 `cli.js` fixture 与临时 `vendor` 目录上验证：资源复制、AST 检测、应用、重复应用识别及基线还原后的其它补丁重打路径。
4. `--help`、`--check` 与主菜单的第五项显示正确；既有四项的检测路径不变。

真实 Claude Code 二进制版本不同可能让 AST 定位失败；届时必须显示明确的 `NOT_FOUND` / 验证失败信息，不能误报已应用。
