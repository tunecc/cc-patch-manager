# Context Limit Integration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 将 Bash 版 Context Limit 补丁作为第六项集成到统一管理器，并保留当前 Auto Mode 双形态检测器。

**Architecture:** 沿用现有补丁注册表和内嵌 Node/Acorn 引擎结构：上游 `.sh` 原样复制到 `original-scripts/`，管理器内移植 AST 引擎并增加统一基线备份与 AST 级幂等检测。Auto Mode 不替换实现，只用特征回归测试防止同步上游时降级。

**Tech Stack:** Bash、Node.js、Acorn 8.16.0、Git

## Global Constraints

- 只支持 Bash/Unix 路径；不复制、修改或执行任何 `.ps1` 文件。
- 不修改、移动或删除根目录的 `apply-claude-code-context-limit-patch/` 和 `apply-claude-code-enable-auto-mode/` 输入目录。
- 仅复制 `apply-claude-code-context-limit-patch/apply-claude-code-context-limit-patch.sh` 到 `original-scripts/`。
- `context-limit` 必须追加在现有五项之后，保持前五项菜单编号、备份后缀和行为不变。
- 未设置 `CLAUDE_CODE_CONTEXT_LIMIT` 时，补丁后的默认值必须仍为 `200000`。
- Context Limit 必须复用 `cli.js.cc-patch-baseline`，不得由管理器额外创建 `backup-ctxlimit-*` 时间戳备份。
- Auto Mode 保留 `oQqCandidatesLegacy`、`oQqCandidatesFlat` 和 `rankFlat`，不整体替换为重新发布版。
- 测试只操作临时 fixture，不检测或修改真实 Claude Code 安装。
- 不新增 npm、Homebrew 或 PowerShell 依赖；Acorn 继续通过管理器现有 `ensure_acorn` 路径获取。
- 根目录四个上游输入文件在实现前后的 SHA-256 必须保持：
  - Context Limit `.sh`：`3bd475fb9241704bfffc71523268fa7ab7afb7906abdd7d62ac03a19d41be9bc`
  - Context Limit `.ps1`：`7f5fb35918d38bacbac0cdbc43aea9e73a220ad44af8b044994ef2f18ec62c05`
  - Auto Mode `.sh`：`11b317d3bb2004e35402cba6a17fa0ab284ff526225714c17e2616feefd9ee7f`
  - Auto Mode `.ps1`：`bb2770b1c23c59f50330db8392ea16e360064a21a3d443ba16709c846ebfd300`

## File Map

- `cc-patch-manager.sh`：注册第六个补丁、展示文案、菜单范围、Context Limit Node/Acorn 引擎。
- `original-scripts/apply-claude-code-context-limit-patch.sh`：上游 Bash 脚本的原样留档，不承载管理器适配。
- `tests/test_context_limit_integration.sh`：注册信息、界面契约和 Context Limit 完整状态闭环。
- `tests/test_auto_mode_engine.sh`：锁定 Auto Mode 旧版/平铺版双检测器特征。
- `tests/test_voice_mode_platform.sh`：把帮助文案断言从五项改为六项。

---

### Task 1: 注册第六个补丁并更新界面契约

**Files:**
- Create: `tests/test_context_limit_integration.sh`
- Modify: `cc-patch-manager.sh:28-145`
- Modify: `cc-patch-manager.sh:2515-2535`
- Modify: `cc-patch-manager.sh:2730-2759`
- Modify: `tests/test_voice_mode_platform.sh:60-62`

**Interfaces:**
- Consumes: 现有 `PATCH_IDS`、`patch_name`、`patch_note`、`patch_suffix`、`patch_purpose` 和 `usage` 函数。
- Produces: id 为 `context-limit` 的第六项注册信息；数字 `6` 可进入该补丁详情页；后续任务可调用 `patch_suffix context-limit` 得到 `backup-ctxlimit`。

- [ ] **Step 1: 写注册与界面失败测试**

用 `apply_patch` 创建 `tests/test_context_limit_integration.sh`：

```bash
#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

assert_eq() {
  local actual="$1" expected="$2" label="$3"
  [[ "$actual" == "$expected" ]] || fail "$label: expected [$expected], got [$actual]"
}

source "$ROOT/cc-patch-manager.sh"

assert_eq "${PATCH_IDS[*]}" \
  "auto-mode keybindings transcript-dialog ultracode voice-mode context-limit" \
  "context-limit must be appended as patch six"
assert_eq "$(patch_name context-limit)" "上下文上限配置" "context-limit name"
assert_eq "$(patch_note context-limit)" \
  "通过 CLAUDE_CODE_CONTEXT_LIMIT 覆盖默认 200K 上限" \
  "context-limit note"
assert_eq "$(patch_suffix context-limit)" "backup-ctxlimit" "context-limit suffix"

purpose=$(patch_purpose context-limit)
[[ "$purpose" == *"CLAUDE_CODE_CONTEXT_LIMIT"* ]] || fail "purpose must document the env var"
[[ "$purpose" == *"默认仍为 200000"* ]] || fail "purpose must document the unchanged default"
[[ "$purpose" == *"服务端"* ]] || fail "purpose must document the server-side limit risk"

help=$("$ROOT/cc-patch-manager.sh" --help)
[[ "$help" == *"打印六个补丁状态后退出"* ]] || fail "help must report six patch statuses"
grep -Fq "[1-6] 选择补丁" "$ROOT/cc-patch-manager.sh" || fail "menu hint must accept 1-6"
grep -Fq '1|2|3|4|5|6)' "$ROOT/cc-patch-manager.sh" || fail "menu dispatch must accept choice 6"

printf 'PASS: context-limit registry and UI contract\n'
```

- [ ] **Step 2: 运行测试并确认因第六项尚未注册而失败**

Run:

```bash
bash tests/test_context_limit_integration.sh
```

Expected: FAIL，第一条错误包含 `context-limit must be appended as patch six`，实际 `PATCH_IDS` 仍只有五项。

- [ ] **Step 3: 在注册表中追加 Context Limit**

用 `apply_patch` 修改 `cc-patch-manager.sh` 注册区为：

```bash
PATCH_IDS=(auto-mode keybindings transcript-dialog ultracode voice-mode context-limit)
```

在四个 case 函数中分别加入：

```bash
# patch_name
context-limit) echo "上下文上限配置" ;;

# patch_note
context-limit) echo "通过 CLAUDE_CODE_CONTEXT_LIMIT 覆盖默认 200K 上限" ;;

# patch_suffix
context-limit) echo "backup-ctxlimit" ;;
```

在 `patch_purpose` 的 `voice-mode` 分支之后加入：

```bash
    context-limit)
      cat <<'EOF'
现象：Claude Code 在多处把上下文窗口上限固定为 200000，无法通过设置覆盖。

改动：
  (1) 支持环境变量 CLAUDE_CODE_CONTEXT_LIMIT 覆盖客户端限制
  (2) settings.json / --settings 中的 env 加载后会重新应用该值
  (3) 未设置或设置为 0 时默认仍为 200000

限制：这是客户端补丁，服务端可能拒绝过大的值；更大上下文也会增加费用、延迟和内存占用。
EOF
      ;;
```

- [ ] **Step 4: 更新帮助文案与菜单选择范围**

用 `apply_patch` 完成以下精确替换：

```bash
# usage
六个社区常用 Claude Code 本地补丁的统一管理（中文交互）。
  $(basename "$0") --check          打印六个补丁状态后退出

# draw_main
printf '[1-6] 选择补丁   [a] 一键应用全部   [b] 备份当前   [r] 刷新全部   [p] 换路径   [q] 退出\n'

# menu_loop
1|2|3|4|5|6)
  id="${PATCH_IDS[$((choice - 1))]}"
  show_detail "$id"
  ;;
```

- [ ] **Step 5: 更新 Voice Mode 帮助断言**

用 `apply_patch` 修改 `tests/test_voice_mode_platform.sh` 末尾为：

```bash
help=$("$ROOT/cc-patch-manager.sh" --help)
[[ "$help" == *"打印六个补丁状态后退出"* ]]
printf 'PASS: help reports six patch statuses\n'
```

- [ ] **Step 6: 运行注册测试和已有 Voice Mode 测试**

Run:

```bash
bash tests/test_context_limit_integration.sh
bash tests/test_voice_mode_platform.sh
```

Expected: 两个脚本均退出 0；输出分别包含 `PASS: context-limit registry and UI contract` 和 `PASS: help reports six patch statuses`。

- [ ] **Step 7: 提交注册与界面变更**

```bash
git add cc-patch-manager.sh tests/test_context_limit_integration.sh tests/test_voice_mode_platform.sh
git commit -m "feat: register context limit patch"
```

---

### Task 2: 移植 Context Limit 引擎并完成状态闭环

**Files:**
- Copy: `apply-claude-code-context-limit-patch/apply-claude-code-context-limit-patch.sh` → `original-scripts/apply-claude-code-context-limit-patch.sh`
- Modify: `cc-patch-manager.sh:534-595`
- Modify: `tests/test_context_limit_integration.sh`

**Interfaces:**
- Consumes: Task 1 的 `context-limit` id、`backup-ctxlimit` 后缀，以及现有 `run_node_patch`、`parse_and_set_status`、`baseline_path`、`restore_patch`。
- Produces: `write_patch_script_context_limit(out)`；`write_patch_script context-limit` 返回可执行的临时 Node 脚本；输出遵循 `NEEDS_PATCH`、`PATCH_COUNT`、`ALREADY_PATCHED`、`SUCCESS`、`NOT_FOUND` 和 `VERIFY_FAILED` 契约。

- [ ] **Step 1: 扩展测试，覆盖上游留档和完整生命周期**

用 `apply_patch` 在 `tests/test_context_limit_integration.sh` 现有 PASS 之前插入以下内容，并把最终 PASS 改成两条：

```bash
source_script="$ROOT/original-scripts/apply-claude-code-context-limit-patch.sh"
[[ -f "$source_script" ]] || fail "archived context-limit source is missing"
grep -Fq 'CLAUDE_CODE_CONTEXT_LIMIT' "$source_script" || fail "archived source lost its env marker"

engine=$(write_patch_script context-limit)
grep -Fq 'CLAUDE_CODE_CONTEXT_LIMIT' "$engine" || fail "generated engine lost its env marker"
grep -Fq 'ALREADY_PATCHED' "$engine" || fail "generated engine lacks idempotence marker"
grep -Fq 'CC_PATCH_SKIP_BACKUP' "$engine" || fail "generated engine lacks baseline adapter"
rm -f "$engine"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
CLI_PATH="$tmp/cli.js"
ACORN_PATH="$tmp/acorn.js"

cat >"$CLI_PATH" <<'JS'
#!/usr/bin/env node
let hookLimit=200000,toolLimit=200000;
function loadProjectEnv(env){for(const item of [])void item;Object.assign(process.env,env)}
function loadFlagEnv(env){Object.assign(process.env,env)}
function isLargeMessage(tokens){return tokens>200000}
console.log(hookLimit,toolLimit,isLargeMessage(1));
JS

before="$tmp/cli-before.js"
cp "$CLI_PATH" "$before"

run_node_patch context-limit check
assert_eq "${STATUS[context-limit]:-}" "idle" "initial context-limit status"
assert_eq "${MSG[context-limit]:-}" "需修补 3 处" "initial patch count"

run_node_patch context-limit apply
assert_eq "${STATUS[context-limit]:-}" "applied" "status after apply"
assert_eq "${MSG[context-limit]:-}" "已修补 5 处" "apply count includes two env loaders"

baseline="$CLI_PATH.cc-patch-baseline"
[[ -f "$baseline" ]] || fail "manager baseline was not created"
cmp -s "$baseline" "$before" || fail "baseline must preserve the unpatched fixture"
if compgen -G "$CLI_PATH.backup-ctxlimit-*" >/dev/null; then
  fail "manager must not create timestamp context-limit backups"
fi

env_ref_count=$(grep -o 'process.env.CLAUDE_CODE_CONTEXT_LIMIT' "$CLI_PATH" | wc -l | tr -d ' ')
assert_eq "$env_ref_count" "7" "patched env reference count"

node - "$ACORN_PATH" "$CLI_PATH" <<'NODE'
const fs = require('fs');
const acorn = require(process.argv[2]);
const code = fs.readFileSync(process.argv[3], 'utf8').replace(/^#![^\n]*\n/, '');
acorn.parse(code, { ecmaVersion: 'latest', sourceType: 'module' });
NODE

run_node_patch context-limit check
assert_eq "${STATUS[context-limit]:-}" "applied" "status after second check"
[[ "$LAST_OUTPUT" == *"ALREADY_PATCHED"* ]] || fail "second check must report ALREADY_PATCHED"
[[ "$LAST_OUTPUT" != *"NOT_FOUND"* ]] || fail "second check must not report NOT_FOUND"

after_first_apply="$tmp/cli-after-first-apply.js"
cp "$CLI_PATH" "$after_first_apply"
run_node_patch context-limit apply
assert_eq "${STATUS[context-limit]:-}" "applied" "status after second apply"
cmp -s "$CLI_PATH" "$after_first_apply" || fail "second apply must not mutate the file"

restore_patch context-limit
cmp -s "$CLI_PATH" "$baseline" || fail "restore must return to the shared baseline"

printf 'PASS: context-limit registry and UI contract\n'
printf 'PASS: context-limit check/apply/idempotence/restore lifecycle\n'
```

- [ ] **Step 2: 运行测试并确认因上游留档或引擎缺失而失败**

Run:

```bash
bash tests/test_context_limit_integration.sh
```

Expected: FAIL，错误为 `archived context-limit source is missing`。如果留档文件已由人工提前复制，则应在 `write_patch_script context-limit` 处失败并打印 `未知补丁 id: context-limit`。

- [ ] **Step 3: 原样复制 Bash 上游脚本并验证输入未被改动**

执行机械复制：

```bash
cp apply-claude-code-context-limit-patch/apply-claude-code-context-limit-patch.sh \
  original-scripts/apply-claude-code-context-limit-patch.sh
cmp -s apply-claude-code-context-limit-patch/apply-claude-code-context-limit-patch.sh \
  original-scripts/apply-claude-code-context-limit-patch.sh
```

Expected: `cmp` 退出 0。不要复制同目录的 `.ps1`。

- [ ] **Step 4: 注册 Context Limit 引擎 writer**

用 `apply_patch` 在 `write_patch_script` case 中加入：

```bash
context-limit) write_patch_script_context_limit "$tmp" ;;
```

在 `write_patch_script_voice_mode` 之前新增函数外壳：

```bash
write_patch_script_context_limit() {
  local out="$1"
  cat >"$out" <<'PATCH_EOF'
```

函数主体必须从 `original-scripts/apply-claude-code-context-limit-patch.sh:195-499` 精确复制：起点是 `const fs = require('fs');`，终点是 `console.log('SUCCESS:' + patchedCount);`。结尾使用：

```bash
PATCH_EOF
}
```

除 Step 5 和 Step 6 指定的两个替换块外，不改变上游 AST 定位、替换排序、验证条件、日志 marker 或默认表达式。

- [ ] **Step 5: 用 AST 成员访问实现幂等检测**

在移植主体中，用以下代码完整替换上游 `if (patchedCount === 0)` 块：

```javascript
const existingContextLimitRefs = findNodes(ast, n =>
    n.type === 'MemberExpression' &&
    n.object?.type === 'MemberExpression' &&
    n.object.object?.name === 'process' &&
    n.object.property?.name === 'env' &&
    n.property?.name === 'CLAUDE_CODE_CONTEXT_LIMIT'
);

if (patchedCount === 0) {
    if (existingContextLimitRefs.length > 0) {
        console.log('ALREADY_PATCHED');
        process.exit(2);
    }
    console.error('NOT_FOUND:No patchable 200000 literals found');
    process.exit(1);
}
```

这个判断必须位于环境加载函数搜索之前，使已经应用的文件不会因为找不到新的目标字面量而报错，也不会再次注入。

- [ ] **Step 6: 把时间戳备份替换为管理器统一基线适配**

用以下代码完整替换上游 `const timestamp ... console.log('BACKUP:' + backupPath);` 块：

```javascript
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

保留紧随其后的：

```javascript
fs.writeFileSync(cliPath, shebang + newCode);
console.log('SUCCESS:' + patchedCount);
```

- [ ] **Step 7: 运行完整 Context Limit 生命周期测试**

Run:

```bash
bash tests/test_context_limit_integration.sh
```

Expected: 退出 0，并输出：

```text
PASS: context-limit registry and UI contract
PASS: context-limit check/apply/idempotence/restore lifecycle
```

测试首次运行可能通过现有 `ensure_acorn` 从 `https://unpkg.com/acorn@8.16.0/dist/acorn.js` 下载到测试临时目录；如果网络下载失败，应报告环境问题，不得跳过 AST 生命周期测试。

- [ ] **Step 8: 验证只复制了 Bash 源且输入哈希未变化**

Run:

```bash
test ! -e original-scripts/apply-claude-code-context-limit-patch.ps1
shasum -a 256 \
  apply-claude-code-context-limit-patch/apply-claude-code-context-limit-patch.sh \
  apply-claude-code-context-limit-patch/apply-claude-code-context-limit-patch.ps1 \
  apply-claude-code-enable-auto-mode/apply-claude-code-enable-auto-mode.sh \
  apply-claude-code-enable-auto-mode/apply-claude-code-enable-auto-mode.ps1
```

Expected: 四个哈希依次与 Global Constraints 中的值完全相同。

- [ ] **Step 9: 提交 Context Limit 引擎与测试**

```bash
git add cc-patch-manager.sh \
  original-scripts/apply-claude-code-context-limit-patch.sh \
  tests/test_context_limit_integration.sh
git commit -m "feat: integrate context limit patch"
```

---

### Task 3: 锁定 Auto Mode 双形态检测并完成全量验证

**Files:**
- Create: `tests/test_auto_mode_engine.sh`
- Verify: `cc-patch-manager.sh`
- Verify: `original-scripts/apply-claude-code-enable-auto-mode.sh`

**Interfaces:**
- Consumes: 现有 `write_patch_script auto-mode`。
- Produces: 不依赖根目录重新发布版的 Auto Mode 防降级测试，确保管理器继续生成旧版与 2.1.204+ 平铺版两套候选检测器。

- [ ] **Step 1: 写 Auto Mode 特征回归测试**

用 `apply_patch` 创建 `tests/test_auto_mode_engine.sh`：

```bash
#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

source "$ROOT/cc-patch-manager.sh"

engine=$(write_patch_script auto-mode)
mv "$engine" "$tmp/auto-mode-engine.js"
engine="$tmp/auto-mode-engine.js"

for marker in \
  'oQqCandidatesLegacy' \
  'oQqCandidatesFlat' \
  'rankFlat' \
  "bodySrc.includes('claude-3-')" \
  "bodySrc.includes('firstParty')" \
  "bodySrc.includes('anthropicAws')"
do
  grep -Fq "$marker" "$engine" || {
    printf 'FAIL: auto-mode engine lost marker: %s\n' "$marker" >&2
    exit 1
  }
done

grep -Fq 'if (oQqCandidatesFlat.length > 0)' "$engine"
grep -Fq 'else if (oQqCandidatesLegacy.length > 0)' "$engine"
grep -Fq 'FOUND:using flat TBe-style model eligibility detector' "$engine"
grep -Fq 'FOUND:using legacy nested-block model eligibility detector' "$engine"

printf 'PASS: auto-mode retains legacy and flat model-gate detectors\n'
```

- [ ] **Step 2: 运行特征测试，确认当前增强实现已满足契约**

Run:

```bash
bash tests/test_auto_mode_engine.sh
```

Expected: 退出 0，并输出 `PASS: auto-mode retains legacy and flat model-gate detectors`。该测试是对已有增强行为的 characterization test，因此预期首次即通过，不要求为制造红灯而删除现有正确代码。

- [ ] **Step 3: 提交 Auto Mode 防降级测试**

```bash
git add tests/test_auto_mode_engine.sh
git commit -m "test: preserve auto mode dual detector"
```

- [ ] **Step 4: 运行完整验证集**

Run:

```bash
bash -n cc-patch-manager.sh
bash tests/test_context_limit_integration.sh
bash tests/test_auto_mode_engine.sh
bash tests/test_voice_mode_platform.sh
git diff --check
```

Expected: 四个 Bash 命令均退出 0；三个测试脚本合计输出七条 PASS（Context Limit 2 条、Auto Mode 1 条、Voice Mode 4 条）；`git diff --check` 无输出。

- [ ] **Step 5: 核对需求、提交范围与用户输入保护**

Run:

```bash
git status --short
git log -4 --oneline
shasum -a 256 \
  apply-claude-code-context-limit-patch/apply-claude-code-context-limit-patch.sh \
  apply-claude-code-context-limit-patch/apply-claude-code-context-limit-patch.ps1 \
  apply-claude-code-enable-auto-mode/apply-claude-code-enable-auto-mode.sh \
  apply-claude-code-enable-auto-mode/apply-claude-code-enable-auto-mode.ps1
```

Expected:

- `git status --short` 只显示用户原有的两个未跟踪输入目录；实现文件均已提交。
- 最近提交包含设计、注册、Context Limit 引擎和 Auto Mode 防降级测试。
- 四个上游输入哈希与 Global Constraints 完全相同。
- `original-scripts/` 中新增 `.sh`，没有新增 `.ps1`。

- [ ] **Step 6: 按 verification-before-completion 复核证据后交付**

最终答复必须引用 Step 4 和 Step 5 的新鲜输出，说明：新增第六项、Context Limit 生命周期测试结果、Auto Mode 不替换的结论、上游输入未修改，以及剩余版本结构变化风险。不得把未运行的真实 Claude Code 冒烟测试表述为已验证。
