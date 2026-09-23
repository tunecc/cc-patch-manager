# 补丁引擎

## 目标包与布局

补丁管理器支持已识别的 `@cometix/claude-code` single-cjs 包和 `@cometix/anthropic-cc` split-esm 包。目标身份来自包清单与入口文件，补丁定位不得依赖易变化的 chunk 文件名或压缩符号名。

## 语义规划

每个补丁先生成基于 AST 的 PatchPlan。每个必需语义目标必须恰好匹配一次；零次匹配报告 `MISSING_TARGET`，多次匹配报告 `AMBIGUOUS_TARGET`。只有完整计划通过目标、重叠、解析和来源校验后才能进入事务写入。

### 自动模式

自动模式补丁必须唯一识别实际被 Auto 可用性逻辑消费的模型资格门禁（`supported:` 属性调用门禁，且该消费者被 body 含 `tengu_auto_mode_config` 的函数调用）。消费链是主锚；provider 门禁与模型黑名单按以下任一形态确认：

- provider 门禁：资格函数 body 内联 `firstParty` 比较，或调用同模块 0 参 helper 且 helper body 含 `firstParty` 比较（2.1.280 形态）；
- 模型黑名单：legacy 家族（`claude-3-` + `claude-opus-4-` + `claude-sonnet-4-`）直接位于门禁 body，或位于门禁调用的同模块 1 参 helper（helper 形态通过模型字符串、返回结构和消费关系共同确认），或门禁 body 直接含 2.1.273/2.1.280 第二条件共有的 `claude-opus-4-6` + `claude-sonnet-4-6` + `haiku` 三元组。

模型资格候选扫描不得依赖 `claude-3-` 继续存在；候选 token 同时覆盖 legacy 家族与新三元组。

应用后模型资格门禁始终允许 Auto，分类器模型可由 `CLAUDE_CLASSIFIER_MODEL` 覆盖，分类器不可用且不能回退到提问对话时返回询问决策而不是拒绝决策。

### Ultracode

Ultracode 补丁必须沿模块绑定关系唯一识别 xhigh gate、max gate、资格判断、effort fallback 和激活判断。激活函数可以携带三个或四个参数；额外的 per-turn effort 参数及其解析调用必须原样保留。

应用后仅支持 max 的模型也通过 Ultracode 资格判断，xhigh 不可用时回退到 max，并且解析出的 max 与 xhigh 都视为已激活。

### 语音模式

语音模式补丁必须唯一识别入口门禁、认证与 feature flag、流能力、命令 availability、设置数组和语音连接函数。入口门禁解析优先在命令对象所在 chunk 内按名查找；同 chunk 无定义时沿 import 绑定（ModuleIndex）解析到门禁定义文件后按导出名查找，entry-gate、auth-probe 与 feature-flag 补丁写入门禁定义所在文件。设置宿主可以提供旧式 `setChanges` setter，或提供带 `record` 方法的 `changeLog` 对象；注入代码必须使用宿主实际存在的接口。

应用后设置项写入 `userSettings`，同步 settings 与 app state，并记录 Voice mode 变更；本地 Cometix ASR 资源按事务协议复制，重复检查报告已应用。

## 事务与还原

首次成功写入前创建可信 package baseline。单补丁应用与还原以及批量应用必须保持原子性；失败不能留下部分写入。`restore-all` 恢复所有受管文件并删除补丁创建的目录。基线身份、哈希或路径不可信时必须拒绝操作。

## 兼容与验收

single-cjs legacy 引擎与 split-esm 各历史形态（2.1.213 flat、2.1.273、2.1.280）必须继续通过对应回归夹具。2.1.273 与 2.1.280 split-esm 必须通过七补丁的逐项检查、应用、幂等检查和还原生命周期。批量应用后的 CLI 必须能输出版本；全还原后临时包树必须与应用前一致。真实安装包只作为只读源复制，验收不得改变其内容。
