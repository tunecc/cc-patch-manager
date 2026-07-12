# Patch Manager Copy Rewrite Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rewrite user-facing Chinese copy in `cc-patch-manager.sh` so names read as capabilities, list notes as user-facing symptoms, and detail pages as phenomenon + changes — matching the approved design and original author post narrative.

**Architecture:** Single-file string replacement only. Touch `patch_name`, `patch_note`, `patch_purpose`, and a one-line `usage` blurb. No logic, registry order, apply scripts, or status vocabulary changes.

**Tech Stack:** Bash (`cc-patch-manager.sh`); verification via `bash -n`, `grep`, and function source extraction.

## Global Constraints

- Scope: **only** `cc-patch-manager.sh` user-visible Chinese strings
- Do **not** modify any `apply-claude-code-*.sh`
- Do **not** change `PATCH_IDS` order: `auto-mode` → `keybindings` → `transcript-dialog` → `ultracode`
- Do **not** change status labels, menu keybinds, backup strategy, or apply/restore logic
- Detail copy: no `fail-open`, no AST/acorn, no internal function names
- Keep user-operable terms: `CLAUDE_CLASSIFIER_MODEL`, `~/.claude/keybindings.json`, Escape / Ctrl+C
- Spec source of truth: `docs/superpowers/specs/2026-07-12-patch-copy-rewrite-design.md` §5

## File Map

| File | Role |
|------|------|
| `cc-patch-manager.sh` | **Modify** — only `patch_name` / `patch_note` / `patch_purpose` / `usage` |
| `docs/superpowers/specs/2026-07-12-patch-copy-rewrite-design.md` | Read-only reference |
| `apply-claude-code-*.sh` | **Do not touch** |

---

### Task 1: Replace registry display copy and usage blurb

**Files:**
- Modify: `cc-patch-manager.sh:31-117` (`patch_name`, `patch_note`, `patch_purpose`, `usage`)
- Test: shell checks below (no separate test file)

**Interfaces:**
- Consumes: existing function names `patch_name` / `patch_note` / `patch_purpose` / `usage` (signatures unchanged)
- Produces: same functions, new string bodies only

- [ ] **Step 1: Confirm current anchors still match**

Run from repo root:

```bash
sed -n '31,117p' cc-patch-manager.sh
```

Expected: see old names (`自动模式`, `快捷键`, `会话记录弹窗`), old notes containing `fail-open`, old purposes starting with `三处补丁` / `两处补丁`, and `usage` without the community-blurb line.

- [ ] **Step 2: Replace `patch_name`**

In `cc-patch-manager.sh`, replace the entire `patch_name` function with:

```bash
patch_name() {
  case "$1" in
    auto-mode) echo "自动模式解锁" ;;
    keybindings) echo "快捷键与 Ctrl+C" ;;
    transcript-dialog) echo "权限弹窗重放" ;;
    ultracode) echo "Ultracode 解锁" ;;
    *) echo "$1" ;;
  esac
}
```

- [ ] **Step 3: Replace `patch_note`**

Replace the entire `patch_note` function with:

```bash
patch_note() {
  case "$1" in
    auto-mode) echo "非默认模型也能开 Auto；分类器可改用 Haiku" ;;
    keybindings) echo "开自定义快捷键；Ctrl+C 退出，Esc 才中断" ;;
    transcript-dialog) echo "Ctrl+O 看会话时审批卡 Waiting… / 被中断" ;;
    ultracode) echo "在只支持 max、不支持 xhigh 的模型上启用" ;;
    *) echo "" ;;
  esac
}
```

- [ ] **Step 4: Replace `patch_purpose`**

Replace the entire `patch_purpose` function with:

```bash
patch_purpose() {
  case "$1" in
    auto-mode)
      cat <<'EOF'
现象：部分模型（如早期 Opus 4.6）进不了 Auto Mode；分类器常跟主对话
用同一模型，贵且易 429，作者实践里 Haiku 更稳。

改动：
  (1) 放开自动模式的模型资格检查
  (2) 分类器暂时不可用时改为询问，而不是直接拒绝
  (3) 支持环境变量 CLAUDE_CLASSIFIER_MODEL 指定分类模型
EOF
      ;;
    keybindings)
      cat <<'EOF'
现象：自定义快捷键被功能开关关掉；且 2.1.x 起 Ctrl+C 默认直接打断
Agent（旧版更像「再按一次才退出」），习惯旧行为的人容易误触。

改动：
  (1) 强制开启自定义快捷键（~/.claude/keybindings.json）
  (2) 默认 Ctrl+C 改为退出程序；中断 Agent 仍用 Escape
EOF
      ;;
    transcript-dialog)
      cat <<'EOF'
现象：从约 2.1.140+ 起，在 Ctrl+O 会话记录视图时若触发权限审批，
会一直 Waiting…；反过来在审批将出时切视图，也可能直接中断对话。

改动：
  (1) 权限弹窗通道记住待处理请求，宿主挂载后可重放
  (2) 切换会话记录界面时不取消待审批
EOF
      ;;
    ultracode)
      cat <<'EOF'
现象：Ultracode 默认要求 xhigh；只支持 max 的模型（如 4.6 系）
进不去，或努力度被降成 high 导致 ultracode 实际不生效。

改动：
  (1) 支持 max 的模型也可进入 ultracode
  (2) xhigh 不可用时优先落到 max（而不是 high）
  (3) 激活检查把 max 也算作有效 ultracode 努力度
EOF
      ;;
  esac
}
```

- [ ] **Step 5: Add optional usage blurb**

Replace the entire `usage` function with:

```bash
usage() {
  cat <<EOF
Claude Code 补丁管理器 v${VERSION}
四个社区常用 Claude Code 本地补丁的统一管理（中文交互）。

用法:
  $(basename "$0")                  进入交互菜单
  $(basename "$0") /path/to/cli.js  指定目标后进入菜单
  $(basename "$0") --check          打印四个补丁状态后退出
  $(basename "$0") --help           显示本帮助

环境变量:
  CLAUDE_CLI_PATH   若文件存在则优先作为 cli.js 路径
EOF
}
```

- [ ] **Step 6: Syntax check**

```bash
bash -n cc-patch-manager.sh
```

Expected: no output, exit code 0.

- [ ] **Step 7: Assert display strings (source the registry helpers only)**

```bash
# Extract just the four helper functions + call them without running the full manager
bash <<'VERIFY'
set -euo pipefail
# Pull lines for the four functions by re-evaluating the edited bodies via sed range
# Safer: source a snippet — define functions by evaluating the file's function defs only.
eval "$(sed -n '/^patch_name()/,/^}/p; /^patch_note()/,/^}/p; /^patch_purpose()/,/^}/p' cc-patch-manager.sh)"

test "$(patch_name auto-mode)" = "自动模式解锁"
test "$(patch_name keybindings)" = "快捷键与 Ctrl+C"
test "$(patch_name transcript-dialog)" = "权限弹窗重放"
test "$(patch_name ultracode)" = "Ultracode 解锁"

test "$(patch_note auto-mode)" = "非默认模型也能开 Auto；分类器可改用 Haiku"
test "$(patch_note keybindings)" = "开自定义快捷键；Ctrl+C 退出，Esc 才中断"
test "$(patch_note transcript-dialog)" = "Ctrl+O 看会话时审批卡 Waiting… / 被中断"
test "$(patch_note ultracode)" = "在只支持 max、不支持 xhigh 的模型上启用"

auto_p=$(patch_purpose auto-mode)
key_p=$(patch_purpose keybindings)
tr_p=$(patch_purpose transcript-dialog)
ultra_p=$(patch_purpose ultracode)

# required phrases
printf '%s' "$auto_p" | grep -q 'CLAUDE_CLASSIFIER_MODEL'
printf '%s' "$auto_p" | grep -q '现象：'
printf '%s' "$auto_p" | grep -q '改动：'
printf '%s' "$key_p" | grep -q 'keybindings.json'
printf '%s' "$key_p" | grep -q 'Escape'
printf '%s' "$tr_p" | grep -q 'Waiting…'
printf '%s' "$tr_p" | grep -q '重放'
printf '%s' "$ultra_p" | grep -q 'xhigh'
printf '%s' "$ultra_p" | grep -q 'max'

# forbidden in purpose text
! printf '%s' "$auto_p$key_p$tr_p$ultra_p" | grep -q 'fail-open'
! printf '%s' "$auto_p$key_p$tr_p$ultra_p" | grep -qi 'acorn'
! printf '%s' "$auto_p$key_p$tr_p$ultra_p" | grep -q 'AST'
! printf '%s' "$auto_p$key_p$tr_p$ultra_p" | grep -q 'tengu_keybinding'
! printf '%s' "$auto_p$key_p$tr_p$ultra_p" | grep -q 'app:interrupt'
! printf '%s' "$auto_p$key_p$tr_p$ultra_p" | grep -q 'app:exit'

# usage blurb present
./cc-patch-manager.sh --help | grep -q '四个社区常用 Claude Code 本地补丁的统一管理'

# apply scripts untouched in this working tree relative to HEAD for those paths
# (if already dirty for other reasons, at least ensure we did not edit them now)
git diff --name-only | grep -E 'apply-claude-code-' && exit 1 || true

echo "ALL COPY CHECKS PASSED"
VERIFY
```

Expected last line: `ALL COPY CHECKS PASSED`

- [ ] **Step 8: Smoke `--help` and name column width sanity**

```bash
./cc-patch-manager.sh --help
# name display widths (approx UTF-8 display; flag if any name is wildly long)
python3 - <<'PY'
names = ["自动模式解锁", "快捷键与 Ctrl+C", "权限弹窗重放", "Ultracode 解锁"]
notes = [
  "非默认模型也能开 Auto；分类器可改用 Haiku",
  "开自定义快捷键；Ctrl+C 退出，Esc 才中断",
  "Ctrl+O 看会话时审批卡 Waiting… / 被中断",
  "在只支持 max、不支持 xhigh 的模型上启用",
]
def dw(s):
    n = 0
    for ch in s:
        n += 2 if ord(ch) > 127 else 1
    return n
for n in names:
    w = dw(n)
    print(f"name width={w:2d}: {n}")
    assert w <= 16, n
for n in notes:
    w = dw(n)
    print(f"note width={w:2d}: {n}")
    assert w <= 60, n
print("WIDTH OK")
PY
```

Expected: help text shows new blurb; `WIDTH OK`.

- [ ] **Step 9: Commit**

```bash
git add cc-patch-manager.sh
git commit -m "$(cat <<'EOF'
fix(ui): rewrite patch names, notes, and purpose copy

Align manager list/detail text with author-post phenomena while
keeping apply logic and apply-*.sh scripts unchanged.
EOF
)"
```

---

## Spec Coverage Checklist (self-review)

| Spec item | Task |
|-----------|------|
| §5.1 `patch_name` | Task 1 Step 2 |
| §5.2 `patch_note` | Task 1 Step 3 |
| §5.3 `patch_purpose` | Task 1 Step 4 |
| §5.4 `usage` blurb | Task 1 Step 5 |
| §7.1 string match | Task 1 Step 7 |
| §7.2 list width | Task 1 Step 8 |
| §7.3 no fail-open/AST/fn names | Task 1 Step 7 |
| §7.4 keep env/path/keys | Task 1 Step 7 |
| §7.5 `bash -n` + no logic change | Task 1 Steps 6–7 |
| §7.6 no `apply-*.sh` | Task 1 Step 7 + commit scope |

## Placeholder / consistency scan

- No TBD/TODO left in steps
- Exact replacement bodies included (not “similar to spec”)
- Function names match existing code: `patch_name`, `patch_note`, `patch_purpose`, `usage`
