# 目标

让补丁管理器兼容 `@cometix/anthropic-cc` 2.1.273 的 split-esm 包布局，使自动模式、Ultracode 和语音模式补丁重新可检测、可应用、可重复检查并可从事务基线还原，同时保持其余四个补丁行为不回归。

# 范围

- 更新 `cc-patch-manager.sh` 中三个语义分析器，兼容 2.1.273 的新 AST 形态。
- 为新形态增加聚焦回归夹具，并把 cruce 真实包验收目标更新到 2.1.273。
- 在真实安装包的临时副本上验证七补丁生命周期、CLI 启动和全还原；不直接写入 Homebrew 安装目录。

# 非目标

- 不改变七个补丁原有的用户可见功能定义、默认开关或菜单交互。
- 不放宽包身份校验、目标唯一性、事务原子性或基线完整性检查。
- 不修改、升级或重装 `/opt/homebrew` 下的真实安装包。
- 不重构与三个失效锚点无关的补丁实现。

# 验收示例

- A1：对 2.1.273 新的 Auto 门禁形态执行 `check` 返回 `NEEDS_PATCH`，应用后返回 `ALREADY_PATCHED`；未知或无关的模型能力函数不被误匹配。
- A2：Auto 补丁应用后仍同时实现模型资格放开、分类器环境变量覆盖，以及分类器不可用时从拒绝改为询问。
- A3：对 2.1.273 四参数 Ultracode 激活函数执行 `check` 返回 `NEEDS_PATCH`，应用后 max-only 模型可通过资格、回退和激活三层判断，且 `turnEffort` 路径保留。
- A4：对同时含旧 `setChanges` 和新 `changeLog` 设置宿主形态的 Voice 夹具，设置项均可唯一定位、应用后可重复检测，并维持写设置、更新内存状态和记录变更的行为。
- A5：在 `@cometix/anthropic-cc` 2.1.273 的临时完整副本上，全部七个补丁依次完成 `NEEDS_PATCH -> apply -> ALREADY_PATCHED -> restore`，随后批量应用、`node cli.js --version` 启动检查和 `restore-all` 均成功，副本恢复到原始哈希。
- A6：项目现有快速测试全部通过，且真实 `/opt/homebrew` 源包在验收前后哈希不变。

# 约束与不变量

- 继续基于 Acorn AST 和模块绑定关系定位语义目标，不使用仅依赖 chunk 文件名或压缩变量名的补丁规则。
- 每个语义目标必须保持唯一匹配；缺失或歧义时快速失败，不静默跳过。
- 新旧包形态均须支持，补丁标记、可逆 body 编码、事务基线与资源复制协议保持兼容。
- 测试命令使用支持关联数组的 Homebrew Bash 5，而非 macOS Bash 3.2。

# 决策

- Auto 通过“门禁函数调用同模块模型黑名单 helper，并被 Auto 支持状态消费”的结构关系兼容 2.1.273，而不是恢复对具体压缩函数名的依赖。
- Ultracode 激活分析器接受语义等价的三参数和四参数函数，并继续验证解析函数到 effort fallback 的绑定路径。
- Voice 设置注入兼容旧 `setChanges` setter 与新 `changeLog.record` 接口，按宿主已有接口生成对应变更记录代码。
- 真实包验收只操作临时副本；现有 package baseline 仅作为可恢复性证据和测试输入来源。
- 用户已于 2026-09-16 确认目标、范围、A1-A6 验收标准和非目标。

# 待解决问题

- 无。

# 验证预期

- 运行三个新增/更新的聚焦测试，覆盖 Auto helper 关联、四参数 Ultracode 激活和 Voice `changeLog` 宿主。
- 运行仓库完整快速测试集。
- 设置 `CC_PATCH_CRUCE_PACKAGE=/opt/homebrew/lib/node_modules/@cometix/anthropic-cc`，运行 cruce 2.1.273 真实包验收；测试自身复制源包并比较前后哈希。
