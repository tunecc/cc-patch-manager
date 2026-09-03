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

### Requirement: 受支持版本的真实包验收
发布本次适配前，管理器 MUST 在临时副本中完成 CometixSpace 2.1.224 与 cruce 2.1.259 的七补丁生命周期验证，并 SHALL 对补丁后的命令执行版本、帮助和启动级冒烟检查。验证不得直接修改用户当前安装。

#### Scenario: cruce 2.1.259 验收
- **WHEN** 对 cruce 2.1.259 的临时 package 副本运行完整验收
- **THEN** 七个补丁均通过检测、应用、幂等复检和还原，且补丁后的 CLI 通过冒烟检查

#### Scenario: CometixSpace 2.1.224 回归验收
- **WHEN** 对 CometixSpace 2.1.224 的临时 package 副本运行完整验收
- **THEN** 七个补丁均通过生命周期与 CLI 冒烟检查，且还原后逐文件哈希与基线一致

