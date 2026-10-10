# 目标

修复"脚本报告已解锁、实际功能未解锁"的根因：**补丁管理器只发现并修补两个已安装发行版中的一个，而用户实际运行的是另一个**；同时在发现多个目标时让用户选择应用到哪一个。

## 已查明的事实（只读调查，未改动任何安装包）

**F1 本机装了两个 Claude Code 发行版，版本与安装方式都不同。**

| 发行版 | 版本 | npm 包路径 | 真实 JS 入口 | 补丁状态 |
| --- | --- | --- | --- | --- |
| `@cometix/claude-code`（CometixSpace） | 2.1.284 | `/opt/homebrew/lib/node_modules/@cometix/claude-code/` | 包内 `cli.js`（split-ESM，约 211 MB） | 七个补丁全部已应用（本工具 + 上游 patcher 混合） |
| `@cometix/anthropic-cc`（y-cruce） | **2.1.296** | `/opt/homebrew/lib/node_modules/@cometix/anthropic-cc/` | 包内 `cli.js` 只是 179 字节启动器；真实 JS 在生成的运行树 `~/.local/share/anthropic-cc/versions/2.1.296/build-1791622995381-dAxjz9/runtime-entry.js` | **完全未打补丁** |

安装来源（`~/.zsh_history`）：`@cometix/claude-code` 来自 `npm install -g @cometix/claude-code`；`@cometix/anthropic-cc` 来自 `curl -fsSL https://raw.githubusercontent.com/y-cruce/claude-code/main/install.sh | bash`（该发行版只发 GitHub Releases，npmjs.org 上 404，最高版本 2.1.296）。用户实际运行的命令是 `anthropic-cc`（`/opt/homebrew/bin/anthropic-cc`）。

**F2 `find_cli_js()` 永远只返回第一个目标。**
候选列表顺序为 `@anthropic-ai/claude-code` → `@cometix/claude-code` → `@cometix/anthropic-cc`（`cc-patch-manager.sh:196-232`）。本机 `@cometix/claude-code/cli.js` 先命中，`@cometix/anthropic-cc` 永远不会被检查到。脚本也没有任何"检测到多个目标"的提示或选择入口——用户明确指出这是缺陷。

**F3 即使指向 `@cometix/anthropic-cc` 的包内 `cli.js` 也无法工作。**
该文件是 179 字节启动器（`import('./runtime.mjs')`），没有任何顶层 `ImportDeclaration`，也没有 CommonJS 形态 → 七个补丁全部报 `TARGET_ERROR:"entry has neither split-ESM imports nor a single-CJS shape"`。

**F4 `@cometix/anthropic-cc` 的真实运行树是运行时生成的，路径不在包内。**
`runtime.mjs` 的 `launch()` 把平台包 `@cometix/anthropic-cc-darwin-arm64` 复制到 `versionsRoot()/versions/<version>/<build>/`，并把原 `cli.js` 改名为 `runtime-entry.js`，再写一个 438 字节的 `cli.js`（写 PID 后 `import('./runtime-entry.js')`）。选择规则：
- 根目录：`process.env.ANTHROPIC_CC_DATA_DIR`，否则 `$XDG_DATA_HOME/anthropic-cc/versions`，否则 `~/.local/share/anthropic-cc/versions`。
- 指针：`versions/<version>/current.json` = `{"build":"build-<ts>-<rand>","source":"<runtimeBuild>"}`；运行树 = `versions/<version>/<build>`，且必须含 `cli.js`。
- `source` 必须等于主包 `package.json` 的 `runtimeBuild`，否则重新生成；旧运行树由 `prune()` 清理。
- 该树的 `package.json` 由主包 `package.json` 整体写入，`name` 仍为 `@cometix/anthropic-cc`（在 `supportedPackages` 内）。

**F5 引擎本身已经支持 2.1.296，不需要改分析器。**
在 `/tmp/cc296tree`（2.1.296 运行树的完整副本，未触碰真实安装）上以 `runtime-entry.js` 为入口实测：
- 七个补丁 check 全部 `NEEDS_PATCH`（auto-mode 3 / keybindings 1 / transcript-dialog 2 / ultracode 2 / voice-mode 7 / context-limit 3 / computer-use 4）；
- apply 全部 `PATCHED`，落点为本工具标记（`COMETIX_VOICE_GATE/FLAG/AUTH/AVAIL/SETTING/STREAM_AVAIL/ASR_VOICE_STREAM`、`CC_AUTO_MODE_MODEL_ELIGIBILITY/FAIL_OPEN`、`CC_KEYBINDINGS_CTRL_C`、`CC_DIALOG_FIX_*`、`CC_ULTRACODE_ELIGIBILITY/EFFORT_FALLBACK`、`CC_CONTEXT_DEFAULT/SETTINGS_REFRESH`、`CC_COMPUTER_CONFIG/ENABLE/IMPORTS/SCHEMA`）与 `vendor/cometix-asr`；
- 复检全部 `ALREADY_PATCHED`；`restore-all` 后与 pristine 副本逐字节一致（仅多出 `.cc-patch-manager-baseline`）。
→ **唯一缺口是目标解析，不是补丁引擎。**

**F6 用户"语音模式没解锁"的直接原因。**
2.1.296 运行树内既无本工具标记也无上游 `@cc:` 标记（只有原始包里就有的 `CC_MEMORY`/`CC_COLORS`/`CC_EXEC_PREFIX`/`CC_DISCLAIMED`/`CC_KEEP_` 等字符串，纯净 2.1.285 副本里同样存在，属干扰项而非补丁标记）。用户实际运行的是这个未打补丁的 2.1.296；`--check` 显示的"已应用"来自另一个没人运行的 2.1.284。

**F7 2.1.296 官方 `@anthropic-ai/claude-code` 只有原生二进制**（`bin/claude.exe` + 平台 optionalDependencies，tar 内无 cli.js），与本 change 无关；本 change 的可补丁 2.1.296 指 y-cruce 的 Node 还原版。

**F8 补丁耐久性问题。**
2.1.296 的运行树由 `runtime.mjs` 在 `runtimeBuild` 变化时整体重建并 prune 旧树。打在运行树里的补丁会在升级时静默丢失，用户再次运行脚本时会看到"未应用"。这一点必须在产品行为上可见（提示或自动重打），否则会再次表现为"显示解锁/实际没解锁"。

**F9 上游 patcher（`.claude-patcher/`）与外部满足判定。**
2.1.284 上四个补丁的部分语义目标靠 live 代码里的 `/*@cc:<id>#<site>*/` 上游标记按"外部已满足"计入已应用（`EXTERNAL_PATCH_EQUIVALENTS`，`cc-patch-manager.sh:1267`）。本机 2.1.296 树上没有任何上游标记，因此该项对本 change 的主目标无影响；但既然要改状态语义，需要一并决定是否区分"本工具已应用 / 仅外部已应用"。

**F10 `@cometix/anthropic-cc` 的包内布局在 2.1.296 发生了变化，这是本回归的直接原因。**
上一个 change（`fix-cc-2-1-284-patches`，已归档）在 `@cometix/anthropic-cc` **2.1.284** 上做过完整真实包验收：`cli.js` 就是真实入口，七补丁 `NEEDS_PATCH → apply → ALREADY_PATCHED → restore` 全通过，并用 `node cli.js --version` 做启动冒烟。到 **2.1.296**，y-cruce 把包内 `cli.js` 改成 179 字节启动器、真实入口搬到 `~/.local/share/anthropic-cc/versions/<version>/<build>/runtime-entry.js`（见 F4）。`find_cli_js()` 与该版验收通过时的假设不再成立，于是整台 2.1.296 从未被打过补丁。

# 范围

`cc-patch-manager.sh`（及配套测试）：

1. **目标发现**：枚举本机全部可补丁目标，覆盖两种发行版：
   - `@cometix/claude-code`：沿用现有 `cli.js` 解析。
   - `@cometix/anthropic-cc`：解析包内 `package.json` 的 `runtimeBuild`，按 F4 规则定位当前运行树，取 `runtime-entry.js` 作为真实入口；运行树不存在（从未启动过）时给出明确提示。
   - 保持 `CLAUDE_CLI_PATH` / 位置参数显式指定的最高优先级。
2. **多目标选择**（用户已确认）：交互菜单在检测到多个目标时弹出选择清单（`[t]` 可随时改选）；`--check` 把检测到的全部目标依次列出（各自包名、版本、路径与七个补丁状态），不静默只报第一个。未做出选择时不写任何文件。切换目标时同时清空上一个目标的身份与状态缓存。破坏性 `--restore-all` 在多目标环境下拒绝执行并要求显式指定目标。
3. **耐久性可见化**：识别 `@cometix/anthropic-cc` 目标，在其运行树可能被重建时给出明确提示，避免升级后补丁静默丢失。
4. **状态语义**（用户已确认）：`--check` 与菜单状态区分三态——"已应用"（本工具标记）、"外部已应用"（仅由上游 `/*@cc:<id>#<site>*/` 标记满足）、"未应用"；错误态保持原样。由运行时新增的 `PATCH_SOURCE:` 协议行提供依据。
5. **测试**：合成 `@cometix/anthropic-cc` 夹具（启动器 `cli.js` + 生成运行树 + `current.json`），覆盖：单目标解析、多目标枚举与选择、运行树缺失、`runtimeBuild` 不匹配、切换目标清缓存、`--restore-all` 拒绝、三态状态显示；`tests/test_real_package_acceptance.sh` 新增 `cruce-launcher` 目标类型。
6. 真实包只读验收：2.1.296（`@cometix/anthropic-cc` 运行树）复制到临时副本完成七补丁全流程与 `restore-all`，源运行树前后哈希不变；2.1.284 源包同样只读。**不改动任何真实安装**（用户已确认由用户自行运行脚本应用）。

## 本次实际改动

- `cc-patch-manager.sh`
  - 目标发现：新增 `candidate_package_roots` / `patchable_package_names` / `anthropic_cc_versions_root` / `json_scalar_field` / `resolve_anthropic_cc_runtime_entry` / `anthropic_cc_runtime_entry_only` / `discover_targets`；`find_cli_js` 改为基于 `discover_targets` 的薄封装（返回第一个可补丁目标，保持旧调用方语义）。
  - 目标选择：新增 `TARGET_*` 清单、`load_targets` / `select_target` / `target_note_cn` / `target_check_note` / `choose_target_interactive`；`main()` 在无显式路径时枚举目标，多目标交互询问；`menu_loop` 新增 `[t]` 换目标（显式指定路径时拒绝覆盖）；`draw_header` 显示启动树耐久性提醒与"第 n/m 个发行版"。
  - 启动器重定向：`launcher_real_entry` / `redirect_launcher_entry`，显式指向启动器 `cli.js` 时改指向运行树 `runtime-entry.js` 并说明原因。
  - `run_check_mode` 拆出 `print_check_table`，按目标循环输出，新增"外部已应用"状态列；启动器解析失败的目标只输出说明与"暂不可补丁"，不把 179 字节启动器交给引擎。
  - `run_restore_all_mode` 多目标时拒绝执行。
  - 运行时（`write_patch_runtime`）：新增 `patchSource(plan)`，在 `ALREADY_PATCHED` 时追加 `PATCH_SOURCE:own|external|mixed|structural`；`parse_and_set_status` 据此把 `external` 映射为独立状态。
- 测试：新增 `tests/test_launcher_layout_discovery.sh`；`tests/test_real_package_acceptance.sh` 新增 `cruce-launcher` 目标类型（入口名 `runtime-entry.js`）。

## 第一轮 Verify 失败与修复

Runtime 首轮独立验收判定 **A4 / A5 失败**（7/9 通过），缺陷真实存在：

- **现象**：`discover_targets` 在命令替换里调用 `resolve_anthropic_cc_runtime_entry`，该函数把失败原因写进全局变量 `CC_RESOLVE_REASON`，而命令替换运行在子 shell 中，原因随子 shell 一起丢失。结果是备注列恒为空，`--check` 改而显示通用耐久性提示，并把 179 字节启动器 `cli.js` 交给引擎，输出 A4 明令禁止的 `统一补丁失败: "entry has neither split-ESM imports nor a single-CJS shape"` 与 `cruce 目标结构检查失败，已拒绝旧单文件写入路径`，退出码 1；选择清单里该目标显示 `[launcher]` 而非原因，且可被选中。
- **掩盖原因**：新增测试直接调用 `resolve_anthropic_cc_runtime_entry`，`CC_RESOLVE_REASON` 留在测试自身 shell 中，后续 `discover_targets` 子 shell 继承了这个残留值，`cut -f5` 因此偶然通过；测试也从未对"损坏的启动器"跑过 `--check`。
- **修复**：
  1. `resolve_anthropic_cc_runtime_entry` 改为单行输出 `<真实入口>\t<失败原因>`，两个字段走同一行 stdout，命令替换即可同时取到；新增 `anthropic_cc_runtime_entry_only` 供只需要入口的调用方使用。彻底移除全局变量传值。
  2. `discover_targets` 解析失败时入口留空、只带原因；`run_check_mode` 对入口为空的目标只输出路径、中文原因与"暂不可补丁"，不再调用引擎。
  3. `choose_target_interactive` 对不可补丁目标只显示原因、不给可选编号；只有本机恰好一个目标时才静默选中（保持单目标旧行为），否则一律列出全部已发现目标。
  4. `[t]` 在目标是显式指定路径时拒绝覆盖，引导用户先按 `[p]` 或重新指定。
  5. 测试改为通过命令替换断言原因（不再读全局变量），并新增：损坏启动器的 `--check` 不得出现内部引擎错误、必须出现中文原因与"暂不可补丁"、健康兄弟目标仍被完整报告；选择清单必须显示不可用原因且不给编号。
- **回归验证**：把修复按原样改回缺陷版本后，测试在 `successful resolution carries no reason` 断言上失败（证明断言有效）；恢复修复后通过。
- 修复后复跑：19/19 测试通过；`cruce-launcher` 真实包验收通过；本机 `--check` 两个目标输出正常；两个真实安装仍未写入。

# 非目标

- 不改变七个补丁的功能定义、默认开关或菜单交互。
- 不修改、迁移、清理或还原上游 patcher 的 `.claude-patcher/` 状态目录。
- 不放宽目标唯一性、事务原子性、基线完整性或包身份校验。
- 不自动升级/降级任何 Claude Code 安装，不调用 y-cruce 或 CometixSpace 的安装脚本。
- 不支持官方 `@anthropic-ai/claude-code` 原生二进制（无 cli.js，见 F7）。
- 不重构与目标解析无关的分析器。

# 验收示例

- A1 单目标（仅 `@cometix/claude-code`）：行为与现在完全一致，`--check` 只输出一个身份行、不出现多目标横幅、不出现运行树提示。
- A2 多目标（两个发行版都在）：`--check` 依次列出 2 个目标（各自包名、版本、路径）及每个补丁状态；交互菜单在应用前弹出目标选择清单；未选择时不写任何文件。
- A3 `@cometix/anthropic-cc` 目标：解析到当前运行树的 `runtime-entry.js`；七个补丁 `NEEDS_PATCH → apply → ALREADY_PATCHED → restore` 全通过；`--check` 显示的包名/版本为 `@cometix/anthropic-cc` 2.1.296。
- A4 运行树缺失（装过主包但从未启动过）：目标仍被列出但带中文可操作备注，不报"entry has neither split-ESM imports nor a single-CJS shape"这类内部错误。
- A5 `runtimeBuild` 不匹配 / 运行树被重建：识别为 `stale-runtime-build` 并提示"运行树已过期（重启该 CLI 后会重建）"；启动器形态目标在 `--check` 与菜单头常驻显示耐久性提醒。
- A6 显式指定路径（位置参数 / `CLAUDE_CLI_PATH`）仍然最高优先，且指向 `@cometix/anthropic-cc` 包内启动器 `cli.js` 时自动改指向运行树 `runtime-entry.js` 并说明原因。
- A7 三态状态显示：仅有本工具标记 → "已应用"；仅有上游 `@cc:` 标记 → "外部已应用"；两者都无 → "未应用"；`--check` 与交互菜单显示一致。
- A8 真实安装只读验收：2.1.296 运行树临时副本上七补丁 `check→apply→check→restore`、批量应用、`node runtime-entry.js --version` 冒烟与 `restore-all` 均成功，副本回到应用前哈希；2.1.296 源运行树与 2.1.284 源包验收前后哈希不变。
- A9 现有快速测试集全部通过（18 个既有测试 + 1 个新增）。

补充行为（同属范围第 2 项，不单独占验收 ID）：破坏性 `--restore-all` 在多目标环境下拒绝执行并要求显式指定目标，不静默挑第一个。

# 约束与不变量

- 继续基于 Acorn AST 与模块绑定关系定位语义目标，不依赖 chunk 文件名或压缩符号名。
- 每个必需语义目标保持唯一匹配；缺失或歧义时快速失败，不静默跳过。
- 新旧包形态均须支持（single-cjs legacy、2.1.213 flat、2.1.273、2.1.280、2.1.284、2.1.296），补丁标记、可逆 body 编码、事务基线与资源复制协议保持兼容。
- 真实安装包只作只读源复制验收，不直接写入 `/opt/homebrew` 或 `~/.local/share/anthropic-cc`。
- 测试命令使用支持关联数组的 Homebrew Bash 5。
- `@cometix/anthropic-cc` 运行树定位逻辑必须与上游 `runtime.mjs` 的语义保持一致（环境变量、`current.json`、`runtimeBuild` 校验、`cli.js` 存在性）。

# 决策

- 已定：两种发行版都要支持，`@cometix/anthropic-cc` 以运行树的 `runtime-entry.js` 为补丁入口（引擎已验证可用，见 F5）。
- 已定：真实安装包一律只读验收，操作只在临时副本上进行；**由用户自行运行脚本把补丁应用到真实目标**，不由本 change 代打。
- 【2026-10-10 用户确认】多目标时：交互菜单弹目标选择清单，`--check` 依次列出全部检测到的目标，不静默只报第一个；未选择不写文件。
- 【2026-10-10 用户确认】状态三态："已应用"（本工具标记）、"外部已应用"（仅上游 `@cc:` 标记满足）、"未应用"，错误态保持原样。

# 待解决问题

- 无。

# 验证预期

- 运行新增/扩充的聚焦测试（anthropic-cc 夹具族）与仓库完整快速测试集。
- 在 2.1.296 运行树临时副本上跑七补丁 apply/check/restore，并与 pristine 副本逐字节 diff 复核。
- 本机两个真实安装只读验收：复制到临时目录后操作，比较前后哈希。
- `--check` 与菜单的三态显示、多目标清单在真实双目标环境下手动核对。
