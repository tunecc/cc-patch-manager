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
