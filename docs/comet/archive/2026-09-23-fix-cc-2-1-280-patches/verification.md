---
generated_from_state_version: 10
---

# 验证

## 当前结果

- 结果: **已归档**
- 验证情况: **已完成检查，验证结果已确认**
- 目标周期: 1
- 迭代: 2
- 验证器尝试次数: 1
- 完成时间: 2026-09-23T02:08:32.051Z
- 摘要: A1-A4 全部通过：2.1.280 auto-mode helper/三元组与 voice-mode 跨 chunk 门禁按规格匹配且诱饵快速失败；真实包七补丁生命周期、CLI 启动与 restore-all 成功；快速测试全部退出码 0，Homebrew 源包验收窗口内未被写入。

## 验收

| 编号 | 结果 | 来源 | 验收项 | 原因 |
| --- | --- | --- | --- | --- |
| A1 | passed | brief.md | A1：对 2.1.280 形态夹具（provider 门禁为 0 参 helper、黑名单为 opus-4-6/sonnet-4-6/haiku 三元组、`supported:` 属性消费门禁且被 `tengu_auto_mode_config` 消费者调用）执行 auto-mode `check` 返回 `NEEDS_PATCH`，应用后返回 `ALREADY_PATCHED`；`firstParty` 内联旧形态夹具继续匹配，缺消费链或缺三元组的诱饵不被匹配。 | test_cc_2_1_280_compat.sh 退出码 0：2.1.280 夹具（0 参 helper 含 firstParty、opus-4-6/sonnet-4-6/haiku 三元组、supported 被 tengu_auto_mode_config 消费）check 为 NEEDS_PATCH，apply 后 ALREADY_PATCHED 且标记写入 auto-gate.js；缺消费链诱饵报告 MISSING_TARGET:model-eligibility；独立探针确认缺 haiku 的三元组不匹配、firstParty 内联旧形态返回 NEEDS_PATCH、跨模块 helper 不误匹配。 |
| A2 | passed | brief.md | A2：对 voice 命令对象与门禁/auth/flag 函数分属两个 chunk 的夹具执行 voice-mode `check` 返回 `NEEDS_PATCH`，应用后返回 `ALREADY_PATCHED`，且 entry-gate 补丁写入门禁定义所在 chunk；门禁与命令对象同 chunk 的旧形态夹具继续匹配。 | 2.1.280 测试退出码 0：命令对象与门禁分属两个 chunk，check 为 NEEDS_PATCH，apply 后 ALREADY_PATCHED，COMETIX_VOICE_GATE 只出现在门禁定义 chunk；2.1.273 同 chunk 夹具由 test_cc_2_1_273_compat.sh 覆盖并退出码 0。 |
| A3 | passed | brief.md | A3：在 `@cometix/anthropic-cc` 2.1.280 真实包的临时完整副本上，全部七个补丁依次完成 `NEEDS_PATCH -> apply -> ALREADY_PATCHED -> restore`，随后批量应用、`node cli.js --version` 启动检查和 `restore-all` 均成功，副本恢复到原始哈希。 | CC_PATCH_CRUCE_PACKAGE=/tmp/cc-clean-2.1.280 真实包验收退出码 0：TARGET_VERSION:2.1.280，七补丁逐项 NEEDS_PATCH 到 apply 到 ALREADY_PATCHED 到 restore，再批量 apply、node cli.js --version、restore-all，副本与源包哈希前后一致。 |
| A4 | passed | brief.md | A4：项目现有快速测试全部通过（含 2.1.273 兼容测试与 dual-layout 生命周期），且真实 `/opt/homebrew` 源包在验收前后哈希不变。 | test_cc_2_1_273_compat.sh、test_dual_layout_lifecycle.sh、test_restore_all_baseline.sh、test_restore_skips_missing_target.sh 均退出码 0；/opt/homebrew 源包在验收窗口内无文件 mtime 变化。 |

## 检查

_没有记录 Runtime 检查。_

### Builder 报告的证据

以下为 Builder 报告，不等同于 Runtime 检查凭据或独立验收结果。

- test_cc_2_1_280_compat.sh: passed — 2.1.280 auto helper 形态与跨 chunk voice 形态，含诱饵
- tests/test_*.sh 全套 16 项: passed — 含 2.1.273 兼容、dual-layout、restore 回归
- test_real_package_acceptance.sh cruce: passed — 2.1.280 干净副本七补丁生命周期通过
- 已知限制: 真实 /opt/homebrew 安装包带有用户之前一键应用的 5 个补丁与基线目录，验收在从基线还原的干净副本 /tmp/cc-clean-2.1.280 上进行；源包未被修改

## 阻塞项

_无。_

## 风险与跳过的工作

- legacy hasModelList 从三家族收成 claude-3- 加 claude-opus-4-，sonnet-4- 不再是必要条件；现有夹具与真实包均含 opus-4-，未观察到回归
- 2.1.280 测试断言 entry-gate 写入定义 chunk，auth-probe 与 feature-flag 的写入位置由代码审查确认（同走 gateProgram）
- provider helper 只认同模块 0 参 FunctionDeclaration，不跟随 import；跨模块探针按规格返回 MISSING_TARGET

## 之前的迭代

| 目标周期 | 迭代 | 尝试 | 结果 | 未解决项 | 摘要 | 完成时间 |
| ---: | ---: | ---: | --- | --- | --- | --- |
| 1 | 1 | 0 | recovery | — | Native check input changed after the candidate was built; a new Builder candidate is required before checks can run again. | 2026-09-23T01:44:29.849Z |
| 1 | 2 | 1 | pass | — | A1-A4 全部通过：2.1.280 auto-mode helper/三元组与 voice-mode 跨 chunk 门禁按规格匹配且诱饵快速失败；真实包七补丁生命周期、CLI 启动与 restore-all 成功；快速测试全部退出码 0，Homebrew 源包验收窗口内未被写入。 | 2026-09-23T02:08:32.051Z |



## 结论

A1-A4 全部通过：2.1.280 auto-mode helper/三元组与 voice-mode 跨 chunk 门禁按规格匹配且诱饵快速失败；真实包七补丁生命周期、CLI 启动与 restore-all 成功；快速测试全部退出码 0，Homebrew 源包验收窗口内未被写入。
