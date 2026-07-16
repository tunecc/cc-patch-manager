# 原脚本目录收拢 Design Spec

**Date:** 2026-07-16  
**Status:** 已确认，待规格复核  
**Scope:** 仓库目录布局与 `cc-patch-manager.sh` 的 VoiceMode 资源定位

## Goal

让仓库根目录的可见补丁脚本只保留 `cc-patch-manager.sh`；将原始补丁来源集中到名称明确的 `original-scripts/`。

## Layout

```text
cc-patch-manager.sh
original-scripts/
├── apply-claude-code-enable-auto-mode.sh
├── apply-claude-code-enable-keybindings-fix.sh
├── apply-claude-code-transcript-dialog-replay-fix.sh
├── apply-claude-code-unlock-ultracode-fix.sh
└── claude-code-enable-voice-mode-darwin-arm64/
    ├── apply-claude-code-enable-voice-mode.sh
    └── cometix-asr/
```

`docs/` 与 `tests/` 保持原位置，不纳入 `original-scripts/`。

## Implementation

1. 使用 `git mv` 移动四个根目录旧 `apply-*.sh` 和完整 VoiceMode 目录，以保留 Git 重命名历史。
2. 将管理器内 VoiceMode 资源目录改为 `original-scripts/claude-code-enable-voice-mode-darwin-arm64/cometix-asr`。
3. 将管理器内 VoiceMode AST 提取源改为同一目录的 `apply-claude-code-enable-voice-mode.sh`。
4. 更新测试，断言资源路径和 AST 引擎均可从新目录加载。

## Non-Goals

- 不改变任一旧脚本的内容或运行行为。
- 不改变 `cc-patch-manager.sh` 的 CLI、补丁逻辑、平台限制或基线备份策略。
- 不移动 `docs/`、`tests/` 或隐藏的 Git 文件。

## Validation

1. `bash -n cc-patch-manager.sh` 与 `bash -n tests/test_voice_mode_platform.sh` 通过。
2. `bash tests/test_voice_mode_platform.sh` 通过，覆盖平台门禁、资源缺失、AST 引擎和帮助文案。
3. `git diff --check` 无输出，`git status --short` 只显示预期的重命名与修改。
4. 根目录不再存在四个 `apply-claude-code-*.sh`，VoiceMode 目录仅位于 `original-scripts/` 下。
