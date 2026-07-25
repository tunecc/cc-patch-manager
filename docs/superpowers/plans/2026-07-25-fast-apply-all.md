# Fast Apply-All Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make interactive `[a]` 一键应用全部 a fast path: one confirm, apply every patch, trust apply STATUS — no pre/post `refresh_all`.

**Architecture:** Only change orchestration in `cc-patch-manager.sh`. Extract a pure summary helper that classifies each patch from in-memory `STATUS`/`MSG` after the apply loop. Engines stay untouched; they already emit `SUCCESS` / `ALREADY_PATCHED` and `parse_and_set_status` already updates maps.

**Tech Stack:** Bash 3.2+/4 associative arrays (existing), existing shell test style under `tests/`, no new dependencies.

**Spec:** `docs/superpowers/specs/2026-07-25-fast-apply-all-design.md`

## Global Constraints

- Scope: `apply_all_patches` (+ optional `print_apply_all_summary`) only; do not change patch engines, restore, single-patch apply, or startup scan policy
- Always iterate full `PATCH_IDS` on `[a]` (no in-memory skip of `applied`)
- Exactly one `[Y/n]` confirm; default Enter = yes
- On apply failure: continue remaining patches
- No `refresh_all` / `refresh_one` inside apply-all path
- Chinese UI copy must match the design (说明行 + 汇总行)
- Do not add `CC_PATCH_YES` or silent mode

## File map

| File | Role |
|------|------|
| `cc-patch-manager.sh` | Host: rewrite `apply_all_patches`; add `print_apply_all_summary` |
| `tests/test_fast_apply_all.sh` | Static contract + summary unit tests (no live 18MB cli.js) |

---

### Task 1: Failing tests for fast apply-all contract + summary

**Files:**
- Create: `tests/test_fast_apply_all.sh`
- Modify: (none yet)
- Test: `tests/test_fast_apply_all.sh`

**Interfaces:**
- Consumes: existing `source "$ROOT/cc-patch-manager.sh"` pattern; `PATCH_IDS`, `STATUS`, `MSG`, `patch_name`
- Produces: failing suite that locks (1) `apply_all_patches` must not call pre/post refresh, (2) `print_apply_all_summary` classification rules

- [ ] **Step 1: Write the failing test file**

Create `tests/test_fast_apply_all.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

assert_eq() {
  local actual="$1" expected="$2" label="$3"
  [[ "$actual" == "$expected" ]] || fail "$label: expected [$expected], got [$actual]"
}

# --- Static contract on apply_all_patches body ---
# Extract the function text between its definition and the next top-level function.
fn_body=$(awk '
  /^apply_all_patches\(\)/ {grab=1}
  grab {print}
  grab && /^[a-zA-Z_][a-zA-Z0-9_]*\(\)/ && !/^apply_all_patches\(\)/ {exit}
' "$ROOT/cc-patch-manager.sh")

[[ -n "$fn_body" ]] || fail "could not extract apply_all_patches"

# Must not pre-detect or post-recheck via refresh_all
if printf '%s\n' "$fn_body" | grep -Fq 'refresh_all'; then
  fail "apply_all_patches must not call refresh_all (pre or post)"
fi
if printf '%s\n' "$fn_body" | grep -Fq 'refresh_one'; then
  fail "apply_all_patches must not call refresh_one"
fi
if printf '%s\n' "$fn_body" | grep -Fq '尚未检测，先刷新状态'; then
  fail "apply_all_patches must not print pre-detect copy"
fi
if printf '%s\n' "$fn_body" | grep -Fq '正在复检全部补丁'; then
  fail "apply_all_patches must not print post-recheck copy"
fi

# Must always walk PATCH_IDS (not a filtered need= list of only non-applied)
printf '%s\n' "$fn_body" | grep -Fq 'for id in "${PATCH_IDS[@]}"' \
  || fail "apply_all_patches must iterate PATCH_IDS"

# Confirm copy requirements from design
printf '%s\n' "$fn_body" | grep -Fq '已应用的补丁会自动跳过' \
  || fail "confirm must state engines skip already-applied patches"
printf '%s\n' "$fn_body" | grep -Fq '确认执行？ [Y/n]' \
  || fail "must keep single [Y/n] confirm"

# Must print summary helper (or inline 一键应用结束) after applies
if ! printf '%s\n' "$fn_body" | grep -Eq 'print_apply_all_summary|一键应用结束'; then
  fail "apply_all_patches must print batch summary after applies"
fi

# --- Unit: print_apply_all_summary classification ---
source "$ROOT/cc-patch-manager.sh"

# Stub registry to three ids so the test does not depend on full seven-name list length in output counts only.
# Do NOT replace PATCH_IDS if the function always reads global PATCH_IDS — instead set STATUS for all real ids
# to applied/skip/fail mix and only assert counts via captured output.

for id in "${PATCH_IDS[@]}"; do
  STATUS[$id]=applied
  MSG[$id]="已打补丁"
done
# First id = fresh success, second = skip already, last = error (if ≥3 patches)
ids=("${PATCH_IDS[@]}")
STATUS[${ids[0]}]=applied
MSG[${ids[0]}]="已修补 3 处"
if [[ ${#ids[@]} -ge 2 ]]; then
  STATUS[${ids[1]}]=applied
  MSG[${ids[1]}]="已打补丁"
fi
if [[ ${#ids[@]} -ge 3 ]]; then
  STATUS[${ids[2]}]=error
  MSG[${ids[2]}]="校验失败: demo"
fi
# Remaining stay 已打补丁 / applied → all count as 跳过

# Expected: 1 success (ids[0]), 1 fail (ids[2] if present), rest skip
n=${#ids[@]}
exp_success=1
exp_fail=0
exp_skip=$((n - 1))
if [[ $n -ge 3 ]]; then
  exp_fail=1
  exp_skip=$((n - 2))
fi

if ! declare -F print_apply_all_summary >/dev/null 2>&1; then
  fail "print_apply_all_summary function is missing"
fi

summary=$(print_apply_all_summary)
printf '%s\n' "$summary" | grep -Fq "一键应用结束：${exp_success} 成功 · ${exp_skip} 跳过 · ${exp_fail} 失败" \
  || fail "summary header counts wrong. got:
$summary
expected header fragment: 一键应用结束：${exp_success} 成功 · ${exp_skip} 跳过 · ${exp_fail} 失败"

printf '%s\n' "$summary" | grep -Fq "${MSG[${ids[0]}]}" \
  || fail "summary must list success message"

if [[ $n -ge 3 ]]; then
  printf '%s\n' "$summary" | grep -Fq "校验失败: demo" \
    || fail "summary must list failure message"
fi

printf 'PASS: fast apply-all contract + summary classification\n'
```

Make executable:

```bash
chmod +x tests/test_fast_apply_all.sh
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```bash
bash tests/test_fast_apply_all.sh
```

Expected: FAIL — either `apply_all_patches must not call refresh_all` and/or `print_apply_all_summary function is missing` (current code still has pre/post refresh and no helper).

- [ ] **Step 3: Commit the failing test**

```bash
git add tests/test_fast_apply_all.sh
git commit -m "test: lock fast apply-all contract before rewrite"
```

---

### Task 2: Implement `print_apply_all_summary` + rewrite `apply_all_patches`

**Files:**
- Modify: `cc-patch-manager.sh` (replace `apply_all_patches` ~3465–3517; insert helper just above it)
- Test: `tests/test_fast_apply_all.sh`

**Interfaces:**
- Consumes: `PATCH_IDS`, `STATUS`, `MSG`, `patch_name`, `require_target_writable`, `has_baseline`, `run_node_patch`, `success`/`error`/`info`/`warning`
- Produces:
  - `print_apply_all_summary` → prints summary to stdout; exit 0; uses globals only
  - `apply_all_patches` → no `refresh_all`/`refresh_one`; always applies full registry after one confirm

- [ ] **Step 1: Add `print_apply_all_summary` immediately above `apply_all_patches`**

Insert:

```bash
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
```

Note: `success` prints to stdout with `[完成]` prefix — the test greps for `一键应用结束：…` inside that line, which is fine.

- [ ] **Step 2: Replace entire `apply_all_patches` function**

Replace from the comment `# 一键应用全部…` through the closing `}` of `apply_all_patches` with:

```bash
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
```

Do **not** leave any `need=()` filtering, pre-`refresh_all`, or post-`refresh_all`.

- [ ] **Step 3: Run the new test**

```bash
bash tests/test_fast_apply_all.sh
```

Expected: `PASS: fast apply-all contract + summary classification`

- [ ] **Step 4: Run existing suite smoke (no regressions on source)**

```bash
bash tests/test_context_limit_integration.sh
bash tests/test_computer_use_integration.sh
```

Expected: both PASS (they source the manager; menu markers unchanged).

Optional if time: `bash tests/test_auto_mode_engine.sh` (heavier; engines untouched so should pass).

- [ ] **Step 5: Manual sanity (if a real cli.js is available on the machine)**

Not required for CI. If operator has a target:

1. Run `./cc-patch-manager.sh`
2. Without pressing `[r]`, press `[a]`
3. Confirm: no「尚未检测，先刷新状态…」; one confirm; no「正在复检全部补丁…」; summary line appears
4. After pause, main list should show applied/error from apply, not all「未检测」

- [ ] **Step 6: Commit implementation**

```bash
git add cc-patch-manager.sh tests/test_fast_apply_all.sh
git commit -m "feat: fast apply-all without double refresh

Drop pre-detect and post refresh_all on [a]. Always attempt every
patch; trust apply STATUS; print success/skip/fail summary."
```

---

## Spec coverage checklist (self-review)

| Spec requirement | Task |
|------------------|------|
| No pre-`refresh_all` | Task 2 rewrite + Task 1 static grep |
| No post-`refresh_all` | Task 2 rewrite + Task 1 static grep |
| One confirm, default Y | Task 2 confirm block |
| Always attempt all `PATCH_IDS` | Task 2 loop + Task 1 grep |
| Continue on failure | Task 2 `if run_node_patch` else error, no `return` |
| Summary success/skip/fail | Task 2 `print_apply_all_summary` + Task 1 unit |
| Skip = applied + `已打补丁` | Task 2 helper + Task 1 counts |
| Restart warning | Task 2 `warning` line |
| Single-patch / `[r]` / startup unchanged | No edits outside apply-all path |
| No silent mode / env flag | Not added |

## Placeholder / consistency notes

- Helper name is consistently `print_apply_all_summary` in tests and implementation.
- Skip detection uses exact message `已打补丁` as set by `parse_and_set_status` for `ALREADY_PATCHED` (see `cc-patch-manager.sh` around the apply-mode branch).
- `success` wraps the header; tests grep the Chinese fragment inside the line.
