# Claude Code Patch Manager — Design Spec

**Date:** 2026-07-11  
**Status:** Approved for implementation planning  
**Deliverable:** Single executable `cc-patch-manager.sh`  
**Workspace:** `/Users/tune/Downloads/fix_cc` (not a git repository at design time; doc is written to disk only unless user requests git init/commit)

## 1. Problem

Four independent Claude Code local patch scripts exist in this workspace:

| Script | Purpose |
|--------|---------|
| `apply-claude-code-enable-auto-mode.sh` | Auto Mode unlock (model eligibility, classifier fail-open, classifier model env override) |
| `apply-claude-code-enable-keybindings-fix.sh` | Enable keybinding customization + Ctrl+C → `app:exit` |
| `apply-claude-code-transcript-dialog-replay-fix.sh` | Replay permission dialogs lost while Ctrl+O transcript is open |
| `apply-claude-code-unlock-ultracode-fix.sh` | Unlock ultracode for max-capable models that lack xhigh |

Each script supports apply (default), `--check` / `-c`, and `--restore` / `-r`, with optional `cli.js` path. Day-to-day use requires remembering which script does what, running checks one by one, and understanding restore side effects. There is no unified view of “what is applied.”

## 2. Goal

One pure-Bash interactive manager that:

1. Shows at a glance which of the four patches are applied / idle / error.
2. Lets the user pick a patch and manually **apply**, **restore**, or **re-check** it.
3. Uses a clean, scannable terminal UI (no gum/fzf/web).
4. Lives in **one maintainable file** after delivery.

## 3. Non-Goals (v1)

- Web UI, gum, fzf, or other external TUI frameworks
- Per-patch diff/quilt-style backup (byte-level independent undo)
- Intelligent “replay remaining patches after restore”
- Auto re-apply after Claude Code upgrades
- Persistent state database / `state.json` as source of truth
- Non-interactive bulk `apply all` / `restore all`
- Deleting the legacy four scripts (they remain as migration source and behavioral reference only; the manager does **not** invoke them at runtime)
- Shipping or vendoring acorn inside the repo (v1 keeps download-to-`/tmp` behavior)

## 4. Approach

**Single-file monolith (Approach 2).**

All of the following live in `cc-patch-manager.sh`:

- Menu TUI
- Shared path detection, colors, confirmations, backup helpers
- Built-in registry of four patches
- Per-patch `check` / `apply` / `restore` logic migrated from the existing scripts (Node + acorn AST patches)

**Rejected alternatives:**

| Approach | Why not |
|----------|---------|
| Thin orchestrator over the four scripts | User wants one file to maintain long-term |
| Shared `lib/common.sh` + thin patches + manager | More files, worse fit for “maintain one file” |

## 5. User Experience

### 5.1 Main screen

```
┌─────────────────────────────────────────────────────────┐
│  Claude Code Patch Manager                     v1.0     │
├─────────────────────────────────────────────────────────┤
│  Target:  /path/to/.../claude-code/cli.js               │
│  Status:  2 applied · 1 idle · 1 error                  │
├─────────────────────────────────────────────────────────┤
│   #  Status      Patch                  Notes           │
│   1  ✓ APPLIED   Auto Mode              …               │
│   2  · idle      Keybindings            …               │
│   3  ✓ APPLIED   Transcript Dialog      …               │
│   4  ! ERROR     Ultracode Unlock       …               │
├─────────────────────────────────────────────────────────┤
│  [1-4] select patch   [r] refresh   [p] path   [q] quit │
└─────────────────────────────────────────────────────────┘
```

Exact box-drawing may be simplified to plain lines if needed for terminal compatibility; information hierarchy is mandatory:

1. Target path + summary counts always visible on the main screen
2. List columns: index, status, short name, one-line note
3. Long PURPOSE text only on the detail screen

### 5.2 Status vocabulary

| Display | Meaning |
|---------|---------|
| `✓ APPLIED` (green) | Check reports patch present |
| `· idle` (gray) | Check reports patch absent |
| `! ERROR` (red) | Check failed (parse, missing markers, IO, missing node, etc.) |
| `? UNKNOWN` (yellow) | Unparseable outcome (should be rare; treat as engineering defect if common) |

### 5.3 Navigation

```
Main
  ├─ 1-4 → Detail
  │     ├─ [a] Apply   → Confirm → Run → Result → refresh all → Detail/Main
  │     ├─ [r] Restore → Confirm (strong if multi-applied) → Run → Result → refresh all
  │     ├─ [c] Check   → update this patch status (no confirm)
  │     └─ [b] Back
  ├─ [r] Refresh all four checks
  ├─ [p] Set/replace cli.js path → validate → refresh all
  └─ [q] Quit
```

### 5.4 Confirmations

- **Check:** no confirmation.
- **Apply:** show patch name, target path, backup suffix that will be created, list of currently applied patches; confirm with `y` (default **N** on empty enter).
- **Restore with exactly one patch applied:** same style; confirm with `y`.
- **Restore with two or more patches applied:** risk banner required:

  - Restore overwrites **entire** `cli.js` from that patch’s latest whole-file backup.
  - Other patches may disappear as a side effect; post-op check is authoritative.
  - Suggest LIFO restore order when user applied A then B.
  - Confirm token is the full word **`yes`** (not just `y`) to reduce accidents.

### 5.5 Post-operation

1. Print success/failure summary (paths + patch id).
2. Always run **full refresh** of all four checks.
3. If restore caused other patches to flip from APPLIED → idle, surface a one-line note that this is expected whole-file rollback side effect.
4. Remind user to restart Claude Code after successful apply (same operational note as legacy scripts).

## 6. Built-in patch registry

Hard-coded in the manager (order fixed as shown):

| id | Short name | One-line note | Backup suffix |
|----|------------|---------------|---------------|
| `auto-mode` | Auto Mode | Unlock Auto Mode: model eligibility + classifier fail-open + classifier model env | `backup-automode-model` |
| `keybindings` | Keybindings | Enable custom keybindings; Ctrl+C exits (Escape interrupts) | `backup-keybindings-enable` |
| `transcript-dialog` | Transcript Dialog | Replay permission dialogs lost on Ctrl+O transcript screen | `backup-transcript-dialog-replay` |
| `ultracode` | Ultracode Unlock | Unlock ultracode for max-capable models without xhigh | `backup-ultracode` |

Detail screens may show longer PURPOSE text migrated from legacy script headers.

Adding a fifth patch in a future version means: one registry row + three functions (`check`/`apply`/`restore`) in the same file.

## 7. Internal architecture

### 7.1 File layout (logical sections inside one script)

```
cc-patch-manager.sh
├── 1. Header: version, usage, globals
├── 2. UI primitives: colors, clear, banner, table row, confirm, pause
├── 3. Target resolution: find_cli_js, validate, set_target
├── 4. Registry: PATCH_IDS + metadata getters
├── 5. Patch engines (per id):
│     patch_<id>_check | apply | restore
├── 6. Orchestration: refresh_all, apply_with_confirm, restore_with_confirm
├── 7. Screens: main, detail, confirm/result
└── 8. main: argv → detect path → first refresh → menu loop
```

### 7.2 Per-patch contract

Every patch implements:

```
check(cli_path)   → status ∈ {applied, idle, error} + human message
apply(cli_path)   → ok|fail + message; on success creates cli.js.<suffix>-<timestamp>
restore(cli_path) → ok|fail + message; restores from newest matching backup
```

Menu code calls patches **only** through this contract (by id). It never embeds AST details.

### 7.3 State storage

- No on-disk truth file.
- In-memory maps: `STATUS[id]`, `MSG[id]`, optional last operation summary.
- Refreshed on startup, `[r]`, successful apply/restore, and detail `[c]`.

### 7.4 Migration source

Patch detection and mutation logic is **ported** from the four legacy scripts (Node temporary scripts + acorn AST edits). Shared concerns (path find, acorn cache, backup naming, colored output, CLI flags) are unified once inside the manager.

Legacy scripts are **not** subprocess dependencies.

## 8. Target `cli.js` resolution

### 8.1 Priority

1. CLI argument: `./cc-patch-manager.sh /path/to/cli.js`
2. Env: `CLAUDE_CLI_PATH` if set and file exists
3. Auto-detect first existing path among:

   - `$HOME/.claude/local/node_modules/@anthropic-ai/claude-code/cli.js`
   - `$HOME/.claude/local/node_modules/@cometix/claude-code/cli.js`
   - `$(npm root -g)/@anthropic-ai/claude-code/cli.js` (if `npm` works)
   - `$(npm root -g)/@cometix/claude-code/cli.js`
   - `/usr/local/lib/node_modules/@anthropic-ai/claude-code/cli.js`
   - `/usr/local/lib/node_modules/@cometix/claude-code/cli.js`
   - `/usr/lib/node_modules/@anthropic-ai/claude-code/cli.js`
   - `/usr/lib/node_modules/@cometix/claude-code/cli.js`

This merges legacy differences: some scripts only searched `@cometix`; newer ones also search `@anthropic-ai`. The manager searches **both**.

### 8.2 Failure / change

- If no target: show `Target: (not found)`, disable apply/restore, allow `[p]` to set path manually; checks yield ERROR or are skipped with clear messaging.
- `[p]`: read path, require regular readable file, set global `CLI_PATH`, full refresh.
- Apply/restore additionally require write permission on `cli.js` (and ability to create backups in the same directory).

## 9. Backup and restore semantics

| Item | Rule |
|------|------|
| Location | Same directory as `cli.js` |
| Name | `cli.js.<BACKUP_SUFFIX>-<timestamp>` |
| Suffix | From registry (section 6); keep legacy suffix strings for compatibility with existing backups |
| Apply | Before mutating, create a new timestamped whole-file backup when applying a change |
| Restore | `ls -t cli.js.<suffix>-* \| head -1` then copy over `cli.js` |
| No backup | Restore fails with explicit error; no silent no-op success |
| History | Do not auto-delete old backups in v1 |

**Critical honesty:** backups are whole-file snapshots, not patch-scoped diffs. Restoring patch A after A+B were applied can remove B’s changes. UX must state this; post-restore full check is mandatory. v1 does **not** implement smart re-apply of survivors.

## 10. Dependencies

| Dependency | Role | If missing |
|------------|------|------------|
| `bash` | Host script | Cannot run |
| `node` | AST parse/patch (same as legacy) | Startup or preflight fails; disable check/apply/restore with install hint |
| `curl` | First-time acorn download | Fail with clear message unless cache already present |
| `tput` / ANSI | Colors / clear | Degrade to plain text; features remain |

**Acorn cache (v1):**

- Path: `/tmp/acorn-claude-fix.js` (same as legacy scripts for reuse)
- Source: `https://unpkg.com/acorn@8.16.0/dist/acorn.js` via curl when missing
- Shared by all four patch engines inside the single file (download at most once per machine cache miss)

No Python, no extra global npm packages, no gum/fzf.

## 11. CLI surface

```
./cc-patch-manager.sh                  # interactive menu (default)
./cc-patch-manager.sh /path/to/cli.js  # set target, then menu
./cc-patch-manager.sh --check          # non-interactive: print four statuses, exit
./cc-patch-manager.sh --help
```

v1 does **not** provide non-interactive apply/restore bulk commands (YAGNI; prevents accidents). Interactive confirmed actions only.

**Exit codes:**

- `0` — normal interactive quit, or `--check` completed with no ERROR statuses
- `1` — invalid target / missing hard dependency / `--check` reported at least one ERROR

## 12. Error handling principles

- Fail fast with context: patch id, `cli.js` path, underlying reason.
- Never report success if the file was not updated as claimed.
- Map Node machine markers (aligned with legacy) into status:

  - `ALREADY_PATCHED` → `applied`
  - `NEEDS_PATCH` / `PATCH_COUNT` → `idle`
  - `PARSE_ERROR` / `NOT_FOUND` / unexpected non-zero without known markers → `error`

- Prefer emitting stable machine-readable tokens from the embedded Node helpers so the Bash layer does not scrape localized success prose.
- User cancel at confirm → no file changes.

## 13. Security and safety boundaries

- Only mutates local `cli.js` and creates `cli.js.<suffix>-*` backups beside it.
- No network use except optional acorn download from the fixed unpkg URL.
- No reading of Claude conversation transcripts for patch logic.
- Serial operations only (no parallel apply).
- Level-appropriate caution: apply/restore always confirmed; multi-patch restore requires `yes`.

## 14. Acceptance checklist (manual)

Implementation is not done until these pass on a real install path (or a deliberate copy of `cli.js` used as target):

1. **No cli.js:** starts without crash; shows not-found; apply/restore unavailable; `[p]` can set path.
2. **Valid cli.js:** auto-detect or argv sets correct Target in header.
3. **Full check:** four statuses match conclusions of legacy scripts’ `--check` on the **same** path (behavioral parity).
4. **Apply idle patch:** confirm → success → backup created → status APPLIED → restart reminder.
5. **Apply when already applied:** safe skip / already-applied message; file not corrupted.
6. **Restore single applied patch:** returns to idle; content restored from that suffix’s latest backup.
7. **Multi-patch:** apply A then B → restore A → must require `yes` → full check reflects whole-file side effects.
8. **Cancel confirm:** non-`y` / non-`yes` leaves file and statuses unchanged.
9. **Refresh / path change:** `[r]` and `[p]` update list consistently for the active target.
10. **UI:** no extra TUI deps; critical info readable without horizontal chaos on a normal terminal width (~80 cols preferred).

## 15. Implementation notes for the plan phase

- Port AST patch bodies carefully; keep backup suffixes identical so existing backups remain restorable.
- Unify path detection before any per-patch logic runs.
- Keep Node helpers temporary (`mktemp`) and cleaned up; same pattern as legacy.
- Structure the Bash file with clear section banners so a ~long single file remains navigable.
- Prefer correctness and parity with legacy check/apply/restore over UI chrome.
- After implementation, run the acceptance checklist; do not claim done without evidence.

## 16. Documentation / repo note

- Spec path: `docs/superpowers/specs/2026-07-11-cc-patch-manager-design.md`
- At design approval time the workspace was **not** a git repository. This file is written to disk; git init/commit is out of band unless the user requests it.

## 17. Next step

After user review of this spec file, create a detailed implementation plan via the **writing-plans** skill (not implementation yet).
