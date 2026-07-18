# Computer Use 补丁集成设计

**日期：** 2026-07-18

**状态：** 已批准

**范围：** Bash 补丁管理器与 Unix `.sh` 上游脚本

## 背景

仓库根目录新增了 `apply-claude-code-computer-use-fix.sh`。该脚本通过 AST 修改 Claude Code 的设置 schema、Computer Use 启用门禁和子配置合并逻辑，使 Computer Use MCP 可以通过 `settings.json` 或环境变量启用，同时保持默认关闭。

当前 `cc-patch-manager.sh` 已统一管理六个补丁的检测、应用、单基线备份、单补丁还原和一键应用。本次将 Computer Use 作为第七个补丁接入同一生命周期。

## 目标

1. 将 Computer Use 作为第七个补丁加入管理器。
2. 支持检测、应用、重复检测、重复应用、一键应用和单补丁还原。
3. 保持补丁默认关闭；只有显式设置时才启用 Computer Use。
4. 复用管理器的 Acorn 缓存、状态解析和 `cli.js.cc-patch-baseline` 单基线备份策略。
5. 自动化验证注册信息和完整状态闭环。

## 非目标

- 不直接修改真实安装目录中的 Claude Code `cli.js`。
- 不改变现有六个补丁的顺序或业务行为。
- 不为 Computer Use 增加新的权限申请、系统设置修改或运行时服务。
- 不清理、移动或提交根目录中与本任务无关的未跟踪目录。
- 不扩展上游 AST 定位逻辑以支持尚未观察到的 Claude Code 结构。

## 方案选择

采用现有 Context Limit 等非资源型补丁的移植模式：

1. 将根目录脚本原样复制到 `original-scripts/apply-claude-code-computer-use-fix.sh`，作为来源留档。
2. 将其 Node/Acorn AST 引擎嵌入 `cc-patch-manager.sh`。
3. 仅在管理器内增加统一基线备份适配，保留补丁的 schema、门禁和配置合并逻辑。

不选择运行时直接调用完整上游脚本，因为它会绕过管理器的 Acorn 缓存、状态映射和单基线还原流程。不选择运行时从 Bash 文件提取 heredoc，因为这种方式依赖上游脚本排版，维护稳定性较差。

## 注册表与界面

在 `PATCH_IDS` 末尾追加 `computer-use`，保留现有六项编号：

```text
auto-mode → keybindings → transcript-dialog → ultracode → voice-mode → context-limit → computer-use
```

新增注册信息：

- id：`computer-use`
- 名称：`Computer Use 解锁`
- 说明：`通过设置或环境变量启用 Computer Use MCP，默认关闭`
- 旧式备份后缀：`backup-computer-use`

帮助文案、状态数量、菜单选择范围和数字分派从六项更新为七项。`computer-use` 自动进入刷新全部、一键应用和还原重打循环。

详情页说明以下启用方式：

- `settings.json`：`{ "computerUseEnabled": true }`
- 环境变量：`CLAUDE_CODE_COMPUTER_USE=1`
- 可选子配置：`computerUseConfig`

同时说明默认行为保持关闭，并提示 Computer Use 仍受 macOS 辅助功能、屏幕录制权限及实际运行环境约束。

## AST 引擎行为

移植引擎保留上游的三项核心修改：

1. 在设置 Zod schema 中注册 `computerUseEnabled` 和 `computerUseConfig`。
2. 将 Computer Use 启用门禁改为“环境变量 → 设置 → 原始订阅与服务端门禁”的三级优先级。
3. 将用户提供的 `computerUseConfig` 合并到原始配置结果中。

引擎继续通过函数结构、已有设置字段和 Computer Use 配置形态动态提取压缩后的函数名，不硬编码 Claude Code 的局部符号名。写入后重新使用 Acorn 解析，语法验证失败时不得覆盖目标文件。

已应用检测沿用以下标记：

- `CLAUDE_CODE_COMPUTER_USE`
- `computerUseEnabled`
- `computerUseConfig`

只有三部分都已应用时输出 `ALREADY_PATCHED`。部分命中但仍存在可修改节点时，只补齐缺失部分。

## 备份与状态契约

管理器模式下，引擎支持：

- `CC_PATCH_SKIP_BACKUP=1`
- `CC_PATCH_BASELINE=<cli.js.cc-patch-baseline>`

首次实际写入前创建统一基线；已经应用时不创建备份，也不修改文件。独立归档脚本保持原始时间戳备份行为不变。

输出复用管理器现有契约：

- `NEEDS_PATCH` 与 `PATCH_COUNT:n` → `idle`
- `ALREADY_PATCHED` → `applied`
- `SUCCESS:n` → `applied`
- `PARSE_ERROR`、`NOT_FOUND`、`VERIFY_FAILED` → `error`

以下情况不得写入目标文件：

- Node 或 Acorn 不可用。
- `cli.js` 不可读或不可写。
- AST 解析失败。
- 无法提取设置读取器、环境变量解析器或目标函数。
- 修改后的 JavaScript 无法重新解析。

## 文件影响

### 新增

- `original-scripts/apply-claude-code-computer-use-fix.sh`
- `tests/test_computer_use_integration.sh`

### 修改

- `cc-patch-manager.sh`
- 现有依赖六项帮助文案或菜单范围的测试文件

根目录 `apply-claude-code-computer-use-fix.sh` 作为用户提供的上游输入保持原位，不在本任务中删除。

## 测试设计

### 注册与界面测试

验证：

- `PATCH_IDS` 包含七项，且 `computer-use` 位于末尾。
- 名称、说明、用途和备份后缀正确。
- `write_patch_script computer-use` 能生成包含三个 Computer Use 设置标记和统一基线适配的引擎。
- 帮助文案声明七个补丁，菜单接受数字 `7`。
- 归档来源与根目录输入内容一致。

### 状态闭环测试

构造最小 `cli.js` fixture，包含：

- `autoCompactEnabled` 设置 schema，用于提取 Zod 构造器。
- 同时读取 `autoCompactEnabled` 与 `DISABLE_AUTO_COMPACT` 的函数，用于提取设置读取器和环境变量解析器。
- 原始 Computer Use 配置函数和订阅/服务端启用门禁。

按以下顺序验证：

1. 首次 `check` 返回 `idle` 和三个待修改位置。
2. `apply` 成功，并只创建统一基线备份。
3. 修改后的文件包含 `computerUseEnabled`、`computerUseConfig` 和 `CLAUDE_CODE_COMPUTER_USE`。
4. 修改后的 JavaScript 可由 Acorn 重新解析。
5. 再次 `check` 返回 `applied`。
6. 再次 `apply` 不重复注入，也不修改文件。
7. `restore_patch computer-use` 将 fixture 恢复为基线内容。

### 全量验证

实现完成前运行：

```bash
bash -n cc-patch-manager.sh
bash tests/test_computer_use_integration.sh
bash tests/test_context_limit_integration.sh
bash tests/test_auto_mode_engine.sh
bash tests/test_voice_mode_platform.sh
git diff --check
```

## 风险与边界

- 上游引擎依赖 Claude Code 当前压缩代码结构；后续版本改变设置 schema 或 Computer Use 函数结构时，会安全失败为 `error`，届时需要基于真实失败 fixture 更新定位器。
- 启用 Computer Use 不等于系统权限已经就绪；macOS 仍可能要求辅助功能与屏幕录制授权。
- 一键应用会写入该补丁，但默认仍关闭 Computer Use，因此不会仅因打补丁就开始桌面控制。
- 本次不验证真实桌面控制链路，只验证 `cli.js` 补丁的检测、写入、幂等和还原行为。

## 验收标准

1. 管理器显示并可选择第七个 Computer Use 补丁。
2. Computer Use 支持检测、应用、重复检测、重复应用、一键应用和单补丁还原。
3. 未显式配置时，Computer Use 默认保持关闭。
4. 管理器不会为该补丁创建额外时间戳备份。
5. 归档脚本保留用户提供的上游内容，管理器内适配统一备份。
6. 新增测试及现有回归测试全部通过。
