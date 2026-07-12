# Claude Code Patch Manager Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deliver one executable `cc-patch-manager.sh` that interactively shows, applies, and restores the four Claude Code local patches with a clean pure-Bash TUI.

**Architecture:** Single-file monolith. Shared path/acorn/backup/UI layer dispatches to four in-process patch engines. Each engine embeds the legacy Node+acorn AST logic (ported verbatim from the four `apply-*.sh` scripts) and returns a uniform `applied|idle|error` status. Menu never shells out to the legacy scripts.

**Tech Stack:** Bash 3.2+ compatible scripts, Node.js (AST), acorn@8.16.0 cached at `/tmp/acorn-claude-fix.js`, ANSI/`tput` colors, `curl` for first-time acorn fetch.

**Spec:** `docs/superpowers/specs/2026-07-11-cc-patch-manager-design.md`

## Global Constraints

- **One runtime file only:** `cc-patch-manager.sh` (legacy `apply-*.sh` stay as reference; manager must not invoke them).
- **Status truth:** real `--check` / AST detection only — no `state.json`.
- **Backup suffixes (exact):** `backup-automode-model`, `backup-keybindings-enable`, `backup-transcript-dialog-replay`, `backup-ultracode`.
- **Backup form:** `cli.js.<suffix>-<timestamp>` whole-file; restore = newest match overwrites `cli.js`.
- **Confirmations:** Apply → `y` (default N); multi-patch Restore → full word `yes`.
- **Path priority:** argv → `CLAUDE_CLI_PATH` → auto list (both `@anthropic-ai` and `@cometix`).
- **CLI surface:** interactive default; `--check`; `--help`; no bulk non-interactive apply/restore.
- **Exit codes:** `0` ok / `--check` with no ERROR; `1` hard failure or ERROR status in `--check`.
- **Git:** workspace may not be a git repo — treat commit steps as optional (`git init` only if user already asked).
- **No network except** optional acorn download from `https://unpkg.com/acorn@8.16.0/dist/acorn.js`.
- Prefer parity with legacy check/apply/restore over UI chrome.

## File Structure

| Path | Role |
|------|------|
| `cc-patch-manager.sh` | **Create** — sole deliverable (TUI + engines) |
| `apply-claude-code-enable-auto-mode.sh` | **Read-only** migration source |
| `apply-claude-code-enable-keybindings-fix.sh` | **Read-only** migration source (smallest; port first) |
| `apply-claude-code-transcript-dialog-replay-fix.sh` | **Read-only** migration source |
| `apply-claude-code-unlock-ultracode-fix.sh` | **Read-only** migration source |
| `docs/superpowers/specs/2026-07-11-cc-patch-manager-design.md` | Spec (do not rewrite during implement) |
| `docs/superpowers/plans/2026-07-11-cc-patch-manager.md` | This plan |

No new library files, no `package.json`, no vendored acorn in-repo for v1.

---

### Task 1: Scaffold script header, colors, registry, help

**Files:**
- Create: `cc-patch-manager.sh`

**Interfaces:**
- Produces: `VERSION`, color helpers, `PATCH_IDS`, `patch_meta_*` getters, `usage`, executable bit
- Consumes: nothing

- [ ] **Step 1: Create the scaffold**

Create `cc-patch-manager.sh` with:

```bash
#!/usr/bin/env bash
# Claude Code Patch Manager — unified interactive patch TUI
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

success() { printf '%s[OK]%s %s\n' "$GREEN" "$NC" "$*"; }
warning() { printf '%s[!]%s %s\n' "$YELLOW" "$NC" "$*"; }
error()   { printf '%s[X]%s %s\n' "$RED" "$NC" "$*" >&2; }
info()    { printf '%s[>]%s %s\n' "$BLUE" "$NC" "$*"; }

# ---------- registry (order fixed) ----------
PATCH_IDS=(auto-mode keybindings transcript-dialog ultracode)

patch_name() {
  case "$1" in
    auto-mode) echo "Auto Mode" ;;
    keybindings) echo "Keybindings" ;;
    transcript-dialog) echo "Transcript Dialog" ;;
    ultracode) echo "Ultracode Unlock" ;;
    *) echo "$1" ;;
  esac
}

patch_note() {
  case "$1" in
    auto-mode) echo "Unlock Auto Mode: model eligibility + classifier fail-open + classifier model env" ;;
    keybindings) echo "Enable custom keybindings; Ctrl+C exits (Escape interrupts)" ;;
    transcript-dialog) echo "Replay permission dialogs lost on Ctrl+O transcript screen" ;;
    ultracode) echo "Unlock ultracode for max-capable models without xhigh" ;;
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
Three patches: (1) force auto-mode model eligibility true; (2) classifier unavailable fail-open deny→ask; (3) CLAUDE_CLASSIFIER_MODEL env override injection.
EOF
      ;;
    keybindings)
      cat <<'EOF'
Force-enable tengu_keybinding_customization_release and change default ctrl+c from app:interrupt to app:exit.
EOF
      ;;
    transcript-dialog)
      cat <<'EOF'
Persist/replay pending permission dialogs so Ctrl+O transcript does not drop approval UI (Waiting… stuck).
EOF
      ;;
    ultracode)
      cat <<'EOF'
Accept max-capable models for ultracode: availability gate, effort degradation xhigh→max, active check accepts max.
EOF
      ;;
  esac
}

# In-memory status: applied | idle | error | unknown
declare -A STATUS=()
declare -A MSG=()

usage() {
  cat <<EOF
Claude Code Patch Manager v${VERSION}

Usage:
  $(basename "$0")                  Interactive menu
  $(basename "$0") /path/to/cli.js  Set target, then menu
  $(basename "$0") --check          Print four statuses and exit
  $(basename "$0") --help           This help

Env:
  CLAUDE_CLI_PATH   Preferred cli.js if file exists
EOF
}

# stub main until later tasks
main() {
  if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    usage
    exit 0
  fi
  echo "cc-patch-manager scaffold OK (v${VERSION}); engines not wired yet"
  exit 0
}

main "$@"
```

- [ ] **Step 2: Make executable and smoke-test help**

Run:

```bash
chmod +x cc-patch-manager.sh
./cc-patch-manager.sh --help
./cc-patch-manager.sh
```

Expected:
- Help prints usage and version
- Bare run prints scaffold OK message and exits 0

- [ ] **Step 3: Optional commit**

If (and only if) the directory is a git repo and the user wants commits:

```bash
git add cc-patch-manager.sh
git commit -m "feat(patch-manager): scaffold header, registry, and help"
```

Otherwise skip.

---

### Task 2: Target resolution, acorn ensure, restore helper

**Files:**
- Modify: `cc-patch-manager.sh`

**Interfaces:**
- Consumes: registry `patch_suffix`
- Produces:
  - `CLI_PATH` global (may be empty)
  - `find_cli_js` → prints path, return 0/1
  - `resolve_target [optional_path]` → sets `CLI_PATH`
  - `require_target_writable` → 0/1
  - `ensure_acorn` → 0/1
  - `restore_patch <id>` → 0/1, uses newest `cli.js.<suffix>-*`

- [ ] **Step 1: Add path detection (spec order)**

Insert before `main`:

```bash
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
    error "Specified file not found: $arg"
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
```

- [ ] **Step 2: Add acorn + restore**

```bash
ensure_node() {
  if ! command -v node >/dev/null 2>&1; then
    error "node not found — install Node.js to check/apply patches"
    return 1
  fi
  return 0
}

ensure_acorn() {
  if [[ -f "$ACORN_PATH" ]]; then
    return 0
  fi
  if ! command -v curl >/dev/null 2>&1; then
    error "curl not found and acorn cache missing at $ACORN_PATH"
    return 1
  fi
  info "Downloading acorn parser..."
  if ! curl -fsSL "$ACORN_URL" -o "$ACORN_PATH"; then
    error "Failed to download acorn parser"
    rm -f "$ACORN_PATH"
    return 1
  fi
  return 0
}

# restore_patch id → 0 success, 1 fail
restore_patch() {
  local id="$1"
  local suffix dir latest
  suffix=$(patch_suffix "$id")
  if ! require_target_writable; then
    error "Target not writable: ${CLI_PATH:-none}"
    return 1
  fi
  dir=$(dirname "$CLI_PATH")
  # shellcheck disable=SC2012
  latest=$(ls -t "$dir"/cli.js."${suffix}"-* 2>/dev/null | head -1 || true)
  if [[ -z "${latest:-}" ]]; then
    error "No backup file found (cli.js.${suffix}-*)"
    return 1
  fi
  cp "$latest" "$CLI_PATH"
  success "Restored from backup: $latest"
  return 0
}
```

- [ ] **Step 3: Extend main temporarily for path smoke**

```bash
main() {
  local mode="menu" path_arg=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --help|-h) usage; exit 0 ;;
      --check) mode="check"; shift ;;
      -*) error "Unknown option: $1"; usage; exit 1 ;;
      *) path_arg="$1"; shift ;;
    esac
  done
  resolve_target "$path_arg" || true
  if [[ -n "$CLI_PATH" ]]; then
    info "Target: $CLI_PATH"
  else
    warning "Target: (not found)"
  fi
  echo "path layer OK"
  exit 0
}
```

- [ ] **Step 4: Verify path layer**

Run:

```bash
./cc-patch-manager.sh --help | head -5
# if you know a real cli.js:
./cc-patch-manager.sh /nonexistent/cli.js ; echo exit:$?
# expect error about not found, path layer still prints
CLAUDE_CLI_PATH="" ./cc-patch-manager.sh 2>&1 | head -20
```

Expected: help works; bad path reports not found; auto-detect either finds a real install or shows `(not found)` without crashing.

---

### Task 3: Node runner + status mapping harness

**Files:**
- Modify: `cc-patch-manager.sh`

**Interfaces:**
- Produces:
  - `run_node_patch <id> <mode>` where mode is `check|apply`
  - Writes Node script via `write_patch_script_<id>` (stubs until Task 4–7)
  - Sets `STATUS[id]` and `MSG[id]`
  - `parse_patch_output` maps markers → status
  - `refresh_one <id>`, `refresh_all`
- Consumes: `CLI_PATH`, `ensure_node`, `ensure_acorn`, `patch_suffix`

**Machine markers (must match legacy Node helpers):**

| Marker | Meaning |
|--------|---------|
| `ALREADY_PATCHED` | applied |
| `NEEDS_PATCH` / `PATCH_COUNT:*` | idle |
| `SUCCESS:*` | apply ok |
| `BACKUP:*` | backup path (informational) |
| `PARSE_ERROR:*` / `NOT_FOUND:*` / `VERIFY_FAILED:*` | error |
| exit 2 from Node historically = already patched for keybindings | treat as applied if marker present |

- [ ] **Step 1: Implement output parser and runner**

```bash
# Globals set by last run
LAST_OUTPUT=""
LAST_BACKUP=""

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
        MSG[$id]="Already patched"
        ;;
      NEEDS_PATCH)
        has_needs=1
        MSG[$id]="Patch needed"
        ;;
      PATCH_COUNT:*)
        has_needs=1
        MSG[$id]="Need to patch ${line#PATCH_COUNT:} location(s)"
        ;;
      SUCCESS:*)
        has_success=1
        MSG[$id]="Patched ${line#SUCCESS:} location(s)"
        ;;
      BACKUP:*)
        LAST_BACKUP="${line#BACKUP:}"
        ;;
      PARSE_ERROR:*)
        has_err=1
        err_msg="Parse error: ${line#PARSE_ERROR:}"
        ;;
      NOT_FOUND:*)
        has_err=1
        err_msg="Not found: ${line#NOT_FOUND:}"
        ;;
      VERIFY_FAILED:*)
        has_err=1
        err_msg="Verify failed: ${line#VERIFY_FAILED:}"
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
      MSG[$id]="Already patched"
      return 0
    fi
    STATUS[$id]=error
    MSG[$id]="Unparseable check output (exit $exit_code)"
    return 1
  fi

  # apply mode
  if [[ $has_success -eq 1 ]]; then
    STATUS[$id]=applied
    return 0
  fi
  if [[ $has_already -eq 1 ]]; then
    STATUS[$id]=applied
    MSG[$id]="Already patched"
    return 0
  fi
  STATUS[$id]=error
  MSG[$id]="${MSG[$id]:-Apply failed (exit $exit_code)}"
  return 1
}

# write_patch_script_<id> must write path to fd or stdout — use shared pattern:
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
    *) error "Unknown patch id: $id"; rm -f "$tmp"; return 1 ;;
  esac
  printf '%s\n' "$tmp"
}

# stubs — Task 4–7 replace with real heredocs
write_patch_script_auto_mode() { echo "console.log('NOT_FOUND:auto-mode not ported'); process.exit(1);" >"$1"; }
write_patch_script_keybindings() { echo "console.log('NOT_FOUND:keybindings not ported'); process.exit(1);" >"$1"; }
write_patch_script_transcript_dialog() { echo "console.log('NOT_FOUND:transcript not ported'); process.exit(1);" >"$1"; }
write_patch_script_ultracode() { echo "console.log('NOT_FOUND:ultracode not ported'); process.exit(1);" >"$1"; }

run_node_patch() {
  local id="$1"
  local mode="$2"   # check|apply
  local script check_arg="" output ec=0

  if ! require_target_readable; then
    STATUS[$id]=error
    MSG[$id]="No readable target"
    return 1
  fi
  if ! ensure_node || ! ensure_acorn; then
    STATUS[$id]=error
    MSG[$id]="Missing node or acorn"
    return 1
  fi

  script=$(write_patch_script "$id") || return 1
  [[ "$mode" == "check" ]] && check_arg="--check"

  export BACKUP_SUFFIX
  BACKUP_SUFFIX=$(patch_suffix "$id")
  set +e
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

refresh_all() {
  local id
  for id in "${PATCH_IDS[@]}"; do
    refresh_one "$id"
  done
}

count_status() {
  local want="$1" id n=0
  for id in "${PATCH_IDS[@]}"; do
    [[ "${STATUS[$id]:-unknown}" == "$want" ]] && n=$((n + 1))
  done
  printf '%s\n' "$n"
}
```

- [ ] **Step 2: Smoke parser with a fake Node one-liner**

Temporarily point `write_patch_script_keybindings` to:

```bash
write_patch_script_keybindings() {
  cat >"$1" <<'EOF'
console.log('ALREADY_PATCHED');
process.exit(2);
EOF
}
```

With a readable dummy file:

```bash
echo 'console.log(1)' > /tmp/fake-cli.js
./cc-patch-manager.sh /tmp/fake-cli.js
# then in a one-off bash debug, source functions OR add temporary:
# refresh_one keybindings; echo ${STATUS[keybindings]}
```

Add a temporary debug flag only if needed; remove after verifying `STATUS[keybindings]=applied`. Restore stub or proceed to Task 4 real port.

- [ ] **Step 3: Optional commit**

`feat(patch-manager): add node runner and status mapping`

---

### Task 4: Port keybindings engine (first real patch)

**Files:**
- Modify: `cc-patch-manager.sh` — replace `write_patch_script_keybindings`
- Read-only source: `apply-claude-code-enable-keybindings-fix.sh` lines **185–406** (`PATCH_EOF` body)

**Interfaces:**
- Produces: working `check`/`apply` for id `keybindings`
- Consumes: `run_node_patch`, `restore_patch`

- [ ] **Step 1: Replace stub with legacy Node body**

Implement:

```bash
write_patch_script_keybindings() {
  local out="$1"
  # IMPORTANT: copy the exact contents between PATCH_EOF markers from
  # apply-claude-code-enable-keybindings-fix.sh (the Node script only).
  # Do not invent new AST logic. Use a quoted heredoc so bash does not expand.
  cat >"$out" <<'PATCH_EOF'
# --- paste lines 186-405 from apply-claude-code-enable-keybindings-fix.sh here ---
# (from `const fs = require('fs');` through `console.log('SUCCESS:' + patchedCount);`)
PATCH_EOF
}
```

**Implementation instruction (no placeholders in final code):** open `apply-claude-code-enable-keybindings-fix.sh`, copy the Node source **verbatim** from `const fs = require('fs');` through `console.log('SUCCESS:' + patchedCount);` into the heredoc. Do not change AST matchers, exit codes, or marker strings.

- [ ] **Step 2: Behavioral parity check vs legacy**

On a real `cli.js` (or a full copy):

```bash
CLI=... # path to cli.js
# legacy
./apply-claude-code-enable-keybindings-fix.sh --check "$CLI"; echo legacy:$?
# manager (after wiring a tiny debug or using --check from Task 9 early)
# Prefer: temporarily add to main for this task only:
#   resolve_target "$1"; refresh_one keybindings; echo ${STATUS[keybindings]} ${MSG[keybindings]}
```

Expected: both report the same applied vs needs-patch conclusion.

- [ ] **Step 3: Apply + restore smoke (use a COPY of cli.js)**

```bash
cp "$CLI" /tmp/cli.js.test
# apply via manager once apply path exists; or call run_node_patch keybindings apply in debug
# verify backup: ls -t /tmp/cli.js.test.backup-keybindings-enable-* | head -1
# restore_patch keybindings with CLI_PATH=/tmp/cli.js.test
```

Never test first apply against production `cli.js` without a backup mindset; prefer a copied target.

- [ ] **Step 4: Optional commit**

`feat(patch-manager): port keybindings check/apply engine`

---

### Task 5: Port auto-mode engine

**Files:**
- Modify: `cc-patch-manager.sh` — `write_patch_script_auto_mode`
- Read-only: `apply-claude-code-enable-auto-mode.sh` Node heredoc body (between `PATCH_EOF` markers; starts near the `PATCH_SCRIPT=$(mktemp)` section — full Node file through SUCCESS/ALREADY markers)

**Interfaces:**
- Same contract as keybindings for id `auto-mode`
- Suffix must remain `backup-automode-model`

- [ ] **Step 1: Verbatim port of Node heredoc into `write_patch_script_auto_mode`**

Same pattern as Task 4. Preserve:

- `ALREADY_PATCHED` / `NEEDS_PATCH` / `SUCCESS:` / `PARSE_ERROR:` / `NOT_FOUND:` / `VERIFY_FAILED:` / `BACKUP:`
- `process.env.BACKUP_SUFFIX`
- `process.argv[2]` acorn, `argv[3]` cli, `argv[4] === '--check'`

- [ ] **Step 2: Parity `--check` vs legacy**

```bash
./apply-claude-code-enable-auto-mode.sh --check "$CLI"
# manager refresh_one auto-mode → STATUS must match
```

- [ ] **Step 3: Optional apply on **copy** of cli.js; confirm backup suffix string**

```bash
ls /tmp/cli.js.test.backup-automode-model-* 2>/dev/null | head
```

- [ ] **Step 4: Optional commit**

`feat(patch-manager): port auto-mode engine`

---

### Task 6: Port transcript-dialog engine

**Files:**
- Modify: `cc-patch-manager.sh` — `write_patch_script_transcript_dialog`
- Read-only: `apply-claude-code-transcript-dialog-replay-fix.sh` Node heredoc (full body between PATCH_EOF)

**Interfaces:**
- id `transcript-dialog`, suffix `backup-transcript-dialog-replay`

- [ ] **Step 1: Verbatim Node port**

Note: this script’s Node side is larger (dialog channel factory + host cleanup). Copy entire logic; do not simplify AST helpers.

- [ ] **Step 2: Parity check vs legacy `--check`**

- [ ] **Step 3: Optional commit**

`feat(patch-manager): port transcript-dialog engine`

---

### Task 7: Port ultracode engine

**Files:**
- Modify: `cc-patch-manager.sh` — `write_patch_script_ultracode`
- Read-only: `apply-claude-code-unlock-ultracode-fix.sh` Node heredoc

**Interfaces:**
- id `ultracode`, suffix `backup-ultracode`

- [ ] **Step 1: Verbatim Node port**

- [ ] **Step 2: Parity check vs legacy `--check`**

- [ ] **Step 3: Optional commit**

`feat(patch-manager): port ultracode engine`

---

### Task 8: Interactive TUI — main list, detail, confirms

**Files:**
- Modify: `cc-patch-manager.sh` — replace stub `main` with full menu

**Interfaces:**
- Consumes: `STATUS`, `MSG`, `refresh_all`, `run_node_patch`, `restore_patch`, `resolve_target`
- Produces: interactive loop matching spec §5

- [ ] **Step 1: UI helpers**

```bash
clear_screen() {
  if [[ -t 1 ]]; then
    printf '\033[2J\033[H'
  fi
}

pause() {
  printf '\nPress Enter to continue...'
  # shellcheck disable=SC2162
  read _ || true
}

status_label() {
  case "${1:-unknown}" in
    applied) printf '%s✓ APPLIED%s' "$GREEN" "$NC" ;;
    idle)    printf '%s· idle%s' "$DIM" "$NC" ;;
    error)   printf '%s! ERROR%s' "$RED" "$NC" ;;
    *)       printf '%s? UNKNOWN%s' "$YELLOW" "$NC" ;;
  esac
}

applied_ids() {
  local id
  for id in "${PATCH_IDS[@]}"; do
    [[ "${STATUS[$id]:-}" == "applied" ]] && printf '%s\n' "$id"
  done
}

count_applied() { count_status applied; }

draw_header() {
  local a i e
  a=$(count_status applied)
  i=$(count_status idle)
  e=$(count_status error)
  printf '%sClaude Code Patch Manager%s  v%s\n' "$BOLD" "$NC" "$VERSION"
  printf '----------------------------------------\n'
  if [[ -n "$CLI_PATH" ]]; then
    printf 'Target:  %s\n' "$CLI_PATH"
  else
    printf 'Target:  %s(not found)%s\n' "$RED" "$NC"
  fi
  printf 'Status:  %s applied · %s idle · %s error\n' "$a" "$i" "$e"
  printf '----------------------------------------\n'
}

draw_main() {
  clear_screen
  draw_header
  local idx=1 id
  printf '  #  %-12s  %-20s  %s\n' "Status" "Patch" "Notes"
  for id in "${PATCH_IDS[@]}"; do
    printf '  %d  ' "$idx"
    status_label "${STATUS[$id]:-unknown}"
    printf '  %-20s  %s\n' "$(patch_name "$id")" "$(patch_note "$id")"
    idx=$((idx + 1))
  done
  printf '----------------------------------------\n'
  printf '[1-4] select patch   [r] refresh   [p] path   [q] quit\n'
}

confirm_apply() {
  local id="$1" list="" x
  printf '\nAbout to APPLY: %s\n' "$(patch_name "$id")"
  printf 'Target:  %s\n' "$CLI_PATH"
  printf 'Backup:  will create cli.js.%s-<timestamp>\n' "$(patch_suffix "$id")"
  printf 'Currently applied:\n'
  while IFS= read -r x; do
    [[ -n "$x" ]] && printf '  · %s\n' "$(patch_name "$x")" && list=1
  done < <(applied_ids)
  [[ -z "${list:-}" ]] && printf '  (none)\n'
  printf '\nConfirm? [y/N] '
  local ans
  read -r ans || true
  [[ "$ans" == "y" || "$ans" == "Y" ]]
}

confirm_restore() {
  local id="$1" n ans x
  n=$(count_applied)
  printf '\nAbout to RESTORE: %s\n' "$(patch_name "$id")"
  printf 'Target:  %s\n' "$CLI_PATH"
  printf 'Source:  newest cli.js.%s-*\n' "$(patch_suffix "$id")"
  if [[ "$n" -ge 2 ]]; then
    printf '\n%s⚠ MULTI-PATCH RISK%s\n' "$YELLOW" "$NC"
    printf 'Restore overwrites the ENTIRE cli.js from this patch backup.\n'
    printf 'Other patches may be removed as a side effect.\n'
    printf 'Currently applied:\n'
    while IFS= read -r x; do
      [[ -n "$x" ]] && printf '  · %s%s\n' "$(patch_name "$x")" \
        "$([[ "$x" == "$id" ]] && echo '  ← restoring' || true)"
    done < <(applied_ids)
    printf '\nSuggest restoring in reverse apply order (LIFO).\n'
    printf 'Type %syes%s to continue (anything else cancels): ' "$BOLD" "$NC"
    read -r ans || true
    [[ "$ans" == "yes" ]]
  else
    printf '\nConfirm? [y/N] '
    read -r ans || true
    [[ "$ans" == "y" || "$ans" == "Y" ]]
  fi
}

show_detail() {
  local id="$1" choice before after
  while true; do
    clear_screen
    draw_header
    printf '\n%s\n' "$(patch_name "$id")"
    printf '%s\n\n' "$(patch_purpose "$id")"
    printf 'Status: '; status_label "${STATUS[$id]:-unknown}"; printf '\n'
    printf 'Detail: %s\n' "${MSG[$id]:-}"
    printf 'Suffix: %s\n\n' "$(patch_suffix "$id")"
    printf '[a] apply  [r] restore  [c] check  [b] back\n'
    printf 'Choice: '
    read -r choice || true
    case "$choice" in
      a|A)
        if ! require_target_writable; then
          error "Target missing or not writable"; pause; continue
        fi
        if confirm_apply "$id"; then
          if run_node_patch "$id" apply; then
            success "Apply finished: ${MSG[$id]}"
            [[ -n "$LAST_BACKUP" ]] && info "Backup: $LAST_BACKUP"
            warning "Restart Claude Code for changes to take effect"
          else
            error "Apply failed: ${MSG[$id]}"
          fi
          refresh_all
        else
          info "Cancelled"
        fi
        pause
        ;;
      r|R)
        if ! require_target_writable; then
          error "Target missing or not writable"; pause; continue
        fi
        mapfile -t _before < <(applied_ids)
        if confirm_restore "$id"; then
          if restore_patch "$id"; then
            refresh_all
            # side-effect note
            local lost="" x
            for x in "${_before[@]}"; do
              if [[ "$x" != "$id" && "${STATUS[$x]:-}" != "applied" ]]; then
                lost+="$(patch_name "$x"), "
              fi
            done
            if [[ -n "$lost" ]]; then
              warning "Also no longer applied (whole-file rollback): ${lost%, }"
            fi
          fi
        else
          info "Cancelled"
        fi
        pause
        ;;
      c|C)
        refresh_one "$id"
        ;;
      b|B|"") return 0 ;;
      *) warning "Unknown choice" ; pause ;;
    esac
  done
}

set_path_interactive() {
  local p
  printf 'Enter absolute path to cli.js: '
  read -r p || true
  if [[ -f "$p" ]]; then
    CLI_PATH="$p"
    success "Target set"
    refresh_all
  else
    error "Not a readable file: $p"
  fi
  pause
}

menu_loop() {
  local choice id
  refresh_all || true
  while true; do
    draw_main
    printf 'Choice: '
    read -r choice || true
    case "$choice" in
      q|Q) exit 0 ;;
      r|R) refresh_all; ;;
      p|P) set_path_interactive ;;
      1|2|3|4)
        id="${PATCH_IDS[$((choice - 1))]}"
        show_detail "$id"
        ;;
      *) warning "Unknown choice"; pause ;;
    esac
  done
}
```

- [ ] **Step 2: Wire `main` to menu when not `--check`**

```bash
main() {
  local mode="menu" path_arg=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --help|-h) usage; exit 0 ;;
      --check|-c) mode="check"; shift ;;
      -*)
        error "Unknown option: $1"
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
    # Task 9 fills this; temporary:
    if ! require_target_readable; then
      error "No cli.js target"
      exit 1
    fi
    refresh_all || true
    local id ec=0
    for id in "${PATCH_IDS[@]}"; do
      printf '%-18s %-10s %s\n' "$id" "${STATUS[$id]:-unknown}" "${MSG[$id]:-}"
      [[ "${STATUS[$id]:-}" == "error" ]] && ec=1
    done
    exit "$ec"
  fi

  menu_loop
}
```

- [ ] **Step 3: Manual UI walk**

Run `./cc-patch-manager.sh`, verify:

- Header shows target + counts  
- Keys `1-4`, `r`, `p`, `q` work  
- Detail apply cancel with Enter leaves file unchanged  
- Multi-patch restore demands `yes` (can simulate STATUS by applying two patches on a **copy**)

- [ ] **Step 4: Optional commit**

`feat(patch-manager): interactive main menu and confirm flows`

---

### Task 9: Finalize non-interactive `--check` and preflight polish

**Files:**
- Modify: `cc-patch-manager.sh`

**Interfaces:**
- Produces: stable `--check` table + exit codes per spec §11
- Disable apply/restore when no target (already in detail guards)

- [ ] **Step 1: Pretty `--check` output**

```bash
run_check_mode() {
  if ! require_target_readable; then
    error "No cli.js target (pass path or set CLAUDE_CLI_PATH)"
    exit 1
  fi
  if ! ensure_node; then
    exit 1
  fi
  refresh_all || true
  local id ec=0
  printf 'Target: %s\n\n' "$CLI_PATH"
  printf '%-18s %-10s %s\n' "ID" "STATUS" "MESSAGE"
  printf '%-18s %-10s %s\n' "------------------" "----------" "-------"
  for id in "${PATCH_IDS[@]}"; do
    printf '%-18s %-10s %s\n' "$id" "${STATUS[$id]:-unknown}" "${MSG[$id]:-}"
    [[ "${STATUS[$id]:-}" == "error" ]] && ec=1
  done
  exit "$ec"
}
```

Call `run_check_mode` from `main` when `mode=check`.

- [ ] **Step 2: Verify exit codes**

```bash
./cc-patch-manager.sh --check /path/to/cli.js; echo $?
# 0 if no ERROR rows; 1 if any ERROR or missing target
./cc-patch-manager.sh --check /no/such/cli.js; echo $?   # expect 1
```

- [ ] **Step 3: Ensure `set -euo pipefail` does not kill menu on cancelled ops**

Audit: `run_node_patch` / `refresh_all` use `|| true` where status can be error; `read` failures handled.

- [ ] **Step 4: Optional commit**

`feat(patch-manager): finalize --check mode and exit codes`

---

### Task 10: Acceptance checklist (spec §14) — evidence before “done”

**Files:**
- No new files required; operate on `cc-patch-manager.sh` + a **copied** `cli.js` for destructive tests

**Interfaces:** none new

- [ ] **Step 1: Run checklist and record results**

Execute each item; fix bugs before claiming complete:

1. No cli.js → starts, `(not found)`, apply/restore blocked, `[p]` works  
2. Valid path via argv / env / auto-detect  
3. Full check parity with each legacy `apply-*.sh --check` on same path  
4. Apply one idle patch on a **copy** → backup created → APPLIED → restart warning  
5. Re-apply when applied → already patched, no corruption  
6. Restore single → idle + file restored  
7. Apply A then B on copy → restore A → must type `yes` → other statuses refresh honestly  
8. Cancel confirm → no changes  
9. `[r]` / `[p]` consistency  
10. UI readable ~80 columns, no gum/fzf  

Parity helper:

```bash
CLI=/path/to/cli.js
for s in \
  apply-claude-code-enable-auto-mode.sh \
  apply-claude-code-enable-keybindings-fix.sh \
  apply-claude-code-transcript-dialog-replay-fix.sh \
  apply-claude-code-unlock-ultracode-fix.sh
do
  echo "==== $s ===="
  ./"$s" --check "$CLI" || true
done
./cc-patch-manager.sh --check "$CLI" || true
```

- [ ] **Step 2: Fix any parity gaps** (wrong marker mapping, missing already-patched paths, wrong suffix)

- [ ] **Step 3: Final optional commit**

`test(patch-manager): acceptance checklist passed`

- [ ] **Step 4: Do not claim completion without Step 1 evidence**

Per project rules / verification-before-completion: paste or summarize actual command output for checks 3–7 at minimum.

---

## Self-Review (plan vs spec)

| Spec section | Task coverage |
|--------------|---------------|
| §2 Goal / single file | Task 1 deliverable path |
| §3 Non-goals | No tasks for web/gum/state.json/bulk apply |
| §4 Approach monolith | All tasks edit only `cc-patch-manager.sh` |
| §5 UX main/detail/confirm | Task 8 |
| §5.4 multi-patch `yes` | Task 8 `confirm_restore` |
| §5.5 post-op refresh + side-effect note | Task 8 restore branch |
| §6 Registry | Task 1 |
| §7 Architecture / contract | Tasks 3–7 |
| §8 Path resolution | Task 2 |
| §9 Backup/restore | Task 2 `restore_patch` + Node BACKUP in ports |
| §10 Dependencies / acorn | Task 2 `ensure_*` |
| §11 CLI `--check`/`--help` | Tasks 1, 8, 9 |
| §12 Error mapping | Task 3 |
| §13 Safety | Tasks 2, 8 confirms |
| §14 Acceptance | Task 10 |

**Placeholder scan:** Task 4–7 intentionally use “verbatim copy from file X” instead of pasting 2k+ lines of AST into the plan (the plan would be unreadable and drift). The implementer must paste the real Node sources; stubs must not ship.

**Type/name consistency:** ids `auto-mode|keybindings|transcript-dialog|ultracode`; functions `write_patch_script_*`, `run_node_patch`, `restore_patch`, `refresh_all`, `STATUS`/`MSG` used uniformly across tasks.

**Note on `declare -A`:** requires Bash 4+. macOS default `/bin/bash` is 3.2; this environment has Homebrew bash 5.x. Shebang is `#!/usr/bin/env bash` — implementer must verify `bash --version` ≥ 4, or replace assoc arrays with parallel encoded strings if supporting 3.2 is required. **Decision locked for this plan:** require Bash 4+ (document in header comment). If `env bash` resolves to 3.2 on a machine, user should run `/opt/homebrew/bin/bash cc-patch-manager.sh` or fix PATH.

---

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-07-11-cc-patch-manager.md`.

**Two execution options:**

1. **Subagent-Driven (recommended)** — fresh subagent per task, review between tasks  
2. **Inline Execution** — execute tasks in this session with executing-plans and checkpoints  

Which approach?
