---
change: adapt-cruce-split-esm
design-doc: docs/superpowers/specs/2026-09-03-adapt-cruce-split-esm-design.md
base-ref: 12a8af769933ae4388cc6c86bcd80d87f7685a63
---

# 双布局补丁管理器实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 保持 `cc-patch-manager.sh` 是唯一生产交付物，使七个补丁同时支持 CometixSpace 2.1.224 single-CJS 与 cruce 2.1.259 split-ESM 的检测、应用、幂等复检和还原。

**Architecture:** Bash 继续拥有参数、发现、TUI、确认和状态；临时生成的 Node runtime 建立 TargetDescriptor、索引模块、产生 PatchPlan，并以 manifest 和文件事务完成写入与恢复。analyzer 只返回计划，不自行写文件。

**Tech Stack:** Bash 3.2+、Node.js、Acorn 8.16.0、JSON、POSIX rename、Bash 测试。

## Global Constraints

- 只交付 `cc-patch-manager.sh`；不依赖额外 runtime 文件、chunk 文件名、压缩变量名或偏移。
- 仅支持 `@cometix/claude-code` 和 `@cometix/anthropic-cc`；布局由入口和相邻模块的结构识别，不按版本号分支。
- `PATCH_IDS` 必须保持 `auto-mode keybindings transcript-dialog ultracode voice-mode context-limit computer-use`。
- 任一必要语义目标缺失、歧义、绑定无法解析、AST 或后置条件失败时必须零写入。
- 一项补丁是独立全有或全无事务；`apply-all` 按固定顺序跑七笔事务，一笔失败不阻止后续项。
- 包级基线在 `.cc-patch-manager-baseline/`，记录 package 身份和所有受管路径的原始存在状态、mode、SHA-256、镜像。
- VoiceMode 只支持 Darwin/arm64，资源预检先于基线和目标写入。
- 快速测试使用临时 fixture；真实验收只复制包，不写 `/opt/homebrew/lib/node_modules/@cometix/anthropic-cc`。
- 两个真实包都必须通过七补丁矩阵、`--version`、`--help`、非交互启动 smoke 和还原树哈希检查。
- 每项任务执行红、绿、重构、完整复跑、单独提交。

---

## File Structure

- `cc-patch-manager.sh`: Bash facade 与嵌入 Node runtime，负责目标、索引、计划、七 analyzer、manifest、事务。
- `tests/lib/dual-layout-fixture.sh`: 建立临时 package/chunk、树哈希和生命周期断言。
- `tests/test_target_descriptor.sh`: 路径优先级、包身份与布局。
- `tests/test_module_index.sh`: marker、ESM import/export/alias、歧义、越界和循环。
- `tests/test_patch_plan_contract.sh`: 计划基数、replacement 校验、共同 check/apply 路径。
- `tests/test_package_baseline_transaction.sh`: manifest、旧基线、故障注入、回滚、重打。
- `tests/test_dual_layout_lifecycle.sh`: 七补丁在两种 fixture 的统一生命周期。
- `tests/test_real_package_acceptance.sh`: 两个真实包副本、CLI smoke 和全局 cruce 哈希保护。

## Shared Interfaces

```bash
write_patch_runtime
runtime_exec inspect "$entry"
runtime_exec check "$entry" "$patch"
runtime_exec apply "$entry" "$patch"
runtime_exec restore "$entry" "$patch"
runtime_exec backup "$entry"

fixture_make_package "$tmp/old" single-cjs '@cometix/claude-code' 2.1.224
fixture_make_package "$tmp/new" split-esm '@cometix/anthropic-cc' 2.1.259
fixture_entry "$tmp/new"
fixture_add_module "$tmp/new" chunks/gate.js 'export function gate(){return false}'
fixture_hash_tree "$tmp/new"
fixture_assert_tree_equals "$before" "$after"
fixture_assert_lifecycle "$tmp/new" auto-mode
```

### Task 1.1: 目标发现失败测试

**Files:** Create `tests/lib/dual-layout-fixture.sh`, `tests/test_target_descriptor.sh`; Modify `cc-patch-manager.sh:180-233`.

**Interfaces:** Consumes `resolve_target`, `CLAUDE_CLI_PATH`, `find_cli_js`; produces fixture 构建器和新旧包发现测试。

- [ ] **Step 1: 写失败测试**

```bash
fixture_make_package "$tmp/old" single-cjs '@cometix/claude-code' 2.1.224
fixture_make_package "$tmp/new" split-esm '@cometix/anthropic-cc' 2.1.259
CLAUDE_CLI_PATH="$(fixture_entry "$tmp/old")" resolve_target "$(fixture_entry "$tmp/new")"
assert_eq "$CLI_PATH" "$(fixture_entry "$tmp/new")" 'explicit target wins'
```

- [ ] **Step 2: 确认红灯**

Run: `bash tests/test_target_descriptor.sh`

Expected: FAIL；当前没有 fixture 且 `find_cli_js` 没有 cruce 候选。

- [ ] **Step 3: 实施最小发现改动**

```bash
# 在 find_cli_js 的 locations 数组中，紧随旧 @cometix 候选加入同 root 的 cruce 候选：
locations+=("$HOME/.claude/local/node_modules/@cometix/anthropic-cc/cli.js")
locations+=("$npm_root/@cometix/anthropic-cc/cli.js")
fixture_make_package() { mkdir -p "$1"; echo "{\"name\":\"$3\",\"version\":\"$4\"}" >"$1/package.json"; echo '#!/usr/bin/env node' >"$1/cli.js"; }
```

- [ ] **Step 4: 复跑**

Run: `bash tests/test_target_descriptor.sh`

Expected: PASS；显式路径、环境变量、旧包、新包优先级固定，无效入口拒绝。

- [ ] **Step 5: 提交**

```bash
git add cc-patch-manager.sh tests/lib/dual-layout-fixture.sh tests/test_target_descriptor.sh
git commit -m "test: cover dual package target discovery"
```

### Task 1.2: TargetDescriptor 与布局检测

**Files:** Modify `cc-patch-manager.sh:180-233,565-583`, `tests/test_target_descriptor.sh`.

**Interfaces:** Produces `TargetDescriptor { entryPath, packageRoot, packageName, packageVersion, layout, identityFingerprint }` and `runtime_exec inspect`.

- [ ] **Step 1: 写失败断言**

```bash
out=$(runtime_exec inspect "$(fixture_entry "$tmp/new")")
grep -Fx 'TARGET_PACKAGE:@cometix/anthropic-cc' <<<"$out"
grep -Fx 'TARGET_LAYOUT:split-esm' <<<"$out"
runtime_exec inspect "$(fixture_entry "$tmp/unsupported")" && fail 'unsupported package accepted'
```

- [ ] **Step 2: 确认红灯**

Run: `bash tests/test_target_descriptor.sh`

Expected: FAIL；尚无 runtime 和 `TARGET_*` 机器协议。

- [ ] **Step 3: 实施结构检查**

```javascript
function inspectTarget(entryPath) {
  const packageRoot = nearestPackageRoot(entryPath), pkg = readPackage(packageRoot);
  requireSupportedPackage(pkg.name);
  const layout = staticRelativeImports(entryPath).some(e => exists(e.resolved)) ? 'split-esm' : 'single-cjs';
  return {entryPath, packageRoot, packageName: pkg.name, packageVersion: pkg.version, layout,
    identityFingerprint: fingerprintTarget(packageRoot, entryPath, pkg, layout)};
}
```

- [ ] **Step 4: 复跑**

Run: `bash tests/test_target_descriptor.sh && bash tests/test_fast_apply_all.sh`

Expected: PASS；包根越界、非支持包和无结构证据目标失败。

- [ ] **Step 5: 提交**

```bash
git add cc-patch-manager.sh tests/test_target_descriptor.sh
git commit -m "feat: inspect package layout structurally"
```

### Task 1.3: marker 与 ESM 索引 fixture

**Files:** Create `tests/test_module_index.sh`; Modify `tests/lib/dual-layout-fixture.sh`, `cc-patch-manager.sh:565-583`.

**Interfaces:** Produces `scanMarkerCandidates(descriptor, groups)` and `ModuleIndex.resolveBinding(file, localName)`.

- [ ] **Step 1: 写失败 fixture**

```bash
fixture_add_module "$tmp/new" chunks/source.js 'export const policy="deny"'
fixture_add_module "$tmp/new" chunks/entry.js 'import {policy as localPolicy} from "./source.js";export{localPolicy}'
fixture_add_module "$tmp/new" node_modules/ignored.js 'export const policy="deny"'
runtime_exec check "$(fixture_entry "$tmp/new")" auto-mode || true
```

- [ ] **Step 2: 确认红灯**

Run: `bash tests/test_module_index.sh`

Expected: FAIL；当前 engine 只读取一个 `CLI_PATH`。

- [ ] **Step 3: 实施静态索引**

```javascript
resolveBinding(file, localName, seen = new Set()) {
  if (seen.has(`${file}:${localName}`)) throw new Error('cyclic re-export');
  const b = this.locals.get(file)?.get(localName); if (!b) throw new Error(`missing binding ${localName}`);
  return b.kind === 'import' || b.kind === 'reexport' ? this.resolveBinding(b.sourceFile, b.exportedName, new Set([...seen, `${file}:${localName}`])) : {file, exportedName: localName};
}
```

- [ ] **Step 4: 复跑**

Run: `bash tests/test_module_index.sh`

Expected: PASS；排除 node_modules，拒绝缺失/重复 export、包根逃逸和不可收敛循环。

- [ ] **Step 5: 提交**

```bash
git add cc-patch-manager.sh tests/lib/dual-layout-fixture.sh tests/test_module_index.sh
git commit -m "feat: index split esm patch candidates"
```

### Task 1.4: marker 预筛与 AST 缓存

**Files:** Modify `cc-patch-manager.sh:565-583`, `tests/test_module_index.sh`.

**Interfaces:** Produces `AnalysisContext.readAst(relativePath, sourceType)` with content-hash cache.

- [ ] **Step 1: 写失败断言**

```bash
out=$(CC_PATCH_TRACE_PARSE=1 runtime_exec check "$(fixture_entry "$tmp/new")" keybindings || true)
grep -F 'TARGET_FILE:chunks/keymap.js' <<<"$out"
grep -F 'TARGET_FILE:chunks/unrelated.js' <<<"$out" && fail 'unrelated chunk parsed'
```

- [ ] **Step 2: 确认红灯**

Run: `bash tests/test_module_index.sh`

Expected: FAIL；没有 marker-first 共同分析路径。

- [ ] **Step 3: 实施缓存**

```javascript
readAst(relativePath, sourceType) {
  const text = this.readText(relativePath), key = `${relativePath}:${sha256(text)}:${sourceType}`;
  if (!this.astCache.has(key)) this.astCache.set(key, buildAstRecord(text, sourceType));
  return this.astCache.get(key);
}
```

- [ ] **Step 4: 复跑**

Run: `bash tests/test_module_index.sh && CC_PATCH_TRACE_PARSE=1 ./cc-patch-manager.sh /opt/homebrew/lib/node_modules/@cometix/anthropic-cc/cli.js --check`

Expected: PASS；真实检查不写入且只报告 marker 命中的模块。

- [ ] **Step 5: 提交**

```bash
git add cc-patch-manager.sh tests/test_module_index.sh
git commit -m "perf: cache marker-selected ast analysis"
```

### Task 1.5: PatchPlan 合同

**Files:** Create `tests/test_patch_plan_contract.sh`; Modify `cc-patch-manager.sh:471-583,3236-3286`.

**Interfaces:** Produces `PatchPlan { patchId, state, semanticTargets, files, resources, diagnostics }` and `validatePlan(context, plan)`.

- [ ] **Step 1: 写缺失目标零写入测试**

```bash
before=$(fixture_hash_tree "$tmp/new")
out=$(runtime_exec apply "$(fixture_entry "$tmp/new")" transcript-dialog || true)
grep -F 'MISSING_TARGET:host-cleanup' <<<"$out"
fixture_assert_tree_equals "$before" "$(fixture_hash_tree "$tmp/new")"
```

- [ ] **Step 2: 确认红灯**

Run: `bash tests/test_patch_plan_contract.sh`

Expected: FAIL；check/apply 仍是独立 heredoc engine。

- [ ] **Step 3: 实施计划校验器**

```javascript
function validatePlan(context, plan) {
  for (const t of plan.semanticTargets) requireCardinality(t);
  for (const f of plan.files) assertNonOverlapping(f.replacements);
  const rendered = renderPlanInMemory(context, plan); for (const f of rendered) parseSource(f.text, f.sourceType);
  runPostconditions(context.withRendered(rendered), plan); return rendered;
}
```

- [ ] **Step 4: 复跑**

Run: `bash tests/test_patch_plan_contract.sh`

Expected: PASS；check/apply 共用 analyzer/validator，完整状态才是 `ALREADY_PATCHED`。

- [ ] **Step 5: 提交**

```bash
git add cc-patch-manager.sh tests/test_patch_plan_contract.sh
git commit -m "feat: validate shared multi-file patch plans"
```

### Task 2.1: package manifest 身份

**Files:** Create `tests/test_package_baseline_transaction.sh`; Modify `tests/lib/dual-layout-fixture.sh`, `cc-patch-manager.sh:338-466,565-583`.

**Interfaces:** Produces `BaselineManifest { schemaVersion, package, files, createdDirectories }` and `baselinePath(descriptor)`.

- [ ] **Step 1: 写陈旧身份测试**

```bash
runtime_exec apply "$(fixture_entry "$tmp/new")" keybindings
manifest="$tmp/new/.cc-patch-manager-baseline/manifest.json"
node -e 'const m=require(process.argv[1]);if(m.package.layout!=="split-esm")process.exit(1)' "$manifest"
echo different-build >>"$tmp/new/package.json"
runtime_exec restore "$(fixture_entry "$tmp/new")" keybindings && fail 'stale baseline restored'
```

- [ ] **Step 2: 确认红灯**

Run: `bash tests/test_package_baseline_transaction.sh`

Expected: FAIL；当前仅有 `cli.js.cc-patch-baseline`。

- [ ] **Step 3: 实施 manifest**

```javascript
function makeManifest(target) { return {schemaVersion: 1, package: {name: target.packageName, version: target.packageVersion, layout: target.layout, identityFingerprint: target.identityFingerprint}, files: {}, createdDirectories: []}; }
function assertBaselineIdentity(m, t) { if (m.package.identityFingerprint !== t.identityFingerprint) throw new Error('stale baseline identity'); }
```

- [ ] **Step 4: 复跑**

Run: `bash tests/test_package_baseline_transaction.sh`

Expected: PASS；路径存在状态、mode、镜像 SHA-256 与 package 身份均受校验，未知修改不得静默接纳。

- [ ] **Step 5: 提交**

```bash
git add cc-patch-manager.sh tests/lib/dual-layout-fixture.sh tests/test_package_baseline_transaction.sh
git commit -m "feat: record package-level patch baselines"
```

### Task 2.2: single-CJS 旧基线迁移

**Files:** Modify `cc-patch-manager.sh:338-466,565-583`, `tests/test_package_baseline_transaction.sh`, `tests/test_context_limit_integration.sh`, `tests/test_computer_use_integration.sh`.

**Interfaces:** Produces `migrateLegacyBaseline(target)` only for identity-compatible single-CJS.

- [ ] **Step 1: 写迁移失败测试**

```bash
cp "$(fixture_entry "$tmp/old")" "$(fixture_entry "$tmp/old").cc-patch-baseline"
runtime_exec backup "$(fixture_entry "$tmp/old")"
test -f "$tmp/old/.cc-patch-manager-baseline/files/cli.js"
test -f "$(fixture_entry "$tmp/old").cc-patch-baseline"
```

- [ ] **Step 2: 确认红灯**

Run: `bash tests/test_package_baseline_transaction.sh`

Expected: FAIL；没有 package 基线目录和迁移逻辑。

- [ ] **Step 3: 实施迁移**

```javascript
function migrateLegacyBaseline(target) {
  const legacy = `${target.entryPath}.cc-patch-baseline`;
  if (target.layout !== 'single-cjs' || !exists(legacy)) return false;
  assertLegacyBuildCompatible(target, legacy); recordOriginalFile(target, 'cli.js', readBytes(legacy), statMode(legacy)); return true;
}
```

- [ ] **Step 4: 复跑**

Run: `bash tests/test_package_baseline_transaction.sh && bash tests/test_context_limit_integration.sh && bash tests/test_computer_use_integration.sh`

Expected: PASS；匹配旧基线迁移不删除，不匹配旧基线拒绝。

- [ ] **Step 5: 提交**

```bash
git add cc-patch-manager.sh tests/test_package_baseline_transaction.sh tests/test_context_limit_integration.sh tests/test_computer_use_integration.sh
git commit -m "feat: migrate compatible single-file baselines"
```

### Task 2.3: 多文件事务故障注入

**Files:** Modify `tests/test_package_baseline_transaction.sh`, `tests/lib/dual-layout-fixture.sh`, `cc-patch-manager.sh:565-583`.

**Interfaces:** Produces `commitTransaction(target, operations)` and test-only `CC_PATCH_TEST_FAIL_AFTER`.

- [ ] **Step 1: 写中途失败测试**

```bash
before=$(fixture_hash_tree "$tmp/new")
CC_PATCH_TEST_FAIL_AFTER=2 runtime_exec apply "$(fixture_entry "$tmp/new")" voice-mode || true
fixture_assert_tree_equals "$before" "$(fixture_hash_tree "$tmp/new")"
```

- [ ] **Step 2: 确认红灯**

Run: `bash tests/test_package_baseline_transaction.sh`

Expected: FAIL；旧 VoiceMode 资源复制无法回滚。

- [ ] **Step 3: 实施事务**

```javascript
function commitTransaction(target, operations) {
  const tx = createTransactionDirectory(target.packageRoot);
  try { for (const op of operations) stageAndRename(tx, op); verifyCommitted(operations); }
  catch (error) { rollbackReverse(tx); verifyTransactionBeforeHashes(tx); throw error; }
  finally { removeCompletedTransaction(tx); }
}
```

- [ ] **Step 4: 复跑**

Run: `bash tests/test_package_baseline_transaction.sh`

Expected: PASS；任意第 N 次 JS/resource 操作失败后，树回到事务前。

- [ ] **Step 5: 提交**

```bash
git add cc-patch-manager.sh tests/lib/dual-layout-fixture.sh tests/test_package_baseline_transaction.sh
git commit -m "feat: transact multi-file patch writes"
```

### Task 2.4: 中断恢复与写前门禁

**Files:** Modify `cc-patch-manager.sh:565-583,3236-3286`, `tests/test_package_baseline_transaction.sh`, `tests/test_patch_plan_contract.sh`.

**Interfaces:** Produces `recoverIncompleteTransactions(target)` and `prepareWrite(target, plan)`.

- [ ] **Step 1: 写遗留事务测试**

```bash
before=$(fixture_hash_tree "$tmp/new")
CC_PATCH_TEST_LEAVE_TRANSACTION=1 runtime_exec apply "$(fixture_entry "$tmp/new")" transcript-dialog || true
runtime_exec apply "$(fixture_entry "$tmp/new")" transcript-dialog || true
fixture_assert_tree_equals "$before" "$(fixture_hash_tree "$tmp/new")"
```

- [ ] **Step 2: 确认红灯**

Run: `bash tests/test_package_baseline_transaction.sh && bash tests/test_patch_plan_contract.sh`

Expected: FAIL；无持久事务日志和写前门禁。

- [ ] **Step 3: 实施恢复**

```javascript
function prepareWrite(target, plan) {
  recoverIncompleteTransactions(target);
  const rendered = validatePlan(new AnalysisContext(target), plan);
  ensureBaselineForUnmanagedPaths(target, plan); return rendered;
}
```

- [ ] **Step 4: 复跑**

Run: `bash tests/test_package_baseline_transaction.sh && bash tests/test_patch_plan_contract.sh`

Expected: PASS；无法证明恢复成功就停止，AST/后置条件失败零写入。

- [ ] **Step 5: 提交**

```bash
git add cc-patch-manager.sh tests/test_package_baseline_transaction.sh tests/test_patch_plan_contract.sh
git commit -m "fix: recover interrupted patch transactions"
```

### Task 2.5: 单补丁还原与重打

**Files:** Modify `cc-patch-manager.sh:407-466,565-583,3236-3286`, `tests/test_package_baseline_transaction.sh`.

**Interfaces:** Produces `restorePatch(target, removeId)`; consumes `PATCH_IDS`, manifest and `checkPatch`.

- [ ] **Step 1: 写组合状态测试**

```bash
runtime_exec apply "$(fixture_entry "$tmp/new")" auto-mode
runtime_exec apply "$(fixture_entry "$tmp/new")" voice-mode
runtime_exec restore "$(fixture_entry "$tmp/new")" voice-mode
runtime_exec check "$(fixture_entry "$tmp/new")" voice-mode | grep -Fx NEEDS_PATCH
runtime_exec check "$(fixture_entry "$tmp/new")" auto-mode | grep -Fx ALREADY_PATCHED
test ! -e "$tmp/new/vendor/cometix-asr"
```

- [ ] **Step 2: 确认红灯**

Run: `bash tests/test_package_baseline_transaction.sh`

Expected: FAIL；当前 restore 只能复制 cli.js。

- [ ] **Step 3: 实施包级还原**

```javascript
function restorePatch(target, removeId) {
  const applied = PATCH_IDS.filter(id => checkPatch(target, id).state === 'already-patched');
  assertBaselineIntegrity(target); restoreAllManagedPaths(target);
  return applied.filter(id => id !== removeId).map(id => applyPatch(target, id));
}
```

- [ ] **Step 4: 复跑**

Run: `bash tests/test_package_baseline_transaction.sh`

Expected: PASS；目标 idle，保留项重打，VoiceMode 资源恢复原始不存在状态。

- [ ] **Step 5: 提交**

```bash
git add cc-patch-manager.sh tests/test_package_baseline_transaction.sh
git commit -m "feat: restore one patch from package baseline"
```

### Task 3.1: Auto Mode 与 Keybindings

**Files:** Create `tests/test_dual_layout_lifecycle.sh`; Modify `cc-patch-manager.sh:961-1797,565-583`, `tests/test_auto_mode_engine.sh`.

**Interfaces:** Produces Auto `model-eligibility`, `classifier-fail-closed`, `classifier-model-source`; Keybindings `custom-keybindings-enabled`, `ctrl-c-exit-binding`.

- [ ] **Step 1: 写跨模块 fixture**

```bash
fixture_add_module "$tmp/new" chunks/auto-gate.js 'export function modelEligible(m){return m.includes("claude-3-")?false:true}'
fixture_add_module "$tmp/new" chunks/keymap.js 'export const bindings={"ctrl+c":"app:interrupt"}'
fixture_assert_lifecycle "$tmp/new" auto-mode
fixture_assert_lifecycle "$tmp/new" keybindings
```

- [ ] **Step 2: 确认红灯**

Run: `bash tests/test_dual_layout_lifecycle.sh auto-mode keybindings && bash tests/test_auto_mode_engine.sh`

Expected: FAIL；split chunks 未产生跨文件计划。

- [ ] **Step 3: 迁移两个 analyzer**

```javascript
const autoTargets = ['model-eligibility', 'classifier-fail-closed', 'classifier-model-source'];
const keyTargets = ['custom-keybindings-enabled', 'ctrl-c-exit-binding'];
// 上游默认开启 custom keybindings 时，第一个 target 是 semantic-satisfied。
```

- [ ] **Step 4: 复跑**

Run: `bash tests/test_dual_layout_lifecycle.sh auto-mode keybindings && bash tests/test_auto_mode_engine.sh`

Expected: PASS；两种布局均完成 clean check、apply、复检、二次 apply 不变、restore 相同。

- [ ] **Step 5: 提交**

```bash
git add cc-patch-manager.sh tests/test_dual_layout_lifecycle.sh tests/test_auto_mode_engine.sh
git commit -m "feat: support auto mode and keybindings in split esm"
```

### Task 3.2: Transcript Dialog 与 Ultracode

**Files:** Modify `cc-patch-manager.sh:1800-2736,565-583`, `tests/test_dual_layout_lifecycle.sh`.

**Interfaces:** Produces Transcript `dialog-channel-factory`, `host-cleanup`; Ultracode `ultracode-eligibility`, `ultracode-effort-fallback`, `ultracode-activation`.

- [ ] **Step 1: 写跨模块 fixture**

```bash
fixture_add_module "$tmp/new" chunks/dialog.js 'export function createChannel(){return {reply(){}}}'
fixture_add_module "$tmp/new" chunks/host.js 'export function unmountHost(){reply({cancelled:true})}'
fixture_add_module "$tmp/new" chunks/ultra.js 'export const allowed=["xhigh"];export const fallback="high"'
fixture_assert_lifecycle "$tmp/new" transcript-dialog
fixture_assert_lifecycle "$tmp/new" ultracode
```

- [ ] **Step 2: 确认红灯**

Run: `bash tests/test_dual_layout_lifecycle.sh transcript-dialog ultracode`

Expected: FAIL；旧 engine 假定目标共处一处。

- [ ] **Step 3: 实施 analyzer**

```javascript
requireExactTargets(plan, ['dialog-channel-factory', 'host-cleanup']);
requireExactTargets(plan, ['ultracode-eligibility', 'ultracode-effort-fallback', 'ultracode-activation']);
```

- [ ] **Step 4: 复跑**

Run: `bash tests/test_dual_layout_lifecycle.sh transcript-dialog ultracode`

Expected: PASS；Transcript 保留 reply/request 语义，Ultracode 只在确认调用链里处理 xhigh/max。

- [ ] **Step 5: 提交**

```bash
git add cc-patch-manager.sh tests/test_dual_layout_lifecycle.sh
git commit -m "feat: migrate transcript and ultracode analyzers"
```

### Task 3.3: VoiceMode

**Files:** Modify `cc-patch-manager.sh:243-299,916-960,565-583,3236-3286`, `tests/test_dual_layout_lifecycle.sh`, `tests/test_voice_mode_gate.sh`, `tests/test_voice_mode_platform.sh`.

**Interfaces:** Produces seven targets `entry-gate`, `stream-capability`, `availability`, `settings-ui-schema`, `connection`, `auth-probe`, `feature-flag` and resource `vendor/cometix-asr`.

- [ ] **Step 1: 写七目标和资源失败测试**

```bash
fixture_add_voice_surface "$tmp/new"
before=$(fixture_hash_tree "$tmp/new")
CC_PATCH_TEST_MISSING_ASSET=1 runtime_exec apply "$(fixture_entry "$tmp/new")" voice-mode || true
fixture_assert_tree_equals "$before" "$(fixture_hash_tree "$tmp/new")"
```

- [ ] **Step 2: 确认红灯**

Run: `bash tests/test_dual_layout_lifecycle.sh voice-mode && bash tests/test_voice_mode_gate.sh && bash tests/test_voice_mode_platform.sh`

Expected: FAIL；资源不在计划事务，split-ESM 尚不可识别。

- [ ] **Step 3: 实施 JS 和资源的同一计划**

```javascript
plan.resources.push({kind: 'copy-tree', source: voiceAssetSource(), destination: 'vendor/cometix-asr', expectedBefore: 'absent-or-baselined'});
requireExactTargets(plan, ['entry-gate','stream-capability','availability','settings-ui-schema','connection','auth-probe','feature-flag']);
```

- [ ] **Step 4: 复跑**

Run: `bash tests/test_dual_layout_lifecycle.sh voice-mode && bash tests/test_voice_mode_gate.sh && bash tests/test_voice_mode_platform.sh`

Expected: PASS；非 Darwin/arm64/缺资源零写入，JS 与 vendor 一起 apply/restore。

- [ ] **Step 5: 提交**

```bash
git add cc-patch-manager.sh tests/test_dual_layout_lifecycle.sh tests/test_voice_mode_gate.sh tests/test_voice_mode_platform.sh
git commit -m "feat: transact voicemode split esm patch"
```

### Task 3.4: Context Limit

**Files:** Modify `cc-patch-manager.sh:583-915,565-583`, `tests/test_context_limit_integration.sh`, `tests/test_dual_layout_lifecycle.sh`.

**Interfaces:** Produces `context-default`, `settings-env-refresh`; preserves `CLAUDE_CODE_CONTEXT_LIMIT` and 0 -> 200000.

- [ ] **Step 1: 写跨模块与 settings env 测试**

```bash
fixture_add_module "$tmp/new" chunks/limit.js 'export let limit=200000;export const setLimit=n=>limit=n'
fixture_add_module "$tmp/new" chunks/settings.js 'import{setLimit}from"./limit.js";export function loadEnv(e){Object.assign(process.env,e)}'
fixture_assert_context_limit "$tmp/new" 345678
```

- [ ] **Step 2: 确认红灯**

Run: `bash tests/test_context_limit_integration.sh && bash tests/test_dual_layout_lifecycle.sh context-limit`

Expected: FAIL；旧逻辑仅替换同一文件中的数值。

- [ ] **Step 3: 实施绑定安全刷新**

```javascript
const defaultLimit = findContextLimitDefinition(context), settingsLoader = findSettingsEnvLoaderUsing(defaultLimit.binding);
plan.files.push(replaceDefaultWithEnvRead(defaultLimit));
plan.files.push(insertRefreshAfterEnvLoad(settingsLoader, defaultLimit.binding));
```

- [ ] **Step 4: 复跑**

Run: `bash tests/test_context_limit_integration.sh && bash tests/test_dual_layout_lifecycle.sh context-limit`

Expected: PASS；环境和 settings env 生效，未设置/0 仍为 200000，幂等及还原成立。

- [ ] **Step 5: 提交**

```bash
git add cc-patch-manager.sh tests/test_context_limit_integration.sh tests/test_dual_layout_lifecycle.sh
git commit -m "feat: support context limit across esm modules"
```

### Task 3.5: Computer Use

**Files:** Modify `cc-patch-manager.sh:2739-3233,565-583`, `tests/test_computer_use_integration.sh`, `tests/test_dual_layout_lifecycle.sh`.

**Interfaces:** Produces `settings-schema`, `enable-gate`, `config-merge`; supports default off, `CLAUDE_CODE_COMPUTER_USE=1`, settings and child config merge.

- [ ] **Step 1: 写跨模块 fixture**

```bash
fixture_add_module "$tmp/new" chunks/schema.js 'export const schema={autoCompactEnabled:z.boolean()}'
fixture_add_module "$tmp/new" chunks/gate.js 'export function enabled(){return subscribed()&&config().enabled}'
fixture_add_module "$tmp/new" chunks/config.js 'export const config=()=>({enabled:false,mouseAnimation:true})'
fixture_assert_computer_use "$tmp/new"
```

- [ ] **Step 2: 确认红灯**

Run: `bash tests/test_computer_use_integration.sh && bash tests/test_dual_layout_lifecycle.sh computer-use`

Expected: FAIL；旧 engine 假定 builder、gate、merge 在同一文件。

- [ ] **Step 3: 实施 live builder 计划**

```javascript
const builders = inferZodBuilders(findAdjacentSchemaProperty(context, 'autoCompactEnabled'));
plan.files.push(insertComputerUseSchema(schemaTarget, builders));
plan.files.push(rewriteComputerUseGate(gateTarget, settingsBinding));
plan.files.push(mergeComputerUseConfig(configTarget, settingsBinding));
```

- [ ] **Step 4: 复跑**

Run: `bash tests/test_computer_use_integration.sh && bash tests/test_dual_layout_lifecycle.sh computer-use`

Expected: PASS；typed factory、hipaa 早返回、默认/环境/settings/子配置行为不退化。

- [ ] **Step 5: 提交**

```bash
git add cc-patch-manager.sh tests/test_computer_use_integration.sh tests/test_dual_layout_lifecycle.sh
git commit -m "feat: migrate computer use to split esm"
```

### Task 4.1: TUI、--check 与诊断

**Files:** Modify `cc-patch-manager.sh:471-564,3289-3707`, `tests/test_target_descriptor.sh`, `tests/test_patch_plan_contract.sh`.

**Interfaces:** Consumes `TARGET_PACKAGE`, `TARGET_VERSION`, `TARGET_LAYOUT`, `MISSING_TARGET`, `AMBIGUOUS_TARGET`, `ROLLBACK`; produces Bash globals and中文状态。

- [ ] **Step 1: 写失败输出断言**

```bash
out=$(./cc-patch-manager.sh "$(fixture_entry "$tmp/new")" --check || true)
grep -F '包: @cometix/anthropic-cc 2.1.259 (split-esm)' <<<"$out"
grep -F '缺失目标: host-cleanup' <<<"$out"
```

- [ ] **Step 2: 确认红灯**

Run: `bash tests/test_target_descriptor.sh && bash tests/test_patch_plan_contract.sh`

Expected: FAIL；状态 parser 只理解旧标记。

- [ ] **Step 3: 实施协议映射**

```bash
case "$line" in
  TARGET_PACKAGE:*) TARGET_PACKAGE=${line#TARGET_PACKAGE:} ;;
  TARGET_VERSION:*) TARGET_VERSION=${line#TARGET_VERSION:} ;;
  TARGET_LAYOUT:*) TARGET_LAYOUT=${line#TARGET_LAYOUT:} ;;
  MISSING_TARGET:*) err_msg="缺失目标: ${line#MISSING_TARGET:}" ;;
  AMBIGUOUS_TARGET:*) err_msg="目标歧义: ${line#AMBIGUOUS_TARGET:}" ;;
esac
```

- [ ] **Step 4: 复跑**

Run: `bash tests/test_target_descriptor.sh && bash tests/test_patch_plan_contract.sh`

Expected: PASS；目标身份和布局可见，错误含 patch、阶段、文件和语义目标。

- [ ] **Step 5: 提交**

```bash
git add cc-patch-manager.sh tests/test_target_descriptor.sh tests/test_patch_plan_contract.sh
git commit -m "feat: report package layout and patch diagnostics"
```

### Task 4.2: apply-all 独立事务

**Files:** Modify `cc-patch-manager.sh:3589-3637`, `tests/test_fast_apply_all.sh`, `tests/test_package_baseline_transaction.sh`.

**Interfaces:** Consumes `PATCH_IDS`, `run_node_patch`, `STATUS`, `MSG`; produces a one-confirmation fixed-order loop and summary.

- [ ] **Step 1: 写失败继续测试**

```bash
CC_PATCH_TEST_FAIL_PATCH=transcript-dialog apply_all_patches <<< $'\n'
assert_eq "${STATUS[transcript-dialog]}" error 'failing transaction reported'
assert_eq "${STATUS[ultracode]}" applied 'next transaction continued'
```

- [ ] **Step 2: 确认红灯**

Run: `bash tests/test_fast_apply_all.sh && bash tests/test_package_baseline_transaction.sh`

Expected: FAIL；runtime 错误尚未按项隔离。

- [ ] **Step 3: 实施固定循环**

```bash
for id in "${PATCH_IDS[@]}"; do
  info "应用: $(patch_name "$id")..."
  if run_node_patch "$id" apply; then success "  → ${MSG[$id]}"; else error "  → 失败: ${MSG[$id]}"; fi
done
print_apply_all_summary
```

- [ ] **Step 4: 复跑**

Run: `bash tests/test_fast_apply_all.sh && bash tests/test_package_baseline_transaction.sh`

Expected: PASS；没有批量预检/复检，失败回滚，后续继续，计数正确。

- [ ] **Step 5: 提交**

```bash
git add cc-patch-manager.sh tests/test_fast_apply_all.sh tests/test_package_baseline_transaction.sh
git commit -m "test: continue apply-all after isolated failure"
```

### Task 4.3: 快速回归

**Files:** Modify `cc-patch-manager.sh`, `tests/test_*.sh` only for a test-proven dual-layout adapter regression.

**Interfaces:** Consumes all preceding APIs; produces complete fast suite and old single-CJS parity.

- [ ] **Step 1: 写并运行全套快速回归**

```bash
for test_file in tests/test_*.sh; do bash "$test_file"; done
```

- [ ] **Step 2: 确认失败可定位**

Run: `for test_file in tests/test_*.sh; do bash "$test_file"; done`

Expected: 若失败，精确定位 facade、基线兼容或补丁语义，绝不忽略退出码。

- [ ] **Step 3: 修复被断言覆盖的 facade 回归**

```bash
run_node_patch() {
  local id="$1" mode="$2" output ec=0
  set +e; output=$(runtime_exec "$mode" "$CLI_PATH" "$id" 2>&1); ec=$?; set -e
  LAST_OUTPUT="$output"; parse_and_set_status "$id" "$mode" "$output" "$ec"
}
```

- [ ] **Step 4: 复跑**

Run: `bash -n cc-patch-manager.sh && for test_file in tests/test_*.sh; do bash "$test_file"; done`

Expected: PASS；全部 Bash 测试零失败且旧七补丁语义保留。

- [ ] **Step 5: 提交**

```bash
git add cc-patch-manager.sh tests
git commit -m "test: complete dual-layout regression suite"
```

### Task 5.1: CometixSpace 2.1.224 副本验收

**Files:** Create `tests/test_real_package_acceptance.sh`; Modify `tests/lib/dual-layout-fixture.sh`.

**Interfaces:** Consumes `CC_PATCH_COMETIXSPACE_PACKAGE`; produces `accept_package root expectedName expectedVersion`.

- [ ] **Step 1: 写失败的缺参测试**

```bash
unset CC_PATCH_COMETIXSPACE_PACKAGE
bash tests/test_real_package_acceptance.sh cometixspace && fail 'missing source accepted'
```

- [ ] **Step 2: 确认红灯**

Run: `bash tests/test_real_package_acceptance.sh cometixspace`

Expected: FAIL；输出要求可信的 CometixSpace 2.1.224 package root。

- [ ] **Step 3: 实施临时副本矩阵**

```bash
accept_package() {
  local source="$1" expected_name="$2" expected_version="$3" copy entry before output status
  copy=$(mktemp -d)/package; cp -R "$source" "$copy"; entry="$copy/cli.js"; before=$(fixture_hash_tree "$copy")
  runtime_exec inspect "$entry" | grep -Fx "TARGET_PACKAGE:$expected_name"
  runtime_exec inspect "$entry" | grep -Fx "TARGET_VERSION:$expected_version"
  for id in "${PATCH_IDS[@]}"; do fixture_assert_lifecycle "$copy" "$id"; done
  node "$entry" --version; node "$entry" --help
  set +e; output=$(node "$entry" </dev/null 2>&1); status=$?; set -e
  grep -Eq 'SyntaxError|ERR_MODULE_NOT_FOUND|ReferenceError' <<<"$output" && fail "startup smoke failed (exit $status): $output"
  for id in "${PATCH_IDS[@]}"; do runtime_exec restore "$entry" "$id"; done
  fixture_assert_tree_equals "$before" "$(fixture_hash_tree "$copy")"
}
```

从已检出的 `v2.1.224` 源仓库生成可信 package；测试只消费生成物，不修改源仓库：

```bash
node /Users/tune/Downloads/code/CometixSpaceclaude-code/scripts/fetch-and-process.mjs \
  --version 2.1.224 --platforms darwin-arm64 \
  --output /private/tmp/cc-patch-cometixspace-2.1.224
cp /private/tmp/cc-patch-cometixspace-2.1.224/packages/darwin-arm64/cli.js \
  /private/tmp/cc-patch-cometixspace-2.1.224/main/cli.js
cp -R /private/tmp/cc-patch-cometixspace-2.1.224/packages/darwin-arm64/vendor \
  /private/tmp/cc-patch-cometixspace-2.1.224/main/vendor
```

- [ ] **Step 4: 运行真实验收**

Run: `CC_PATCH_COMETIXSPACE_PACKAGE=/private/tmp/cc-patch-cometixspace-2.1.224/main bash tests/test_real_package_acceptance.sh cometixspace`

Expected: PASS；七项矩阵、单项/全还原、树哈希和 CLI smoke 全部通过。

- [ ] **Step 5: 提交**

```bash
git add tests/lib/dual-layout-fixture.sh tests/test_real_package_acceptance.sh
git commit -m "test: accept cometixspace 2.1.224 in a copy"
```

### Task 5.2: cruce 2.1.259 副本与全局保护

**Files:** Modify `tests/test_real_package_acceptance.sh`, `tests/lib/dual-layout-fixture.sh`.

**Interfaces:** Consumes `CC_PATCH_CRUCE_PACKAGE`, default `/opt/homebrew/lib/node_modules/@cometix/anthropic-cc`; produces `assert_unchanged_tree`.

- [ ] **Step 1: 写全局树不变测试**

```bash
global=/opt/homebrew/lib/node_modules/@cometix/anthropic-cc
before=$(fixture_hash_tree "$global")
CC_PATCH_CRUCE_PACKAGE="$global" bash tests/test_real_package_acceptance.sh cruce
fixture_assert_tree_equals "$before" "$(fixture_hash_tree "$global")"
```

- [ ] **Step 2: 确认红灯**

Run: `CC_PATCH_CRUCE_PACKAGE=/opt/homebrew/lib/node_modules/@cometix/anthropic-cc bash tests/test_real_package_acceptance.sh cruce`

Expected: FAIL；直到入口被明确指向副本。

- [ ] **Step 3: 实施前后树检查**

```bash
global_before=$(fixture_hash_tree "$source")
accept_package "$source" '@cometix/anthropic-cc' 2.1.259
global_after=$(fixture_hash_tree "$source")
fixture_assert_tree_equals "$global_before" "$global_after"
```

- [ ] **Step 4: 运行真实验收**

Run: `CC_PATCH_CRUCE_PACKAGE=/opt/homebrew/lib/node_modules/@cometix/anthropic-cc bash tests/test_real_package_acceptance.sh cruce`

Expected: PASS；副本通过七项矩阵和 smoke，全局文件集合/哈希不变。

- [ ] **Step 5: 提交**

```bash
git add tests/lib/dual-layout-fixture.sh tests/test_real_package_acceptance.sh
git commit -m "test: protect global cruce during acceptance"
```

### Task 5.3: 发布前验证与范围审计

**Files:** Modify only test-proven defects in `cc-patch-manager.sh` and `tests/`.

**Interfaces:** Consumes complete fast suite and real acceptance; produces reproducible zero-failure verification.

- [ ] **Step 1: 运行完整验证**

```bash
bash -n cc-patch-manager.sh
for test_file in tests/test_*.sh; do bash "$test_file"; done
CC_PATCH_COMETIXSPACE_PACKAGE=/private/tmp/cc-patch-cometixspace-2.1.224/main bash tests/test_real_package_acceptance.sh cometixspace
CC_PATCH_CRUCE_PACKAGE=/opt/homebrew/lib/node_modules/@cometix/anthropic-cc bash tests/test_real_package_acceptance.sh cruce
```

- [ ] **Step 2: 确认绿色结果**

Run: 按 Step 1 顺序执行。

Expected: 每段退出码 0；两个副本树回到基线；全局 cruce 树不变。

- [ ] **Step 3: 依据失败断言修复最后问题**

```bash
for test_file in tests/test_*.sh; do
  bash "$test_file" || { bash "$test_file"; exit 1; }
done
```

- [ ] **Step 4: 审计范围**

Run: `git diff --check && git diff --name-only 12a8af769933ae4388cc6c86bcd80d87f7685a63..HEAD && git status --short`

Expected: 无空白错误；仅脚本、测试和当前 change 工件变动；真实上游无变动。

- [ ] **Step 5: 提交**

```bash
git add cc-patch-manager.sh tests docs/openspec/changes/adapt-cruce-split-esm docs/superpowers
git commit -m "feat: complete cruce split esm compatibility"
```

## Spec Coverage Review

| OpenSpec tasks | Plan tasks |
| --- | --- |
| 1.1-1.5 | 1.1-1.5 |
| 2.1-2.5 | 2.1-2.5 |
| 3.1-3.5 | 3.1-3.5 |
| 4.1-4.3 | 4.1-4.3 |
| 5.1-5.3 | 5.1-5.3 |

21 项 OpenSpec task 均有一对一实施任务；被后续任务调用的接口在 Shared Interfaces 或前序任务中定义。

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-09-03-adapt-cruce-split-esm.md`. Two execution options:

1. **Subagent-Driven (recommended)** - I dispatch a fresh subagent per task, review between tasks, fast iteration.

2. **Inline Execution** - Execute tasks in this session using executing-plans, batch execution with checkpoints.

Which approach?
