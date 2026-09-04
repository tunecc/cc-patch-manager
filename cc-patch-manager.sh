#!/usr/bin/env bash
# Claude Code 补丁管理器 — 统一交互式补丁 TUI（中文界面）
# Spec: docs/superpowers/specs/2026-07-11-cc-patch-manager-design.md
set -euo pipefail

VERSION="1.0.0"
ACORN_PATH="/tmp/acorn-claude-fix.js"
ACORN_URL="https://unpkg.com/acorn@8.16.0/dist/acorn.js"

# ---------- colors (degrade if not a tty) ----------
if [[ -t 1 ]] && command -v tput >/dev/null 2>&1; then
  RED=$(tput setaf 1 2>/dev/null || printf '\033[0;31m')
  GREEN=$(tput setaf 2 2>/dev/null || printf '\033[0;32m')
  YELLOW=$(tput setaf 3 2>/dev/null || printf '\033[1;33m')
  BLUE=$(tput setaf 4 2>/dev/null || printf '\033[0;34m')
  BOLD=$(tput bold 2>/dev/null || printf '\033[1m')
  DIM=$(tput dim 2>/dev/null || printf '\033[2m')
  NC=$(tput sgr0 2>/dev/null || printf '\033[0m')
else
  RED=""; GREEN=""; YELLOW=""; BLUE=""; BOLD=""; DIM=""; NC=""
fi

success() { printf '%s[完成]%s %s\n' "$GREEN" "$NC" "$*"; }
warning() { printf '%s[注意]%s %s\n' "$YELLOW" "$NC" "$*"; }
error()   { printf '%s[错误]%s %s\n' "$RED" "$NC" "$*" >&2; }
info()    { printf '%s[信息]%s %s\n' "$BLUE" "$NC" "$*"; }

# ---------- registry (order fixed) ----------
PATCH_IDS=(auto-mode keybindings transcript-dialog ultracode voice-mode context-limit computer-use)

patch_name() {
  case "$1" in
    auto-mode) echo "自动模式解锁" ;;
    keybindings) echo "Ctrl+C 回滚" ;;
    transcript-dialog) echo "权限弹窗重放" ;;
    ultracode) echo "Ultracode 解锁" ;;
    voice-mode) echo "语音模式解锁" ;;
    context-limit) echo "上下文上限配置" ;;
    computer-use) echo "Computer Use 解锁" ;;
    *) echo "$1" ;;
  esac
}

patch_note() {
  case "$1" in
    auto-mode) echo "放开 Auto 模型门禁；分类器可自定义；不可用时改询问" ;;
    keybindings) echo "2.1 起 Ctrl+C 直接打断 Agent；打回旧退出习惯" ;;
    transcript-dialog) echo "Ctrl+O 看会话时审批卡 Waiting… / 被中断" ;;
    ultracode) echo "在只支持 max、不支持 xhigh 的模型上启用" ;;
    voice-mode) echo "解锁 VoiceMode，语音识别改用本地 Cometix ASR" ;;
    context-limit) echo "通过 CLAUDE_CODE_CONTEXT_LIMIT 覆盖默认 200K 上限" ;;
    computer-use) echo "通过设置或环境变量启用 Computer Use MCP，默认关闭" ;;
    *) echo "" ;;
  esac
}

patch_suffix() {
  case "$1" in
    auto-mode) echo "backup-automode-model" ;;
    keybindings) echo "backup-keybindings-enable" ;;
    transcript-dialog) echo "backup-transcript-dialog-replay" ;;
    ultracode) echo "backup-ultracode" ;;
    voice-mode) echo "backup-cometix-asr" ;;
    context-limit) echo "backup-ctxlimit" ;;
    computer-use) echo "backup-computer-use" ;;
    *) echo "backup" ;;
  esac
}

patch_purpose() {
  case "$1" in
    auto-mode)
      cat <<'EOF'
现象：部分模型进不了 Auto Mode；分类器常跟主对话同一模型（贵且易 429）；
分类器暂时不可用时官方会直接拒绝工具，对话容易卡住。

改动：
  (1) 放开 Auto 的模型资格检查（不限官方默认名单）
  (2) 分类器暂时不可用时改为询问，而不是直接拒绝
  (3) 支持环境变量 CLAUDE_CLASSIFIER_MODEL 自定义分类模型
     （可设 Haiku 等；也支持 settings.json / --settings 的 env）
EOF
      ;;
    keybindings)
      cat <<'EOF'
现象：2.1.x 起 Ctrl+C 默认直接打断 Agent；旧版是执行中先 tip、再按一次
才退出，习惯旧行为的人改不回来。自定义快捷键也被功能开关关掉。

改动：
  (1) 默认 Ctrl+C 改回退出程序；中断 Agent 仍用 Escape
  (2) 强制开启自定义快捷键（~/.claude/keybindings.json）
EOF
      ;;
    transcript-dialog)
      cat <<'EOF'
现象：从约 2.1.140+ 起，在 Ctrl+O 会话记录视图时若触发权限审批，
会一直 Waiting…；反过来在审批将出时切视图，也可能直接中断对话。

改动：
  (1) 权限弹窗通道记住待处理请求，宿主挂载后可重放
  (2) 切换会话记录界面时不取消待审批
EOF
      ;;
    ultracode)
      cat <<'EOF'
现象：Ultracode 默认要求 xhigh；只支持 max 的模型（如 4.6 系）
进不去，或努力度被降成 high 导致 ultracode 实际不生效。

改动：
  (1) 支持 max 的模型也可进入 ultracode
  (2) xhigh 不可用时优先落到 max（而不是 high）
  (3) 激活检查把 max 也算作有效 ultracode 努力度
EOF
      ;;
    voice-mode)
      cat <<'EOF'
现象：VoiceMode 原本受 Claude.ai 登录与订阅门槛限制；部分环境没有入口，
且官方流式语音识别依赖远端服务。

改动：
  (1) 解锁 VoiceMode 的入口、可用性与设置项
  (2) 流式语音识别改用本地 Cometix ASR

限制：仅支持 macOS Apple Silicon（Darwin/arm64）。应用后请重启 Claude Code。
EOF
      ;;
    context-limit)
      cat <<'EOF'
现象：Claude Code 在多处把上下文窗口上限固定为 200000，无法通过设置覆盖。

改动：
  (1) 支持环境变量 CLAUDE_CODE_CONTEXT_LIMIT 覆盖客户端限制
  (2) settings.json / --settings 中的 env 加载后会重新应用该值
  (3) 未设置或设置为 0 时默认仍为 200000

限制：这是客户端补丁，服务端可能拒绝过大的值；更大上下文也会增加费用、延迟和内存占用。
EOF
      ;;
    computer-use)
      cat <<'EOF'
现象：Computer Use MCP 默认受订阅与服务端功能开关限制，无法只通过本地
settings.json 决定是否启用，也不能覆盖鼠标动画等子配置。

改动：
  (1) 支持 settings.json 中的 computerUseEnabled 开关
  (2) 支持 CLAUDE_CODE_COMPUTER_USE=1 环境变量强制启用
  (3) 支持 computerUseConfig 覆盖鼠标动画、动作前隐藏、剪贴板保护和坐标模式

限制：补丁默认关闭；启用后仍需要 macOS 辅助功能和屏幕录制权限。
EOF
      ;;
  esac
}

# In-memory status: applied | idle | error | unknown
declare -A STATUS=()
declare -A MSG=()

# Globals set by last run_node_patch / parse_and_set_status
LAST_OUTPUT=""
LAST_BACKUP=""
# 目标包身份（inspect / check / apply 输出的 TARGET_* 标记）
TARGET_PACKAGE=""
TARGET_VERSION=""
TARGET_LAYOUT=""
TARGET_IDENTITY_LOADED=""

# 机器协议的 JSON 字符串字段值（路径等）剥引号后用于展示
protocol_json_value() {
  local value="$1"
  if [[ "$value" == \"*\" && "${#value}" -ge 2 ]]; then
    value="${value#\"}"
    value="${value%\"}"
  fi
  printf '%s' "$value"
}

usage() {
  cat <<EOF
Claude Code 补丁管理器 v${VERSION}
七个社区常用 Claude Code 本地补丁的统一管理（中文交互）。

用法:
  $(basename "$0")                  进入交互菜单
  $(basename "$0") /path/to/cli.js  指定目标后进入菜单
  $(basename "$0") --check          打印七个补丁状态后退出
  $(basename "$0") --help           显示本帮助

环境变量:
  CLAUDE_CLI_PATH   若文件存在则优先作为 cli.js 路径
EOF
}

# ---------- target resolution ----------
find_cli_js() {
  local locations=(
    "$HOME/.claude/local/node_modules/@anthropic-ai/claude-code/cli.js"
    "$HOME/.claude/local/node_modules/@cometix/claude-code/cli.js"
    "$HOME/.claude/local/node_modules/@cometix/anthropic-cc/cli.js"
  )
  if command -v npm >/dev/null 2>&1; then
    local npm_root
    npm_root=$(npm root -g 2>/dev/null || true)
    if [[ -n "${npm_root:-}" ]]; then
      locations+=(
        "$npm_root/@anthropic-ai/claude-code/cli.js"
        "$npm_root/@cometix/claude-code/cli.js"
        "$npm_root/@cometix/anthropic-cc/cli.js"
      )
    fi
  fi
  locations+=(
    "/usr/local/lib/node_modules/@anthropic-ai/claude-code/cli.js"
    "/usr/local/lib/node_modules/@cometix/claude-code/cli.js"
    "/usr/local/lib/node_modules/@cometix/anthropic-cc/cli.js"
    "/usr/lib/node_modules/@anthropic-ai/claude-code/cli.js"
    "/usr/lib/node_modules/@cometix/claude-code/cli.js"
    "/usr/lib/node_modules/@cometix/anthropic-cc/cli.js"
  )
  local p
  for p in "${locations[@]}"; do
    if [[ -f "$p" ]]; then
      printf '%s\n' "$p"
      return 0
    fi
  done
  return 1
}

CLI_PATH=""

resolve_target() {
  local arg="${1:-}"
  if [[ -n "$arg" ]]; then
    if [[ -f "$arg" ]]; then
      CLI_PATH="$arg"
      TARGET_IDENTITY_LOADED=""
      return 0
    fi
    error "指定文件不存在: $arg"
    CLI_PATH=""
    TARGET_IDENTITY_LOADED=""
    return 1
  fi
  if [[ -n "${CLAUDE_CLI_PATH:-}" && -f "$CLAUDE_CLI_PATH" ]]; then
    CLI_PATH="$CLAUDE_CLI_PATH"
    TARGET_IDENTITY_LOADED=""
    return 0
  fi
  if CLI_PATH=$(find_cli_js); then
    TARGET_IDENTITY_LOADED=""
    return 0
  fi
  CLI_PATH=""
  TARGET_IDENTITY_LOADED=""
  return 1
}

require_target_readable() {
  [[ -n "$CLI_PATH" && -f "$CLI_PATH" && -r "$CLI_PATH" ]]
}

require_target_writable() {
  require_target_readable || return 1
  [[ -w "$CLI_PATH" && -w "$(dirname "$CLI_PATH")" ]]
}

voice_mode_supported() {
  [[ "$(uname -s)" == "Darwin" && "$(uname -m)" == "arm64" ]]
}

voice_mode_platform_error() {
  STATUS[voice-mode]=error
  MSG[voice-mode]="当前平台不支持（仅支持 macOS Apple Silicon）"
}

voice_mode_source_dir() {
  printf '%s/original-scripts/claude-code-enable-voice-mode-darwin-arm64/cometix-asr\n' \
    "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
}

voice_mode_assets_ready() {
  local source="${1:-$(voice_mode_source_dir)}"
  [[ -f "$source/index.js" && -f "$source/index.d.ts" && -f "$source/package.json" &&
    -f "$source/libcometix-asr.darwin-arm64.node" ]]
}

voice_mode_assets_error() {
  STATUS[voice-mode]=error
  MSG[voice-mode]="缺少 VoiceMode 资源（需要 cometix-asr/index.js 和 libcometix-asr*.node）"
}

install_voice_mode_vendor() {
  local source vendor native
  source=$(voice_mode_source_dir)
  vendor="$(dirname "$CLI_PATH")/vendor/cometix-asr"
  if ! voice_mode_assets_ready "$source"; then
    voice_mode_assets_error
    return 1
  fi
  if ! mkdir -p "$vendor" || ! rm -f "$vendor"/*.node; then
    STATUS[voice-mode]=error
    MSG[voice-mode]="无法创建或清理 Cometix ASR 目录"
    return 1
  fi
  for native in "$source"/libcometix-asr*.node; do
    if ! cp -f "$native" "$vendor/"; then
      STATUS[voice-mode]=error
      MSG[voice-mode]="复制 Cometix ASR 原生模块失败"
      return 1
    fi
  done
  if ! cp -f "$source/index.js" "$vendor/index.js"; then
    STATUS[voice-mode]=error
    MSG[voice-mode]="复制 Cometix ASR 加载器失败"
    return 1
  fi
  [[ -f "$source/index.d.ts" ]] && cp -f "$source/index.d.ts" "$vendor/"
  [[ -f "$source/package.json" ]] && cp -f "$source/package.json" "$vendor/"
  if ! node -e 'const m=require(process.argv[1]);if(typeof m.startSession!=="function")process.exit(2)' "$vendor/index.js"; then
    STATUS[voice-mode]=error
    MSG[voice-mode]="Cometix ASR 模块加载失败"
    return 1
  fi
}

# ---------- acorn + restore ----------
ensure_node() {
  if ! command -v node >/dev/null 2>&1; then
    error "未找到 node — 请安装 Node.js 后再检测/应用补丁"
    return 1
  fi
  return 0
}

ensure_acorn() {
  if [[ -f "$ACORN_PATH" ]]; then
    return 0
  fi
  if ! command -v curl >/dev/null 2>&1; then
    error "未找到 curl，且 acorn 缓存不存在: $ACORN_PATH"
    return 1
  fi
  info "正在下载 acorn 解析器..."
  if ! curl -fsSL "$ACORN_URL" -o "$ACORN_PATH"; then
    error "下载 acorn 解析器失败"
    rm -f "$ACORN_PATH"
    return 1
  fi
  return 0
}

# ============================================================
# 备份策略：备份文件只存一份（cli.js.cc-patch-baseline）
#
# 思路：
#   - 主菜单 [b] 可随时把「当前 cli.js」备份到固定路径
#   - 第一次 apply 改写前，若尚无备份，也会自动复制一份
#   - 之后每次 apply 不再按补丁另存时间戳备份（避免「谁是谁」）
#   - 还原某个补丁 = 从备份还原 + 重打「除该补丁外」原先已应用的其它补丁
#   - 覆盖备份会更新还原点（需确认 yes）
# ============================================================
baseline_path() {
  printf '%s.cc-patch-baseline\n' "$CLI_PATH"
}

has_baseline() {
  [[ -n "${CLI_PATH:-}" && -f "$(baseline_path)" ]]
}

# 若无备份则创建；已有则跳过。返回 0=就绪，1=失败
ensure_baseline() {
  local bp
  if ! require_target_writable; then
    error "目标不可写，无法创建备份: ${CLI_PATH:-无}"
    return 1
  fi
  bp=$(baseline_path)
  if [[ -f "$bp" ]]; then
    info "已有备份，跳过: $(basename "$bp")"
    LAST_BACKUP="$bp"
    return 0
  fi
  cp "$CLI_PATH" "$bp"
  success "已创建备份: $bp"
  LAST_BACKUP="$bp"
  return 0
}

# 用户主动备份当前 cli.js → cli.js.cc-patch-baseline
# 已有备份时需确认覆盖（会丢掉旧还原点）
backup_current_cli() {
  local bp ans n_applied
  if ! require_target_writable; then
    error "目标不存在或不可写: ${CLI_PATH:-无}"
    return 1
  fi
  bp=$(baseline_path)
  printf '\n即将【备份当前文件】\n'
  printf '源:  %s\n' "$CLI_PATH"
  printf '到:  %s\n' "$bp"
  if [[ -f "$bp" ]]; then
    warning "已存在备份，继续将覆盖该文件"
    n_applied=$(count_applied)
    if [[ "$n_applied" -gt 0 ]]; then
      warning "当前已有 $n_applied 个补丁显示为已应用 — 覆盖后还原点会变成「带补丁的当前文件」"
    fi
    printf '确认覆盖？请输入 %syes%s 继续: ' "$BOLD" "$NC"
    read -r ans || true
    if [[ "$ans" != "yes" ]]; then
      info "已取消"
      return 0
    fi
  else
    printf '确认执行？ [Y/n] '
    read -r ans || true
    if [[ -n "$ans" && "$ans" != "y" && "$ans" != "Y" ]]; then
      info "已取消"
      return 0
    fi
  fi
  if ! cp "$CLI_PATH" "$bp"; then
    error "备份失败: $bp"
    return 1
  fi
  LAST_BACKUP="$bp"
  success "已备份当前文件 → $(basename "$bp")"
  return 0
}

# 整文件回到备份
restore_baseline() {
  local bp
  if ! require_target_writable; then
    error "目标不可写: ${CLI_PATH:-无}"
    return 1
  fi
  bp=$(baseline_path)
  if [[ ! -f "$bp" ]]; then
    error "未找到备份: $bp"
    error "提示: 可在主菜单按 [b] 备份当前 cli.js，或先成功应用一次补丁（会自动建备份）。"
    return 1
  fi
  cp "$bp" "$CLI_PATH"
  success "已从备份还原: $bp"
  return 0
}

# 还原单个补丁：从备份还原后重打其它已应用补丁（保持「一份备份」模型）
restore_patch() {
  local id="$1" other kept=() x output ec=0
  if [[ "$id" == "voice-mode" || ( ( "$id" == "context-limit" || "$id" == "computer-use" ) &&
      -f "$(dirname "$CLI_PATH")/.cc-patch-manager-baseline/manifest.json" ) ]]; then
    if ! require_target_readable || ! ensure_node || ! ensure_acorn; then
      error "补丁目标或 Node/acorn 不可用"
      return 1
    fi
    set +e
    output=$(runtime_exec restore "$CLI_PATH" "$id" 2>&1)
    ec=$?
    set -e
    LAST_OUTPUT="$output"
    if [[ "$ec" -ne 0 ]]; then
      STATUS[$id]=error
      MSG[$id]="VoiceMode 还原失败"
      error "$MSG[$id]: $output"
      return 1
    fi
    STATUS[$id]=idle
    MSG[$id]="已还原"
    return 0
  fi
  if ! has_baseline; then
    # 兼容旧版按 suffix 的时间戳备份
    local suffix dir latest
    suffix=$(patch_suffix "$id")
    dir=$(dirname "$CLI_PATH")
    # shellcheck disable=SC2012
    latest=$(ls -t "$dir"/cli.js."${suffix}"-* 2>/dev/null | head -1 || true)
    if [[ -n "${latest:-}" ]]; then
      warning "无备份文件，回退使用旧式备份: $latest"
      cp "$latest" "$CLI_PATH"
      success "已从旧备份还原: $latest"
      return 0
    fi
    error "未找到备份，也无该补丁旧备份 (cli.js.$(patch_suffix "$id")-*)"
    return 1
  fi

  mapfile -t kept < <(applied_ids)
  info "还原「$(patch_name "$id")」= 从备份还原后重打其它补丁..."
  restore_baseline || return 1

  for x in "${kept[@]}"; do
    [[ -n "$x" && "$x" != "$id" ]] || continue
    info "重打: $(patch_name "$x")..."
    if ! run_node_patch "$x" apply; then
      warning "重打失败: $(patch_name "$x") — ${MSG[$x]:-}"
    fi
  done
  return 0
}

# 可选：清理历史 timestamp 备份（旧策略残留），保留基线
prune_legacy_timestamp_backups() {
  local dir f
  [[ -n "${CLI_PATH:-}" ]] || return 0
  dir=$(dirname "$CLI_PATH")
  for f in "$dir"/cli.js.backup-*-20*; do
    [[ -e "$f" ]] || continue
    rm -f "$f"
    info "已清理旧式时间戳备份: $(basename "$f")"
  done
}

# ---------- node runner + status mapping ----------
parse_and_set_status() {
  local id="$1"
  local mode="$2"   # check|apply
  local output="$3"
  local exit_code="$4"

  LAST_BACKUP=""
  MSG[$id]=""
  local line has_already=0 has_needs=0 has_success=0 has_err=0 err_msg="" structured=0 scope_kind="" scope_files=""
  local stage_cn
  case "$mode" in
    apply) stage_cn="应用" ;;
    *)     stage_cn="检测" ;;
  esac

  while IFS= read -r line || [[ -n "$line" ]]; do
    case "$line" in
      ALREADY_PATCHED)
        has_already=1
        MSG[$id]="已打补丁"
        ;;
      NEEDS_PATCH)
        has_needs=1
        MSG[$id]="需要打补丁"
        ;;
      PATCH_COUNT:*)
        has_needs=1
        MSG[$id]="需修补 ${line#PATCH_COUNT:} 处"
        ;;
      SUCCESS:*)
        has_success=1
        MSG[$id]="已修补 ${line#SUCCESS:} 处"
        ;;
      PATCHED:*)
        has_success=1
        MSG[$id]="已应用事务补丁"
        ;;
      BACKUP:*)
        LAST_BACKUP="${line#BACKUP:}"
        ;;
      BASELINE_CREATED:*)
        LAST_BACKUP="${line#BASELINE_CREATED:}"
        info "已创建备份: $LAST_BACKUP"
        ;;
      TARGET_PACKAGE:*)
        TARGET_PACKAGE="${line#TARGET_PACKAGE:}"
        ;;
      TARGET_VERSION:*)
        TARGET_VERSION="${line#TARGET_VERSION:}"
        ;;
      TARGET_LAYOUT:*)
        TARGET_LAYOUT="${line#TARGET_LAYOUT:}"
        ;;
      MISSING_TARGET:*)
        has_err=1
        structured=1
        scope_kind="范围"
        err_msg="${id} ${stage_cn}: 缺失目标: ${line#MISSING_TARGET:}"
        ;;
      CANDIDATE_FILE:*)
        scope_files="${scope_files}${scope_files:+、}$(protocol_json_value "${line#CANDIDATE_FILE:}" </dev/null)"
        ;;
      AMBIGUOUS_TARGET:*)
        has_err=1
        structured=1
        scope_kind="候选"
        err_msg="${id} ${stage_cn}: 目标歧义: ${line#AMBIGUOUS_TARGET:}"
        ;;
      AMBIGUOUS_FILE:*)
        scope_files="${scope_files}${scope_files:+、}$(protocol_json_value "${line#AMBIGUOUS_FILE:}" </dev/null)"
        ;;
      PARSE_ERROR:*)
        has_err=1
        err_msg="解析错误: ${line#PARSE_ERROR:}"
        ;;
      NOT_FOUND:*)
        has_err=1
        err_msg="未找到: ${line#NOT_FOUND:}"
        ;;
      VERIFY_FAILED:*)
        has_err=1
        err_msg="校验失败: ${line#VERIFY_FAILED:}"
        ;;
      TARGET_ERROR:*)
        has_err=1
        if [[ $structured -eq 0 ]]; then
          err_msg="统一补丁失败: ${line#TARGET_ERROR:}"
        fi
        ;;
      FOUND:*|PATCH:*|STEP:*|VERSION:*|OQQ_NAME:*)
        # informational; keep last interesting in MSG if empty later
        ;;
    esac
  done <<< "$output"

  if [[ $has_err -eq 1 ]]; then
    STATUS[$id]=error
    # 结构化诊断（缺失/歧义目标）携带补丁 ID、阶段与候选文件，优先于通用 TARGET_ERROR
    if [[ -n "$scope_files" ]]; then
      [[ -n "$scope_kind" ]] || scope_kind="候选"
      err_msg="${err_msg}（${scope_kind}: ${scope_files}）"
    fi
    MSG[$id]="$err_msg"
    return 1
  fi

  if [[ "$mode" == "check" ]]; then
    if [[ $has_already -eq 1 ]]; then
      STATUS[$id]=applied
      return 0
    fi
    if [[ $has_needs -eq 1 ]]; then
      STATUS[$id]=idle
      return 0
    fi
    # some engines exit 0 with only FOUND already lines
    if [[ $has_already -eq 0 && $has_needs -eq 0 && $exit_code -eq 2 ]]; then
      STATUS[$id]=applied
      MSG[$id]="已打补丁"
      return 0
    fi
    STATUS[$id]=error
    MSG[$id]="无法解析检测输出 (exit $exit_code)"
    return 1
  fi

  # apply mode
  if [[ $has_success -eq 1 ]]; then
    STATUS[$id]=applied
    return 0
  fi
  if [[ $has_already -eq 1 ]]; then
    STATUS[$id]=applied
    MSG[$id]="已打补丁"
    return 0
  fi
  STATUS[$id]=error
  MSG[$id]="${MSG[$id]:-应用失败 (exit $exit_code)}"
  return 1
}

# 惰性加载目标包身份：成功后缓存（缓存命中返回 0 即身份可用），失败不缓存以便重试；
# 换路径由调用方重置 TARGET_IDENTITY_LOADED，全量刷新由 refresh_all 重置。
load_target_identity() {
  local output ec=0 line
  [[ -n "$CLI_PATH" ]] || return 1
  [[ -z "${TARGET_IDENTITY_LOADED:-}" ]] || return 0
  TARGET_PACKAGE="" TARGET_VERSION="" TARGET_LAYOUT=""
  set +e
  output=$(runtime_exec inspect "$CLI_PATH" 2>&1)
  ec=$?
  set -e
  if [[ "$ec" -ne 0 ]]; then
    return 1
  fi
  while IFS= read -r line || [[ -n "$line" ]]; do
    case "$line" in
      TARGET_PACKAGE:*) TARGET_PACKAGE="${line#TARGET_PACKAGE:}" ;;
      TARGET_VERSION:*) TARGET_VERSION="${line#TARGET_VERSION:}" ;;
      TARGET_LAYOUT:*) TARGET_LAYOUT="${line#TARGET_LAYOUT:}" ;;
    esac
  done <<< "$output"
  TARGET_IDENTITY_LOADED=1
  return 0
}

# Unified runtime. Later tasks add scanning, PatchPlan, transactions, and analyzers here.
write_patch_runtime() {
  local tmp
  tmp=$(mktemp)
  cat >"$tmp" <<'RUNTIME_EOF'
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const acorn = require(process.argv[2]);

const command = process.argv[3];
const requestedEntry = process.argv[4];
const runtimeArgs = process.argv.slice(5);
const supportedPackages = new Set(['@cometix/claude-code', '@cometix/anthropic-cc']);
const patchIds = ['auto-mode', 'keybindings', 'transcript-dialog', 'ultracode', 'voice-mode', 'context-limit', 'computer-use'];
const astCache = new Map();
let tracePackageRoot = '';

function fail(message) {
  console.error(`TARGET_ERROR:${JSON.stringify(message)}`);
  process.exit(1);
}

function sha256(value) {
  return crypto.createHash('sha256').update(value).digest('hex');
}

function insideRoot(root, candidate) {
  return candidate === root || candidate.startsWith(`${root}${path.sep}`);
}

function findPackageRoot(entryPath) {
  let cursor = path.dirname(entryPath);
  for (;;) {
    const manifest = path.join(cursor, 'package.json');
    if (fs.existsSync(manifest) && fs.statSync(manifest).isFile()) return cursor;
    const parent = path.dirname(cursor);
    if (parent === cursor) fail(`package.json not found above ${entryPath}`);
    cursor = parent;
  }
}

function parseProgram(file, sourceType) {
  const text = fs.readFileSync(file, 'utf8');
  const cacheKey = `${file}:${sourceType}:${sha256(text)}`;
  if (astCache.has(cacheKey)) return astCache.get(cacheKey);
  try {
    const record = {text, ast: acorn.parse(text, {ecmaVersion: 'latest', sourceType, allowHashBang: true})};
    astCache.set(cacheKey, record);
    if (process.env.CC_PATCH_TRACE_PARSE === '1') {
      const display = tracePackageRoot && insideRoot(tracePackageRoot, file) ? path.relative(tracePackageRoot, file) : file;
      console.log(`PARSE_FILE:${JSON.stringify(display)}:${sourceType}`);
    }
    return record;
  } catch (error) {
    fail(`cannot parse ${file} as ${sourceType}: ${error.message}`);
  }
}

function relativeSpecifiers(ast) {
  const values = [];
  for (const node of ast.body) {
    const isImport = node.type === 'ImportDeclaration';
    const isExport = node.type === 'ExportNamedDeclaration' || node.type === 'ExportAllDeclaration';
    if ((isImport || isExport) && node.source?.value?.startsWith('.')) values.push(node.source.value);
  }
  return values;
}

function resolveRelativeModule(packageRoot, importer, specifier, ignoreNonJavaScript = false) {
  const unresolved = path.resolve(path.dirname(importer), specifier);
  const candidates = [unresolved, `${unresolved}.js`, `${unresolved}.mjs`, path.join(unresolved, 'index.js')];
  const found = candidates.find(candidate => fs.existsSync(candidate) && fs.statSync(candidate).isFile());
  if (!found) fail(`relative module ${specifier} imported by ${importer} does not exist`);
  if (!/\.(?:js|mjs)$/.test(found)) {
    if (ignoreNonJavaScript) return null;
    fail(`relative module is not JavaScript: ${specifier}`);
  }
  const real = fs.realpathSync(found);
  if (!insideRoot(packageRoot, real)) fail(`relative module escapes package root: ${specifier}`);
  return real;
}

function hasCommonJsShape(ast) {
  const stack = [ast];
  while (stack.length) {
    const node = stack.pop();
    if (!node || typeof node !== 'object') continue;
    if (node.type === 'CallExpression' && node.callee?.type === 'Identifier' && node.callee.name === 'require') return true;
    if (node.type === 'MemberExpression' && node.object?.type === 'Identifier' && node.object.name === 'module') return true;
    for (const [key, value] of Object.entries(node)) {
      if (key === 'start' || key === 'end') continue;
      if (Array.isArray(value)) stack.push(...value);
      else if (value && typeof value === 'object') stack.push(value);
    }
  }
  return false;
}

function excludedPackagePath(relativePath) {
  const parts = relativePath.split(path.sep);
  return parts.includes('node_modules') || parts.includes('vendor') ||
    parts.includes('.cc-patch-manager-baseline') ||
    parts.some(part => part.startsWith('.cc-patch-manager-baseline.stage-')) ||
    parts.some(part => part.startsWith('.cc-patch-manager-transaction') || part.startsWith('.cc-patch-manager-tx'));
}

function packageModulePaths(packageRoot) {
  const paths = [];
  const visit = directory => {
    for (const entry of fs.readdirSync(directory, {withFileTypes: true})) {
      const absolute = path.join(directory, entry.name);
      const relative = path.relative(packageRoot, absolute);
      if (excludedPackagePath(relative)) continue;
      if (entry.isDirectory()) visit(absolute);
      else if (entry.isFile() && /\.(?:js|mjs)$/.test(entry.name)) paths.push(relative);
    }
  };
  visit(packageRoot);
  return paths.sort();
}

function packageFile(packageRoot, relativePath) {
  const absolute = path.resolve(packageRoot, relativePath);
  if (!insideRoot(packageRoot, absolute)) fail(`module path escapes package root: ${relativePath}`);
  if (relativePath.split(/[\\/]/).includes('node_modules')) fail(`node_modules is not indexable: ${relativePath}`);
  if (!fs.existsSync(absolute) || !fs.statSync(absolute).isFile()) fail(`module does not exist: ${relativePath}`);
  const real = fs.realpathSync(absolute);
  if (!insideRoot(packageRoot, real)) fail(`module symlink escapes package root: ${relativePath}`);
  return real;
}

function declaredNames(declaration) {
  if (!declaration) return [];
  if (declaration.id?.name) return [declaration.id.name];
  if (declaration.type === 'VariableDeclaration') {
    return declaration.declarations.map(item => item.id?.name).filter(Boolean);
  }
  return [];
}

class ModuleIndex {
  constructor(target) {
    this.target = target;
    this.records = new Map();
  }

  load(file) {
    file = fs.realpathSync(file);
    if (this.records.has(file)) return this.records.get(file);
    const {ast} = parseProgram(file, 'module');
    const record = {locals: new Map(), exports: new Map(), exportAll: [], externalExportAll: []};
    this.records.set(file, record);
    const addExport = (name, binding) => {
      const bindings = record.exports.get(name) || [];
      bindings.push(binding);
      record.exports.set(name, bindings);
    };

    for (const node of ast.body) {
      if (node.type === 'ImportDeclaration') {
        if (!node.source.value.startsWith('.')) {
          for (const specifier of node.specifiers) {
            record.locals.set(specifier.local.name, {kind: 'external', specifier: node.source.value});
          }
          continue;
        }
        const sourceFile = resolveRelativeModule(this.target.packageRoot, file, node.source.value);
        for (const specifier of node.specifiers) {
          const exportedName = specifier.type === 'ImportDefaultSpecifier' ? 'default' : specifier.imported?.name;
          if (!exportedName) throw new Error(`unsupported namespace import in ${file}`);
          record.locals.set(specifier.local.name, {kind: 'import', sourceFile, exportedName});
        }
        continue;
      }

      if (node.type === 'VariableDeclaration' || node.type === 'FunctionDeclaration' || node.type === 'ClassDeclaration') {
        for (const name of declaredNames(node)) record.locals.set(name, {kind: 'local', file, name});
        continue;
      }

      if (node.type === 'ExportNamedDeclaration') {
        for (const name of declaredNames(node.declaration)) {
          record.locals.set(name, {kind: 'local', file, name});
          addExport(name, {kind: 'local-export', localName: name});
        }
        const relativeSource = node.source?.value?.startsWith('.') ? node.source.value : null;
        const sourceFile = relativeSource ? resolveRelativeModule(this.target.packageRoot, file, relativeSource) : null;
        for (const specifier of node.specifiers) {
          const exportedName = specifier.exported.name;
          if (sourceFile) addExport(exportedName, {kind: 'reexport', sourceFile, importedName: specifier.local.name});
          else if (node.source) addExport(exportedName, {kind: 'external-reexport', specifier: node.source.value, importedName: specifier.local.name});
          else addExport(exportedName, {kind: 'local-export', localName: specifier.local.name});
        }
        continue;
      }
      if (node.type === 'ExportAllDeclaration') {
        if (node.source.value.startsWith('.')) {
          record.exportAll.push(resolveRelativeModule(this.target.packageRoot, file, node.source.value));
        } else {
          record.externalExportAll.push(node.source.value);
        }
      }
    }
    return record;
  }

  resolveLocal(file, localName, seen = new Set()) {
    file = fs.realpathSync(file);
    const key = `local:${file}:${localName}`;
    if (seen.has(key)) throw new Error(`cyclic binding: ${localName}`);
    const nextSeen = new Set(seen).add(key);
    const binding = this.load(file).locals.get(localName);
    if (!binding) throw new Error(`missing local binding ${localName} in ${file}`);
    if (binding.kind === 'local') return {file, exportedName: binding.name};
    if (binding.kind === 'external') throw new Error(`external binding unsupported: ${localName} from ${binding.specifier}`);
    return this.resolveExport(binding.sourceFile, binding.exportedName, nextSeen);
  }

  resolveExport(file, exportedName, seen = new Set()) {
    file = fs.realpathSync(file);
    const key = `export:${file}:${exportedName}`;
    if (seen.has(key)) throw new Error(`cyclic re-export: ${exportedName}`);
    const nextSeen = new Set(seen).add(key);
    const record = this.load(file);
    const bindings = record.exports.get(exportedName) || [];
    if (bindings.length === 0 && record.externalExportAll.length > 0) {
      throw new Error(`external export-star unsupported for ${exportedName}: ${record.externalExportAll.join(',')}`);
    }
    if (bindings.length === 0 && exportedName !== 'default' && record.exportAll.length > 0) {
      const candidates = [];
      for (const sourceFile of record.exportAll) {
        try {
          candidates.push(this.resolveExport(sourceFile, exportedName, nextSeen));
        } catch (error) {
          if (!error.message.startsWith('missing export ')) throw error;
        }
      }
      const unique = [...new Map(candidates.map(candidate => [`${candidate.file}:${candidate.exportedName}`, candidate])).values()];
      if (unique.length === 1) return unique[0];
      if (unique.length > 1) throw new Error(`ambiguous export-star ${exportedName} in ${file}: ${unique.length}`);
    }
    if (bindings.length === 0) throw new Error(`missing export ${exportedName} in ${file}`);
    if (bindings.length !== 1) throw new Error(`ambiguous export ${exportedName} in ${file}: ${bindings.length}`);
    const binding = bindings[0];
    if (binding.kind === 'external-reexport') {
      throw new Error(`external re-export unsupported: ${binding.importedName} from ${binding.specifier}`);
    }
    if (binding.kind === 'reexport') return this.resolveExport(binding.sourceFile, binding.importedName, nextSeen);
    return this.resolveLocal(file, binding.localName, nextSeen);
  }
}

function markerGroups(value) {
  if (!value) fail('marker is required');
  try {
    const parsed = JSON.parse(value);
    if (Array.isArray(parsed) && parsed.length > 0 &&
        parsed.every(group => Array.isArray(group) && group.length > 0 &&
          group.every(marker => typeof marker === 'string' && marker.length > 0))) {
      return parsed;
    }
    if (Array.isArray(parsed)) fail('marker groups must be non-empty');
  } catch {}
  return [[value]];
}

function scanMarkerCandidateGroups(target, marker) {
  const groups = markerGroups(marker);
  const sources = packageModulePaths(target.packageRoot).map(relativePath => ({
    relativePath,
    text: fs.readFileSync(path.join(target.packageRoot, relativePath), 'utf8'),
  }));
  return groups.map(group => sources
    .filter(source => group.some(value => source.text.includes(value)))
    .map(source => source.relativePath));
}

function scanMarkerCandidates(target, marker) {
  return [...new Set(scanMarkerCandidateGroups(target, marker).flat())];
}

function tokenMatches(text, token, relativePath, state) {
  const matches = [];
  let offset = 0;
  while ((offset = text.indexOf(token, offset)) !== -1) {
    matches.push({relativePath, start: offset, end: offset + token.length, state});
    offset += token.length;
  }
  return matches;
}

function findAstNodes(node, predicate, results = []) {
  if (!node || typeof node !== 'object') return results;
  if (predicate(node)) results.push(node);
  for (const [key, value] of Object.entries(node)) {
    if (key === 'start' || key === 'end') continue;
    if (Array.isArray(value)) value.forEach(child => findAstNodes(child, predicate, results));
    else if (value && typeof value === 'object') findAstNodes(value, predicate, results);
  }
  return results;
}

function sourceTypeForTarget(target) {
  return target.layout === 'split-esm' ? 'module' : 'script';
}

function candidatePrograms(target, markers) {
  const sourceType = sourceTypeForTarget(target);
  const relativePaths = scanMarkerCandidates(target, JSON.stringify([markers]));
  return relativePaths.map(relativePath => {
    const absolute = packageFile(target.packageRoot, relativePath);
    const parsed = parseProgram(absolute, sourceType);
    return {relativePath, sourceType, ...parsed};
  });
}

function propertyNamed(object, name) {
  return object?.type === 'ObjectExpression' ? object.properties.find(property =>
    property.type === 'Property' && (property.key?.name === name || property.key?.value === name)) : undefined;
}

function memberNamed(node, name) {
  return findAstNodes(node, candidate => candidate.type === 'MemberExpression' &&
    (candidate.property?.name === name || candidate.property?.value === name)).length > 0;
}

function enclosingNode(ast, target, type) {
  const containers = findAstNodes(ast, node => node.type === type && node.start <= target.start && target.end <= node.end);
  return containers.sort((left, right) => (left.end - left.start) - (right.end - right.start))[0] || null;
}

function bindingPatternNames(pattern, names = []) {
  if (!pattern) return names;
  if (pattern.type === 'Identifier') names.push(pattern.name);
  else if (pattern.type === 'RestElement') bindingPatternNames(pattern.argument, names);
  else if (pattern.type === 'AssignmentPattern') bindingPatternNames(pattern.left, names);
  else if (pattern.type === 'ArrayPattern') pattern.elements.forEach(item => bindingPatternNames(item, names));
  else if (pattern.type === 'ObjectPattern') pattern.properties.forEach(property =>
    bindingPatternNames(property.type === 'RestElement' ? property.argument : property.value, names));
  return names;
}

function astPathToNode(root, target, path = []) {
  if (!root || typeof root !== 'object') return null;
  const next = [...path, root];
  if (root === target) return next;
  for (const [key, value] of Object.entries(root)) {
    if (key === 'start' || key === 'end') continue;
    if (Array.isArray(value)) {
      for (const child of value) {
        const found = astPathToNode(child, target, next);
        if (found) return found;
      }
    } else if (value && typeof value === 'object') {
      const found = astPathToNode(value, target, next);
      if (found) return found;
    }
  }
  return null;
}

function declarationBindsName(declaration, name) {
  if (declaration?.type === 'VariableDeclaration') {
    return declaration.declarations.some(item => bindingPatternNames(item.id).includes(name));
  }
  return ['FunctionDeclaration', 'ClassDeclaration'].includes(declaration?.type) && declaration.id?.name === name;
}

function functionVarBindsName(fn, name) {
  const visit = (node, root = false) => {
    if (!node || typeof node !== 'object') return false;
    if (!root && ['FunctionDeclaration', 'FunctionExpression', 'ArrowFunctionExpression'].includes(node.type)) return false;
    if (node.type === 'VariableDeclaration' && node.kind === 'var' && declarationBindsName(node, name)) return true;
    for (const [key, value] of Object.entries(node)) {
      if (key === 'start' || key === 'end') continue;
      if (Array.isArray(value) && value.some(child => visit(child))) return true;
      if (value && typeof value === 'object' && visit(value)) return true;
    }
    return false;
  };
  return visit(fn.body, true);
}

function identifierIsLexicallyShadowed(ast, identifier) {
  if (identifier?.type !== 'Identifier') return true;
  const pathToIdentifier = astPathToNode(ast, identifier);
  if (!pathToIdentifier) return true;
  const name = identifier.name;
  for (const scope of pathToIdentifier) {
    if (['FunctionDeclaration', 'FunctionExpression', 'ArrowFunctionExpression'].includes(scope.type)) {
      if (scope.params.some(param => bindingPatternNames(param).includes(name)) ||
          scope.type === 'FunctionExpression' && scope.id?.name === name || functionVarBindsName(scope, name)) return true;
    }
    if (scope.type === 'CatchClause' && bindingPatternNames(scope.param).includes(name)) return true;
    if (scope.type === 'BlockStatement' && scope.body.some(statement =>
      statement.type === 'VariableDeclaration' && statement.kind !== 'var' && declarationBindsName(statement, name) ||
      ['FunctionDeclaration', 'ClassDeclaration'].includes(statement.type) && declarationBindsName(statement, name))) return true;
    if (['ForStatement', 'ForInStatement', 'ForOfStatement'].includes(scope.type)) {
      const declaration = scope.type === 'ForStatement' ? scope.init : scope.left;
      if (declaration?.type === 'VariableDeclaration' && declaration.kind !== 'var' && declarationBindsName(declaration, name)) return true;
    }
  }
  return false;
}

function booleanReturnCount(node, value) {
  return findAstNodes(node, candidate => candidate.type === 'ReturnStatement' &&
    candidate.argument?.type === 'UnaryExpression' && candidate.argument.operator === '!' &&
    candidate.argument.argument?.type === 'Literal' && candidate.argument.argument.value === (value ? 0 : 1)).length;
}

function replaceNodeSource(container, node, replacement, text) {
  const original = text.slice(container.start, container.end);
  const start = node.start - container.start;
  const end = node.end - container.start;
  return original.slice(0, start) + replacement + original.slice(end);
}

function addPlannedReplacement(files, program, replacement, beforeContainer, afterContainer) {
  if (!files.has(program.relativePath)) {
    files.set(program.relativePath, {
      relativePath: program.relativePath,
      sourceHash: sha256(program.text),
      sourceType: program.sourceType,
      replacements: [],
      postconditions: [],
    });
  }
  const file = files.get(program.relativePath);
  file.replacements.push(replacement);
  file.postconditions.push({
    absent: beforeContainer,
    present: afterContainer,
    semanticId: replacement.semanticId,
  });
}

function finishSemanticPlan(patchId, semanticTargets, files, diagnostics) {
  const transformations = semanticTargets.flatMap(target => target.matches)
    .filter(match => match.attributable !== false)
    .map(match => ({
      semanticId: targetIdForMatch(semanticTargets, match),
      relativePath: match.relativePath,
      start: match.start,
      state: match.state,
      before: match.before,
      after: match.after,
    }));
  return {
    patchId,
    state: semanticTargets.every(target => target.matches.length === 1 && target.matches[0].state === 'after') ?
      'already-patched' : 'needs-patch',
    semanticTargets,
    files: [...files.values()],
    resources: [],
    attribution: {transformations},
    diagnostics,
  };
}

function targetIdForMatch(semanticTargets, match) {
  return semanticTargets.find(target => target.matches.includes(match))?.id || 'unknown';
}

function analyzeAutoMode(target) {
  const files = new Map();
  const modelMatches = [];
  const modelSentinel = '/*CC_AUTO_MODE_MODEL_ELIGIBILITY*/return !0;';
  const modelPrograms = candidatePrograms(target, ['claude-3-', 'CC_AUTO_MODE_MODEL_ELIGIBILITY']);
  for (const program of modelPrograms) {
    const functions = findAstNodes(program.ast, node => node.type === 'FunctionDeclaration' && node.params.length === 1);
    for (const fn of functions) {
      const body = program.text.slice(fn.body.start, fn.body.end);
      if (body.startsWith(`{${modelSentinel}`)) {
        const before = `{${body.slice(1 + modelSentinel.length)}`;
        modelMatches.push({relativePath: program.relativePath, start: fn.body.start, end: fn.body.end,
          state: 'after', before, after: body});
        continue;
      }
      if (fn.end - fn.start > 800 || !body.includes('claude-3-') || !body.includes('firstParty') ||
          (!body.includes('claude-opus-4-') && !body.includes('claude-sonnet-4-')) ||
          booleanReturnCount(fn, false) < 2 || booleanReturnCount(fn, true) !== 1) continue;
      const after = `{${modelSentinel}${body.slice(1)}`;
      const match = {relativePath: program.relativePath, start: fn.body.start, end: fn.body.end,
        state: 'before', before: body, after};
      modelMatches.push(match);
      addPlannedReplacement(files, program,
        {start: fn.body.start, end: fn.body.end, text: after, semanticId: 'model-eligibility'}, body, after);
    }
  }

  const failClosedMatches = [];
  const failOpenSentinel = '/*CC_AUTO_MODE_FAIL_OPEN*/';
  const failPrograms = candidatePrograms(target,
    ['Auto mode classifier unavailable, denying with retry guidance (fail closed)', 'CC_AUTO_MODE_FAIL_OPEN']);
  for (const program of failPrograms) {
    const anchors = findAstNodes(program.ast, node => node.type === 'Literal' && typeof node.value === 'string' &&
      node.value.includes('Auto mode classifier unavailable, denying with retry guidance (fail closed)'));
    for (const anchor of anchors) {
      const returned = enclosingNode(program.ast, anchor, 'ReturnStatement');
      const argument = returned?.argument;
      const decision = argument?.type === 'SequenceExpression' ? argument.expressions.at(-1) : argument;
      const behavior = propertyNamed(decision, 'behavior')?.value;
      if (decision?.type !== 'ObjectExpression' || behavior?.type !== 'Literal' ||
          !['deny', 'ask'].includes(behavior.value)) continue;
      const decisionSource = program.text.slice(decision.start, decision.end);
      if (behavior.value === 'deny') {
        const replacement = `"ask"${failOpenSentinel}`;
        const after = replaceNodeSource(decision, behavior, replacement, program.text);
        failClosedMatches.push({relativePath: program.relativePath, start: decision.start, end: decision.end,
          state: 'before', before: decisionSource, after});
        addPlannedReplacement(files, program,
          {start: behavior.start, end: behavior.end, text: replacement, semanticId: 'classifier-fail-closed'},
          decisionSource, after);
      } else {
        const attributable = decisionSource.includes(failOpenSentinel);
        const before = attributable ? decisionSource.replace(`"ask"${failOpenSentinel}`, '"deny"') : '';
        failClosedMatches.push({relativePath: program.relativePath, start: decision.start, end: decision.end,
          state: 'after', before, after: decisionSource, attributable});
      }
    }
  }

  const classifierMatches = [];
  const classifierGuard = 'if(process.env.CLAUDE_CLASSIFIER_MODEL)return{value:process.env.CLAUDE_CLASSIFIER_MODEL,src:"env"};';
  const classifierPrograms = candidatePrograms(target,
    ['tengu_auto_mode_config', 'modelByMainModel', 'CLAUDE_CLASSIFIER_MODEL']);
  for (const program of classifierPrograms) {
    const functions = findAstNodes(program.ast, node => node.type === 'FunctionDeclaration' && node.params.length === 0 &&
      node.end - node.start < 1000);
    for (const fn of functions) {
      const body = program.text.slice(fn.body.start, fn.body.end);
      const classifierShape = memberNamed(fn, 'model') && (
        (body.includes('tengu_auto_mode_config') && fn.body.body.at(-1)?.type === 'ReturnStatement') ||
        (body.includes('modelByMainModel') && body.includes('src:"default"')));
      if (!classifierShape) continue;
      if (body.startsWith(`{${classifierGuard}`)) {
        const before = `{${body.slice(1 + classifierGuard.length)}`;
        classifierMatches.push({relativePath: program.relativePath, start: fn.body.start, end: fn.body.end,
          state: 'after', before, after: body});
      } else if (!body.includes('process.env.CLAUDE_CLASSIFIER_MODEL')) {
        const after = `{${classifierGuard}${body.slice(1)}`;
        classifierMatches.push({relativePath: program.relativePath, start: fn.body.start, end: fn.body.end,
          state: 'before', before: body, after});
        addPlannedReplacement(files, program,
          {start: fn.body.start, end: fn.body.end, text: after, semanticId: 'classifier-model-source'}, body, after);
      }
    }
  }

  const semanticTargets = [
    {id: 'model-eligibility', expectedCardinality: 1, matches: modelMatches},
    {id: 'classifier-fail-closed', expectedCardinality: 1, matches: failClosedMatches},
    {id: 'classifier-model-source', expectedCardinality: 1, matches: classifierMatches},
  ];
  return finishSemanticPlan('auto-mode', semanticTargets, files, {
    candidateFiles: [...new Set([...modelPrograms, ...failPrograms, ...classifierPrograms].map(item => item.relativePath))],
  });
}

function analyzeKeybindings(target) {
  const files = new Map();
  const flagMatches = [];
  const flagNotOneSentinel = '/*CC_KEYBINDINGS_FLAG_NOT1*/';
  const flagFalseSentinel = '/*CC_KEYBINDINGS_FLAG_FALSE*/';
  const flagPrograms = candidatePrograms(target,
    ['tengu_keybinding_customization_release', 'CC_KEYBINDINGS_FLAG_NOT1', 'CC_KEYBINDINGS_FLAG_FALSE']);
  for (const program of flagPrograms) {
    const calls = findAstNodes(program.ast, node => node.type === 'CallExpression' && node.arguments?.length === 2 &&
      node.arguments[0]?.type === 'Literal' && node.arguments[0].value === 'tengu_keybinding_customization_release');
    for (const call of calls) {
      const value = call.arguments[1];
      const callSource = program.text.slice(call.start, call.end);
      const disabled = value.type === 'Literal' && value.value === false ||
        value.type === 'UnaryExpression' && value.operator === '!' && value.argument?.type === 'Literal' && value.argument.value === 1;
      const enabled = value.type === 'Literal' && value.value === true ||
        value.type === 'UnaryExpression' && value.operator === '!' && value.argument?.type === 'Literal' && value.argument.value === 0;
      if (disabled) {
        const beforeValue = program.text.slice(value.start, value.end);
        const replacement = beforeValue === 'false' ? `true${flagFalseSentinel}` : `!0${flagNotOneSentinel}`;
        const after = replaceNodeSource(call, value, replacement, program.text);
        flagMatches.push({relativePath: program.relativePath, start: call.start, end: call.end,
          state: 'before', before: callSource, after});
        addPlannedReplacement(files, program,
          {start: value.start, end: value.end, text: replacement, semanticId: 'custom-keybindings-enabled'},
          callSource, after);
      } else if (enabled) {
        const fromNotOne = callSource.includes(flagNotOneSentinel);
        const fromFalse = callSource.includes(flagFalseSentinel);
        const attributable = fromNotOne || fromFalse;
        const before = fromNotOne ? callSource.replace(`!0${flagNotOneSentinel}`, '!1') :
          fromFalse ? callSource.replace(`true${flagFalseSentinel}`, 'false') : '';
        flagMatches.push({relativePath: program.relativePath, start: call.start, end: call.end,
          state: 'after', before, after: callSource, attributable});
      }
    }
  }

  const ctrlMatches = [];
  const ctrlSentinel = '/*CC_KEYBINDINGS_CTRL_C*/';
  const ctrlPrograms = candidatePrograms(target, ['"ctrl+c"', 'CC_KEYBINDINGS_CTRL_C']);
  for (const program of ctrlPrograms) {
    const globals = findAstNodes(program.ast, node => node.type === 'ObjectExpression' &&
      propertyNamed(node, 'context')?.value?.type === 'Literal' && propertyNamed(node, 'context').value.value === 'Global');
    for (const global of globals) {
      const bindings = propertyNamed(global, 'bindings')?.value;
      const ctrl = propertyNamed(bindings, 'ctrl+c');
      if (bindings?.type !== 'ObjectExpression' || ctrl?.value?.type !== 'Literal' ||
          !['app:interrupt', 'app:exit'].includes(ctrl.value.value)) continue;
      const globalSource = program.text.slice(global.start, global.end);
      if (ctrl.value.value === 'app:interrupt') {
        const replacement = `"app:exit"${ctrlSentinel}`;
        const after = replaceNodeSource(global, ctrl.value, replacement, program.text);
        ctrlMatches.push({relativePath: program.relativePath, start: global.start, end: global.end,
          state: 'before', before: globalSource, after});
        addPlannedReplacement(files, program,
          {start: ctrl.value.start, end: ctrl.value.end, text: replacement, semanticId: 'ctrl-c-exit-binding'},
          globalSource, after);
      } else {
        const attributable = globalSource.includes(ctrlSentinel);
        const before = attributable ? globalSource.replace(`"app:exit"${ctrlSentinel}`, '"app:interrupt"') : '';
        ctrlMatches.push({relativePath: program.relativePath, start: global.start, end: global.end,
          state: 'after', before, after: globalSource, attributable});
      }
    }
  }

  const semanticTargets = [
    {id: 'custom-keybindings-enabled', expectedCardinality: 1, matches: flagMatches},
    {id: 'ctrl-c-exit-binding', expectedCardinality: 1, matches: ctrlMatches},
  ];
  return finishSemanticPlan('keybindings', semanticTargets, files, {
    candidateFiles: [...new Set([...flagPrograms, ...ctrlPrograms].map(item => item.relativePath))],
  });
}

function reversibleBodyMarker(id, original, modified) {
  return `/*CC_${id}:${Buffer.from(original).toString('base64')}:${sha256(modified)}*/`;
}

function decodeReversibleBody(body, id) {
  const matches = [...body.matchAll(new RegExp(`/\\*CC_${id}:([A-Za-z0-9+/=]+):([a-f0-9]{64})\\*/`, 'g'))];
  if (matches.length !== 1) return null;
  const match = matches[0];
  try {
    const original = Buffer.from(match[1], 'base64').toString('utf8');
    if (Buffer.from(original).toString('base64') !== match[1] || sha256(body.replace(match[0], '')) !== match[2]) return null;
    return original;
  } catch {
    return null;
  }
}

function bodyPatch(files, program, fn, semanticId, markerId, modifiedBody) {
  const before = program.text.slice(fn.body.start, fn.body.end);
  const after = `{${reversibleBodyMarker(markerId, before, modifiedBody)}${modifiedBody.slice(1)}`;
  addPlannedReplacement(files, program,
    {start: fn.body.start, end: fn.body.end, text: after, semanticId}, before, after);
  return {relativePath: program.relativePath, start: fn.body.start, end: fn.body.end,
    state: 'before', before, after};
}

function reconstructedBodyMatch(program, fn, markerId, renderModifiedBody) {
  const after = program.text.slice(fn.body.start, fn.body.end);
  const before = decodeReversibleBody(after, markerId);
  if (before === null) return null;
  const parameters = fn.params.map(param => program.text.slice(param.start, param.end)).join(',');
  const text = `${fn.async ? 'async ' : ''}function __CC_RECONSTRUCT(${parameters})${before}`;
  let ast;
  try {
    ast = acorn.parse(text, {ecmaVersion: 'latest', sourceType: 'script'});
  } catch {
    return null;
  }
  const originalFunction = ast.body[0];
  if (originalFunction?.type !== 'FunctionDeclaration') return null;
  const modified = renderModifiedBody({...program, text, ast}, originalFunction);
  if (typeof modified !== 'string') return null;
  const expected = `{${reversibleBodyMarker(markerId, before, modified)}${modified.slice(1)}`;
  if (after !== expected) return null;
  return {relativePath: program.relativePath, start: fn.body.start, end: fn.body.end,
    state: 'after', before, after};
}

function functionLikeNodes(ast) {
  return findAstNodes(ast, node => ['FunctionDeclaration', 'FunctionExpression', 'ArrowFunctionExpression'].includes(node.type));
}

function propertyFunction(property) {
  return property?.value && ['FunctionExpression', 'ArrowFunctionExpression'].includes(property.value.type) ? property.value : null;
}

function memberCall(node, objectName, propertyName) {
  return node?.type === 'CallExpression' && node.callee?.type === 'MemberExpression' &&
    node.callee.object?.type === 'Identifier' && node.callee.object.name === objectName &&
    (node.callee.property?.name === propertyName || node.callee.property?.value === propertyName);
}

function dialogFactoryShape(program, fn) {
  if (fn.params.length !== 0 || fn.body?.type !== 'BlockStatement') return null;
  if (fn.body.body.length !== 2) return null;
  const [declaration, returned] = fn.body.body;
  if (declaration.type !== 'VariableDeclaration' || ![5, 6].includes(declaration.declarations.length) ||
      !declaration.declarations.every(item => item.id?.type === 'Identifier') ||
      returned.type !== 'ReturnStatement' || returned.argument?.type !== 'ObjectExpression') return null;
  if (!declaration || !returned) return null;
  const declarations = declaration.declarations;
  if (!declarations.slice(0, 3).every(item => item.init?.type === 'CallExpression') ||
      declarations[3].init?.type !== 'NewExpression' || declarations[3].init.callee?.name !== 'Map' ||
      declarations[4].init?.type !== 'Literal' || declarations[4].init.value !== 0) return null;
  const [eventSignal, cancelSignal, updateSignal, pendingMap, counter] = declarations.slice(0, 5).map(item => item.id.name);
  const subscriber = declarations[5]?.init?.type === 'Literal' && declarations[5].init.value === 0 ? declarations[5].id?.name : null;
  if (declarations.length === 6 && !subscriber) return null;
  const properties = new Map(returned.argument.properties.map(property => [property.key?.name || property.key?.value, property]));
  if (returned.argument.properties.length !== 5 || properties.size !== 5 ||
      !['subscribe', 'onCancel', 'onUpdate', 'reply', 'request'].every(name => properties.has(name))) return null;
  if (program.text.slice(properties.get('onCancel').value.start, properties.get('onCancel').value.end) !== `${cancelSignal}.subscribe` ||
      program.text.slice(properties.get('onUpdate').value.start, properties.get('onUpdate').value.end) !== `${updateSignal}.subscribe`) return null;
  const reply = propertyFunction(properties.get('reply'));
  const request = propertyFunction(properties.get('request'));
  if (!reply || !request || request.params.length !== 2 || request.params[1]?.type !== 'Identifier') return null;
  const subscribeProperty = properties.get('subscribe');
  const directSubscribe = program.text.slice(subscribeProperty.value.start, subscribeProperty.value.end) === `${eventSignal}.subscribe`;
  const subscribe = propertyFunction(subscribeProperty);
  if (directSubscribe ? subscriber !== null : !subscribe || !subscriber || subscribe.body?.body?.length !== 3 ||
      findAstNodes(subscribe, node => memberCall(node, eventSignal, 'subscribe')).length !== 1 ||
      findAstNodes(subscribe, node => node.type === 'AssignmentExpression' && node.left?.name === subscriber &&
        node.operator === '+=').length !== 1 ||
      findAstNodes(subscribe, node => node.type === 'AssignmentExpression' && node.left?.name === subscriber &&
        node.operator === '-=').length !== 1) return null;
  if (reply.body?.type !== 'BlockStatement' || reply.body.body.length !== 3 ||
      findAstNodes(reply, node => memberCall(node, pendingMap, 'get')).length !== 1 ||
      findAstNodes(reply, node => memberCall(node, pendingMap, 'delete')).length !== 1) return null;
  if (request.body?.type !== 'BlockStatement' || request.body.body.length !== 6 ||
      request.body.body[0].type !== 'ExpressionStatement' || request.body.body[1].type !== 'VariableDeclaration' ||
      request.body.body[2].type !== 'IfStatement' || request.body.body[3].type !== 'VariableDeclaration' ||
      request.body.body[4].type !== 'IfStatement' || request.body.body[5].type !== 'ReturnStatement' ||
      findAstNodes(request.body.body[0], node => node.type === 'AssignmentExpression' &&
        node.left?.name === counter && node.operator === '+=').length !== 1 ||
      findAstNodes(request.body.body[4], node => memberCall(node, pendingMap, 'set')).length !== 1 ||
      findAstNodes(request.body.body[4], node => memberCall(node, cancelSignal, 'emit')).length !== 1 ||
      findAstNodes(request.body.body[4], node => node.type === 'CallExpression' &&
        (node.callee?.property?.name === 'addEventListener' || node.callee?.property?.value === 'addEventListener')).length !== 1 ||
      findAstNodes(request.body.body[5], node => memberCall(node, eventSignal, 'emit')).length !== 1 ||
      findAstNodes(request.body.body[5], node => memberCall(node, updateSignal, 'emit')).length !== 1) return null;
  const deferred = findAstNodes(request, node => node.type === 'VariableDeclarator' && node.id?.type === 'ObjectPattern' &&
    node.id.properties.some(property => (property.key?.name || property.key?.value) === 'promise') &&
    node.id.properties.some(property => (property.key?.name || property.key?.value) === 'resolve') &&
    node.init?.type === 'CallExpression')[0];
  const idDeclaration = findAstNodes(request, node => node.type === 'VariableDeclarator' && node.id?.type === 'Identifier' &&
    node.init?.type === 'TemplateLiteral' && node.init.quasis?.some(quasi => quasi.value.raw.includes('dialog-')))[0];
  const signalDeclaration = findAstNodes(request, node => node.type === 'VariableDeclarator' && node.id?.type === 'Identifier' &&
    node.init?.type === 'ChainExpression' && memberNamed(node.init, 'signal'))[0] ||
    findAstNodes(request, node => node.type === 'VariableDeclarator' && node.id?.type === 'Identifier' && memberNamed(node.init, 'signal'))[0];
  const emit = findAstNodes(request, node => memberCall(node, eventSignal, 'emit') && node.arguments[0]?.type === 'ObjectExpression')[0];
  if (!deferred || !idDeclaration || !signalDeclaration || !emit) return null;
  const promiseProperty = deferred.id.properties.find(property => (property.key?.name || property.key?.value) === 'promise');
  const resolveProperty = deferred.id.properties.find(property => (property.key?.name || property.key?.value) === 'resolve');
  const promiseName = promiseProperty?.value?.name || promiseProperty?.key?.name;
  const resolveName = resolveProperty?.value?.name || resolveProperty?.key?.name;
  if (!promiseName || !resolveName) return null;
  return {
    declaration, eventSignal, cancelSignal, updateSignal, pendingMap, counter, subscriber,
    factories: declarations.slice(0, 3).map(item => program.text.slice(item.init.start, item.init.end)),
    reply, request, requestParams: request.params.map(param => program.text.slice(param.start, param.end)),
    optionsName: request.params[1].name, idName: idDeclaration.id.name, promiseName, resolveName,
    deferredFactory: program.text.slice(deferred.init.callee.start, deferred.init.callee.end),
    signalName: signalDeclaration.id.name, eventSource: program.text.slice(emit.arguments[0].start, emit.arguments[0].end),
  };
}

function renderDialogFactoryBody(shape) {
  const [eventFactory, cancelFactory, updateFactory] = shape.factories;
  const subscriberDeclaration = shape.subscriber ? `,${shape.subscriber}=0` : '';
  const subscribeAccounting = shape.subscriber ?
    `${shape.subscriber}+=1;let CC_DIALOG_FIX_unsub=${shape.eventSignal}.subscribe(CC_DIALOG_FIX_listener),CC_DIALOG_FIX_closed=!1;` :
    `let CC_DIALOG_FIX_unsub=${shape.eventSignal}.subscribe(CC_DIALOG_FIX_listener);`;
  const unsubscribe = shape.subscriber ?
    `return()=>{if(CC_DIALOG_FIX_closed)return;CC_DIALOG_FIX_closed=!0,${shape.subscriber}-=1,CC_DIALOG_FIX_unsub()}` :
    'return CC_DIALOG_FIX_unsub';
  const [requestInput, requestOptions] = shape.requestParams;
  return `{let ${shape.eventSignal}=${eventFactory},${shape.cancelSignal}=${cancelFactory},${shape.updateSignal}=${updateFactory},${shape.pendingMap}=new Map,${shape.counter}=0${subscriberDeclaration};return{subscribe(CC_DIALOG_FIX_listener){${subscribeAccounting}for(let CC_DIALOG_FIX_entry of ${shape.pendingMap}.values())queueMicrotask(()=>{if(${shape.pendingMap}.has(CC_DIALOG_FIX_entry.id))CC_DIALOG_FIX_listener(CC_DIALOG_FIX_entry.event)});${unsubscribe}},onCancel:${shape.cancelSignal}.subscribe,onUpdate:${shape.updateSignal}.subscribe,reply(CC_DIALOG_FIX_reply){let CC_DIALOG_FIX_entry=${shape.pendingMap}.get(CC_DIALOG_FIX_reply.id);if(!CC_DIALOG_FIX_entry)return;${shape.pendingMap}.delete(CC_DIALOG_FIX_reply.id),CC_DIALOG_FIX_entry.resolve(CC_DIALOG_FIX_reply)},request(${requestInput},${requestOptions}){${shape.counter}+=1;let ${shape.idName}=\`dialog-\${${shape.counter}}\`,{promise:${shape.promiseName},resolve:${shape.resolveName}}=${shape.deferredFactory}(),${shape.signalName}=${shape.optionsName}?.signal;if(${shape.signalName}?.aborted)return queueMicrotask(()=>${shape.resolveName}({id:${shape.idName},cancelled:!0})),{id:${shape.idName},replied:${shape.promiseName},update:()=>{}};let CC_DIALOG_FIX_abort,CC_DIALOG_FIX_event=${shape.eventSource};if(${shape.pendingMap}.set(${shape.idName},{id:${shape.idName},event:CC_DIALOG_FIX_event,resolve:(CC_DIALOG_FIX_value)=>{if(${shape.signalName}&&CC_DIALOG_FIX_abort)${shape.signalName}.removeEventListener("abort",CC_DIALOG_FIX_abort);${shape.resolveName}(CC_DIALOG_FIX_value)}}),${shape.signalName})CC_DIALOG_FIX_abort=()=>{if(${shape.pendingMap}.delete(${shape.idName}))${shape.resolveName}({id:${shape.idName},cancelled:!0}),${shape.cancelSignal}.emit(${shape.idName})},${shape.signalName}.addEventListener("abort",CC_DIALOG_FIX_abort,{once:!0});return ${shape.eventSignal}.emit(CC_DIALOG_FIX_event),{id:${shape.idName},replied:${shape.promiseName},update:(CC_DIALOG_FIX_payload)=>{let CC_DIALOG_FIX_entry=${shape.pendingMap}.get(${shape.idName});if(CC_DIALOG_FIX_entry){CC_DIALOG_FIX_entry.event={...CC_DIALOG_FIX_entry.event,payload:CC_DIALOG_FIX_payload};${shape.updateSignal}.emit({id:${shape.idName},payload:CC_DIALOG_FIX_payload})}}}}}}`;
}

function statementExpressionList(statement) {
  if (statement?.type === 'ExpressionStatement') {
    return statement.expression.type === 'SequenceExpression' ? statement.expression.expressions : [statement.expression];
  }
  if (statement?.type === 'BlockStatement' && statement.body.length === 1) return statementExpressionList(statement.body[0]);
  return [];
}

function renderDialogCleanupBody(program, loop, loopVariable) {
  const expressions = statementExpressionList(loop.body);
  if (expressions.length !== 2) return null;
  const dismiss = expressions.find(expression => memberCall(expression, expression.callee?.object?.name, 'dismiss') &&
    expression.arguments.length === 1 && expression.arguments[0]?.name === loopVariable);
  const reply = expressions.find(expression => memberCall(expression, expression.callee?.object?.name, 'reply') &&
    propertyNamed(expression.arguments[0], 'id')?.value?.name === loopVariable &&
    propertyNamed(expression.arguments[0], 'cancelled')?.value?.type === 'UnaryExpression' &&
    propertyNamed(expression.arguments[0], 'cancelled').value.operator === '!' &&
    propertyNamed(expression.arguments[0], 'cancelled').value.argument?.type === 'Literal' &&
    propertyNamed(expression.arguments[0], 'cancelled').value.argument.value === 0);
  if (!dismiss || !reply || dismiss === reply) return null;
  return `{${program.text.slice(dismiss.start, dismiss.end)};}`;
}

function reconstructedDialogCleanupMatch(program, loop, loopVariable) {
  const after = program.text.slice(loop.body.start, loop.body.end);
  const before = decodeReversibleBody(after, 'DIALOG_FIX_HOST_CLEANUP');
  if (before === null) return null;
  const text = `for(const ${loopVariable} of [])${before}`;
  let ast;
  try {
    ast = acorn.parse(text, {ecmaVersion: 'latest', sourceType: 'script'});
  } catch {
    return null;
  }
  const originalLoop = ast.body[0];
  if (originalLoop?.type !== 'ForOfStatement') return null;
  const modified = renderDialogCleanupBody({...program, text, ast}, originalLoop, loopVariable);
  if (modified === null) return null;
  const expected = `${modified.slice(0, -1)}${reversibleBodyMarker('DIALOG_FIX_HOST_CLEANUP', before, modified)}}`;
  if (after !== expected) return null;
  return {relativePath: program.relativePath, start: loop.body.start, end: loop.body.end,
    state: 'after', before, after};
}

function enclosingFunctionWith(node, functions, predicate) {
  return functions.filter(fn => fn.start <= node.start && node.end <= fn.end && predicate(fn))
    .sort((left, right) => (left.end - left.start) - (right.end - right.start))[0] || null;
}

function analyzeTranscriptDialog(target) {
  const files = new Map();
  const factoryMatches = [];
  const factoryPrograms = candidatePrograms(target, ['dialog-', 'CC_DIALOG_FIX_CHANNEL_FACTORY']);
  for (const program of factoryPrograms) {
    for (const fn of functionLikeNodes(program.ast)) {
      const body = program.text.slice(fn.body.start, fn.body.end);
      const patched = reconstructedBodyMatch(program, fn, 'DIALOG_FIX_CHANNEL_FACTORY',
        (originalProgram, originalFunction) => {
          const shape = dialogFactoryShape(originalProgram, originalFunction);
          return shape ? renderDialogFactoryBody(shape) : null;
        });
      if (patched) {
        factoryMatches.push(patched);
        continue;
      }
      if (body.includes('CC_DIALOG_FIX_CHANNEL_FACTORY:')) continue;
      const shape = dialogFactoryShape(program, fn);
      if (!shape) continue;
      factoryMatches.push(bodyPatch(files, program, fn, 'dialog-channel-factory',
        'DIALOG_FIX_CHANNEL_FACTORY', renderDialogFactoryBody(shape)));
    }
  }

  const cleanupMatches = [];
  const cleanupPrograms = candidatePrograms(target, ['onClosed', 'CC_DIALOG_FIX_HOST_CLEANUP']);
  for (const program of cleanupPrograms) {
    const functions = functionLikeNodes(program.ast);
    const seenLoops = new Set();
    for (const loop of findAstNodes(program.ast, node => node.type === 'ForOfStatement')) {
      if (seenLoops.has(loop.start)) continue;
      const host = enclosingFunctionWith(loop, functions, fn => memberNamed(fn, 'onClosed') && memberNamed(fn, 'subscribe'));
      if (!host) continue;
      const loopBody = program.text.slice(loop.body.start, loop.body.end);
      const loopVariable = loop.left?.type === 'VariableDeclaration' ? loop.left.declarations?.[0]?.id?.name : null;
      if (!loopVariable) continue;
      const patched = reconstructedDialogCleanupMatch(program, loop, loopVariable);
      if (patched) {
        cleanupMatches.push(patched);
        seenLoops.add(loop.start);
        continue;
      }
      if (loopBody.includes('CC_DIALOG_FIX_HOST_CLEANUP:')) {
        seenLoops.add(loop.start);
        continue;
      }
      const modified = renderDialogCleanupBody(program, loop, loopVariable);
      if (modified === null) continue;
      const before = loopBody;
      const after = `${modified.slice(0, -1)}${reversibleBodyMarker('DIALOG_FIX_HOST_CLEANUP', before, modified)}}`;
      cleanupMatches.push({relativePath: program.relativePath, start: loop.body.start, end: loop.body.end,
        state: 'before', before, after});
      addPlannedReplacement(files, program,
        {start: loop.body.start, end: loop.body.end, text: after, semanticId: 'host-cleanup'}, before, after);
      seenLoops.add(loop.start);
    }
  }

  const semanticTargets = [
    {id: 'dialog-channel-factory', expectedCardinality: 1, matches: factoryMatches},
    {id: 'host-cleanup', expectedCardinality: 1, matches: cleanupMatches},
  ];
  return finishSemanticPlan('transcript-dialog', semanticTargets, files, {
    candidateFiles: [...new Set([...factoryPrograms, ...cleanupPrograms].map(item => item.relativePath))],
  });
}

function literalComparison(node, value) {
  if (node?.type !== 'BinaryExpression' || node.operator !== '===') return false;
  return node.left?.type === 'Literal' && node.left.value === value ||
    node.right?.type === 'Literal' && node.right.value === value;
}

function bindingKey(binding) {
  return binding ? `${binding.file}:${binding.exportedName}` : '';
}

function resolvedCallBinding(index, absoluteFile, call) {
  if (call?.type !== 'CallExpression' || call.callee?.type !== 'Identifier') return null;
  try {
    return index.resolveLocal(absoluteFile, call.callee.name);
  } catch {
    return null;
  }
}

function localNameForBinding(index, absoluteFile, binding) {
  const record = index.load(absoluteFile);
  for (const localName of record.locals.keys()) {
    try {
      if (bindingKey(index.resolveLocal(absoluteFile, localName)) === bindingKey(binding)) return localName;
    } catch {}
  }
  return null;
}

function discoverEffortGate(target, index, literal) {
  const programs = candidatePrograms(target, [literal]);
  const matches = [];
  for (const program of programs) {
    const absoluteFile = packageFile(target.packageRoot, program.relativePath);
    for (const fn of findAstNodes(program.ast, node => node.type === 'FunctionDeclaration' && node.id?.name && node.params.length === 1)) {
      const calls = findAstNodes(fn.body, node => node.type === 'CallExpression' &&
        node.arguments?.[1]?.type === 'Literal' && node.arguments[1].value === literal);
      if (calls.length > 0) matches.push({program, fn, binding: index.resolveLocal(absoluteFile, fn.id.name)});
    }
  }
  return {programs, matches};
}

function bindingCallsTarget(index, binding, targetBinding, remainingDepth, seen = new Set()) {
  if (bindingKey(binding) === bindingKey(targetBinding)) return true;
  if (!binding || remainingDepth === 0 || seen.has(bindingKey(binding))) return false;
  const nextSeen = new Set(seen).add(bindingKey(binding));
  let parsed;
  try {
    parsed = parseProgram(binding.file, 'module');
  } catch {
    return false;
  }
  const fn = findAstNodes(parsed.ast, node => node.type === 'FunctionDeclaration' &&
    node.id?.name === binding.exportedName)[0];
  if (!fn) return false;
  return findAstNodes(fn.body, node => node.type === 'CallExpression' && node.callee?.type === 'Identifier')
    .some(call => {
      const called = resolvedCallBinding(index, binding.file, call);
      return called && bindingCallsTarget(index, called, targetBinding, remainingDepth - 1, nextSeen);
    });
}

function renderUltracodeEligibility(program, fn, index, absoluteFile, xhighBinding, maxLocalName) {
  const eligibilityShape = fn.params.length === 1 && fn.body.body?.length === 1 &&
    fn.body.body[0].type === 'ReturnStatement' && findAstNodes(fn.body, node =>
      node.type === 'BinaryExpression' && node.operator === '===' &&
      (node.left?.type === 'UnaryExpression' && node.left.operator === 'void' ||
       node.right?.type === 'UnaryExpression' && node.right.operator === 'void')).length > 0;
  if (!eligibilityShape || !maxLocalName) return null;
  const xhighCalls = findAstNodes(fn.body, node => node.type === 'CallExpression').filter(call =>
    bindingKey(resolvedCallBinding(index, absoluteFile, call)) === bindingKey(xhighBinding));
  if (xhighCalls.length !== 1) return null;
  const call = xhighCalls[0];
  const argumentSource = program.text.slice(call.arguments[0].start, call.arguments[0].end);
  const capabilityBranch = findAstNodes(fn.body, node => node.type === 'LogicalExpression' && node.operator === '&&' &&
    node.start <= call.start && call.end <= node.end &&
    findAstNodes(node, child => child.type === 'Literal' && child.value === 'xhigh').length > 0)
    .sort((left, right) => (left.end - left.start) - (right.end - right.start))[0];
  const supportCall = capabilityBranch && findAstNodes(capabilityBranch, node => node.type === 'CallExpression' &&
    node !== call && node.arguments?.[0]?.type === 'Literal' && node.arguments[0].value === 'xhigh')[0];
  if (!capabilityBranch || !supportCall) return null;
  const branchSource = program.text.slice(capabilityBranch.start, capabilityBranch.end);
  const supportSource = replaceNodeSource(supportCall, supportCall.arguments[0], '"max"', program.text);
  return replaceNodeSource(fn.body, capabilityBranch,
    `(${branchSource}||${maxLocalName}(${argumentSource})&&${supportSource})`, program.text);
}

function renderUltracodeFallbacks(program, fn, index, absoluteFile, xhighBinding, maxLocalName) {
  const fallbackShape = fn.params.length === 2 && findAstNodes(fn.body, node =>
    node.type === 'Literal' && node.value === 'xhigh').length > 0;
  if (!fallbackShape || !maxLocalName) return [];
  const modifiedBodies = [];
  for (const statement of findAstNodes(fn.body, node => node.type === 'IfStatement' &&
    node.test?.type === 'LogicalExpression' && node.test.operator === '&&')) {
    if (!literalComparison(statement.test.left, 'xhigh') || statement.test.right?.type !== 'UnaryExpression' ||
        statement.test.right.operator !== '!' ||
        bindingKey(resolvedCallBinding(index, absoluteFile, statement.test.right.argument)) !== bindingKey(xhighBinding)) continue;
    const consequent = statement.consequent?.type === 'BlockStatement' && statement.consequent.body.length === 1 ?
      statement.consequent.body[0] : statement.consequent;
    const high = consequent?.type === 'ReturnStatement' ? consequent.argument :
      consequent?.type === 'ExpressionStatement' && consequent.expression?.type === 'AssignmentExpression' ?
        consequent.expression.right : null;
    if (high?.type !== 'Literal' || high.value !== 'high') continue;
    const modelArgument = statement.test.right.argument.arguments[0];
    const modelSource = program.text.slice(modelArgument.start, modelArgument.end);
    modifiedBodies.push(replaceNodeSource(fn.body, high, `${maxLocalName}(${modelSource})?"max":"high"`, program.text));
  }
  return modifiedBodies;
}

function renderUltracodeActivation(program, fn, index, absoluteFile, fallbackBindings) {
  if (fn.params.length !== 3 || fn.body.body?.length !== 1 || fn.body.body[0].type !== 'ReturnStatement') return null;
  const comparisons = findAstNodes(fn.body, node => literalComparison(node, 'xhigh') &&
    (node.left?.type === 'CallExpression' || node.right?.type === 'CallExpression'));
  const enabledCheck = findAstNodes(fn.body, node => node.type === 'BinaryExpression' && node.operator === '===' &&
    (node.left?.type === 'UnaryExpression' && node.left.operator === '!' && node.left.argument?.value === 0 ||
     node.right?.type === 'UnaryExpression' && node.right.operator === '!' && node.right.argument?.value === 0));
  if (comparisons.length !== 1 || enabledCheck.length === 0) return null;
  const comparison = comparisons[0];
  const call = comparison.left.type === 'CallExpression' ? comparison.left : comparison.right;
  const resolverBinding = resolvedCallBinding(index, absoluteFile, call);
  if (!resolverBinding || !fallbackBindings.some(binding =>
    bindingCallsTarget(index, resolverBinding, binding, 2))) return null;
  const callSource = program.text.slice(call.start, call.end);
  const comparisonSource = program.text.slice(comparison.start, comparison.end);
  return replaceNodeSource(fn.body, comparison, `(${comparisonSource}||${callSource}==="max")`, program.text);
}

function analyzeUltracode(target) {
  const files = new Map();
  const index = new ModuleIndex(target);
  const xhighGate = discoverEffortGate(target, index, 'xhigh_effort');
  const maxGate = discoverEffortGate(target, index, 'max_effort');
  const consumerPrograms = candidatePrograms(target,
    ['"xhigh"', '"max"', 'CC_ULTRACODE_ELIGIBILITY', 'CC_ULTRACODE_EFFORT_FALLBACK', 'CC_ULTRACODE_ACTIVATION']);
  const eligibilityMatches = [], fallbackMatches = [], activationMatches = [], fallbackBindings = [];
  const uniqueGates = xhighGate.matches.length === 1 && maxGate.matches.length === 1;
  const xhighBinding = uniqueGates ? xhighGate.matches[0].binding : null;
  const maxBinding = uniqueGates ? maxGate.matches[0].binding : null;

  for (const program of consumerPrograms) {
    const absoluteFile = packageFile(target.packageRoot, program.relativePath);
    const maxLocalName = uniqueGates ? localNameForBinding(index, absoluteFile, maxBinding) : null;
    for (const fn of findAstNodes(program.ast, node => node.type === 'FunctionDeclaration')) {
      const body = program.text.slice(fn.body.start, fn.body.end);
      const eligibilityPatched = uniqueGates ? reconstructedBodyMatch(program, fn, 'ULTRACODE_ELIGIBILITY',
        (originalProgram, originalFunction) => renderUltracodeEligibility(
          originalProgram, originalFunction, index, absoluteFile, xhighBinding, maxLocalName)) : null;
      if (eligibilityPatched) eligibilityMatches.push(eligibilityPatched);
      const fallbackPatched = uniqueGates ? reconstructedBodyMatch(program, fn, 'ULTRACODE_EFFORT_FALLBACK',
        (originalProgram, originalFunction) => {
          const modified = renderUltracodeFallbacks(
            originalProgram, originalFunction, index, absoluteFile, xhighBinding, maxLocalName);
          return modified.length === 1 ? modified[0] : null;
        }) : null;
      if (fallbackPatched) {
        fallbackMatches.push(fallbackPatched);
        fallbackBindings.push(index.resolveLocal(absoluteFile, fn.id.name));
      }
      if (body.includes('CC_ULTRACODE_')) continue;
      if (!uniqueGates || eligibilityPatched || fallbackPatched) continue;

      const eligibilityModified = renderUltracodeEligibility(
        program, fn, index, absoluteFile, xhighBinding, maxLocalName);
      if (eligibilityModified !== null) {
        eligibilityMatches.push(bodyPatch(files, program, fn, 'ultracode-eligibility',
          'ULTRACODE_ELIGIBILITY', eligibilityModified));
        continue;
      }

      for (const modified of renderUltracodeFallbacks(
        program, fn, index, absoluteFile, xhighBinding, maxLocalName)) {
        fallbackMatches.push(bodyPatch(files, program, fn, 'ultracode-effort-fallback',
          'ULTRACODE_EFFORT_FALLBACK', modified));
        fallbackBindings.push(index.resolveLocal(absoluteFile, fn.id.name));
      }
    }
  }

  const uniqueFallbackBindings = [...new Map(fallbackBindings.map(binding => [bindingKey(binding), binding])).values()];
  for (const program of consumerPrograms) {
    const absoluteFile = packageFile(target.packageRoot, program.relativePath);
    for (const fn of findAstNodes(program.ast, node => node.type === 'FunctionDeclaration')) {
      const body = program.text.slice(fn.body.start, fn.body.end);
      const activationPatched = reconstructedBodyMatch(program, fn, 'ULTRACODE_ACTIVATION',
        (originalProgram, originalFunction) => renderUltracodeActivation(
          originalProgram, originalFunction, index, absoluteFile, uniqueFallbackBindings));
      if (activationPatched) {
        activationMatches.push(activationPatched);
        continue;
      }
      if (body.includes('CC_ULTRACODE_')) continue;
      const modified = renderUltracodeActivation(program, fn, index, absoluteFile, uniqueFallbackBindings);
      if (modified === null) continue;
      activationMatches.push(bodyPatch(files, program, fn, 'ultracode-activation',
        'ULTRACODE_ACTIVATION', modified));
    }
  }

  const semanticTargets = [
    {id: 'ultracode-eligibility', expectedCardinality: 1, matches: eligibilityMatches},
    {id: 'ultracode-effort-fallback', expectedCardinality: 1, matches: fallbackMatches},
    {id: 'ultracode-activation', expectedCardinality: 1, matches: activationMatches},
  ];
  return finishSemanticPlan('ultracode', semanticTargets, files, {
    candidateFiles: [...new Set([...xhighGate.programs, ...maxGate.programs, ...consumerPrograms].map(item => item.relativePath))],
  });
}

function voiceFunctionByName(program, name) {
  return findAstNodes(program.ast, node => node.type === 'FunctionDeclaration' && node.id?.name === name)[0] || null;
}

function voiceAndCalls(node) {
  if (node?.type === 'LogicalExpression' && node.operator === '&&') {
    const left = voiceAndCalls(node.left), right = voiceAndCalls(node.right);
    return left && right ? [...left, ...right] : null;
  }
  return node?.type === 'CallExpression' && node.callee?.type === 'Identifier' && node.arguments.length === 0 ?
    [node.callee.name] : null;
}

function voiceUnlockBody(marker) {
  return `{return!0/*${marker}*/}`;
}

function voiceSettingsBindings(program, fn) {
  const bindingFor = (pattern, key) => {
    if (pattern?.type !== 'ObjectPattern') return null;
    const property = pattern.properties.find(item => item.type === 'Property' &&
      (item.key?.name === key || item.key?.value === key));
    if (property?.value?.type === 'Identifier') return property.value.name;
    if (property?.value?.type === 'AssignmentPattern' && property.value.left?.type === 'Identifier') {
      return property.value.left.name;
    }
    return null;
  };
  let pattern = fn.params[0];
  if (pattern?.type === 'Identifier') {
    pattern = findAstNodes(fn.body, node => node.type === 'VariableDeclarator' && node.id?.type === 'ObjectPattern' &&
      node.init?.type === 'Identifier' && node.init.name === fn.params[0].name)[0]?.id;
  }
  const bindings = {
    settingsData: bindingFor(pattern, 'settingsData'),
    setAppState: bindingFor(pattern, 'setAppState'),
    setSettingsData: bindingFor(pattern, 'setSettingsData'),
    setChanges: bindingFor(pattern, 'setChanges'),
  };
  const writerCall = findAstNodes(fn.body, node => node.type === 'CallExpression' && node.callee?.type === 'Identifier' &&
    node.arguments?.[0]?.type === 'Literal' && node.arguments[0].value === 'userSettings')[0];
  if (!writerCall) return null;
  const nestedWriter = functionLikeNodes(fn.body).filter(candidate => candidate !== fn && candidate.start <= writerCall.start &&
    writerCall.end <= candidate.end && candidate.type === 'FunctionDeclaration' && candidate.id?.name)
    .sort((left, right) => (left.end - left.start) - (right.end - right.start))[0];
  bindings.writer = nestedWriter?.id.name || writerCall.callee.name;
  bindings.writerTakesKind = !nestedWriter;
  return Object.values(bindings).every(value => value !== null && value !== undefined) ? bindings : null;
}

function voiceSettingsArrays(fn) {
  const arrays = findAstNodes(fn.body, node => node.type === 'ArrayExpression').filter(array => {
    const ids = new Set(findAstNodes(array, node => node.type === 'Property' &&
      (node.key?.name === 'id' || node.key?.value === 'id') && node.value?.type === 'Literal' &&
      typeof node.value.value === 'string').map(node => node.value.value));
    return ids.has('autoCompact') && ids.has('language') && ids.has('editor');
  });
  return arrays.filter(array => !arrays.some(other => other !== array && other.start < array.start && array.end < other.end));
}

function renderVoiceSettingSource(before, bindings) {
  const writerCall = bindings.writerTakesKind ? `${bindings.writer}("userSettings",` : `${bindings.writer}(`;
  const setting = `{id:"voiceMode",label:"Voice mode",value:((${bindings.settingsData}?.voice?.enabled??${bindings.settingsData}?.voiceEnabled)===!0?(${bindings.settingsData}?.voice?.mode??"hold"):"off"),options:["off","hold","tap"],type:"enum",async onChange(__mode){const __enabled=__mode!=="off",__voiceMode=__mode==="tap"?"tap":__mode==="hold"?"hold":(${bindings.settingsData}?.voice?.mode??"hold");const __result=await ${writerCall}{voiceEnabled:__enabled,voice:{...${bindings.settingsData}?.voice,enabled:__enabled,mode:__voiceMode}});if(__result?.error)return{error:__result.error};${bindings.setSettingsData}(__state=>({...__state,voiceEnabled:__enabled,voice:{...__state?.voice,enabled:__enabled,mode:__voiceMode}}));${bindings.setAppState}(__state=>({...__state,settings:{...__state.settings,voiceEnabled:__enabled,voice:{...__state.settings?.voice,enabled:__enabled,mode:__voiceMode}}}));${bindings.setChanges}(__state=>({...__state,"Voice mode":__mode}))}}/*COMETIX_VOICE_SETTING*/,`;
  return `[${setting}${before.slice(1)}`;
}

function renderVoiceSetting(program, array, bindings) {
  return renderVoiceSettingSource(program.text.slice(array.start, array.end), bindings);
}

function reconstructedVoiceSettingsMatch(program, fn, array) {
  const after = program.text.slice(array.start, array.end);
  const before = decodeReversibleBody(after, 'VOICE_SETTING');
  if (before === null) return null;
  const bindings = voiceSettingsBindings(program, fn);
  if (!bindings) return null;
  const modified = renderVoiceSettingSource(before, bindings);
  const expected = `[${reversibleBodyMarker('VOICE_SETTING', before, modified)}${modified.slice(1)}`;
  if (after !== expected) return null;
  return {relativePath: program.relativePath, start: array.start, end: array.end, state: 'after', before, after};
}

function voiceAdapterBody(target, program, fn) {
  if (fn.params[0]?.type !== 'Identifier') return null;
  const callbacks = fn.params[0].name;
  const vendorRelative = path.posix.relative(path.posix.dirname(program.relativePath), 'vendor/cometix-asr/index.js');
  const vendorSpecifier = vendorRelative.startsWith('.') ? vendorRelative : `./${vendorRelative}`;
  const loader = target.layout === 'split-esm' ?
    `const [{createRequire:__createRequire},{fileURLToPath:__fileURLToPath}]=await Promise.all([import("node:module"),import("node:url")]),__require=__createRequire(import.meta.url),_path=__require("node:path"),_fs=__require("node:fs");function __loadCometixAsr(){try{const m=__require(__fileURLToPath(new URL(${JSON.stringify(vendorSpecifier)},import.meta.url)));return m&&typeof m.startSession==="function"?m:null}catch{return null}}` :
    `const _path=require("path"),_fs=require("fs");function __loadCometixAsr(){const tryLoad=(p)=>{try{if(!p)return null;const m=require(p);if(m&&typeof m.startSession==="function")return m}catch{}return null};const dirs=[];try{dirs.push(_path.join(__dirname,"vendor","cometix-asr"))}catch{}for(const dir of dirs){if(!dir||!_fs.existsSync(dir))continue;let m=tryLoad(_path.join(dir,"index.js"));if(m)return m;m=tryLoad(dir);if(m)return m;try{for(const f of _fs.readdirSync(dir).filter(x=>x.startsWith("libcometix-asr")&&x.endsWith(".node"))){m=tryLoad(_path.join(dir,f));if(m)return m}}catch{}}return null}`;
  return `{/*COMETIX_ASR_VOICE_STREAM*/
/* CC voice bridge: cumulative Preview + one final result for the whole hold */
${loader}
const __asr=__loadCometixAsr();
if(!__asr){try{${callbacks}.onError("cometix-asr vendor missing startSession",{fatal:true,connectFailureCode:"cometix_asr_missing"})}catch{}return null}
let __handle=null,__connected=false,__finalized=false,__closed=false,__readyFired=false;
let __finalText="",__previewText="",__previewBase="",__livePiece="";
let __previewAcceptedAt=0;
let __emittedFinal=false,__finResolve=null,__finTimer=null;
let __audioChunks=0,__audioBytes=0;
const __traceFile=String(process.env.COMETIX_ASR_TRACE_FILE||"").trim();
const __traceId=String(process.pid)+"-"+String(Date.now())+"-"+Math.random().toString(36).slice(2,8);
const __traceStartedAt=Date.now();
let __traceLastAt=__traceStartedAt,__traceSeq=0,__traceWriteFailed=false;
function __trace(kind,data){
  if(!__traceFile)return;
  const now=Date.now();
  const row={schema:1,traceId:__traceId,seq:++__traceSeq,at:new Date(now).toISOString(),elapsedMs:now-__traceStartedAt,deltaMs:now-__traceLastAt,kind,...(data||{})};
  __traceLastAt=now;
  try{const line=JSON.stringify(row,(key,value)=>{if(typeof value==="string"&&value.length>2000)return value.slice(0,2000)+"...<len="+String(value.length)+">";return value});_fs.appendFileSync(__traceFile,line+String.fromCharCode(10),"utf8")}catch(err){if(!__traceWriteFailed){__traceWriteFailed=true;try{if(typeof v==="function")v("[cometix_asr_trace] write failed: "+String(err))}catch{}}}
}
function __previewState(){return{previewText:__previewText,previewBase:__previewBase,livePiece:__livePiece,previewAcceptedAt:__previewAcceptedAt,finalText:__finalText,emittedFinal:__emittedFinal}}
function __cleanTranscript(text){return String(text||"").trim()}
function __commonPrefixLength(a,b){let n=Math.min(a.length,b.length),i=0;while(i<n&&a.charCodeAt(i)===b.charCodeAt(i))i++;return i}
function __sameLiveRewrite(a,b){a=__cleanTranscript(a);b=__cleanTranscript(b);if(!a||!b||a.startsWith(b)||b.startsWith(a))return true;const short=Math.min(a.length,b.length),common=__commonPrefixLength(a,b);return common>=Math.min(4,Math.max(1,Math.ceil(short*0.45)))}
function __isStrictProjection(container,candidate){return Boolean(container&&candidate&&container!==candidate&&(container.startsWith(candidate)||container.endsWith(candidate)))}
function __appendTranscript(base,tail){base=__cleanTranscript(base);tail=__cleanTranscript(tail);if(!base)return tail;if(!tail||base.endsWith(tail))return base;if(tail.startsWith(base))return tail;for(let n=Math.min(base.length,tail.length);n>0;n--){if(base.endsWith(tail.slice(0,n)))return base+tail.slice(n)}const sep=/[A-Za-z0-9]$/.test(base)&&/^[A-Za-z0-9]/.test(tail)?" ":"";return base+sep+tail}
function __cumulativePreview(full,piece,stage){
  full=__cleanTranscript(full);piece=__cleanTranscript(piece);const before=__previewState(),incoming=full||piece,previous=__previewText;const now=Date.now(),projectionAgeMs=__previewAcceptedAt?now-__previewAcceptedAt:null;
  if(!incoming){__trace("preview.normalize",{stage,decision:"empty",full,piece,projectionAgeMs,before,after:__previewState(),output:__previewText});return __previewText}
  let decision="",next=previous,accepted=false;const live=piece||incoming;
  if(!previous){decision=stage+".first";next=incoming;accepted=true}
  else if(incoming===previous){decision=stage+".ignore_duplicate";__previewAcceptedAt=now}
  else if(__isStrictProjection(previous,incoming)&&projectionAgeMs!==null&&projectionAgeMs<=20){decision=stage+".ignore_parallel_projection";if(stage==="stable"&&previous.startsWith(incoming)){__previewBase=incoming;__livePiece=previous.slice(incoming.length)}}
  else if(incoming.startsWith(previous)){decision=stage+".accept_extension";next=incoming;accepted=true}
  else if(previous.startsWith(incoming)||__sameLiveRewrite(previous,incoming)){decision=stage+".accept_whole_rewrite";next=incoming;accepted=true}
  else if(__previewBase){if(incoming.startsWith(__previewBase)&&incoming.length>__previewBase.length){decision=stage+".accept_cumulative_display";next=incoming}else if(__livePiece&&__sameLiveRewrite(__livePiece,live)){decision=stage+".rewrite_live_piece";next=__appendTranscript(__previewBase,live)}else{decision=stage+".rebuild_from_base";next=__appendTranscript(__previewBase,live)}accepted=true}
  else{decision=stage+".new_phrase_reset";__previewBase=previous;__livePiece=live;next=__appendTranscript(__previewBase,live);accepted=true}
  if(accepted){__previewText=next;__previewAcceptedAt=now;if(stage==="stable"){__previewBase=next;__livePiece=""}else if(__previewBase&&next.startsWith(__previewBase)){__livePiece=next.slice(__previewBase.length)}else{__livePiece=live}}
  __trace("preview.normalize",{stage,decision,full,piece,projectionAgeMs,accepted,before,after:__previewState(),output:__previewText});return __previewText
}
function __emitFinalOnce(text,source){text=__cleanTranscript(text);source=source||"unknown";if(!text){__trace("final.skip",{source,reason:"empty",state:__previewState()});return}if(__emittedFinal){__trace("final.skip",{source,reason:"already_emitted",text,textLength:text.length,state:__previewState()});return}__emittedFinal=true;__finalText=text;__trace("cc.onTranscript",{source,isFinal:true,text,textLength:text.length,state:__previewState()});try{${callbacks}.onTranscript(text,true)}catch(err){__trace("cc.onTranscript.error",{source,isFinal:true,error:String(err)})}if(__finResolve){const r=__finResolve;__finResolve=null;if(__finTimer){clearTimeout(__finTimer);__finTimer=null}__trace("bridge.finalize.resolve",{source,result:"session_final",state:__previewState()});r("session_final")}}
__trace("bridge.init",{pid:process.pid,traceFile:__traceFile});
const __api={
  send(k){if(!__connected||__finalized||__closed||__handle==null)return;const size=k&&typeof k.length==="number"?k.length:0;__audioChunks++;__audioBytes+=size;try{__asr.feedPcm(__handle,Buffer.from(k))}catch(err){__trace("audio.feed.error",{error:String(err),chunkBytes:size,audioChunks:__audioChunks,audioBytes:__audioBytes})}},
  finalize(){if(__finalized||__closed){__trace("bridge.finalize.skip",{reason:"already_closed",finalized:__finalized,closed:__closed,state:__previewState()});return Promise.resolve("ws_already_closed")}__finalized=true;__trace("bridge.finalize.request",{audioChunks:__audioChunks,audioBytes:__audioBytes,state:__previewState()});return new Promise((resolve)=>{__finResolve=resolve;try{__asr.finalizeSession(__handle)}catch(err){__trace("addon.finalize.error",{error:String(err)})}__finTimer=setTimeout(()=>{__finTimer=null;__trace("bridge.finalize.timeout",{hasFinalText:Boolean(__finalText),state:__previewState()});if(!__emittedFinal&&__finalText)__emitFinalOnce(__finalText,"finalize_timeout_fallback");const r=__finResolve;__finResolve=null;if(r){const result=__emittedFinal?"session_final":"safety_timeout";__trace("bridge.finalize.resolve",{source:"timeout",result,state:__previewState()});r(result)}},12000)})},
  close(){__trace("bridge.close.request",{audioChunks:__audioChunks,audioBytes:__audioBytes,state:__previewState()});__closed=true;__connected=false;try{if(__handle!=null)__asr.closeSession(__handle)}catch(err){__trace("addon.close.error",{error:String(err)})}__handle=null;if(__finResolve){const r=__finResolve;__finResolve=null;if(__finTimer){clearTimeout(__finTimer);__finTimer=null}__trace("bridge.finalize.resolve",{source:"api.close",result:"ws_close",state:__previewState()});r("ws_close")}try{${callbacks}.onClose&&${callbacks}.onClose()}catch(err){__trace("cc.onClose.error",{error:String(err)})}},
  isConnected(){return __connected&&!__closed}
};
function __startLive(){__trace("addon.start.request",{});__handle=__asr.startSession("{}",(err,j)=>{if(err){__trace("addon.callback.error",{error:String(err)});try{${callbacks}.onError(String(err))}catch(callbackErr){__trace("cc.onError.error",{error:String(callbackErr)})}return}let ev;try{ev=JSON.parse(j)}catch(parseErr){__trace("addon.event.parse_error",{error:String(parseErr),raw:String(j||"")});return}if(ev.type==="ready"){__connected=true;__trace("addon.ready",{sessionId:ev.session_id||"",mode:ev.mode||""});if(!__readyFired){__readyFired=true;__trace("cc.onReady",{});try{${callbacks}.onReady(__api)}catch(callbackErr){__trace("cc.onReady.error",{error:String(callbackErr)})}}}else if(ev.type==="transcript"){const display=__cleanTranscript(ev.display),piece=__cleanTranscript(ev.text);const full=display||piece;const stage=ev.stage||((ev.is_vad_finished||ev.is_final)?"stable":"interim");__trace("addon.transcript",{rawStage:ev.stage||"",stage,isInterim:Boolean(ev.is_interim),isVadFinished:Boolean(ev.is_vad_finished),isFinal:Boolean(ev.is_final),text:piece,textLength:piece.length,display,displayLength:display.length,passCount:Number(ev.pass_count||0),stableText:__cleanTranscript(ev.stable_text),liveText:__cleanTranscript(ev.live_text),state:__previewState()});if(!full&&!__previewText){__trace("transcript.skip",{reason:"empty",stage,state:__previewState()});return}if(stage==="session_final"){__emitFinalOnce(full||__previewText,"addon.session_final")}else{const normalizedStage=stage==="stable"?"stable":"interim",previousPreview=__previewText,preview=__cumulativePreview(full,piece,normalizedStage);if(!preview){__trace("transcript.skip",{reason:"normalized_empty",stage,state:__previewState()});return}__finalText=preview;if(preview===previousPreview){__trace("cc.onTranscript.skip",{source:"preview."+normalizedStage,reason:"unchanged_projection",text:preview,textLength:preview.length,state:__previewState()});return}__trace("cc.onTranscript",{source:"preview."+normalizedStage,isFinal:false,text:preview,textLength:preview.length,state:__previewState()});try{${callbacks}.onTranscript(preview,false)}catch(callbackErr){__trace("cc.onTranscript.error",{source:"preview."+normalizedStage,isFinal:false,error:String(callbackErr)})}}}else if(ev.type==="processed"){__trace("addon.processed",{text:__cleanTranscript(ev.text),fmtText:__cleanTranscript(ev.fmt_text)});__emitFinalOnce(ev.text||ev.fmt_text||"","addon.processed")}else if(ev.type==="error"){__trace("addon.error",{message:ev.message||"asr error",code:ev.code||""});try{${callbacks}.onError(ev.message||"asr error")}catch(callbackErr){__trace("cc.onError.error",{error:String(callbackErr)})}}else if(ev.type==="close"){__connected=false;__trace("addon.close",{state:__previewState(),audioChunks:__audioChunks,audioBytes:__audioBytes});if(__finalText&&!__emittedFinal)__emitFinalOnce(__finalText,"addon.close_fallback");if(__finResolve){const r=__finResolve;__finResolve=null;if(__finTimer){clearTimeout(__finTimer);__finTimer=null}const result=__emittedFinal?"session_final":"close";__trace("bridge.finalize.resolve",{source:"addon.close",result,state:__previewState()});r(result)}try{${callbacks}.onClose&&${callbacks}.onClose()}catch(callbackErr){__trace("cc.onClose.error",{error:String(callbackErr)})}}else if(ev.type==="debug"){__trace("addon.debug",{message:ev.message||""})}else{__trace("addon.unknown",{event:ev})}})}
try{__startLive()}catch(err){__trace("addon.start.error",{error:String(err)});try{${callbacks}.onError(String(err),{fatal:true,connectFailureCode:"cometix_start_failed"})}catch(callbackErr){__trace("cc.onError.error",{error:String(callbackErr)})}return null}
return __api}`;
}

function voiceAssetResources(options = {}) {
  const configured = process.env.CC_PATCH_VOICE_ASSET_SOURCE;
  if (!configured) throw new Error('VoiceMode resource source is not configured');
  const rootStat = lstatIfPresent(configured);
  if (!rootStat || !rootStat.isDirectory() || rootStat.isSymbolicLink()) {
    if (!options.allowMissingResources || rootStat) {
      throw new Error(`VoiceMode resource directory is not safe: ${configured}`);
    }
  }
  const root = rootStat ? fs.realpathSync(configured) : path.resolve(configured);
  const names = ['index.js', 'index.d.ts', 'package.json', 'libcometix-asr.darwin-arm64.node'];
  return names.map(name => {
    const source = path.join(root, name), stat = lstatIfPresent(source);
    if (!stat || !stat.isFile() || stat.isSymbolicLink() || path.dirname(source) !== root) {
      if (!options.allowMissingResources || stat) {
        throw new Error(`VoiceMode resource is not a regular file: ${name}`);
      }
    }
    return {kind: 'copy', source, sourceKind: 'voice-asset', destination: `vendor/cometix-asr/${name}`,
      expectedBefore: 'absent-or-baselined', sourceAvailable: Boolean(stat)};
  });
}

function analyzeVoiceMode(target, options = {}) {
  const files = new Map(), commandPrograms = candidatePrograms(target,
    ['allow_voice_mode', 'name:"voice"', 'COMETIX_VOICE_GATE', 'COMETIX_VOICE_AVAIL']);
  const entryMatches = [], availabilityMatches = [], authMatches = [], flagMatches = [];
  for (const program of commandPrograms) {
    for (const fn of findAstNodes(program.ast, node => node.type === 'FunctionDeclaration')) {
      for (const [id, marker, list] of [
        ['entry-gate', 'COMETIX_VOICE_GATE', entryMatches],
        ['auth-probe', 'COMETIX_VOICE_AUTH', authMatches],
        ['feature-flag', 'COMETIX_VOICE_FLAG', flagMatches],
      ]) {
        const patched = reconstructedBodyMatch(program, fn, marker,
          () => voiceUnlockBody(marker));
        if (patched) list.push(patched);
      }
    }
    for (const object of findAstNodes(program.ast, node => node.type === 'ObjectExpression')) {
      if (propertyNamed(object, 'name')?.value?.value !== 'voice') continue;
      const availability = propertyNamed(object, 'availability')?.value;
      const hidden = object.properties.find(property => property.type === 'Property' && property.kind === 'get' &&
        (property.key?.name === 'isHidden' || property.key?.value === 'isHidden'));
      const hiddenReturn = hidden && findAstNodes(hidden.value, node => node.type === 'ReturnStatement')[0];
      const gateCall = hiddenReturn?.argument?.type === 'UnaryExpression' && hiddenReturn.argument.operator === '!' ?
        hiddenReturn.argument.argument : null;
      const gate = gateCall?.type === 'CallExpression' && gateCall.callee?.type === 'Identifier' ?
        voiceFunctionByName(program, gateCall.callee.name) : null;
      if (gate && !program.text.slice(gate.body.start, gate.body.end).includes('COMETIX_VOICE_GATE')) {
        const returned = gate.body.body.length === 1 && gate.body.body[0].type === 'ReturnStatement' ? gate.body.body[0] : null;
        const calledNames = voiceAndCalls(returned?.argument);
        if (calledNames && [2, 3].includes(calledNames.length)) {
          entryMatches.push(bodyPatch(files, program, gate, 'entry-gate', 'COMETIX_VOICE_GATE',
            voiceUnlockBody('COMETIX_VOICE_GATE')));
          for (const calledName of calledNames) {
            const called = voiceFunctionByName(program, calledName);
            if (!called) continue;
            const source = program.text.slice(called.start, called.end);
            if (source.includes('allow_voice_mode') && !source.includes('COMETIX_VOICE_FLAG')) {
              flagMatches.push(bodyPatch(files, program, called, 'feature-flag', 'COMETIX_VOICE_FLAG',
                voiceUnlockBody('COMETIX_VOICE_FLAG')));
            }
            const tryStatement = called.body.body.length === 1 && called.body.body[0].type === 'TryStatement' ? called.body.body[0] : null;
            if (tryStatement && !source.includes('COMETIX_VOICE_AUTH')) {
              const hasNegatedCall = findAstNodes(tryStatement.block, node => node.type === 'IfStatement' &&
                node.test?.type === 'UnaryExpression' && node.test.operator === '!' &&
                node.test.argument?.type === 'CallExpression').length === 1;
              const hasReturnCall = findAstNodes(tryStatement.block, node => node.type === 'ReturnStatement' &&
                node.argument?.type === 'CallExpression').length === 1;
              if (hasNegatedCall && hasReturnCall) authMatches.push(bodyPatch(files, program, called, 'auth-probe',
                'COMETIX_VOICE_AUTH', voiceUnlockBody('COMETIX_VOICE_AUTH')));
            }
          }
        }
      }
      if (availability) {
        const suffix = program.text.slice(availability.end, availability.end + 512);
        const markerSuffix = suffix.match(/^\/\*COMETIX_VOICE_AVAIL\*\/\/\*CC_VOICE_AVAIL:[A-Za-z0-9+/=]+:[a-f0-9]{64}\*\//)?.[0] || '';
        const afterEnd = availability.end + markerSuffix.length;
        const after = program.text.slice(availability.start, afterEnd);
        const before = markerSuffix ? decodeReversibleBody(after, 'VOICE_AVAIL') : null;
        if (before !== null) {
          const modified = 'void 0/*COMETIX_VOICE_AVAIL*/';
          const expected = `${modified}${reversibleBodyMarker('VOICE_AVAIL', before, modified)}`;
          if (after === expected) availabilityMatches.push({relativePath: program.relativePath, start: availability.start,
            end: afterEnd, state: 'after', before, after});
        } else if (availability.type === 'ArrayExpression' && availability.elements.some(item => item?.value === 'claude-ai')) {
          const modified = 'void 0/*COMETIX_VOICE_AVAIL*/';
          const replacement = `${modified}${reversibleBodyMarker('VOICE_AVAIL', after, modified)}`;
          availabilityMatches.push({relativePath: program.relativePath, start: availability.start, end: availability.end,
            state: 'before', before: after, after: replacement});
          const commandBefore = program.text.slice(object.start, object.end);
          const commandAfter = replaceNodeSource(object, availability, replacement, program.text);
          addPlannedReplacement(files, program,
            {start: availability.start, end: availability.end, text: replacement, semanticId: 'availability'},
            commandBefore, commandAfter);
        }
      }
    }
  }

  const capabilityIndex = new ModuleIndex(target);
  const capabilityReferencePrograms = candidatePrograms(target, ['isVoiceStreamAvailable']);
  const capabilityBindings = [];
  for (const program of capabilityReferencePrograms) {
    const absoluteFile = packageFile(target.packageRoot, program.relativePath);
    for (const property of findAstNodes(program.ast, node => node.type === 'Property' &&
      (node.key?.name === 'isVoiceStreamAvailable' || node.key?.value === 'isVoiceStreamAvailable'))) {
      let reference = property.value;
      if (reference?.type === 'ArrowFunctionExpression') reference = reference.body;
      if (reference?.type === 'CallExpression' && reference.arguments.length === 0) reference = reference.callee;
      if (reference?.type !== 'Identifier') continue;
      try { capabilityBindings.push(capabilityIndex.resolveLocal(absoluteFile, reference.name)); } catch {}
    }
  }
  const uniqueCapabilityBindings = [...new Map(capabilityBindings.map(binding => [bindingKey(binding), binding])).values()];
  const capabilityPrograms = candidatePrograms(target,
    ['isVoiceStreamAvailable', 'accessToken', 'COMETIX_VOICE_STREAM_AVAIL']);
  const capabilityMatches = [];
  for (const program of capabilityPrograms) {
    const absoluteFile = packageFile(target.packageRoot, program.relativePath);
    for (const fn of findAstNodes(program.ast, node => node.type === 'FunctionDeclaration' && node.params.length === 0)) {
      let functionBinding = null;
      try { functionBinding = capabilityIndex.resolveLocal(absoluteFile, fn.id.name); } catch {}
      if (!functionBinding || uniqueCapabilityBindings.length !== 1 ||
          bindingKey(functionBinding) !== bindingKey(uniqueCapabilityBindings[0])) continue;
      const patched = reconstructedBodyMatch(program, fn, 'COMETIX_VOICE_STREAM_AVAIL',
        () => voiceUnlockBody('COMETIX_VOICE_STREAM_AVAIL'));
      if (patched) { capabilityMatches.push(patched); continue; }
      const source = program.text.slice(fn.start, fn.end);
      if (source.includes('COMETIX_VOICE_STREAM_AVAIL') || !memberNamed(fn, 'accessToken')) continue;
      const negatedCall = findAstNodes(fn.body, node => node.type === 'IfStatement' &&
        node.test?.type === 'UnaryExpression' && node.test.operator === '!' &&
        node.test.argument?.type === 'CallExpression');
      if (negatedCall.length !== 1) continue;
      capabilityMatches.push(bodyPatch(files, program, fn, 'stream-capability', 'COMETIX_VOICE_STREAM_AVAIL',
        voiceUnlockBody('COMETIX_VOICE_STREAM_AVAIL')));
    }
  }

  const settingsPrograms = candidatePrograms(target,
    ['id:"autoCompact"', 'id:"language"', 'id:"editor"', 'COMETIX_VOICE_SETTING']);
  const settingsMatches = [];
  for (const program of settingsPrograms) {
    for (const fn of findAstNodes(program.ast, node => node.type === 'FunctionDeclaration' && node.params.length > 0)) {
      const bindings = voiceSettingsBindings(program, fn);
      for (const array of voiceSettingsArrays(fn)) {
        const patched = reconstructedVoiceSettingsMatch(program, fn, array);
        if (patched) { settingsMatches.push(patched); continue; }
        if (!bindings || program.text.slice(array.start, array.end).includes('COMETIX_VOICE_SETTING')) continue;
        const before = program.text.slice(array.start, array.end), modified = renderVoiceSetting(program, array, bindings);
        const after = `[${reversibleBodyMarker('VOICE_SETTING', before, modified)}${modified.slice(1)}`;
        settingsMatches.push({relativePath: program.relativePath, start: array.start, end: array.end,
          state: 'before', before, after});
        addPlannedReplacement(files, program,
          {start: array.start, end: array.end, text: after, semanticId: 'settings-ui-schema'}, before, after);
      }
    }
  }

  const connectionPrograms = candidatePrograms(target,
    ['speech_to_text/voice_stream', 'stt_provider', 'linear16', 'COMETIX_ASR_VOICE_STREAM']);
  const connectionMatches = [];
  for (const program of connectionPrograms) {
    for (const fn of findAstNodes(program.ast, node => node.type === 'FunctionDeclaration' && node.async)) {
      const patched = reconstructedBodyMatch(program, fn, 'COMETIX_ASR_VOICE_STREAM',
        (originalProgram, originalFunction) => voiceAdapterBody(target, program, originalFunction));
      if (patched) { connectionMatches.push(patched); continue; }
      const source = program.text.slice(fn.start, fn.end), strings = findAstNodes(fn, node => node.type === 'Literal' &&
        typeof node.value === 'string').map(node => node.value);
      const hasVoiceTransport = strings.some(value => value === 'linear16' || value.includes('deepgram') ||
        value.includes('speech_to_text/voice_stream'));
      if (source.includes('COMETIX_ASR_VOICE_STREAM') || !hasVoiceTransport ||
          (!memberNamed(fn, 'onTranscript') && !memberNamed(fn, 'onReady'))) continue;
      const modified = voiceAdapterBody(target, program, fn);
      if (modified !== null) connectionMatches.push(bodyPatch(files, program, fn, 'connection',
        'COMETIX_ASR_VOICE_STREAM', modified));
    }
  }

  const resources = voiceAssetResources(options);
  const resourcesCurrent = resources.every(resource => {
    const destination = managedDestination(target, resource.destination), stat = lstatIfPresent(destination);
    return stat?.isFile() && !stat.isSymbolicLink() && (!resource.sourceAvailable ||
      sha256(fs.readFileSync(destination)) === sha256(fs.readFileSync(resource.source)) &&
      (stat.mode & 0o777) === (fs.statSync(resource.source).mode & 0o777));
  });
  const semanticTargets = [
    {id: 'entry-gate', expectedCardinality: 1, matches: entryMatches},
    {id: 'stream-capability', expectedCardinality: 1, matches: capabilityMatches},
    {id: 'availability', expectedCardinality: 1, matches: availabilityMatches},
    {id: 'settings-ui-schema', expectedCardinality: 1, matches: settingsMatches},
    {id: 'connection', expectedCardinality: 1, matches: connectionMatches},
    {id: 'auth-probe', expectedCardinality: 1, matches: authMatches},
    {id: 'feature-flag', expectedCardinality: 1, matches: flagMatches},
  ];
  const plan = finishSemanticPlan('voice-mode', semanticTargets, files, {
    candidateFiles: [...new Set([...commandPrograms, ...capabilityPrograms, ...settingsPrograms, ...connectionPrograms]
      .map(item => item.relativePath))],
  });
  plan.resources = resources;
  if (!resourcesCurrent) plan.state = 'needs-patch';
  return plan;
}

function contextLimitValue() {
  return '(+process.env.CLAUDE_CODE_CONTEXT_LIMIT||200000)';
}

function contextDefaultDeclarators(program, declaration) {
  const declarators = declaration.declarations.filter(item => item.id?.type === 'Identifier' &&
    item.init?.type === 'Literal' && item.init.value === 200000);
  if (declarators.length !== 2) return null;
  if (!memberNamed(program.ast, 'CLAUDE_CODE_DISABLE_1M_CONTEXT')) return null;
  const functions = findAstNodes(program.ast, node => node.type === 'FunctionDeclaration' && node.id?.name);
  const usesIdentifier = (node, name) => findAstNodes(node,
    child => child.type === 'Identifier' && child.name === name).length > 0;
  const callsFunction = (node, name) => findAstNodes(node,
    child => child.type === 'CallExpression' && child.callee?.type === 'Identifier' && child.callee.name === name).length > 0;
  const pairs = [];
  for (const context of declarators) {
    const maximumFunctions = functions.filter(fn =>
      memberNamed(fn, 'CLAUDE_CODE_MAX_CONTEXT_TOKENS') && usesIdentifier(fn, context.id.name));
    const compact = declarators.find(item => item !== context);
    for (const maximum of maximumFunctions) {
      if (functions.some(fn => fn !== maximum && usesIdentifier(fn, compact.id.name) &&
          callsFunction(fn, maximum.id.name))) pairs.push({context, compact});
    }
  }
  const unique = [...new Map(pairs.map(pair =>
    [`${pair.context.id.name}:${pair.compact.id.name}`, pair])).values()];
  return unique.length === 1 ? [unique[0].context, unique[0].compact] : null;
}

function renderContextDefault(program, declaration, target, declarators) {
  let rendered = program.text.slice(declaration.start, declaration.end);
  for (const item of [...declarators].sort((a, b) => b.init.start - a.init.start)) {
    const start = item.init.start - declaration.start, end = item.init.end - declaration.start;
    rendered = rendered.slice(0, start) + contextLimitValue() + rendered.slice(end);
  }
  const names = declarators.map(item => item.id.name);
  const setter = `function __ccRefreshContextLimit(){${names.join('=')}=${contextLimitValue()}}`;
  return `${rendered};${setter}${target.layout === 'split-esm' ? ';export{__ccRefreshContextLimit};' : ''}`;
}

function contextSettingsBody(program, fn, refreshName) {
  const body = program.text.slice(fn.body.start, fn.body.end);
  return `${body.slice(0, -1)};${refreshName}();}`;
}

function contextSetterSpecifier(settingsFile, defaultFile) {
  let specifier = path.posix.relative(path.posix.dirname(settingsFile), defaultFile);
  if (!specifier.startsWith('.')) specifier = `./${specifier}`;
  return specifier;
}

function analyzeContextLimit(target) {
  const files = new Map();
  const defaultPrograms = candidatePrograms(target,
    ['CLAUDE_CODE_DISABLE_1M_CONTEXT', 'CLAUDE_CODE_MAX_CONTEXT_TOKENS', 'CC_CONTEXT_DEFAULT']);
  const defaultMatches = [];
  for (const program of defaultPrograms) {
    const marker = /\/\*CC_CONTEXT_DEFAULT:[A-Za-z0-9+/=]+:[a-f0-9]{64}\*\//g;
    for (const match of program.text.matchAll(marker)) {
      const declaration = [...program.ast.body].reverse().find(node => node.type === 'VariableDeclaration' && node.start < match.index);
      if (!declaration) continue;
      const start = declaration.start, end = match.index + match[0].length;
      const after = program.text.slice(start, end), before = decodeReversibleBody(after, 'CONTEXT_DEFAULT');
      if (before === null) continue;
      let original;
      try { original = acorn.parse(before, {ecmaVersion: 'latest', sourceType: program.sourceType}).body[0]; } catch { continue; }
      const declarators = contextDefaultDeclarators(program, original);
      if (!declarators) continue;
      const originalProgram = {...program, text: before, ast: {body: [original]}};
      const modified = renderContextDefault(originalProgram, original, target, declarators);
      const expected = `${modified}${reversibleBodyMarker('CONTEXT_DEFAULT', before, modified)}`;
      if (after === expected) defaultMatches.push({relativePath: program.relativePath, start, end, state: 'after', before, after});
    }
    if (defaultMatches.some(item => item.relativePath === program.relativePath)) continue;
    for (const declaration of program.ast.body.filter(node => node.type === 'VariableDeclaration')) {
      const before = program.text.slice(declaration.start, declaration.end);
      const declarators = contextDefaultDeclarators(program, declaration);
      if (!declarators) continue;
      const modified = renderContextDefault(program, declaration, target, declarators);
      const after = `${modified}${reversibleBodyMarker('CONTEXT_DEFAULT', before, modified)}`;
      defaultMatches.push({relativePath: program.relativePath, start: declaration.start, end: declaration.end,
        state: 'before', before, after});
      addPlannedReplacement(files, program,
        {start: declaration.start, end: declaration.end, text: after, semanticId: 'context-default'}, before, after);
    }
  }

  const defaultFiles = [...new Set(defaultMatches.map(item => item.relativePath))];
  const settingsPrograms = candidatePrograms(target,
    ['applyConfigEnvironmentVariables', 'Object.assign(process.env', 'CC_CONTEXT_SETTINGS_REFRESH']);
  const settingsMatches = [], importTransformations = [];
  for (const program of settingsPrograms) {
    const methods = findAstNodes(program.ast, node => node.type === 'MethodDefinition' &&
      (node.key?.name === 'applyConfigEnvironmentVariables' || node.key?.value === 'applyConfigEnvironmentVariables') &&
      findAstNodes(node.value, child => child.type === 'CallExpression' && child.callee?.type === 'MemberExpression' &&
        child.callee.object?.name === 'Object' && child.callee.property?.name === 'assign' &&
        child.arguments?.[0]?.type === 'MemberExpression' && child.arguments[0].object?.name === 'process' &&
        child.arguments[0].property?.name === 'env').length > 0);
    for (const method of methods) {
      const refreshName = target.layout === 'split-esm' ? '__ccPatchRefreshContextLimit' : '__ccRefreshContextLimit';
      const patched = reconstructedBodyMatch(program, method.value, 'CONTEXT_SETTINGS_REFRESH',
        (originalProgram, originalFunction) => contextSettingsBody(originalProgram, originalFunction, refreshName));
      if (patched) {
        if (target.layout === 'split-esm') {
          if (defaultMatches.length !== 1 || defaultFiles.length !== 1) continue;
          const expectedSpecifier = contextSetterSpecifier(program.relativePath, defaultFiles[0]);
          const imports = program.ast.body.filter(node => node.type === 'ImportDeclaration');
          const setterImports = imports.filter(node => node.source.value === expectedSpecifier &&
            node.specifiers.length === 1 && node.specifiers[0].type === 'ImportSpecifier' &&
            node.specifiers[0].local?.name === refreshName &&
            node.specifiers[0].imported?.name === '__ccRefreshContextLimit');
          if (setterImports.length !== 1) continue;
          const setterIndex = imports.indexOf(setterImports[0]);
          const setterImport = imports[setterIndex], originalImport = imports[setterIndex + 1];
          if (!originalImport || setterImport.end !== originalImport.start) continue;
          try {
            const binding = new ModuleIndex(target).resolveLocal(
              packageFile(target.packageRoot, program.relativePath), refreshName);
            if (binding.file !== packageFile(target.packageRoot, defaultFiles[0]) ||
                binding.exportedName !== '__ccRefreshContextLimit') continue;
          } catch { continue; }
          const after = program.text.slice(setterImport.start, originalImport.end);
          const before = program.text.slice(originalImport.start, originalImport.end).replace(/^import\s+/, 'import');
          importTransformations.push({semanticId: 'settings-env-refresh-import', relativePath: program.relativePath,
            start: setterImport.start, state: 'after', before, after});
        }
        settingsMatches.push(patched);
        continue;
      }
      if (target.layout === 'split-esm') {
        if (defaultMatches.length !== 1 || defaultFiles.length !== 1) continue;
        if (findAstNodes(program.ast, node => node.type === 'Identifier' && node.name === refreshName).length > 0) continue;
        const firstImport = program.ast.body.find(node => node.type === 'ImportDeclaration');
        if (!firstImport) continue;
        const match = bodyPatch(files, program, method.value, 'settings-env-refresh',
          'CONTEXT_SETTINGS_REFRESH', contextSettingsBody(program, method.value, refreshName));
        settingsMatches.push(match);
        const specifier = contextSetterSpecifier(program.relativePath, defaultFiles[0]);
        const before = program.text.slice(firstImport.start, firstImport.end);
        const prefix = `import{__ccRefreshContextLimit as ${refreshName}}from${JSON.stringify(specifier)};`;
        const after = `${prefix}import ${before.slice('import'.length)}`;
        addPlannedReplacement(files, program,
          {start: firstImport.start, end: firstImport.end, text: after, semanticId: 'settings-env-refresh-import'}, before, after);
        importTransformations.push({semanticId: 'settings-env-refresh-import', relativePath: program.relativePath,
          start: firstImport.start, state: 'before', before, after});
      } else if (defaultMatches.length === 1) {
        const match = bodyPatch(files, program, method.value, 'settings-env-refresh',
          'CONTEXT_SETTINGS_REFRESH', contextSettingsBody(program, method.value, refreshName));
        settingsMatches.push(match);
      }
    }
  }
  const semanticTargets = [
    {id: 'context-default', expectedCardinality: 1, matches: defaultMatches},
    {id: 'settings-env-refresh', expectedCardinality: 1, matches: settingsMatches},
  ];
  const plan = finishSemanticPlan('context-limit', semanticTargets, files, {
    candidateFiles: [...new Set([...defaultPrograms, ...settingsPrograms].map(item => item.relativePath))],
  });
  plan.attribution.transformations.push(...importTransformations);
  return plan;
}

function unwrapComputerSchemaExpression(expression) {
  let current = expression;
  while (current?.type === 'SequenceExpression' || current?.type === 'ParenthesizedExpression') {
    current = current.type === 'SequenceExpression' ? current.expressions.at(-1) : current.expression;
  }
  return current;
}

function computerSchemaRoot(expression) {
  let current = unwrapComputerSchemaExpression(expression);
  while (current?.type === 'CallExpression' && current.callee?.type === 'MemberExpression') {
    current = unwrapComputerSchemaExpression(current.callee.object);
  }
  return current;
}

function computerSchemaShape(program, property) {
  if ((property.key?.name || property.key?.value) !== 'autoCompactEnabled') return null;
  const parent = enclosingNode(program.ast, property, 'ObjectExpression');
  const valueSource = program.text.slice(property.value.start, property.value.end).toLowerCase();
  if (!parent || parent.properties.length < 50 || !valueSource.includes('compact conversation')) return null;
  const root = computerSchemaRoot(property.value);
  if (root?.type === 'Identifier') {
    return {property, parent, direct: true, boolean: root.name, object: root.name, enumeration: root.name};
  }
  if (root?.type !== 'CallExpression' || root.callee?.type !== 'Identifier') return null;
  const objects = new Set(), enumerations = new Set();
  for (const sibling of parent.properties) {
    if (sibling.type !== 'Property') continue;
    const siblingRoot = computerSchemaRoot(sibling.value);
    if (siblingRoot?.type !== 'CallExpression' || siblingRoot.callee?.type !== 'Identifier') continue;
    if (siblingRoot.arguments[0]?.type === 'ObjectExpression') objects.add(siblingRoot.callee.name);
    if (siblingRoot.arguments[0]?.type === 'ArrayExpression' && siblingRoot.arguments[0].elements.length > 0 &&
        siblingRoot.arguments[0].elements.every(item => item?.type === 'Literal' && typeof item.value === 'string')) {
      enumerations.add(siblingRoot.callee.name);
    }
  }
  if (objects.size !== 1 || enumerations.size !== 1) return null;
  return {property, parent, direct: false, boolean: root.callee.name,
    object: [...objects][0], enumeration: [...enumerations][0]};
}

function computerSchemaInsertion(shape, keys) {
  const boolean = shape.direct ? `${shape.boolean}.boolean()` : `${shape.boolean}()`;
  const object = shape.direct ? `${shape.object}.object` : shape.object;
  const enumeration = shape.direct ? `${shape.enumeration}.enum` : shape.enumeration;
  const parts = [];
  if (keys.includes('computerUseEnabled')) {
    parts.push(`computerUseEnabled:${boolean}.optional().describe("Enable computer use MCP server for desktop control (macOS only, default off)")`);
  }
  if (keys.includes('computerUseConfig')) {
    parts.push(`computerUseConfig:${object}({mouseAnimation:${boolean}.optional(),hideBeforeAction:${boolean}.optional(),clipboardGuard:${boolean}.optional(),coordinateMode:${enumeration}(["pixels","normalized_0_100"]).optional()}).optional().describe("Computer use sub-configuration overrides")`);
  }
  return parts.length > 0 ? `,${parts.join(',')}` : '';
}

function analyzeComputerSchema(target, files) {
  const programs = candidatePrograms(target,
    ['autoCompactEnabled', 'Automatically compact conversation', 'compact conversation', 'CC_COMPUTER_SCHEMA']);
  const matches = [];
  for (const program of programs) {
    const properties = findAstNodes(program.ast, node => node.type === 'Property' &&
      (node.key?.name || node.key?.value) === 'autoCompactEnabled');
    for (const property of properties) {
      const shape = computerSchemaShape(program, property);
      if (!shape) continue;
      const keys = shape.parent.properties.map(item => item.key?.name || item.key?.value);
      const enabledCount = keys.filter(key => key === 'computerUseEnabled').length;
      const configCount = keys.filter(key => key === 'computerUseConfig').length;
      if (enabledCount > 1 || configCount > 1) continue;
      const missing = [];
      if (enabledCount === 0) missing.push('computerUseEnabled');
      if (configCount === 0) missing.push('computerUseConfig');
      if (missing.length > 0) {
        const insertion = computerSchemaInsertion(shape, missing);
        const marked = `${reversibleBodyMarker('COMPUTER_SCHEMA', '', insertion)}${insertion}`;
        const beforeProperty = program.text.slice(property.start, property.end);
        const afterProperty = `${beforeProperty}${marked}`;
        const beforeParent = program.text.slice(shape.parent.start, shape.parent.end);
        const offset = property.end - shape.parent.start;
        const afterParent = beforeParent.slice(0, offset) + marked + beforeParent.slice(offset);
        matches.push({relativePath: program.relativePath, start: property.start, end: property.end,
          state: 'before', before: beforeProperty, after: afterProperty});
        addPlannedReplacement(files, program,
          {start: property.start, end: property.end, text: afterProperty, semanticId: 'settings-schema'},
          beforeParent, afterParent);
        continue;
      }
      const marker = /\/\*CC_COMPUTER_SCHEMA:[A-Za-z0-9+/=]*:[a-f0-9]{64}\*\//g;
      const parentSource = program.text.slice(shape.parent.start, shape.parent.end);
      const attributed = [];
      for (const markerMatch of parentSource.matchAll(marker)) {
        const start = shape.parent.start + markerMatch.index;
        for (const insertedKeys of [
          ['computerUseEnabled', 'computerUseConfig'], ['computerUseEnabled'], ['computerUseConfig']]) {
          const insertion = computerSchemaInsertion(shape, insertedKeys);
          const expected = `${reversibleBodyMarker('COMPUTER_SCHEMA', '', insertion)}${insertion}`;
          if (program.text.slice(start, start + expected.length) === expected) {
            const propertySource = program.text.slice(property.start, property.end);
            attributed.push({relativePath: program.relativePath, start: property.start,
              end: start + expected.length, state: 'after', before: propertySource,
              after: `${propertySource}${expected}`});
          }
        }
      }
      if (attributed.length === 1) matches.push(attributed[0]);
      else if (attributed.length === 0) matches.push({relativePath: program.relativePath,
        start: shape.parent.start, end: shape.parent.end, state: 'after', before: '',
        after: parentSource, attributable: false});
    }
  }
  return {programs, matches};
}

function processEnvMember(node, names) {
  return node?.type === 'MemberExpression' && names.includes(node.property?.name || node.property?.value) &&
    node.object?.type === 'MemberExpression' && node.object.object?.name === 'process' &&
    (node.object.property?.name || node.object.property?.value) === 'env';
}

function computerImmediateImportRoute(target, program, localName, binding) {
  const absolute = packageFile(target.packageRoot, program.relativePath);
  for (const declaration of program.ast.body.filter(node => node.type === 'ImportDeclaration' &&
      typeof node.source.value === 'string' && node.source.value.startsWith('.'))) {
    const specifier = declaration.specifiers.find(item => item.local?.name === localName &&
      item.type === 'ImportSpecifier' && item.imported?.name);
    if (!specifier) continue;
    const sourceFile = resolveRelativeModule(target.packageRoot, absolute, declaration.source.value);
    return {sourceFile, sourceRelative: path.relative(target.packageRoot, sourceFile),
      importedName: specifier.imported.name, binding};
  }
  return null;
}

function discoverComputerHelpers(target) {
  const programs = candidatePrograms(target,
    ['DISABLE_AUTO_COMPACT', 'DISABLE_COMPACT', 'autoCompactEnabled']);
  const index = new ModuleIndex(target), envFunctions = [], envUses = [];
  for (const program of programs) {
    const absolute = packageFile(target.packageRoot, program.relativePath);
    for (const fn of findAstNodes(program.ast, node => node.type === 'FunctionDeclaration' && node.id?.name)) {
      if (!memberNamed(fn, 'DISABLE_AUTO_COMPACT') && !memberNamed(fn, 'DISABLE_COMPACT')) continue;
      const calls = findAstNodes(fn, node => node.type === 'CallExpression' &&
        node.callee?.type === 'Identifier' &&
        processEnvMember(node.arguments?.[0], ['DISABLE_AUTO_COMPACT', 'DISABLE_COMPACT']));
      for (const call of calls) {
        if (identifierIsLexicallyShadowed(program.ast, call.callee)) continue;
        try {
          const binding = index.resolveLocal(absolute, call.callee.name);
          envFunctions.push({relativePath: program.relativePath, name: fn.id.name});
          envUses.push({program, localName: call.callee.name, binding,
            route: target.layout === 'split-esm' ?
              computerImmediateImportRoute(target, program, call.callee.name, binding) : null});
        } catch {}
      }
    }
  }
  const settingUses = [];
  for (const program of programs) {
    const absolute = packageFile(target.packageRoot, program.relativePath);
    const localEnvFunctions = envFunctions.filter(item => item.relativePath === program.relativePath).map(item => item.name);
    for (const fn of findAstNodes(program.ast, node => node.type === 'FunctionDeclaration')) {
      const readsDisableEnv = memberNamed(fn, 'DISABLE_AUTO_COMPACT') || memberNamed(fn, 'DISABLE_COMPACT');
      const callsEnvReader = findAstNodes(fn, node => node.type === 'CallExpression' &&
        node.callee?.type === 'Identifier' && localEnvFunctions.includes(node.callee.name) &&
        !identifierIsLexicallyShadowed(program.ast, node.callee)).length > 0;
      if (!readsDisableEnv && !callsEnvReader) continue;
      const calls = findAstNodes(fn, node => node.type === 'CallExpression' &&
        node.callee?.type === 'Identifier' && node.arguments?.[0]?.type === 'Literal' &&
        node.arguments[0].value === 'autoCompactEnabled');
      for (const call of calls) {
        if (identifierIsLexicallyShadowed(program.ast, call.callee)) continue;
        try {
          const binding = index.resolveLocal(absolute, call.callee.name);
          settingUses.push({program, localName: call.callee.name, binding,
            route: target.layout === 'split-esm' ?
              computerImmediateImportRoute(target, program, call.callee.name, binding) : null});
        } catch {}
      }
    }
  }
  const unique = uses => [...new Map(uses.map(use => [bindingKey(use.binding), use])).values()];
  const environments = unique(envUses), settings = unique(settingUses);
  if (environments.length !== 1 || settings.length !== 1) return null;
  if (target.layout === 'split-esm' && (!environments[0].route || !settings[0].route)) return null;
  return {index, environment: environments[0], setting: settings[0], programs};
}

function computerConfigShape(fn) {
  const statements = fn.body?.body;
  if (!statements || statements.length !== 1 || statements[0].type !== 'ReturnStatement') return null;
  const object = statements[0].argument;
  if (object?.type !== 'ObjectExpression' || object.properties.length !== 2) return null;
  const [defaults, feature] = object.properties;
  if (defaults.type !== 'SpreadElement' || defaults.argument?.type !== 'Identifier' ||
      feature.type !== 'SpreadElement' || feature.argument?.type !== 'CallExpression' ||
      feature.argument.callee?.type !== 'Identifier' ||
      feature.argument.arguments?.[0]?.type !== 'Literal' ||
      feature.argument.arguments[0].value !== 'tengu_malort_pedway' ||
      feature.argument.arguments[1]?.name !== defaults.argument.name) return null;
  return {defaults: defaults.argument.name, feature: feature.argument.callee.name};
}

function falseReturn(statement) {
  if (statement?.type !== 'ReturnStatement') return false;
  const value = statement.argument;
  return value?.type === 'Literal' && (value.value === false || value.value === 0) ||
    value?.type === 'UnaryExpression' && value.operator === '!' &&
    value.argument?.type === 'Literal' && value.argument.value === 1;
}

function computerGateShape(fn) {
  const statements = fn.body?.body;
  if (!statements || statements.length < 1 || statements.length > 4) return null;
  for (const statement of statements.slice(0, -1)) {
    const returned = statement.type === 'IfStatement' && !statement.alternate ?
      (statement.consequent?.type === 'BlockStatement' ? statement.consequent.body?.[0] : statement.consequent) : null;
    if (!falseReturn(returned)) return null;
  }
  const value = statements.at(-1)?.type === 'ReturnStatement' ? statements.at(-1).argument : null;
  if (value?.type !== 'LogicalExpression' || value.operator !== '&&' ||
      value.left?.type !== 'CallExpression' || value.left.callee?.type !== 'Identifier' ||
      value.right?.type !== 'MemberExpression' ||
      (value.right.property?.name || value.right.property?.value) !== 'enabled' ||
      value.right.object?.type !== 'CallExpression' || value.right.object.callee?.type !== 'Identifier') return null;
  return {config: value.right.object.callee.name, configCall: value.right.object};
}

function reconstructedComputerFunction(program, fn, markerId) {
  const before = decodeReversibleBody(program.text.slice(fn.body.start, fn.body.end), markerId);
  if (before === null) return null;
  const parameters = fn.params.map(param => program.text.slice(param.start, param.end)).join(',');
  const text = `function __CC_RECONSTRUCT(${parameters})${before}`;
  try {
    const ast = acorn.parse(text, {ecmaVersion: 'latest', sourceType: 'script'});
    return {before, program: {...program, text, ast}, fn: ast.body[0]};
  } catch { return null; }
}

function computerLocalCollision(fn, names) {
  return findAstNodes(fn, node =>
    node.type === 'VariableDeclarator' && node.id?.type === 'Identifier' && names.includes(node.id.name) ||
    node.type === 'Identifier' && fn.params.includes(node) && names.includes(node.name)).length > 0;
}

function computerImportSpecifier(targetFile, sourceFile) {
  let specifier = path.posix.relative(path.posix.dirname(targetFile), sourceFile);
  if (!specifier.startsWith('.')) specifier = `./${specifier}`;
  return specifier;
}

function prepareComputerImports(target, program, requirements, helpers, files, transformations) {
  if (target.layout !== 'split-esm') {
    return {environment: helpers.environment.localName, setting: helpers.setting.localName};
  }
  const definitions = {
    environment: {helper: helpers.environment, alias: '__ccComputerEnvTruthy'},
    setting: {helper: helpers.setting, alias: '__ccComputerReadSetting'},
  };
  const requested = requirements.map(name => ({name, ...definitions[name]}));
  const imports = requested.map(item => {
    const route = item.helper.route;
    const specifier = computerImportSpecifier(program.relativePath, route.sourceRelative);
    return `import{${route.importedName} as ${item.alias}}from${JSON.stringify(specifier)};`;
  }).join('');
  const marker = '/*CC_COMPUTER_IMPORTS*/';
  const prefix = `${marker}${imports}`;
  const markerPositions = [...program.text.matchAll(/\/\*CC_COMPUTER_IMPORTS\*\//g)].map(match => match.index);
  if (markerPositions.length > 0) {
    if (markerPositions.length !== 1 || program.text.slice(markerPositions[0], markerPositions[0] + prefix.length) !== prefix) return null;
    const prefixEnd = markerPositions[0] + prefix.length;
    const shiftedNode = program.ast.body.find(node => node.start >= prefixEnd);
    if (!shiftedNode) return null;
    const shifted = program.text.slice(shiftedNode.start, shiftedNode.end);
    const leading = shifted.match(/^([A-Za-z]+)(\s+)/);
    if (!leading) return null;
    const before = `${leading[1]}${leading[2].slice(0, -1)}${shifted.slice(leading[0].length)}`;
    const after = `${prefix}${shifted}`;
    const index = new ModuleIndex(target), absolute = packageFile(target.packageRoot, program.relativePath);
    for (const item of requested) {
      try {
        if (bindingKey(index.resolveLocal(absolute, item.alias)) !== bindingKey(item.helper.binding)) return null;
      } catch { return null; }
    }
    transformations.push({semanticId: 'computer-helper-imports', relativePath: program.relativePath,
      start: markerPositions[0], state: 'after', before, after});
  } else {
    if (requested.some(item => findAstNodes(program.ast,
      node => node.type === 'Identifier' && node.name === item.alias).length > 0)) return null;
    const first = program.ast.body[0];
    if (!first) return null;
    const before = program.text.slice(first.start, first.end);
    const shifted = before.replace(/^([A-Za-z]+)(\s*)/, (_, keyword, whitespace) =>
      `${keyword}${whitespace} `);
    if (shifted === before) return null;
    const after = `${prefix}${shifted}`;
    addPlannedReplacement(files, program,
      {start: first.start, end: first.end, text: after, semanticId: 'computer-helper-imports'}, before, after);
    transformations.push({semanticId: 'computer-helper-imports', relativePath: program.relativePath,
      start: first.start, state: 'before', before, after});
  }
  return Object.fromEntries(requested.map(item => [item.name, item.alias]));
}

function computerGateBody(program, fn, helpers) {
  const body = program.text.slice(fn.body.start, fn.body.end);
  return `{if(${helpers.environment}(process.env.CLAUDE_CODE_COMPUTER_USE))return!0;` +
    `var __ccComputerSetting=${helpers.setting}("computerUseEnabled",void 0);` +
    `if(__ccComputerSetting.source!=="default")return!!__ccComputerSetting.value;${body.slice(1)}`;
}

function computerConfigBody(shape, setting) {
  return `{var __ccComputerBase={...${shape.defaults},...${shape.feature}("tengu_malort_pedway",${shape.defaults})};` +
    `var __ccComputerOptions=${setting}("computerUseConfig",void 0);` +
    'if(__ccComputerOptions.source!=="default"&&typeof __ccComputerOptions.value==="object"&&__ccComputerOptions.value!==null)' +
    'return{...__ccComputerBase,...__ccComputerOptions.value};return __ccComputerBase}';
}

function analyzeComputerUse(target) {
  const files = new Map(), importTransformations = [];
  const schema = analyzeComputerSchema(target, files);
  const helpers = discoverComputerHelpers(target);
  const configPrograms = candidatePrograms(target, ['tengu_malort_pedway', 'CC_COMPUTER_CONFIG']);
  const rawConfigs = [];
  for (const program of configPrograms) {
    for (const fn of findAstNodes(program.ast, node => node.type === 'FunctionDeclaration' && node.id?.name)) {
      const reconstructed = reconstructedComputerFunction(program, fn, 'COMPUTER_CONFIG');
      const sourceFunction = reconstructed?.fn || fn;
      const shape = computerConfigShape(sourceFunction);
      if (shape) rawConfigs.push({program, fn, sourceFunction, shape,
        state: reconstructed ? 'after' : 'before'});
    }
  }
  const index = new ModuleIndex(target), configBindings = [];
  for (const targetConfig of rawConfigs) {
    try {
      configBindings.push(index.resolveLocal(packageFile(target.packageRoot, targetConfig.program.relativePath),
        targetConfig.fn.id.name));
    } catch {}
  }
  const uniqueConfigBindings = [...new Map(configBindings.map(binding => [bindingKey(binding), binding])).values()];
  const gatePrograms = candidatePrograms(target, ['hipaa', '.enabled', 'CC_COMPUTER_ENABLE']);
  const rawGates = [];
  for (const program of gatePrograms) {
    const absolute = packageFile(target.packageRoot, program.relativePath);
    for (const fn of findAstNodes(program.ast, node => node.type === 'FunctionDeclaration' && node.id?.name)) {
      const reconstructed = reconstructedComputerFunction(program, fn, 'COMPUTER_ENABLE');
      const sourceFunction = reconstructed?.fn || fn;
      const shape = computerGateShape(sourceFunction);
      if (!shape || uniqueConfigBindings.length !== 1) continue;
      const sourceProgram = reconstructed?.program || program;
      if (identifierIsLexicallyShadowed(sourceProgram.ast, shape.configCall.callee)) continue;
      try {
        if (bindingKey(index.resolveLocal(absolute, shape.config)) !== bindingKey(uniqueConfigBindings[0])) continue;
      } catch { continue; }
      rawGates.push({program, fn, sourceProgram, sourceFunction, shape, state: reconstructed ? 'after' : 'before'});
    }
  }

  const requirements = new Map();
  for (const item of rawConfigs) requirements.set(item.program.relativePath, {program: item.program, names: new Set(['setting'])});
  for (const item of rawGates) {
    const current = requirements.get(item.program.relativePath) || {program: item.program, names: new Set()};
    current.names.add('environment');
    current.names.add('setting');
    requirements.set(item.program.relativePath, current);
  }
  const aliases = new Map();
  if (helpers) {
    for (const [relativePath, requirement] of requirements) {
      const prepared = prepareComputerImports(target, requirement.program,
        [...requirement.names].sort(), helpers, files, importTransformations);
      if (prepared) aliases.set(relativePath, prepared);
    }
  }

  const configMatches = [];
  for (const item of rawConfigs) {
    const names = aliases.get(item.program.relativePath);
    if (!names || computerLocalCollision(item.sourceFunction,
      ['__ccComputerBase', '__ccComputerOptions', names.setting])) continue;
    if (item.state === 'before') {
      const modified = computerConfigBody(item.shape, names.setting);
      configMatches.push(bodyPatch(files, item.program, item.fn, 'config-merge', 'COMPUTER_CONFIG', modified));
    } else {
      const match = reconstructedBodyMatch(item.program, item.fn, 'COMPUTER_CONFIG',
        (originalProgram, originalFunction) => {
          const shape = computerConfigShape(originalFunction);
          return shape ? computerConfigBody(shape, names.setting) : null;
        });
      if (match) configMatches.push(match);
    }
  }
  const gateMatches = [];
  for (const item of rawGates) {
    const names = aliases.get(item.program.relativePath);
    if (!names || computerLocalCollision(item.sourceFunction,
      ['__ccComputerSetting', names.environment, names.setting])) continue;
    if (item.state === 'before') {
      gateMatches.push(bodyPatch(files, item.program, item.fn, 'enable-gate', 'COMPUTER_ENABLE',
        computerGateBody(item.program, item.fn, names)));
    } else {
      const match = reconstructedBodyMatch(item.program, item.fn, 'COMPUTER_ENABLE',
        (originalProgram, originalFunction) => computerGateShape(originalFunction) ?
          computerGateBody(originalProgram, originalFunction, names) : null);
      if (match) gateMatches.push(match);
    }
  }
  const semanticTargets = [
    {id: 'settings-schema', expectedCardinality: 1, matches: schema.matches},
    {id: 'enable-gate', expectedCardinality: 1, matches: gateMatches},
    {id: 'config-merge', expectedCardinality: 1, matches: configMatches},
  ];
  const plan = finishSemanticPlan('computer-use', semanticTargets, files, {
    candidateFiles: [...new Set([...schema.programs, ...(helpers?.programs || []), ...configPrograms, ...gatePrograms]
      .map(item => item.relativePath))],
  });
  plan.attribution.transformations.push(...importTransformations);
  return plan;
}

function analyzeContractFixture(target, patchId = '__contract__') {
  if (process.env.CC_PATCH_TESTING !== '1') throw new Error('internal contract analyzer is disabled');
  const allDefinitions = [
    {id: 'alpha', before: 'CC_BEFORE_ALPHA', after: 'CC_AFTER_ALPHA'},
    {id: 'beta', before: 'CC_BEFORE_BETA', after: 'CC_AFTER_BETA'},
    {id: 'gamma', before: 'CC_BEFORE_GAMMA', after: 'CC_AFTER_GAMMA'},
    {id: 'delta', before: 'CC_BEFORE_DELTA', after: 'CC_AFTER_DELTA'},
    {id: 'epsilon', before: 'CC_BEFORE_EPSILON', after: 'CC_AFTER_EPSILON'},
  ];
  const alphaOnly = patchId === '__contract-alpha__' ||
    (process.env.CC_PATCH_TEST_PRODUCTION_IDS === '1' && patchId === 'auto-mode');
  const resourceOnly = patchId === '__contract-resource__' ||
    (process.env.CC_PATCH_TEST_PRODUCTION_IDS === '1' && patchId === 'voice-mode');
  const gammaOnly = process.env.CC_PATCH_TEST_PRODUCTION_IDS === '1' && patchId === 'keybindings';
  const deltaOnly = process.env.CC_PATCH_TEST_PRODUCTION_IDS === '1' && patchId === 'transcript-dialog';
  const epsilonOnly = process.env.CC_PATCH_TEST_PRODUCTION_IDS === '1' && patchId === 'ultracode';
  const definitions = alphaOnly ? allDefinitions.slice(0, 1) : resourceOnly ? allDefinitions.slice(1, 2) :
    gammaOnly ? allDefinitions.slice(2, 3) : deltaOnly ? allDefinitions.slice(3, 4) :
    epsilonOnly ? allDefinitions.slice(4, 5) : allDefinitions.slice(0, 2);
  const sourceType = target.layout === 'split-esm' ? 'module' : 'script';
  const files = new Map();
  const semanticTargets = definitions.map(definition => {
    const matches = [];
    for (const relativePath of packageModulePaths(target.packageRoot)) {
      const text = fs.readFileSync(path.join(target.packageRoot, relativePath), 'utf8');
      matches.push(...tokenMatches(text, definition.before, relativePath, 'before'));
      matches.push(...tokenMatches(text, definition.after, relativePath, 'after'));
    }
    for (const match of matches.filter(item => item.state === 'before')) {
      if (!files.has(match.relativePath)) {
        const text = fs.readFileSync(path.join(target.packageRoot, match.relativePath), 'utf8');
        files.set(match.relativePath, {relativePath: match.relativePath, sourceHash: sha256(text), sourceType, replacements: [], postconditions: []});
      }
      const file = files.get(match.relativePath);
      file.replacements.push({start: match.start, end: match.end, text: definition.after, semanticId: definition.id});
      file.postconditions.push({absent: definition.before, present: definition.after, semanticId: definition.id});
    }
    return {id: definition.id, expectedCardinality: 1, matches};
  });
  const states = semanticTargets.map(targetEntry => targetEntry.matches[0]?.state);
  for (const file of files.values()) {
    const source = fs.readFileSync(path.join(target.packageRoot, file.relativePath), 'utf8');
    if (source.includes('CC_CONTRACT_OVERLAP') && file.replacements.length > 0) {
      const original = file.replacements[0];
      file.replacements.push({start: original.start + 1, end: original.end, text: 'CC_OVERLAP', semanticId: 'overlap-probe'});
    }
    if (source.includes('CC_CONTRACT_INVALID_AST') && file.replacements.length > 0) {
      file.replacements[0].text += '"';
    }
  }
  const entryText = fs.readFileSync(target.entryPath, 'utf8');
  const resources = (alphaOnly || gammaOnly || deltaOnly || epsilonOnly ? [] :
    [...entryText.matchAll(/CC_CONTRACT_RESOURCE:([^\s*]+)/g)])
    .map(match => {
      const [source, destination] = match[1].includes('->') ? match[1].split('->', 2) : [null, match[1]];
      return {kind: 'copy', source, destination, expectedBefore: 'absent-or-baselined'};
    });
  return {
    patchId,
    state: states.every(state => state === 'after') ? 'already-patched' : 'needs-patch',
    semanticTargets,
    files: [...files.values()],
    resources,
    attribution: {
      transformations: definitions.flatMap((definition, index) =>
        semanticTargets[index].matches.map(match => ({
          semanticId: definition.id,
          relativePath: match.relativePath,
          start: match.start,
          state: match.state,
          before: definition.before,
          after: definition.after,
        }))),
    },
    diagnostics: [],
  };
}

function renderReplacements(source, replacements) {
  let previousStart = source.length;
  let rendered = source;
  for (const replacement of [...replacements].sort((a, b) => b.start - a.start)) {
    if (!Number.isInteger(replacement.start) || !Number.isInteger(replacement.end) || replacement.start < 0 || replacement.end > source.length || replacement.start >= replacement.end) {
      throw new Error(`invalid replacement range: ${replacement.start}:${replacement.end}`);
    }
    if (replacement.end > previousStart) throw new Error(`overlapping replacements at ${replacement.start}:${replacement.end}`);
    rendered = rendered.slice(0, replacement.start) + replacement.text + rendered.slice(replacement.end);
    previousStart = replacement.start;
  }
  return rendered;
}

function validatePlan(target, plan) {
  for (const semanticTarget of plan.semanticTargets) {
    const count = semanticTarget.matches.length;
    if (count === 0) {
      console.error(`MISSING_TARGET:${semanticTarget.id}`);
      for (const file of (plan.diagnostics && plan.diagnostics.candidateFiles) || []) {
        console.error(`CANDIDATE_FILE:${JSON.stringify(file)}`);
      }
      throw new Error(`missing semantic target: ${semanticTarget.id}`);
    }
    if (count !== semanticTarget.expectedCardinality) {
      console.error(`AMBIGUOUS_TARGET:${semanticTarget.id}:${count}`);
      for (const match of semanticTarget.matches) {
        console.error(`AMBIGUOUS_FILE:${JSON.stringify(match.relativePath)}`);
      }
      throw new Error(`ambiguous semantic target: ${semanticTarget.id}`);
    }
  }

  const renderedFiles = [];
  for (const file of plan.files) {
    const absolute = packageFile(target.packageRoot, file.relativePath);
    const source = fs.readFileSync(absolute, 'utf8');
    if (sha256(source) !== file.sourceHash) throw new Error(`source changed during analysis: ${file.relativePath}`);
    const rendered = renderReplacements(source, file.replacements);
    try {
      acorn.parse(rendered, {ecmaVersion: 'latest', sourceType: file.sourceType, allowHashBang: true});
    } catch (error) {
      throw new Error(`post-patch parse failed in ${file.relativePath}: ${error.message}`);
    }
    for (const condition of file.postconditions) {
      if (rendered.includes(condition.absent) || !rendered.includes(condition.present)) {
        throw new Error(`postcondition failed for ${condition.semanticId} in ${file.relativePath}`);
      }
    }
    renderedFiles.push({...file, absolute, rendered});
  }
  return renderedFiles;
}

function analyzerForPatch(patchId) {
  if (process.env.CC_PATCH_TESTING === '1' &&
      ['__contract__', '__contract-alpha__', '__contract-resource__'].includes(patchId)) {
    return target => analyzeContractFixture(target, patchId);
  }
  if (process.env.CC_PATCH_TESTING === '1' && process.env.CC_PATCH_TEST_PRODUCTION_IDS === '1' &&
      ['auto-mode', 'keybindings', 'transcript-dialog', 'ultracode', 'voice-mode'].includes(patchId)) {
    return target => analyzeContractFixture(target, patchId);
  }
  if (process.env.CC_PATCH_TESTING === '1' && process.env.CC_PATCH_TEST_PRODUCTION_IDS === '1' &&
      ['context-limit', 'computer-use'].includes(patchId)) return null;
  if (patchId === 'auto-mode') return analyzeAutoMode;
  if (patchId === 'keybindings') return analyzeKeybindings;
  if (patchId === 'transcript-dialog') return analyzeTranscriptDialog;
  if (patchId === 'ultracode') return analyzeUltracode;
  if (patchId === 'voice-mode') return analyzeVoiceMode;
  if (patchId === 'context-limit') return analyzeContextLimit;
  if (patchId === 'computer-use') return analyzeComputerUse;
  return null;
}

function registeredPatchIdsFor(patchId) {
  if (patchId === '__contract__') return [patchId];
  const internalPatchIds = ['__contract-alpha__', '__contract-resource__'];
  const candidates = internalPatchIds.includes(patchId) ? internalPatchIds : patchIds;
  return candidates.filter(candidate => analyzerForPatch(candidate));
}

function analyzePatch(target, patchId, options = {}) {
  const analyzer = analyzerForPatch(patchId);
  if (analyzer) return analyzer(target, options);
  throw new Error(`unsupported patch id: ${patchId}`);
}

function baselineDirectory(target) {
  return path.join(target.packageRoot, '.cc-patch-manager-baseline');
}

function buildIdentityFromText(text) {
  return text.slice(0, 4096).match(/(?:Version|VERSION|build(?:Date)?)\s*[:=]\s*["']?([^"'\s,;]+)/i)?.[1] || '';
}

function lstatIfPresent(candidate) {
  try {
    return fs.lstatSync(candidate);
  } catch (error) {
    if (error.code === 'ENOENT') return null;
    throw error;
  }
}

function assertManagedPathSafe(packageRoot, candidate) {
  const absolute = path.resolve(candidate);
  if (!insideRoot(packageRoot, absolute)) throw new Error(`managed path escapes package root: ${candidate}`);
  const relative = path.relative(packageRoot, absolute);
  let cursor = packageRoot;
  for (const part of relative.split(path.sep).filter(Boolean)) {
    cursor = path.join(cursor, part);
    const stat = lstatIfPresent(cursor);
    if (!stat) continue;
    if (stat.isSymbolicLink()) throw new Error(`managed path contains symlink: ${cursor}`);
    if (!insideRoot(packageRoot, fs.realpathSync(cursor))) throw new Error(`managed path resolves outside package root: ${cursor}`);
  }
  return absolute;
}

function ensureManagedDirectory(packageRoot, directory) {
  assertManagedPathSafe(packageRoot, directory);
  fs.mkdirSync(directory, {recursive: true});
  assertManagedPathSafe(packageRoot, directory);
  if (!fs.statSync(directory).isDirectory()) throw new Error(`managed directory is not a directory: ${directory}`);
  let cursor = directory;
  while (insideRoot(packageRoot, cursor)) {
    fsyncDirectory(cursor);
    if (cursor === packageRoot) break;
    cursor = path.dirname(cursor);
  }
}

function fsyncFile(file) {
  const descriptor = fs.openSync(file, 'r');
  try { fs.fsyncSync(descriptor); } finally { fs.closeSync(descriptor); }
}

function fsyncDirectory(directory) {
  const descriptor = fs.openSync(directory, 'r');
  try { fs.fsyncSync(descriptor); } finally { fs.closeSync(descriptor); }
}

function writeManagedFileAtomic(packageRoot, destination, bytes, mode) {
  const directory = path.dirname(destination);
  ensureManagedDirectory(packageRoot, directory);
  assertManagedPathSafe(packageRoot, destination);
  if (lstatIfPresent(destination)) throw new Error(`untracked baseline mirror already exists: ${destination}`);
  const temporary = path.join(directory, `.write-${process.pid}-${crypto.randomBytes(6).toString('hex')}.tmp`);
  try {
    assertManagedPathSafe(packageRoot, temporary);
    fs.writeFileSync(temporary, bytes, {mode, flag: 'wx'});
    fs.chmodSync(temporary, mode);
    fsyncFile(temporary);
    fs.renameSync(temporary, destination);
    fsyncDirectory(directory);
    assertManagedPathSafe(packageRoot, destination);
  } catch (error) {
    try { fs.unlinkSync(temporary); } catch (cleanupError) {
      if (cleanupError.code !== 'ENOENT') throw cleanupError;
    }
    throw error;
  }
}

function readBaselineManifest(target) {
  const manifestPath = path.join(baselineDirectory(target), 'manifest.json');
  if (!fs.existsSync(manifestPath)) return null;
  try {
    return JSON.parse(fs.readFileSync(manifestPath, 'utf8'));
  } catch (error) {
    throw new Error(`invalid baseline manifest: ${error.message}`);
  }
}

function assertBaselineIdentity(manifest, target) {
  const expected = manifest.package || {};
  const entryPath = path.relative(target.packageRoot, target.entryPath);
  if (expected.name !== target.packageName || expected.version !== target.packageVersion ||
      expected.layout !== target.layout || expected.identityFingerprint !== target.identityFingerprint ||
      expected.entryPath !== entryPath || !/^[a-f0-9]{64}$/.test(expected.entrySha256 || '') ||
      manifest.files?.[entryPath]?.sha256 !== expected.entrySha256) {
    throw new Error('stale baseline package identity');
  }
}

function assertBaselineMirrors(manifest, target, root = baselineDirectory(target)) {
  for (const [relativePath, item] of Object.entries(manifest.files || {})) {
    if (!item.existed) continue;
    const mirror = packageFile(root, item.mirror);
    const actual = sha256(fs.readFileSync(mirror));
    if (actual !== item.sha256) throw new Error(`corrupt baseline mirror: ${relativePath}`);
  }
}

const knownPatchSentinels = [
  {patchId: 'auto-mode', value: 'CLAUDE_CLASSIFIER_MODEL'},
  {patchId: 'keybindings', value: '"ctrl+c":"app:exit"'},
  {patchId: 'voice-mode', value: 'COMETIX_ASR_'},
  {patchId: 'voice-mode', value: 'COMETIX_VOICE_'},
  {patchId: 'voice-mode', value: 'cometix-asr voice adapter'},
  {patchId: 'context-limit', value: 'CLAUDE_CODE_CONTEXT_LIMIT'},
  {patchId: 'computer-use', value: 'computerUseEnabled'},
  {patchId: 'computer-use', value: 'computerUseConfig'},
  {patchId: 'transcript-dialog', value: 'CC_DIALOG_FIX_'},
  {patchId: 'ultracode', value: 'CC_ULTRACODE_'},
];

function findUntrustedPatchSentinel(target) {
  for (const relativePath of packageModulePaths(target.packageRoot)) {
    const text = fs.readFileSync(path.join(target.packageRoot, relativePath), 'utf8');
    for (const sentinel of knownPatchSentinels) {
      if (text.includes(sentinel.value)) return {...sentinel, relativePath};
    }
    const unknown = text.match(/\bCC_[A-Z0-9_]*(?:PATCH|PATCHED)\b/);
    if (unknown) return {patchId: 'unknown', value: unknown[0], relativePath};
  }
  return null;
}

function normalizeKnownPatchState(text, plan, relativePath) {
  let normalized = text;
  const transformations = (plan.attribution?.transformations || [])
    .filter(transformation => transformation.relativePath === relativePath && transformation.state === 'after')
    .sort((left, right) => right.start - left.start);
  let previousStart = text.length;
  for (const transformation of transformations) {
    if (!transformation.before || !transformation.after || transformation.before === transformation.after ||
        !Number.isInteger(transformation.start) || transformation.start < 0 ||
        transformation.start + transformation.after.length > text.length ||
        transformation.start + transformation.after.length > previousStart ||
        text.slice(transformation.start, transformation.start + transformation.after.length) !== transformation.after) {
      throw new Error(`invalid attribution transformation: ${transformation.semanticId || 'unknown'}`);
    }
    normalized = normalized.slice(0, transformation.start) + transformation.before +
      normalized.slice(transformation.start + transformation.after.length);
    previousStart = transformation.start;
  }
  return normalized;
}

function assertManagedFilesAttributable(manifest, target, plan) {
  const root = baselineDirectory(target);
  for (const [relativePath, item] of Object.entries(manifest.files || {})) {
    const absolute = path.resolve(target.packageRoot, relativePath);
    if (!insideRoot(target.packageRoot, absolute) || relativePath.startsWith('..') || path.isAbsolute(relativePath)) {
      throw new Error(`baseline path escapes package root: ${relativePath}`);
    }
    assertManagedPathSafe(target.packageRoot, absolute);
    const stat = lstatIfPresent(absolute);
    const resource = (plan.resources || []).find(candidate => candidate.destination === relativePath);
    if (resource && stat?.isFile() && !stat.isSymbolicLink()) {
      const currentHash = sha256(fs.readFileSync(absolute)), currentMode = stat.mode & 0o777;
      if (item.patchSha256 && currentHash === item.patchSha256 && currentMode === item.patchMode) continue;
      if (!item.patchSha256 && resource.sourceAvailable !== false) {
        const source = resourceSourcePath(target, {...resource, patchId: plan.patchId});
        const sourceStat = lstatIfPresent(source);
        if (sourceStat?.isFile() && !sourceStat.isSymbolicLink() &&
            currentHash === sha256(fs.readFileSync(source)) && currentMode === (sourceStat.mode & 0o777)) continue;
      }
    }
    if (!item.existed) {
      if (!stat) continue;
      throw new Error(`managed resource cannot be attributed to known patch state: ${relativePath}`);
    }
    if (!stat || !stat.isFile()) throw new Error(`managed file no longer matches baseline: ${relativePath}`);
    assertManagedPathSafe(target.packageRoot, absolute);
    const current = fs.readFileSync(absolute);
    if (sha256(current) === item.sha256) continue;
    const mirror = fs.readFileSync(packageFile(root, item.mirror));
    const normalized = normalizeKnownPatchState(current.toString('utf8'), plan, relativePath);
    if (sha256(Buffer.from(normalized)) !== sha256(mirror)) {
      throw new Error(`managed file cannot be attributed to baseline or known patch state: ${relativePath}`);
    }
  }
}

function attributionPlanForTarget(target, plan) {
  const relatedPatchIds = registeredPatchIdsFor(plan.patchId);
  if (relatedPatchIds.length < 2) return plan;
  const relatedPlans = relatedPatchIds.map(patchId => analyzePatch(target, patchId));
  return {
    attribution: {
      transformations: relatedPlans.flatMap(relatedPlan => relatedPlan.attribution?.transformations || []),
    },
    resources: relatedPlans.flatMap(relatedPlan => relatedPlan.resources || []),
  };
}

function writeManifestAtomic(target, manifest, root = baselineDirectory(target)) {
  ensureManagedDirectory(target.packageRoot, root);
  const manifestPath = path.join(root, 'manifest.json');
  const temporary = path.join(root, `.manifest-${process.pid}-${crypto.randomBytes(6).toString('hex')}.tmp`);
  assertManagedPathSafe(target.packageRoot, manifestPath);
  assertManagedPathSafe(target.packageRoot, temporary);
  try {
    fs.writeFileSync(temporary, `${JSON.stringify(manifest, null, 2)}\n`, {mode: 0o600, flag: 'wx'});
    fsyncFile(temporary);
    fs.renameSync(temporary, manifestPath);
    fsyncDirectory(root);
    assertManagedPathSafe(target.packageRoot, manifestPath);
    return manifestPath;
  } catch (error) {
    try { fs.unlinkSync(temporary); fsyncDirectory(root); } catch (cleanupError) {
      if (cleanupError.code !== 'ENOENT') throw cleanupError;
    }
    throw error;
  }
}

function migrateLegacyBaseline(target) {
  if (target.layout !== 'single-cjs') return null;
  const legacyPath = `${target.entryPath}.cc-patch-baseline`;
  const legacyStat = lstatIfPresent(legacyPath);
  if (!legacyStat) return null;
  if (!legacyStat.isFile() || legacyStat.isSymbolicLink()) throw new Error(`legacy baseline is not a regular file: ${legacyPath}`);
  assertManagedPathSafe(target.packageRoot, legacyPath);

  const legacyBytes = fs.readFileSync(legacyPath);
  const currentBytes = fs.readFileSync(target.entryPath);
  const legacyText = legacyBytes.toString('utf8');
  try {
    const ast = acorn.parse(legacyText.replace(/^#![^\n]*(?:\n|$)/, ''), {
      ecmaVersion: 'latest', sourceType: 'script', allowHashBang: true,
    });
    if (!hasCommonJsShape(ast)) throw new Error('legacy baseline has no CommonJS entry shape');
  } catch (error) {
    throw new Error(`invalid legacy baseline: ${error.message}`);
  }
  for (const sentinel of knownPatchSentinels) {
    if (legacyText.includes(sentinel.value)) throw new Error(`legacy baseline contains patch sentinel: ${sentinel.value}`);
  }
  if (/\bCC_[A-Z0-9_]*(?:PATCH|PATCHED)\b/.test(legacyText)) {
    throw new Error('legacy baseline contains an unknown patch sentinel');
  }

  if (!legacyBytes.equals(currentBytes)) {
    const legacyBuild = buildIdentityFromText(legacyText);
    const currentBuild = buildIdentityFromText(currentBytes.toString('utf8'));
    if (!legacyBuild || legacyBuild !== currentBuild || legacyBuild !== target.packageVersion) {
      throw new Error('legacy baseline build identity does not match current package');
    }
  }

  const finalRoot = baselineDirectory(target);
  assertManagedPathSafe(target.packageRoot, finalRoot);
  if (lstatIfPresent(finalRoot)) throw new Error(`untrusted baseline path already exists: ${finalRoot}`);
  const stagingRoot = path.join(target.packageRoot, `.cc-patch-manager-baseline.stage-${process.pid}-${crypto.randomBytes(6).toString('hex')}`);
  const entryPath = path.relative(target.packageRoot, target.entryPath);
  const entryHash = sha256(legacyBytes);
  const mirrorRelative = path.join('files', entryPath);
  const manifest = {
    schemaVersion: 1,
    package: {name: target.packageName, version: target.packageVersion, layout: target.layout,
      identityFingerprint: target.identityFingerprint, entryPath, entrySha256: entryHash},
    createdAt: new Date().toISOString(),
    managerVersion: '1.0.0',
    migratedFrom: path.basename(legacyPath),
    files: {
      [entryPath]: {type: 'file', existed: true, sha256: entryHash,
        mode: legacyStat.mode & 0o777, mirror: mirrorRelative},
    },
    createdDirectories: [],
  };
  try {
    writeManagedFileAtomic(target.packageRoot, path.join(stagingRoot, mirrorRelative), legacyBytes, legacyStat.mode & 0o777);
    writeManifestAtomic(target, manifest, stagingRoot);
    assertBaselineMirrors(manifest, target, stagingRoot);
    if (lstatIfPresent(finalRoot)) throw new Error(`untrusted baseline path already exists: ${finalRoot}`);
    fs.renameSync(stagingRoot, finalRoot);
    fsyncDirectory(target.packageRoot);
    assertManagedPathSafe(target.packageRoot, finalRoot);
    return path.join(finalRoot, 'manifest.json');
  } catch (error) {
    fs.rmSync(stagingRoot, {recursive: true, force: true});
    throw error;
  }
}

function managedDestination(target, relativePath) {
  const absolute = path.resolve(target.packageRoot, relativePath);
  if (!insideRoot(target.packageRoot, absolute) || relativePath.startsWith('..') || path.isAbsolute(relativePath)) {
    throw new Error(`transaction path escapes package root: ${relativePath}`);
  }
  assertManagedPathSafe(target.packageRoot, absolute);
  const relativeParts = relativePath.split(/[\\/]/);
  if (relativeParts.includes('.cc-patch-manager-baseline') ||
      relativeParts.some(part => part.startsWith('.cc-patch-manager-transaction'))) {
    throw new Error(`transaction path is reserved: ${relativePath}`);
  }
  return absolute;
}

function resourceSourcePath(target, resource) {
  if (resource.sourceKind !== 'voice-asset') return managedDestination(target, resource.source);
  if (resource.kind !== 'copy' || resource.patchId && resource.patchId !== 'voice-mode' ||
      !path.isAbsolute(resource.source)) throw new Error('invalid VoiceMode resource operation');
  const configured = process.env.CC_PATCH_VOICE_ASSET_SOURCE;
  if (!configured) throw new Error('VoiceMode resource source is not configured');
  const rootStat = lstatIfPresent(configured);
  if (!rootStat?.isDirectory() || rootStat.isSymbolicLink()) {
    throw new Error(`VoiceMode resource source directory is not safe: ${configured}`);
  }
  const root = fs.realpathSync(configured), name = path.basename(resource.source);
  if (!['index.js', 'index.d.ts', 'package.json', 'libcometix-asr.darwin-arm64.node'].includes(name)) {
    throw new Error(`VoiceMode resource source escapes configured directory: ${resource.source}`);
  }
  const expected = path.join(root, name), sourceStat = lstatIfPresent(expected);
  if (resource.source !== expected || !sourceStat?.isFile() || sourceStat.isSymbolicLink() ||
      fs.realpathSync(expected) !== expected) {
    throw new Error(`VoiceMode resource source is not a safe regular file: ${name}`);
  }
  return expected;
}

function transactionOperations(target, plan, renderedFiles) {
  const operations = renderedFiles.map(file => ({
    kind: 'write',
    relativePath: file.relativePath,
    destination: managedDestination(target, file.relativePath),
    bytes: Buffer.from(file.rendered),
    mode: fs.statSync(file.absolute).mode & 0o777,
    expectedBeforeHash: file.sourceHash,
  }));
  for (const resource of plan.resources || []) {
    if (resource.kind !== 'copy' || !resource.source) throw new Error(`unsupported resource operation: ${resource.kind || 'missing'}`);
    const source = resourceSourcePath(target, {...resource, patchId: plan.patchId});
    const sourceStat = lstatIfPresent(source);
    if (!sourceStat || !sourceStat.isFile()) throw new Error(`resource source is not a regular file: ${resource.source}`);
    const sourceBytes = fs.readFileSync(source);
    operations.push({
      kind: 'copy',
      relativePath: resource.destination,
      destination: managedDestination(target, resource.destination),
      source,
      sourceRelativePath: resource.sourceKind === 'voice-asset' ? path.basename(source) : resource.source,
      expectedSourceHash: sha256(sourceBytes),
      expectedSourceMode: sourceStat.mode & 0o777,
      bytes: sourceBytes,
      mode: sourceStat.mode & 0o777,
    });
  }
  const destinations = new Set();
  for (const operation of operations) {
    if (destinations.has(operation.destination)) throw new Error(`duplicate transaction destination: ${operation.relativePath}`);
    destinations.add(operation.destination);
    const current = lstatIfPresent(operation.destination);
    if (current && !current.isFile()) throw new Error(`transaction destination is not a regular file: ${operation.relativePath}`);
    if (operation.kind === 'copy') {
      operation.expectedDestinationExisted = Boolean(current);
      if (current) {
        operation.expectedDestinationHash = sha256(fs.readFileSync(operation.destination));
        operation.expectedDestinationMode = current.mode & 0o777;
      }
    }
  }
  return operations;
}

function missingParentDirectories(packageRoot, destination) {
  const relative = path.relative(packageRoot, path.dirname(destination));
  const missing = [];
  let cursor = packageRoot;
  for (const part of relative.split(path.sep).filter(Boolean)) {
    cursor = path.join(cursor, part);
    const stat = lstatIfPresent(cursor);
    if (!stat) missing.push(cursor);
    else if (!stat.isDirectory() || stat.isSymbolicLink()) throw new Error(`transaction parent is not a safe directory: ${cursor}`);
  }
  return missing;
}

function replaceFileAtomic(packageRoot, destination, bytes, mode) {
  assertManagedPathSafe(packageRoot, destination);
  const temporary = path.join(path.dirname(destination), `.cc-patch-manager-write-${process.pid}-${crypto.randomBytes(6).toString('hex')}`);
  try {
    fs.writeFileSync(temporary, bytes, {mode, flag: 'wx'});
    fs.chmodSync(temporary, mode);
    fsyncFile(temporary);
    fs.renameSync(temporary, destination);
    fsyncDirectory(path.dirname(destination));
    assertManagedPathSafe(packageRoot, destination);
  } catch (error) {
    try { fs.unlinkSync(temporary); fsyncDirectory(path.dirname(temporary)); } catch (cleanupError) {
      if (cleanupError.code !== 'ENOENT') throw cleanupError;
    }
    throw error;
  }
}

function transactionTargetIdentity(target, manifest) {
  return {
    name: target.packageName,
    version: target.packageVersion,
    layout: target.layout,
    identityFingerprint: target.identityFingerprint,
    entrySha256: manifest.package.entrySha256,
  };
}

function classifyPreparedTransactionState(state) {
  const current = lstatIfPresent(state.destination);
  if (!current) {
    if (!state.operation.existed) return 'before';
    return state.operation.afterExisted === false ? 'after' : 'unknown';
  }
  if (!current.isFile() || current.isSymbolicLink()) return 'unknown';
  const currentHash = sha256(fs.readFileSync(state.destination));
  const currentMode = current.mode & 0o777;
  if (state.operation.existed && currentHash === state.operation.sha256 && currentMode === state.operation.mode) {
    return 'before';
  }
  if (state.operation.afterExisted !== false &&
      currentHash === state.operation.afterSha256 && currentMode === state.operation.afterMode) return 'after';
  return 'unknown';
}

function rollbackPreparedTransaction(target, states, createdDirectories) {
  const classified = states.map(state => ({state, status: classifyPreparedTransactionState(state)}));
  const unknown = classified.find(item => item.status === 'unknown');
  if (unknown) throw new Error(`transaction destination changed independently: ${unknown.state.operation.relativePath}`);

  if (process.env.CC_PATCH_TESTING === '1' && process.env.CC_PATCH_TEST_MUTATE_AFTER_RECOVERY_CLASSIFICATION) {
    const relativePath = process.env.CC_PATCH_TEST_MUTATE_AFTER_RECOVERY_CLASSIFICATION;
    const selected = states.find(state => state.operation.relativePath === relativePath);
    if (!selected) throw new Error(`unknown recovery mutation target: ${relativePath}`);
    fs.appendFileSync(selected.destination, '\n// CC_TEST_EXTERNAL_MUTATION\n');
  }
  const changed = classified.find(item => classifyPreparedTransactionState(item.state) !== item.status);
  if (changed) throw new Error(`transaction destination changed during recovery: ${changed.state.operation.relativePath}`);

  for (const {state, status} of [...classified].reverse()) {
    if (classifyPreparedTransactionState(state) !== status) {
      throw new Error(`transaction destination changed during recovery: ${state.operation.relativePath}`);
    }
    if (status === 'before') continue;
    if (state.operation.existed) {
      replaceFileAtomic(target.packageRoot, state.destination, state.bytes, state.operation.mode);
    } else {
      fs.unlinkSync(state.destination);
      fsyncDirectory(path.dirname(state.destination));
    }
  }
  for (const directory of [...createdDirectories].sort((left, right) => right.length - left.length)) {
    try { fs.rmdirSync(directory); fsyncDirectory(path.dirname(directory)); } catch (error) {
      if (error.code !== 'ENOENT' && error.code !== 'ENOTEMPTY') throw error;
    }
  }
  for (const state of states) {
    if (classifyPreparedTransactionState(state) !== 'before') {
      throw new Error(`transaction recovery verification failed: ${state.operation.relativePath}`);
    }
  }
}

function restoreTransactionDirectory(target, txRoot) {
  assertManagedPathSafe(target.packageRoot, txRoot);
  const journalPath = path.join(txRoot, 'transaction.json');
  assertManagedPathSafe(target.packageRoot, journalPath);
  let journal;
  try {
    journal = JSON.parse(fs.readFileSync(journalPath, 'utf8'));
  } catch (error) {
    throw new Error(`invalid transaction journal ${path.basename(txRoot)}: ${error.message}`);
  }
  if (journal.schemaVersion !== 1 || !['prepared', 'committed'].includes(journal.state) ||
      !journal.target || !Array.isArray(journal.operations) || !Array.isArray(journal.createdDirectories)) {
    throw new Error(`invalid transaction journal contract: ${path.basename(txRoot)}`);
  }
  const manifest = readBaselineManifest(target);
  if (!manifest) throw new Error(`transaction has no trusted baseline: ${path.basename(txRoot)}`);
  assertBaselineIdentity(manifest, target);
  assertBaselineMirrors(manifest, target);
  const expectedTarget = transactionTargetIdentity(target, manifest);
  if (Object.keys(expectedTarget).some(key => journal.target[key] !== expectedTarget[key])) {
    throw new Error(`transaction target identity mismatch: ${path.basename(txRoot)}`);
  }

  const seenPaths = new Set();
  const states = journal.operations.map((operation, index) => {
    const afterExisted = operation?.afterExisted !== false;
    if (!operation || typeof operation.relativePath !== 'string' || typeof operation.existed !== 'boolean' ||
        (afterExisted && (!/^[a-f0-9]{64}$/.test(operation.afterSha256 || '') || !Number.isInteger(operation.afterMode)))) {
      throw new Error(`invalid transaction operation ${index}: ${path.basename(txRoot)}`);
    }
    if (!Object.prototype.hasOwnProperty.call(manifest.files || {}, operation.relativePath) || seenPaths.has(operation.relativePath)) {
      throw new Error(`transaction path is not uniquely managed by baseline: ${operation.relativePath}`);
    }
    seenPaths.add(operation.relativePath);
    const destination = managedDestination(target, operation.relativePath);
    if (!operation.existed) return {operation, destination, bytes: null};
    if (!Number.isInteger(operation.mode) || !/^[a-f0-9]{64}$/.test(operation.sha256 || '')) {
      throw new Error(`invalid transaction snapshot metadata: ${operation.relativePath}`);
    }
    const snapshotPath = path.join(txRoot, 'before', String(index));
    assertManagedPathSafe(target.packageRoot, snapshotPath);
    const bytes = fs.readFileSync(snapshotPath);
    if (sha256(bytes) !== operation.sha256) throw new Error(`corrupt transaction snapshot: ${operation.relativePath}`);
    return {operation, destination, bytes};
  });
  const createdDirectories = journal.createdDirectories.map(relativeDirectory => {
    if (typeof relativeDirectory !== 'string') throw new Error(`invalid transaction directory: ${relativeDirectory}`);
    const directory = path.resolve(target.packageRoot, relativeDirectory);
    if (!insideRoot(target.packageRoot, directory) || path.isAbsolute(relativeDirectory) || relativeDirectory.startsWith('..')) {
      throw new Error(`transaction directory escapes package root: ${relativeDirectory}`);
    }
    return directory;
  });

  if (journal.state === 'committed') {
    for (const state of states) {
      const current = lstatIfPresent(state.destination);
      const valid = state.operation.afterExisted === false ? !current :
        current && current.isFile() && sha256(fs.readFileSync(state.destination)) === state.operation.afterSha256 &&
          (current.mode & 0o777) === state.operation.afterMode;
      if (!valid) {
        throw new Error(`committed transaction verification failed: ${state.operation.relativePath}`);
      }
    }
    return;
  }

  rollbackPreparedTransaction(target, states, createdDirectories);
}

function incompleteTransactionEntries(target) {
  return fs.readdirSync(target.packageRoot, {withFileTypes: true})
    .filter(entry => entry.name.startsWith('.cc-patch-manager-transaction-'))
    .sort((left, right) => left.name.localeCompare(right.name));
}

function cleanupBaselineStagingDirectories(target) {
  const entries = fs.readdirSync(target.packageRoot, {withFileTypes: true})
    .filter(entry => entry.name.startsWith('.cc-patch-manager-baseline.stage-'));
  for (const entry of entries) {
    const stagingRoot = path.join(target.packageRoot, entry.name);
    const stat = fs.lstatSync(stagingRoot);
    if (!entry.isDirectory() || stat.isSymbolicLink()) throw new Error(`unsafe baseline staging path: ${entry.name}`);
    fs.rmSync(stagingRoot, {recursive: true, force: true});
    fsyncDirectory(target.packageRoot);
  }
  return entries.length;
}

function recoverIncompleteTransactions(target) {
  const transactions = incompleteTransactionEntries(target);
  for (const entry of transactions) {
    const txRoot = path.join(target.packageRoot, entry.name);
    const stat = fs.lstatSync(txRoot);
    if (!entry.isDirectory() || stat.isSymbolicLink()) throw new Error(`unsafe transaction journal path: ${entry.name}`);
    restoreTransactionDirectory(target, txRoot);
    fs.rmSync(txRoot, {recursive: true, force: true});
    fsyncDirectory(target.packageRoot);
  }
  return transactions.length;
}

function commitTransaction(target, operations) {
  const txRoot = path.join(target.packageRoot, `.cc-patch-manager-transaction-${process.pid}-${crypto.randomBytes(6).toString('hex')}`);
  const snapshots = [];
  const createdDirectories = [];
  let committed = 0;
  let preserveTransaction = false;
  let journal = null;
  try {
    const manifest = readBaselineManifest(target);
    if (!manifest) throw new Error('transaction requires a trusted baseline');
    assertBaselineIdentity(manifest, target);
    assertBaselineMirrors(manifest, target);
    for (const operation of operations) {
      if (!Object.prototype.hasOwnProperty.call(manifest.files || {}, operation.relativePath)) {
        throw new Error(`transaction destination is not managed by baseline: ${operation.relativePath}`);
      }
      if (operation.source) {
        const sourceStat = lstatIfPresent(operation.source);
        if (!sourceStat || !sourceStat.isFile() ||
            sha256(fs.readFileSync(operation.source)) !== operation.expectedSourceHash ||
            (sourceStat.mode & 0o777) !== operation.expectedSourceMode) {
          throw new Error(`resource source changed after analysis: ${operation.sourceRelativePath}`);
        }
      }
      if (operation.kind === 'copy') {
        const destinationStat = lstatIfPresent(operation.destination);
        if (Boolean(destinationStat) !== operation.expectedDestinationExisted ||
            (destinationStat && (!destinationStat.isFile() ||
              sha256(fs.readFileSync(operation.destination)) !== operation.expectedDestinationHash ||
              (destinationStat.mode & 0o777) !== operation.expectedDestinationMode))) {
          throw new Error(`resource destination changed after analysis: ${operation.relativePath}`);
        }
      }
      if (operation.expectedBeforeHash) {
        const beforeStat = lstatIfPresent(operation.destination);
        if (!beforeStat || !beforeStat.isFile() ||
            sha256(fs.readFileSync(operation.destination)) !== operation.expectedBeforeHash ||
            (Number.isInteger(operation.expectedBeforeMode) &&
              (beforeStat.mode & 0o777) !== operation.expectedBeforeMode)) {
          throw new Error(`transaction source changed after analysis: ${operation.relativePath}`);
        }
      }
    }
    if (process.env.CC_PATCH_TESTING === '1' && process.env.CC_PATCH_TEST_MUTATE_AFTER_PREFLIGHT) {
      const mutated = managedDestination(target, process.env.CC_PATCH_TEST_MUTATE_AFTER_PREFLIGHT);
      fs.appendFileSync(mutated, '\n// CC_TEST_EXTERNAL_MUTATION\n');
    }
    ensureManagedDirectory(target.packageRoot, txRoot);
    for (const [index, operation] of operations.entries()) {
      if (operation.source) {
        const sourceStat = lstatIfPresent(operation.source);
        if (!sourceStat || !sourceStat.isFile()) {
          throw new Error(`resource source changed after analysis: ${operation.sourceRelativePath}`);
        }
        const sourceBytes = fs.readFileSync(operation.source);
        if (sha256(sourceBytes) !== operation.expectedSourceHash ||
            (sourceStat.mode & 0o777) !== operation.expectedSourceMode) {
          throw new Error(`resource source changed after analysis: ${operation.sourceRelativePath}`);
        }
        operation.bytes = sourceBytes;
        operation.mode = sourceStat.mode & 0o777;
      }
      const stat = lstatIfPresent(operation.destination);
      if (operation.expectedBeforeHash &&
          (!stat || !stat.isFile() || sha256(fs.readFileSync(operation.destination)) !== operation.expectedBeforeHash ||
            (Number.isInteger(operation.expectedBeforeMode) &&
              (stat.mode & 0o777) !== operation.expectedBeforeMode))) {
        throw new Error(`transaction source changed after analysis: ${operation.relativePath}`);
      }
      if (operation.kind === 'copy' &&
          (Boolean(stat) !== operation.expectedDestinationExisted ||
            (stat && (!stat.isFile() ||
              sha256(fs.readFileSync(operation.destination)) !== operation.expectedDestinationHash ||
              (stat.mode & 0o777) !== operation.expectedDestinationMode)))) {
        throw new Error(`resource destination changed after analysis: ${operation.relativePath}`);
      }
      const snapshot = {operation, existed: Boolean(stat), mode: stat ? stat.mode & 0o777 : null, sha256: null, snapshotPath: null};
      if (stat) {
        if (!stat.isFile()) throw new Error(`transaction destination is not a regular file: ${operation.relativePath}`);
        const bytes = fs.readFileSync(operation.destination);
        snapshot.sha256 = sha256(bytes);
        snapshot.snapshotPath = path.join(txRoot, 'before', String(index));
        writeManagedFileAtomic(target.packageRoot, snapshot.snapshotPath, bytes, snapshot.mode);
      }
      snapshots.push(snapshot);
    }

    for (const snapshot of snapshots) {
      for (const directory of missingParentDirectories(target.packageRoot, snapshot.operation.destination)) {
        if (!createdDirectories.includes(directory)) createdDirectories.push(directory);
      }
    }

    const journalPath = path.join(txRoot, 'transaction.json');
    journal = {
      schemaVersion: 1,
      state: 'prepared',
      target: transactionTargetIdentity(target, manifest),
      operations: snapshots.map(snapshot => ({relativePath: snapshot.operation.relativePath,
        existed: snapshot.existed, mode: snapshot.mode, sha256: snapshot.sha256,
        afterExisted: snapshot.operation.kind !== 'delete',
        afterMode: snapshot.operation.kind === 'delete' ? null : snapshot.operation.mode,
        afterSha256: snapshot.operation.kind === 'delete' ? null : sha256(snapshot.operation.bytes)})),
      createdDirectories: createdDirectories.map(directory => path.relative(target.packageRoot, directory)),
    };
    fs.writeFileSync(journalPath, `${JSON.stringify(journal, null, 2)}\n`, {mode: 0o600, flag: 'wx'});
    fsyncFile(journalPath);
    fsyncDirectory(txRoot);

    if (process.env.CC_PATCH_TESTING === '1' && process.env.CC_PATCH_TEST_MUTATE_AFTER_SNAPSHOT) {
      const relativePath = process.env.CC_PATCH_TEST_MUTATE_AFTER_SNAPSHOT;
      const snapshot = snapshots.find(item => item.operation.relativePath === relativePath);
      if (!snapshot) throw new Error(`unknown snapshot mutation target: ${relativePath}`);
      fs.appendFileSync(snapshot.operation.destination, '\n// CC_TEST_EXTERNAL_MUTATION\n');
      throw new Error('injected transaction failure after snapshots');
    }

    for (const [index, snapshot] of snapshots.entries()) {
      if (snapshot.operation.kind === 'delete') continue;
      const staged = path.join(txRoot, 'after', String(index));
      writeManagedFileAtomic(target.packageRoot, staged, snapshot.operation.bytes, snapshot.operation.mode);
      snapshot.stagedPath = staged;
    }

    if (process.env.CC_PATCH_TESTING === '1' && process.env.CC_PATCH_TEST_MUTATE_BEFORE_RENAME) {
      const mutated = managedDestination(target, process.env.CC_PATCH_TEST_MUTATE_BEFORE_RENAME);
      fs.appendFileSync(mutated, '\n// CC_TEST_EXTERNAL_MUTATION\n');
    }

    for (const [index, snapshot] of snapshots.entries()) {
      const state = {operation: journal.operations[index], destination: snapshot.operation.destination};
      if (classifyPreparedTransactionState(state) !== 'before') {
        throw new Error(`transaction destination changed before rename: ${snapshot.operation.relativePath}`);
      }
      if (snapshot.operation.kind === 'delete') {
        fs.unlinkSync(snapshot.operation.destination);
        fsyncDirectory(path.dirname(snapshot.operation.destination));
      } else {
        fs.mkdirSync(path.dirname(snapshot.operation.destination), {recursive: true});
        assertManagedPathSafe(target.packageRoot, path.dirname(snapshot.operation.destination));
        for (const directory of createdDirectories) {
          if (fs.existsSync(directory)) {
            fsyncDirectory(directory);
            fsyncDirectory(path.dirname(directory));
          }
        }
        fs.renameSync(snapshot.stagedPath, snapshot.operation.destination);
        if (process.env.CC_PATCH_TESTING === '1' && process.env.CC_PATCH_TEST_FAIL_AFTER_RENAME === '1' && committed === 0) {
          throw new Error('injected transaction failure after destination rename');
        }
        fs.chmodSync(snapshot.operation.destination, snapshot.operation.mode);
        fsyncFile(snapshot.operation.destination);
        fsyncDirectory(path.dirname(snapshot.operation.destination));
      }
      committed += 1;
      if (process.env.CC_PATCH_TESTING === '1' && process.env.CC_PATCH_TEST_LEAVE_TRANSACTION === '1' && committed === 1) {
        console.error(`INCOMPLETE_TRANSACTION:${path.basename(txRoot)}`);
        process.exit(86);
      }
      if (process.env.CC_PATCH_TESTING === '1' && Number(process.env.CC_PATCH_TEST_FAIL_AFTER) === committed) {
        throw new Error(`injected transaction failure after operation ${committed}`);
      }
    }

    for (const snapshot of snapshots) {
      const stat = lstatIfPresent(snapshot.operation.destination);
      const valid = snapshot.operation.kind === 'delete' ? !stat :
        stat && stat.isFile() && sha256(fs.readFileSync(snapshot.operation.destination)) === sha256(snapshot.operation.bytes) &&
          (stat.mode & 0o777) === snapshot.operation.mode;
      if (!valid) {
        throw new Error(`transaction verification failed: ${snapshot.operation.relativePath}`);
      }
    }
    journal.state = 'committed';
    replaceFileAtomic(target.packageRoot, journalPath, Buffer.from(`${JSON.stringify(journal, null, 2)}\n`), 0o600);
    if (process.env.CC_PATCH_TESTING === '1' && process.env.CC_PATCH_TEST_LEAVE_COMMITTED_TRANSACTION === '1') {
      console.error(`COMMITTED_TRANSACTION:${path.basename(txRoot)}`);
      process.exit(87);
    }
  } catch (error) {
    let rollbackError = null;
    try {
      if (journal) {
        const states = snapshots.map((snapshot, index) => ({
          operation: journal.operations[index],
          destination: snapshot.operation.destination,
          bytes: snapshot.existed ? fs.readFileSync(snapshot.snapshotPath) : null,
        }));
        rollbackPreparedTransaction(target, states, createdDirectories);
      }
    } catch (caught) {
      rollbackError = caught;
    }
    if (rollbackError) {
      preserveTransaction = true;
      throw new Error(`${error.message}; ${rollbackError.message}`);
    }
    throw error;
  } finally {
    if (!preserveTransaction) {
      fs.rmSync(txRoot, {recursive: true, force: true});
      fsyncDirectory(target.packageRoot);
    }
  }
}

function ensureBaselineForPlan(target, plan, operations = [], publication = null) {
  let manifest = readBaselineManifest(target);
  const creating = !manifest;
  const previousManifest = manifest ? JSON.parse(JSON.stringify(manifest)) : null;
  const entryPath = path.relative(target.packageRoot, target.entryPath);
  if (!manifest) {
    const hasManagedState = plan.semanticTargets.some(semanticTarget =>
      semanticTarget.matches.some(match => match.state === 'after' && match.attributable !== false));
    if (hasManagedState) throw new Error('patched or unknown state has no trusted baseline');
    const sentinel = findUntrustedPatchSentinel(target);
    if (sentinel) {
      throw new Error(`untrusted patch sentinel ${sentinel.value} in ${sentinel.relativePath}`);
    }
    manifest = {
      schemaVersion: 1,
      package: {name: target.packageName, version: target.packageVersion, layout: target.layout,
        identityFingerprint: target.identityFingerprint, entryPath, entrySha256: null},
      createdAt: new Date().toISOString(),
      managerVersion: '1.0.0',
      files: {},
      createdDirectories: [],
    };
  } else {
    if (manifest.schemaVersion !== 1) throw new Error(`unsupported baseline schema: ${manifest.schemaVersion}`);
    assertBaselineIdentity(manifest, target);
    assertBaselineMirrors(manifest, target);
    assertManagedFilesAttributable(manifest, target, attributionPlanForTarget(target, plan));
  }

  const finalRoot = baselineDirectory(target);
  const managedPaths = [...new Set([
    entryPath,
    ...plan.files.map(file => file.relativePath),
    ...(plan.resources || []).map(resource => resource.destination),
  ])];
  const newPaths = managedPaths.filter(relativePath => !manifest.files[relativePath]);
  const resourceOperations = new Map(operations.filter(operation => operation.kind === 'copy')
    .map(operation => [operation.relativePath, operation]));
  const recordResourcePatchState = (item, resource) => {
    if (!resource?.source) return false;
    const operation = resourceOperations.get(resource.destination);
    let patchSha256, patchMode;
    if (operation) {
      patchSha256 = operation.expectedSourceHash;
      patchMode = operation.expectedSourceMode;
    } else {
      const source = resourceSourcePath(target, {...resource, patchId: plan.patchId});
      const sourceStat = fs.statSync(source);
      patchSha256 = sha256(fs.readFileSync(source));
      patchMode = sourceStat.mode & 0o777;
    }
    const changed = item.patchSha256 !== patchSha256 || item.patchMode !== patchMode;
    item.patchSha256 = patchSha256;
    item.patchMode = patchMode;
    return changed;
  };
  let metadataChanged = false;
  for (const resource of plan.resources || []) {
    const item = manifest.files[resource.destination];
    if (item && resourceOperations.has(resource.destination)) {
      metadataChanged = recordResourcePatchState(item, resource) || metadataChanged;
    }
  }
  if (!creating && newPaths.length === 0 && !metadataChanged) return path.join(finalRoot, 'manifest.json');
  if (publication) {
    publication.creating = creating;
    publication.previousManifest = previousManifest;
    publication.newPaths = [...newPaths];
    publication.publishedMirrors = [];
    publication.published = false;
  }
  let stagingRoot = path.join(target.packageRoot, `.cc-patch-manager-baseline.stage-${process.pid}-${crypto.randomBytes(6).toString('hex')}`);
  const root = stagingRoot;
  const recordPath = (relativePath, requireExisting) => {
    if (manifest.files[relativePath]) return;
    const absolute = path.resolve(target.packageRoot, relativePath);
    if (!insideRoot(target.packageRoot, absolute) || relativePath.startsWith('..') || path.isAbsolute(relativePath)) {
      throw new Error(`baseline path escapes package root: ${relativePath}`);
    }
    assertManagedPathSafe(target.packageRoot, absolute);
    const stat = lstatIfPresent(absolute);
    if (!stat) {
      if (requireExisting) throw new Error(`managed source does not exist: ${relativePath}`);
      let parent = path.dirname(relativePath);
      const missing = [];
      while (parent && parent !== '.') {
        const parentAbsolute = path.join(target.packageRoot, parent);
        if (lstatIfPresent(parentAbsolute)) break;
        missing.push(parent);
        parent = path.dirname(parent);
      }
      for (const directory of missing.reverse()) {
        if (!manifest.createdDirectories.includes(directory)) manifest.createdDirectories.push(directory);
      }
      manifest.files[relativePath] = {type: 'file', existed: false, sha256: null, mode: null, mirror: null};
      const resource = (plan.resources || []).find(candidate => candidate.destination === relativePath);
      recordResourcePatchState(manifest.files[relativePath], resource);
      return;
    }
    if (!stat.isFile()) throw new Error(`managed path is not a file: ${relativePath}`);
    const bytes = fs.readFileSync(absolute);
    const mode = stat.mode & 0o777;
    const mirrorRelative = path.join('files', relativePath);
    const mirror = path.join(root, mirrorRelative);
    writeManagedFileAtomic(target.packageRoot, mirror, bytes, mode);
    manifest.files[relativePath] = {type: 'file', existed: true, sha256: sha256(bytes), mode, mirror: mirrorRelative};
    const resource = (plan.resources || []).find(candidate => candidate.destination === relativePath);
    recordResourcePatchState(manifest.files[relativePath], resource);
  };
  try {
    for (const relativePath of managedPaths) {
      const requireExisting = relativePath === entryPath || plan.files.some(file => file.relativePath === relativePath);
      recordPath(relativePath, requireExisting);
    }
    if (!manifest.package.entrySha256) manifest.package.entrySha256 = manifest.files[entryPath].sha256;
    manifest.createdDirectories.sort();
    writeManifestAtomic(target, manifest, root);
    for (const relativePath of newPaths) {
      const item = manifest.files[relativePath];
      if (!item.existed) continue;
      const mirror = packageFile(root, item.mirror);
      if (sha256(fs.readFileSync(mirror)) !== item.sha256) throw new Error(`corrupt staged baseline mirror: ${relativePath}`);
    }
    if (process.env.CC_PATCH_TESTING === '1' && process.env.CC_PATCH_FAIL_BASELINE_AFTER_MIRROR === '1') {
      throw new Error('injected baseline publication failure');
    }
    if (creating) {
      assertManagedPathSafe(target.packageRoot, finalRoot);
      if (lstatIfPresent(finalRoot)) throw new Error(`untrusted baseline path already exists: ${finalRoot}`);
      fs.renameSync(root, finalRoot);
      fsyncDirectory(target.packageRoot);
      stagingRoot = null;
      assertManagedPathSafe(target.packageRoot, finalRoot);
      if (publication) publication.published = true;
    } else {
      const publishedMirrors = [];
      const createdMirrorDirectories = [];
      let manifestPublished = false;
      try {
        for (const relativePath of newPaths) {
          const item = manifest.files[relativePath];
          if (!item.existed) continue;
          const source = packageFile(root, item.mirror);
          const destination = path.join(finalRoot, item.mirror);
          const existing = lstatIfPresent(destination);
          if (existing) {
            assertManagedPathSafe(target.packageRoot, destination);
            if (!existing.isFile() || sha256(fs.readFileSync(destination)) !== item.sha256 ||
                (existing.mode & 0o777) !== item.mode) throw new Error(`conflicting orphan baseline mirror: ${relativePath}`);
            continue;
          }
          for (const directory of missingParentDirectories(target.packageRoot, destination)) {
            if (!createdMirrorDirectories.includes(directory)) createdMirrorDirectories.push(directory);
          }
          writeManagedFileAtomic(target.packageRoot, destination, fs.readFileSync(source), item.mode);
          publishedMirrors.push(destination);
          if (process.env.CC_PATCH_TESTING === '1' && process.env.CC_PATCH_TEST_LEAVE_BASELINE_ORPHAN === '1' && publishedMirrors.length === 1) {
            console.error(`BASELINE_ORPHAN:${path.relative(target.packageRoot, destination)}`);
            process.exit(88);
          }
        }
        writeManifestAtomic(target, manifest, finalRoot);
        manifestPublished = true;
        assertBaselineMirrors(manifest, target, finalRoot);
        if (publication) {
          publication.published = true;
          publication.publishedMirrors = [...publishedMirrors];
        }
      } catch (error) {
        if (!manifestPublished) {
          for (const mirror of publishedMirrors.reverse()) {
            try { fs.unlinkSync(mirror); fsyncDirectory(path.dirname(mirror)); } catch (cleanupError) {
              if (cleanupError.code !== 'ENOENT') throw cleanupError;
            }
          }
          for (const directory of createdMirrorDirectories.sort((left, right) => right.length - left.length)) {
            try { fs.rmdirSync(directory); fsyncDirectory(path.dirname(directory)); } catch (cleanupError) {
              if (cleanupError.code !== 'ENOENT' && cleanupError.code !== 'ENOTEMPTY') throw cleanupError;
            }
          }
        }
        throw error;
      }
    }
    if (stagingRoot) {
      fs.rmSync(stagingRoot, {recursive: true, force: true});
      fsyncDirectory(target.packageRoot);
      stagingRoot = null;
    }
    return path.join(finalRoot, 'manifest.json');
  } catch (error) {
    if (stagingRoot) fs.rmSync(stagingRoot, {recursive: true, force: true});
    throw error;
  }
}

function rollbackBaselinePublication(target, publication) {
  if (!publication?.published) return;
  const root = baselineDirectory(target);
  if (publication.creating) {
    assertManagedPathSafe(target.packageRoot, root);
    fs.rmSync(root, {recursive: true, force: true});
    fsyncDirectory(target.packageRoot);
    return;
  }
  writeManifestAtomic(target, publication.previousManifest, root);
  for (const mirror of [...publication.publishedMirrors].reverse()) {
    const stat = lstatIfPresent(mirror);
    if (stat) {
      assertManagedPathSafe(target.packageRoot, mirror);
      if (!stat.isFile() || stat.isSymbolicLink()) throw new Error(`cannot roll back baseline mirror: ${mirror}`);
      fs.unlinkSync(mirror);
      fsyncDirectory(path.dirname(mirror));
    }
    let directory = path.dirname(mirror), filesRoot = path.join(root, 'files');
    while (directory !== filesRoot && insideRoot(filesRoot, directory)) {
      try {
        fs.rmdirSync(directory);
        fsyncDirectory(path.dirname(directory));
      } catch (error) {
        if (error.code !== 'ENOENT' && error.code !== 'ENOTEMPTY') throw error;
        break;
      }
      directory = path.dirname(directory);
    }
  }
  assertBaselineMirrors(publication.previousManifest, target);
}

function restoreOperationsFromBaseline(target, manifest) {
  const operations = [];
  for (const [relativePath, item] of Object.entries(manifest.files || {})) {
    const destination = managedDestination(target, relativePath);
    const stat = lstatIfPresent(destination);
    if (item.existed) {
      if (!stat || !stat.isFile() || stat.isSymbolicLink()) {
        throw new Error(`managed file cannot be restored safely: ${relativePath}`);
      }
      const beforeBytes = fs.readFileSync(destination);
      const baselineBytes = fs.readFileSync(packageFile(baselineDirectory(target), item.mirror));
      if (sha256(beforeBytes) === item.sha256 && (stat.mode & 0o777) === item.mode) continue;
      operations.push({
        kind: 'write', relativePath, destination, bytes: baselineBytes, mode: item.mode,
        expectedBeforeHash: sha256(beforeBytes), expectedBeforeMode: stat.mode & 0o777,
      });
    } else if (stat) {
      if (!stat.isFile() || stat.isSymbolicLink()) {
        throw new Error(`managed created path cannot be restored safely: ${relativePath}`);
      }
      operations.push({
        kind: 'delete', relativePath, destination,
        expectedBeforeHash: sha256(fs.readFileSync(destination)), expectedBeforeMode: stat.mode & 0o777,
      });
    }
  }
  return operations;
}

function removeBaselineCreatedDirectories(target, manifest) {
  const directories = (manifest.createdDirectories || [])
    .map(relativePath => ({relativePath, absolute: managedDestination(target, relativePath)}))
    .sort((left, right) => right.absolute.length - left.absolute.length);
  for (const directory of directories) {
    const stat = lstatIfPresent(directory.absolute);
    if (!stat) continue;
    if (!stat.isDirectory() || stat.isSymbolicLink()) {
      throw new Error(`managed created directory is not safe: ${directory.relativePath}`);
    }
    try {
      fs.rmdirSync(directory.absolute);
      fsyncDirectory(path.dirname(directory.absolute));
    } catch (error) {
      if (error.code !== 'ENOTEMPTY') throw error;
    }
  }
}

function applyRuntimePatch(target, patchId) {
  const plan = analyzePatch(target, patchId);
  const renderedFiles = validatePlan(target, plan);
  if (plan.state === 'already-patched') return false;
  commitPlanTransaction(target, plan, renderedFiles);
  return true;
}

function commitPlanTransaction(target, plan, renderedFiles) {
  const operations = transactionOperations(target, plan, renderedFiles);
  if (process.env.CC_PATCH_TESTING === '1' && process.env.CC_PATCH_TEST_MUTATE_RESOURCE_BEFORE_BASELINE) {
    const mutated = managedDestination(target, process.env.CC_PATCH_TEST_MUTATE_RESOURCE_BEFORE_BASELINE);
    fs.appendFileSync(mutated, '\n// CC_TEST_EXTERNAL_MUTATION\n');
  }
  const publication = {};
  ensureBaselineForPlan(target, plan, operations, publication);
  try {
    if (process.env.CC_PATCH_TESTING === '1' && process.env.CC_PATCH_TEST_MUTATE_AFTER_ANALYSIS) {
      const mutated = managedDestination(target, process.env.CC_PATCH_TEST_MUTATE_AFTER_ANALYSIS);
      fs.appendFileSync(mutated, '\n// CC_TEST_EXTERNAL_MUTATION\n');
    }
    if (process.env.CC_PATCH_TESTING === '1' && process.env.CC_PATCH_TEST_CHMOD_AFTER_ANALYSIS) {
      const mutated = managedDestination(target, process.env.CC_PATCH_TEST_CHMOD_AFTER_ANALYSIS);
      fs.chmodSync(mutated, 0o600);
    }
    commitTransaction(target, operations);
  } catch (error) {
    if (incompleteTransactionEntries(target).length === 0) rollbackBaselinePublication(target, publication);
    throw error;
  }
}

function restoreOrchestrationPath(target) {
  return path.join(baselineDirectory(target), 'restore.json');
}

function readRestoreOrchestration(target) {
  const journalPath = restoreOrchestrationPath(target);
  const stat = lstatIfPresent(journalPath);
  if (!stat) return null;
  assertManagedPathSafe(target.packageRoot, journalPath);
  if (!stat.isFile() || stat.isSymbolicLink()) throw new Error('restore orchestration state is not a regular file');
  try {
    return JSON.parse(fs.readFileSync(journalPath, 'utf8'));
  } catch (error) {
    throw new Error(`invalid restore orchestration state: ${error.message}`);
  }
}

function writeRestoreOrchestration(target, journal) {
  const journalPath = restoreOrchestrationPath(target);
  writeManagedFileAtomic(target.packageRoot, journalPath,
    Buffer.from(`${JSON.stringify(journal, null, 2)}\n`), 0o600);
  return journalPath;
}

function validateRestoreOrchestration(journal, target, manifest, removeId, candidates) {
  if (!journal || journal.schemaVersion !== 1 || journal.removeId !== removeId ||
      !journal.target || !Array.isArray(journal.retained)) {
    throw new Error('restore orchestration state does not match the requested patch');
  }
  const expectedTarget = transactionTargetIdentity(target, manifest);
  if (Object.keys(expectedTarget).some(key => journal.target[key] !== expectedTarget[key])) {
    throw new Error('restore orchestration target identity mismatch');
  }
  let previousIndex = -1;
  for (const patchId of journal.retained) {
    const index = candidates.indexOf(patchId);
    if (index <= previousIndex || patchId === removeId) {
      throw new Error(`invalid retained patch in restore orchestration: ${patchId}`);
    }
    previousIndex = index;
  }
  return journal;
}

function restorePatchFromBaseline(target, removeId) {
  const candidates = registeredPatchIdsFor(removeId);
  if (!candidates.includes(removeId)) {
    throw new Error(`unsupported restore patch id: ${removeId}`);
  }
  const plans = candidates.map(patchId => ({patchId,
    plan: analyzePatch(target, patchId, {allowMissingResources: true})}));
  for (const {plan} of plans) validatePlan(target, plan);
  const manifest = readBaselineManifest(target);
  if (!manifest) throw new Error('patch restore requires a trusted baseline');
  assertBaselineIdentity(manifest, target);
  assertBaselineMirrors(manifest, target);
  assertManagedFilesAttributable(manifest, target, {
    patchId: removeId,
    attribution: {transformations: plans.flatMap(item => item.plan.attribution?.transformations || [])},
    resources: plans.flatMap(item => item.plan.resources || []),
  });

  let orchestration = readRestoreOrchestration(target);
  if (orchestration) {
    orchestration = validateRestoreOrchestration(orchestration, target, manifest, removeId, candidates);
  } else {
    const retained = plans.filter(item => item.patchId !== removeId && item.plan.state === 'already-patched')
      .map(item => item.patchId);
    orchestration = {schemaVersion: 1, target: transactionTargetIdentity(target, manifest), removeId, retained};
    writeRestoreOrchestration(target, orchestration);
  }

  const operations = restoreOperationsFromBaseline(target, manifest);
  if (operations.length > 0) commitTransaction(target, operations);
  removeBaselineCreatedDirectories(target, manifest);
  const reapplied = [];
  for (const [index, patchId] of orchestration.retained.entries()) {
    try {
      if (process.env.CC_PATCH_TESTING === '1' && process.env.CC_PATCH_TEST_FAIL_REAPPLY === patchId) {
        throw new Error('injected retained patch reapply failure');
      }
      applyRuntimePatch(target, patchId);
      reapplied.push(patchId);
    } catch (error) {
      console.error(`RESTORE_REAPPLIED:${reapplied.join(',')}`);
      console.error(`RESTORE_PENDING:${orchestration.retained.slice(index).join(',')}`);
      throw new Error(`retained patch reapply failed at ${patchId}: ${error.message}; retry the same restore operation`);
    }
  }
  fs.unlinkSync(restoreOrchestrationPath(target));
  fsyncDirectory(baselineDirectory(target));
  return {removed: removeId, reapplied};
}

function inspectTarget(entry) {
  if (!entry) fail('entry path is required');
  let entryPath;
  try {
    entryPath = fs.realpathSync(entry);
  } catch (error) {
    fail(`entry is not readable: ${entry}: ${error.message}`);
  }
  if (!fs.statSync(entryPath).isFile()) fail(`entry is not a file: ${entryPath}`);

  const packageRoot = fs.realpathSync(findPackageRoot(entryPath));
  tracePackageRoot = packageRoot;
  if (!insideRoot(packageRoot, entryPath)) fail(`entry escapes package root: ${entryPath}`);
  const manifestPath = path.join(packageRoot, 'package.json');
  const manifestText = fs.readFileSync(manifestPath, 'utf8');
  let manifest;
  try {
    manifest = JSON.parse(manifestText);
  } catch (error) {
    fail(`invalid package.json: ${error.message}`);
  }
  if (!supportedPackages.has(manifest.name)) fail(`unsupported package: ${manifest.name || 'unnamed'}`);

  const moduleProgram = parseProgram(entryPath, 'module');
  const specifiers = relativeSpecifiers(moduleProgram.ast);
  const resolvedModules = specifiers
    .map(specifier => resolveRelativeModule(packageRoot, entryPath, specifier, true))
    .filter(Boolean);
  const commonJsShape = hasCommonJsShape(moduleProgram.ast);
  let layout;
  if (resolvedModules.length > 0) {
    if (commonJsShape) fail('entry has conflicting split-ESM and CommonJS evidence');
    layout = 'split-esm';
  } else {
    const scriptProgram = parseProgram(entryPath, 'script');
    if (!hasCommonJsShape(scriptProgram.ast)) fail('entry has neither split-ESM imports nor a single-CJS shape');
    layout = 'single-cjs';
  }

  const header = buildIdentityFromText(moduleProgram.text);
  const modulePaths = layout === 'split-esm' ? packageModulePaths(packageRoot) : ['cli.js'];
  const identityFingerprint = sha256(JSON.stringify({manifest: sha256(manifestText), header, modulePaths}));
  return {entryPath, packageRoot, packageName: manifest.name, packageVersion: String(manifest.version || ''), layout, identityFingerprint, resolvedModules};
}

const target = inspectTarget(requestedEntry);
if (!['inspect', 'restore'].includes(command) && lstatIfPresent(restoreOrchestrationPath(target))) {
  fail('incomplete patch restore exists; retry the same restore operation first');
}
if (command === 'check' && incompleteTransactionEntries(target).length > 0) {
  fail('incomplete patch transaction exists; run an apply, baseline, or backup operation to recover it first');
}
if (command === 'backup' || command === 'baseline' || command === 'restore' ||
    (command === 'apply' && process.env.CC_PATCH_VALIDATE_ONLY !== '1')) {
  try {
    cleanupBaselineStagingDirectories(target);
    const recovered = recoverIncompleteTransactions(target);
    if (recovered > 0) throw new Error(`recovered ${recovered} incomplete transaction(s); retry the requested operation`);
  } catch (error) {
    fail(error.message);
  }
}
if (command === 'inspect') {
  console.log(`TARGET_PACKAGE:${target.packageName}`);
  console.log(`TARGET_VERSION:${target.packageVersion}`);
  console.log(`TARGET_LAYOUT:${target.layout}`);
  console.log(`TARGET_ENTRY:${JSON.stringify(target.entryPath)}`);
  console.log(`TARGET_ROOT:${JSON.stringify(target.packageRoot)}`);
  console.log(`TARGET_IDENTITY:${target.identityFingerprint}`);
  for (const file of target.resolvedModules) console.log(`TARGET_FILE:${JSON.stringify(path.relative(target.packageRoot, file))}`);
} else if (command === 'index') {
  const [relativeFile, localName, marker] = runtimeArgs;
  const candidateGroups = scanMarkerCandidateGroups(target, marker);
  for (const [index, group] of candidateGroups.entries()) {
    if (group.length === 0) {
      console.error(`MISSING_MARKER_GROUP:${index}`);
      fail(`required marker group is empty: ${index}`);
    }
    for (const file of group) console.log(`TARGET_GROUP:${index}:${JSON.stringify(file)}`);
  }
  const candidates = [...new Set(candidateGroups.flat())];
  for (const file of candidates) console.log(`TARGET_FILE:${JSON.stringify(file)}`);
  let binding;
  try {
    binding = new ModuleIndex(target).resolveLocal(packageFile(target.packageRoot, relativeFile), localName);
  } catch (error) {
    fail(error.message);
  }
  console.log(`BINDING_SOURCE:${JSON.stringify(path.relative(target.packageRoot, binding.file))}:${binding.exportedName}`);
} else if (command === 'backup') {
  let manifestPath;
  try {
    const manifest = readBaselineManifest(target);
    if (manifest) {
      assertBaselineIdentity(manifest, target);
      assertBaselineMirrors(manifest, target);
      manifestPath = path.join(baselineDirectory(target), 'manifest.json');
    } else {
      manifestPath = migrateLegacyBaseline(target);
      if (!manifestPath) throw new Error('compatible legacy baseline not found');
    }
  } catch (error) {
    fail(error.message);
  }
  console.log(`BASELINE:${JSON.stringify(manifestPath)}`);
} else if (command === 'restore') {
  try {
    const result = restorePatchFromBaseline(target, runtimeArgs[0]);
    console.log(`RESTORED:${result.removed}`);
    for (const patchId of result.reapplied) console.log(`REAPPLIED:${patchId}`);
  } catch (error) {
    fail(error.message);
  }
} else if (command === 'check' || command === 'apply' || command === 'baseline') {
  const patchId = runtimeArgs[0];
  console.log(`TARGET_PACKAGE:${target.packageName}`);
  console.log(`TARGET_VERSION:${target.packageVersion}`);
  console.log(`TARGET_LAYOUT:${target.layout}`);
  let plan, renderedFiles;
  try {
    plan = analyzePatch(target, patchId);
    renderedFiles = validatePlan(target, plan);
    if (process.env.CC_PATCH_TESTING === '1' && process.env.CC_PATCH_TEST_SWAP_VOICE_SOURCE_AFTER_ANALYSIS) {
      const [sourceName, targetName] = process.env.CC_PATCH_TEST_SWAP_VOICE_SOURCE_AFTER_ANALYSIS.split(':');
      const allowed = ['index.js', 'index.d.ts', 'package.json', 'libcometix-asr.darwin-arm64.node'];
      if (patchId !== 'voice-mode' || !allowed.includes(sourceName) || !allowed.includes(targetName)) {
        throw new Error('invalid injected VoiceMode source swap');
      }
      const sourceRoot = process.env.CC_PATCH_VOICE_ASSET_SOURCE;
      fs.unlinkSync(path.join(sourceRoot, sourceName));
      fs.symlinkSync(targetName, path.join(sourceRoot, sourceName));
    }
  } catch (error) {
    fail(error.message);
  }
  console.log(`ANALYSIS_HASH:${sha256(JSON.stringify(plan))}`);
  if (command === 'baseline') {
    let manifestPath;
    try {
      manifestPath = ensureBaselineForPlan(target, plan);
    } catch (error) {
      fail(error.message);
    }
    console.log(`BASELINE:${JSON.stringify(manifestPath)}`);
  } else if (plan.state === 'already-patched') {
    console.log('ALREADY_PATCHED');
  } else if (command === 'check') {
    console.log('NEEDS_PATCH');
    console.log(`PATCH_COUNT:${plan.files.reduce((count, file) => count + file.replacements.length, 0)}`);
  } else if (process.env.CC_PATCH_VALIDATE_ONLY === '1') {
    console.log('PLAN_VALID');
  } else {
    if (process.env.CC_PATCH_TESTING === '1' && process.env.CC_PATCH_TEST_FAIL_PATCH === patchId) {
      fail(`injected apply transaction failure: ${patchId}`);
    }
    try {
      commitPlanTransaction(target, plan, renderedFiles);
    } catch (error) {
      fail(error.message);
    }
    console.log(`PATCHED:${plan.patchId}`);
  }
} else {
  fail(`unsupported runtime command: ${command || 'missing'}`);
}
RUNTIME_EOF
  printf '%s\n' "$tmp"
}

runtime_exec() {
  local command="$1" entry="$2" runtime output status voice_asset_source
  shift 2
  ensure_node || return 1
  ensure_acorn || return 1
  runtime=$(write_patch_runtime) || return 1
  voice_asset_source="${CC_PATCH_VOICE_ASSET_SOURCE:-$(voice_mode_source_dir)}"
  set +e
  output=$(CC_PATCH_VOICE_ASSET_SOURCE="$voice_asset_source" node "$runtime" "$ACORN_PATH" "$command" "$entry" "$@" 2>&1)
  status=$?
  set -e
  rm -f "$runtime"
  printf '%s\n' "$output"
  return "$status"
}

target_declares_cruce() {
  node - "$1" <<'NODE'
const fs = require('fs');
const path = require('path');
let cursor = path.dirname(path.resolve(process.argv[2]));
for (;;) {
  const manifest = path.join(cursor, 'package.json');
  if (fs.existsSync(manifest)) {
    try {
      process.exit(JSON.parse(fs.readFileSync(manifest, 'utf8')).name === '@cometix/anthropic-cc' ? 0 : 1);
    } catch {
      process.exit(1);
    }
  }
  const parent = path.dirname(cursor);
  if (parent === cursor) process.exit(1);
  cursor = parent;
}
NODE
}

# write_patch_script id → prints temp file path
write_patch_script() {
  local id="$1"
  local tmp
  tmp=$(mktemp)
  case "$id" in
    auto-mode) write_patch_script_auto_mode "$tmp" ;;
    keybindings) write_patch_script_keybindings "$tmp" ;;
    transcript-dialog) write_patch_script_transcript_dialog "$tmp" ;;
    ultracode) write_patch_script_ultracode "$tmp" ;;
    voice-mode) write_patch_script_voice_mode "$tmp" ;;
    context-limit) write_patch_script_context_limit "$tmp" ;;
    computer-use) write_patch_script_computer_use "$tmp" ;;
    *) error "未知补丁 id: $id"; rm -f "$tmp"; return 1 ;;
  esac
  printf '%s\n' "$tmp"
}

write_patch_script_context_limit() {
  local out="$1"
  cat >"$out" <<'PATCH_EOF'
const fs = require('fs');
const acorn = require(process.argv[2]);
const cliPath = process.argv[3];
const checkOnly = process.argv[4] === '--check';
const backupSuffix = process.env.BACKUP_SUFFIX || 'backup';

let code = fs.readFileSync(cliPath, 'utf-8');

// Preserve shebang
let shebang = '';
if (code.startsWith('#!')) {
    const idx = code.indexOf('\n');
    shebang = code.slice(0, idx + 1);
    code = code.slice(idx + 1);
}

// Version info (informational) - check multiple patterns
const versionMatch = code.slice(0, 1000).match(/Version:\s*([\d.]+)/)
    || code.match(/VERSION:\s*"([\d.]+)"/)
    || code.match(/"version"\s*:\s*"([\d.]+)"/);
console.log('VERSION:' + (versionMatch ? versionMatch[1] : 'unknown'));

// ============================================================
// Parse AST
// ============================================================
let ast;
try {
    ast = acorn.parse(code, { ecmaVersion: 'latest', sourceType: 'module' });
} catch (e) {
    console.error('PARSE_ERROR:' + e.message);
    process.exit(1);
}

// AST helpers
function findNodes(node, predicate, results = []) {
    if (!node || typeof node !== 'object') return results;
    if (predicate(node)) results.push(node);
    for (const key in node) {
        if (key === 'start' || key === 'end' || key === 'type') continue;
        if (node[key] && typeof node[key] === 'object') {
            if (Array.isArray(node[key])) {
                node[key].forEach(child => findNodes(child, predicate, results));
            } else {
                findNodes(node[key], predicate, results);
            }
        }
    }
    return results;
}

const src = (node) => code.slice(node.start, node.end);

// ============================================================
// Phase 1: Find 200000 numeric literals and classify
// ============================================================

console.log('STEP:1 - Finding 200000 numeric literals');

const numericLiterals = findNodes(ast, n =>
    n.type === 'Literal' && typeof n.value === 'number' && n.value === 200000
);

console.log('FOUND:' + numericLiterals.length + ' occurrences of numeric literal 200000');

// Build parent map
const parentMap = new Map();
function buildParentMap(node, parent) {
    if (!node || typeof node !== 'object') return;
    if (node.type) parentMap.set(node, parent);
    for (const key in node) {
        if (key === 'start' || key === 'end' || key === 'type') continue;
        if (node[key] && typeof node[key] === 'object') {
            if (Array.isArray(node[key])) {
                node[key].forEach(child => buildParentMap(child, node));
            } else {
                buildParentMap(node[key], node);
            }
        }
    }
}
buildParentMap(ast, null);

console.log('STEP:2 - Classifying literals by parent AST node');

const replacements = [];
const contextVarNames = [];  // collect var names for Phase 3 injection
let patchedCount = 0;
let skippedCount = 0;

const replacement = '(+process.env.CLAUDE_CODE_CONTEXT_LIMIT||200000)';

for (const lit of numericLiterals) {
    const parent = parentMap.get(lit);
    const grandparent = parent ? parentMap.get(parent) : null;
    let context = 'unknown';
    let shouldPatch = false;
    let varName = null;

    // Pattern 1: Top-level VariableDeclarator init
    if (parent && parent.type === 'VariableDeclarator' && parent.init === lit) {
        if (grandparent && grandparent.type === 'VariableDeclaration') {
            const isTopLevel = ast.body.includes(grandparent);
            if (isTopLevel) {
                varName = parent.id.name;
                context = 'top-level-var(' + varName + ')';
                shouldPatch = true;
                contextVarNames.push(varName);
            }
        }
    }

    // Pattern 2: BinaryExpression comparison operand
    if (!shouldPatch && parent && parent.type === 'BinaryExpression' && parent.right === lit) {
        const cmpOps = ['>', '<', '>=', '<=', '==', '!=', '===', '!=='];
        if (cmpOps.includes(parent.operator)) {
            context = 'comparison(' + parent.operator + ')';
            shouldPatch = true;
        }
    }

    // Pattern 3: LEFT operand of a comparison
    if (!shouldPatch && parent && parent.type === 'BinaryExpression' && parent.left === lit) {
        const cmpOps = ['>', '<', '>=', '<=', '==', '!=', '===', '!=='];
        if (cmpOps.includes(parent.operator)) {
            context = 'comparison-left(' + parent.operator + ')';
            shouldPatch = true;
        }
    }

    if (shouldPatch) {
        const label = varName || context;
        console.log('  [PATCH] ' + label + ' at offset ' + lit.start);
        replacements.push({
            start: lit.start,
            end: lit.end,
            replacement,
            context,
            varName
        });
        patchedCount++;
    } else {
        skippedCount++;
        const preview = code.slice(Math.max(0, lit.start - 30), lit.end + 20).replace(/\n/g, '\\n');
        console.log('  [SKIP]  unknown context at offset ' + lit.start + ': ...' + preview + '...');
    }
}

console.log('VAR_NAMES_FOR_REASSIGN:' + JSON.stringify(contextVarNames));
console.log(`\nSUMMARY: ${patchedCount} will be patched, ${skippedCount} skipped`);

const existingContextLimitRefs = findNodes(ast, n =>
    n.type === 'MemberExpression' &&
    n.object?.type === 'MemberExpression' &&
    n.object.object?.name === 'process' &&
    n.object.property?.name === 'env' &&
    n.property?.name === 'CLAUDE_CODE_CONTEXT_LIMIT'
);

if (patchedCount === 0) {
    if (existingContextLimitRefs.length > 0) {
        console.log('ALREADY_PATCHED');
        process.exit(2);
    }
    console.error('NOT_FOUND:No patchable 200000 literals found');
    process.exit(1);
}

// ============================================================
// Phase 2: Find env-loading functions (Ay8 and Ui analogues)
//
// Detection strategy (AST structure, name-agnostic):
//   1) Find all FunctionDeclarations whose body contains
//      Object.assign(process.env, ...)
//   2) Ay8 = the one with ForOfStatement (has for...of loops)
//   3) Ui  = the one without ForOfStatement (just assign + call chain)
// ============================================================

console.log('STEP:3 - Finding env-loading functions');

function hasProcessEnvAssign(funcNode) {
    const assignCalls = findNodes(funcNode, n =>
        n.type === 'CallExpression' &&
        n.callee?.type === 'MemberExpression' &&
        n.callee.object?.name === 'Object' &&
        n.callee.property?.name === 'assign' &&
        n.arguments?.length >= 2 &&
        n.arguments[0]?.type === 'MemberExpression' &&
        n.arguments[0].object?.name === 'process' &&
        n.arguments[0].property?.name === 'env'
    );
    return assignCalls.length > 0;
}

const allFuncDecls = findNodes(ast, n => n.type === 'FunctionDeclaration');

const envLoaderFuncs = allFuncDecls.filter(fn => hasProcessEnvAssign(fn));

if (envLoaderFuncs.length < 2) {
    console.error('NOT_FOUND:Cannot find env-loading functions (found ' + envLoaderFuncs.length + ', need >= 2)');
    process.exit(1);
}

for (const fn of envLoaderFuncs) {
    console.log('FOUND:env-loader = ' + fn.id.name + ' at offset ' + fn.start + ' [' + (fn.end - fn.start) + ' bytes]');
}

// ============================================================
// Check-only mode
// ============================================================
if (checkOnly) {
    console.log('NEEDS_PATCH');
    console.log('PATCH_COUNT:' + patchedCount);
    console.log('ENV_LOADERS:' + envLoaderFuncs.map(fn => fn.id.name).join(','));
    console.log('VAR_NAMES:' + JSON.stringify(contextVarNames));
    process.exit(1);
}

// ============================================================
// Phase 3: Apply patches
//
// 3a: Replace 200000 literals (reverse order to preserve positions)
// 3b: Inject re-assignment code at end of Ay8 and Ui
// ============================================================

let newCode = code;

function replaceAt(str, start, end, replacement) {
    return str.slice(0, start) + replacement + str.slice(end);
}

// 3b: Collect env-loader injection points (AST body.end - 1 = before closing brace)
const reassignExpr = '(+process.env.CLAUDE_CODE_CONTEXT_LIMIT||';
const reassignStmts = contextVarNames
    .map(name => name + '=' + reassignExpr + name + ')')
    .join(';');

for (const fn of envLoaderFuncs) {
    // body.end points to the char AFTER '}', so body.end - 1 = the '}' itself
    const insertAt = fn.body.end - 1;
    replacements.push({
        start: insertAt,
        end: insertAt,
        replacement: ';' + reassignStmts + ';',
        context: 'env-inject(' + fn.id.name + ')',
        varName: null
    });
    patchedCount++;
    console.log('PATCH:inject:' + fn.id.name + ' - Will inject at AST body.end-1 (offset ' + insertAt + ')');
}

// 3c: Apply ALL replacements (literals + injections) in one pass, reverse order
replacements.sort((a, b) => b.start - a.start);
for (const r of replacements) {
    newCode = replaceAt(newCode, r.start, r.end, r.replacement);
    console.log('PATCH:' + r.context + (r.varName ? ' (' + r.varName + ')' : '') + ' at offset ' + r.start);
}

// ============================================================
// Phase 4: Verify via AST re-parse
// ============================================================

let newAst;
try {
    newAst = acorn.parse(newCode, { ecmaVersion: 'latest', sourceType: 'module' });
    console.log('VERIFY:AST re-parse confirms valid syntax');
} catch (e) {
    console.error('VERIFY_FAILED:Patched code fails to parse: ' + e.message);
    process.exit(1);
}

// 4b. Verify env-var expressions exist in AST (MemberExpression process.env.CLAUDE_CODE_CONTEXT_LIMIT)
const envRefNodes = findNodes(newAst, n =>
    n.type === 'MemberExpression' &&
    n.object?.type === 'MemberExpression' &&
    n.object.object?.name === 'process' &&
    n.object.property?.name === 'env' &&
    n.property?.name === 'CLAUDE_CODE_CONTEXT_LIMIT'
);
console.log('VERIFY:process.env.CLAUDE_CODE_CONTEXT_LIMIT refs in AST: ' + envRefNodes.length);
if (envRefNodes.length < patchedCount) {
    console.error('VERIFY_FAILED:Expected >= ' + patchedCount + ' env refs, found ' + envRefNodes.length);
    process.exit(1);
}

// 4c. Verify each env-loader function now contains re-assignment
for (const fn of envLoaderFuncs) {
    const patchedFn = findNodes(newAst, n =>
        n.type === 'FunctionDeclaration' && n.id?.name === fn.id.name
    )[0];
    if (!patchedFn) {
        console.error('VERIFY_FAILED:' + fn.id.name + ' not found after patch');
        process.exit(1);
    }
    const hasEnvRef = findNodes(patchedFn, n =>
        n.type === 'MemberExpression' &&
        n.object?.type === 'MemberExpression' &&
        n.object.object?.name === 'process' &&
        n.object.property?.name === 'env' &&
        n.property?.name === 'CLAUDE_CODE_CONTEXT_LIMIT'
    ).length > 0;
    if (!hasEnvRef) {
        console.error('VERIFY_FAILED:' + fn.id.name + ' missing CLAUDE_CODE_CONTEXT_LIMIT ref after patch');
        process.exit(1);
    }
    console.log('VERIFY:' + fn.id.name + ' has CLAUDE_CODE_CONTEXT_LIMIT re-assignment');
}

// ============================================================
// Backup and write
// ============================================================
let backupPath = '';
if (process.env.CC_PATCH_SKIP_BACKUP === '1') {
    backupPath = process.env.CC_PATCH_BASELINE || (cliPath + '.cc-patch-baseline');
    if (!fs.existsSync(backupPath)) {
        fs.copyFileSync(cliPath, backupPath);
        console.log('BASELINE_CREATED:' + backupPath);
    }
    console.log('BACKUP:' + backupPath);
} else {
    const timestamp = new Date().toISOString().replace(/[:.]/g, '-').slice(0, 19);
    backupPath = cliPath + '.' + backupSuffix + '-' + timestamp;
    fs.copyFileSync(cliPath, backupPath);
    console.log('BACKUP:' + backupPath);
}

fs.writeFileSync(cliPath, shebang + newCode);
console.log('SUCCESS:' + patchedCount);
PATCH_EOF
}

write_patch_script_voice_mode() {
  local out="$1"
  local source
  source="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/original-scripts/claude-code-enable-voice-mode-darwin-arm64/apply-claude-code-enable-voice-mode.sh"
  if [[ ! -f "$source" ]]; then
    error "缺少 VoiceMode AST 引擎: $source"
    return 1
  fi
  if ! sed -n '/^cat > "\$PATCH_SCRIPT" << '\''PATCH_EOF'\''$/,/^PATCH_EOF$/p' "$source" | sed '1d;$d' >"$out"; then
    error "提取 VoiceMode AST 引擎失败"
    return 1
  fi
  if ! node - "$out" <<'NODE'
const fs = require('fs');
const scriptPath = process.argv[2];
const legacy = `const timestamp = new Date().toISOString().replace(/[:.]/g, '-').slice(0, 19);
const backupPath = cliPath + '.' + backupSuffix + '-' + timestamp;
fs.copyFileSync(cliPath, backupPath);
console.log('BACKUP:' + backupPath);`;
const managed = `let backupPath = '';
if (process.env.CC_PATCH_SKIP_BACKUP === '1') {
  backupPath = process.env.CC_PATCH_BASELINE || (cliPath + '.cc-patch-baseline');
  if (!fs.existsSync(backupPath)) {
    fs.copyFileSync(cliPath, backupPath);
    console.log('BASELINE_CREATED:' + backupPath);
  }
  console.log('BACKUP:' + backupPath);
} else {
  const timestamp = new Date().toISOString().replace(/[:.]/g, '-').slice(0, 19);
  backupPath = cliPath + '.' + backupSuffix + '-' + timestamp;
  fs.copyFileSync(cliPath, backupPath);
  console.log('BACKUP:' + backupPath);
}`;
const code = fs.readFileSync(scriptPath, 'utf8');
if (!code.includes(legacy)) process.exit(1);
fs.writeFileSync(scriptPath, code.replace(legacy, managed));
NODE
  then
    error "转换 VoiceMode 基线备份逻辑失败"
    return 1
  fi
}

# stubs — Task 4–7 replace with real heredocs
# auto-mode — real engine (ported from apply-claude-code-enable-auto-mode.sh)
write_patch_script_auto_mode() {
  local out="$1"
  cat >"$out" <<'PATCH_EOF'
const fs = require('fs');
const acorn = require(process.argv[2]);
const cliPath = process.argv[3];
const checkOnly = process.argv[4] === '--check';
const backupSuffix = process.env.BACKUP_SUFFIX || 'backup';

let code = fs.readFileSync(cliPath, 'utf-8');

// Preserve shebang
let shebang = '';
if (code.startsWith('#!')) {
    const idx = code.indexOf('\n');
    shebang = code.slice(0, idx + 1);
    code = code.slice(idx + 1);
}

// Version info — try comment header first, then sibling package.json
let version = 'unknown';
const headerMatch = code.slice(0, 1000).match(/Version:\s*([\d.]+)/);
if (headerMatch) {
    version = headerMatch[1];
} else {
    const path = require('path');
    try {
        const pkg = JSON.parse(fs.readFileSync(path.join(path.dirname(cliPath), 'package.json'), 'utf-8'));
        if (pkg.version) version = pkg.version;
    } catch {}
}
console.log('VERSION:' + version);

// ============================================================
// Parse AST
// ============================================================
let ast;
try {
    ast = acorn.parse(code, { ecmaVersion: 'latest', sourceType: 'module' });
} catch (e) {
    console.error('PARSE_ERROR:' + e.message);
    process.exit(1);
}

// AST helpers
function findNodes(node, predicate, results = []) {
    if (!node || typeof node !== 'object') return results;
    if (predicate(node)) results.push(node);
    for (const key in node) {
        if (key === 'start' || key === 'end' || key === 'type') continue;
        if (node[key] && typeof node[key] === 'object') {
            if (Array.isArray(node[key])) {
                node[key].forEach(child => findNodes(child, predicate, results));
            } else {
                findNodes(node[key], predicate, results);
            }
        }
    }
    return results;
}

const src = (node) => code.slice(node.start, node.end);

function replaceAt(str, s, e, repl) {
    return str.slice(0, s) + repl + str.slice(e);
}

// Find the nearest enclosing ReturnStatement for a node. acorn nodes do not
// carry parent pointers, so we collect every ReturnStatement and pick the
// innermost one whose [start,end) range contains the target.
function findEnclosingReturn(ast, target) {
    const all = findNodes(ast, n => n.type === 'ReturnStatement');
    let best = null;
    for (const r of all) {
        if (r.start <= target.start && target.end <= r.end) {
            if (!best || r.start > best.start) best = r;
        }
    }
    return best;
}

// Collect all replacements; apply from end to start to preserve offsets
let replacements = [];
let patchCount = 0;

// ============================================================
// Phase 1: Find the auto-mode model eligibility function
//
// Legacy (≤~2.1.201): nested BlockStatement first child, 1× return !0, ≥3× return !1
// 2.1.204+ (TBe-style): flat body, model denylist string literals, ≥2× return !1, 1× return !0
// Patch both by replacing entire body with {return !0}
// ============================================================
console.log('STEP:1 - Finding auto-mode model check function');

const allFuncDecls = findNodes(ast, n =>
    n.type === 'FunctionDeclaration' && n.params.length === 1
);

function isReturnBoolLiteral(n, boolAsZeroOrOne) {
    // return !0  (true) or return !1 (false) in minified form
    return n.type === 'ReturnStatement' && n.argument &&
        n.argument.type === 'UnaryExpression' && n.argument.operator === '!' &&
        n.argument.argument && n.argument.argument.type === 'Literal' &&
        n.argument.argument.value === boolAsZeroOrOne;
}

// Shape A: legacy nested-block gate
const oQqCandidatesLegacy = allFuncDecls.filter(fn => {
    const body = fn.body;
    if (body.type !== 'BlockStatement') return false;
    const stmts = body.body;
    if (stmts.length < 2) return false;
    if (stmts[0].type !== 'BlockStatement') return false;
    if (stmts[stmts.length - 1].type !== 'ReturnStatement') return false;

    const rets0 = findNodes(fn, n => isReturnBoolLiteral(n, 0));
    if (rets0.length !== 1) return false;
    const rets1 = findNodes(fn, n => isReturnBoolLiteral(n, 1));
    if (rets1.length < 3) return false;
    return true;
});

// Shape B: 2.1.204+ flat model denylist (TBe / w6e-style)
// 2.1.204 example:
//   function TBe(e){let t=lo(e),r=wn();if(!Z6t(r))return!1;if(t.includes("claude-3-")||...)return!1;...;return!0}
// 2.1.213 example (no anthropicAws token in body; still firstParty + denylist):
//   function w6e(e){let t=so(e),r=En();if(!D7t(r))return!1;if(t.includes("claude-3-")||...)return!1;if(r!=="firstParty"&&...)return!1;return!0}
// Call sites: supportsAutoMode / verifyAutoModeGateAccess.modelSupported
const oQqCandidatesFlat = allFuncDecls.filter(fn => {
    const body = fn.body;
    if (body.type !== 'BlockStatement') return false;
    const stmts = body.body;
    if (stmts.length < 2) return false;
    // Flat shape: first stmt is VariableDeclaration, not nested BlockStatement
    if (stmts[0].type === 'BlockStatement') return false;
    if (stmts[stmts.length - 1].type !== 'ReturnStatement') return false;
    // Size guard: model eligibility is a small gate, not a huge helper
    if (fn.end - fn.start > 800) return false;

    const rets0 = findNodes(fn, n => isReturnBoolLiteral(n, 0));
    if (rets0.length !== 1) return false;
    const rets1 = findNodes(fn, n => isReturnBoolLiteral(n, 1));
    if (rets1.length < 2) return false;

    const bodySrc = code.slice(fn.body.start, fn.body.end);
    // Must look like the auto-mode model denylist + provider gate.
    // anthropicAws is optional: present in 2.1.204 TBe, absent in 2.1.213 w6e.
    if (!bodySrc.includes('claude-3-')) return false;
    if (!bodySrc.includes('firstParty')) return false;
    if (!bodySrc.includes('claude-opus-4-') && !bodySrc.includes('claude-sonnet-4-')) return false;
    return true;
});

// Prefer flat matches that include more denylist markers; else legacy
function rankFlat(fn) {
    const s = code.slice(fn.body.start, fn.body.end);
    let score = 0;
    if (s.includes('firstParty')) score += 2;
    if (s.includes('anthropicAws')) score += 2;
    if (s.includes('claude-opus-4-0')) score += 1;
    if (s.includes('claude-sonnet-4-6')) score += 1;
    if (s.includes('haiku')) score += 1;
    return score;
}

let oQqCandidates = [];
if (oQqCandidatesFlat.length > 0) {
    oQqCandidates = oQqCandidatesFlat.slice().sort((a, b) => rankFlat(b) - rankFlat(a));
    console.log('FOUND:using flat TBe-style model eligibility detector (' + oQqCandidatesFlat.length + ' candidate(s))');
} else if (oQqCandidatesLegacy.length > 0) {
    oQqCandidates = oQqCandidatesLegacy;
    console.log('FOUND:using legacy nested-block model eligibility detector');
}

let oQqPatched = false;
let oQqName = '(unknown)';
let oQqFunc = null;

if (oQqCandidates.length === 0) {
    // Check if already patched: 1-param FuncDecl with body = {return !0}
    // Prefer ones previously matched as model gates via nearby string markers, else any small body
    const alreadyPatched = allFuncDecls.filter(fn => {
        const s = code.slice(fn.body.start, fn.body.end).replace(/\s+/g, '');
        return s === '{return!0}';
    });
    if (alreadyPatched.length > 0) {
        // Prefer a previously-known gate near auto-mode helpers if multiple
        oQqFunc = alreadyPatched[0];
        oQqName = oQqFunc.id.name;
        oQqPatched = true;
        console.log('FOUND:' + oQqName + ' already patched (body = {return !0})');
    } else {
        console.error('NOT_FOUND:Cannot find auto-mode model check function');
        process.exit(1);
    }
} else {
    oQqFunc = oQqCandidates[0];
    oQqName = oQqFunc.id.name;

    if (oQqCandidates.length > 1) {
        console.log('  [WARN] Found ' + oQqCandidates.length + ' candidates, using first: ' + oQqName);
    }

    console.log('FOUND:func = ' + oQqName + '(' + oQqFunc.params.map(p => p.name).join(',') +
        ') at offset ' + oQqFunc.start + ' [' + (oQqFunc.end - oQqFunc.start) + ' bytes]');

    // Check if already patched
    const bodySrc = code.slice(oQqFunc.body.start, oQqFunc.body.end);
    const normalizedBody = bodySrc.replace(/\s+/g, '');
    if (normalizedBody === '{return!0}') {
        console.log('FOUND:oQq already patched (body = {return !0})');
        oQqPatched = true;
    } else {
        const newBody = '{return !0}';
        replacements.push({
            start: oQqFunc.body.start,
            end: oQqFunc.body.end,
            replacement: newBody,
            label: oQqName + '.body → ' + newBody
        });
        patchCount++;
        console.log('FOUND:needs patching — ' + oQqName + ' body has ' +
            (oQqFunc.body.end - oQqFunc.body.start) + ' bytes of gate logic');
    }
}

// ============================================================
// Phase 2: Classifier unavailable → fail-open (deny → ask)
//
// Strategy A (≥2.1.163): Find the string literal
//   "Auto mode classifier unavailable, denying with retry guidance (fail closed)"
// then locate the sibling ObjectExpression in the same SequenceExpression
// that has property behavior:"deny", and replace "deny" with "ask".
//
// Strategy B (2.1.143–2.1.162, legacy): Find CallExpression where
//   arguments[0] = Literal "tengu_iron_gate_closed"
// and replace entire CallExpression with !1 (false).
// ============================================================
console.log('STEP:2 - Finding classifier unavailable fail-closed logic');

const UNAVAIL_ANCHOR = 'Auto mode classifier unavailable';
let ironGatePatched = false;

if (code.includes(UNAVAIL_ANCHOR)) {
    // Strategy A: hardcoded fail-closed (≥2.1.163)
    // Find the Literal node containing the anchor string
    const anchorLiterals = findNodes(ast, n =>
        n.type === 'Literal' &&
        typeof n.value === 'string' &&
        n.value.includes(UNAVAIL_ANCHOR)
    );

    if (anchorLiterals.length === 0) {
        console.error('NOT_FOUND:anchor string found in raw code but not in AST — possible encoding issue');
        process.exit(1);
    }

    console.log('FOUND:' + anchorLiterals.length + ' "classifier unavailable" anchor(s)');

    // Find the behavior:{deny|ask} decision object paired with each unavailable anchor.
    //
    // An anchor lives inside the leading log call of a ReturnStatement whose
    // argument is a SequenceExpression (comma operator):
    //   return T("Auto mode classifier unavailable, ...",{level:"warn"}),{behavior:"deny",...}
    // The fail-closed object is the SequenceExpression's LAST expression. Locating it
    // structurally (not by a fixed char window) avoids the brittle +300 offset that, on
    // recent builds, reached the NEXT function's deny objects and rewrote the wrong commas
    // — corrupting the file. Some anchors share the same decision object (the fall-back
    // path returns the question-dialog object `a` instead, with no behavior property);
    // those are skipped, and a dedup set guards against double-patching a shared object.
    let failClosedPatched = 0;
    const denyMarked = new Set();  // behavior value offsets already converted
    for (const anchor of anchorLiterals) {
        const ret = findEnclosingReturn(ast, anchor);
        if (!ret) {
            console.log('FOUND:no ReturnStatement wrapping anchor at offset ' + anchor.start);
            continue;
        }
        // Decision object: last expr of a SequenceExpression, else the return arg itself.
        let decObj = null;
        const arg = ret.argument;
        if (arg?.type === 'SequenceExpression') {
            const exprs = arg.expressions;
            decObj = exprs[exprs.length - 1];
        } else if (arg?.type === 'ObjectExpression') {
            decObj = arg;
        }
        if (!decObj || decObj.type !== 'ObjectExpression' ||
            !decObj.properties || decObj.properties.length === 0) {
            console.log('FOUND:no decision object in the unavailable ReturnStatement near offset ' + anchor.start);
            continue;
        }
        const behaviorProp = decObj.properties.find(p =>
            p.key && (p.key.name === 'behavior' || p.key.value === 'behavior'));
        if (!behaviorProp) {
            // Fall-back path: returns the question-dialog object (no behavior prop) — not fail-closed.
            console.log('FOUND:decision object has no behavior property near offset ' + anchor.start);
            continue;
        }
        const bv = behaviorProp.value;
        if (bv?.type === 'Literal' && bv.value === 'ask') {
            console.log('FOUND:classifier unavailable already patched to behavior:"ask" (anchor ' + anchor.start + ')');
            failClosedPatched++;
            continue;
        }
        if (bv?.type !== 'Literal' || bv.value !== 'deny') {
            console.log('FOUND:decision behavior is not "deny" near offset ' + anchor.start +
                ' (got ' + (bv ? src(bv) : 'none') + ') — skipping');
            continue;
        }
        if (denyMarked.has(bv.start)) {
            // Same object co-referenced by multiple anchors — already handled.
            failClosedPatched++;
            continue;
        }
        denyMarked.add(bv.start);
        replacements.push({
            start: bv.start,
            end: bv.end,
            replacement: '"ask"',
            label: 'classifier unavailable: behavior:"deny" → behavior:"ask" (anchor ' + anchor.start + ')'
        });
        patchCount++;
        failClosedPatched++;
    }

    if (failClosedPatched < anchorLiterals.length) {
        console.log('FOUND:patched ' + failClosedPatched + '/' + anchorLiterals.length + ' unavailable sites');
    }
} else if (code.includes('tengu_iron_gate_closed')) {
    // Strategy B: legacy flag-based control (2.1.143–2.1.162)
    const ironGateCalls = findNodes(ast, n =>
        n.type === 'CallExpression' &&
        n.arguments && n.arguments.length >= 2 &&
        n.arguments[0].type === 'Literal' &&
        n.arguments[0].value === 'tengu_iron_gate_closed'
    );

    if (ironGateCalls.length === 0) {
        console.log('FOUND:iron_gate string exists but no matching CallExpression — may be already patched');
        ironGatePatched = true;
    } else {
        const calleeName = src(ironGateCalls[0].callee);
        console.log('FOUND:' + ironGateCalls.length + ' iron_gate call site(s) via ' + calleeName + '() [legacy]');
        for (let i = 0; i < ironGateCalls.length; i++) {
            const call = ironGateCalls[i];
            const originalSrc = src(call);
            if (originalSrc === '!1') {
                console.log('FOUND:site ' + (i+1) + ' already locked to !1');
                continue;
            }
            replacements.push({
                start: call.start,
                end: call.end,
                replacement: '!1',
                label: 'iron_gate site ' + (i+1) + ': ' + originalSrc.slice(0, 60) + ' → !1'
            });
            patchCount++;
        }
        if (replacements.length === (oQqPatched ? 0 : 1)) {
            ironGatePatched = true;
            console.log('FOUND:all iron_gate sites already locked to !1');
        }
    }
} else {
    console.log('FOUND:no classifier unavailable anchor or iron_gate flag — skipping (pre-v2.1.143)');
    ironGatePatched = true;
}

// ============================================================
// Phase 3: Find classifier model selection function
//
// AST: FunctionDeclaration with 0 params containing
//   Literal "tengu_auto_mode_config" and MemberExpression ?.model
//   Last stmt returns session model (CallExpression or Identifier)
//
// Inject: if(process.env.CLAUDE_CLASSIFIER_MODEL)return process.env.CLAUDE_CLASSIFIER_MODEL;
//
// This env var is populated from:
//   - Shell environment
//   - settings.json → env.CLAUDE_CLASSIFIER_MODEL
//   - --settings flagSettings → env.CLAUDE_CLASSIFIER_MODEL
// All applied to process.env via Ae() before any conversation starts.
// ============================================================
console.log('STEP:3 - Finding classifier model selection function');

const ENV_VAR = 'CLAUDE_CLASSIFIER_MODEL';
const envGuard = 'if(process.env.' + ENV_VAR + ')return{value:process.env.' + ENV_VAR + ',src:"env"};';

const allFuncDecls0 = findNodes(ast, n =>
    n.type === 'FunctionDeclaration' && n.params.length === 0
);

// Find the classifier model function: legacy builds read tengu_auto_mode_config
// directly; split builds use a config helper and expose modelByMainModel.
const classifierModelCandidates = allFuncDecls0.filter(fn => {
    const bodySrc = src(fn.body);
    const legacyShape = bodySrc.includes('tengu_auto_mode_config');
    const splitShape = bodySrc.includes('modelByMainModel') && bodySrc.includes('src:"default"');
    if (!legacyShape && !splitShape) return false;

    // Must have ?.model or .model access
    const modelAccess = findNodes(fn.body, n =>
        n.type === 'MemberExpression' &&
        n.property && (n.property.name === 'model' || n.property.value === 'model')
    );
    if (modelAccess.length === 0) return false;

    // Must end with a return statement (fallback to session model)
    const stmts = fn.body.body;
    if (stmts.length === 0) return false;
    const lastStmt = stmts[stmts.length - 1];
    if (lastStmt.type !== 'ReturnStatement') return false;

    // Should be a relatively small selector, not a classifier request function.
    if (fn.end - fn.start > 1000) return false;

    return true;
});

let classifierPatched = false;
let classifierName = '(unknown)';
let classifierFunc = null;

if (classifierModelCandidates.length === 0) {
    // Check if already patched: look for the env guard string
    if (code.includes('process.env.' + ENV_VAR)) {
        console.log('FOUND:classifier model override already injected (process.env.' + ENV_VAR + ' found)');
        classifierPatched = true;
    } else {
        console.log('FOUND:no classifier model function found — skipping (may be pre-v2.1.136 or different structure)');
        classifierPatched = true;
    }
} else {
    classifierFunc = classifierModelCandidates[0];
    classifierName = classifierFunc.id.name;

    console.log('FOUND:classifierModel = ' + classifierName + '() at offset ' +
                classifierFunc.start + ' [' + (classifierFunc.end - classifierFunc.start) + ' bytes]');

    // Check if already patched
    const bodyStart = classifierFunc.body.start;
    const existingStart = code.slice(bodyStart, bodyStart + envGuard.length + 5);
    if (existingStart.includes('process.env.' + ENV_VAR)) {
        console.log('FOUND:' + classifierName + ' already has env var guard');
        classifierPatched = true;
    } else {
        // Show what the function currently does
        const hasCedarHollow = src(classifierFunc.body).includes('tengu_cedar_hollow');
        console.log('FOUND:needs patching — ' + classifierName + '() returns session model' +
                    (hasCedarHollow ? ' (with cedar_hollow override for opus-4-8)' : '') +
                    ' → injecting ' + ENV_VAR + ' env var check');

        const insertionPoint = classifierFunc.body.start + 1; // after '{'
        replacements.push({
            start: insertionPoint,
            end: insertionPoint,
            replacement: envGuard,
            label: classifierName + ': injected env var guard → ' + ENV_VAR
        });
        patchCount++;
    }
}

// ============================================================
// All already patched?
// ============================================================
if (oQqPatched && ironGatePatched && classifierPatched) {
    console.log('ALREADY_PATCHED');
    process.exit(2);
}

if (replacements.length === 0) {
    console.log('ALREADY_PATCHED');
    process.exit(2);
}

// ============================================================
// Check-only mode
// ============================================================
if (checkOnly) {
    console.log('NEEDS_PATCH');
    console.log('PATCH_COUNT:' + patchCount);
    console.log('OQQ_NAME:' + oQqName);
    if (classifierFunc) console.log('CLASSIFIER_NAME:' + classifierName);
    process.exit(1);
}

// ============================================================
// Phase 4: Apply all replacements (end-to-start order)
// ============================================================
console.log('STEP:4 - Applying ' + replacements.length + ' replacement(s)');

replacements.sort((a, b) => b.start - a.start);

let newCode = code;
for (const r of replacements) {
    newCode = replaceAt(newCode, r.start, r.end, r.replacement);
    console.log('PATCH:' + r.label);
}

// ============================================================
// Phase 5: Verify
// ============================================================

// 5a. Re-parse to confirm syntax is valid
let newAst;
try {
    newAst = acorn.parse(newCode, { ecmaVersion: 'latest', sourceType: 'module' });
    console.log('VERIFY:AST re-parse confirms valid syntax');
} catch (e) {
    console.error('VERIFY_FAILED:Patched code fails to parse: ' + e.message);
    process.exit(1);
}

// 5b. Verify oQq if it was patched
if (!oQqPatched) {
    const verifySig = code.slice(oQqFunc.start, oQqFunc.body.start);
    if (newCode.indexOf(verifySig) === -1) {
        console.error('VERIFY_FAILED:' + oQqName + ' function declaration corrupted');
        process.exit(1);
    }
    console.log('VERIFY:' + oQqName + ' function declaration intact');
}

// 5c. Verify classifier unavailable path is now fail-open
if (!ironGatePatched) {
    if (code.includes(UNAVAIL_ANCHOR)) {
        // Strategy A: verify behavior:"deny" near anchor is now "ask"
        const anchorLiterals = findNodes(newAst, n =>
            n.type === 'Literal' && typeof n.value === 'string' &&
            n.value.includes(UNAVAIL_ANCHOR)
        );
        for (const anchor of anchorLiterals) {
            // Reuse the same structural decision-object lookup as the patcher so the
            // check matches what was actually patched, not every behavior:"deny" in a
            // 300-char window (some belong to unrelated fall-back paths).
            const ret = findEnclosingReturn(newAst, anchor);
            if (!ret) continue;
            let decObj = null;
            const arg = ret.argument;
            if (arg?.type === 'SequenceExpression') {
                const exprs = arg.expressions;
                decObj = exprs[exprs.length - 1];
            } else if (arg?.type === 'ObjectExpression') {
                decObj = arg;
            }
            if (!decObj || decObj.type !== 'ObjectExpression') continue;
            const bp = decObj.properties.find(p =>
                p.key && (p.key.name === 'behavior' || p.key.value === 'behavior'));
            if (!bp) continue;  // fall-back path: no behavior property
            if (bp.value?.type === 'Literal' && bp.value.value === 'deny') {
                console.error('VERIFY_FAILED:classifier unavailable path still has behavior:"deny" after patch');
                process.exit(1);
            }
        }
        console.log('VERIFY:classifier unavailable path now uses behavior:"ask"');
    } else {
        // Strategy B (legacy): verify iron_gate calls removed
        const remaining = findNodes(newAst,
            n => n.type === 'CallExpression' && n.arguments?.length >= 2 &&
                 n.arguments[0].type === 'Literal' && n.arguments[0].value === 'tengu_iron_gate_closed'
        );
        if (remaining.length > 0) {
            console.error('VERIFY_FAILED:' + remaining.length + ' iron_gate call(s) still present after patch');
            process.exit(1);
        }
        console.log('VERIFY:all tengu_iron_gate_closed calls replaced with !1');
    }
}

// 5d. Verify classifier model env guard if it was patched
if (!classifierPatched) {
    if (!newCode.includes('process.env.' + ENV_VAR)) {
        console.error('VERIFY_FAILED:' + ENV_VAR + ' env var check not found after patch');
        process.exit(1);
    }
    console.log('VERIFY:' + classifierName + '() now checks process.env.' + ENV_VAR);
}

// ============================================================
// Backup and write
// ============================================================
// 管理器模式：只在真正写入前、且尚无基线时，保存唯一干净原件
let backupPath = '';
if (process.env.CC_PATCH_SKIP_BACKUP === '1') {
    backupPath = process.env.CC_PATCH_BASELINE || (cliPath + '.cc-patch-baseline');
    if (!fs.existsSync(backupPath)) {
        fs.copyFileSync(cliPath, backupPath);
        console.log('BASELINE_CREATED:' + backupPath);
    }
    console.log('BACKUP:' + backupPath);
} else {
    const timestamp = new Date().toISOString().replace(/[:.]/g, '-').slice(0, 19);
    backupPath = cliPath + '.' + backupSuffix + '-' + timestamp;
    fs.copyFileSync(cliPath, backupPath);
    console.log('BACKUP:' + backupPath);
}

fs.writeFileSync(cliPath, shebang + newCode);
console.log('SUCCESS:' + patchCount);
PATCH_EOF
}
# keybindings — real engine (ported from apply-claude-code-enable-keybindings-fix.sh)
write_patch_script_keybindings() {
  local out="$1"
  cat >"$out" <<'PATCH_EOF'
const fs = require('fs');
const acornPath = process.argv[2];
const acorn = require(acornPath);

const cliPath = process.argv[3];
const checkOnly = process.argv[4] === '--check';
const backupSuffix = process.env.BACKUP_SUFFIX || 'backup';

let code = fs.readFileSync(cliPath, 'utf-8');

// Preserve shebang
let shebang = '';
if (code.startsWith('#!')) {
    const idx = code.indexOf('\n');
    shebang = code.slice(0, idx + 1);
    code = code.slice(idx + 1);
}

// ============================================================
// Fix: Force-enable keybinding customization by patching tengu_keybinding_customization_release flag
// ============================================================

let fixes = {
    featureFlag: { found: false, patched: false, node: null },
    ctrlCBinding: { found: false, patched: false, node: null },
};

// Parse AST
let ast;
try {
    ast = acorn.parse(code, { ecmaVersion: "latest", sourceType: 'module' });
} catch (e) {
    console.error('PARSE_ERROR:' + e.message);
    process.exit(1);
}

// AST walker
function findNodes(node, predicate, results = []) {
    if (!node || typeof node !== 'object') return results;
    if (predicate(node)) results.push(node);
    for (const key in node) {
        if (node[key] && typeof node[key] === 'object') {
            if (Array.isArray(node[key])) {
                node[key].forEach(child => findNodes(child, predicate, results));
            } else {
                findNodes(node[key], predicate, results);
            }
        }
    }
    return results;
}

const src = (node) => code.slice(node.start, node.end);

// ============================================================
// Patch 1: Force-enable tengu_keybinding_customization_release
//
// Target: fn("tengu_keybinding_customization_release", !1)
// ============================================================

const callExprs = findNodes(ast, n =>
    n.type === 'CallExpression' &&
    n.arguments &&
    n.arguments.length === 2 &&
    n.arguments[0].type === 'Literal' &&
    n.arguments[0].value === 'tengu_keybinding_customization_release'
);

let calleeName = '';
let flagAlreadyPatched = false;

for (const call of callExprs) {
    calleeName = src(call.callee);
    const secondArg = call.arguments[1];

    if (secondArg.type === 'UnaryExpression' &&
        secondArg.operator === '!' &&
        secondArg.argument.type === 'Literal' &&
        secondArg.argument.value === 1) {
        fixes.featureFlag.found = true;
        fixes.featureFlag.node = secondArg;
        console.log('FOUND:featureFlag ' + calleeName + '("tengu_keybinding_customization_release", !1)');
        break;
    }

    if ((secondArg.type === 'UnaryExpression' && secondArg.operator === '!' &&
         secondArg.argument.type === 'Literal' && secondArg.argument.value === 0) ||
        (secondArg.type === 'Literal' && secondArg.value === true)) {
        flagAlreadyPatched = true;
        console.log('FOUND:featureFlag already enabled');
        break;
    }

    if (secondArg.type === 'Literal' && secondArg.value === false) {
        fixes.featureFlag.found = true;
        fixes.featureFlag.node = secondArg;
        console.log('FOUND:featureFlag ' + calleeName + '("tengu_keybinding_customization_release", false)');
        break;
    }
}

if (!fixes.featureFlag.found && !flagAlreadyPatched) {
    console.error('NOT_FOUND:Unable to locate tengu_keybinding_customization_release feature flag');
    process.exit(1);
}

// ============================================================
// Patch 2: Change default ctrl+c binding from app:interrupt to app:exit
//
// Target AST: Property node where
//   key   = Literal "ctrl+c"
//   value = Literal "app:interrupt"
// inside the default bindings array (context: "Global")
// ============================================================

const ctrlCProps = findNodes(ast, n =>
    n.type === 'Property' &&
    n.key && n.key.type === 'Literal' && n.key.value === 'ctrl+c' &&
    n.value && n.value.type === 'Literal' && n.value.value === 'app:interrupt'
);

if (ctrlCProps.length > 0) {
    fixes.ctrlCBinding.found = true;
    fixes.ctrlCBinding.node = ctrlCProps[0].value;
    console.log('FOUND:ctrlCBinding "ctrl+c":"app:interrupt" -> will change to "app:exit"');
} else {
    // Check if already patched
    const patched = findNodes(ast, n =>
        n.type === 'Property' &&
        n.key && n.key.type === 'Literal' && n.key.value === 'ctrl+c' &&
        n.value && n.value.type === 'Literal' && n.value.value === 'app:exit'
    );
    if (patched.length > 0) {
        console.log('FOUND:ctrlCBinding already changed to app:exit');
    } else {
        console.error('NOT_FOUND:Unable to locate "ctrl+c":"app:interrupt" in default bindings');
        process.exit(1);
    }
}

// ============================================================
// Check results
// ============================================================

const needsPatch = Object.values(fixes).some(f => f.found);
if (!needsPatch) {
    console.log('ALREADY_PATCHED');
    process.exit(2);
}

if (checkOnly) {
    console.log('NEEDS_PATCH');
    const count = Object.values(fixes).filter(f => f.found).length;
    console.log('PATCH_COUNT:' + count);
    process.exit(1);
}

// ============================================================
// Apply fixes
// ============================================================

let newCode = code;

function replaceAt(str, start, end, replacement) {
    return str.slice(0, start) + replacement + str.slice(end);
}

let replacements = [];

if (fixes.featureFlag.found && fixes.featureFlag.node) {
    const node = fixes.featureFlag.node;
    replacements.push({ start: node.start, end: node.end, replacement: '!0' });
    fixes.featureFlag.patched = true;
    console.log('PATCH:featureFlag - Changed default from !1 (false) to !0 (true)');
}

if (fixes.ctrlCBinding.found && fixes.ctrlCBinding.node) {
    const node = fixes.ctrlCBinding.node;
    replacements.push({ start: node.start, end: node.end, replacement: '"app:exit"' });
    fixes.ctrlCBinding.patched = true;
    console.log('PATCH:ctrlCBinding - Changed "ctrl+c" from "app:interrupt" to "app:exit"');
}

replacements.sort((a, b) => b.start - a.start);
for (const r of replacements) {
    newCode = replaceAt(newCode, r.start, r.end, r.replacement);
}

// ============================================================
// Verify and save
// ============================================================

const patchedCount = Object.values(fixes).filter(f => f.patched).length;
if (patchedCount === 0) {
    console.error('VERIFY_FAILED:No fixes were applied');
    process.exit(1);
}

if (fixes.featureFlag.patched) {
    const expected = calleeName + '("tengu_keybinding_customization_release",!0)';
    if (!newCode.includes(expected)) {
        console.error('VERIFY_FAILED:Expected "' + expected + '" not found after patch');
        process.exit(1);
    }
}

if (fixes.ctrlCBinding.patched) {
    if (!newCode.includes('"ctrl+c":"app:exit"')) {
        console.error('VERIFY_FAILED:Expected "ctrl+c":"app:exit" not found after patch');
        process.exit(1);
    }
}

// 管理器模式：只在真正写入前、且尚无基线时，保存唯一干净原件
let backupPath = '';
if (process.env.CC_PATCH_SKIP_BACKUP === '1') {
    backupPath = process.env.CC_PATCH_BASELINE || (cliPath + '.cc-patch-baseline');
    if (!fs.existsSync(backupPath)) {
        fs.copyFileSync(cliPath, backupPath);
        console.log('BASELINE_CREATED:' + backupPath);
    }
    console.log('BACKUP:' + backupPath);
} else {
    const timestamp = new Date().toISOString().replace(/[:.]/g, '-').slice(0, 19);
    backupPath = cliPath + '.' + backupSuffix + '-' + timestamp;
    fs.copyFileSync(cliPath, backupPath);
    console.log('BACKUP:' + backupPath);
}

fs.writeFileSync(cliPath, shebang + newCode);
console.log('SUCCESS:' + patchedCount);
PATCH_EOF
}
# transcript-dialog — real engine (ported from apply-claude-code-transcript-dialog-replay-fix.sh)
write_patch_script_transcript_dialog() {
  local out="$1"
  cat >"$out" <<'PATCH_EOF'
const fs = require('fs');
const acornPath = process.argv[2];
const acorn = require(acornPath);

const cliPath = process.argv[3];
const checkOnly = process.argv[4] === '--check';
const backupSuffix = process.env.BACKUP_SUFFIX || 'backup-transcript-dialog-replay';

let code = fs.readFileSync(cliPath, 'utf-8');

// Preserve shebang
let shebang = '';
if (code.startsWith('#!')) {
    const idx = code.indexOf('\n');
    shebang = code.slice(0, idx + 1);
    code = code.slice(idx + 1);
}

let ast;
try {
    ast = acorn.parse(code, { ecmaVersion: 'latest', sourceType: 'script' });
} catch (e) {
    console.error('PARSE_ERROR:' + e.message);
    process.exit(1);
}

function findNodes(node, predicate, results = []) {
    if (!node || typeof node !== 'object') return results;
    if (predicate(node)) results.push(node);
    for (const key in node) {
        const value = node[key];
        if (!value || typeof value !== 'object') continue;
        if (Array.isArray(value)) {
            for (const child of value) findNodes(child, predicate, results);
        } else {
            findNodes(value, predicate, results);
        }
    }
    return results;
}

function propName(prop) {
    if (!prop || !prop.key) return undefined;
    if (prop.key.type === 'Identifier') return prop.key.name;
    if (prop.key.type === 'Literal') return String(prop.key.value);
    return undefined;
}

function isIdentifier(node, name) {
    return node && node.type === 'Identifier' && node.name === name;
}

function isSubscribeMember(node, objName) {
    return node && node.type === 'MemberExpression' &&
        isIdentifier(node.object, objName) &&
        !node.computed &&
        node.property && node.property.type === 'Identifier' &&
        node.property.name === 'subscribe';
}

function findDeferredFactoryName(requestFn) {
    const calls = findNodes(requestFn, n =>
        n.type === 'VariableDeclarator' &&
        n.id && n.id.type === 'ObjectPattern' &&
        n.init && n.init.type === 'CallExpression' &&
        n.init.callee &&
        (n.init.callee.type === 'Identifier' || n.init.callee.type === 'MemberExpression') &&
        n.id.properties.some(p => propName(p) === 'promise') &&
        n.id.properties.some(p => propName(p) === 'resolve')
    );
    if (!calls[0]) return null;
    const callee = calls[0].init.callee;
    if (callee.type === 'Identifier') return callee.name;
    return code.slice(callee.start, callee.end);
}

function analyzeDialogChannelFactory(fn) {
    if (!fn.body || fn.body.type !== 'BlockStatement') return null;
    if (fn.params && fn.params.length !== 0) return null;
    // Safety guard for whole-body replacement: only patch the tiny dialog
    // channel factory shape used by affected versions. Refuse future variants
    // that add setup/cleanup/telemetry statements instead of dropping them.
    if (fn.body.body.length !== 2) return null;
    if (fn.body.body[0].type !== 'VariableDeclaration') return null;
    if (fn.body.body[1].type !== 'ReturnStatement') return null;

    const firstDecl = fn.body.body.find(stmt =>
        stmt.type === 'VariableDeclaration' &&
        stmt.declarations && stmt.declarations.length >= 5 &&
        stmt.declarations[0].id.type === 'Identifier' &&
        stmt.declarations[1].id.type === 'Identifier' &&
        stmt.declarations[2].id.type === 'Identifier' &&
        stmt.declarations[3].id.type === 'Identifier' &&
        stmt.declarations[4].id.type === 'Identifier' &&
        stmt.declarations[0].init?.type === 'CallExpression' &&
        stmt.declarations[1].init?.type === 'CallExpression' &&
        stmt.declarations[2].init?.type === 'CallExpression' &&
        stmt.declarations[3].init?.type === 'NewExpression' &&
        stmt.declarations[3].init.callee?.type === 'Identifier' &&
        stmt.declarations[3].init.callee.name === 'Map' &&
        stmt.declarations[4].init?.type === 'Literal' &&
        stmt.declarations[4].init.value === 0
    );
    if (!firstDecl) return null;

    const eventSignal = firstDecl.declarations[0].id.name;
    const cancelSignal = firstDecl.declarations[1].id.name;
    const updateSignal = firstDecl.declarations[2].id.name;
    const pendingMap = firstDecl.declarations[3].id.name;
    const counter = firstDecl.declarations[4].id.name;
    const eventSignalFactorySrc = code.slice(firstDecl.declarations[0].init.start, firstDecl.declarations[0].init.end);
    const cancelSignalFactorySrc = code.slice(firstDecl.declarations[1].init.start, firstDecl.declarations[1].init.end);
    const updateSignalFactorySrc = code.slice(firstDecl.declarations[2].init.start, firstDecl.declarations[2].init.end);

    const ret = fn.body.body.find(stmt => stmt.type === 'ReturnStatement' && stmt.argument?.type === 'ObjectExpression');
    if (!ret) return null;

    const propNames = ret.argument.properties.map(propName);
    const expectedPropNames = ['subscribe', 'onCancel', 'onUpdate', 'reply', 'request'];
    if (propNames.length !== expectedPropNames.length) return null;
    if (!expectedPropNames.every(name => propNames.includes(name))) return null;

    const props = new Map(ret.argument.properties.map(p => [propName(p), p]));
    const subscribeProp = props.get('subscribe');
    const onCancelProp = props.get('onCancel');
    const onUpdateProp = props.get('onUpdate');
    const replyProp = props.get('reply');
    const requestProp = props.get('request');
    if (!subscribeProp || !onCancelProp || !onUpdateProp || !replyProp || !requestProp) return null;
    if (!isSubscribeMember(onCancelProp.value, cancelSignal)) return null;
    if (!isSubscribeMember(onUpdateProp.value, updateSignal)) return null;

    const requestFn = requestProp.value;
    if (!requestFn || (requestFn.type !== 'FunctionExpression' && requestFn.type !== 'ArrowFunctionExpression')) return null;
    const deferredFactory = findDeferredFactoryName(requestFn);
    if (!deferredFactory) return null;

    const subscribeIsOld = isSubscribeMember(subscribeProp.value, eventSignal);
    const subscribeSrc = code.slice(subscribeProp.start, subscribeProp.end);
    const alreadyPatched = !subscribeIsOld &&
        subscribeSrc.includes('.values()') &&
        subscribeSrc.includes('queueMicrotask') &&
        code.slice(fn.body.start, fn.body.end).includes('event:');

    if (!subscribeIsOld && !alreadyPatched) return null;

    return {
        fn,
        eventSignal,
        cancelSignal,
        updateSignal,
        pendingMap,
        counter,
        eventSignalFactorySrc,
        cancelSignalFactorySrc,
        updateSignalFactorySrc,
        deferredFactory,
        subscribeIsOld,
        alreadyPatched
    };
}

function memberPropName(node) {
    if (!node || node.type !== 'MemberExpression') return undefined;
    if (!node.computed && node.property?.type === 'Identifier') return node.property.name;
    if (node.computed && node.property?.type === 'Literal') return String(node.property.value);
    return undefined;
}

function objectHasTrueProp(obj, name) {
    return obj && obj.type === 'ObjectExpression' && obj.properties.some(p =>
        propName(p) === name &&
        ((p.value?.type === 'Literal' && p.value.value === true) ||
         (p.value?.type === 'UnaryExpression' && p.value.operator === '!' && p.value.argument?.type === 'Literal' && p.value.argument.value === 0))
    );
}

function objectHasIdPropForVar(obj, name) {
    return obj && obj.type === 'ObjectExpression' && obj.properties.some(p =>
        propName(p) === 'id' && isIdentifier(p.value, name)
    );
}

function callsMemberProp(node, prop) {
    return findNodes(node, n =>
        n.type === 'CallExpression' &&
        n.callee?.type === 'MemberExpression' &&
        memberPropName(n.callee) === prop
    ).length > 0;
}

function statementExpressions(stmt) {
    if (!stmt) return [];
    if (stmt.type === 'ExpressionStatement') {
        if (stmt.expression.type === 'SequenceExpression') return stmt.expression.expressions;
        return [stmt.expression];
    }
    if (stmt.type === 'BlockStatement' && stmt.body.length === 1) return statementExpressions(stmt.body[0]);
    return [];
}

function isDismissCall(expr, loopVar) {
    return expr?.type === 'CallExpression' &&
        expr.callee?.type === 'MemberExpression' &&
        memberPropName(expr.callee) === 'dismiss' &&
        expr.arguments.length === 1 &&
        isIdentifier(expr.arguments[0], loopVar);
}

function isCancelledReplyCall(expr, loopVar) {
    if (expr?.type !== 'CallExpression') return false;
    if (expr.callee?.type !== 'MemberExpression') return false;
    if (memberPropName(expr.callee) !== 'reply') return false;
    const arg = expr.arguments[0];
    return objectHasTrueProp(arg, 'cancelled') && objectHasIdPropForVar(arg, loopVar);
}

function analyzeDialogHostCleanup(fn) {
    if (!fn.body || fn.body.type !== 'BlockStatement') return null;
    // The dialog host hook function has both an Ig.onClosed(...) subscription
    // and a React useEffect(...) that installs channel subscriptions.
    if (!callsMemberProp(fn, 'onClosed') || !callsMemberProp(fn, 'useEffect')) return null;

    let oldLoops = [];
    let patchedLoops = [];
    const loops = findNodes(fn, n => n.type === 'ForOfStatement');
    for (const loop of loops) {
        const decl = loop.left?.type === 'VariableDeclaration' ? loop.left.declarations?.[0] : null;
        const loopVar = decl?.id?.type === 'Identifier' ? decl.id.name : null;
        if (!loopVar) continue;
        const exprs = statementExpressions(loop.body);
        const dismiss = exprs.find(e => isDismissCall(e, loopVar));
        if (!dismiss) continue;
        const cancelledReply = exprs.find(e => isCancelledReplyCall(e, loopVar));
        if (cancelledReply) {
            oldLoops.push({ loop, loopVar, dismiss });
        } else if (exprs.length === 1) {
            patchedLoops.push({ loop, loopVar, dismiss });
        }
    }

    if (oldLoops.length > 1) {
        return { ambiguous: true, count: oldLoops.length };
    }
    if (oldLoops.length === 1) {
        return { fn, old: true, alreadyPatched: false, ...oldLoops[0] };
    }
    if (patchedLoops.length > 0) {
        return { fn, old: false, alreadyPatched: true, ...patchedLoops[0] };
    }
    return null;
}

const functions = findNodes(ast, n =>
    n.type === 'FunctionDeclaration' || n.type === 'FunctionExpression' || n.type === 'ArrowFunctionExpression'
);

// Fix point 1: requestDialog channel must replay pending requests to later hosts.
const factoryCandidates = functions.map(analyzeDialogChannelFactory).filter(Boolean);
const factoryTargets = factoryCandidates.filter(c => c.subscribeIsOld);
const factoryAlreadyPatched = factoryCandidates.some(c => c.alreadyPatched);
if (factoryTargets.length > 1) {
    console.error('NOT_FOUND:Found multiple dialog channel factory candidates; refusing ambiguous patch (' + factoryTargets.length + ')');
    process.exit(1);
}

// Fix point 2: dialog host unmount (screen switch) must not answer cancelled.
const cleanupCandidates = functions.map(analyzeDialogHostCleanup).filter(Boolean);
const ambiguousCleanup = cleanupCandidates.find(c => c.ambiguous);
if (ambiguousCleanup) {
    console.error('NOT_FOUND:Found multiple dialog cleanup loops in one host; refusing ambiguous patch (' + ambiguousCleanup.count + ')');
    process.exit(1);
}
const cleanupTargets = cleanupCandidates.filter(c => c.old);
const cleanupAlreadyPatched = cleanupCandidates.some(c => c.alreadyPatched);
if (cleanupTargets.length > 1) {
    console.error('NOT_FOUND:Found multiple dialog host cleanup candidates; refusing ambiguous patch (' + cleanupTargets.length + ')');
    process.exit(1);
}

if (factoryTargets.length === 0 && !factoryAlreadyPatched) {
    console.error('NOT_FOUND:Unable to locate old dialog channel factory (subscribe:<signal>.subscribe, pending Map, reply/request methods)');
    process.exit(1);
}
if (cleanupTargets.length === 0 && !cleanupAlreadyPatched) {
    console.error('NOT_FOUND:Unable to locate old dialog host cleanup cancellation loop');
    process.exit(1);
}

let replacements = [];

if (factoryTargets.length === 1) {
    const t = factoryTargets[0];
    const name = t.fn.id?.name || '<anonymous>';
    console.log('FOUND:dialog channel factory ' + name + ' at byte ' + t.fn.start);

    const H = t.eventSignal;
    const C = t.cancelSignal;
    const U = t.updateSignal;
    const Q = t.pendingMap;
    const K = t.counter;
    const eventSignalFactory = t.eventSignalFactorySrc;
    const cancelSignalFactory = t.cancelSignalFactorySrc;
    const updateSignalFactory = t.updateSignalFactorySrc;
    const deferredFactory = t.deferredFactory;

    const replacementBody = `{let ${H}=${eventSignalFactory},${C}=${cancelSignalFactory},${U}=${updateSignalFactory},${Q}=new Map,${K}=0;return{subscribe(CC_DIALOG_FIX_listener){let CC_DIALOG_FIX_unsub=${H}.subscribe(CC_DIALOG_FIX_listener);for(let CC_DIALOG_FIX_entry of ${Q}.values())queueMicrotask(()=>{if(${Q}.has(CC_DIALOG_FIX_entry.id))CC_DIALOG_FIX_listener(CC_DIALOG_FIX_entry.event)});return CC_DIALOG_FIX_unsub},onCancel:${C}.subscribe,onUpdate:${U}.subscribe,reply(CC_DIALOG_FIX_reply){let CC_DIALOG_FIX_entry=${Q}.get(CC_DIALOG_FIX_reply.id);if(!CC_DIALOG_FIX_entry)return;${Q}.delete(CC_DIALOG_FIX_reply.id),CC_DIALOG_FIX_entry.resolve(CC_DIALOG_FIX_reply)},request({kind:CC_DIALOG_FIX_kind,payload:CC_DIALOG_FIX_payload},CC_DIALOG_FIX_options){${K}+=1;let CC_DIALOG_FIX_id=\`dialog-\${${K}}\`,{promise:CC_DIALOG_FIX_promise,resolve:CC_DIALOG_FIX_resolve}=${deferredFactory}(),CC_DIALOG_FIX_signal=CC_DIALOG_FIX_options?.signal;if(CC_DIALOG_FIX_signal?.aborted)return queueMicrotask(()=>CC_DIALOG_FIX_resolve({id:CC_DIALOG_FIX_id,cancelled:!0})),{id:CC_DIALOG_FIX_id,replied:CC_DIALOG_FIX_promise,update:()=>{}};let CC_DIALOG_FIX_abort,CC_DIALOG_FIX_event={id:CC_DIALOG_FIX_id,kind:CC_DIALOG_FIX_kind,payload:CC_DIALOG_FIX_payload};if(${Q}.set(CC_DIALOG_FIX_id,{id:CC_DIALOG_FIX_id,event:CC_DIALOG_FIX_event,resolve:(CC_DIALOG_FIX_value)=>{if(CC_DIALOG_FIX_signal&&CC_DIALOG_FIX_abort)CC_DIALOG_FIX_signal.removeEventListener("abort",CC_DIALOG_FIX_abort);CC_DIALOG_FIX_resolve(CC_DIALOG_FIX_value)}}),CC_DIALOG_FIX_signal)CC_DIALOG_FIX_abort=()=>{if(${Q}.delete(CC_DIALOG_FIX_id))CC_DIALOG_FIX_resolve({id:CC_DIALOG_FIX_id,cancelled:!0}),${C}.emit(CC_DIALOG_FIX_id)},CC_DIALOG_FIX_signal.addEventListener("abort",CC_DIALOG_FIX_abort,{once:!0});return ${H}.emit(CC_DIALOG_FIX_event),{id:CC_DIALOG_FIX_id,replied:CC_DIALOG_FIX_promise,update:(CC_DIALOG_FIX_payload_update)=>{let CC_DIALOG_FIX_entry=${Q}.get(CC_DIALOG_FIX_id);if(CC_DIALOG_FIX_entry){CC_DIALOG_FIX_entry.event={...CC_DIALOG_FIX_entry.event,payload:CC_DIALOG_FIX_payload_update};${U}.emit({id:CC_DIALOG_FIX_id,payload:CC_DIALOG_FIX_payload_update})}}}}}}`;

    replacements.push({
        start: t.fn.body.start,
        end: t.fn.body.end,
        replacement: replacementBody,
        name: 'dialog-channel-replay'
    });
} else {
    console.log('FOUND:dialog channel factory already has pending replay');
}

if (cleanupTargets.length === 1) {
    const t = cleanupTargets[0];
    const name = t.fn.id?.name || '<anonymous>';
    const dismissSrc = code.slice(t.dismiss.start, t.dismiss.end);
    console.log('FOUND:dialog host cleanup ' + name + ' at byte ' + t.loop.start);
    replacements.push({
        start: t.loop.body.start,
        end: t.loop.body.end,
        replacement: dismissSrc + ';',
        name: 'dialog-host-nondestructive-cleanup'
    });
} else {
    console.log('FOUND:dialog host cleanup already avoids cancellation on unmount');
}

if (replacements.length === 0) {
    console.log('ALREADY_PATCHED');
    process.exit(2);
}

if (checkOnly) {
    console.log('NEEDS_PATCH');
    console.log('PATCH_COUNT:' + replacements.length);
    process.exit(1);
}

let newCode = code;
replacements.sort((a, b) => b.start - a.start);
for (const r of replacements) {
    newCode = newCode.slice(0, r.start) + r.replacement + newCode.slice(r.end);
    console.log('PATCH:' + r.name);
}

try {
    acorn.parse(newCode, { ecmaVersion: 'latest', sourceType: 'script' });
} catch (e) {
    console.error('VERIFY_FAILED:Patched cli.js failed to parse: ' + e.message);
    process.exit(1);
}

if (replacements.some(r => r.name === 'dialog-channel-replay') &&
    (!newCode.includes('CC_DIALOG_FIX_listener') || !newCode.includes('CC_DIALOG_FIX_entry.event'))) {
    console.error('VERIFY_FAILED:Dialog replay patch markers missing after rewrite');
    process.exit(1);
}
if (replacements.some(r => r.name === 'dialog-host-nondestructive-cleanup') &&
    /for\s*\([^)]*\)\s*[^;{}]*\.dismiss\([^)]*\)\s*,\s*[^;{}]*\.reply\(\{[^}]*cancelled/.test(newCode)) {
    console.error('VERIFY_FAILED:Old destructive cleanup pattern still appears after rewrite');
    process.exit(1);
}

// 管理器模式：只在真正写入前、且尚无基线时，保存唯一干净原件
let backupPath = '';
if (process.env.CC_PATCH_SKIP_BACKUP === '1') {
    backupPath = process.env.CC_PATCH_BASELINE || (cliPath + '.cc-patch-baseline');
    if (!fs.existsSync(backupPath)) {
        fs.copyFileSync(cliPath, backupPath);
        console.log('BASELINE_CREATED:' + backupPath);
    }
    console.log('BACKUP:' + backupPath);
} else {
    const timestamp = new Date().toISOString().replace(/[:.]/g, '-').slice(0, 19);
    backupPath = cliPath + '.' + backupSuffix + '-' + timestamp;
    fs.copyFileSync(cliPath, backupPath);
    console.log('BACKUP:' + backupPath);
}

fs.writeFileSync(cliPath, shebang + newCode);
console.log('SUCCESS:' + replacements.length);
PATCH_EOF
}

write_patch_script_ultracode() {
  local out="$1"
  cat >"$out" <<'PATCH_EOF'
const fs = require('fs');
const acorn = require(process.argv[2]);
const cliPath = process.argv[3];
const checkOnly = process.argv[4] === '--check';
const backupSuffix = process.env.BACKUP_SUFFIX || 'backup';

let code = fs.readFileSync(cliPath, 'utf-8');

let shebang = '';
if (code.startsWith('#!')) {
    const idx = code.indexOf('\n');
    shebang = code.slice(0, idx + 1);
    code = code.slice(idx + 1);
}

let version = 'unknown';
const headerMatch = code.slice(0, 1000).match(/Version:\s*([\d.]+)/);
if (headerMatch) {
    version = headerMatch[1];
} else {
    const path = require('path');
    try {
        const pkg = JSON.parse(fs.readFileSync(path.join(path.dirname(cliPath), 'package.json'), 'utf-8'));
        if (pkg.version) version = pkg.version;
    } catch {}
}
console.log('VERSION:' + version);

// ============================================================
// Parse AST
// ============================================================
let ast;
try {
    ast = acorn.parse(code, { ecmaVersion: 'latest', sourceType: 'module' });
} catch (e) {
    console.error('PARSE_ERROR:' + e.message);
    process.exit(1);
}

function findNodes(node, predicate, results = []) {
    if (!node || typeof node !== 'object') return results;
    if (predicate(node)) results.push(node);
    for (const key in node) {
        if (key === 'start' || key === 'end' || key === 'type') continue;
        if (node[key] && typeof node[key] === 'object') {
            if (Array.isArray(node[key])) {
                node[key].forEach(child => findNodes(child, predicate, results));
            } else {
                findNodes(node[key], predicate, results);
            }
        }
    }
    return results;
}

const src = (node) => code.slice(node.start, node.end);

function replaceAt(str, s, e, repl) {
    return str.slice(0, s) + repl + str.slice(e);
}

let replacements = [];
let patchCount = 0;
let patchedFlags = { gu: false, oa: false, za: false };

// ============================================================
// Phase 1: Find anchor functions by their capability literals
//
// QnH: FunctionDeclaration(1 param) containing "xhigh_effort"
// kj6: FunctionDeclaration(1 param) containing "max_effort"
// ============================================================
console.log('STEP:1 - Finding anchor functions (xhigh_effort + max_effort gates)');

const allFunc1 = findNodes(ast, n =>
    n.type === 'FunctionDeclaration' && n.params.length === 1
);

function findGateFunc(funcs, literal) {
    return funcs.filter(fn =>
        findNodes(fn.body, n =>
            n.type === 'CallExpression' &&
            n.arguments && n.arguments.length >= 2 &&
            n.arguments[1].type === 'Literal' &&
            n.arguments[1].value === literal
        ).length > 0
    );
}

const xhighCandidates = findGateFunc(allFunc1, 'xhigh_effort');
if (xhighCandidates.length === 0) {
    console.error('NOT_FOUND:Cannot find xhigh_effort gate function');
    process.exit(1);
}
const qnhFunc = xhighCandidates[0];
const qnhName = qnhFunc.id.name;
console.log('FOUND:QnH = ' + qnhName + '() — xhigh_effort gate');

const maxCandidates = findGateFunc(allFunc1, 'max_effort');
if (maxCandidates.length === 0) {
    console.error('NOT_FOUND:Cannot find max_effort gate function');
    process.exit(1);
}
const kj6Func = maxCandidates[0];
const kj6Name = kj6Func.id.name;
console.log('FOUND:kj6 = ' + kj6Name + '() — max_effort gate');

// ============================================================
// Phase 2: Find and patch Gu() — ultracode availability
//
// AST: FunctionDeclaration(1 param), single return,
//      calls QnH by name, has === void 0 check
//
// Patch: QnH(H) → QnH(H) || kj6(H)
// ============================================================
console.log('STEP:2 - Finding Gu() — ultracode availability gate');

const guCandidates = allFunc1.filter(fn => {
    const body = fn.body.body;
    if (!body || body.length !== 1 || body[0].type !== 'ReturnStatement') return false;
    const qnhCalls = findNodes(fn.body, n =>
        n.type === 'CallExpression' &&
        n.callee.type === 'Identifier' &&
        n.callee.name === qnhName
    );
    if (qnhCalls.length !== 1) return false;
    const voidChecks = findNodes(fn.body, n =>
        n.type === 'BinaryExpression' && n.operator === '===' &&
        ((n.right.type === 'UnaryExpression' && n.right.operator === 'void') ||
         (n.left.type === 'UnaryExpression' && n.left.operator === 'void'))
    );
    return voidChecks.length > 0;
});

if (guCandidates.length === 0) {
    console.error('NOT_FOUND:Cannot find Gu() — no 1-param FuncDecl calling ' + qnhName + ' with void 0 check');
    process.exit(1);
}

const guFunc = guCandidates[0];
const guName = guFunc.id.name;
const guParam = guFunc.params[0].name;
console.log('FOUND:Gu = ' + guName + '(' + guParam + ') at offset ' + guFunc.start);

const guQnhCall = findNodes(guFunc.body, n =>
    n.type === 'CallExpression' &&
    n.callee.type === 'Identifier' &&
    n.callee.name === qnhName
)[0];

// Check if already patched (kj6 call already present)
const guKj6Calls = findNodes(guFunc.body, n =>
    n.type === 'CallExpression' &&
    n.callee.type === 'Identifier' &&
    n.callee.name === kj6Name
);

if (guKj6Calls.length > 0) {
    console.log('FOUND:Gu already has ' + kj6Name + '() call — skipping');
    patchedFlags.gu = true;
} else {
    const addition = '||' + kj6Name + '(' + guParam + ')';
    replacements.push({
        start: guQnhCall.end,
        end: guQnhCall.end,
        replacement: addition,
        label: 'Gu: ' + qnhName + '(' + guParam + ') → ' + qnhName + '(' + guParam + ')' + addition
    });
    patchCount++;
    console.log('FOUND:Gu needs patching — adding ' + kj6Name + ' fallback');
}

// ============================================================
// Phase 3: Find and patch Oa() — effort resolver
//
// AST: FunctionDeclaration(2 params), calls both QnH and kj6,
//      contains string literals "xhigh", "max", "high"
//
// Target: the IfStatement where test is `L === "xhigh" && !QnH(H)`
//         and consequent returns "high".
// Patch: return "high" → return kj6(H) ? "max" : "high"
// ============================================================
console.log('STEP:3 - Finding Oa() — effort resolver');

const allFunc2 = findNodes(ast, n =>
    n.type === 'FunctionDeclaration' && n.params.length === 2
);

const oaCandidates = allFunc2.filter(fn => {
    const callsQnH = findNodes(fn.body, n =>
        n.type === 'CallExpression' &&
        n.callee.type === 'Identifier' &&
        n.callee.name === qnhName
    ).length > 0;
    const callsKj6 = findNodes(fn.body, n =>
        n.type === 'CallExpression' &&
        n.callee.type === 'Identifier' &&
        n.callee.name === kj6Name
    ).length > 0;
    if (!callsQnH || !callsKj6) return false;
    const hasXhigh = findNodes(fn.body, n =>
        n.type === 'Literal' && n.value === 'xhigh'
    ).length > 0;
    const hasMax = findNodes(fn.body, n =>
        n.type === 'Literal' && n.value === 'max'
    ).length > 0;
    const hasHigh = findNodes(fn.body, n =>
        n.type === 'Literal' && n.value === 'high'
    ).length > 0;
    return hasXhigh && hasMax && hasHigh;
});

if (oaCandidates.length === 0) {
    console.error('NOT_FOUND:Cannot find Oa() — no 2-param FuncDecl calling both ' + qnhName + ' and ' + kj6Name);
    process.exit(1);
}

const oaFunc = oaCandidates[0];
const oaName = oaFunc.id.name;
const oaModelParam = oaFunc.params[0].name;
console.log('FOUND:Oa = ' + oaName + '(' + oaModelParam + ', ...) at offset ' + oaFunc.start);

// Find the xhigh degradation IfStatement:
//   if (L === "xhigh" && !QnH(H)) return "high"
const oaIfStmts = findNodes(oaFunc.body, n => n.type === 'IfStatement');

let xhighDegradeIf = null;
let xhighDegradeReturn = null;

for (const ifStmt of oaIfStmts) {
    if (ifStmt.test.type !== 'LogicalExpression' || ifStmt.test.operator !== '&&') continue;

    const left = ifStmt.test.left;
    if (left.type !== 'BinaryExpression' || left.operator !== '===' ||
        !(left.right?.type === 'Literal' && left.right.value === 'xhigh')) continue;

    const right = ifStmt.test.right;
    if (right.type !== 'UnaryExpression' || right.operator !== '!') continue;
    if (right.argument?.type !== 'CallExpression' ||
        right.argument.callee?.name !== qnhName) continue;

    // Found the xhigh degradation IfStatement — inspect consequent
    xhighDegradeIf = ifStmt;

    // Three shapes exist across versions:
    //   Old (≤2.1.162): return "high"           (ReturnStatement)
    //   New (≥2.1.195): i = "high"              (ExpressionStatement + AssignmentExpression, right Literal)
    //   Patched / 2.1.204+: i = gBe(e)?"max":"high"  (AssignmentExpression, right ConditionalExpression)
    //                       OR bare ExpressionStatement without requiring right==="high" first
    let retStmt = null;
    let assignExpr = null;
    const cons = ifStmt.consequent;
    if (cons.type === 'ReturnStatement') retStmt = cons;
    else if (cons.type === 'BlockStatement' &&
             cons.body.length === 1 &&
             cons.body[0].type === 'ReturnStatement') {
        retStmt = cons.body[0];
    } else if (cons.type === 'ExpressionStatement' &&
               cons.expression.type === 'AssignmentExpression' &&
               cons.expression.operator === '=') {
        assignExpr = cons.expression;
    } else if (cons.type === 'BlockStatement' &&
               cons.body.length === 1 &&
               cons.body[0].type === 'ExpressionStatement' &&
               cons.body[0].expression.type === 'AssignmentExpression' &&
               cons.body[0].expression.operator === '=') {
        assignExpr = cons.body[0].expression;
    }
    if (!retStmt && !assignExpr) break;

    function isKj6MaxHighConditional(cond) {
        const testCallsKj6 = cond?.type === 'ConditionalExpression' &&
            cond.test?.type === 'CallExpression' &&
            cond.test.callee?.type === 'Identifier' &&
            cond.test.callee.name === kj6Name;
        const consequentIsMax = cond?.consequent?.type === 'Literal' &&
            cond.consequent.value === 'max';
        const altIsHigh = cond?.alternate?.type === 'Literal' &&
            cond.alternate.value === 'high';
        return testCallsKj6 && consequentIsMax && altIsHigh;
    }

    if (retStmt) {
        if (retStmt.argument?.type === 'Literal' && retStmt.argument.value === 'high') {
            // Unpatched old form: return "high"
            xhighDegradeReturn = retStmt.argument;
        } else if (isKj6MaxHighConditional(retStmt.argument)) {
            console.log('FOUND:' + oaName + ' xhigh degradation already patched (' + kj6Name + '→"max")');
            patchedFlags.oa = true;
        }
    } else if (assignExpr) {
        if (assignExpr.right?.type === 'Literal' && assignExpr.right.value === 'high') {
            // Unpatched assign form: i = "high"
            xhighDegradeReturn = assignExpr.right;
        } else if (isKj6MaxHighConditional(assignExpr.right)) {
            // Already patched assign form: i = gBe(e)?"max":"high"
            console.log('FOUND:' + oaName + ' xhigh degradation already patched (' + kj6Name + '→"max") [assign form]');
            patchedFlags.oa = true;
        } else {
            // Found xhigh&&!QnH but right-hand side is neither "high" nor expected conditional
            console.log('FOUND:xhigh assign RHS unexpected: ' + src(assignExpr.right).slice(0, 80));
        }
    }
    break;
}

if (!xhighDegradeIf) {
    console.error('NOT_FOUND:Cannot find xhigh degradation IfStatement (==="xhigh"&&!' + qnhName + ') in ' + oaName + '()');
    process.exit(1);
}

if (!patchedFlags.oa && xhighDegradeReturn) {
    console.log('FOUND:xhigh degradation at offset ' + xhighDegradeIf.start +
                ' — "high" → ' + kj6Name + '(' + oaModelParam + ')?"max":"high"');

    // Ensure space after `return` — minified code may have `return"high"` (no space)
    const charBefore = code[xhighDegradeReturn.start - 1];
    const spacer = (charBefore && /[a-zA-Z_$0-9]/.test(charBefore)) ? ' ' : '';

    replacements.push({
        start: xhighDegradeReturn.start,
        end: xhighDegradeReturn.end,
        replacement: spacer + kj6Name + '(' + oaModelParam + ')?"max":"high"',
        label: oaName + ': xhigh degrade "high" → ' + kj6Name + '(…)?"max":"high"'
    });
    patchCount++;
} else if (!patchedFlags.oa) {
    console.error('NOT_FOUND:Unexpected return structure in xhigh degradation of ' + oaName + '()');
    process.exit(1);
}

// ============================================================
// Phase 4: Find and patch za() — ultracode active check
//
// AST: FunctionDeclaration(3 params), single return statement,
//      contains BinaryExpression === "xhigh"
//
// Patch: Oa(H,_)==="xhigh" → (Oa(H,_)==="xhigh"||Oa(H,_)==="max")
// ============================================================
console.log('STEP:4 - Finding za() — ultracode active check');

const allFunc3 = findNodes(ast, n =>
    n.type === 'FunctionDeclaration' && n.params.length === 3
);

const zaCandidates = allFunc3.filter(fn => {
    const body = fn.body.body;
    if (!body || body.length !== 1 || body[0].type !== 'ReturnStatement') return false;
    const xhighComps = findNodes(fn.body, n =>
        n.type === 'BinaryExpression' && n.operator === '===' &&
        ((n.right?.type === 'Literal' && n.right.value === 'xhigh') ||
         (n.left?.type === 'Literal' && n.left.value === 'xhigh'))
    );
    return xhighComps.length > 0;
});

if (zaCandidates.length === 0) {
    console.error('NOT_FOUND:Cannot find za() — no 3-param FuncDecl with single return containing === "xhigh"');
    process.exit(1);
}
{
    const zaFunc = zaCandidates[0];
    const zaName = zaFunc.id.name;
    console.log('FOUND:za = ' + zaName + '(' + zaFunc.params.map(p => p.name).join(', ') + ') at offset ' + zaFunc.start);

    // Find the === "xhigh" comparison
    const xhighComp = findNodes(zaFunc.body, n =>
        n.type === 'BinaryExpression' && n.operator === '===' &&
        n.right?.type === 'Literal' && n.right.value === 'xhigh'
    )[0];

    if (!xhighComp) {
        console.error('NOT_FOUND:Cannot find === "xhigh" comparison in ' + zaName);
        process.exit(1);
    }

    // Check if already patched: look for "max" comparison in same function
    const maxComps = findNodes(zaFunc.body, n =>
        n.type === 'BinaryExpression' && n.operator === '===' &&
        n.right?.type === 'Literal' && n.right.value === 'max'
    );

    if (maxComps.length > 0) {
        console.log('FOUND:za already accepts "max" — skipping');
        patchedFlags.za = true;
    } else {
        // The comparison is: Oa(H,_)==="xhigh"
        // Replace with: (Oa(H,_)==="xhigh"||Oa(H,_)==="max")
        const oaCallSrc = src(xhighComp.left);
        const fullComparison = src(xhighComp);
        const replacement = '(' + fullComparison + '||' + oaCallSrc + '==="max")';

        replacements.push({
            start: xhighComp.start,
            end: xhighComp.end,
            replacement: replacement,
            label: 'za: ' + fullComparison + ' → ' + replacement
        });
        patchCount++;
        console.log('FOUND:za needs patching — adding "max" acceptance');
    }
}

// ============================================================
// All already patched?
// ============================================================
if (patchedFlags.gu && patchedFlags.oa && patchedFlags.za) {
    console.log('ALREADY_PATCHED');
    process.exit(2);
}

if (replacements.length === 0) {
    console.log('ALREADY_PATCHED');
    process.exit(2);
}

// ============================================================
// Check-only mode
// ============================================================
if (checkOnly) {
    console.log('NEEDS_PATCH');
    console.log('PATCH_COUNT:' + patchCount);
    process.exit(1);
}

// ============================================================
// Phase 5: Apply replacements (end-to-start order)
// ============================================================
console.log('STEP:5 - Applying ' + replacements.length + ' replacement(s)');

replacements.sort((a, b) => b.start - a.start);

let newCode = code;
for (const r of replacements) {
    newCode = replaceAt(newCode, r.start, r.end, r.replacement);
    console.log('PATCH:' + r.label);
}

// ============================================================
// Phase 6: Verify
// ============================================================

// 6a. Re-parse
let newAst;
try {
    newAst = acorn.parse(newCode, { ecmaVersion: 'latest', sourceType: 'module' });
    console.log('VERIFY:AST re-parse OK');
} catch (e) {
    console.error('VERIFY_FAILED:Patched code fails to parse: ' + e.message);
    process.exit(1);
}

// 6b. Verify Gu now calls kj6
if (!patchedFlags.gu) {
    const patchedGu = findNodes(newAst, n =>
        n.type === 'FunctionDeclaration' && n.id.name === guName
    )[0];
    if (!patchedGu) {
        console.error('VERIFY_FAILED:' + guName + ' not found after patch');
        process.exit(1);
    }
    const kj6InGu = findNodes(patchedGu.body, n =>
        n.type === 'CallExpression' &&
        n.callee.type === 'Identifier' &&
        n.callee.name === kj6Name
    );
    if (kj6InGu.length === 0) {
        console.error('VERIFY_FAILED:' + guName + ' does not call ' + kj6Name + ' after patch');
        process.exit(1);
    }
    console.log('VERIFY:' + guName + ' now calls ' + kj6Name + '()');
}

// 6c. Verify Oa xhigh degradation has kj6 conditional
if (!patchedFlags.oa) {
    const patchedOa = findNodes(newAst, n =>
        n.type === 'FunctionDeclaration' && n.id.name === oaName
    )[0];
    if (!patchedOa) {
        console.error('VERIFY_FAILED:' + oaName + ' not found after patch');
        process.exit(1);
    }
    const condExprs = findNodes(patchedOa.body, n =>
        n.type === 'ConditionalExpression' &&
        n.test?.type === 'CallExpression' &&
        n.test.callee?.type === 'Identifier' &&
        n.test.callee.name === kj6Name &&
        n.consequent?.type === 'Literal' &&
        n.consequent.value === 'max'
    );
    if (condExprs.length === 0) {
        console.error('VERIFY_FAILED:' + oaName + ' missing ' + kj6Name + '(…)?"max":"high" conditional');
        process.exit(1);
    }
    console.log('VERIFY:' + oaName + ' xhigh degradation now falls to "max" when supported');
}

// 6d. Verify za accepts "max"
if (!patchedFlags.za) {
    const patchedZaName = zaCandidates[0].id.name;
    const patchedZa = findNodes(newAst, n =>
        n.type === 'FunctionDeclaration' && n.id.name === patchedZaName
    )[0];
    if (!patchedZa) {
        console.error('VERIFY_FAILED:' + patchedZaName + ' not found after patch');
        process.exit(1);
    }
    const maxCompsVerify = findNodes(patchedZa.body, n =>
        n.type === 'BinaryExpression' && n.operator === '===' &&
        ((n.right?.type === 'Literal' && n.right.value === 'max') ||
         (n.left?.type === 'Literal' && n.left.value === 'max'))
    );
    if (maxCompsVerify.length === 0) {
        console.error('VERIFY_FAILED:' + patchedZaName + ' does not accept "max" after patch');
        process.exit(1);
    }
    console.log('VERIFY:' + patchedZaName + ' now accepts "max" as valid ultracode effort');
}

// ============================================================
// Backup and write
// ============================================================
// 管理器模式：只在真正写入前、且尚无基线时，保存唯一干净原件
let backupPath = '';
if (process.env.CC_PATCH_SKIP_BACKUP === '1') {
    backupPath = process.env.CC_PATCH_BASELINE || (cliPath + '.cc-patch-baseline');
    if (!fs.existsSync(backupPath)) {
        fs.copyFileSync(cliPath, backupPath);
        console.log('BASELINE_CREATED:' + backupPath);
    }
    console.log('BACKUP:' + backupPath);
} else {
    const timestamp = new Date().toISOString().replace(/[:.]/g, '-').slice(0, 19);
    backupPath = cliPath + '.' + backupSuffix + '-' + timestamp;
    fs.copyFileSync(cliPath, backupPath);
    console.log('BACKUP:' + backupPath);
}

fs.writeFileSync(cliPath, shebang + newCode);
console.log('FUNC_NAMES:' + guName + '|' + oaName + '|' + zaCandidates[0].id.name);
console.log('SUCCESS:' + patchCount);
PATCH_EOF
}

write_patch_script_computer_use() {
  local out="$1"
  cat >"$out" <<'PATCH_EOF'
const fs = require('fs');
const acorn = require(process.argv[2]);
const cliPath = process.argv[3];
const checkOnly = process.argv[4] === '--check';
const backupSuffix = process.env.BACKUP_SUFFIX || 'backup';

let code = fs.readFileSync(cliPath, 'utf-8');

let shebang = '';
if (code.startsWith('#!')) {
    const idx = code.indexOf('\n');
    shebang = code.slice(0, idx + 1);
    code = code.slice(idx + 1);
}

const src = (node) => code.slice(node.start, node.end);

// ============================================================
// AST walker
// ============================================================
function walk(node, visitor, parent) {
    if (!node || typeof node !== 'object') return;
    if (node.type) visitor(node, parent);
    for (const k of Object.keys(node)) {
        const c = node[k];
        if (Array.isArray(c)) c.forEach(x => walk(x, visitor, node));
        else if (c && typeof c === 'object' && c.type) walk(c, visitor, node);
    }
}

// ============================================================
// Parse AST
// ============================================================
let ast;
try {
    ast = acorn.parse(code, { ecmaVersion: 'latest', sourceType: 'module' });
} catch (e) {
    console.error('PARSE_ERROR:' + e.message);
    process.exit(1);
}

// ============================================================
// Fix tracking + AST node storage
// ============================================================
let fixes = {
    schema: { found: false, patched: false, node: null, parentNode: null },
    t0n:    { found: false, patched: false, node: null },
    s7r:    { found: false, patched: false, node: null },
};

// Settings schema values follow one of two Zod conventions; resolve the
// builders dynamically so the inserted computerUse* properties reuse the
// exact builders the build trusts. See resolveZodBuilders() in the schema walk.
let zodDirect = false;  // direct ZodRoot form (z.boolean()) vs wrapped factories (Lt())
let zodBool = null;   // boolean builder ref  (z | Lt)
let zodObj  = null;   // object  builder ref  (z | Te)
let zodEnum = null;   // enum    builder ref  (z | xr)
let stFn = null;     // truthy env-var parser: st, A6, ...
let ScFn = null;     // settings reader: Sc, K4, ...

// Already-patched sentinels
const SENTINEL_T0N = 'CLAUDE_CODE_COMPUTER_USE';
const SENTINEL_S7R = '"computerUseConfig"';

// ============================================================
// Extract st() and Sc() equivalents from the YC-equivalent function
//   YC-equivalent: the FunctionDeclaration whose body contains both
//     "autoCompactEnabled" and "DISABLE_AUTO_COMPACT"
//   Inside it:
//     st-equiv = callee of CallExpression(arg includes DISABLE_AUTO_COMPACT)
//     Sc-equiv = callee of CallExpression(arg[0] === "autoCompactEnabled")
// ============================================================
walk(ast, (node) => {
    if (stFn && ScFn) return;
    if (node.type !== 'FunctionDeclaration') return;
    const body = src(node);
    if (!body.includes('"autoCompactEnabled"')) return;
    if (!body.includes('DISABLE_AUTO_COMPACT')) return;

    walk(node, (n) => {
        if (n.type !== 'CallExpression' || n.callee?.type !== 'Identifier') return;
        const argSrc = n.arguments?.[0] ? src(n.arguments[0]) : '';
        if (!stFn && argSrc.includes('DISABLE_AUTO_COMPACT')) stFn = n.callee.name;
        if (!ScFn && n.arguments?.[0]?.value === 'autoCompactEnabled') ScFn = n.callee.name;
    });
    if (stFn && ScFn) {
        console.log('FOUND:helpers — st=' + stFn + ', Sc=' + ScFn +
            ' (from YC-equivalent: ' + node.id?.name + ')');
    }
});
if (!stFn || !ScFn) {
    console.error('NOT_FOUND:Could not extract st/Sc function names from YC-equivalent. Version unsupported.');
    process.exit(1);
}

// ============================================================
// Helper: unwrap a Zod chain to its leftmost node.
//   A schema Property value may be wrapped in a SequenceExpression — e.g.
//   `(0,Lt().boolean().optional().describe(...))` — or a ParenthesizedExpression.
//   unwrapZodExpr() peels those wrappers so the chain itself is visible.
//
// chainRoot() then walks the CallExpression chain (Lt().optional().describe())
// leftward until it reaches the node that reveals the convention:
//   - Identifier            → direct ZodRoot form (z.boolean()): one builder for all types
//   - CallExpression(callee=Identifier) → wrapped factory form (Lt()): one factory per type
// ============================================================
function unwrapZodExpr(expr) {
    let cur = expr;
    while (cur) {
        if (cur.type === 'SequenceExpression') {
            cur = cur.expressions?.[cur.expressions.length - 1] || null;
            continue;
        }
        if (cur.type === 'ParenthesizedExpression') {
            cur = cur.expression;
            continue;
        }
        break;
    }
    return cur;
}

function chainRoot(expr) {
    let cur = unwrapZodExpr(expr);
    while (cur?.type === 'CallExpression' && cur.callee?.type === 'MemberExpression') {
        cur = unwrapZodExpr(cur.callee.object);
    }
    return cur;
}

// ============================================================
// Patch 1 — Locate autoCompactEnabled Property in settings schema
//
// The settings schema is an ObjectExpression with 100+ properties. The
// autoCompactEnabled Property value is a Zod chain like
//   z.boolean().optional().describe("...compact conversation...")      (direct)
//   Lt().optional().describe("...compact conversation...")            (wrapped)
// possibly wrapped in a SequenceExpression/ParenthesizedExpression.
//
// The chain root determines the builder convention used build-wide; from it
// we resolve boolean/object/enum builder references for the insertion below.
// ============================================================
walk(ast, (node, parent) => {
    if (fixes.schema.found) return;
    if (node.type !== 'Property') return;
    if (node.key?.type !== 'Identifier' || node.key.name !== 'autoCompactEnabled') return;
    const zodExpr = unwrapZodExpr(node.value);
    if (zodExpr?.type !== 'CallExpression') return;
    if (parent?.type !== 'ObjectExpression' || parent.properties.length < 50) return;
    const valSrc = src(zodExpr);
    if (!valSrc.includes('compact conversation')) return;

    // Resolve Zod builder convention from autoCompactEnabled's chain root.
    //   direct  : root is an Identifier (a ZodRoot like z/b/v) — one builder
    //             serves boolean/object/enum via its .boolean()/.object()/.enum() methods.
    //   wrapped : root is a typed factory CallExpression (e.g. Lt()) — each type has its
    //             own minified factory, discovered from sibling schema properties below.
    const root = chainRoot(node.value);
    if (root?.type === 'Identifier') {
        zodDirect = true;
        zodBool = zodObj = zodEnum = root.name;
    } else if (root?.type === 'CallExpression' && root.callee?.type === 'Identifier') {
        zodDirect = false;
        zodBool = root.callee.name;   // boolean factory from autoCompactEnabled's chain
        // Discover object/enum factories by shape from the live schema so the inserted
        // computerUse* properties reuse the exact builders the build trusts.
        for (const p of parent.properties) {
            if (p.type !== 'Property' || !p.value) continue;
            const r = chainRoot(p.value);
            if (r?.type !== 'CallExpression' || r.callee?.type !== 'Identifier') continue;
            const a0 = r.arguments?.[0];
            if (!zodObj  && a0?.type === 'ObjectExpression') zodObj  = r.callee.name;
            if (!zodEnum && a0?.type === 'ArrayExpression')  zodEnum = r.callee.name;
            if (zodObj && zodEnum) break;
        }
    }
    if (!zodBool || (!zodDirect && (!zodObj || !zodEnum))) {
        console.error('NOT_FOUND:Could not resolve Zod builder(s) from autoCompactEnabled value (bool=' +
            zodBool + ', obj=' + zodObj + ', enum=' + zodEnum + ')');
        process.exit(1);
    }

    fixes.schema.found = true;
    fixes.schema.node = node;
    fixes.schema.parentNode = parent;
    console.log('FOUND:schema — Property[autoCompactEnabled] at ' + node.start +
        ' (parent ObjectExpression has ' + parent.properties.length + ' props, ' +
        (zodDirect ? ('direct zod=' + zodBool) : ('wrapped bool=' + zodBool + '()/obj=' + zodObj + '()/enum=' + zodEnum + '()')) + ')');
});

// ============================================================
// Patch 4 — Locate s7r-equivalent FunctionDeclaration (MUST run before Patch 2)
//
// Name-independent structural match:
//   FunctionDeclaration {
//     body.body = [ReturnStatement {
//       argument: ObjectExpression {
//         properties: [
//           SpreadElement { argument: Identifier },          (the config defaults var)
//           SpreadElement { argument: CallExpression {
//             arguments: [Literal("tengu_malort_pedway"), Identifier]  (same defaults var)
//           }}
//         ]
//       }
//     }]
//   }
// ============================================================
let s7rFnName = null;
walk(ast, (node) => {
    if (fixes.s7r.found) return;
    if (node.type !== 'FunctionDeclaration') return;
    const stmts = node.body?.body;
    if (!stmts || stmts.length !== 1) return;
    const ret = stmts[0];
    if (ret.type !== 'ReturnStatement') return;
    const obj = ret.argument;
    if (obj?.type !== 'ObjectExpression') return;
    if (obj.properties.length !== 2) return;
    const sp0 = obj.properties[0];
    if (sp0.type !== 'SpreadElement' || sp0.argument?.type !== 'Identifier') return;
    const sp1 = obj.properties[1];
    if (sp1.type !== 'SpreadElement' || sp1.argument?.type !== 'CallExpression') return;
    // Key: the call must have "tengu_malort_pedway" as first argument
    if (sp1.argument.arguments?.[0]?.value !== 'tengu_malort_pedway') return;
    // And the second argument must be the same Identifier as sp0
    if (sp1.argument.arguments?.[1]?.name !== sp0.argument.name) return;

    fixes.s7r.found = true;
    fixes.s7r.node = node;
    s7rFnName = node.id?.name;
    console.log('FOUND:s7r — ' + s7rFnName + '() at ' + node.start +
        ' [return{...' + sp0.argument.name + ',...' + sp1.argument.callee?.name +
        '("tengu_malort_pedway",' + sp0.argument.name + ')}]');
});

// ============================================================
// Patch 2 — Locate t0n-equivalent FunctionDeclaration
//
// Supports two observed shapes:
//
// 1) Legacy single-return gate:
//   function t0n(){ return t5d() && s7r().enabled }
//
// 2) Claude Code 2.1.211+ hipaa-wrapped gate:
//   function Ppo(){
//     if (Jse("hipaa")) return !1;
//     return fiy() && xps().enabled
//   }
//
// Matching rule (name-independent):
//   - last statement is return <subGate>() && <configFn>().enabled
//   - configFn must be the s7r-equivalent when that was found
//   - optional leading if(...)return false/!1 statements are allowed
// ============================================================
function isEnabledGateReturn(arg) {
    if (arg?.type !== 'LogicalExpression' || arg.operator !== '&&') return null;
    if (arg.left?.type !== 'CallExpression' || arg.left.callee?.type !== 'Identifier') return null;
    if (arg.right?.type !== 'MemberExpression') return null;
    if (arg.right.object?.type !== 'CallExpression' || arg.right.object.callee?.type !== 'Identifier') return null;
    if (arg.right.property?.name !== 'enabled') return null;
    const configFn = arg.right.object.callee.name;
    if (s7rFnName && configFn !== s7rFnName) return null;
    return {
        subGate: arg.left.callee.name,
        configFn
    };
}

function isFalseyReturn(stmt) {
    if (stmt?.type !== 'ReturnStatement') return false;
    const arg = stmt.argument;
    if (!arg) return false;
    if (arg.type === 'Literal' && (arg.value === false || arg.value === 0)) return true;
    if (arg.type === 'UnaryExpression' && arg.operator === '!' &&
        arg.argument?.type === 'Literal' && arg.argument.value === 1) return true;
    return false;
}

walk(ast, (node) => {
    if (fixes.t0n.found) return;
    if (node.type !== 'FunctionDeclaration') return;
    const stmts = node.body?.body;
    if (!stmts || stmts.length < 1 || stmts.length > 4) return;

    // Optional leading if (...) return false / !1 guards (e.g. hipaa).
    for (let i = 0; i < stmts.length - 1; i++) {
        const stmt = stmts[i];
        if (stmt.type !== 'IfStatement') return;
        if (stmt.alternate) return;
        if (!isFalseyReturn(stmt.consequent?.type === 'BlockStatement'
            ? stmt.consequent.body?.[0]
            : stmt.consequent)) return;
    }

    const ret = stmts[stmts.length - 1];
    if (ret.type !== 'ReturnStatement') return;
    const gate = isEnabledGateReturn(ret.argument);
    if (!gate) return;

    fixes.t0n.found = true;
    fixes.t0n.node = node;
    console.log('FOUND:t0n — ' + node.id?.name + '() at ' + node.start +
        ' [stmts=' + stmts.length + ' return ' + gate.subGate + '()&&' + gate.configFn + '().enabled]');
});

// ============================================================
// Check already-patched
// ============================================================
if (code.includes(SENTINEL_T0N))    { fixes.t0n.found = true;    fixes.t0n.patched = true;    console.log('FOUND:t0n — already patched (sentinel)'); }
if (code.includes(SENTINEL_S7R))    { fixes.s7r.found = true;    fixes.s7r.patched = true;    console.log('FOUND:s7r — already patched (sentinel)'); }
// Schema sentinel: both settings keys must exist in the same schema object.
const schemaProperties = fixes.schema.parentNode?.properties || [];
const schemaHasKey = (name) => schemaProperties.some((property) =>
    property.type === 'Property' && (property.key?.name === name || property.key?.value === name)
);
const schemaHasEnabled = schemaHasKey('computerUseEnabled');
const schemaHasConfig = schemaHasKey('computerUseConfig');
if (schemaHasEnabled && schemaHasConfig) {
    fixes.schema.patched = true;
    console.log('FOUND:schema — already patched (sentinel)');
}

const allAlreadyPatched = Object.values(fixes).every(f => f.found && f.patched);
if (allAlreadyPatched) {
    console.log('ALREADY_PATCHED');
    process.exit(2);
}

const anyNeedsPatch = Object.values(fixes).some(f => f.found && !f.patched);
if (!anyNeedsPatch) {
    const missing = Object.entries(fixes).filter(([,f]) => !f.found).map(([k]) => k).join(', ');
    console.error('NOT_FOUND:Could not locate AST nodes for: ' + missing + '. Version may be unsupported.');
    process.exit(1);
}

if (checkOnly) {
    console.log('NEEDS_PATCH');
    const count = Object.values(fixes).filter(f => f.found && !f.patched).length;
    console.log('PATCH_COUNT:' + count);
    process.exit(1);
}

// ============================================================
// Build replacements (applied end→start to preserve offsets)
// ============================================================
let replacements = [];

// --- Patch 1: insert after autoCompactEnabled Property.end ---
if (fixes.schema.found && !fixes.schema.patched && fixes.schema.node) {
    if (!zodBool || (!zodDirect && (!zodObj || !zodEnum))) {
        console.error('VERIFY_FAILED:Zod builders not resolved — cannot generate schema insertion');
        process.exit(1);
    }
    const insertAfter = fixes.schema.node.end;
    // Boolean base: direct → <root>.boolean(); wrapped → <boolFactory>() (already typed).
    const boolBase = zodDirect ? zodBool + '.boolean()' : zodBool + '()';
    let insertion = '';
    if (!schemaHasEnabled) {
        insertion += ',computerUseEnabled:' + boolBase + '.optional().describe("Enable computer use MCP server for desktop control (macOS only, default off)")';
    }
    if (!schemaHasConfig) {
        if (zodDirect) {
            insertion += ',computerUseConfig:' + zodObj + '.object({mouseAnimation:' + zodObj + '.boolean().optional(),' +
                'hideBeforeAction:' + zodObj + '.boolean().optional(),' +
                'clipboardGuard:' + zodObj + '.boolean().optional(),' +
                'coordinateMode:' + zodObj + '.enum(["pixels","normalized_0_100"]).optional()' +
                '}).optional().describe("Computer use sub-configuration overrides")';
        } else {
            // Wrapped: each field uses its typed factory directly (Lt()/xr()); the object
            // factory takes the shape as its first argument (Te({...})).
            insertion += ',computerUseConfig:' + zodObj + '({mouseAnimation:' + zodBool + '().optional(),' +
                'hideBeforeAction:' + zodBool + '().optional(),' +
                'clipboardGuard:' + zodBool + '().optional(),' +
                'coordinateMode:' + zodEnum + '(["pixels","normalized_0_100"]).optional()' +
                '}).optional().describe("Computer use sub-configuration overrides")';
        }
    }
    replacements.push({
        start: insertAfter,
        end: insertAfter,
        text: insertion,
        name: 'schema'
    });
    fixes.schema.patched = true;
    console.log('PATCH:schema — inserted computerUseEnabled + computerUseConfig (' +
        (zodDirect ? ('direct zod=' + zodBool) : ('wrapped ' + zodBool + '()/' + zodObj + '()/' + zodEnum + '()')) + ')');
}

// --- Patch 2: replace entire t0n FunctionDeclaration ---
//     Uses dynamically extracted stFn (st-equiv) and ScFn (Sc-equiv)
//     Preserves the original body (including hipaa early returns) as fallback.
if (fixes.t0n.found && !fixes.t0n.patched && fixes.t0n.node) {
    const fn = fixes.t0n.node;
    const fnName = fn.id.name;
    const originalBody = src(fn.body).replace(/^\{/, '').replace(/\}$/, '');
    const replacement =
        'function ' + fnName + '(){' +
            'if(' + stFn + '(process.env.CLAUDE_CODE_COMPUTER_USE))return!0;' +
            'var _cu=' + ScFn + '("computerUseEnabled",void 0);' +
            'if(_cu.source!=="default")return!!_cu.value;' +
            originalBody +
        '}';
    replacements.push({
        start: fn.start,
        end: fn.end,
        text: replacement,
        name: 't0n'
    });
    fixes.t0n.patched = true;
    console.log('PATCH:t0n — env(' + stFn + ') → settings(' + ScFn + ') → original body fallback');
}

// --- Patch 4: replace entire s7r FunctionDeclaration ---
//     Uses dynamically extracted ScFn (Sc-equiv)
//     Recovers jna-equiv and BR-equiv names from original AST node
if (fixes.s7r.found && !fixes.s7r.patched && fixes.s7r.node) {
    const fn = fixes.s7r.node;
    const fnName = fn.id.name;
    const retObj = fn.body.body[0].argument;
    const jnaName = retObj.properties[0].argument.name;
    const BRName = retObj.properties[1].argument.callee.name;
    const replacement =
        'function ' + fnName + '(){' +
            'var _b={...' + jnaName + ',...' + BRName + '("tengu_malort_pedway",' + jnaName + ')};' +
            'var _uo=' + ScFn + '("computerUseConfig",void 0);' +
            'if(_uo.source!=="default"&&typeof _uo.value==="object"&&_uo.value!==null)' +
                'return{..._b,..._uo.value};' +
            'return _b' +
        '}';
    replacements.push({
        start: fn.start,
        end: fn.end,
        text: replacement,
        name: 's7r'
    });
    fixes.s7r.patched = true;
    console.log('PATCH:s7r — computerUseConfig settings merge (Sc=' + ScFn + ')');
}

// ============================================================
// Apply replacements end→start
// ============================================================
replacements.sort((a, b) => b.start - a.start);
let newCode = code;
for (const r of replacements) {
    newCode = newCode.slice(0, r.start) + r.text + newCode.slice(r.end);
}

// ============================================================
// Post-patch verification: re-parse to ensure valid JS
// ============================================================
try {
    acorn.parse(newCode, { ecmaVersion: 'latest', sourceType: 'module' });
} catch (e) {
    console.error('VERIFY_FAILED:Patched code fails to parse: ' + e.message);
    process.exit(1);
}

// ============================================================
// Save
// ============================================================
const patchedCount = Object.values(fixes).filter(f => f.patched).length;
const failedNames = Object.entries(fixes)
    .filter(([, f]) => f.found && !f.patched)
    .map(([name]) => name);

if (patchedCount === 0) {
    console.error('VERIFY_FAILED:No fixes were applied');
    process.exit(1);
}
if (failedNames.length > 0) {
    console.log('WARN:partial — could not patch: ' + failedNames.join(', '));
}

let backupPath = '';
if (process.env.CC_PATCH_SKIP_BACKUP === '1') {
    backupPath = process.env.CC_PATCH_BASELINE || (cliPath + '.cc-patch-baseline');
    if (!fs.existsSync(backupPath)) {
        fs.copyFileSync(cliPath, backupPath);
        console.log('BASELINE_CREATED:' + backupPath);
    }
    console.log('BACKUP:' + backupPath);
} else {
    const timestamp = new Date().toISOString().replace(/[:.]/g, '-').slice(0, 19);
    backupPath = cliPath + '.' + backupSuffix + '-' + timestamp;
    fs.copyFileSync(cliPath, backupPath);
    console.log('BACKUP:' + backupPath);
}

fs.writeFileSync(cliPath, shebang + newCode);
console.log('SUCCESS:' + patchedCount);
PATCH_EOF
}

run_node_patch() {
  local id="$1"
  local mode="$2"   # check|apply
  local script check_arg="" output ec=0 target_info target_layout

  if [[ "$id" == "voice-mode" ]] && ! voice_mode_supported; then
    voice_mode_platform_error
    return 1
  fi
  if [[ "$id" == "voice-mode" ]] && ! voice_mode_assets_ready; then
    voice_mode_assets_error
    return 1
  fi

  if ! require_target_readable; then
    STATUS[$id]=error
    MSG[$id]="目标不可读"
    return 1
  fi
  if ! ensure_node || ! ensure_acorn; then
    STATUS[$id]=error
    MSG[$id]="缺少 node 或 acorn"
    return 1
  fi

  if [[ "$id" == "voice-mode" ]]; then
    set +e
    output=$(runtime_exec "$mode" "$CLI_PATH" "$id" 2>&1)
    ec=$?
    set -e
    LAST_OUTPUT="$output"
    parse_and_set_status "$id" "$mode" "$output" "$ec"
    return $?
  fi

  # 先刷新目标包身份（带缓存；inspect 失败时 target_layout 为空，走旧单文件回退）
  target_layout=""
  local inspect_ok=0
  if [[ -z "${TARGET_IDENTITY_LOADED:-}" ]]; then
    set +e
    target_info=$(runtime_exec inspect "$CLI_PATH" 2>&1)
    ec=$?
    set -e
    if [[ "$ec" -eq 0 ]]; then
      TARGET_IDENTITY_LOADED=1
      inspect_ok=1
      local line
      while IFS= read -r line || [[ -n "$line" ]]; do
        case "$line" in
          TARGET_PACKAGE:*) TARGET_PACKAGE="${line#TARGET_PACKAGE:}" ;;
          TARGET_VERSION:*) TARGET_VERSION="${line#TARGET_VERSION:}" ;;
          TARGET_LAYOUT:*) TARGET_LAYOUT="${line#TARGET_LAYOUT:}" ;;
        esac
      done <<< "$target_info"
    else
      # inspect 失败不缓存：保证后续补丁/刷新重新探测，且 cruce-reject 路径的
      # LAST_OUTPUT 仍持有本次 inspect 的原始错误输出（target_info 刚由命令替换赋值）。
      TARGET_PACKAGE="" TARGET_VERSION="" TARGET_LAYOUT=""
    fi
  elif [[ -n "${TARGET_LAYOUT:-}" ]]; then
    inspect_ok=1
  fi
  target_layout="${TARGET_LAYOUT:-}"

  # split-esm 与已接入统一引擎的补丁走 runtime check/apply（输出含 TARGET_* 身份行）。
  # context-limit/computer-use 仅在 inspect 成功（真实包结构）时走 runtime；
  # inspect 失败的合成单文件 fixture 仍走旧引擎以保持 single-CJS 回归行为。
  if [[ "$target_layout" == "split-esm" || \
        ( "$inspect_ok" -eq 1 && ( "$id" == "context-limit" || "$id" == "computer-use" ) ) ]]; then
    set +e
    output=$(runtime_exec "$mode" "$CLI_PATH" "$id" 2>&1)
    ec=$?
    set -e
    LAST_OUTPUT="$output"
    parse_and_set_status "$id" "$mode" "$output" "$ec"
    return $?
  fi

  # inspect 失败且目标声明 cruce：拒绝旧单文件写入路径
  if [[ "$inspect_ok" -eq 0 ]] && target_declares_cruce "$CLI_PATH"; then
    STATUS[$id]=error
    MSG[$id]="cruce 目标结构检查失败，已拒绝旧单文件写入路径"
    LAST_OUTPUT="${target_info:-}"
    return 1
  fi

  if [[ "$mode" == "apply" ]]; then
    # 引擎真正写入前才会创建基线（已应用则不写、不建基线）
    export CC_PATCH_SKIP_BACKUP=1
    export CC_PATCH_BASELINE
    CC_PATCH_BASELINE=$(baseline_path)
  else
    unset CC_PATCH_SKIP_BACKUP || true
  fi

  script=$(write_patch_script "$id") || return 1
  [[ "$mode" == "check" ]] && check_arg="--check"

  export BACKUP_SUFFIX
  BACKUP_SUFFIX=$(patch_suffix "$id")
  set +e
  # shellcheck disable=SC2086
  output=$(node "$script" "$ACORN_PATH" "$CLI_PATH" $check_arg 2>&1)
  ec=$?
  set -e
  rm -f "$script"
  LAST_OUTPUT="$output"
  parse_and_set_status "$id" "$mode" "$output" "$ec"
}

refresh_one() {
  local id="$1"
  run_node_patch "$id" check || true
}

# 全量检测全部补丁；quiet=1 时不打印进度（给 --check 用）
refresh_all() {
  local quiet="${1:-0}" id n=0 total=${#PATCH_IDS[@]}
  # 全量刷新：丢弃上次 inspect 缓存（含失败缓存），让本次刷新重新探测目标身份。
  # 用户在外部修复/更换目标后按 [r] 能拿到最新身份，而非复用陈旧的失败缓存。
  TARGET_IDENTITY_LOADED=""
  for id in "${PATCH_IDS[@]}"; do
    n=$((n + 1))
    if [[ "$quiet" != "1" ]]; then
      printf '\r%s检测中 (%d/%d): %s...%s' "$DIM" "$n" "$total" "$(patch_name "$id")" "$NC" >&2
    fi
    refresh_one "$id"
  done
  if [[ "$quiet" != "1" ]]; then
    printf '\r\033[K' >&2
  fi
}

count_status() {
  local want="$1" id n=0
  for id in "${PATCH_IDS[@]}"; do
    [[ "${STATUS[$id]:-unknown}" == "$want" ]] && n=$((n + 1))
  done
  printf '%s\n' "$n"
}

# temporary main (Tasks 2–3): path smoke + --check status print; full TUI in Task 8
# (replaced by Task 8 interactive TUI below)

clear_screen() {
  if [[ -t 1 ]]; then
    printf '\033[2J\033[H'
  fi
}

pause() {
  printf '\n按任意键继续...'
  if [[ -t 0 ]]; then
    # shellcheck disable=SC2162
    IFS= read -r -n 1 -s _ || true
    printf '\n'
  else
    # shellcheck disable=SC2162
    read _ || true
  fi
}

status_label() {
  case "${1:-unknown}" in
    applied) printf '%s✓ 已应用%s' "$GREEN" "$NC" ;;
    idle)    printf '%s· 未应用%s' "$DIM" "$NC" ;;
    error)   printf '%s! 错误%s' "$RED" "$NC" ;;
    *)       printf '%s? 未检测%s' "$YELLOW" "$NC" ;;
  esac
}

# 不含 ANSI 的状态文案（用于对齐列宽）
status_plain() {
  case "${1:-unknown}" in
    applied) printf '✓ 已应用' ;;
    idle)    printf '· 未应用' ;;
    error)   printf '! 错误' ;;
    *)       printf '? 未检测' ;;
  esac
}

# 显示宽度：ASCII=1，其它（含中文）=2
disp_width() {
  local s="$1"
  # node 为补丁引擎硬依赖，菜单对齐复用它
  node -e 'let s=process.argv[1],w=0;for(const c of s){const cp=c.codePointAt(0);w+=cp>127?2:1}process.stdout.write(String(w))' "$s"
}

# 按显示宽度右侧补空格
pad_right() {
  local s="$1" width="$2" n pad
  n=$(disp_width "$s")
  if (( n >= width )); then
    printf '%s' "$s"
    return
  fi
  pad=$((width - n))
  printf '%s%*s' "$s" "$pad" ''
}

applied_ids() {
  local id
  for id in "${PATCH_IDS[@]}"; do
    [[ "${STATUS[$id]:-}" == "applied" ]] && printf '%s\n' "$id"
  done
}

count_applied() { count_status applied; }

draw_header() {
  local a i e u=0 id
  a=$(count_status applied)
  i=$(count_status idle)
  e=$(count_status error)
  for id in "${PATCH_IDS[@]}"; do
    case "${STATUS[$id]:-}" in
      applied|idle|error) ;;
      *) u=$((u + 1)) ;;
    esac
  done
  printf '%sClaude Code 补丁管理器%s  v%s\n' "$BOLD" "$NC" "$VERSION"
  printf '%s\n' '----------------------------------------'
  if [[ -n "$CLI_PATH" ]]; then
    printf '目标:  %s\n' "$CLI_PATH"
  else
    printf '目标:  %s(未找到)%s\n' "$RED" "$NC"
  fi
  if [[ -n "${TARGET_PACKAGE:-}" ]]; then
    printf '包:    %s %s (%s)\n' "$TARGET_PACKAGE" "${TARGET_VERSION:-}" "${TARGET_LAYOUT:-}"
  elif [[ -n "$CLI_PATH" ]]; then
    load_target_identity 2>/dev/null || true
    if [[ -n "${TARGET_PACKAGE:-}" ]]; then
      printf '包:    %s %s (%s)\n' "$TARGET_PACKAGE" "${TARGET_VERSION:-}" "${TARGET_LAYOUT:-}"
    fi
  fi
  if [[ $((a + i + e)) -eq 0 ]]; then
    printf '状态:  %s尚未检测%s — 按 [r] 刷新全部，或进入补丁后按 [c]\n' "$YELLOW" "$NC"
  else
    printf '状态:  %s 已应用 · %s 未应用 · %s 错误' "$a" "$i" "$e"
    [[ "$u" -gt 0 ]] && printf ' · %s 未检测' "$u"
    printf '\n'
  fi
  printf '%s\n' '----------------------------------------'
}

draw_main() {
  clear_screen
  draw_header
  local idx=1 id st plain name note pad
  # 固定显示列宽：状态 9、补丁 16（须 ≥ 最长补丁名显示宽，否则说明列首字不齐）
  local name_w=16
  printf '  #  %s  %s  %s\n' "$(pad_right "状态" 9)" "$(pad_right "补丁" "$name_w")" "说明"
  for id in "${PATCH_IDS[@]}"; do
    st="${STATUS[$id]:-unknown}"
    plain=$(status_plain "$st")
    name=$(patch_name "$id")
    note=$(patch_note "$id")
    pad=$((9 - $(disp_width "$plain")))
    (( pad < 0 )) && pad=0
    printf '  %d  ' "$idx"
    status_label "$st"
    printf '%*s  %s  %s\n' "$pad" '' "$(pad_right "$name" "$name_w")" "$note"
    idx=$((idx + 1))
  done
  printf '%s\n' '----------------------------------------'
  printf '[1-7] 选择补丁   [a] 一键应用全部   [b] 备份当前   [r] 刷新全部   [p] 换路径   [q] 退出\n'
  if has_baseline 2>/dev/null; then
    printf '备份:  %s\n' "$(basename "$(baseline_path)")"
  else
    printf '备份:  %s尚未创建%s — 按 [b] 备份当前 cli.js\n' "$DIM" "$NC"
  fi
}

confirm_apply() {
  local id="$1" list="" x bp
  bp=$(baseline_path 2>/dev/null || true)
  printf '\n即将【应用】: %s\n' "$(patch_name "$id")"
  printf '目标:  %s\n' "$CLI_PATH"
  if has_baseline; then
    printf '备份:  已有 (%s)，本次不另存\n' "$(basename "$bp")"
  else
    printf '备份:  尚无 — 应用前将自动备份当前 cli.js\n'
  fi
  printf '当前已应用:\n'
  while IFS= read -r x; do
    [[ -n "$x" ]] && printf '  · %s\n' "$(patch_name "$x")" && list=1
  done < <(applied_ids)
  [[ -z "${list:-}" ]] && printf '  （无）\n'
  printf '\n确认执行？ [Y/n] '
  local ans
  read -r ans || true
  # 默认回车 = 确认
  [[ -z "$ans" || "$ans" == "y" || "$ans" == "Y" ]]
}

confirm_restore() {
  local id="$1" n ans x
  n=$(count_applied)
  printf '\n即将【还原】: %s\n' "$(patch_name "$id")"
  printf '目标:  %s\n' "$CLI_PATH"
  if has_baseline; then
    printf '策略:  从备份还原后，自动重打其它已应用补丁\n'
  else
    printf '策略:  无备份时回退旧式 cli.js.%s-* 文件\n' "$(patch_suffix "$id")"
  fi
  if [[ "$n" -ge 2 ]]; then
    printf '\n%s说明%s\n' "$YELLOW" "$NC"
    printf '当前已应用:\n'
    while IFS= read -r x; do
      [[ -n "$x" ]] && printf '  · %s%s\n' "$(patch_name "$x")" \
        "$([[ "$x" == "$id" ]] && echo '  ← 将移除' || echo '  ← 将重打')"
    done < <(applied_ids)
    printf '请输入 %syes%s 继续（其它任意键取消）: ' "$BOLD" "$NC"
    read -r ans || true
    [[ "$ans" == "yes" ]]
  else
    printf '\n确认执行？ [Y/n] '
    read -r ans || true
    [[ -z "$ans" || "$ans" == "y" || "$ans" == "Y" ]]
  fi
}

show_detail() {
  local id="$1" choice before after
  while true; do
    clear_screen
    draw_header
    printf '\n%s\n' "$(patch_name "$id")"
    printf '%s\n\n' "$(patch_purpose "$id")"
    printf '状态: '; status_label "${STATUS[$id]:-unknown}"; printf '\n'
    printf '详情: %s\n' "${MSG[$id]:-}"
    printf '补丁 id: %s\n' "$id"
    if has_baseline; then
      printf '备份: %s\n\n' "$(basename "$(baseline_path)")"
    else
      printf '备份: (尚未创建)\n\n'
    fi
    printf '[a] 应用  [r] 还原本补丁  [c] 检测  [b] 返回\n'
    printf '请选择: '
    if ! read -r choice; then
      return 0
    fi
    case "$choice" in
      a|A)
        if ! require_target_writable; then
          error "目标不存在或不可写"; pause; continue
        fi
        if confirm_apply "$id"; then
          if run_node_patch "$id" apply; then
            success "应用完成: ${MSG[$id]}"
            if has_baseline; then
              info "备份: $(baseline_path)"
            fi
            warning "请重启 Claude Code 使更改生效"
            # 只复检当前补丁，避免对 18MB cli.js 连跑全部 AST 引擎
            info "正在复检当前补丁..."
            refresh_one "$id"
          else
            error "应用失败: ${MSG[$id]}"
            info "正在复检当前补丁..."
            refresh_one "$id"
          fi
        else
          info "已取消"
        fi
        pause
        ;;
      r|R)
        if ! require_target_writable; then
          error "目标不存在或不可写"; pause; continue
        fi
        if confirm_restore "$id"; then
          if restore_patch "$id"; then
            info "正在复检全部补丁..."
            refresh_all
          fi
        else
          info "已取消"
        fi
        pause
        ;;
      c|C)
        info "正在检测..."
        refresh_one "$id"
        ;;
      b|B|"") return 0 ;;
      *) warning "未知选项" ; pause ;;
    esac
  done
}

# 一键应用结束后的汇总：信任 apply 写入的 STATUS/MSG，不再 refresh_all
# 分类：applied +「已打补丁」→ 跳过；其它 applied → 成功；其余 → 失败
print_apply_all_summary() {
  local id st msg n_ok=0 n_skip=0 n_fail=0
  for id in "${PATCH_IDS[@]}"; do
    st="${STATUS[$id]:-}"
    msg="${MSG[$id]:-}"
    if [[ "$st" == "applied" && "$msg" == "已打补丁" ]]; then
      n_skip=$((n_skip + 1))
    elif [[ "$st" == "applied" ]]; then
      n_ok=$((n_ok + 1))
    else
      n_fail=$((n_fail + 1))
    fi
  done
  success "一键应用结束：${n_ok} 成功 · ${n_skip} 跳过 · ${n_fail} 失败"
  for id in "${PATCH_IDS[@]}"; do
    st="${STATUS[$id]:-}"
    msg="${MSG[$id]:-}"
    if [[ "$st" == "applied" && "$msg" == "已打补丁" ]]; then
      printf '  %s✓%s %s  %s\n' "$GREEN" "$NC" "$(patch_name "$id")" "$msg"
    elif [[ "$st" == "applied" ]]; then
      printf '  %s✓%s %s  %s\n' "$GREEN" "$NC" "$(patch_name "$id")" "$msg"
    else
      printf '  %s!%s %s  %s\n' "$RED" "$NC" "$(patch_name "$id")" "${msg:-未知错误}"
    fi
  done
}

# 一键应用全部补丁（极速路径：不预检、不复检；引擎幂等跳过已应用）
apply_all_patches() {
  local id ans n
  if ! require_target_writable; then
    error "目标不存在或不可写"
    return 1
  fi

  n=${#PATCH_IDS[@]}
  printf '\n即将【一键应用】全部 %s 个补丁:\n' "$n"
  for id in "${PATCH_IDS[@]}"; do
    printf '  · %s\n' "$(patch_name "$id")"
  done
  printf '目标:  %s\n' "$CLI_PATH"
  if has_baseline; then
    printf '备份:  已有，本次不另存\n'
  else
    printf '备份:  尚无 — 首次成功写入前自动建 baseline\n'
  fi
  printf '说明:  已应用的补丁会自动跳过，无需先按 [r] 检测\n'
  printf '\n确认执行？ [Y/n] '
  read -r ans || true
  if [[ -n "$ans" && "$ans" != "y" && "$ans" != "Y" ]]; then
    info "已取消"
    return 0
  fi

  for id in "${PATCH_IDS[@]}"; do
    info "应用: $(patch_name "$id")..."
    if run_node_patch "$id" apply; then
      success "  → ${MSG[$id]}"
    else
      error "  → 失败: ${MSG[$id]:-}"
    fi
  done

  print_apply_all_summary
  warning "请重启 Claude Code 使更改生效"
}

set_path_interactive() {
  local p
  printf '请输入 cli.js 的绝对路径: '
  read -r p || true
  if [[ -f "$p" ]]; then
    CLI_PATH="$p"
    TARGET_IDENTITY_LOADED=""
    STATUS=()
    MSG=()
    success "目标已设置（状态已清空，按 [r] 检测）"
  else
    error "不是可读文件: $p"
  fi
  pause
}

menu_loop() {
  local choice id
  # 启动不自动全量扫描：每次进程 STATUS 都是空的，所谓「首次」实际是每次启动。
  # 需要状态时再按 [r] 刷新全部，或进入补丁后按 [c] 只检当前。
  while true; do
    draw_main
    printf '请选择: '
    if ! read -r choice; then
      exit 0
    fi
    case "$choice" in
      q|Q) exit 0 ;;
      a|A)
        apply_all_patches
        pause
        ;;
      b|B)
        backup_current_cli
        pause
        ;;
      r|R)
        info "正在刷新全部补丁..."
        refresh_all
        ;;
      p|P) set_path_interactive ;;
      1|2|3|4|5|6|7)
        id="${PATCH_IDS[$((choice - 1))]}"
        show_detail "$id"
        ;;
      *) warning "未知选项"; pause ;;
    esac
  done
}

run_check_mode() {
  if ! require_target_readable; then
    error "未找到 cli.js 目标（请传入路径或设置 CLAUDE_CLI_PATH）"
    exit 1
  fi
  if ! ensure_node; then
    exit 1
  fi
  # --check 静默跑全量，进度不刷屏
  refresh_all 1 || true
  local id ec=0 st_cn
  printf '目标: %s\n' "$CLI_PATH"
  if [[ -n "${TARGET_PACKAGE:-}" ]]; then
    printf '包: %s %s (%s)\n' "$TARGET_PACKAGE" "${TARGET_VERSION:-}" "${TARGET_LAYOUT:-}"
  fi
  printf '\n'
  printf '%-18s %-10s %s\n' "ID" "状态" "说明"
  printf '%-18s %-10s %s\n' "------------------" "----------" "-------"
  for id in "${PATCH_IDS[@]}"; do
    case "${STATUS[$id]:-unknown}" in
      applied) st_cn="已应用" ;;
      idle)    st_cn="未应用" ;;
      error)   st_cn="错误" ;;
      *)       st_cn="未知" ;;
    esac
    printf '%-18s %-10s %s\n' "$id" "$st_cn" "${MSG[$id]:-}"
    [[ "${STATUS[$id]:-}" == "error" ]] && ec=1
  done
  exit "$ec"
}

main() {
  local mode="menu" path_arg=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --help|-h) usage; exit 0 ;;
      --check|-c) mode="check"; shift ;;
      -*)
        error "未知选项: $1"
        usage
        exit 1
        ;;
      *)
        path_arg="$1"
        shift
        ;;
    esac
  done

  resolve_target "${path_arg:-}" || true

  if [[ "$mode" == "check" ]]; then
    run_check_mode
  fi

  menu_loop
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
