# 原脚本目录收拢 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 将原始补丁和 VoiceMode 资源收拢到 `original-scripts/`，根目录只保留管理器脚本。

**Architecture:** 使用 `git mv` 保留历史；管理器仅改 VoiceMode 的资源与 AST 源路径。测试增加新路径断言，防止移动后断链。

**Tech Stack:** Git、Bash、Node.js。

## Global Constraints

- 根目录可见补丁脚本只保留 `cc-patch-manager.sh`。
- `docs/` 和 `tests/` 不移动，不改旧 `apply-*.sh` 内容。
- VoiceMode 资源固定在 `original-scripts/claude-code-enable-voice-mode-darwin-arm64/cometix-asr`。

---

### Task 1: 测试并移动原始脚本

**Files:**

- Move: 四个根目录 `apply-claude-code-*.sh` → `original-scripts/`
- Move: `claude-code-enable-voice-mode-darwin-arm64/` → `original-scripts/claude-code-enable-voice-mode-darwin-arm64/`
- Modify: `cc-patch-manager.sh`
- Modify: `tests/test_voice_mode_platform.sh`

**Interfaces:**

- Consumes: `voice_mode_source_dir()`、`write_patch_script voice-mode`。
- Produces: VoiceMode 资源与 AST 源均从 `original-scripts/` 读取。

- [ ] **Step 1: 写失败测试**

在 `tests/test_voice_mode_platform.sh` 的 AST 引擎断言前增加：

```bash
real_source=$(voice_mode_source_dir)
[[ "$real_source" == "$ROOT/original-scripts/claude-code-enable-voice-mode-darwin-arm64/cometix-asr" ]]
[[ -f "$real_source/index.js" ]]
```

- [ ] **Step 2: 验证测试失败**

Run: `bash tests/test_voice_mode_platform.sh`

Expected: 非零退出，因为管理器仍返回根目录的旧路径。

- [ ] **Step 3: 移动脚本和资源**

```bash
mkdir -p original-scripts
git mv apply-claude-code-enable-auto-mode.sh original-scripts/
git mv apply-claude-code-enable-keybindings-fix.sh original-scripts/
git mv apply-claude-code-transcript-dialog-replay-fix.sh original-scripts/
git mv apply-claude-code-unlock-ultracode-fix.sh original-scripts/
git mv claude-code-enable-voice-mode-darwin-arm64 original-scripts/
```

- [ ] **Step 4: 更新两处管理器路径**

将 `voice_mode_source_dir()` 的目录改为：

```bash
original-scripts/claude-code-enable-voice-mode-darwin-arm64/cometix-asr
```

将 `write_patch_script_voice_mode()` 的 `source` 目录改为：

```bash
original-scripts/claude-code-enable-voice-mode-darwin-arm64/apply-claude-code-enable-voice-mode.sh
```

- [ ] **Step 5: 验证测试通过**

Run: `bash tests/test_voice_mode_platform.sh`

Expected: 退出码 `0`，所有断言输出 `PASS`。

- [ ] **Step 6: 提交迁移**

Run: `git add cc-patch-manager.sh tests/test_voice_mode_platform.sh original-scripts && git commit -m "refactor: group original patch scripts"`

### Task 2: 验证目录边界

**Files:**

- Test: `tests/test_voice_mode_platform.sh`

- [ ] **Step 1: 验证语法与回归测试**

Run: `bash -n cc-patch-manager.sh && bash -n tests/test_voice_mode_platform.sh && bash tests/test_voice_mode_platform.sh`

Expected: 退出码 `0`，测试输出均为 `PASS`。

- [ ] **Step 2: 验证根目录脚本**

Run: `find . -maxdepth 1 -type f -name '*.sh' -print | sort`

Expected: 仅输出 `./cc-patch-manager.sh`。

- [ ] **Step 3: 验证 Git 状态**

Run: `git diff --check && git status --short`

Expected: `git diff --check` 无输出；Task 1 的路径迁移已提交。
