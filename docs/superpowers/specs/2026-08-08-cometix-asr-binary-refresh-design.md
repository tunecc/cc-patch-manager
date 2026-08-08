# Claude Code 补丁管理器 — Cometix ASR 原生二进制刷新 Design Spec

**Date:** 2026-08-08  
**Status:** 已确认（方案 A：仅同步归档源二进制）  
**Scope:** `original-scripts/claude-code-enable-voice-mode-darwin-arm64/cometix-asr/libcometix-asr.darwin-arm64.node`、根目录临时下载目录

## 1. Problem

仓库归档的 VoiceMode 原生 ASR 模块滞后于作者新修复：

```text
original-scripts/claude-code-enable-voice-mode-darwin-arm64/cometix-asr/libcometix-asr.darwin-arm64.node
MD5 fac8ccfca54edba6e4eb1c389d3dc2ac（旧，2825936 B）
```

作者新下载包与本机真实安装均使用新二进制：

```text
claude-code-enable-voice-mode-darwin-arm64 (2)/cometix-asr/libcometix-asr.darwin-arm64.node
MD5 75aa2da47fc97a6975fc424c407682d4（新，2958112 B）
/opt/homebrew/lib/node_modules/@cometix/claude-code/vendor/cometix-asr/libcometix-asr.darwin-arm64.node
MD5 75aa2da47fc97a6975fc424c407682d4（新，已在 Aug 7 部署并运行）
```

管理器 `install_voice_mode_vendor` 在 apply 时以 `original-scripts/.../cometix-asr/` 为部署真相源。归档源不更新，会导致换机 / 重装时又装回旧版。

**三方文件一致性：** `apply-claude-code-enable-voice-mode.sh`、`index.js`、`index.d.ts`、`package.json` 四个文本文件在归档源与新包间**字节完全一致**（MD5 逐一相同），唯一差异即上述原生二进制。

## 2. Goal

将归档源原生二进制同步到作者新修复版，使管理器自动部署的新版与本机已验证版本一致。

成功后：

1. `original-scripts/.../cometix-asr/libcometix-asr.darwin-arm64.node` MD5 = `75aa2da4…`。
2. 新二进制可被 `node -e require(...)` 加载冒烟通过（`startSession` 等 API 面完整）。
3. `bash tests/test_voice_mode_gate.sh` 与 `bash tests/test_voice_mode_platform.sh` 全绿。
4. 根目录临时下载目录 `claude-code-enable-voice-mode-darwin-arm64 (2)/` 被清理，工作区无残留。

## 3. Non-Goals

- 不修改本机真实安装（`/opt/homebrew/...` 已部署新版，无需动）。
- 不改 `cc-patch-manager.sh` 壳层、资源路径、平台门禁、vendor 安装或备份 rewrite。
- 不替换 4 个字节一致的文本文件（避免无意义二进制噪声）。
- 不新增 Linux / Intel macOS 支持。
- 闭源 Rust 二进制不做源码级 diff；行为差异以本机真实运行（已用新版）为证据。

## 4. Approach（选定：方案 A）

仅做一次二进制覆盖：

```text
source: claude-code-enable-voice-mode-darwin-arm64 (2)/cometix-asr/libcometix-asr.darwin-arm64.node
target: original-scripts/claude-code-enable-voice-mode-darwin-arm64/cometix-asr/libcometix-asr.darwin-arm64.node
```

不采用整包覆盖（会引入无意义 diff / 二进制噪声，破坏 git 可读性）；不采用重 apply 真实安装（冗余且无收益风险）。

## 5. File Changes

### 5.1 源二进制（必须）

复制上述目标路径，保留可执行位。

### 5.2 临时目录（必须清理）

实施完成且测试通过后，删除未跟踪的 `claude-code-enable-voice-mode-darwin-arm64 (2)/`，不提交该目录。

### 5.3 管理器壳层（明确不改）

- `voice_mode_source_dir` → `original-scripts/.../cometix-asr`
- `install_voice_mode_vendor` 部署 + `require` 加载检查
- `write_patch_script_voice_mode` 提取路径与 baseline rewrite
- platform 门禁、资源预检、备份逻辑

## 6. Data Flow（不变）

```text
apply voice-mode
  → voice_mode_platform_supported? + assets 预检
  → install_voice_mode_vendor：复制 original-scripts/.../cometix-asr/*.{node,js,d.ts,json} → $CLI_DIR/vendor/cometix-asr
  → node -e require(index.js) 冒烟
  → write_patch_script_voice_mode 提取 AST 引擎 → node check/apply
```

刷新后唯一变化是部署出的 `.node` 为新版本。

## 7. Verification

实施时至少执行：

1. `bash -n cc-patch-manager.sh`
2. 新二进制加载冒烟：`node -e 'const m=require(process.argv[1]); if(typeof m.startSession!=="function") process.exit(2)' cometix-asr/index.js`（已在方案确认阶段完成，OK）
3. `bash tests/test_voice_mode_gate.sh`
4. `bash tests/test_voice_mode_platform.sh`
5. `md5` 对比保证归档源 MD5 = `75aa2da4…`
6. `git status --short`：仅预期变更（二进制）；无 `… 2/` 残留；无意外修改 `cc-patch-manager.sh` 或文本文件

## 8. Risks

| 风险 | 缓解 |
|---|---|
| 新二进制行为回归 | 加载冒烟 + 本机真实安装已用该版本运行（Aug 7 部署）为最佳证据 |
| 误把临时目录提交进 Git | 验收检查 `git status`，显式删除。未跟踪目录不会被 `git add` 遗漏 |
| 覆盖后 MD5 不一致 | 复制后立即 md5 复核 |

## 9. Commit

```text
fix: refresh cometix-asr native binary from upstream

Sync the archived VoiceMode ASR addon to the author's updated build
(MD5 75aa2da4…) so install_voice_mode_vendor deploys the same binary
already verified on this machine.
```