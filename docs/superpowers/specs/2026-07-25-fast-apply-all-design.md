# Fast Apply-All — Design Spec

**Date:** 2026-07-25  
**Status:** Approved for implementation planning  
**Scope:** Interactive `[a]` one-shot apply path in `cc-patch-manager.sh` only  
**Non-scope:** Patch engines, single-patch apply/restore, startup scan policy, non-interactive CLI flags

## 1. Problem

Pressing `[a]` (一键应用全部) currently does three expensive or redundant steps on a cold start:

1. **Pre-detect** — if in-memory `STATUS` is empty, run `refresh_all` (one AST check per patch on ~18MB `cli.js`)
2. **Confirm** — list patches and ask `[Y/n]`
3. **Post-recheck** — after applies, run `refresh_all` again

On a typical first-run “apply everything” session this is roughly **7 checks + 7 applies + 7 checks**. The pre-detect exists only because the menu intentionally starts with empty status; the post-recheck mostly re-validates what each apply engine already reported (`SUCCESS` / `ALREADY_PATCHED` / `VERIFY_FAILED`), which `parse_and_set_status` already stores in `STATUS` / `MSG`.

Single-patch apply already avoided full recheck (“只复检当前补丁”); apply-all did not.

## 2. Goal

Make `[a]` a **fast trust path**:

- One short confirmation
- Apply every registered patch in order (engines skip if already patched)
- Use apply outcomes as the source of truth for the menu
- No pre-`refresh_all`, no post-`refresh_all`

Cold path target: **~N applies only** (N = number of patches in `PATCH_IDS`).

## 3. Non-Goals

- Silent apply with zero confirmation
- Disk-persisted status cache
- Skipping already-applied patches based on in-memory `STATUS` (keep the rule “always attempt all”; engines handle idempotency)
- Changing single-patch `[a]` / `[r]` / detail `[c]` / main `[r]` behavior beyond shared helpers if any
- New env flags (`CC_PATCH_YES`, etc.) in this version
- Changing backup / baseline creation semantics inside engines

## 4. UX

### 4.1 Confirm (exactly once)

Default Enter = yes (same as current apply confirm).

```
即将【一键应用】全部 N 个补丁
  · <patch name 1>
  · <patch name 2>
  · …
目标:  <CLI_PATH>
备份:  已有，本次不另存
       — or —
备份:  尚无 — 首次成功写入前自动建 baseline
说明:  已应用的补丁会自动跳过，无需先按 [r] 检测

确认执行？ [Y/n]
```

No dependency on prior `[r]`. Cancel on non-empty answer other than `y`/`Y`.

### 4.2 Apply loop

For each id in `PATCH_IDS` (fixed registry order):

1. Log `应用: <name>...`
2. `run_node_patch id apply`
3. On success: print short `MSG` (patched count or already patched)
4. On failure: print error `MSG`; **continue** remaining patches (do not abort the batch)

### 4.3 Summary (replaces recheck)

After the loop, print a one-screen summary from in-memory state, e.g.:

```
[完成] 一键应用结束：X 成功 · Y 跳过 · Z 失败
  ✓ …  已修补 N 处
  ✓ …  已打补丁
  ! …  <error>
[注意] 请重启 Claude Code 使更改生效
```

Classification for the summary line:

| Outcome | Count bucket | UI |
|---------|--------------|-----|
| `STATUS=applied` and message indicates already patched (`已打补丁`) | 跳过 | ✓ |
| `STATUS=applied` otherwise (including fresh `SUCCESS`) | 成功 | ✓ |
| `STATUS=error` or other | 失败 | ! |

Then `pause` and return to main menu. Main list reflects apply-updated `STATUS` (no forced refresh).

### 4.4 Unchanged entry points

| Action | Behavior |
|--------|----------|
| Main `[r]` | Full `refresh_all` (user-driven verify) |
| Detail `[c]` | `refresh_one` |
| Detail apply | Confirm + apply + `refresh_one` only |
| Detail / multi restore | Existing confirm + `refresh_all` after restore |
| Startup | Still **no** automatic full scan |
| `[p]` path change | Still clears `STATUS` / `MSG` |

## 5. Implementation notes

**File:** `cc-patch-manager.sh`  
**Primary function:** `apply_all_patches` (orchestration only).

### 5.1 Remove

- Branch that calls `refresh_all` when applied/idle/error counts are all zero
- Final `refresh_all` after the apply loop
- Building a `need=()` list that excludes `applied` (always iterate `PATCH_IDS`)

### 5.2 Keep / reuse

- `require_target_writable`
- Baseline messaging via `has_baseline` / `baseline_path`
- `run_node_patch` + `parse_and_set_status` (engines already idempotent)
- Default-Y confirm style consistent with `confirm_apply`

### 5.3 Optional small helper

`print_apply_all_summary` (or inline) to count success/skip/fail and print rows — keeps `apply_all_patches` readable. Not required as a separate public API.

### 5.4 Warm-path cost (accepted)

If all patches are already applied, `[a]` still runs N apply passes that each hit `ALREADY_PATCHED`. That is accepted for rule simplicity and to avoid “must detect before apply-all.” Users who only want a status board still use `[r]` / `--check`.

## 6. Testing / acceptance

### Automated (if practical in existing shell tests)

- Exercise `apply_all_patches` or a extracted pure summary helper with mocked `STATUS`/`MSG` if the suite already sources the manager; do **not** require live 18MB `cli.js` for unit-level summary logic.
- Prefer not to add heavy integration unless a fixture path already exists.

### Manual acceptance

1. Fresh process, no `[r]`, press `[a]` → must **not** print「尚未检测，先刷新状态…」
2. Exactly **one** confirm prompt; after confirm, continuous applies; must **not** print「正在复检全部补丁…」
3. All unpatched → successes; main screen shows applied counts without another `[r]`
4. Second `[a]` → mostly skip / already patched; no spurious batch failure
5. Force one engine failure (if easy) → that row fails, others continue; `[r]` still works for full verify

## 7. Risks

| Risk | Mitigation |
|------|------------|
| Apply parser misses a success line → menu shows error until user `[r]` | Existing single-patch path already trusts the same parser; fix parser if seen |
| User expects pre-filter “only missing patches” | Copy states engines skip; optional later enhancement explicitly out of scope |
| Continue-on-error leaves partial set | Summary surfaces failures; baseline still allows restore workflows |

## 8. Rollout

Single commit (or one commit after plan tasks) to `cc-patch-manager.sh` (+ tests if added). No registry or engine changes. No doc site beyond this spec + plan.
