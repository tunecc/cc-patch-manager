# Comet Design Handoff

- Change: adapt-cruce-split-esm
- Phase: design
- Mode: compact
- Context hash: fa67a3c5dc7b2824cc3492cb1166a9c7479c88cf334fecea5e85dceb808aa035

Generated-by: comet-handoff.sh

OpenSpec remains the canonical capability spec. This handoff is a deterministic, source-traceable context pack, not an agent-authored summary.

## docs/openspec/changes/adapt-cruce-split-esm/proposal.md

- Source: docs/openspec/changes/adapt-cruce-split-esm/proposal.md
- Lines: 1-31
- SHA256: 851f1b27e5033a78f148803592af6f01eab252bc0b341001d376fb13fd678a8f

```md
## Why

现有补丁管理器以 CometixSpace `@cometix/claude-code` 2.1.224 及更早版本的单文件 CommonJS `cli.js` 为目标。当前改用的 cruce `@cometix/anthropic-cc` 2.1.259 自 2.1.242 起采用入口文件加约 1400 个 ESM chunks 的拆分布局，导致目标发现、七个补丁的 AST 定位以及单文件备份/还原全部失效，因此需要在保留旧布局兼容的同时增加目录级补丁能力。

## What Changes

- 继续在当前 `cc-patch-manager` 仓库维护同一个 `cc-patch-manager.sh`，不因上游 fork 变化新建仓库。
- 自动发现旧 `@cometix/claude-code` 与新 `@cometix/anthropic-cc` 安装，并通过入口结构识别 `single-cjs` 或 `split-esm`，同时保留显式路径和 `CLAUDE_CLI_PATH` 用法。
- 为 split-ESM 建立基于稳定语义 marker、模块 import/export 索引和 AST 唯一确认的候选文件定位机制，不依赖 chunk 哈希名、压缩变量名或固定偏移。
- 使 Auto Mode、Keybindings、权限弹窗重放、Ultracode、VoiceMode、Context Limit 和 Computer Use 七个补丁均可生成和验证跨文件 patch plan。
- 将单文件基线升级为带 package 身份、版本、布局和文件哈希的包级 manifest 与文件镜像，并以事务方式执行多文件写入和故障回滚。
- 保留单补丁还原时“恢复干净基线后重打其他补丁”的现有语义，并将 VoiceMode 的 ASR vendor 资源纳入同一事务。
- 增加 single-CJS 与 split-ESM 的合成 fixture、事务故障测试，以及 CometixSpace 2.1.224 和 cruce 2.1.259 真实包临时副本验收。

## Capabilities

### New Capabilities

- `patch-manager-dual-layout`: 定义补丁管理器对 CometixSpace single-CJS 与 cruce split-ESM 安装的目标发现、七补丁生命周期、多文件事务、备份还原和验证要求。

### Modified Capabilities

无。当前 OpenSpec 主规格中尚无既有 capability。

## Impact

- 主要实现文件：`cc-patch-manager.sh`。
- 测试范围：现有 `tests/*.sh` 以及为双布局、跨模块分析和事务故障新增的测试 fixture/脚本。
- 运行时影响：读取目标 npm package 目录；应用补丁时修改匹配的 `cli.js`/chunk 文件、管理包级基线，并在 VoiceMode 场景管理 `vendor/cometix-asr`。
- 兼容边界：明确验收 CometixSpace 2.1.224 与 cruce 2.1.259；未来版本仅在语义目标能够唯一确认时允许写入。
- 非目标：不修改 CometixSpace 或 cruce 上游仓库，不把补丁接入其构建发布流水线，不重新打包或发布 Claude Code，不承诺本次新增官方原生 `@anthropic-ai/claude-code` 的兼容能力。

```

## docs/openspec/changes/adapt-cruce-split-esm/design.md

- Source: docs/openspec/changes/adapt-cruce-split-esm/design.md
- Lines: 1-90
- SHA256: 524a34680ade24716c38972ebfd0f4535d3aa15455c3ab01451e03d04eca4637

[TRUNCATED]

```md
## Context

参见 `proposal.md` 的动机与范围。现有 `cc-patch-manager.sh` 以单一 `CLI_PATH` 为核心，每个补丁生成一个 Node AST 脚本并直接读写同一个 `cli.js`；共享恢复点也是 `cli.js.cc-patch-baseline`。本机验证表明，该脚本对已安装的 cruce 2.1.259 七项检查全部失败。cruce 自 2.1.242 起使用约 1400 个相互导入的 ESM chunks，且 chunk 名称随构建变化。

本地探测也证明部分现有 AST 规则仍然有效：Auto Mode 可在候选 chunk 中识别，Keybindings 也能在另一个 chunk 中识别。这说明应保留各补丁的语义分析能力，替换目标模型和执行事务，而不是按 2.1.259 重新硬编码文件名。

## Goals / Non-Goals

**Goals:**

- 将目标从单一文件提升为包含 package 身份、入口和布局的描述对象。
- 让七个独立补丁引擎能够分析并提交多文件 patch plan。
- 在不扫描解析全部 chunks 的前提下，通过文本 marker 预筛和 AST 唯一确认获得可接受的检测性能。
- 为多文件和 VoiceMode vendor 资源提供可信基线、事务写入与故障回滚。
- 最大限度保留 single-CJS 的成熟 AST 匹配与现有 TUI 行为。

**Non-Goals:**

- 不把补丁逻辑并入 cruce 或 CometixSpace 的构建流程。
- 不合并、重打包或重新发布 split-ESM bundle。
- 不以 chunk 名称、当前压缩变量名或版本分支替代语义分析。
- 不保证未经真实包验收的未来 Claude Code 版本；未来版本必须通过同一完整性门禁。

## Decisions

### 1. 保留当前仓库与单一脚本入口

继续在 `cc-patch-manager` 中维护 `cc-patch-manager.sh`。仓库表达的是独立的本地补丁管理能力，而非某个恢复版 fork 的附属项目；另开仓库会复制七补丁历史、VoiceMode 资产和测试体系，并制造两套行为契约。

备选方案是把补丁注入 cruce 构建流水线，或先把 ESM chunks 合并回单文件。前者失去安装后独立管理与旧上游兼容，后者会引入循环依赖、动态 import 和资源路径风险，均不采用。

### 2. 使用 TargetDescriptor 和结构化布局检测

目标解析结果统一为 `TargetDescriptor` 概念，至少包含 package root、entry path、package name、version、layout 与入口身份哈希。显式参数、`CLAUDE_CLI_PATH` 和自动发现最终都进入同一解析流程。

自动发现增加 `@cometix/anthropic-cc/cli.js`，保留 `@cometix/claude-code/cli.js`。布局检测读取入口 AST/import 结构和相邻模块存在性：入口为 ESM 且引用同目录拆分模块时判定 `split-esm`，否则按现有单 bundle 约束判定 `single-cjs`。版本仅用于诊断和基线身份，不控制匹配分支。

### 3. 两阶段候选定位与轻量模块索引

split-ESM 分析先枚举 package 自有 JS 文件，排除 `node_modules` 与补丁管理器基线目录。每个补丁提供一组稳定文本 marker，将约 1800 个文件收敛为少量候选；只有候选文件进入 Acorn module AST 分析。

模块索引记录候选文件的静态 import、export、本地别名与相对模块路径。补丁需要跨文件识别 helper 或绑定时，沿已解析的 import/export 边解析，不根据压缩名称猜测。索引不执行模块，也不尝试构建完整运行时代码图。

每个补丁的分析器返回结构化 `PatchPlan`：必要目标结果、受影响文件、按文件分组的 replacements、资源操作、已应用判定和验证器。`check`、`apply` 与补丁后 verify 复用同一分析路径，只通过模式参数决定是否提交计划。

### 4. 七补丁按语义目标拆分

- Auto Mode：模型资格门禁、分类器不可用决策与分类模型来源独立定位。
- Keybindings：功能开关与默认 `ctrl+c` 映射独立定位。
- 权限弹窗重放：使用 module AST，分别确认 dialog channel factory 与 host cleanup。
- Ultracode：分别确认 xhigh 资格、max 回退与激活状态语义。
- VoiceMode：入口门禁、流能力、可用性、设置 schema、连接函数、认证探针和 feature flag 分别定位，并把 ASR vendor 操作加入计划。
- Context Limit：确认语义相关的 200K 默认值和设置环境加载路径，通过模块绑定分析保证 settings env 生效后限制值可刷新。
- Computer Use：分别确认 settings schema、启用门禁与配置合并路径，并解析所需设置 helper 的跨模块绑定。

分析器对每个必要目标声明期望基数和后置条件。目标不完整或歧义时整个补丁计划无效，禁止降级为部分成功。

### 5. 包级基线和多文件事务

基线存储在目标 package 内的专用隐藏目录，包含 manifest 与按相对路径镜像的原始内容。manifest 记录 schema 版本、package 名称、package 版本、layout、入口身份哈希，以及每个受管路径的原始哈希、文件模式或原始不存在状态。对 single-CJS 保留旧基线读取兼容，但新写入统一进入包级格式。

应用流程先在内存中生成全部新内容并完成 AST 与补丁后置条件验证，再建立缺失的干净基线条目。提交阶段为每个目标生成同目录临时文件并保留本次事务前镜像，然后替换正式文件。任何写入失败都会按事务前镜像恢复已经触及的路径；基线不能替代事务前镜像，因为当前文件可能已包含其他补丁。

单补丁还原先记录当前已应用补丁集合，校验 manifest 身份，恢复所有受管路径至干净基线，再按原顺序重打除目标外的补丁。VoiceMode 新建目录和文件通过“原始不存在”记录精确删除，已有资源则按镜像恢复。

### 6. 每补丁独立事务的 Apply All

`apply-all` 保留一次用户确认和既有补丁顺序，但每个补丁分别分析、验证和提交。一个补丁失败时，该补丁回滚到事务前状态，然后继续后续补丁；最终汇总区分成功、已应用跳过与失败。这在保持现有交互效率的同时，将故障范围限制到单个补丁。

### 7. 分层验证

现有 Bash 测试风格继续作为测试入口。为每个补丁补充最小 single-CJS 与 split-ESM fixture，后者使用多个具备真实 import/export 关系的模块。共享测试覆盖目标发现、布局识别、模块别名解析、manifest 身份、逐文件哈希、幂等应用、单补丁还原和故障注入。

最终验收使用 CometixSpace 2.1.224 与 cruce 2.1.259 的真实 package 临时副本，不修改当前全局安装。每个版本执行七补丁生命周期，并对补丁结果运行版本、帮助和启动级冒烟检查。未来版本只有在相同分析与验证门禁通过后才允许写入。

## Risks / Trade-offs

- [压缩构建的语义形状仍会变化] -> 使用 marker 预筛、AST 基数和后置条件快速失败，并用真实版本 fixture 固化已验证范围。
- [跨 chunk import/export 解析增加复杂度] -> 索引只覆盖静态相对导入和补丁候选依赖，不实现通用 bundler 或动态执行。
- [多文件写入无法获得文件系统级全局原子性] -> 写前全量验证、同目录临时文件和事务前镜像将失败窗口降到最低，并对中途故障执行恢复测试。

```

Full source: docs/openspec/changes/adapt-cruce-split-esm/design.md

## docs/openspec/changes/adapt-cruce-split-esm/tasks.md

- Source: docs/openspec/changes/adapt-cruce-split-esm/tasks.md
- Lines: 1-35
- SHA256: 93c45b818ccf3151770e88a1936f9b5123deaffb72d7f7632348c5a64aa1e147

```md
## 1. 双布局目标与分析基础

- [ ] 1.1 为显式路径、`CLAUDE_CLI_PATH`、旧 `@cometix/claude-code` 与新 `@cometix/anthropic-cc` 自动发现编写失败测试，并验证测试能够区分优先级和无效 package
- [ ] 1.2 实现 TargetDescriptor 与结构化 `single-cjs`/`split-esm` 检测，并通过 1.1 的目标解析测试及现有路径行为回归测试
- [ ] 1.3 为 marker 预筛、ESM 静态 import/export 别名和跨 chunk 绑定解析编写最小多模块失败 fixture，并验证歧义、缺失导出和 `node_modules` 排除场景均被覆盖
- [ ] 1.4 实现候选文件扫描与轻量模块索引，并通过 1.3 测试且确认对 cruce 2.1.259 只解析 marker 命中的候选模块
- [ ] 1.5 定义共享 PatchPlan 的必要目标基数、按文件 replacements、资源操作、已应用状态和后置验证合同，并通过 check/apply 共用分析路径及“不完整计划零写入”测试

## 2. 包级基线与事务

- [ ] 2.1 为 package 身份、版本、布局、入口哈希、逐路径原始哈希/模式/不存在状态编写 manifest 失败测试，并覆盖陈旧基线与未知修改拒绝场景
- [ ] 2.2 实现包级 manifest 和相对路径基线镜像，保留 single-CJS 旧基线读取兼容，并通过 2.1 与现有单文件基线测试
- [ ] 2.3 为多文件写前校验、临时文件替换、中途 I/O 故障和 VoiceMode 资源操作编写事务故障测试，并验证所有故障场景恢复到事务前逐文件哈希
- [ ] 2.4 实现 PatchPlan 事务提交与故障恢复，并通过 2.3 测试及 AST/后置条件失败零写入测试
- [ ] 2.5 实现包级恢复、单补丁移除和其余已应用补丁重打，并通过跨文件补丁组合、VoiceMode 原始不存在资源和幂等恢复测试

## 3. 七补丁 split-ESM 迁移

- [ ] 3.1 先增加 Auto Mode 与 Keybindings 的 split-ESM 多模块失败 fixture，再迁移两者的候选定位和 PatchPlan 生成，并通过新 fixture 与现有 single-CJS 回归测试
- [ ] 3.2 先增加权限弹窗重放与 Ultracode 的 split-ESM 多模块失败 fixture，再迁移 module AST、channel/cleanup 及 xhigh/max/激活目标，并通过新旧布局生命周期测试
- [ ] 3.3 先增加 VoiceMode 七类语义目标和 ASR vendor 操作的 split-ESM 失败 fixture，再迁移 VoiceMode PatchPlan，并通过平台门禁、资源缺失、应用、复检和还原测试
- [ ] 3.4 先增加 Context Limit 跨模块默认值与 settings env 刷新失败 fixture，再实现绑定解析和补丁后刷新语义，并通过环境变量、settings env、幂等与恢复测试
- [ ] 3.5 先增加 Computer Use 跨模块 schema、启用门禁、配置合并与 settings helper 失败 fixture，再迁移 PatchPlan，并通过默认关闭、环境变量、settings、部分状态修复与恢复测试

## 4. 交互、诊断与批量行为

- [ ] 4.1 更新 TUI 与 `--check` 输出以显示 package、版本和布局，并通过旧新目标快照测试及错误信息包含补丁 ID、阶段、候选文件和缺失目标的断言
- [ ] 4.2 保持 `apply-all` 一次确认和固定补丁顺序，为单补丁事务失败后继续后续补丁编写测试，并验证最终成功/跳过/失败汇总准确
- [ ] 4.3 运行全部现有测试并修复仅由目标抽象或包级基线引起的回归，验证 `tests/test_*.sh` 全部通过且旧 single-CJS 七补丁行为不退化

## 5. 真实包验收

- [ ] 5.1 获取或构建 CometixSpace 2.1.224 package 临时副本，在副本中完成七补丁 check/apply/幂等/单补丁还原/全还原矩阵，并验证还原后逐文件哈希与基线一致及 CLI 冒烟通过
- [ ] 5.2 复制本机 cruce 2.1.259 package 到临时目录，在副本中完成七补丁 check/apply/幂等/单补丁还原/全还原矩阵，并验证当前全局安装哈希未改变及 CLI 冒烟通过
- [ ] 5.3 运行 Shell 语法检查、全部快速测试和双真实版本验收，记录每项命令与结果，并确认 Git diff 只包含获准的脚本、测试和 Comet/OpenSpec 产物

```

## docs/openspec/changes/adapt-cruce-split-esm/specs/patch-manager-dual-layout/spec.md

- Source: docs/openspec/changes/adapt-cruce-split-esm/specs/patch-manager-dual-layout/spec.md
- Lines: 1-92
- SHA256: 04c8b893f46c41668ddad823a5f5dd78bba5bb318cad2a4a091eb825118bb896

[TRUNCATED]

```md
## Purpose

为同一个 Claude Code 本地补丁管理器定义可验证的双布局兼容契约，使七个补丁能在旧版单文件包和新版拆分 ESM 包上安全检测、应用、复检与还原。

## ADDED Requirements

### Requirement: 双上游目标发现与布局识别
补丁管理器 SHALL 自动发现 CometixSpace `@cometix/claude-code` 与 cruce `@cometix/anthropic-cc` 的全局或本地安装，并 MUST 保留显式路径和 `CLAUDE_CLI_PATH` 的目标指定方式。管理器 SHALL 根据入口与相邻模块的实际结构识别 `single-cjs` 或 `split-esm`，不得仅依赖版本号推断布局。

#### Scenario: 自动发现 cruce 安装
- **WHEN** 系统仅安装 `@cometix/anthropic-cc` 且其入口为 split-ESM 布局
- **THEN** 管理器选择该 package 的 `cli.js`，报告 package 名称、版本和 `split-esm` 布局

#### Scenario: 保留旧 CometixSpace 安装
- **WHEN** 目标是 `@cometix/claude-code` 2.1.224 的单文件 bundle
- **THEN** 管理器识别为 `single-cjs` 并继续支持原有七补丁流程

#### Scenario: 显式路径优先
- **WHEN** 用户传入有效入口路径或设置有效的 `CLAUDE_CLI_PATH`
- **THEN** 管理器使用显式目标并从该入口解析 package 根和布局

### Requirement: 七补丁双布局生命周期
Auto Mode、Keybindings、权限弹窗重放、Ultracode、VoiceMode、Context Limit 和 Computer Use 七个补丁 SHALL 在两种布局上提供一致的 `check`、`apply`、幂等复检和 `restore` 生命周期。split-ESM 目标定位 MUST 基于稳定语义与结构确认，不得依赖 chunk 哈希文件名、压缩变量名或固定字符偏移。

#### Scenario: split-ESM 补丁跨多个模块
- **WHEN** 一个补丁的必要目标分布在多个 ESM chunks
- **THEN** 管理器将全部必要文件纳入同一个 patch plan，并在全部目标唯一确认后才允许应用

#### Scenario: 二次应用保持幂等
- **WHEN** 用户对已经完整应用的任一补丁再次执行应用
- **THEN** 管理器报告该补丁已应用，且目标 package 中没有文件内容变化

#### Scenario: 旧布局行为不回归
- **WHEN** 七个补丁针对 CometixSpace 2.1.224 执行完整生命周期
- **THEN** 每个补丁仍能检测、应用、复检和还原，并保持已有用户可见功能语义

### Requirement: 语义目标必须完整且无歧义
每个补丁 MUST 声明其必要语义目标集合。任何必要目标缺失、出现多个无法区分的候选，或跨模块绑定无法可靠解析时，管理器 MUST 拒绝写入该补丁的所有文件，并提供可定位的错误信息。

#### Scenario: 缺失必要目标
- **WHEN** 新版本中缺少某补丁声明的必要语义目标
- **THEN** 应用失败且不修改目标 package，错误包含补丁 ID、缺失目标和已检查的候选文件

#### Scenario: 候选目标存在歧义
- **WHEN** AST 分析得到多个同等有效且无法唯一确认的目标
- **THEN** 应用失败且不选择任一候选进行猜测性写入

### Requirement: 单补丁多文件事务
单个补丁的应用 SHALL 是全有或全无的多文件事务。管理器 MUST 在写入前完成所有替换结果的语法和补丁后置条件校验；若实际写入期间失败，MUST 恢复本次事务开始前的所有文件和资源状态。

#### Scenario: 写入前验证失败
- **WHEN** patch plan 中任一目标文件无法通过补丁后 AST 校验或后置条件
- **THEN** 管理器不写入任何目标文件并报告失败文件与验证原因

#### Scenario: 中途写入失败
- **WHEN** 多文件写入在部分文件替换后发生 I/O 故障
- **THEN** 管理器使用事务快照恢复所有已触及路径，并报告回滚结果

#### Scenario: Apply All 部分失败
- **WHEN** `apply-all` 中一个补丁事务失败而其他补丁可成功应用
- **THEN** 失败补丁不留下部分修改，其他补丁事务可继续，最终汇总逐项报告成功、跳过或失败

### Requirement: 包级基线与精确还原
管理器 SHALL 为目标 package 维护一份带 package 名称、版本、布局、入口身份和逐文件哈希的可信基线 manifest，并保存所有被补丁触及路径的原始内容或原始不存在状态。单补丁还原 SHALL 先恢复干净基线，再重打还原前处于已应用状态的其他补丁。

#### Scenario: 还原单个跨文件补丁
- **WHEN** 多个补丁已应用且用户还原其中一个跨文件补丁
- **THEN** 所有基线路径先恢复为原始状态，目标补丁保持移除，其余先前已应用补丁重新应用并通过复检

#### Scenario: VoiceMode 资源还原
- **WHEN** VoiceMode 应用时创建或替换 `vendor/cometix-asr` 资源，随后用户还原 VoiceMode
- **THEN** JS 文件和 vendor 资源均恢复到基线记录的内容或不存在状态

#### Scenario: 基线与已升级 package 不匹配
- **WHEN** 当前 package 身份、版本、布局或入口哈希与基线 manifest 不一致
- **THEN** 管理器禁止跨版本还原并要求恢复干净安装或明确重建基线

#### Scenario: 未知修改且无可信基线
- **WHEN** 管理器检测到已有补丁或未知修改但没有可验证的干净基线
- **THEN** 管理器不得静默把当前内容当作干净原件，并给出建立可信恢复点所需的操作说明

```

Full source: docs/openspec/changes/adapt-cruce-split-esm/specs/patch-manager-dual-layout/spec.md
