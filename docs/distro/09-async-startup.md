# Async startup: idle-streaming (variant A) + follow-ups (Step 13)

Decision: variant A (maximum). First paint ~50ms, features stream in.
Kill-switch `settings.distro_defer=false` restores byte-identical sync behavior.

## Model

- Phase 0 (sync, budget <50ms): options, keymaps, theme, devicons, stubs, statusline.
- Phase 1 (scheduled, post-paint): deferred triggers don't load synchronously —
  they `kick()` a deduped scheduled `M.load`.
- Phase 2 (idle, one-shot 300ms timer from `VimEnter`): preload cmp chain.
- Headless (no UI): always synchronous (scripts stay deterministic).
- Theme + devicons stay eager (no white flash, statusline icons from frame one).

## A-items

| # | File | Change |
|---|---|---|
| A-1 | `manifest.lua` | `defer_idle = true` on: nvim-lspconfig, nvim-treesitter, nvim-cmp (+deps inherit), nvim-dap (+deps), go.nvim (+guihua), nvim-lint |
| A-2 | `loader.lua` | `pending` set + `kick(name)`: schedule-or-sync by UI presence; all event/ft callbacks go through `kick` |
| A-3 | `loader.lua` | Phase-2 one-shot `uv` timer 300ms on `VimEnter once` → preload `nvim-cmp`; cancel on `VimLeavePre` |
| A-4 | `configs/editor/treesitter.lua` | `foldmethod/foldexpr` set inside scheduled setup only (start `manual`); no `E121` window |
| A-5 | `configs/completion/lsp.lua` | No code change (enable runs in scheduled context); verify LspAttach chain + buffer keymaps on late attach |
| A-6 | `keymap/completion.lua` | `<leader>cl`: notify-once when no lenses instead of silent nothing |
| A-7 | `settings.lua` | `distro_defer = true` + rollback comment |
| A-8 | `health.lua` | `Startup` section shows mode (`deferred`/`eager`) |

## B-items (approved: all incl. B3–B6)

- **B1 tiered treesitter**: `<treesitter_full_lines` (default 2000) full;
  `<treesitter_lite_lines` (default 10000) highlight-only (vim indent, manual folds);
  above → off. Thresholds in settings. `:TreesitterTier` buffer override cycle.
  Health shows current buffer tier.
- **B2 attach on idle**: highlight attach on first `CursorHold`/`InsertLeave`
  (never mid-typing), not blind timer.
- **B3 gopls tuning**: `debounce_text_changes` setting (default 150, weak-PC hint 250);
  audit `analyses` flags with comments; `directoryFilters` for big repos;
  `gopls -remote` daemon: researched, REJECTED (fragile, multi-instance only win).
- **B4 autocmd consolidation**: researched, REJECTED (negative ROI, order-sensitive Go chain).
- **B5 vim.loader**: verify enabled by default on 0.11; enable explicitly if not.
- **B6 `scripts/startup-bench.sh`**: empty/go-file/big-file × clean-vs-ours, min-of-3.

## Risks & mitigations

| Risk | Mitigation |
|---|---|
| `gd`/`:w` in first ~300ms hit "no LSP yet" | guards exist; A-6 makes `cl` explicit |
| Fold jump when treesitter engages | single switch; accepted flicker |
| Double load (trigger + idle timer) | `pending` set + idempotent `M.loaded` |
| Headless scripts change behavior | no-UI → fully synchronous path |
| Broken defer = never-loaded plugin | phase-2 watchdog re-checks `pending`, sync fallback + warn |
| Tier confusion ("no folds here?") | health shows tier; `:TreesitterTier` override |
| Parse starting mid-typing (B2) | attach on idle events only |
| gopls flag side effects (B3) | each flag opt-in with current default |

## Verification

1. `--startuptime` before/after + TUI screenshots ~50ms (plain), ~300ms (highlight), ~800ms (LSP).
2. Races: open + `gd`/`：w`/InsertEnter within 200ms — graceful, zero tracebacks.
3. `distro_defer=false` — today's behavior (startuptime compare).
4. Headless `+qa` and scripts unchanged.
5. Benchmarks: our config vs clean on file open, `gd`, `gr` (see report below).
