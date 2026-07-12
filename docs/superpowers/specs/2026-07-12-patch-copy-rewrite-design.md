# Claude Code 补丁管理器 — 用户可见文案优化 Design Spec

**Date:** 2026-07-12  
**Status:** Approved for implementation planning  
**Scope:** 仅 `cc-patch-manager.sh` 用户可见中文文案  
**Reference:** 原作者帖子导出 `又来修一下CC.html`（linux.do / 哈雷彗星）

## 1. Problem

管理器主列表与详情页的说明偏实现口吻（`fail-open`、`max/xhigh`、「三处补丁」），用户第一眼对不上「解决什么痛」。原帖用「现象 → 原因 → 补丁」讲清楚四个产物；现文案未继承该叙事。

## 2. Goal

在不改功能、不改四个 `apply-*.sh`、不改备份/应用逻辑的前提下，让：

1. 主列表名称偏**能力**（好扫）
2. 主列表一句话偏**现象**（好共鸣，对齐原帖）
3. 详情页 = **现象 1–2 句 + 改动列表**（不写 AST / 函数名）

## 3. Non-Goals

- 不改 `apply-claude-code-*.sh` 顶部英文 PURPOSE / FIX_DESCRIPTION
- 不改设计文档 Purpose 表以外的架构说明（本 spec 只服务文案；旧 design 可后续另开）
- 不改状态词、菜单键位、registry 顺序、备份策略、一键应用逻辑
- 不新增 README / 对外文档（除非用户另开任务）

## 4. Constraints

- 主列表名称列宽约 14 显示宽；说明单行、不换行
- 详情无 `fail-open`、无内部函数名、无 AST 术语
- 可保留用户可操作信息：`CLAUDE_CLASSIFIER_MODEL`、`~/.claude/keybindings.json`、`Escape`
- 语言：简体中文；语气贴近原帖但不照搬口语脏话
- PATCH_IDS 顺序不变：`auto-mode` → `keybindings` → `transcript-dialog` → `ultracode`

## 5. Copy Inventory（唯一真相源）

实现时只替换 `patch_name` / `patch_note` / `patch_purpose`（及可选 `usage` 半行简介）。下列正文为定稿字符串。

### 5.1 `patch_name`

| id | 新名称 |
|----|--------|
| `auto-mode` | 自动模式解锁 |
| `keybindings` | 快捷键与 Ctrl+C |
| `transcript-dialog` | 权限弹窗重放 |
| `ultracode` | Ultracode 解锁 |

### 5.2 `patch_note`（主列表一句话）

| id | 新说明 |
|----|--------|
| `auto-mode` | 非默认模型也能开 Auto；分类器可改用 Haiku |
| `keybindings` | 开自定义快捷键；Ctrl+C 退出，Esc 才中断 |
| `transcript-dialog` | Ctrl+O 看会话时审批卡 Waiting… / 被中断 |
| `ultracode` | 在只支持 max、不支持 xhigh 的模型上启用 |

### 5.3 `patch_purpose`（详情：现象 + 改动）

**auto-mode**

```
现象：部分模型（如早期 Opus 4.6）进不了 Auto Mode；分类器常跟主对话
用同一模型，贵且易 429，作者实践里 Haiku 更稳。

改动：
  (1) 放开自动模式的模型资格检查
  (2) 分类器暂时不可用时改为询问，而不是直接拒绝
  (3) 支持环境变量 CLAUDE_CLASSIFIER_MODEL 指定分类模型
```

**keybindings**

```
现象：自定义快捷键被功能开关关掉；且 2.1.x 起 Ctrl+C 默认直接打断
Agent（旧版更像「再按一次才退出」），习惯旧行为的人容易误触。

改动：
  (1) 强制开启自定义快捷键（~/.claude/keybindings.json）
  (2) 默认 Ctrl+C 改为退出程序；中断 Agent 仍用 Escape
```

**transcript-dialog**

```
现象：从约 2.1.140+ 起，在 Ctrl+O 会话记录视图时若触发权限审批，
会一直 Waiting…；反过来在审批将出时切视图，也可能直接中断对话。

改动：
  (1) 权限弹窗通道记住待处理请求，宿主挂载后可重放
  (2) 切换会话记录界面时不取消待审批
```

**ultracode**

```
现象：Ultracode 默认要求 xhigh；只支持 max 的模型（如 4.6 系）
进不去，或努力度被降成 high 导致 ultracode 实际不生效。

改动：
  (1) 支持 max 的模型也可进入 ultracode
  (2) xhigh 不可用时优先落到 max（而不是 high）
  (3) 激活检查把 max 也算作有效 ultracode 努力度
```

### 5.4 可选：`usage()` 简介

在标题下增加一行（不扩功能）：

```
四个社区常用 Claude Code 本地补丁的统一管理（中文交互）。
```

## 6. Implementation Surface

| 位置 | 动作 |
|------|------|
| `cc-patch-manager.sh` → `patch_name` | 替换 4 个 case 分支字符串 |
| `cc-patch-manager.sh` → `patch_note` | 替换 4 个 case 分支字符串 |
| `cc-patch-manager.sh` → `patch_purpose` | 替换 4 个 heredoc 正文 |
| `cc-patch-manager.sh` → `usage` | 可选半行简介 |
| 其它文件 | **不改** |

## 7. Acceptance Criteria

1. `patch_name` / `patch_note` / `patch_purpose` 与 §5 字符串一致（允许 heredoc 换行排版微调，语义不变）
2. 主列表四行名称/说明在常见 80 列终端下可读、说明不主动折成多行逻辑行
3. 详情页无 `fail-open`、无 acorn/AST/内部函数名
4. 保留 `CLAUDE_CLASSIFIER_MODEL`、`~/.claude/keybindings.json`、Escape/Ctrl+C 用户操作信息
5. `bash -n cc-patch-manager.sh` 通过；交互菜单/详情仅文案变化，键位与状态逻辑不变
6. 不修改任何 `apply-*.sh`

## 8. Out-of-band notes (for implementer)

- 原帖映射备忘（勿写进 UI）：
  - transcript = 主帖核心 bug（dialog channel 重构）
  - auto-mode = 副产物（模型门禁 + `CLAUDE_CLASSIFIER_MODEL`）
  - ultracode = 副产物（4.6 上捣鼓）
  - keybindings = 旧货（Ctrl+C 行为回滚 + 自定义快捷键开关）
- 文案风格已定：**混合**（名能力 / 注现象 / 详现象+改动）
- 详情深度已定：**A**（现象 + 改动点，无使用长教程）
