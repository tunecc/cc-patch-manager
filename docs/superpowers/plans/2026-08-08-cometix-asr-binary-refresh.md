# Cometix ASR 原生二进制刷新 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把 Author 新版 Cometix ASR 原生二进制（MD5 `75aa2da4…`）覆盖进归档源，使 `install_voice_mode_vendor` 部署的二进制与本机已验证版本一致。

**Architecture:** 唯一变更是一个二进制资产替换——从临时包 `claude-code-enable-voice-mode-darwin-arm64 (2)/` 复制 `libcometix-asr.darwin-arm64.node` 覆盖 `original-scripts/.../cometix-asr/` 同名文件，随后加载冒烟 + 既有 voice 测试验证，清理临时目录并提交。`cc-patch-manager.sh` 壳层与 4 个字节一致的文本文件一律不动。

**Tech Stack:** Bash、Node.js（加载冒烟）、Git。

## Global Constraints

- 目标路径固定：`original-scripts/claude-code-enable-voice-mode-darwin-arm64/cometix-asr/libcometix-asr.darwin-arm64.node`；不得改管理器路径常量。
- 源临时包（本次输入）为仓库根未跟踪目录 `claude-code-enable-voice-mode-darwin-arm64 (2)/`；验收后必须删除且不得提交。
- 不修改 `cc-patch-manager.sh`、`apply-claude-code-enable-voice-mode.sh`、`index.js`、`index.d.ts`、`package.json`（已字节一致）。
- 不触碰本机真实安装 `/opt/homebrew/.../vendor/cometix-asr`（已部署新版）。
- 复制后目标二进制 MD5 必须为 `75aa2da47fc97a6975fc424c407682d4`，且保留可执行位（`-rwxr-xr-x`）。
- 提交按仓库惯例单条：`fix: refresh cometix-asr native binary from upstream`。

---

### Task 1: 替换归档源二进制并验收

**Files:**
- Modify: `original-scripts/claude-code-enable-voice-mode-darwin-arm64/cometix-asr/libcometix-asr.darwin-arm64.node`（整文件替换）
- Delete (untracked): `claude-code-enable-voice-mode-darwin-arm64 (2)/`
- Test: `tests/test_voice_mode_gate.sh`、`tests/test_voice_mode_platform.sh`
- Do not modify: `cc-patch-manager.sh`、`original-scripts/.../apply-claude-code-enable-voice-mode.sh`、`original-scripts/.../cometix-asr/{index.js,index.d.ts,package.json}`

**Interfaces:**
- Consumes: 临时包内的新二进制  
  `claude-code-enable-voice-mode-darwin-arm64 (2)/cometix-asr/libcometix-asr.darwin-arm64.node`（MD5 `75aa2da47fc97a6975fc424c407682d4` 已核对）
- Produces: 归档源二进制同款 MD5 `75aa2da47fc97a6975fc424c407682d4`；管理器 `install_voice_mode_vendor` 输出同款 `.node`（本任务不改该函数，仅资产变更）

- [ ] **Step 1: 前置检查——当前状态**

在仓库根目录 `/Users/tune/Develop/GitHub/cc-patch-manager` 执行：

```bash
git log --oneline -1
git status --short
md5 -q "original-scripts/claude-code-enable-voice-mode-darwin-arm64/cometix-asr/libcometix-asr.darwin-arm64.node"
md5 -q "claude-code-enable-voice-mode-darwin-arm64 (2)/cometix-asr/libcometix-asr.darwin-arm64.node"
```

Expected:
- HEAD 为 `1dcddb2 docs: design cometix asr binary refresh`
- `git status --short` 仅显示未跟踪 `claude-code-enable-voice-mode-darwin-arm64 (2)/`
- 归档源 MD5 = `fac8cccf…`（旧），临时包 MD5 = `75aa2da4…`（新）

若不一致则停止，先报告实际状态，不要覆盖。

- [ ] **Step 2: 新二进制加载冒烟（可选重跑，延续设计阶段已完成验证）**

```bash
cd "claude-code-enable-voice-mode-darwin-arm64 (2)/cometix-asr" && node -e 'const m=require(process.argv[1]);if(typeof m.startSession!=="function"){process.exit(2)}console.log("loadOk")' ./index.js
```

Expected: 退出码 0 且打印 `loadOk`。API 面（`startSession/feedPcm/finalizeSession/closeSession` 等）完整。

（本步已在设计方案确认阶段跑通过，作为 final Gate 重跑一次即可。）

- [ ] **Step 3: 覆盖归档源二进制**

路径含空格，必须加引号。在仓库根目录执行：

```bash
cp -p "claude-code-enable-voice-mode-darwin-arm64 (2)/cometix-asr/libcometix-asr.darwin-arm64.node" \
      "original-scripts/claude-code-enable-voice-mode-darwin-arm64/cometix-asr/libcometix-asr.darwin-arm64.node"
chmod +x "original-scripts/claude-code-enable-voice-mode-darwin-arm64/cometix-asr/libcometix-asr.darwin-arm64.node"
```

Expected:
- 归档源文件变为 **2958112 B**，`-rwxr-xr-x`。

- [ ] **Step 4: md5 复核**

```bash
md5 -q "original-scripts/claude-code-enable-voice-mode-darwin-arm64/cometix-asr/libcometix-asr.darwin-arm64.node"
```

Expected: `75aa2da47fc97a6975fc424c407682d4`（与临时包、本机 vendor 一致）。不匹配则回滚复制并停止。

- [ ] **Step 5: 静态检查管理器壳层**

```bash
bash -n cc-patch-manager.sh
```

Expected: 退出 0，无任何语法错误。此步确认未意外改动壳层。

- [ ] **Step 6: 跑 voice 相关测试**

```bash
bash tests/test_voice_mode_gate.sh
bash tests/test_voice_mode_platform.sh
```

Expected:
- `test_voice_mode_gate.sh` 退出 0，输出 `PASS: voice-mode gate detector accepts 2-call and 3-call shapes`
- `test_voice_mode_platform.sh` 退出 0（平台门禁 / 资源路径 / 集成断言全绿）

若任一失败：恢复旧二进制（`git checkout -- <归档源路径>`）后再排查，不得带红提交。

- [ ] **Step 7: 清理临时下载目录**

```bash
rm -rf "claude-code-enable-voice-mode-darwin-arm64 (2)"
```

（该目录为未跟踪临时输入，删除不属于危险操作；删除后 `git status` 应无任何残留。）

- [ ] **Step 8: 检查 git 状态仅含预期变更**

```bash
git status --short
git diff --stat
```

Expected:
- 已修改 1 项：`original-scripts/.../cometix-asr/libcometix-asr.darwin-arm64.node`
- 不应出现：`cc-patch-manager.sh` 变更、`… (2)/` 残留、任一文本文件变更、`docs/` 变更

- [ ] **Step 9: 提交**

```bash
git add "original-scripts/claude-code-enable-voice-mode-darwin-arm64/cometix-asr/libcometix-asr.darwin-arm64.node"
git commit -m "fix: refresh cometix-asr native binary from upstream"
```

- [ ] **Step 10: 最终验收**

```bash
bash tests/test_voice_mode_gate.sh
bash tests/test_voice_mode_platform.sh
git log --oneline -1
git status --short
```

Expected:
- 两测试均 PASS
- HEAD 为本次提交 `fix: refresh cometix-asr native binary from upstream`
- 工作区干净（无未跟踪项、无修改）

---

## Self-Review (plan author)

1. **Spec coverage** — spec 的 Goal(1-4) 全部落地：二进制覆盖（Step 3）、md5 复核(Step 4)、加载冒烟(Step 2)、两套 voice 测试(Step 6)、清理临时目录(Step 7)、工作区干净(Step 8/10)。Non-Goals 以 Global Constraints 显式约束（不改壳层 / 文本文件 / 真实安装）。
2. **No placeholders** — 每条命令、期望、失败回滚命令均已写死；无 TBD/TODO。
3. **Type/名一致性** — 路径常量在全部 Step 中书写一致；MD5 值在所有步骤中相同（`75aa2da47fc97a6975fc424c407682d4`）。测得。

4. **Scope** — 单一任务、单一提交，二进制的单文件资产替换，无需拆分子任务。