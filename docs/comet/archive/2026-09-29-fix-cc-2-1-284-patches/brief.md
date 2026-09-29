# 目标

让补丁管理器在 2.1.284 split-esm 上对两个发行版重新可用：`@cometix/claude-code`（上游 CometixSpace patcher 已留有 `.claude-patcher/` 状态目录）与 `@cometix/anthropic-cc`（纯净安装）。具体修复三个独立根因：

- **RC1 外部状态目录污染**：上游 CometixSpace patcher（`y-cruce/claude-code` install.sh → `node bin/patch.mjs`）把 12 个原始 chunk 副本留在包根目录 `.claude-patcher/originals/`。运行时 `excludedPackagePath()` 只排除 `node_modules`/`vendor`/`.cc-patch-manager-*`，未排除 `.claude-patcher`，导致：
  - 语义目标扫描同时命中 live 文件与 originals 副本 → `AMBIGUOUS_TARGET`（auto-mode/keybindings/transcript-dialog/context-limit）；
  - `candidatePrograms`/`ModuleIndex` 把 originals 副本纳入模块图（路径排序在前），其相对导入（如 `./chunk-yhg0e8da.js`）在 originals/ 内不存在 → `TARGET_ERROR: relative module ... does not exist`（ultracode/voice-mode/computer-use）。
- **RC2 ultracode 2.1.284 形态变化**：`chunk-ntkspd6n.js` 中资格逻辑重构——xhigh 门禁 `n9e` 与 max 门禁 `p7` 改为分层查找（statsig `r_e`/`N`、目录 `P4n().includes("xhigh")`、含 4-6 三元组与 `claude-mythos-5` 的黑名单、`Ch` 覆盖、`fN(Vc())` 兜底），新增分发器 `Z(e,n)`、双降级函数 `D`（`max→high`、`xhigh→high`）、激活判断 `A3n`、映射 `Y={ultracode:"xhigh"}`（`r$e`/`Tut`）。现有分析器（资格函数内恰好一次 xhigh 门禁调用形态）不再匹配 → `MISSING_TARGET: ultracode-eligibility`。
- **RC3 computer-use settings-schema 2.1.284 形态变化**：设置 schema 对象属性值改为惰性箭头函数（`autoCompactEnabled:()=>O().optional().describe(...)`，`chunk-dq5fzxjx.js`）。`computerSchemaRoot()` 不解包 `ArrowFunctionExpression` → `MISSING_TARGET: settings-schema`。

附带：cruce 真实包验收目标从 `@cometix/anthropic-cc` 2.1.280 升到 2.1.284（本机安装已更新）。

证据：纯净 `@cometix/anthropic-cc` 2.1.284 上 `--check` 结果为 auto-mode(3)/keybindings(1)/transcript(2)/voice(7)/context-limit(3) 正常识别、ultracode 与 computer-use 报缺失目标；两个发行版的 Z/D/A3n 区域逐字节一致，上游 patcher 未改动我们的补丁点。

# 范围

- `cc-patch-manager.sh`：
  - `excludedPackagePath()` 增加对路径组件 `.claude-patcher` 的精确排除（与 `node_modules`/`vendor` 同机制，单点修复覆盖 `packageModulePaths` 的全部调用方）。
  - `analyzeUltracode` 及配套 renderer：识别 2.1.284 形态并以既有功能语义打补丁（资格/effort-fallback/激活三个语义目标）。锚点方向：`Y={ultracode:"xhigh"}` 映射与 `Z`/`D`/`A3n` 结构、分层门禁函数体；具体锚在 Build 期以聚焦夹具固定。
  - `computerSchemaShape`/`computerSchemaRoot`：解包零参表达式体 `ArrowFunctionExpression`，兄弟属性分类（object/enum schema 构造器）同步按解包后的调用形态判定。
- 测试：
  - 新增 `.claude-patcher/originals/` 污染回归夹具（合成 split-esm 包 + 外部状态目录）。
  - 新增 ultracode 2.1.284 形态夹具（含不应匹配的诱饵）。
  - 新增惰性箭头 schema 夹具（含直接调用旧形态继续匹配）。
  - `tests/test_real_package_acceptance.sh`：cruce 目标版本 2.1.280 → 2.1.284；增加 `@cometix/claude-code`（含 `.claude-patcher/`）真实包验收入口。
- 真实安装包只作只读源复制验收，不直接写入 `/opt/homebrew`。

# 非目标

- 不改变七个补丁的功能定义、默认开关或菜单交互。
- 不修改、迁移、清理或还原上游 patcher 的 `.claude-patcher/` 状态目录；扫描与模块索引完全排除它。外部满足判定只读取 live 代码中的 `/*@cc:<id>#<site>*/` 标记，不解析上游状态文件。
- 不放宽目标唯一性、事务原子性、基线完整性或包身份校验。
- 不重构与三个根因无关的分析器或补丁实现。
- 不支持 single-cjs 上的 ultracode/computer-use 新形态（这两个补丁本就仅走 split-esm 运行时路径）。

# 验收示例

- A1 外部状态目录：合成 split-esm 夹具，包根含 `.claude-patcher/originals/`（内含目标 chunk 的原始副本）与 `applied.json`/`manifest.json`：check 无 `AMBIGUOUS_TARGET`、无 relative module 错误并返回 `NEEDS_PATCH`；apply 只写 live 文件，originals/ 内文件字节不变；再次 check 返回 `ALREADY_PATCHED`；restore 后 live 文件恢复原始内容且 `.claude-patcher/` 原样保留。
- A2 ultracode 2.1.284 形态：分层门禁 + `Z`/`D`/`A3n` + `Y={ultracode:"xhigh"}` 映射的夹具：check 返回 `NEEDS_PATCH`，apply 后返回 `ALREADY_PATCHED`，restore 后回到 `NEEDS_PATCH`；应用后满足既有语义（仅支持 max 的模型通过资格、xhigh 不可用回退到 max 而非 high、max 与 xhigh 均视为已激活）；2.1.273/2.1.280 旧形态夹具继续匹配；缺消费链或缺映射的诱饵不被匹配。
- A3 computer-use 2.1.284 形态：惰性箭头 schema 夹具：check 返回 `NEEDS_PATCH`，apply 后 `ALREADY_PATCHED`，restore 后复原；直接调用形态（旧）夹具继续匹配。
- A4 真实 `@cometix/anthropic-cc` 2.1.284：临时完整副本上七个补丁依次 `NEEDS_PATCH → apply → ALREADY_PATCHED → restore`，随后批量应用、`node cli.js --version` 启动检查与 `restore-all` 均成功，副本恢复到应用前哈希；真实源包验收前后哈希不变。
- A5 真实 `@cometix/claude-code` 2.1.284（含上游已打补丁与 `.claude-patcher/`）：临时完整副本上七个补丁全部无错误收敛——上游已消费的补丁（ultracode/voice-mode/transcript-dialog/keybindings）报告已应用，computer-use 成功补上上游缺失的设置 schema 键，auto-mode 与 context-limit 正常应用；幂等 check 通过；`restore-all` 后受管文件回到本工具 baseline 哈希，`.claude-patcher/` 与上游标记内容未被改动；真实源包验收前后哈希不变。
- A6 项目现有快速测试全部通过（含 2.1.273/2.1.280 兼容与 dual-layout 生命周期）。

# 约束与不变量

- 继续基于 Acorn AST 与模块绑定关系定位语义目标，不依赖 chunk 文件名或压缩符号名。
- 每个必需语义目标保持唯一匹配；缺失或歧义时快速失败，不静默跳过。
- 扫描排除仅按路径组件精确匹配 `.claude-patcher`，不引入"忽略一切点开头目录"类宽泛规则。
- 新旧包形态均须支持（single-cjs legacy 引擎、2.1.213 flat、2.1.273、2.1.280、2.1.284），补丁标记、可逆 body 编码、事务基线与资源复制协议保持兼容。
- 测试命令使用支持关联数组的 Homebrew Bash 5。

# 决策

- RC1 采用运行时扫描排除 `.claude-patcher` 路径组件（与既有 `node_modules`/`vendor` 排除同机制）；上游状态目录不进入扫描、索引与基线。
- ultracode 与 computer-use 按既有功能规格扩展识别锚点；ultracode 以 `Y={ultracode:"xhigh"}` 映射和 `Z`/`D`/`A3n` 函数结构为主锚（不依赖压缩名 `n9e`/`p7`/`Z`/`D`/`A3n` 本身），schema 以零参箭头解包为主锚。
- 2.1.284 中 ultracode 激活判断改为基于请求别名/设置项（对 max 天然容忍）：存在别名映射且旧激活形态无匹配时，激活目标按 0 基数处理，不算缺失。
- 【2026-09-29 用户改定】上游 CometixSpace patcher 已消费位点时，识别 live 代码中的 `/*@cc:<id>#<site>*/` 上游标记：对应补丁的 0 匹配语义目标按"外部已满足"处理（0 基数），可应用的部分照常应用（computer-use 补上上游缺失的设置键，auto-mode 补剩余位点）；全部目标外部满足或已应用时补丁报告已应用。无标记时保持缺失/歧义快速失败。该决定取代此前"外部状态完全不可见"的表述；`.claude-patcher/` 状态目录本身仍不读取、不修改。
- cruce 真实包验收目标升级到 `@cometix/anthropic-cc` 2.1.284；`@cometix/claude-code`（含 `.claude-patcher/`）作为第二个真实验收目标，只操作临时副本。

# 待解决问题

- 无。

# 验证预期

- 运行新增三项聚焦测试（外部状态目录污染、ultracode 2.1.284 形态、惰性箭头 schema）。
- 运行仓库完整快速测试集。
- 设置 `CC_PATCH_CRUCE_PACKAGE=/opt/homebrew/lib/node_modules/@cometix/anthropic-cc` 运行 cruce 2.1.284 真实包验收；以 `@cometix/claude-code`（含 `.claude-patcher/`）为源运行第二个真实包验收；两者均复制源包并比较前后哈希。
- 用户在真实目标上重跑 `a`（一键应用全部）作为最终用户侧确认。
