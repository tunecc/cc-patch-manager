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
- [包升级可能留下陈旧基线] -> manifest 绑定 package 身份、版本、布局与入口哈希，身份不一致时禁止还原或继续沿用。
- [真实包体积较大，完整测试成本上升] -> 日常单元测试使用最小 fixture，真实双版本生命周期作为发布前验收而非每个快速测试的强制步骤。

## Migration Plan

1. 先以测试锁定当前 single-CJS 行为和新的 TargetDescriptor/layout 合同。
2. 增加 split-ESM 候选扫描、模块索引和只读 `check`，在任何多文件写入前验证七补丁目标集合。
3. 引入包级 manifest、事务提交和还原，再逐个启用七补丁的 split-ESM apply。
4. 在临时真实包副本完成 2.1.224 与 2.1.259 验收后发布脚本更新。
5. 若迁移失败，代码回退到变更前版本；目标 package 则从事务镜像或可信基线恢复。陈旧或不可信基线不得用于跨版本恢复，必要时重新安装对应上游 package。
