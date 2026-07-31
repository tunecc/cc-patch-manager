# Claude Code 补丁管理器 — VoiceMode 上游脚本刷新 Design Spec

**Date:** 2026-07-31  
**Status:** 已确认，待规格复核  
**Scope:** `original-scripts/claude-code-enable-voice-mode-darwin-arm64/`、`tests/test_voice_mode_gate.sh`、根目录临时下载目录

## 1. Problem

仓库归档的 VoiceMode 原脚本位于：

```text
original-scripts/claude-code-enable-voice-mode-darwin-arm64/
├── apply-claude-code-enable-voice-mode.sh
└── cometix-asr/
```

管理器通过 `write_patch_script_voice_mode` 从该脚本动态提取 AST 引擎（`PATCH_EOF` heredoc），并在提取后把独立时间戳备份改写为基线备份语义。因此 **源脚本即 AST 真相源**；归档过期会直接导致检测/应用失败。

用户提供了原作者更新包：

```text
claude-code-enable-voice-mode-darwin-arm64 2/
├── apply-claude-code-enable-voice-mode.sh
└── cometix-asr/
```

并说明旧归档已失效，需要把我们的源同步到新版。与此同时，我们在 `0ddf1d1` 已对旧归档做过 2-call gate 修复（注释为 `2.1.217+`），不能盲目覆盖而不做差异分析。

## 2. Goal

将上游新版 VoiceMode 脚本合入 `original-scripts/`，使管理器自动获得上游的 gate 检测重构，并保持现有集成壳层不变。

成功后：

1. 唯一正式源仍是 `original-scripts/claude-code-enable-voice-mode-darwin-arm64/`。
2. 提取出的引擎包含 `isVoiceGateAndChain`，对 2-call 与 3-call fixture 均能 `FOUND:voiceGateVmr`。
3. 基线备份 rewrite 仍成功。
4. 相关测试通过；根目录临时下载目录被清理。

## 3. Non-Goals

- 不修改 `cc-patch-manager.sh` 的资源路径、平台门禁、vendor 安装或备份 rewrite 逻辑。
- 不改变其它补丁的 AST 规则或备份策略。
- 不新增多平台（Linux / Intel macOS）支持。
- 不把根目录临时下载目录长期纳入仓库布局。
- 本次不强制对本机真实 `cli.js` 执行 apply；验收以 fixture、提取冒烟和既有 shell 测试为准。

## 4. Three-way Diff Findings

| 版本 | 路径/来源 | Gate 行为 |
|---|---|---|
| pre-our | `0ddf1d1^` 归档 | 仅接受 3-call `A()&&B()&&C()` |
| ours 当前 | `original-scripts/.../apply-....sh`（`0ddf1d1`） | 内联接受 2-call 或 3-call；注释写 `2.1.217+` |
| upstream 新 | `claude-code-enable-voice-mode-darwin-arm64 2/` | 抽出 `isVoiceGateAndChain()`；接受 2/3-call；要求 AND 叶子全是零参调用；注释写 `2.1.212+` |

结论：

1. **功能面已对齐**：我们先前修复与上游目标相同（支持 2-call + 3-call voice UI gate）。
2. **上游是等价重构，略更严格**：`isVoiceGateAndChain` 额外要求 `calls.length === parts.length`（AND 链中不得夹杂非零参调用叶子）。
3. **`cometix-asr/` 四文件 MD5 完全一致**，无运行时二进制差异。
4. **独立脚本的 legacy 备份块仍存在**，`write_patch_script_voice_mode` 的字符串替换继续可用。
5. **现有 `tests/test_voice_mode_gate.sh` 的源码字符串断言会失败**：它硬匹配 `calls.length === 2`，而上游改为 helper 内的 `calls.length !== 2 && calls.length !== 3`。

## 5. Chosen Approach

**以上游新版为权威源，整文件替换归档脚本；同步收紧/更新 gate 测试；清理临时目录。**

不采用：

- 保留我们内联 2-call 补丁、丢弃上游：会与上游分叉，违背“旧版失效、要更新”的意图。
- 手工 cherry-pick helper 到我们文件：最终与整文件替换几乎相同，但增加维护分叉成本。

## 6. File Changes

### 6.1 源脚本（必须）

用上游全文覆盖：

```text
original-scripts/claude-code-enable-voice-mode-darwin-arm64/apply-claude-code-enable-voice-mode.sh
```

来源：

```text
claude-code-enable-voice-mode-darwin-arm64 2/apply-claude-code-enable-voice-mode.sh
```

覆盖后不手工再叠我们的 `0ddf1d1` 注释；上游注释（`2.1.212+`）与 helper 即为新基线。

### 6.2 cometix-asr（可选对齐）

MD5 已一致。实施时可：

- **默认**：不改 `cometix-asr/` 文件内容（避免无意义二进制噪声）；或
- **可选**：用上游目录再覆盖一次，仅对齐归档来源，行为不变。

两种都不影响验收。推荐默认不改，除非需要“整包来源一致”的审计观感。

### 6.3 Gate 测试（必须）

更新 `tests/test_voice_mode_gate.sh`：

1. **保留** 2-call / 3-call fixture 的行为断言：`write_patch_script voice-mode` → `node … --check` 必须对两种 shape 输出 `FOUND:voiceGateVmr` 与 `NEEDS_PATCH`，且不得出现 `AST miss: voiceGate`。
2. **替换** 源码字符串硬匹配：
   - 旧：要求引擎文本含 `calls.length === 2`（或宽松 regex）。
   - 新：要求引擎文本含 `isVoiceGateAndChain`，并且仍能表达“接受 2 与 3”的约束（例如 helper 内 `calls.length !== 2 && calls.length !== 3`，或等价注释/条件）。
3. 不得再把“仅接受恰好 3-call”的旧逻辑当作失败条件的唯一依据。

### 6.4 临时目录（必须清理）

实施完成且测试通过后，删除未跟踪的：

```text
claude-code-enable-voice-mode-darwin-arm64 2/
```

不提交该目录。正式源只保留在 `original-scripts/`。

### 6.5 管理器壳层（明确不改）

以下保持现状：

- `voice_mode_source_dir` → `original-scripts/.../cometix-asr`
- `write_patch_script_voice_mode` 提取路径与 baseline rewrite
- `voice_mode_supported` / assets 预检 / `install_voice_mode_vendor`
- `PATCH_IDS` 与 UI 文案

## 7. Application / Data Flow（不变，仅源内容变）

```text
run_node_patch voice-mode
  → platform + assets 预检
  → apply 时 install_voice_mode_vendor
  → write_patch_script_voice_mode
       读取 original-scripts/.../apply-....sh
       提取 PATCH_EOF 引擎
       将独立 timestamp backup 改写为 CC_PATCH_SKIP_BACKUP / baseline
  → node 引擎 check/apply
```

刷新后唯一变化是提取出的引擎 gate 段使用 `isVoiceGateAndChain`。

## 8. Error Handling

- 若新源缺少 `PATCH_EOF` 边界或 legacy backup 块：`write_patch_script_voice_mode` 必须继续失败并给出现有错误信息；实施时先做提取/rewrite 冒烟，失败则停止覆盖提交。
- 若 fixture 仍 `AST miss: voiceGate`：视为合入失败，不得宣称完成。
- 真实 Claude Code 版本若出现新的 gate shape（非 2/3 零参 AND）：仍按既有语义报 `NOT_FOUND` / 验证失败，不在本次扩大匹配面。

## 9. Validation

实施时至少执行：

1. `bash -n cc-patch-manager.sh`
2. 从新源提取引擎：确认含 `isVoiceGateAndChain`；对提取结果执行与 `write_patch_script_voice_mode` 相同的 baseline rewrite，必须成功。
3. `bash tests/test_voice_mode_gate.sh`
4. `bash tests/test_voice_mode_platform.sh`
5. `git status`：仅预期变更（源脚本、gate 测试；可选 cometix）；无 `… 2/` 残留；无意外修改 `cc-patch-manager.sh`。

## 10. Risks

| 风险 | 缓解 |
|---|---|
| 测试只改字符串、行为回归 | 保留 2-call/3-call fixture 的 `node --check` 行为断言为主证据 |
| 上游以后再改 backup 块格式 | 提取后 rewrite 冒烟；失败即停 |
| 误把临时目录提交进 Git | 验收检查 `git status`，显式删除 `… 2/` |
| 与我们 `0ddf1d1` 注释分叉造成审计困惑 | 本 spec 记录三方差异；合入后以上游为唯一注释基线 |

## 11. Implementation Notes for Plan

建议实施顺序：

1. 用测试锁定：先改 `test_voice_mode_gate.sh` 的字符串断言（此时对旧源可能仍因缺少 `isVoiceGateAndChain` 失败，或先写“接受旧或新”的过渡断言——计划阶段选定一种；推荐直接断言新 helper，再替换源脚本使测试变绿）。
2. 整文件复制上游脚本到 `original-scripts/.../apply-....sh`。
3. 跑提取 rewrite 冒烟 + 两套 voice 测试。
4. 删除临时目录。
5. 按仓库惯例提交（docs 可先单独提交；实现提交与测试同批或分批，由 plan 决定）。
