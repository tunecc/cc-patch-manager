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
PATCH_IDS=(auto-mode keybindings transcript-dialog ultracode)

patch_name() {
  case "$1" in
    auto-mode) echo "自动模式解锁" ;;
    keybindings) echo "Ctrl+C 回滚" ;;
    transcript-dialog) echo "权限弹窗重放" ;;
    ultracode) echo "Ultracode 解锁" ;;
    *) echo "$1" ;;
  esac
}

patch_note() {
  case "$1" in
    auto-mode) echo "放开 Auto 模型门禁；分类器可自定义；不可用时改询问" ;;
    keybindings) echo "2.1 起 Ctrl+C 直接打断 Agent；打回旧退出习惯" ;;
    transcript-dialog) echo "Ctrl+O 看会话时审批卡 Waiting… / 被中断" ;;
    ultracode) echo "在只支持 max、不支持 xhigh 的模型上启用" ;;
    *) echo "" ;;
  esac
}

patch_suffix() {
  case "$1" in
    auto-mode) echo "backup-automode-model" ;;
    keybindings) echo "backup-keybindings-enable" ;;
    transcript-dialog) echo "backup-transcript-dialog-replay" ;;
    ultracode) echo "backup-ultracode" ;;
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
  esac
}

# In-memory status: applied | idle | error | unknown
declare -A STATUS=()
declare -A MSG=()

# Globals set by last run_node_patch / parse_and_set_status
LAST_OUTPUT=""
LAST_BACKUP=""

usage() {
  cat <<EOF
Claude Code 补丁管理器 v${VERSION}
四个社区常用 Claude Code 本地补丁的统一管理（中文交互）。

用法:
  $(basename "$0")                  进入交互菜单
  $(basename "$0") /path/to/cli.js  指定目标后进入菜单
  $(basename "$0") --check          打印四个补丁状态后退出
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
  )
  if command -v npm >/dev/null 2>&1; then
    local npm_root
    npm_root=$(npm root -g 2>/dev/null || true)
    if [[ -n "${npm_root:-}" ]]; then
      locations+=(
        "$npm_root/@anthropic-ai/claude-code/cli.js"
        "$npm_root/@cometix/claude-code/cli.js"
      )
    fi
  fi
  locations+=(
    "/usr/local/lib/node_modules/@anthropic-ai/claude-code/cli.js"
    "/usr/local/lib/node_modules/@cometix/claude-code/cli.js"
    "/usr/lib/node_modules/@anthropic-ai/claude-code/cli.js"
    "/usr/lib/node_modules/@cometix/claude-code/cli.js"
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
      return 0
    fi
    error "指定文件不存在: $arg"
    CLI_PATH=""
    return 1
  fi
  if [[ -n "${CLAUDE_CLI_PATH:-}" && -f "$CLAUDE_CLI_PATH" ]]; then
    CLI_PATH="$CLAUDE_CLI_PATH"
    return 0
  fi
  if CLI_PATH=$(find_cli_js); then
    return 0
  fi
  CLI_PATH=""
  return 1
}

require_target_readable() {
  [[ -n "$CLI_PATH" && -f "$CLI_PATH" && -r "$CLI_PATH" ]]
}

require_target_writable() {
  require_target_readable || return 1
  [[ -w "$CLI_PATH" && -w "$(dirname "$CLI_PATH")" ]]
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
# 备份策略：干净基线（golden baseline）只存一份
#
# 思路（类似系统还原点 / 干净镜像）：
#   - 第一次改 cli.js 前，若尚无基线，则复制一份干净原件
#     路径固定：<cli.js 同目录>/cli.js.cc-patch-baseline
#   - 之后每次 apply 不再按补丁另存时间戳备份（避免「谁是谁」）
#   - 还原某个补丁 = 回基线 + 重打「除该补丁外」原先已应用的其它补丁
#   - 一键还原干净 = 仅回基线
# ============================================================
baseline_path() {
  printf '%s.cc-patch-baseline\n' "$CLI_PATH"
}

has_baseline() {
  [[ -n "${CLI_PATH:-}" && -f "$(baseline_path)" ]]
}

# 若无基线则创建；已有则跳过。返回 0=就绪，1=失败
ensure_baseline() {
  local bp
  if ! require_target_writable; then
    error "目标不可写，无法创建基线备份: ${CLI_PATH:-无}"
    return 1
  fi
  bp=$(baseline_path)
  if [[ -f "$bp" ]]; then
    info "已有干净基线，跳过备份: $(basename "$bp")"
    LAST_BACKUP="$bp"
    return 0
  fi
  cp "$CLI_PATH" "$bp"
  success "已创建干净基线（仅此一次）: $bp"
  LAST_BACKUP="$bp"
  return 0
}

# 整文件回到干净基线
restore_baseline() {
  local bp
  if ! require_target_writable; then
    error "目标不可写: ${CLI_PATH:-无}"
    return 1
  fi
  bp=$(baseline_path)
  if [[ ! -f "$bp" ]]; then
    error "未找到干净基线: $bp"
    error "提示: 基线在第一次成功应用补丁前创建；若从未用本管理器改过，则无基线可还。"
    return 1
  fi
  cp "$bp" "$CLI_PATH"
  success "已还原到干净基线: $bp"
  return 0
}

# 还原单个补丁：回基线后重打其它已应用补丁（保持「一次干净备份」模型）
restore_patch() {
  local id="$1" other kept=() x
  if ! has_baseline; then
    # 兼容旧版按 suffix 的时间戳备份
    local suffix dir latest
    suffix=$(patch_suffix "$id")
    dir=$(dirname "$CLI_PATH")
    # shellcheck disable=SC2012
    latest=$(ls -t "$dir"/cli.js."${suffix}"-* 2>/dev/null | head -1 || true)
    if [[ -n "${latest:-}" ]]; then
      warning "无干净基线，回退使用旧式备份: $latest"
      cp "$latest" "$CLI_PATH"
      success "已从旧备份还原: $latest"
      return 0
    fi
    error "未找到干净基线，也无该补丁旧备份 (cli.js.$(patch_suffix "$id")-*)"
    return 1
  fi

  mapfile -t kept < <(applied_ids)
  info "还原「$(patch_name "$id")」= 回干净基线后重打其它补丁..."
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
  local line has_already=0 has_needs=0 has_success=0 has_err=0 err_msg=""

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
      BACKUP:*)
        LAST_BACKUP="${line#BACKUP:}"
        ;;
      BASELINE_CREATED:*)
        LAST_BACKUP="${line#BASELINE_CREATED:}"
        info "已创建干净基线: $LAST_BACKUP"
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
      FOUND:*|PATCH:*|STEP:*|VERSION:*|OQQ_NAME:*)
        # informational; keep last interesting in MSG if empty later
        ;;
    esac
  done <<< "$output"

  if [[ $has_err -eq 1 ]]; then
    STATUS[$id]=error
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
    *) error "未知补丁 id: $id"; rm -f "$tmp"; return 1 ;;
  esac
  printf '%s\n' "$tmp"
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

// Shape B: 2.1.204+ TBe(e) flat model denylist
// function TBe(e){let t=lo(e),r=wn();if(!Z6t(r))return!1;if(t.includes("claude-3-")||...)return!1;...;return!0}
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
    // Must look like the auto-mode model denylist + provider gate (TBe in 2.1.204)
    if (!bodySrc.includes('claude-3-')) return false;
    if (!bodySrc.includes('firstParty')) return false;
    if (!bodySrc.includes('anthropicAws')) return false;
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

    // Walk up: the anchor is inside a CallExpression (T("Auto mode...", {level:"warn"}))
    // which is part of a SequenceExpression (comma operator): T(...), {behavior:"deny",...}
    // which is the argument of a ReturnStatement.
    // We need to find the ObjectExpression with behavior:"deny" near the anchor.

    // Search for ObjectExpression nodes with behavior:"deny" that are close to the anchor
    // (within ~300 chars in source position)
    let failClosedPatched = 0;
    for (const anchor of anchorLiterals) {
        // Find all behavior:"deny" ObjectExpressions after the anchor (within 300 chars)
        const denyObjects = findNodes(ast, n =>
            n.type === 'ObjectExpression' &&
            n.start > anchor.start &&
            n.start < anchor.end + 300 &&
            n.properties && n.properties.some(p =>
                p.key && (p.key.name === 'behavior' || p.key.value === 'behavior') &&
                p.value && p.value.type === 'Literal' && p.value.value === 'deny'
            )
        );

        if (denyObjects.length === 0) {
            // Check if already patched to "ask"
            const askObjects = findNodes(ast, n =>
                n.type === 'ObjectExpression' &&
                n.start > anchor.start &&
                n.start < anchor.end + 300 &&
                n.properties && n.properties.some(p =>
                    p.key && (p.key.name === 'behavior' || p.key.value === 'behavior') &&
                    p.value && p.value.type === 'Literal' && p.value.value === 'ask'
                )
            );
            if (askObjects.length > 0) {
                console.log('FOUND:classifier unavailable already patched to behavior:"ask"');
                failClosedPatched++;
                continue;
            }
            console.log('FOUND:no behavior:"deny" found near anchor at offset ' + anchor.start);
            continue;
        }

        // Patch the first matching deny → ask
        const denyObj = denyObjects[0];
        const behaviorProp = denyObj.properties.find(p =>
            (p.key.name === 'behavior' || p.key.value === 'behavior') &&
            p.value.type === 'Literal' && p.value.value === 'deny'
        );

        replacements.push({
            start: behaviorProp.value.start,
            end: behaviorProp.value.end,
            replacement: '"ask"',
            label: 'classifier unavailable: behavior:"deny" → behavior:"ask" (near offset ' + anchor.start + ')'
        });
        patchCount++;
        failClosedPatched++;
    }

    if (failClosedPatched === anchorLiterals.length) {
        // All anchors handled
    } else {
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

// Find the classifier model function: 0-param FuncDecl containing
// "tengu_auto_mode_config" literal AND ?.model member access
const classifierModelCandidates = allFuncDecls0.filter(fn => {
    const bodySrc = src(fn.body);
    if (!bodySrc.includes('tengu_auto_mode_config')) return false;

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

    // Should be a relatively small function (< 500 bytes)
    if (fn.end - fn.start > 500) return false;

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
            const stillDeny = findNodes(newAst, n =>
                n.type === 'ObjectExpression' &&
                n.start > anchor.start && n.start < anchor.end + 300 &&
                n.properties && n.properties.some(p =>
                    (p.key.name === 'behavior' || p.key.value === 'behavior') &&
                    p.value && p.value.type === 'Literal' && p.value.value === 'deny'
                )
            );
            if (stillDeny.length > 0) {
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

run_node_patch() {
  local id="$1"
  local mode="$2"   # check|apply
  local script check_arg="" output ec=0

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

# 全量检测四个补丁；quiet=1 时不打印进度（给 --check 用）
refresh_all() {
  local quiet="${1:-0}" id n=0 total=${#PATCH_IDS[@]}
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
  printf '[1-4] 选择补丁   [a] 一键应用全部   [r] 刷新全部   [p] 换路径   [q] 退出\n'
  if has_baseline 2>/dev/null; then
    printf '基线:  %s\n' "$(basename "$(baseline_path)")"
  else
    printf '基线:  %s尚未创建%s（首次应用时自动生成干净原件）\n' "$DIM" "$NC"
  fi
}

confirm_apply() {
  local id="$1" list="" x bp
  bp=$(baseline_path 2>/dev/null || true)
  printf '\n即将【应用】: %s\n' "$(patch_name "$id")"
  printf '目标:  %s\n' "$CLI_PATH"
  if has_baseline; then
    printf '备份:  已有干净基线，本次不再另存 (%s)\n' "$(basename "$bp")"
  else
    printf '备份:  将创建唯一干净基线 cli.js.cc-patch-baseline（仅首次）\n'
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
    printf '策略:  回干净基线后，自动重打其它已应用补丁\n'
  else
    printf '策略:  无基线时回退旧式 cli.js.%s-* 备份\n' "$(patch_suffix "$id")"
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
      printf '干净基线: %s\n\n' "$(basename "$(baseline_path)")"
    else
      printf '干净基线: (尚未创建)\n\n'
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
              info "干净基线: $(baseline_path)"
            fi
            warning "请重启 Claude Code 使更改生效"
            # 只复检当前补丁，避免对 18MB cli.js 连跑四次 AST
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

# 一键应用全部未应用补丁（已应用跳过）
apply_all_patches() {
  local id ans need=() n
  if ! require_target_writable; then
    error "目标不存在或不可写"
    return 1
  fi
  # 若尚未检测，先快速检测
  if [[ $(count_status applied) -eq 0 && $(count_status idle) -eq 0 && $(count_status error) -eq 0 ]]; then
    info "尚未检测，先刷新状态..."
    refresh_all
  fi
  for id in "${PATCH_IDS[@]}"; do
    case "${STATUS[$id]:-}" in
      applied) ;;
      *) need+=("$id") ;;
    esac
  done
  n=${#need[@]}
  if [[ "$n" -eq 0 ]]; then
    success "全部补丁均已应用，无需操作"
    return 0
  fi
  printf '\n即将【一键应用】以下 %s 个补丁:\n' "$n"
  for id in "${need[@]}"; do
    printf '  · %s  (当前: ' "$(patch_name "$id")"
    status_label "${STATUS[$id]:-unknown}"
    printf ')\n'
  done
  printf '目标:  %s\n' "$CLI_PATH"
  if has_baseline; then
    printf '备份:  已有干净基线，本次不另存\n'
  else
    printf '备份:  将创建唯一干净基线 cli.js.cc-patch-baseline\n'
  fi
  printf '\n确认执行？ [Y/n] '
  read -r ans || true
  if [[ -n "$ans" && "$ans" != "y" && "$ans" != "Y" ]]; then
    info "已取消"
    return 0
  fi
  for id in "${need[@]}"; do
    info "应用: $(patch_name "$id")..."
    if run_node_patch "$id" apply; then
      success "  → ${MSG[$id]}"
    else
      error "  → 失败: ${MSG[$id]:-}"
    fi
  done
  info "正在复检全部补丁..."
  refresh_all
  warning "请重启 Claude Code 使更改生效"
}

set_path_interactive() {
  local p
  printf '请输入 cli.js 的绝对路径: '
  read -r p || true
  if [[ -f "$p" ]]; then
    CLI_PATH="$p"
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
      r|R)
        info "正在刷新全部补丁..."
        refresh_all
        ;;
      p|P) set_path_interactive ;;
      1|2|3|4)
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
  printf '目标: %s\n\n' "$CLI_PATH"
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

main "$@"
