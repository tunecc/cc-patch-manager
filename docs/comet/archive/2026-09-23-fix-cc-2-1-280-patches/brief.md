# 目标

让补丁管理器在 `@cometix/anthropic-cc` 2.1.280 split-esm 包上重新可检测、可应用、可幂等检查并可还原 auto-mode 的 `model-eligibility` 目标与 voice-mode 的 `entry-gate` 目标（含同一解析链上的 auth-probe 与 feature-flag），同时 2.1.273 及更早形态、其余五个补丁行为不回归。

2.1.280 的两处根因：

- auto-mode：模型资格函数的 provider 门禁被抽成同模块 0 参 helper（`bQt(){let e=Oe();return e!=="firstParty"&&!xI(e)}`），函数 body 不再内联 `firstParty`；旧版含 `claude-3-` 的 legacy 黑名单被移除，资格条件只剩 `claude-opus-4-6`/`claude-sonnet-4-6`/`haiku` 三元组。
- voice-mode：`name:"voice"` 命令对象与 `isHidden` 调用的门禁函数（`O2e(){return oRn()&&sRn()}`）被拆进不同 chunk，现有分析器只在同 chunk 内按名解析门禁。

# 范围

- 更新 `cc-patch-manager.sh` 语义分析器：`analyzeAutoMode` 的 model-eligibility 识别接受 provider 门禁 0 参 helper 形态与新黑名单三元组；`analyzeVoiceMode` 在同 chunk 解析失败时通过 `ModuleIndex` 沿 import 绑定跨 chunk 解析门禁函数，entry-gate/auth-probe/feature-flag 补丁写入门禁定义所在文件。
- 为两个新形态增加聚焦回归夹具（含不应匹配的诱饵），并把 cruce 真实包验收目标从 2.1.273 更新到 2.1.280。
- 在真实安装包的临时完整副本上验证七补丁生命周期、CLI 启动和全还原；不直接写入 Homebrew 安装目录。

# 非目标

- 不改变七个补丁原有的用户可见功能定义、默认开关或菜单交互。
- 不放宽包身份校验、目标唯一性、事务原子性或基线完整性检查。
- 不修改、升级或重装 `/opt/homebrew` 下的真实安装包。
- 不重构与两个失效目标无关的分析器或其他补丁实现。

# 验收示例

- A1：对 2.1.280 形态夹具（provider 门禁为 0 参 helper、黑名单为 opus-4-6/sonnet-4-6/haiku 三元组、`supported:` 属性消费门禁且被 `tengu_auto_mode_config` 消费者调用）执行 auto-mode `check` 返回 `NEEDS_PATCH`，应用后返回 `ALREADY_PATCHED`；`firstParty` 内联旧形态夹具继续匹配，缺消费链或缺三元组的诱饵不被匹配。
- A2：对 voice 命令对象与门禁/auth/flag 函数分属两个 chunk 的夹具执行 voice-mode `check` 返回 `NEEDS_PATCH`，应用后返回 `ALREADY_PATCHED`，且 entry-gate 补丁写入门禁定义所在 chunk；门禁与命令对象同 chunk 的旧形态夹具继续匹配。
- A3：在 `@cometix/anthropic-cc` 2.1.280 真实包的临时完整副本上，全部七个补丁依次完成 `NEEDS_PATCH -> apply -> ALREADY_PATCHED -> restore`，随后批量应用、`node cli.js --version` 启动检查和 `restore-all` 均成功，副本恢复到原始哈希。
- A4：项目现有快速测试全部通过（含 2.1.273 兼容测试与 dual-layout 生命周期），且真实 `/opt/homebrew` 源包在验收前后哈希不变。

# 约束与不变量

- 继续基于 Acorn AST 和模块绑定关系定位语义目标，不使用仅依赖 chunk 文件名或压缩变量名的补丁规则。
- 每个语义目标必须保持唯一匹配；缺失或歧义时快速失败，不静默跳过。
- 新旧包形态均须支持（single-cjs legacy 引擎、2.1.213 flat、2.1.273、2.1.280），补丁标记、可逆 body 编码、事务基线与资源复制协议保持兼容。
- 测试命令使用支持关联数组的 Homebrew Bash 5，而非 macOS Bash 3.2。

# 决策

- auto-mode 的 `firstParty` 锚点扩展为「资格函数 body 内联，或调用同模块 0 参 helper 且 helper body 含 `firstParty`」；黑名单锚点在原 `claude-3-` 家族之外接受 2.1.273/2.1.280 第二条件共有的 opus-4-6/sonnet-4-6/haiku 三元组；`supported:` → `tengu_auto_mode_config` 消费链继续作为主锚，不恢复对具体压缩函数名的依赖。
- auto-mode 的模型扫描候选 token 增加 `claude-sonnet-4-6`，使扫描不依赖 `claude-3-` 在未来版本继续存在。
- voice-mode 门禁解析保持「同 chunk 按名解析优先」，失败时用 `ModuleIndex.resolveLocal` 沿 import 绑定解析到定义文件后再按导出名查找；auth-probe 与 feature-flag 仍以门禁函数的被调列表为入口，落在门禁定义所在 chunk 内解析。
- 真实包验收只操作临时副本；cruce 验收目标版本从 2.1.273 升到 2.1.280，现有 package baseline 仅作为可恢复性证据和测试输入来源。

# 待解决问题

- 无。

# 验证预期

- 运行新增/更新的聚焦测试，覆盖 2.1.280 的 auto-mode helper 化 provider 门禁形态与 voice-mode 跨 chunk 门禁形态。
- 运行仓库完整快速测试集。
- 设置 `CC_PATCH_CRUCE_PACKAGE=/opt/homebrew/lib/node_modules/@cometix/anthropic-cc`，运行 cruce 2.1.280 真实包验收；测试自身复制源包并比较前后哈希。
