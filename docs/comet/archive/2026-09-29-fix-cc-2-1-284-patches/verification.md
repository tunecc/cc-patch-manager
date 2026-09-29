---
generated_from_state_version: 17
---

# 验证

## 当前结果

- 结果: **已归档**
- 验证情况: **已完成检查，验证结果已确认**
- 目标周期: 2
- 迭代: 2
- 验证器尝试次数: 1
- 完成时间: 2026-09-29T06:31:21.370Z
- 摘要: 三个根因修复验收通过：RC1 .claude-patcher 以精确路径组件排除并通过污染夹具回归（无 AMBIGUOUS_TARGET/relative module 错误、外部状态零改动）；RC2 ultracode 2.1.284 分层门禁/委托资格/双降级/别名激活按语义锚识别，诱饵与缺映射负例均 fail-fast，旧形态兼容保持；RC3 设置 schema 惰性箭头解包且插入保持 thunk 形态、直接调用旧形态继续匹配。证据构成：两个新增聚焦测试本次独立复跑通过（新鲜证据），A4/A5/A6 采信同一工作树零改动前提下的 Runtime 绑定证据（quick-suite 17/17、cruce @cometix/anthropic-cc 2.1.284 七补丁生命周期+哈希复原、cometixcode @cometix/claude-code 2.1.284 七补丁收敛含 2 个外部满足），并经只读核实真实包上游状态与 live 标记。

## 验收

| 编号 | 结果 | 来源 | 验收项 | 原因 |
| --- | --- | --- | --- | --- |
| A1 | passed | brief.md | A1 外部状态目录：合成 split-esm 夹具，包根含 `.claude-patcher/originals/`（内含目标 chunk 的原始副本）与 `applied.json`/`manifest.json`：check 无 `AMBIGUOUS_TARGET`、无 relative module 错误并返回 `NEEDS_PATCH`；apply 只写 live 文件，originals/ 内文件字节不变；再次 check 返回 `ALREADY_PATCHED`；restore 后 live 文件恢复原始内容且 `.claude-patcher/` 原样保留。 | test_claude_patcher_coexistence.sh 夹具 A：包根 .claude-patcher/originals/ 含目标 chunk 副本与 applied.json/manifest.json，check 无 AMBIGUOUS_TARGET/TARGET_ERROR 且 NEEDS_PATCH，apply/restore 后 .claude-patcher 树哈希不变、restore 回 NEEDS_PATCH；实现为 excludedPackagePath 的 parts.includes('.claude-patcher') 精确路径组件排除；本次独立复跑 exit 0 |
| A2 | passed | brief.md | A2 ultracode 2.1.284 形态：分层门禁 + `Z`/`D`/`A3n` + `Y={ultracode:"xhigh"}` 映射的夹具：check 返回 `NEEDS_PATCH`，apply 后返回 `ALREADY_PATCHED`，restore 后回到 `NEEDS_PATCH`；应用后满足既有语义（仅支持 max 的模型通过资格、xhigh 不可用回退到 max 而非 high、max 与 xhigh 均视为已激活）；2.1.273/2.1.280 旧形态夹具继续匹配；缺消费链或缺映射的诱饵不被匹配。 | test_cc_2_1_284_compat.sh：分层门禁+void-0 委托资格+双降级 resolveEffort+ULTRA_ALIAS={ultracode:"xhigh"} 夹具完整走 NEEDS_PATCH→apply→ALREADY_PATCHED→restore，语义断言 max-only 过资格、xhigh 回退 max 而非 high、别名激活；无别名诱饵 fail-fast 报 MISSING_TARGET:ultracode-activation，unrelatedGate 消费链诱饵经唯一匹配不被命中；2.1.273/2.1.280 旧形态由 quick-suite 对应脚本保持 PASS；本次独立复跑 exit 0 |
| A3 | passed | brief.md | A3 computer-use 2.1.284 形态：惰性箭头 schema 夹具：check 返回 `NEEDS_PATCH`，apply 后 `ALREADY_PATCHED`，restore 后复原；直接调用形态（旧）夹具继续匹配。 | 同文件惰性箭头 schema 夹具（50+ 属性、()=>Bool().optional().describe("…compact conversation…")）完整生命周期且断言插入键保持 ()=> thunk 形态、restore 后键移除；直接调用旧形态夹具继续匹配且插入形态不变；computerSchemaRoot 经 unwrapComputerSchemaExpression 解包零参表达式体箭头；本次独立复跑 exit 0 |
| A4 | passed | brief.md | A4 真实 `@cometix/anthropic-cc` 2.1.284：临时完整副本上七个补丁依次 `NEEDS_PATCH → apply → ALREADY_PATCHED → restore`，随后批量应用、`node cli.js --version` 启动检查与 `restore-all` 均成功，副本恢复到应用前哈希；真实源包验收前后哈希不变。 | Runtime 绑定日志 cruce-acceptance：TARGET_PACKAGE:@cometix/anthropic-cc、TARGET_VERSION:2.1.284、PASS cruce 2.1.284 real-package acceptance (7 applicable, 0 documented inapplicable)；验收脚本逐补丁 NEEDS_PATCH→apply→ALREADY_PATCHED→restore、批量应用、node cli.js --version 冒烟、restore-all RESTORED:all、副本与真实源包前后哈希不变 |
| A5 | passed | brief.md | A5 真实 `@cometix/claude-code` 2.1.284（含上游已打补丁与 `.claude-patcher/`）：临时完整副本上七个补丁全部无错误收敛——上游已消费的补丁（ultracode/voice-mode/transcript-dialog/keybindings）报告已应用，computer-use 成功补上上游缺失的设置 schema 键，auto-mode 与 context-limit 正常应用；幂等 check 通过；`restore-all` 后受管文件回到本工具 baseline 哈希，`.claude-patcher/` 与上游标记内容未被改动；真实源包验收前后哈希不变。 | Runtime 绑定日志 cometixcode-acceptance：TARGET_PACKAGE:@cometix/claude-code、TARGET_VERSION:2.1.284、INFO 2 of 7 外部满足、PASS (convergence, 7 patches)；脚本断言七补丁全部无错误收敛且 post-apply 均 ALREADY_PATCHED、副本树（含 .claude-patcher）restore-all 后哈希复原、真实源包前后哈希不变；真实包上游状态与 12 个 /*@cc:*#*/ live 标记核实，夹具 B 另证 computer-use 补上游缺失 schema 键且不重打已消费 gate、无标记时 fail-fast |
| A6 | passed | brief.md | A6 项目现有快速测试全部通过（含 2.1.273/2.1.280 兼容与 dual-layout 生命周期）。 | Runtime quick-suite 日志 17 个测试脚本（除真实包验收外全部）无 FAIL 全 PASS，含 2.1.273/2.1.280/2.1.284 兼容与 dual-layout 生命周期（single-CJS/split-ESM 同生命周期）；唯一 [错误] 行为 target_descriptor 负例预期输出；Runtime 记录 17/17 exit 0 |

## 检查

_没有记录 Runtime 检查。_

### Builder 报告的证据

以下为 Builder 报告，不等同于 Runtime 检查凭据或独立验收结果。

- quick-suite: passed — 17/17 快速测试通过（含新增 test_cc_2_1_284_compat.sh 与 test_claude_patcher_coexistence.sh）；本次候选重新运行再次通过（exit 0）
- cruce-real-acceptance: passed — cruce 2.1.284 真实包七补丁完整生命周期 + restore-all 哈希复原，源包前后哈希不变（同一工作树，代码零改动）
- cometixcode-real-acceptance: passed — cometixcode 2.1.284（含上游补丁与 .claude-patcher/）七补丁无错误收敛（2 个外部满足），restore-all 后树哈希复原（.claude-patcher 未动），源包前后哈希不变（同一工作树，代码零改动）
- 已知限制: cometixspace 2.1.224 验收路径未运行（本机无该包源；与本次三处修复无交集）
- 已知限制: 用户在真实目标上重跑一键应用 [a] 的最终用户侧确认尚未执行（真实安装包只做过只读 --check）

## 阻塞项

_无。_

## 风险与跳过的工作

- cometixspace 2.1.224 验收路径未运行（本机无该包源；与本次三处修复无交集）
- 用户在真实目标上重跑一键应用 [a] 的最终用户侧确认尚未执行（真实安装包只做过只读 --check 与临时副本验收）
- EXTERNAL_PATCH_EQUIVALENTS 比 delta spec 枚举多出 auto-mode↔chrome-local-socket、voice-mode↔voice-asr-backend 两条未记载映射：真实包确有这两个上游 patch id 且实际结果被同时存在的 classifier/enable-voice 标记遮蔽，但该映射孤立生效时的正确性未经测试、change 文档亦无记载

## 之前的迭代

| 目标周期 | 迭代 | 尝试 | 结果 | 未解决项 | 摘要 | 完成时间 |
| ---: | ---: | ---: | --- | --- | --- | --- |
| 1 | 1 | 0 | recovery | — | Formal requirement write requested for brief.md | 2026-09-29T02:35:09.259Z |
| 2 | 1 | 1 | execution-error | — | Verifier subagent 因宿主 API 错误提前终止（HTTP 400 upstream_error，未产出任何验收结果），需重新派发。 | 2026-09-29T05:15:15.831Z |
| 2 | 1 | 2 | execution-error | — | attempt 2 的独立 Verifier 子代理在推理网关连续故障后终止且无任何结果产出：先 400 upstream_error，随后 502 请求转发失败，最后一次宿主报 503 No active API keys available for this group（网关 127.0.0.1:15721）。子代理未完成任何验收项，未留下部分证据（临时脚本亦丢失）。恢复方式变化：网关已恢复可用，将以全新 Verifier 重试同一验收范围；Runtime 已完成的 3 项检查（quick-suite/cruce-acceptance/cometixcode-acceptance）证据保留并可复用。 | 2026-09-29T06:16:45.409Z |
| 2 | 1 | 2 | recovery | — | Native check input changed after the candidate was built; a new Builder candidate is required before checks can run again. | 2026-09-29T06:17:03.328Z |
| 2 | 2 | 1 | pass | — | 三个根因修复验收通过：RC1 .claude-patcher 以精确路径组件排除并通过污染夹具回归（无 AMBIGUOUS_TARGET/relative module 错误、外部状态零改动）；RC2 ultracode 2.1.284 分层门禁/委托资格/双降级/别名激活按语义锚识别，诱饵与缺映射负例均 fail-fast，旧形态兼容保持；RC3 设置 schema 惰性箭头解包且插入保持 thunk 形态、直接调用旧形态继续匹配。证据构成：两个新增聚焦测试本次独立复跑通过（新鲜证据），A4/A5/A6 采信同一工作树零改动前提下的 Runtime 绑定证据（quick-suite 17/17、cruce @cometix/anthropic-cc 2.1.284 七补丁生命周期+哈希复原、cometixcode @cometix/claude-code 2.1.284 七补丁收敛含 2 个外部满足），并经只读核实真实包上游状态与 live 标记。 | 2026-09-29T06:31:21.370Z |



## 结论

三个根因修复验收通过：RC1 .claude-patcher 以精确路径组件排除并通过污染夹具回归（无 AMBIGUOUS_TARGET/relative module 错误、外部状态零改动）；RC2 ultracode 2.1.284 分层门禁/委托资格/双降级/别名激活按语义锚识别，诱饵与缺映射负例均 fail-fast，旧形态兼容保持；RC3 设置 schema 惰性箭头解包且插入保持 thunk 形态、直接调用旧形态继续匹配。证据构成：两个新增聚焦测试本次独立复跑通过（新鲜证据），A4/A5/A6 采信同一工作树零改动前提下的 Runtime 绑定证据（quick-suite 17/17、cruce @cometix/anthropic-cc 2.1.284 七补丁生命周期+哈希复原、cometixcode @cometix/claude-code 2.1.284 七补丁收敛含 2 个外部满足），并经只读核实真实包上游状态与 live 标记。
