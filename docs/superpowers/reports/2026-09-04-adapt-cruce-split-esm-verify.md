# 验证报告：adapt-cruce-split-esm

- 变更：`adapt-cruce-split-esm`
- 分支：`feature/20260903/adapt-cruce-split-esm`
- 基线（base-ref）：`12a8af769933ae4388cc6c86bcd80d87f7685a63`
- 规模评估：full（任务 21 > 3，delta 能力 1，变更文件 36 > 8）
- 验证模式：`full`；代码审查模式：`thorough`
- 语言：`zh-CN`
- 验证日期：2026-09-04

## 摘要

| 维度 | 状态 |
| --- | --- |
| 完整性 Completeness | 21/21 任务完成；6 项 delta 需求全覆盖 |
| 正确性 Correctness | 6 项需求均有实现与测试映射；场景覆盖见下 |
| 一致性 Coherence | 7 项设计决策均落实；与项目模式一致 |
| 构建/语法 | `bash -n cc-patch-manager.sh` → SYNTAX_OK |
| 快速套件 | 14/14 PASS |
| 真实包验收 | cometixspace 2.1.224（6 适用/1 记录不适用）EXIT=0；cruce 2.1.259（7 适用）PASS |
| 范围审计 | `git diff --check` 无空白错误；仅脚本/测试/change 工件/Comet 元数据；真实上游未改动 |
| 集成代码审查 | CRITICAL（C1）+ IMPORTANT（I1、I2）已修复闭环（见“修复闭环”节）；WARNING/SUGGESTION 非阻断 |

## 1. 完整性 Completeness

### 任务完成

OpenSpec `instructions apply` 报告：`total: 21, complete: 21, remaining: 0`。tasks.md 全部 `[x]`。

### 需求覆盖

delta spec `specs/patch-manager-dual-layout/spec.md` 声明 6 项 ADDED 需求，全部由实现与测试覆盖：

| # | 需求 | 主要实现位置 | 主要测试 |
| - | --- | --- | --- |
| 1 | 双上游目标发现与布局识别 | `inspectTarget`、`findPackageRoot`、single-cjs/split-esm 结构检测 | `tests/test_target_descriptor.sh`、`tests/test_module_index.sh` |
| 2 | 七补丁双布局生命周期 | 各补丁分析器 + `PatchPlan` | `tests/test_dual_layout_lifecycle.sh`、`tests/test_auto_mode_engine.sh`、`tests/test_computer_use_integration.sh`、`tests/test_context_limit_integration.sh`、`tests/test_voice_mode_gate.sh`、`tests/test_voice_mode_platform.sh` |
| 3 | 语义目标必须完整且无歧义 | `validatePlan`（缺失抛 `missing semantic target: <id>`）、必要目标基数 | `tests/test_patch_plan_contract.sh`、`tests/test_module_index.sh`（歧义/缺失导出） |
| 4 | 单补丁多文件事务 | `commitTransaction`（preflight + 写入双校验 `expectedBeforeHash`）、`commitPlanTransaction` 回滚、apply-all 分补丁独立事务 | `tests/test_package_baseline_transaction.sh`、`tests/test_fast_apply_all.sh` |
| 5 | 包级基线与精确还原 | 包级 manifest（身份/版本/布局/入口哈希/逐路径哈希模式）、`restorePatchFromBaseline`（基线→重打）、`restoreAllFromBaseline` | `tests/test_package_baseline_transaction.sh`、`tests/test_restore_skips_missing_target.sh`、`tests/test_restore_all_baseline.sh` |
| 6 | 受支持版本的真实包验收 | `tests/test_real_package_acceptance.sh`（cometixspace + cruce 副本矩阵 + smoke + 源保护） | `tests/test_real_package_acceptance.sh` |

## 2. 正确性 Correctness

### 需求→实现映射与场景覆盖

1. **双上游目标发现与布局识别** — `inspectTarget` 解析显式路径/`CLAUDE_CLI_PATH`/自动发现；入口 AST + 相邻模块结构决定 `single-cjs`/`split-esm`，不依版本号。场景“自动发现 cruce”“保留 CometixSpace 2.1.224”“显式路径优先”由 `test_target_descriptor.sh` 覆盖；真实包 `inspect` 输出 `TARGET_PACKAGE/TARGET_VERSION/TARGET_LAYOUT` 在两版本验收中实证。
2. **七补丁双布局生命周期** — `test_dual_layout_lifecycle.sh` 在 single-cjs 与 split-esm 两布局跑同套生命周期；split-ESM 定位用 marker 预筛 + 模块索引 + AST 基数，不依赖 chunk 哈希名/压缩变量/偏移（见 design decision 3）。幂等复检（`ALREADY_PATCHED` 零写入）由各补丁测试与真实包矩阵实证。
3. **语义目标必须完整且无歧义** — `validatePlan` 在必要目标缺失时抛 `missing semantic target: <id>`，`check` 报 `MISSING_TARGET:`；歧义候选由 AST 基数拒绝。`test_patch_plan_contract.sh` 覆盖基数与“不完整计划零写入”；`test_module_index.sh` 覆盖歧义绑定与缺失导出。
4. **单补丁多文件事务** — `commitTransaction` 在 preflight 与写入两阶段均校验 `expectedBeforeHash/Mode`（`cc-patch-manager.sh:3503-3511, 3533-3538`），任一不符抛 `transaction source changed after analysis`；写前全量 AST + 后置条件校验在 `commitPlanTransaction` 前；中途失败按事务前镜像回滚。apply-all 每补丁独立事务，失败仅回滚该补丁，其余继续，汇总区分成功/跳过/失败（`test_fast_apply_all.sh`）。
5. **包级基线与精确还原** — manifest 记录 schema/package 名/版本/layout/入口哈希/逐路径哈希模式/原始不存在；`assertBaselineIdentity`/`assertBaselineMirrors` 守门；身份不符禁止还原。单补丁还原先恢复干净基线再重打已应用补丁；`restorePatchFromBaseline` 重分析全部注册补丁以发现 retained，对非 removeId 的 MISSING_TARGET 容忍（null-plan + 可选链，`cc-patch-manager.sh:4034-4051`）。`restoreAllFromBaseline` 全还原不重打（大数据包可-path）。VoiceMode 资源（vendor/cometix-asr）纳入同事务，按“原始不存在”精确删除（`test_voice_mode_platform.sh`、真实包验收）。
6. **真实包验收** — `test_real_package_acceptance.sh` 在临时副本跑七补丁矩阵 + smoke（`--version`）+ 全还原 + 树哈希==基线 + 源保护（源包前后哈希一致）。cometixspace 2.1.224：6 适用，context-limit 记录为不适用（MISSING_TARGET）；cruce 2.1.259：7 适用。均不修改用户当前安装（源保护断言通过）。

### 已记录的适用性偏差

- **context-limit 在 CometixSpace 2.1.224 单 CJS 上为 MISSING_TARGET**：真实 2.1.224 将 `applyConfigEnvironmentVariables` 暴露为独立 export-map 函数，而非类 `MethodDefinition`；context-limit 分析器匹配 `MethodDefinition`，故锚点缺失。已按用户先前决定“记录该限制”处理——分析器未改写以匹配独立函数；修复使还原容忍该限制（不中止其它补丁还原），而非逆转该不适用。其余六补丁在 2.1.224 全矩阵通过，context-limit 在 cruce 2.1.259 适用。此为受支持版本边界上的已知限制，非缺陷。

## 3. 一致性 Coherence

### 设计决策落实

design.md 7 项决策全部落实：

1. 保留单仓库单脚本入口 — `cc-patch-manager.sh` 一处维护。
2. `TargetDescriptor` + 结构化布局检测 — 实现，版本仅诊断。
3. 两阶段候选定位 + 轻量模块索引 — marker 预筛 + 静态 import/export 别名解析，不执行模块，排除 node_modules/.cc-patch-manager-。
4. 七补丁按语义目标拆分 — 各补丁独立分析器，声明基数与后置条件。
5. 包级基线 + 多文件事务 — manifest + 同目录临时文件 + 事务前镜像 + 故障回滚；single-CJS 旧基线读取兼容。
6. 每补丁独立事务的 apply-all — 实现，失败隔离。
7. 分层验证 — 合成 fixture（快速）+ 真实包副本验收（发布前）。

### 代码模式一致性

新代码沿用既有 bash + 嵌入 Node AST 运行时风格；机器协议 token（`TARGET_PACKAGE`/`NEEDS_PATCH`/`MISSING_TARGET:`/`PATCHED`/`RESTORED`/`RESTORE_REAPPLIED` 等）与 `fail()`→`console.error('TARGET_ERROR:'+...)` 约定一致。新增测试沿用 `tests/lib/dual-layout-fixture.sh` 原语与 `set -euo pipefail` + `fail()` 模式。

## 4. 构建/语法与测试证据

| 命令 | 结果 |
| --- | --- |
| `bash -n cc-patch-manager.sh` | SYNTAX_OK（exit 0） |
| 快速套件 `for t in tests/test_*.sh; do bash "$t"; done` | 14/14 PASS（auto-mode、computer-use、context-limit、dual-layout-lifecycle、fast-apply-all、module-index、package-baseline-transaction、patch-plan-contract、real-package-acceptance[SKIP]、restore-all-baseline、restore-skips-missing-target、target-descriptor、voice-mode-gate、voice-mode-platform） |
| `comet classic openspec -- validate adapt-cruce-split-esm` | Change is valid |
| cometixspace 2.1.224 真实包验收 | `PASS: cometixspace 2.1.224 real-package acceptance (6 applicable, 1 documented inapplicable)` EXIT=0（运行 4） |
| cruce 2.1.259 真实包验收 | `PASS: cruce 2.1.259 real-package acceptance (7 applicable, 0 documented inapplicable)`（全局树前后哈希一致） |

### cometixspace 验收复跑说明

2.1.224 单 CJS 入口 23MB，单次 acorn 解析约 80s，全量验收约 30–40 分钟。运行 4 已记录 PASS（EXIT=0）。5.2 增加的源保护为 `accept_package` 内共享代码，已由 cruce 验收（5.2）验证（source_before==source_after），且 `fixture_hash_package` 在 /tmp/ccp224real 上的确定性已直接复核（同包两次哈希相等）；5.2 未改动 cometixspace 生命周期逻辑，故组合一致，未重复 30–40 分钟重跑。

## 5. 范围审计

- `git diff --check`：NO_WHITESPACE_ERRORS。
- `git diff --name-only 12a8af7..HEAD`：`cc-patch-manager.sh` + 14 个测试文件 + docs（openspec change 目录 + superpowers 计划/设计/报告）+ Comet 元数据（`.comet/config.yaml`、`.gitignore`、`AGENTS.md`、`CLAUDE.md` 各 19 行 Comet 模板）。
- 真实上游未改动：cruce 全局安装 `/opt/homebrew/lib/node_modules/@cometix/anthropic-cc` 验收前后哈希不变；CometixSpace 源仓库未触动。

## 6. 集成代码审查

审查范围：base→HEAD 全 diff，聚焦正确性/安全/边界条件。审查者独立通读 `cc-patch-manager.sh`（~7440 行）与测试。以下为已核实发现（已对照源码确认，非误报）。

### CRITICAL（阻断归档）

- ~~**C1 — Bash `restore_patch` 路由在 split-ESM 上漏掉 4 个补丁**（`cc-patch-manager.sh:452`）。~~ **已修复（`480b7bd`）。** `restore_patch` 现在的判断为 `if [[ "$id" == "voice-mode" || -f "$(dirname "$CLI_PATH")/.cc-patch-manager-baseline/manifest.json" ]]; then`：包级 manifest 存在即对所有补丁走运行时还原；voice-mode 在无 manifest 的 single-CJS 旧引擎下仍始终走运行时。single-CJS 旧引擎（无 manifest）仍走遗留 `has_baseline` 路径，不回归。
  - 失败场景（原）：split-ESM cruce 2.1.259 上从菜单 apply `auto-mode`（运行时建包级基线）→ 菜单按 `[r]` 还原 → 命中 false 分支 → `has_baseline` 检查不存在的 `cli.js.cc-patch-baseline` → 报“未找到备份”。7 补丁中 4 个（auto-mode/keybindings/transcript-dialog/ultracode）在 split-ESM 菜单还原失效，违反需求 2。
  - 测试盲区（原）：现有测试直接调 `runtime_exec restore`（运行时层），未覆盖 Bash `restore_patch`（UI 层）对这 4 个补丁的路由。
  - 修复证据：新增 `assert_split_esm_restore_patch_routing`（`tests/test_dual_layout_lifecycle.sh`）对 4 个补丁在 split-ESM 副本上驱动 `restore_patch` UI 层：apply → `restore_patch` → 源哈希回基线 → 复检 idle。RED 复现“未找到备份”后 GREEN。快速套件 14/14 PASS；cruce 2.1.259 真实包验收（7 适用）EXIT=0。

### IMPORTANT（应修复）

- ~~**I1 — `restore-all` 无 Bash 接口入口**~~ **已修复（`480b7bd`）。** 新增 `restore_all_patches`（`cc-patch-manager.sh`）：包级 manifest 存在时路由到 `runtime_exec restore-all`，否则回退遗留单文件基线；还原后所有补丁 STATUS 置 idle。菜单增加 `[R] 全还原`（带 `confirm_restore_all` 的 `yes` 二次确认），CLI 增加 `--restore-all`（`run_restore_all_mode`）。`[r]` 刷新保留为小写专用，避免与 `[R]` 还原冲突。
  - 修复证据：`assert_restore_all_ui_split_esm` 驱动 UI 函数（apply 两补丁 → `restore_all_patches` → 源哈希回基线 + STATUS idle）；`assert_restore_all_cli_split_esm` 驱动 `bash cc-patch-manager.sh --restore-all` 端到端（合成 fixture）。另在真实 cruce 2.1.259 副本上跑 `--restore-all` CLI smoke：apply 两补丁改变源哈希 → `--restore-all` EXIT=0 → 源哈希回到基线（`09bd8177…`），全局安装哈希不变（源保护）。
- ~~**I2 — 还原失败消息硬编码“VoiceMode”**（`cc-patch-manager.sh:465`）。~~ **已修复（`480b7bd`）。** `MSG[$id]="$(patch_name "$id") 还原失败"`，并修正失败路径的隐性 `set -u` bug：`error "$MSG[$id]: $output"` 在 `set -u` 下把 `$MSG[$id]` 解析为 `${MSG[0]}`（关联数组无 "0" 键 → “MSG: unbound variable”），改为 `error "${MSG[$id]}: $output"`。该隐性 bug 此前从未被测试触发（旧测试只覆盖成功还原）。
  - 修复证据：`assert_restore_failure_message_uses_patch_name` 在 split-ESM 副本 apply auto-mode + keybindings，注入 `CC_PATCH_TEST_FAIL_REAPPLY=keybindings` 使运行时还原失败，断言 `MSG[auto-mode]` 含“自动模式解锁”且不含“VoiceMode”。

### WARNING（记录、择机处理）

- W1 — `show_detail`（`cc-patch-manager.sh:7331-7335`）用遗留 `has_baseline()` 显示“备份: (尚未创建)”，而包级基线已存在；UI 状态与实际不符。
- W2 — 多处分析器用空 `catch {}` 包装 `ModuleIndex.resolveLocal()`（`:2058, 2267, 2467, 2491, 2652, 2668`），会把瞬时 I/O 错误（权限/磁盘）吞成“missing semantic target”。非正确性错误（不会误写），但诊断信息不具操作性。
- W3 — `scanMarkerCandidateGroups`（`:959-966`）一次性把约 1800 个模块文件读入内存，且每个 marker 集重复读取；AST 缓存不防重复读取。性能/内存，非正确性。
- W4 — `excludedPackagePath`（`:789-795`）排除整个 `vendor/`；对当前 cruce 布局正确，但若未来 ESM chunk 移入 `vendor/` 则脆弱。

### SUGGESTION

- S1 — `parseProgram` 缓存驱逐（`:733-735`）每次解析 O(N) 全键扫描，N 文件总计 O(N²)（约 1800 文件 ~3.24M 次）。无正确性影响（驱逐在新增前，缓存有界）；可改二级 Map 实现 O(1)。

### 核查为稳健的领域

- 路径遍历/符号链接转义：`assertManagedPathSafe`（`:2918`）逐段拒绝符号链接并校验 realpath；`insideRoot`（`:710`）按分隔符边界比较；`packageFile`/`managedDestination` 均走此守门。稳健。
- 乐观并发：`expectedBeforeHash` 在 preflight（`:3503`）、快照（`:3532`）、rename 前（`:3601`）三处校验；分析与写入间任何修改被检出。稳健。
- 部分/模糊计划写入：`validatePlan`（`:2827`）在任何写入前抛缺失/歧义；`commitPlanTransaction` 仅在 `validatePlan` 返回后调用。稳健。
- 陈旧基线：`assertBaselineIdentity`（`:2988`）校验包名/版本/布局/入口身份/清单内部一致性，拒绝跨版本还原。稳健。
- restore-all 跳过 `assertManagedFilesAttributable`：对显式全重置安全（`restoreAllFromBaseline` 覆盖一切至基线，`commitTransaction` 的 `expectedBeforeHash` 防并发修改）；跳过有记录（`:4094-4098`）。稳健。
- 事务回滚 / VoiceMode 资源 / 基线发布回滚 / 遗留基线迁移：均核查稳健。

## 修复闭环（第二轮验证）

第一轮验证发现 C1（CRITICAL）+ I1/I2（IMPORTANT），按 comet-verify Step 1b 自动回到 build 修复（`verify_failures=1 < 3`，非用户决策点）。修复提交 `480b7bd`，复跑验证：

| 复跑项 | 命令 | 结果 |
| --- | --- | --- |
| 语法 | `bash -n cc-patch-manager.sh` | SYNTAX_OK |
| 快速套件 | `for t in tests/test_*.sh; do bash "$t"; done` | 14/14 PASS（含 4 个新增 UI 层测试） |
| cruce 2.1.259 真实包验收 | `bash tests/test_real_package_acceptance.sh cruce` | `PASS: cruce 2.1.259 real-package acceptance (7 applicable, 0 documented inapplicable)` EXIT=0；源保护断言全局安装前后哈希一致 |
| `--restore-all` CLI 端到端（真实 cruce 副本） | apply auto-mode + keybindings → `bash cc-patch-manager.sh --restore-all <entry>` | EXIT=0；源哈希回到基线 `09bd8177…`；全局安装哈希不变 |

新增 UI 层 TDD 测试（`tests/test_dual_layout_lifecycle.sh`，修复前 RED / 修复后 GREEN）：

- `assert_split_esm_restore_patch_routing` — C1：4 个非 voice/context/computer 补丁在 split-ESM 副本上经 `restore_patch`（UI 层，非 runtime_exec）还原成功，源哈希回基线、复检 idle。
- `assert_restore_failure_message_uses_patch_name` — I2：注入 `CC_PATCH_TEST_FAIL_REAPPLY` 使运行时还原失败，断言 `MSG[id]` 用 `patch_name`（含“自动模式解锁”）而非硬编码“VoiceMode”；同时覆盖了修复前 `$MSG[$id]` 在 `set -u` 下的隐性“unbound variable” bug。
- `assert_restore_all_ui_split_esm` — I1：驱动 `restore_all_patches` UI 函数，还原后源哈希回基线 + 全部 STATUS idle。
- `assert_restore_all_cli_split_esm` — I1：驱动 `bash cc-patch-manager.sh --restore-all` CLI 端到端，还原后源哈希回基线。

cometixspace 2.1.224 真实包验收未复跑：第一轮已记录 PASS（EXIT=0，6 适用/1 记录不适用），且本轮修复仅触及 split-ESM 受影响的 `restore_patch`/`restore_all_patches` UI 路由与 `--restore-all` 入口；cometixspace 2.1.224 为 single-CJS，其 `restore_patch` 在无包级 manifest 时仍走遗留 `has_baseline` 路径（未改动），且其验收直接调 `runtime_exec`（不经 Bash UI 层），故不受 C1/I1/I2 修复影响。组合一致，未重复 30–40 分钟重跑。

## 最终评估

**验证通过（PASS）。**

- C1（CRITICAL）已修复并经 UI 层 TDD + cruce 2.1.259 真实包验收实证。
- I1、I2（IMPORTANT）已修复并经 UI/CLI TDD + 真实 cruce `--restore-all` smoke 实证；I2 顺带修复了失败路径的隐性 `set -u` bug。
- 完整性 21/21、正确性 6/6、一致性 7/7；快速套件 14/14；双真实版本验收均 PASS；范围审计无空白错误且真实上游未改动。
- WARNING（W1–W4）与 SUGGESTION（S1）非阻断，记录择机处理；接受这些偏差继续归档（影响范围已在各条目内说明，均为非正确性、非安全问题）。

接受的 WARNING/SUGGESTION 偏差（非阻断，非用户决策点）：
- W1（`show_detail` 用遗留 `has_baseline` 显示“备份: (尚未创建)”而包级基线已存在，UI 状态与实际不符）— 仅展示层，不影响还原/应用正确性；择机与 W3/W4 一并在后续 UI 刷新迭代处理。
- W2（分析器空 `catch {}` 吞瞬时 I/O 错误为“missing semantic target”）— 非正确性错误（不误写），诊断不具操作性但安全；择机补错误区分。
- W3（`scanMarkerCandidateGroups` 一次性读约 1800 模块、每 marker 集重复读取）— 性能/内存，非正确性；AST 缓存有界。
- W4（`excludedPackagePath` 排除整个 `vendor/`，未来 ESM chunk 移入 `vendor/` 则脆弱）— 对当前 cruce 布局正确；未来布局变更时再评估。
- S1（`parseProgram` 缓存驱逐 O(N²)）— 无正确性影响；可改二级 Map 实现 O(1)。
