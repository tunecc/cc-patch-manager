# Brainstorm Summary

- Change: adapt-cruce-split-esm
- Date: 2026-09-03

## 已确认事实与约束

- 继续使用当前 `cc-patch-manager` 仓库和单一 `cc-patch-manager.sh` 交付物。
- 同时兼容 CometixSpace 2.1.224 single-CJS 与 cruce 2.1.259 split-ESM。
- 七个补丁必须全部完成 check、apply、幂等复检和 restore，不接受首轮部分支持。
- split-ESM 不得依赖 chunk 哈希名、压缩变量名或固定偏移；目标不完整或歧义时必须零写入失败。
- 单补丁内部是全有或全无的事务；`apply-all` 由七个独立事务组成，一个失败不阻止后续补丁。

## 确认的技术方案

- Bash 继续负责参数、目标优先级、TUI、确认和状态展示。
- 将目前七份重复生成的 Node patch 脚本收敛为一个由 Bash heredoc 生成的统一 Node runtime；runtime 按命令和 patch ID 执行 inspect、check、apply、restore 与 baseline 操作，最终仓库仍只有一个可执行脚本。
- runtime 统一拥有 TargetDescriptor、marker 预筛、候选 AST 缓存、静态相对 import/export 索引、PatchPlan 校验、包级 manifest 和事务提交，七个补丁只保留各自的语义分析与 replacement 生成。
- 复用现有机器标记并扩展稳定行协议，避免 Bash 解析本地化文案或强依赖 `jq`。
- package 身份使用 package.json 内容、入口中不受补丁影响的版本/构建元数据和 split 模块文件集合生成稳定指纹；受管文件的原始内容另以基线哈希校验，避免用会被补丁修改的完整入口哈希误判陈旧基线。

## 关键取舍与风险

- 统一 runtime 是对脚本内部结构的较大重组，但只保留一份模块图、事务和协议实现，可避免七份安全关键逻辑漂移。
- 模块索引只解析静态相对 ESM import/export；补丁新增跨模块引用时优先复用目标模块已有绑定，必要时才生成经过循环依赖与启动冒烟验证的静态 import，不实现通用 bundler。
- 包级多文件操作无法取得真正的文件系统全局原子性；通过全量写前验证、同目录临时文件、事务前镜像和故障注入测试保证可恢复。
- 从旧 `cli.js.cc-patch-baseline` 迁移时必须验证版本身份；已有未知补丁而无可信干净基线时拒绝自动收编。

## 测试策略

- 继续使用 Bash 测试入口，以最小 single-CJS 和多模块 split-ESM fixture 做 TDD。
- 共享合同覆盖目标发现、布局识别、模块别名、PatchPlan 基数、行协议、manifest、故障回滚和重打其他补丁。
- 每个补丁覆盖新旧布局完整生命周期；最终在两个真实 package 的临时副本运行矩阵与 CLI 冒烟，且核对当前全局安装哈希未改变。

## Spec Patch

无。现有 delta spec 已覆盖目标、失败条件、事务、恢复和真实版本验收。
