# VoiceMode 上游脚本刷新 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 用原作者新版 VoiceMode 脚本替换 `original-scripts` 归档源，并更新 gate 测试以锁定 `isVoiceGateAndChain` 契约。

**Architecture:** 管理器继续从 `original-scripts/claude-code-enable-voice-mode-darwin-arm64/apply-claude-code-enable-voice-mode.sh` 动态提取 AST 引擎并改写基线备份。本次只替换该源脚本全文，不改 `cc-patch-manager.sh` 壳层。测试先锁新 helper 契约（红），再替换源（绿），最后清理根目录临时下载目录。

**Tech Stack:** Bash、Node.js、现有 Acorn 引擎提取路径、Git。

**Spec:** `docs/superpowers/specs/2026-07-31-voice-mode-upstream-refresh-design.md`

## Global Constraints

- 正式源路径固定为 `original-scripts/claude-code-enable-voice-mode-darwin-arm64/`；不得改管理器内路径常量。
- 不修改 `cc-patch-manager.sh` 的平台门禁、vendor 安装、baseline rewrite 或其它补丁引擎。
- `cometix-asr/` 四文件与上游 MD5 已一致：默认不改，避免无意义二进制噪声。
- 根目录 `claude-code-enable-voice-mode-darwin-arm64 2/` 仅为临时输入，验收后必须删除且不得提交。
- 不强制对本机真实 `cli.js` 执行 apply；验收以 fixture、提取 rewrite 冒烟和既有 voice 测试为准。
- 合入后以上游注释与 `isVoiceGateAndChain` 为唯一 gate 基线，不再保留我们 `0ddf1d1` 的内联 2-call 注释形态。

---

### Task 1: 锁定上游 gate helper 测试契约

**Files:**

- Modify: `tests/test_voice_mode_gate.sh:95-100`
- Test: `tests/test_voice_mode_gate.sh`

**Interfaces:**

- Consumes: `write_patch_script voice-mode`（由 `cc-patch-manager.sh` 提供，内部调用 `write_patch_script_voice_mode` 从 `original-scripts/.../apply-claude-code-enable-voice-mode.sh` 提取引擎）。
- Produces: 测试断言引擎必须包含 `isVoiceGateAndChain`，并保留 2-call / 3-call fixture 的行为检查。

- [ ] **Step 1: 改写源码字符串断言为上游 helper 契约**

打开 `tests/test_voice_mode_gate.sh`，将文件末尾（约 95–100 行）从：

```bash
# Source engine must document 2-call support and not hard-require exactly 3 calls only.
engine=$(write_patch_script voice-mode)
grep -Fq 'calls.length === 2' "$engine" || grep -Eq 'calls\.length (===|==) 2|calls\.length >= 2' "$engine" || fail "engine must accept 2-call voice gates"
if grep -Fq 'if (calls.length === 3)' "$engine" && ! grep -Eq 'calls\.length === 2|calls\.length >= 2|calls\.length == 2' "$engine"; then
  fail "engine still only accepts exactly 3-call voice gates"
fi
rm -f "$engine"
```

替换为：

```bash
# Upstream engine must expose isVoiceGateAndChain and accept 2- or 3-call zero-arg AND gates.
engine=$(write_patch_script voice-mode)
grep -Fq 'function isVoiceGateAndChain' "$engine" || fail "engine must define isVoiceGateAndChain"
grep -Fq 'calls.length !== 2 && calls.length !== 3' "$engine" || fail "engine must accept 2-call and 3-call voice gates via isVoiceGateAndChain"
if grep -Fq 'if (calls.length === 3)' "$engine" && ! grep -Fq 'isVoiceGateAndChain' "$engine"; then
  fail "engine still only accepts exactly 3-call voice gates"
fi
rm -f "$engine"
```

保留其上的 `assert_voice_check` 对 `voice-2call.js` / `voice-3call.js` 的行为断言不变。

- [ ] **Step 2: 运行测试，确认在旧源上失败**

Run:

```bash
bash tests/test_voice_mode_gate.sh
```

Expected: 非零退出；输出包含 `engine must define isVoiceGateAndChain`（当前 `original-scripts` 仍是我们内联 2-call 版，没有该 helper）。若 2-call/3-call 行为断言先失败，同样视为红灯，但本任务预期主失败点是 helper 字符串。

- [ ] **Step 3: 提交失败测试（锁定契约）**

```bash
git add tests/test_voice_mode_gate.sh
git commit -m "$(cat <<'EOF'
test: lock voice gate helper contract for upstream refresh

Require isVoiceGateAndChain and 2/3-call acceptance in the
extracted voice-mode engine before replacing the archived source.
EOF
)"
```

---

### Task 2: 替换归档源脚本并验收

**Files:**

- Modify: `original-scripts/claude-code-enable-voice-mode-darwin-arm64/apply-claude-code-enable-voice-mode.sh`（整文件替换）
- Delete (untracked): `claude-code-enable-voice-mode-darwin-arm64 2/`
- Test: `tests/test_voice_mode_gate.sh`、`tests/test_voice_mode_platform.sh`
- Do not modify: `cc-patch-manager.sh`、`original-scripts/.../cometix-asr/*`

**Interfaces:**

- Consumes: 上游包  
  `claude-code-enable-voice-mode-darwin-arm64 2/apply-claude-code-enable-voice-mode.sh`
- Produces: 归档源与上游一致；`write_patch_script_voice_mode` 提取出含 `isVoiceGateAndChain` 的引擎，且 baseline rewrite 成功。

- [ ] **Step 1: 整文件覆盖归档源脚本**

在仓库根目录执行（路径含空格与尾部 `2`，必须加引号）：

```bash
cp "/Users/tune/Develop/GitHub/cc-patch-manager/claude-code-enable-voice-mode-darwin-arm64 2/apply-claude-code-enable-voice-mode.sh" \
  "/Users/tune/Develop/GitHub/cc-patch-manager/original-scripts/claude-code-enable-voice-mode-darwin-arm64/apply-claude-code-enable-voice-mode.sh"
chmod +x "/Users/tune/Develop/GitHub/cc-patch-manager/original-scripts/claude-code-enable-voice-mode-darwin-arm64/apply-claude-code-enable-voice-mode.sh"
```

不要复制或改动 `cometix-asr/`（MD5 已一致）。

- [ ] **Step 2: 提取 + baseline rewrite 冒烟**

```bash
ROOT="/Users/tune/Develop/GitHub/cc-patch-manager"
tmp=$(mktemp -d)
source "$ROOT/cc-patch-manager.sh"
engine=$(write_patch_script voice-mode)
grep -Fq 'function isVoiceGateAndChain' "$engine"
grep -Fq 'CC_PATCH_SKIP_BACKUP' "$engine"
grep -Fq 'cc-patch-baseline' "$engine"
rm -f "$engine"
rm -rf "$tmp"
bash -n "$ROOT/cc-patch-manager.sh"
```

Expected:

- 无报错退出。
- 提取引擎含 `function isVoiceGateAndChain`。
- 提取引擎已被 rewrite 为含 `CC_PATCH_SKIP_BACKUP` 与 `cc-patch-baseline`（证明 legacy backup 块仍被成功替换）。
- `bash -n` 通过。

若 `write_patch_script voice-mode` 报“转换 VoiceMode 基线备份逻辑失败”或“提取 VoiceMode AST 引擎失败”：停止，不要提交，先对照上游脚本的 `PATCH_EOF` 边界与 backup 块。

- [ ] **Step 3: 跑 voice 相关测试**

```bash
bash tests/test_voice_mode_gate.sh
bash tests/test_voice_mode_platform.sh
```

Expected:

- `test_voice_mode_gate.sh` 退出 0，输出  
  `PASS: voice-mode gate detector accepts 2-call and 3-call shapes`
- `test_voice_mode_platform.sh` 退出 0（平台门禁 / 资源路径 / 既有集成断言仍绿）

- [ ] **Step 4: 删除临时上游下载目录**

```bash
rm -rf "/Users/tune/Develop/GitHub/cc-patch-manager/claude-code-enable-voice-mode-darwin-arm64 2"
```

- [ ] **Step 5: 检查 git 状态仅含预期变更**

```bash
git status --short
git diff --stat
```

Expected:

- 已修改：`original-scripts/claude-code-enable-voice-mode-darwin-arm64/apply-claude-code-enable-voice-mode.sh`
- 不应出现：`cc-patch-manager.sh` 变更、`… 2/` 残留、`cometix-asr` 无意义改动（除非你有意覆盖）
- Task 1 的测试提交应已在历史中；工作区可只剩源脚本 diff（若测试已提交）

- [ ] **Step 6: 提交源脚本刷新**

```bash
git add original-scripts/claude-code-enable-voice-mode-darwin-arm64/apply-claude-code-enable-voice-mode.sh
git commit -m "$(cat <<'EOF'
fix: refresh voice mode source from upstream gate helper

Replace the archived apply script with the upstream isVoiceGateAndChain
detector so 2-call and 3-call voice UI gates stay in sync with author.
EOF
)"
```

- [ ] **Step 7: 最终验收**

```bash
bash tests/test_voice_mode_gate.sh
bash tests/test_voice_mode_platform.sh
git status --short
```

Expected:

- 两测试均 PASS
- 工作区干净（或仅有与本任务无关的既有未跟踪项，但不得再有 `claude-code-enable-voice-mode-darwin-arm64 2/`）

---

## Self-Review (plan author)

1. **Spec coverage**
   - 源脚本整文件替换 → Task 2 Step 1
   - gate 测试改 helper 断言 → Task 1
   - 提取 + baseline rewrite 冒烟 → Task 2 Step 2
   - `test_voice_mode_gate` / `test_voice_mode_platform` → Task 2 Step 3/7
   - 清理临时目录 → Task 2 Step 4
   - 不改管理器壳层 / 默认不改 cometix → Global Constraints + Task 2 Files
2. **No placeholders** — 路径、替换代码块、命令、期望输出均已写死。
3. **TDD order** — Task 1 先红锁契约并提交；Task 2 换源变绿。
4. **Consistency** — 正式源与提取路径始终为 `original-scripts/claude-code-enable-voice-mode-darwin-arm64/`。
