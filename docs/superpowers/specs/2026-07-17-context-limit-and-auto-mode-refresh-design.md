# Context Limit 集成与 Auto Mode 上游复核设计

**日期：** 2026-07-17

**状态：** 已批准

**范围：** Bash 补丁管理器与 Unix `.sh` 上游脚本；不包含 Windows PowerShell

## 背景

仓库根目录新增了两份上游输入：

- `apply-claude-code-context-limit-patch/`：新增 Context Limit 补丁的 Bash 与 PowerShell 脚本。
- `apply-claude-code-enable-auto-mode/`：原作者重新发布的 Auto Mode Bash 与 PowerShell 脚本。

当前管理器包含五个补丁，补丁引擎统一由 `cc-patch-manager.sh` 管理状态、应用、基线备份和单补丁还原；Unix 上游脚本集中保存在 `original-scripts/`。本次只集成 Bash 路径，不增加 Windows 执行入口。

## 目标

1. 将 Context Limit 作为第六个补丁加入现有集合。
2. 保持管理器现有的统一检测、应用、基线备份和还原语义。
3. 默认上下文限制仍为 200000；只有设置 `CLAUDE_CODE_CONTEXT_LIMIT` 时才改变限制。
4. 解决上游 Context Limit 引擎在应用后再次检测时报 `NOT_FOUND` 的幂等问题。
5. 复核重新发布的 Auto Mode 脚本，避免用兼容范围更窄的检测器覆盖当前实现。
6. 用自动化测试锁定 Context Limit 的完整状态闭环和 Auto Mode 的双形态检测能力。

## 非目标

- 不实现 PowerShell 或 Windows 版补丁管理器。
- 不把 `.ps1` 文件复制到 `original-scripts/`。
- 不修改真实安装目录中的 Claude Code `cli.js`。
- 不清理、移动或删除用户放在仓库根目录的两个上游输入目录。
- 不改变其他五个补丁的业务行为、备份后缀或菜单顺序。

## 方案选择

采用现有非 Voice Mode 补丁的移植模式：

1. 将 Context Limit 的 Bash 上游脚本复制到 `original-scripts/apply-claude-code-context-limit-patch.sh`，作为来源留档。
2. 将其中 Node/Acorn AST 引擎移植到 `cc-patch-manager.sh` 的 `write_patch_script_context_limit`。
3. 只在管理器内对引擎增加统一基线备份适配和幂等状态适配；上游留档脚本保持输入版本内容不变。

不选择运行时调用完整上游脚本，因为它会绕开管理器的 Acorn 缓存路径、状态解析、单基线备份和还原重打流程。也不选择运行时提取 Context Limit 引擎，因为该补丁没有 Voice Mode 那样的外部二进制资源依赖，嵌入方式与现有 Auto Mode、Keybindings、Transcript Dialog 和 Ultracode 更一致。

## Context Limit 集成设计

### 注册表与界面

在 `PATCH_IDS` 末尾追加 `context-limit`，保留现有五项编号：

```text
auto-mode → keybindings → transcript-dialog → ultracode → voice-mode → context-limit
```

新增注册信息：

- id：`context-limit`
- 名称：`上下文上限配置`
- 说明：`通过 CLAUDE_CODE_CONTEXT_LIMIT 覆盖默认 200K 上限`
- 旧式备份后缀：`backup-ctxlimit`

帮助文案、状态数量、菜单选择范围和“一键应用全部”均从五项调整为六项。Context Limit 采用默认值回退表达式，因此即使由“一键应用全部”写入，未设置环境变量时仍保持 200000 的原行为。

### AST 引擎行为

移植引擎保留上游的核心策略：

1. 找出值为 `200000` 的数字字面量。
2. 只处理顶层变量初始化和二元比较两类位置。
3. 将目标字面量替换为 `(+process.env.CLAUDE_CODE_CONTEXT_LIMIT||200000)`。
4. 找出包含 `Object.assign(process.env, ...)` 的环境加载函数。
5. 在环境加载完成后重新给已识别的顶层限制变量赋值，使 `settings.json` 或 `--settings` 中的 `env` 同样生效。
6. 写入前重新解析 AST，并验证环境变量引用和注入点存在。

管理器适配包含两项：

- **统一备份：** 支持 `CC_PATCH_SKIP_BACKUP=1` 与 `CC_PATCH_BASELINE`，首次实际写入前创建或复用 `cli.js.cc-patch-baseline`，不另建每补丁时间戳备份。
- **幂等检测：** 当不存在可继续处理的 `200000` 目标，但 AST 中已经存在 `process.env.CLAUDE_CODE_CONTEXT_LIMIT` 成员访问时，输出 `ALREADY_PATCHED`；只有两者都不存在时才输出 `NOT_FOUND`。

幂等判断使用 AST 成员访问，不使用字符串包含判断，避免注释或用户文案中的环境变量名称造成误报。

### 状态与错误处理

Context Limit 复用管理器现有输出契约：

- `NEEDS_PATCH` + `PATCH_COUNT:n` → `idle`
- `ALREADY_PATCHED` → `applied`
- `SUCCESS:n` → `applied`
- `PARSE_ERROR`、`NOT_FOUND`、`VERIFY_FAILED` → `error`

以下情况不得写入目标文件：

- Node 或 Acorn 不可用。
- `cli.js` 不可读或不可写。
- AST 解析失败。
- 找不到可处理的限制位置，且文件也没有已应用标记。
- 找不到上游要求的环境加载函数。
- 写入前的 AST 或环境变量引用验证失败。

## Auto Mode 复核结论

重新发布的 Bash 脚本与仓库当前来源相比只有 Phase 1 模型资格函数定位器发生实质变化，整体差异为 27 行新增、71 行删除；分类器不可用时的 `deny → ask` 和 `CLAUDE_CLASSIFIER_MODEL` 覆盖逻辑没有新增能力。

重新发布版使用单一路径，要求候选函数同时包含 `firstParty`、`anthropicAws`、一个 `return !0` 和至少三个 `return !1`。仓库当前实现同时保留：

- 旧版嵌套块形态。
- 2.1.204+ 平铺 denylist 形态，允许至少两个 `return !1`，并用模型字符串和函数大小进一步约束、排序候选。

因此不整体替换 Auto Mode 上游来源或管理器内引擎。重新发布版的硬锚点虽然更严格，但直接合并会排除当前支持的部分旧版或新版结构；在没有覆盖这些版本的真实 fixture 前，不改变现有定位逻辑。

实现阶段只增加回归测试，确认管理器生成的 Auto Mode 引擎仍包含旧版与平铺版两个候选分支及平铺候选排序逻辑。

## 文件影响

### 新增

- `original-scripts/apply-claude-code-context-limit-patch.sh`
- `tests/test_context_limit_integration.sh`
- `tests/test_auto_mode_engine.sh`

### 修改

- `cc-patch-manager.sh`
- `tests/test_voice_mode_platform.sh`：将帮助文案断言从五项更新为六项。

根目录的 `apply-claude-code-context-limit-patch/` 与 `apply-claude-code-enable-auto-mode/` 保持原位且不纳入提交。

## 测试设计

### Context Limit 注册测试

验证：

- `PATCH_IDS` 包含六项，且 `context-limit` 位于末尾。
- 名称、说明、用途和 `backup-ctxlimit` 后缀可查询。
- `write_patch_script context-limit` 能生成包含 `CLAUDE_CODE_CONTEXT_LIMIT` 和幂等标记的 Node 引擎。
- `--help` 声明六个补丁，交互菜单接受数字 `6`。

### Context Limit 状态闭环测试

构造最小 `cli.js` fixture，包含：

- 至少一个顶层 `200000` 变量。
- 至少一个与 `200000` 比较的表达式。
- 至少两个 `Object.assign(process.env, ...)` 环境加载函数。

按以下顺序验证：

1. `check` 返回 `idle` 和正确的待处理数量。
2. `apply` 成功，并只创建统一基线备份。
3. 文件包含上下文环境变量表达式和环境加载后的重新赋值。
4. 修改后的 JavaScript 可被 Acorn 重新解析。
5. 再次 `check` 返回 `applied`，不返回 `NOT_FOUND`。
6. 再次 `apply` 不重复注入、不修改文件。
7. 通过管理器还原后，fixture 回到基线内容。

### Auto Mode 防降级测试

验证管理器生成的 Auto Mode 引擎仍包含：

- `oQqCandidatesLegacy`
- `oQqCandidatesFlat`
- `rankFlat`
- `claude-3-`、`firstParty` 和 `anthropicAws` 平铺候选锚点

该测试不声称覆盖所有 Claude Code 版本，只防止本次或后续同步上游时无意移除当前已有的双形态支持。

### 全量验证

提交实现前运行：

```bash
bash -n cc-patch-manager.sh
bash tests/test_context_limit_integration.sh
bash tests/test_auto_mode_engine.sh
bash tests/test_voice_mode_platform.sh
git diff --check
```

## 风险与边界

- Context Limit 上游检测以 `200000` 和环境加载函数结构为锚点，Claude Code 后续改变常量或加载流程时会安全失败为 `error`，需要更新 fixture 和定位逻辑。
- 放大上下文限制可能增加模型费用、延迟、内存占用或触发服务端限制；管理器用途文案需要明确这是客户端补丁，不保证服务端接受任意数值。
- `CLAUDE_CODE_CONTEXT_LIMIT=0` 会因 `||200000` 回退到 200000；本次保持上游语义，不额外设计数值校验。
- Auto Mode 的新版硬锚点暂不合并；如果后续获得真实失败样本，应基于失败 fixture 走独立 TDD 修复，而不是直接替换整个引擎。

## 验收标准

1. 管理器显示并可选择第六个 Context Limit 补丁。
2. 未设置环境变量时，补丁后的默认限制仍为 200000。
3. Context Limit 支持检测、应用、重复检测、重复应用和统一基线还原。
4. 管理器不会为 Context Limit 创建额外时间戳备份。
5. Auto Mode 保留当前双形态检测器，不被重新发布版降级。
6. PowerShell 文件、真实 Claude Code 安装和两个根目录上游输入均不被修改。
