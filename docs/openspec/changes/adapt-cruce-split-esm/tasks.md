## 1. 双布局目标与分析基础

- [ ] 1.1 为显式路径、`CLAUDE_CLI_PATH`、旧 `@cometix/claude-code` 与新 `@cometix/anthropic-cc` 自动发现编写失败测试，并验证测试能够区分优先级和无效 package
- [ ] 1.2 实现 TargetDescriptor 与结构化 `single-cjs`/`split-esm` 检测，并通过 1.1 的目标解析测试及现有路径行为回归测试
- [ ] 1.3 为 marker 预筛、ESM 静态 import/export 别名和跨 chunk 绑定解析编写最小多模块失败 fixture，并验证歧义、缺失导出和 `node_modules` 排除场景均被覆盖
- [ ] 1.4 实现候选文件扫描与轻量模块索引，并通过 1.3 测试且确认对 cruce 2.1.259 只解析 marker 命中的候选模块
- [ ] 1.5 定义共享 PatchPlan 的必要目标基数、按文件 replacements、资源操作、已应用状态和后置验证合同，并通过 check/apply 共用分析路径及“不完整计划零写入”测试

## 2. 包级基线与事务

- [ ] 2.1 为 package 身份、版本、布局、入口哈希、逐路径原始哈希/模式/不存在状态编写 manifest 失败测试，并覆盖陈旧基线与未知修改拒绝场景
- [ ] 2.2 实现包级 manifest 和相对路径基线镜像，保留 single-CJS 旧基线读取兼容，并通过 2.1 与现有单文件基线测试
- [ ] 2.3 为多文件写前校验、临时文件替换、中途 I/O 故障和 VoiceMode 资源操作编写事务故障测试，并验证所有故障场景恢复到事务前逐文件哈希
- [ ] 2.4 实现 PatchPlan 事务提交与故障恢复，并通过 2.3 测试及 AST/后置条件失败零写入测试
- [ ] 2.5 实现包级恢复、单补丁移除和其余已应用补丁重打，并通过跨文件补丁组合、VoiceMode 原始不存在资源和幂等恢复测试

## 3. 七补丁 split-ESM 迁移

- [ ] 3.1 先增加 Auto Mode 与 Keybindings 的 split-ESM 多模块失败 fixture，再迁移两者的候选定位和 PatchPlan 生成，并通过新 fixture 与现有 single-CJS 回归测试
- [ ] 3.2 先增加权限弹窗重放与 Ultracode 的 split-ESM 多模块失败 fixture，再迁移 module AST、channel/cleanup 及 xhigh/max/激活目标，并通过新旧布局生命周期测试
- [ ] 3.3 先增加 VoiceMode 七类语义目标和 ASR vendor 操作的 split-ESM 失败 fixture，再迁移 VoiceMode PatchPlan，并通过平台门禁、资源缺失、应用、复检和还原测试
- [ ] 3.4 先增加 Context Limit 跨模块默认值与 settings env 刷新失败 fixture，再实现绑定解析和补丁后刷新语义，并通过环境变量、settings env、幂等与恢复测试
- [ ] 3.5 先增加 Computer Use 跨模块 schema、启用门禁、配置合并与 settings helper 失败 fixture，再迁移 PatchPlan，并通过默认关闭、环境变量、settings、部分状态修复与恢复测试

## 4. 交互、诊断与批量行为

- [ ] 4.1 更新 TUI 与 `--check` 输出以显示 package、版本和布局，并通过旧新目标快照测试及错误信息包含补丁 ID、阶段、候选文件和缺失目标的断言
- [ ] 4.2 保持 `apply-all` 一次确认和固定补丁顺序，为单补丁事务失败后继续后续补丁编写测试，并验证最终成功/跳过/失败汇总准确
- [ ] 4.3 运行全部现有测试并修复仅由目标抽象或包级基线引起的回归，验证 `tests/test_*.sh` 全部通过且旧 single-CJS 七补丁行为不退化

## 5. 真实包验收

- [ ] 5.1 获取或构建 CometixSpace 2.1.224 package 临时副本，在副本中完成七补丁 check/apply/幂等/单补丁还原/全还原矩阵，并验证还原后逐文件哈希与基线一致及 CLI 冒烟通过
- [ ] 5.2 复制本机 cruce 2.1.259 package 到临时目录，在副本中完成七补丁 check/apply/幂等/单补丁还原/全还原矩阵，并验证当前全局安装哈希未改变及 CLI 冒烟通过
- [ ] 5.3 运行 Shell 语法检查、全部快速测试和双真实版本验收，记录每项命令与结果，并确认 Git diff 只包含获准的脚本、测试和 Comet/OpenSpec 产物
