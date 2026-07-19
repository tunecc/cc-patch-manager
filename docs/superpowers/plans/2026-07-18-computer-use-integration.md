# Computer Use Integration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 将 `apply-claude-code-computer-use-fix.sh` 作为第七个补丁接入 `cc-patch-manager.sh`，覆盖注册、检测、应用、幂等、统一基线备份和单补丁还原。

**Architecture:** 保留用户提供的 Bash 脚本作为上游来源留档，将其中 Node/Acorn AST 引擎嵌入管理器。管理器继续负责目标定位、Acorn 缓存、状态映射和统一基线；Computer Use 引擎只负责 schema、启用门禁与子配置合并的 AST 修改。

**Tech Stack:** Bash 3+/4+、Node.js、Acorn 8.16.0、Shell 集成测试、Git

## Global Constraints

- 新补丁 id 必须为 `computer-use`，并位于 `PATCH_IDS` 第七位。
- 显示名称必须为 `Computer Use 解锁`。
- 默认行为保持关闭；只有 `computerUseEnabled` 或 `CLAUDE_CODE_COMPUTER_USE=1` 显式启用。
- 可选子配置字段必须为 `computerUseConfig`。
- 管理器必须使用 `cli.js.cc-patch-baseline`，不得创建 Computer Use 时间戳备份。
- 根目录 `apply-claude-code-computer-use-fix.sh` 保持原位，不删除、不覆盖。
- 不修改真实 Claude Code 安装，不改动现有六个补丁的业务逻辑或顺序。
- 不触碰未跟踪的 `apply-claude-code-context-limit-patch/` 与 `apply-claude-code-enable-auto-mode/`。

---

## File Structure

- `cc-patch-manager.sh`：登记第七项、提供说明与菜单入口、生成 Computer Use Node/Acorn 补丁引擎。
- `original-scripts/apply-claude-code-computer-use-fix.sh`：原样保存用户提供的上游 Bash 脚本，作为事实来源和后续对照基线。
- `tests/test_computer_use_integration.sh`：验证注册、上游归档、引擎生成、检测、应用、幂等、统一备份和还原。
- `tests/test_context_limit_integration.sh`：同步补丁总数、菜单范围和数字分派断言；Context Limit 仍保持第六位。
- `tests/test_voice_mode_platform.sh`：同步帮助文案中的补丁数量断言，从六项改为七项。

### Task 1: 注册第七项并归档上游脚本

**Files:**
- Create: `tests/test_computer_use_integration.sh`
- Create: `original-scripts/apply-claude-code-computer-use-fix.sh`
- Modify: `cc-patch-manager.sh:28-160`
- Modify: `cc-patch-manager.sh:2864-2885`
- Modify: `cc-patch-manager.sh:3079-3107`
- Modify: `tests/test_context_limit_integration.sh:18-35`
- Modify: `tests/test_voice_mode_platform.sh:54-56`

**Interfaces:**
- Consumes: `PATCH_IDS`, `patch_name()`, `patch_note()`, `patch_suffix()`, `patch_purpose()`, `usage()`, `menu_loop()`。
- Produces: 注册 id `computer-use`；菜单数字 `7`；归档脚本 `original-scripts/apply-claude-code-computer-use-fix.sh`。

- [ ] **Step 1: 写注册与归档的失败测试**

创建 `tests/test_computer_use_integration.sh`，先只写注册、界面和来源归档断言：

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
  "auto-mode keybindings transcript-dialog ultracode voice-mode context-limit computer-use" \
  "computer-use must be appended as patch seven"
assert_eq "$(patch_name computer-use)" "Computer Use 解锁" "computer-use name"
assert_eq "$(patch_note computer-use)" \
  "通过设置或环境变量启用 Computer Use MCP，默认关闭" \
  "computer-use note"
assert_eq "$(patch_suffix computer-use)" "backup-computer-use" "computer-use suffix"

purpose=$(patch_purpose computer-use)
[[ "$purpose" == *"computerUseEnabled"* ]] || fail "purpose must document settings enablement"
[[ "$purpose" == *"CLAUDE_CODE_COMPUTER_USE"* ]] || fail "purpose must document env enablement"
[[ "$purpose" == *"computerUseConfig"* ]] || fail "purpose must document sub-config"
[[ "$purpose" == *"默认关闭"* ]] || fail "purpose must preserve default-off behavior"

help=$("$ROOT/cc-patch-manager.sh" --help)
[[ "$help" == *"打印七个补丁状态后退出"* ]] || fail "help must report seven patch statuses"
grep -Fq "[1-7] 选择补丁" "$ROOT/cc-patch-manager.sh" || fail "menu hint must accept 1-7"
grep -Fq '1|2|3|4|5|6|7)' "$ROOT/cc-patch-manager.sh" || fail "menu dispatch must accept choice 7"

source_script="$ROOT/original-scripts/apply-claude-code-computer-use-fix.sh"
[[ -f "$source_script" ]] || fail "archived computer-use source is missing"
if command -v shasum >/dev/null 2>&1; then
  source_hash=$(shasum -a 256 "$source_script" | awk '{print $1}')
elif command -v sha256sum >/dev/null 2>&1; then
  source_hash=$(sha256sum "$source_script" | awk '{print $1}')
else
  fail "no SHA-256 command available"
fi
assert_eq "$source_hash" \
  "ea146c487fa094bc4ec3cb06f6fb9b0ddab1b60abd2525f7eb524df57706ab9b" \
  "archived computer-use source hash"

printf 'PASS: computer-use registry, UI contract, and source archive\n'
```

- [ ] **Step 2: 运行测试并确认按预期失败**

Run:

```bash
bash tests/test_computer_use_integration.sh
```

Expected: FAIL，首个失败为 `computer-use must be appended as patch seven`，因为管理器仍只有六项。

- [ ] **Step 3: 原样归档用户提供的脚本**

使用 `apply_patch` 新增 `original-scripts/apply-claude-code-computer-use-fix.sh`。文件内容逐字取自已锁定 SHA-256 为 `ea146c487fa094bc4ec3cb06f6fb9b0ddab1b60abd2525f7eb524df57706ab9b` 的根目录 `apply-claude-code-computer-use-fix.sh`；不得调整注释、缩进、换行或脚本逻辑。

随后验证两份文件一致：

```bash
cmp -s apply-claude-code-computer-use-fix.sh original-scripts/apply-claude-code-computer-use-fix.sh
```

Expected: exit 0。

- [ ] **Step 4: 用最小注册改动使新测试通过**

在 `cc-patch-manager.sh` 中将注册数组改为：

```bash
PATCH_IDS=(auto-mode keybindings transcript-dialog ultracode voice-mode context-limit computer-use)
```

在 `patch_name()`、`patch_note()` 和 `patch_suffix()` 对应 `case` 中分别加入：

```bash
computer-use) echo "Computer Use 解锁" ;;
```

```bash
computer-use) echo "通过设置或环境变量启用 Computer Use MCP，默认关闭" ;;
```

```bash
computer-use) echo "backup-computer-use" ;;
```

在 `patch_purpose()` 的 `context-limit` 分支之后加入：

```bash
computer-use)
  cat <<'EOF'
现象：Computer Use MCP 默认受订阅与服务端功能开关限制，无法只通过本地
settings.json 决定是否启用，也不能覆盖鼠标动画等子配置。

改动：
  (1) 支持 settings.json 中的 computerUseEnabled 开关
  (2) 支持 CLAUDE_CODE_COMPUTER_USE=1 环境变量强制启用
  (3) 支持 computerUseConfig 覆盖鼠标动画、动作前隐藏、剪贴板保护和坐标模式

限制：补丁默认关闭；启用后仍需要 macOS 辅助功能和屏幕录制权限。
EOF
  ;;
```

将帮助文案中的数量更新为：

```text
七个社区常用 Claude Code 本地补丁的统一管理（中文交互）。
```

```text
$(basename "$0") --check          打印七个补丁状态后退出
```

将主菜单提示改为：

```bash
printf '[1-7] 选择补丁   [a] 一键应用全部   [b] 备份当前   [r] 刷新全部   [p] 换路径   [q] 退出\n'
```

将数字分派改为：

```bash
1|2|3|4|5|6|7)
  id="${PATCH_IDS[$((choice - 1))]}"
  show_detail "$id"
  ;;
```

同步修改 `tests/test_voice_mode_platform.sh`：

```bash
help=$("$ROOT/cc-patch-manager.sh" --help)
[[ "$help" == *"打印七个补丁状态后退出"* ]]
printf 'PASS: help reports seven patch statuses\n'
```

同步修改 `tests/test_context_limit_integration.sh` 的总注册表断言，保持 `context-limit` 在第六位，并将 `computer-use` 追加到末尾：

```bash
assert_eq "${PATCH_IDS[*]}" \
  "auto-mode keybindings transcript-dialog ultracode voice-mode context-limit computer-use" \
  "context-limit must remain patch six and computer-use must be patch seven"
```

将同一文件的帮助与菜单断言更新为：

```bash
help=$("$ROOT/cc-patch-manager.sh" --help)
[[ "$help" == *"打印七个补丁状态后退出"* ]] || fail "help must report seven patch statuses"
grep -Fq "[1-7] 选择补丁" "$ROOT/cc-patch-manager.sh" || fail "menu hint must accept 1-7"
grep -Fq '1|2|3|4|5|6|7)' "$ROOT/cc-patch-manager.sh" || fail "menu dispatch must accept choice 7"
```

- [ ] **Step 5: 运行注册测试和受影响回归测试**

Run:

```bash
bash tests/test_computer_use_integration.sh
bash tests/test_context_limit_integration.sh
bash tests/test_voice_mode_platform.sh
bash -n cc-patch-manager.sh
```

Expected: 四个命令全部 exit 0；输出包含：

```text
PASS: computer-use registry, UI contract, and source archive
PASS: help reports seven patch statuses
```

- [ ] **Step 6: 提交注册与归档**

```bash
git add cc-patch-manager.sh original-scripts/apply-claude-code-computer-use-fix.sh tests/test_computer_use_integration.sh tests/test_context_limit_integration.sh tests/test_voice_mode_platform.sh
git commit -m "feat: register computer use patch"
```

### Task 2: 移植 AST 引擎并验证完整生命周期

**Files:**
- Modify: `tests/test_computer_use_integration.sh`
- Modify: `cc-patch-manager.sh:549-566` and the patch-engine function area before `run_node_patch()`

**Interfaces:**
- Consumes: `write_patch_script(id)`, `run_node_patch(id, mode)`, `parse_and_set_status()`, `baseline_path()`, `restore_patch(id)`。
- Produces: `write_patch_script_computer_use(out)`；生成的 Node 脚本输出 `NEEDS_PATCH`、`PATCH_COUNT:n`、`ALREADY_PATCHED`、`BACKUP:path`、`BASELINE_CREATED:path` 和 `SUCCESS:n`。

- [ ] **Step 1: 扩展测试，先锁定引擎与完整状态闭环**

在 `tests/test_computer_use_integration.sh` 的最终 `printf` 之前加入：

```bash
engine=$(write_patch_script computer-use)
grep -Fq 'CLAUDE_CODE_COMPUTER_USE' "$engine" || fail "generated engine lost its env marker"
grep -Fq 'computerUseEnabled' "$engine" || fail "generated engine lost its settings marker"
grep -Fq 'computerUseConfig' "$engine" || fail "generated engine lost its config marker"
grep -Fq 'ALREADY_PATCHED' "$engine" || fail "generated engine lacks idempotence marker"
grep -Fq 'CC_PATCH_SKIP_BACKUP' "$engine" || fail "generated engine lacks baseline adapter"
rm -f "$engine"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
CLI_PATH="$tmp/cli.js"
ACORN_PATH="$tmp/acorn.js"

cat >"$CLI_PATH" <<'JS'
#!/usr/bin/env node
const z={boolean(){return this},optional(){return this},describe(){return this},object(){return this},enum(){return this}};
const settingsSchema={
  p01:0,p02:0,p03:0,p04:0,p05:0,p06:0,p07:0,p08:0,p09:0,p10:0,
  p11:0,p12:0,p13:0,p14:0,p15:0,p16:0,p17:0,p18:0,p19:0,p20:0,
  p21:0,p22:0,p23:0,p24:0,p25:0,p26:0,p27:0,p28:0,p29:0,p30:0,
  p31:0,p32:0,p33:0,p34:0,p35:0,p36:0,p37:0,p38:0,p39:0,p40:0,
  p41:0,p42:0,p43:0,p44:0,p45:0,p46:0,p47:0,p48:0,p49:0,p50:0,
  autoCompactEnabled:z.boolean().optional().describe("compact conversation setting")
};
function envTruthy(value){return value==="1"}
function readSetting(name,fallback){return{source:"default",value:fallback}}
function readCompact(){return envTruthy(process.env.DISABLE_AUTO_COMPACT)||readSetting("autoCompactEnabled",void 0).value}
const computerDefaults={enabled:false,mouseAnimation:true};
function featureConfig(name,defaults){return{}}
function computerConfig(){return{...computerDefaults,...featureConfig("tengu_malort_pedway",computerDefaults)}}
function hasSubscription(){return true}
function computerEnabled(){return hasSubscription()&&computerConfig().enabled}
console.log(settingsSchema,readCompact(),computerEnabled());
JS

before="$tmp/cli-before.js"
cp "$CLI_PATH" "$before"

run_node_patch computer-use check
assert_eq "${STATUS[computer-use]:-}" "idle" "initial computer-use status"
assert_eq "${MSG[computer-use]:-}" "需修补 3 处" "initial computer-use patch count"

run_node_patch computer-use apply
assert_eq "${STATUS[computer-use]:-}" "applied" "status after computer-use apply"
assert_eq "${MSG[computer-use]:-}" "已修补 3 处" "computer-use apply count"

baseline="$CLI_PATH.cc-patch-baseline"
[[ -f "$baseline" ]] || fail "manager baseline was not created"
cmp -s "$baseline" "$before" || fail "baseline must preserve the unpatched fixture"
if compgen -G "$CLI_PATH.backup-computer-use-*" >/dev/null; then
  fail "manager must not create timestamp computer-use backups"
fi

grep -Fq 'CLAUDE_CODE_COMPUTER_USE' "$CLI_PATH" || fail "patched cli lost env gate"
grep -Fq 'computerUseEnabled' "$CLI_PATH" || fail "patched cli lost settings gate"
grep -Fq 'computerUseConfig' "$CLI_PATH" || fail "patched cli lost config merge"

node - "$ACORN_PATH" "$CLI_PATH" <<'NODE'
const fs = require('fs');
const acorn = require(process.argv[2]);
const code = fs.readFileSync(process.argv[3], 'utf8').replace(/^#![^\n]*\n/, '');
acorn.parse(code, { ecmaVersion: 'latest', sourceType: 'module' });
NODE

run_node_patch computer-use check
assert_eq "${STATUS[computer-use]:-}" "applied" "status after second computer-use check"
[[ "$LAST_OUTPUT" == *"ALREADY_PATCHED"* ]] || fail "second check must report ALREADY_PATCHED"

after_first_apply="$tmp/cli-after-first-apply.js"
cp "$CLI_PATH" "$after_first_apply"
run_node_patch computer-use apply
assert_eq "${STATUS[computer-use]:-}" "applied" "status after second computer-use apply"
cmp -s "$CLI_PATH" "$after_first_apply" || fail "second apply must not mutate the file"

restore_patch computer-use
cmp -s "$CLI_PATH" "$baseline" || fail "restore must return to the shared baseline"

printf 'PASS: computer-use check/apply/idempotence/restore lifecycle\n'
```

- [ ] **Step 2: 运行测试并确认引擎尚未登记**

Run:

```bash
bash tests/test_computer_use_integration.sh
```

Expected: FAIL，输出包含 `未知补丁 id: computer-use`，因为 `write_patch_script()` 还没有 Computer Use 分派。

- [ ] **Step 3: 在管理器中登记引擎生成函数**

在 `write_patch_script()` 的 `case` 中加入：

```bash
computer-use) write_patch_script_computer_use "$tmp" ;;
```

使用 `apply_patch` 在 `run_node_patch()` 之前新增 `write_patch_script_computer_use()`。函数结构固定为：接收输出路径、通过单引号 `PATCH_EOF` heredoc 写入 Node 引擎、返回时不执行该引擎。heredoc 内容必须逐字采用归档脚本中唯一一段 Node 补丁脚本：起点是 `const fs = require('fs');`，终点是紧邻关闭 `PATCH_EOF` 之前的 `console.log('SUCCESS:' + patchedCount);`。唯一允许的内容差异是 Step 4 明确给出的备份块替换。

嵌入后的 Bash 边界必须是：

```bash
write_patch_script_computer_use() {
  local out="$1"
  cat >"$out" <<'PATCH_EOF'
```

以及：

```bash
console.log('SUCCESS:' + patchedCount);
PATCH_EOF
}
```

Node 参数接口必须保持：

```javascript
const acorn = require(process.argv[2]);
const cliPath = process.argv[3];
const checkOnly = process.argv[4] === '--check';
```

- [ ] **Step 4: 将上游时间戳备份替换为统一基线适配**

在嵌入的 Node 引擎中，用以下完整代码替换上游从 `const timestamp = ...` 到 `console.log('BACKUP:' + backupPath);` 的备份块：

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

保留下游写入与成功输出：

```javascript
fs.writeFileSync(cliPath, shebang + newCode);
console.log('SUCCESS:' + patchedCount);
```

- [ ] **Step 5: 运行 Computer Use 生命周期测试并修正最小实现**

Run:

```bash
bash tests/test_computer_use_integration.sh
```

Expected: exit 0，输出包含：

```text
PASS: computer-use registry, UI contract, and source archive
PASS: computer-use check/apply/idempotence/restore lifecycle
```

如果失败，只修复导致 fixture 不满足上游结构匹配、输出状态无法映射或统一基线未生效的问题；不得放宽生产定位器来迁就错误 fixture。

- [ ] **Step 6: 运行全量验证**

Run:

```bash
bash -n cc-patch-manager.sh
bash tests/test_computer_use_integration.sh
bash tests/test_context_limit_integration.sh
bash tests/test_auto_mode_engine.sh
bash tests/test_voice_mode_platform.sh
git diff --check
```

Expected: 所有命令 exit 0；没有 Shell 语法错误、测试失败或空白错误。

- [ ] **Step 7: 检查变更范围**

Run:

```bash
git status --short
git diff --stat
git diff -- cc-patch-manager.sh tests/test_computer_use_integration.sh tests/test_voice_mode_platform.sh
cmp -s apply-claude-code-computer-use-fix.sh original-scripts/apply-claude-code-computer-use-fix.sh
```

Expected:

- `cmp` exit 0。
- 只包含计划中的管理器与测试文件，以及已归档的上游脚本。
- 根目录三个用户输入仍保持未跟踪状态，未被删除或改写。

- [ ] **Step 8: 提交 AST 引擎集成**

```bash
git add cc-patch-manager.sh tests/test_computer_use_integration.sh tests/test_voice_mode_platform.sh original-scripts/apply-claude-code-computer-use-fix.sh
git commit -m "feat: integrate computer use patch"
```

提交后再次运行：

```bash
git status --short
```

Expected: 只剩用户原有的根目录未跟踪输入，不出现本任务的未提交修改。
