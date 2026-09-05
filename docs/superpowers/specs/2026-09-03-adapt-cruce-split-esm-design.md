---
comet_change: adapt-cruce-split-esm
role: technical-design
canonical_spec: openspec
archived-with: 2026-09-05-adapt-cruce-split-esm
status: final
---

# Claude Code 补丁管理器双布局适配技术设计

## 1. 设计上下文

需求与验收标准以 OpenSpec change `adapt-cruce-split-esm` 为事实源。本设计细化其实现方式，不复制或替代 capability spec。

当前 `cc-patch-manager.sh` 是 3733 行单文件 Bash 程序，Bash 层维护 TUI、状态和备份流程，每个补丁通过 heredoc 生成独立 Node/Acorn 脚本，且所有引擎只读取一个 `CLI_PATH`。这与 CometixSpace 2.1.224 的单文件 CommonJS bundle 匹配。

cruce 2.1.259 的安装包为 split-ESM：约 18 KB 的 `cli.js` 加 1800 余个 package 文件，其中业务逻辑散布在约 1400 个相对导入的 chunks 中。本地只读基线显示现有七项 `--check` 全部失败；把现有引擎直接指向候选 chunk 后，Auto Mode 和 Keybindings 已能分别识别部分目标，证明主要迁移方向应是目录级目标建模与跨文件计划，而非按当前 chunk 名重写规则。

## 2. 总体结构

仍只交付 `cc-patch-manager.sh`，但把运行时职责分成两层：

```text
Bash host
  参数与自动发现
  TUI / 确认 / 状态映射
  runtime 生命周期与临时文件清理
           |
           | 稳定机器行协议
           v
Embedded Node runtime（运行时写入临时文件）
  inspect target
  scan candidates / index modules
  analyze patch -> PatchPlan
  validate / commit / rollback
  baseline / restore
```

Bash 不理解 AST、模块图或 manifest JSON 内部结构。Node runtime 不负责交互，也不输出需要 Bash 解析的本地化自然语言。这样保留当前单脚本分发和 TUI，同时让安全关键的扫描、验证、事务和恢复代码只有一份。

### 2.1 统一 runtime 命令

runtime 接收入口路径、命令和可选 patch ID：

- `inspect <entry>`：返回目标身份与布局。
- `check <entry> <patch-id>`：分析但不写入。
- `apply <entry> <patch-id>`：分析、验证并提交单补丁事务。
- `restore <entry> <patch-id>`：恢复基线并重打其他补丁。
- `backup <entry>`：显式建立或更新用户确认的恢复点。

现有 `run_node_patch`、`refresh_one`、`refresh_all` 和 TUI 动作继续作为 Bash facade。`apply-all` 仍按固定 `PATCH_IDS` 顺序调用七次 `apply`，而不是创建一个跨补丁大事务。

### 2.2 机器协议

保留现有 `ALREADY_PATCHED`、`NEEDS_PATCH`、`PATCH_COUNT`、`SUCCESS`、`NOT_FOUND`、`PARSE_ERROR` 和 `VERIFY_FAILED` 标记，并增加：

- `TARGET_PACKAGE:<name>`
- `TARGET_VERSION:<version>`
- `TARGET_LAYOUT:single-cjs|split-esm`
- `TARGET_FILE:<relative-path>`
- `MISSING_TARGET:<semantic-id>`
- `AMBIGUOUS_TARGET:<semantic-id>:<count>`
- `ROLLBACK:SUCCESS|FAILED:<context>`
- `BASELINE:<manifest-path>`

字段中可能包含路径的部分采用 JSON 字符串值或等价无歧义编码，避免冒号和空格破坏解析。Bash 映射这些标记为中文状态与错误详情，未知或冲突协议一律视为工程错误。

## 3. TargetDescriptor 与布局检测

Node runtime 将任何入口解析为：

```text
TargetDescriptor
  entryPath
  packageRoot
  packageName
  packageVersion
  layout
  identityFingerprint
```

`packageRoot` 从入口向上寻找包含该入口的最近 `package.json`，并要求入口位于根目录内。支持的 package 名称是 `@cometix/claude-code` 和 `@cometix/anthropic-cc`；显式路径指向其他 package 时显示明确的不支持错误，不凭文件名继续。

Bash 自动发现顺序保留显式参数、`CLAUDE_CLI_PATH`、用户本地安装、npm global root 和标准 global roots 的层级，在每个层级内加入 `@cometix/anthropic-cc/cli.js`。若新旧两个包同时存在，沿用确定性的候选顺序并在 TUI 显示实际选中身份；用户始终可用显式路径覆盖。

布局不按版本分支：

- `split-esm`：入口可按 module 解析，存在相对 `.js` 静态导入，且解析后的相邻目标文件存在。
- `single-cjs`：入口满足现有单 bundle 结构且没有 split-ESM 特征。
- 两者都不满足或同时出现冲突证据：拒绝目标。

身份指纹不能直接使用会被补丁修改的完整 `cli.js` 哈希。它由 `package.json` 内容哈希、入口头部的版本/构建标识，以及 split 布局下排除 baseline、`node_modules` 和 VoiceMode 管理资源后的 package 自有模块相对路径集合构成。受管文件原文由 baseline 条目哈希另行校验。

## 4. 候选扫描与模块索引

### 4.1 Marker 预筛

每个 patch analyzer 声明若干 marker group。group 表达“至少命中一个”的候选条件，多个必要 group 可分别产生候选集合。例如 Keybindings 的功能开关和 `ctrl+c` 映射是两个语义目标，不要求落在同一文件。

split 扫描只遍历 package 自有 `.js`/`.mjs` 文件，并排除：

- `node_modules/`
- baseline 与事务临时目录
- `vendor/` 中非业务 JS
- 已知资产和压缩文本

扫描阶段只读文本，不解析 AST。候选去重后才进入 Acorn `sourceType: module` 解析；single-CJS adapter 继续按其真实 source type 解析原 bundle。

### 4.2 AST 缓存

一次 runtime 调用内以绝对路径和内容哈希缓存源码、AST、parent map 与静态模块边。某文件产生 replacements 后，补丁后验证重新解析新文本，不复用旧 AST。

### 4.3 静态模块索引

索引仅支持 split 包实际使用且可静态证明的相对 ESM 关系：

- `ImportDeclaration`
- `ExportNamedDeclaration`
- `ExportSpecifier`
- `ExportAllDeclaration`
- 相对路径的字符串 module specifier

每个 binding 表示为 `(file, localName)`，并可追踪到 `(sourceFile, exportedName)`。索引拒绝越出 package root、缺失文件、重复导出和循环 re-export 无法收敛的解析。动态 import 只作为 marker 上下文，不用于同步 helper 绑定解析。

补丁插入代码时优先使用目标模块已经存在的本地或 imported binding。确实缺少必要 helper 时，只有在索引能唯一找到 export、引用发生在函数调用期且静态 import 不引入未处理 TDZ 风险时，才可把新 import 纳入 PatchPlan；该路径必须有专门 fixture 和真实 CLI 启动验证。否则分析失败，不退回全局变量或硬编码压缩名。

## 5. PatchPlan 合同

每个 analyzer 只负责语义识别和 replacement 生成，返回统一计划：

```text
PatchPlan
  patchId
  state: needs-patch | already-patched | invalid
  semanticTargets[]
    id, expectedCardinality, matches[]
  files[]
    relativePath, sourceHash, sourceType, replacements[], postconditions[]
  resources[]
    copy | replace | remove, source, destination, expectedBefore
  diagnostics[]
```

共享 validator 在写入前执行：

1. 每个必要语义目标达到精确基数，或满足 analyzer 明确定义的兼容形状。
2. 同文件 replacements 不重叠且边界有效。
3. replacement 只位于已确认 AST 节点或受控插入点。
4. 每个新文件可按正确 source type 重新解析。
5. analyzer 的补丁后置条件全部成立。
6. `already-patched` 必须覆盖完整目标集合；部分状态返回 `needs-patch` 并只补缺失部分，不能误报完成。

`check` 与 `apply` 调用相同 analyzer 和 validator。`check` 在有效计划后输出状态并退出，不走任何 baseline 或事务代码。

## 6. 七个补丁的 analyzer 边界

### 6.1 Auto Mode

分别建模模型资格函数、分类器不可用的 fail-closed decision object，以及分类模型来源。沿用已经验证的 flat/legacy 函数形状和 ReturnStatement 结构匹配，但在 marker 候选集合中独立查找。补丁后验证检查资格门禁、`deny -> ask` 和 `CLAUDE_CLASSIFIER_MODEL` 三项语义，不以总 replacement 数代替完整性。

### 6.2 Keybindings

功能开关与默认 `ctrl+c: app:interrupt` 映射是两个目标集合。功能开关在新版若已由上游默认开启，应记录为语义已满足，而不是强制要求旧 flag 调用仍存在；按键映射仍需唯一修改为 `app:exit`。这一区分避免“上游已经移除门禁”被误判为不支持。

### 6.3 权限弹窗重放

所有候选使用 module source type。dialog channel factory 和 host cleanup 分别定位，可位于不同文件。factory 改写必须保留原信号构造和 reply/request 语义，只增加 pending replay；cleanup 只移除切换宿主时的 cancelled reply，不吞掉真正的 dismiss。两项目标必须同时验证。

### 6.4 Ultracode

资格门禁、努力度回退和激活判定分别以 `xhigh`、`max`、Ultracode 设置/状态上下文筛选。允许三个目标位于不同模块，但每个目标需通过调用关系或共享配置语义消除普通 effort UI 的同名候选。

### 6.5 VoiceMode

入口门禁、流能力、可用性、settings UI/schema、连接函数、认证探针和 feature flag 作为七类必要目标。各目标只生成 JS replacements；ASR loader 和 native binary 作为 resource operations 加入同一 PatchPlan。平台和资源预检先于任何 baseline 或目标写入。restore 根据 manifest 的原始存在状态恢复或移除 `vendor/cometix-asr`。

### 6.6 Context Limit

不能把所有数值 `200000` 都视为目标。analyzer 以 token/context 相关调用、变量用途和比较上下文收窄默认值，并独立定位 settings env 应用路径。split 模块下沿 binding 索引确认限制值定义与消费者；若需要在 env 加载后刷新，生成可证明的跨模块 setter/import 方案，或复用模块已有的动态环境读取。任何无法证明 settings env 生效时序的方案都不得应用，即使纯环境变量启动场景可工作。

### 6.7 Computer Use

settings schema、启用门禁和配置合并是三个必要目标。schema analyzer 从现有相邻字段解析 live Zod builder 约定；门禁和配置 analyzer 从实际调用点解析 env parser、settings reader 和默认配置 binding。helper 位于其他 chunk 时通过模块索引取得现有 alias 或唯一 export，不把旧 bundle 中偶然共址当作前提。默认关闭、env 强制开启、显式 settings 和子配置合并均为后置验证内容。

## 7. 基线 manifest

新基线位于 package root 下的专用隐藏目录，例如 `.cc-patch-manager-baseline/`：

```text
.cc-patch-manager-baseline/
  manifest.json
  files/<relative-path>
```

manifest 至少包含：

- schema version
- package name/version/layout/identity fingerprint
- 创建时间和管理器版本
- 受管路径：类型、原始是否存在、原始 SHA-256、mode、镜像路径
- 由管理器创建的目录清单

首次自动应用前，runtime 先分析所有七个补丁的当前状态。若任一补丁已应用或发现无法归因的 sentinel，而没有可信基线，则拒绝静默建立“干净”基线，并提示重新安装干净 package 或由用户通过备份动作明确接纳当前状态。

旧 `cli.js.cc-patch-baseline` 只在 single-CJS 下迁移：baseline 中的版本/构建身份必须与当前 package 元数据相符，迁移后复制到新镜像并保留旧文件，不自动删除。身份不符时拒绝迁移。

新增受管路径采用增量登记，但写入前确认该路径未被之前的 manager 事务修改却遗漏 manifest；同一文件被多个补丁触及时始终只有一份干净原文。

## 8. 事务提交与恢复

### 8.1 Apply

1. Inspect target 并验证 baseline 身份。
2. Analyze 完整 PatchPlan。
3. 在内存生成所有目标内容并完成 AST/后置条件校验。
4. 为未登记路径补全干净 baseline；manifest 使用临时文件加 rename 更新。
5. 在 package 同一文件系统创建事务前镜像和每个目标的临时新文件。
6. 逐一 rename 提交，资源操作使用相同日志。
7. 重新读取正式路径，验证哈希、AST 与补丁语义。
8. 成功后删除事务快照；失败则逆序恢复并再次校验事务前哈希。

进程崩溃留下的事务目录包含状态日志。下次任何写操作前 runtime 必须检测并尝试恢复；无法证明恢复完成时禁止继续应用。

### 8.2 Restore one patch

1. 运行七项 check，记录完整 applied 集合；任一状态未知则停止。
2. 校验 baseline 身份与镜像哈希。
3. 以事务方式恢复全部受管路径到干净基线。
4. 按 `PATCH_IDS` 顺序重打原 applied 集合中除目标以外的补丁。
5. 全量复检：目标为 idle，保留项为 applied。

重打失败时不能谎报还原成功。系统保留已经成功恢复的干净基线和明确失败列表；由于每个重打仍是独立事务，不会出现单补丁半写状态。

## 9. 错误与边界条件

- package root 越界、符号链接逃逸或非支持 package：目标错误，零写入。
- marker 缺失：输出 semantic ID 和检查范围。
- 多候选无法消歧：列出相对文件与候选数，不选择“第一个”。
- AST parse 或 postcondition 失败：输出 patch ID、阶段和相对文件。
- baseline 身份陈旧或镜像哈希损坏：禁止 restore/apply，提示干净重装或显式重建。
- package 不可写：check 仍可运行，apply/restore 在创建 baseline 前失败。
- VoiceMode 非 Darwin/arm64 或资产缺失：在计划和资源写入前失败。
- 未来版本：只有完整语义目标与事务验证通过才允许应用；版本未知本身不是放宽门禁的理由。

## 10. 测试设计

### 10.1 快速测试

沿用 `tests/test_*.sh`，测试 source `cc-patch-manager.sh` 后调用 facade 或生成统一 runtime。新增共享 fixture builder 在临时目录创建 package.json、cli.js 和多个有真实 import/export 的 chunks，不把实际 Claude Code bundle 提交进仓库。

每个补丁在两种布局上执行统一生命周期断言：

```text
clean check -> idle
apply -> applied
second check -> applied
second apply -> byte-identical
restore -> baseline-identical
```

多补丁组合额外验证“恢复目标后重打其他补丁”。故障注入通过 runtime 测试开关在第 N 次 rename/resource 操作失败，断言事务前后逐路径哈希相同；测试开关只在测试环境变量明确启用时生效。

### 10.2 真实包验收

- CometixSpace 2.1.224：从可信 release artifact 获取或用对应 tag 构建 package，复制到临时目录。
- cruce 2.1.259：复制本机已安装 package 到临时目录，并在开始和结束记录全局安装的文件集合与哈希。

两个 package 均执行七补丁矩阵、单补丁组合恢复、全基线恢复、`--version`、`--help` 和非交互启动级 smoke。VoiceMode 使用当前 Darwin/arm64 资产。真实包验收脚本必须把入口显式指向临时副本，禁止依赖自动发现。

### 10.3 完成门禁

- `bash -n cc-patch-manager.sh`
- 全部快速 Bash 测试零失败
- 2.1.224 真实 package 矩阵零失败
- 2.1.259 真实 package 矩阵零失败
- 两个 package 还原后与各自 baseline 哈希一致
- 当前全局 `@cometix/anthropic-cc` 在验收前后哈希一致
- Git diff 仅包含 change 允许的脚本、测试与 Comet/OpenSpec 产物

## 11. 实施顺序

先通过失败测试建立 TargetDescriptor、布局检测、候选扫描、模块索引和 PatchPlan 合同；再完成 manifest 与事务，确保任何补丁迁移前已有安全写入底座。七个补丁按 Auto/Keybindings、Transcript/Ultracode、VoiceMode、Context Limit、Computer Use 分组迁移。最后统一 TUI/诊断和 apply-all，并完成双真实版本验收。

这个顺序将高风险的多文件写入和恢复能力提前验证，也允许每组补丁用相同底座做严格红绿循环，而不在七个 analyzer 中重复基础设施修复。
