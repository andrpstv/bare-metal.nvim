# Large-file open latency: architecture analysis and hypothesis tree

Branch: `refactor/simplify-and-harden` · Date: 2026-09-25 · Read-only investigation
Machine: macOS 26.3 arm64 (Apple Silicon), nvim headless benchmarks.

## 0. Method and evidence base

All numbers below are wall-clock, measured with `nvim --headless` + `vim.uv.hrtime()`
around `vim.cmd.edit(file)`, min of 2–3 runs. Test corpus (Go, from the local
toolchain — the same stdlib a user hits with "large Go files"):

| file | lines | bytes | size guard |
|---|---|---|---|
| `net/http/h2_bundle.go` | 12 226 | 397 049 | line-count guard (>10 000) |
| `net/http/client.go` | 1 053 | ~30 K | none |
| `/tmp/big.txt` | 19 999 | ~0.6 MB | line-count guard |

**Important measurement caveat up front:** headless mode forces
`defer_enabled() == false` (`lua/distro/loader.lua:157-165` requires
`#vim.api.nvim_list_uis() > 0`), so *all* turbo/defer paths are inert in these runs
unless the code explicitly checks `NVIM_DISTRO_SYNC`. `NVIM_TURBO=1` still changes
behaviour because several WIP sites branch on `turbo.is_on()` *before* the headless
check. Numbers below therefore measure the **synchronous** (worst-case) path, and the
turbo column measures a genuine improvement rather than a headless artifact. Interactive
latency will be lower but shares the same rank ordering.

## 1. Measurements

### 1.1 Cold open (first `edit` of the session, everything un-loaded)

| case | OPEN_MS | ft | large_file |
|---|---|---|---|
| h2_bundle.go (12k LoC), distro | 70.8 / 71.6 / 92.4 / 93.9 | `off` | true |
| h2_bundle.go, distro + `NVIM_TURBO=1` | 27.1 / 27.9 / 29.4 | `off` | true |
| h2_bundle.go, **clean nvim** (`-u NONE`) | **1.4 / 1.5 / 1.7 / 1.9** | — | nil |
| big.txt (20k lines), distro | 72.1 / 73.4 | `off` | true |
| big.txt, clean nvim | 2.2 / 2.2 | — | nil |
| **client.go (1k LoC), distro** | **100.4 / 108.1** | `go` | nil |

### 1.2 Warm open (second file, lazy plugins already resident)

| case | WARM_OPEN_MS |
|---|---|
| distro, normal | 27.5 |
| distro, `NVIM_TURBO=1` | 21.9 |
| clean nvim | ~1.5 |

### 1.3 Post-open settle (3 s window) — what got loaded

* large Go file: `gitsigns.nvim, nvim-lspconfig, nvim-cmp + full dep chain
  (LuaSnip, cmp_luasnip, cmp-nvim-lsp, cmp-path, cmp-buffer, cmp-cmdline,
  friendly-snippets)`, plus the two `start` plugins. **nvim-treesitter NOT loaded.**
* small Go file: the same, **plus** `go.nvim, guihua.lua, nvim-lint, nvim-dap,
  nvim-dap-go, nvim-dap-ui, nvim-nio` (7 more plugins, all `ft = go`).
* `redraw!` costs 7–11 ms in both cases (statusline, 245 registered autocmds).

### 1.4 The finding that reframes the problem

**The small Go file costs MORE than the large one (100 ms vs 71 ms), and the large
file is already fully degraded (`ft=off`, `syntax=off`, `lsp=0`, `ts=nil`,
`gitsigns=nil`, `foldmethod=manual`).** The distro is ~40–50× slower than clean nvim
on *every* file size, and the "large Go files are disproportionately slow" symptom is
**not** visible in these headless numbers — it is inverted.

Two consequences:

1. Whatever makes the distro slow is a **fixed per-open cost**, not a
   buffer-size-dependent one. The `large_file` machinery is working exactly as designed.
2. The user-reported size dependence must come from a path that is **not** taken
   headless: the interactive-only defer queue (`defer_until_idle` treesitter,
   `defer_idle` gitsigns/cmp), gopls actually attaching and indexing, real
   redraw/screen painting, and gitsigns' git subprocess. That is precisely the region
   the WIP touches — and precisely what these measurements cannot see. This is a
   real, load-bearing limitation of the current evidence and should be stated, not
   papered over.

## 2. Architecture map: the open path

`BufReadPre` → `BufReadPost` → `FileType` → `BufEnter` → first redraw.

### 2.1 `nvim_create_autocmd` inventory (source-level, all groups)

| Event | Pattern | Group / file | Work | Risk |
|---|---|---|---|---|
| `BufEnter` | `NvimTree_*` | NvimTreeAutoClose, `event.lua:5` | `winlayout()` + `confirm quit` | cheap, but `confirm` is a **blocking prompt** if a 2-window NvimTree layout ever occurs mid-open |
| `FileType` | qf/help/man/notify/nofile/terminal/prompt/toggleterm/copilot/startuptime/tsplayground | QClose, `event.lua:21` | `nvim_buf_set_keymap` | trivial |
| `LspAttach` | `*` | LspKeymapLoader, `event.lua:48` | keymaps, `vim.lsp.completion.enable(false)`, **inlay hints enable** | per-attach only; `large_file` detaches here |
| `DirChanged` | `*` | CdFollow ×2, `event.lua:89,102` | `vim.cmd.cd` / `edit` | fires on every cwd change incl. plugins calling `lcd`; `vim.cmd.edit` in the netrw branch is a **nested buffer open** |
| `BufReadPost` | `*` | LargeFileDetectPost, `event.lua:117` | `enforce()` then mark-restore | correct and early |
| `WinEnter,BufEnter,InsertLeave` | `*` | `_wins`, `event.lua:241` (WIP turbo) | `vim.wo.cursorline` toggle | **high-frequency**; early-returns keep it ~free |
| `WinLeave,BufLeave,InsertEnter` | `*` | `_wins`, `event.lua:258` (WIP turbo) | `vim.wo.cursorline=false` | same |
| `BufWritePost` | `$VIM_PATH/*` | `_bufs` (vimscript) | `nested source` + `redraw` | full config re-source on config write |
| `BufWritePost,FileWritePost` | `*.vim` | `_bufs` | `nested source <afile>` | recursive-source risk if written from itself |
| `BufWritePre` ×7 | `*~`, `/tmp/*`, `*.tmp`, `*.bak`, MERGE_MSG, description, COMMIT_EDITMSG | `_bufs` | `setlocal noundofile` | trivial |
| `VimLeave` | `*` | `_wins` | `wshada` | fine |
| `FocusGained` | `*` | `_wins` | **`checktime`** | full stat sweep of every open buffer; hurts on slow/network mounts |
| `VimResized` | `*` | `_wins` | **`tabdo wincmd =`** | O(windows) |
| `FileType` | `*`,`markdown`,`dap-repl`,`c,cpp` | `_ft` (vimscript) | option sets, `dap.ext.autocompl` | fine |
| `TextYankPost` | `*` | `_yank` | `highlight.on_yank` | trivial |
| `BufReadPre,BufNewFile` | `*` | LargeFileDetect, `large_file.lua:17` | `uv.fs_stat` + `line_count`; sets syntax/ft/swap/undo off | **the size-dependent gate — see §4** |
| `BufReadPost` | `*` | LargeFileDetectPost | `enforce()` | second line-count gate |
| `BufWritePost` | `*.go` | GoSave, `go.lua:50` | 2 chained LSP requests (organizeImports → formatting) + `noautocmd update` | save-path only |
| `BufReadPost,BufEnter` | `*` | GoLibRO, `go.lua:111` | `nvim_buf_get_name` + `is_go_lib` path regex | trivial, but `BufEnter` = hot |
| `BufWritePre` | `*` | GoLibRO, `go.lua:126` | path check | trivial |
| `BufReadPre` | `*` | DistroLazy (loader) | → `kick("nvim-treesitter")` → **`defer_until_idle`** | interactive only |
| `BufReadPre,BufNewFile` | `*` | DistroLazy | → `kick("nvim-lspconfig")` → `defer_idle` (synchronous in headless) | **loads the whole lspconfig on first open** |
| `BufReadPost` | `*` | DistroLazy | → `kick("gitsigns.nvim")` → `defer_idle` | git subprocess on attach |
| `CursorHold,CursorHoldI` | `*` | DistroLazy | → `kick("flash.nvim")`; **once** → `drain_idle()` | interactive only |
| `InsertEnter,CmdlineEnter` | `*` | DistroLazy | → `kick("nvim-cmp")` | 8-plugin dep subtree |
| `FileType` | `go,gomod,gosum` | DistroLazy | → `go.nvim` (defer_idle), `nvim-lint`, `nvim-dap`+3 deps | ft-triggered |
| `FileType,BufReadPost` | `*` | TreesitterTierFolds, `treesitter.lua:79` | `nvim_list_wins()` loop, sets `foldmethod=manual` if tier ≠ full | per-open win scan |
| `VimEnter` +300 ms | once | DistroLazy | watchdog: force-loads `nvim-cmp` **and flushes the whole pending+idle queue synchronously** | **key finding — see H3** |
| `CursorHold,CursorHoldI,InsertLeave` | `*` | DistroLazy (once) | `drain_idle()` | interactive only |
| `VimLeavePre` | once | DistroLazy | `idle_timer:stop()` | fine |
| `BufEnter,BufWritePost` | `*` | StlCache, `statusline.lua:151` | b:var tick | trivial |
| `LspAttach,LspDetach` | `*` | StlCache | cache clear | trivial |
| `BufWritePost,FocusGained,BufEnter` | `*` | StlCache | git cache clear | trivial |
| `DiagnosticChanged` | `*` | StlCache | `_stl_count_diags` | **O(diagnostics), not O(lines)** — but see H5 |
| `BufWipeout,BufDelete` | `*` | StlCache | cache clear | fine |
| `ModeChanged` | `*` | StlCache | `redrawstatus` | per mode change |
| `BufEnter,InsertLeave,BufWritePost` | `*` | (completion.lua:160) | cmp enable/disable | on hot `BufEnter` |
| `InsertCharPre` | `*` | signature.lua:223 | signature help | **per keystroke** |
| `CursorMovedI` | `*` | signature.lua:266 | signature autohide | **per keystroke** |
| `InsertLeave,BufLeave,WinLeave` | `*` | signature.lua:302 | close | fine |
| `CursorMoved` | `*` | signature.lua:306 | re-arm | **high-frequency** |
| `BufWritePost` | `*` | lint.lua:48 | `nvim-lint` lint by filetypes → **spawns `staticcheck`/`golangci-lint`** | save-path process spawn |
| `ColorScheme` | `*` | utils/init.lua:45 | palette refresh | rare |
| `CursorMoved` | `buffer` (Distro UI only) | DistroUITitle, `ui.lua:689` | title update | **buffer-local; only in the Distro picker** — not a real hot path |

Buffer-size-dependent / process-spawning / FS-touching summary:
* **Process spawning:** gitsigns (`git`), nvim-lint (`staticcheck` etc. on write),
  loader's `nvim-lua/plenary`/build steps, `uv.fs_stat` in `large_file.lua` and
  `loader.is_present` (one `fs_stat` per manifest entry per `kick`).
* **FS reads:** `large_file.is_large_file` (`uv.fs_stat`), `loader.is_present`,
  `loader.source_after` (glob on every load), `checktime` on `FocusGained`.
* **Forces redraw on a size-dependent path:** `REDRAW_MS` measured 7–11 ms with 245
  autocmds; the statusline `%!v:lua._statusline()` is re-evaluated on every redraw and
  does `nvim_buf_get_name`, `fnamemodify`, `_stl_human_size`, devicon glob/cache lookups.

## 3. What the WIP does, and why (design intent vs measured effect)

| # | File | Change | Intent | My assessment |
|---|---|---|---|---|
| T1 | `completion/lsp.lua` | static `TURBO_CMP_CAPS` replacing `cmp_nvim_lsp.default_capabilities()`; real cmp loaded on schedule/InsertEnter | stop pulling 7 cmp plugins into the open path | Correct in intent. **Risk:** the static table omits `documentSelector` and (per the comment) mirrors only `default_capabilities()`. If a server's capabilities were computed from cmp elsewhere, gopls could see a *different* initialize payload between the static and real paths. Claim in the comment ("gopls reads caps once at initialize, already-attached clients don't change") is only true for buffers already attached — a buffer opened *after* the schedule fires is fine, but the first attach may use the static table permanently for that buffer. gd/gr unaffected; completion `resolveSupport` fields are present, so the main risk is a silent capability regression, not breakage. |
| T2 | `themes/black-metal-khold.lua` | custom highlights moved to CursorHold/InsertLeave/300 ms | avoid a post-colorscheme redraw | Removes a *redraw*, not size-dependent work. `M.apply_pending` defined **only inside the turbo branch** — `core.turbo.disable()` guards with `theme.apply_pending ~= nil`, so it degrades safely. Uses `clear = true` on the augroup, so a re-`:colorscheme` in turbo mode replaces the pending timer cleanly. Sound. |
| T3 | `ui/gitsigns.lua` | `auto_attach=false` under turbo; manual `actions.attach` on CursorHold/CursorHoldI/InsertLeave/BufWritePost | don't run git on open | **Strongest member of the set** — gitsigns' `attach` is the one genuinely size-dependent external cost. Three real bugs: (a) the callback sets `vim.b[ev.buf].gitsigns_deferred = true` **before** the `large_file` and `executable("git")` guards, so a large file marks itself done and never retries even if the guard later stops applying; (b) `executable("git")` runs on **every** fire of all four events until one succeeds — `CursorHold` is frequent, and `executable()` is a `$PATH` scan (a subprocess-shaped cost on some platforms, see §6); (c) `vim.b[ev.buf]` on a non-current, non-loaded buffer can error. Also `mapping.gitsigns(bufnr)` is only called through `on_attach`, so a file excluded by the `large_file` guard is fine — but a buffer where `git` is missing silently never gets keymaps. |
| T4 | `core/init.lua` | pairs + format_on_save deferred to `vim.schedule` | don't build buffers/ftplugin at boot | Correct pattern. Headless keeps the synchronous path — correct, and required for the `:Format` command contract. **Caveat:** `configure_format_on_save` registers a `BufWritePre`; a `:w` issued before the scheduled callback runs (e.g. `:edit f | :w` in one command line, or `-c 'edit x' -c 'w'`) skips formatting. The comment claims "vim.schedule runs before first input" — true for interactive typing, **not** for same-tick command sequences. |
| T5 | `core/event.lua` | 2 vimscript cursorline rules → 2 Lua callbacks with early return | cut per-keystroke/`:bwipe` cost | Behaviorally faithful (denylist prefix check replicates the regex; note `filetype=""` and `~=` semantics match). **Risk:** `_wins` is created by `nvim_create_augroups` via `augroup _wins`, and the WIP then calls `nvim_create_augroup("_wins", { clear = false })` — the augroup name here is created *without* the leading underscore, so the two autocmds land in a **different group** (`_wins` vs the builder's `_` + `wins` = `_wins`) — actually the same string, so this is correct, but it is fragile: any future rename of the builder silently splits the group. `vim.wo.cursorline` is window-local and these fire on `BufEnter` with `pattern="*"` for buffers not in the current window — the original vimscript had the same semantics, so no regression. |
| T6 | `keymap/statusline.lua` | on diag-cache miss under turbo, show zeros instead of calling `_stl_count_diags` | avoid `vim.diagnostic.get` on redraw | Measured `redraw!` at 7–11 ms; the diag fallback is one of the contributors. The change is *correct* but the WIP also **caches at module load** (`pcall(require,"core.turbo")` at file top, and `_turbo.is_on()` called per redraw) — `is_on()` is env/g reads only, so the "zero-cost" claim holds. Minor: `_stl_diag_cache` is now never populated on a miss, so *every* redraw before the first `DiagnosticChanged` re-evaluates the turbo branch — cheap, but a deopt for the non-turbo path's cache warmth. |
| — | `distro/loader.lua` | `M.drain_all()` | lets `:TurboOff` flush deferred work | **Bug:** `drain_all` clears `pending[name]` then calls `M.load(name)` — correct. But `drain_idle()` short-circuits on `idle_fired`, so if the idle queue already fired, `drain_all` is a no-op for it, which the docstring claims is fine. `pairs()` over a table being mutated inside `M.load` (which can `kick` nothing, but can re-enter via `finish_subtree`) is a mutation-during-traversal hazard: **`pending[name] = nil` inside the loop body is legal, but a plugin's config that calls `M.kick` for a not-yet-visited name would silently drop it.** Low probability, real class of bug. |
| — | `distro/bench.lua`, `benchui.lua` | prepend turbo status to the report header | label measurements | Harmless. Note `bench.lua` deliberately does *not* set `NVIM_DISTRO_SYNC=1` in the child, so child measurements run with the parent's `NVIM_TURBO` inherited — correct for an A/B, but it means the child is **not** comparable to the historical (pre-turbo) numbers unless the label is read. |

## 4. Buffer-size-dependent work: audit

* **`core/large_file.lua` gates are inconsistent and the primary gate is inert.**
  `is_large_file` runs on `BufReadPre`, where `nvim_buf_line_count` is still ~0, so
  the **10 000-line guard cannot fire at that point** — only the 1 MB `fs_stat` guard
  can. `h2_bundle.go` (12 226 lines, 397 KB) is *under* 1 MB, so at `BufReadPre` it is
  not detected; the 397 KB is also below the default `'maxmempattern'`-irrelevant limits
  but above nothing in particular. It is caught only later by `enforce()` on
  `BufReadPost` via the line count — **after** `FileType` has already run and
  `nvim-lspconfig` has been kicked on `BufReadPre`. Confirmed by measurement: `large=true`
  with `ft=off` at the end, but `nvim-lspconfig` and the whole cmp chain are in the
  loaded set. **This is a genuine ordering defect, not a tuning issue.**
* `enforce()` correctly detaches LSP clients and calls `vim.treesitter.stop`, but it
  cannot un-run the `FileType` ftdetect/ftplugin work or the `BufReadPre` lazy kicks.
* **Treesitter tiering is sound but the file never reached it.** `ts_tier()` maps
  >10 000 lines → `off`, 2 000–10 000 → `lite`, else `full`; the `TreesitterTierFolds`
  autocmd sets `foldmethod=manual` off-full. In my runs treesitter never loaded at all
  because `defer_until_idle` needs `CursorHold`/`InsertLeave` or the 300 ms `VimEnter`
  watchdog, and headless fires neither. So **the tier logic is currently untested on the
  exact path the report cares about** — an evidence gap, flagged rather than assumed good.
* **Fold config.** `foldmethod=expr` + `foldexpr=nvim_treesitter#foldexpr()` is set
  globally in `treesitter.lua:73-74`; the only mitigation is a per-open autocmd that
  rewrites `foldmethod` to `manual` when the tier isn't full. Between `BufReadPre` and
  that autocmd, the first redraw of a large file can pay `foldexpr` over the whole
  window. Window: small, but it is exactly the kind of first-paint cost that reads as
  "open latency".
* **Gitsigns.** `diff_opts = { internal = true }` + `watch_gitdir = { follow_files = true,
  interval = 5000 }`: once attached, a 5 s timer stats the gitdir forever, and
  `on_attach` is correctly gated on `large_file` — but only *after* attach has already
  read the index. The WIP's T3 defers that, which is the right lever.
* **LSP.** `vim.b.lsp_disable` is set, but this is not a Neovim built-in; nothing in
  the config reads it, so it is documentation, not enforcement. Real enforcement is
  `event.lua`'s `LspAttach` detach and `large_file.enforce` detaching clients. The
  `LspAttach` handler runs **per client per buffer** and calls
  `require("modules.utils")`, `require("keymap.completion")`, and
  `require("core.settings")` inside the callback — requires are cached, so cheap, but
  the inlay-hint enable does a `nvim_buf_get_name` + `is_go_lib` path regex per attach.
* **Statusline.** `%!v:lua._statusline()` runs on every redraw; `_stl_count_diags` via
  `vim.diagnostic.get` on a cache miss is the only non-constant part (WIP T6 addresses it).
  Measured redraw 7–11 ms, roughly flat in file size.
* **`DirChanged` ×2** are the most surprising pair: any plugin or netrw doing `lcd`
  triggers a global `cd`, which re-triggers `DirChanged` and can trigger a nested
  `edit`. During a large-file open with netrw involved this is a plausible
  disproportionate cost, and it is **not** size-gated.

## 5. Hypothesis tree

### H1 — Fixed per-open cost dominates; the distro is slow on *all* files, and "large Go" is a confound of *which* plugins load
**Confidence: HIGH.**
* Evidence:* clean nvim 1.4–2.2 ms vs distro 70.8–108.1 ms on every file size (§1.1);
  warm open 27.5 ms — i.e. ~45–70 ms of the cold cost is one-time lazy-plugin
  materialization charged to the first `edit`; 245 registered autocmds vs 10.
* Counter-evidence:* the user's premise is size-dependent, and §1.4 inverts it. Under
  headless, large files get *cheaper* because `enforce()` strips them. The size
  dependence must therefore be an interactive-only effect (H2/H3) or a report of
  "slow to become *usable*" rather than "slow to open".
* Falsifier:* measure a *warm* interactive session (plugins pre-loaded) and compare
  open latency for 1 k vs 12 k LoC. If warm large ≈ warm small, H1 is confirmed and
  the size premise is wrong; if large is 2×+ slower warm, H2 becomes primary and H1
  is only about the *first* open.

### H2 — The real size cost is deferred work that fires *after* the file is painted
**Confidence: MEDIUM-HIGH.**
* Evidence:* `nvim-treesitter` (`defer_until_idle`, `BufReadPre`) never loads headless
  but loads on the first `CursorHold`; `gitsigns` (`defer_idle`, `BufReadPost`) attaches
  on idle and runs `git`; the 300 ms `VimEnter` watchdog force-flushes the entire
  pending + idle queue **synchronously**; `foldexpr` is globally `expr` until
  `TreesitterTierFolds` rewrites it; gopls on a 12 k LoC Go file is the classic
  disproportionate cost and it is only stopped *after* attach.
* Counter-evidence:* none directly — but it is unmeasured here by construction
  (`nvim_list_uis() == 0` disables all of it).
* Falsifier:* in a **real UI** session, `nvim -u init.lua --startuptime` plus
  `:Lazy`-style instrumentation, or simply `vim.defer_fn` at 100/300/1000 ms logging
  `loaded` and `vim.b.gitsigns_status_dict`, and compare against `NVIM_TURBO=1`.
  If the post-paint curve is flat for 12 k vs 1 k, H2 is falsified.

### H3 — The 300 ms `VimEnter` watchdog is a latency *hijacker*: it converts deferred work back into a synchronous spike
**Confidence: MEDIUM.**
* Evidence:* `loader.lua:308-325` — on `VimEnter` + 300 ms, it calls `M.load("nvim-cmp")`
  then flushes **all** of `pending` and calls `drain_idle()`. So a user who opens a
  large file and starts moving the cursor ~300 ms after startup pays the entire cmp
  subtree (8 plugins) *plus* whatever `kick` queued, as one blocking chunk, in the
  middle of what feels like the open. This is the single most plausible mechanism for
  "clean is fast, distro is slow" that no amount of headless benchmarking would show.
* Counter-evidence:* `nvim-treesitter` and `gitsigns` are `defer_until_idle`/`defer_idle`
  and `drain_idle` only fires if `not idle_fired`; but the watchdog calls `drain_idle()`
  unconditionally, so it *does* fire them — the "wait for real idle" design is defeated
  by its own watchdog. That strengthens H3.
* Falsifier:* comment out the `for name in pairs(pending)` + `drain_idle()` lines in a
  scratch copy and measure interactive open-to-first-keystroke. No regression →
  the watchdog is free; a large improvement → H3 confirmed and it should be
  narrowed to a per-plugin deadline.

### H4 — `large_file` line-count detection fires too late to prevent work, only to undo it
**Confidence: HIGH (as a defect); MEDIUM as a material latency contributor.**
* Evidence:* `is_large_file` on `BufReadPre` cannot see line count (buffer empty) —
  only the 1 MB `fs_stat` arm can work there; `h2_bundle.go` at 397 KB / 12 226 lines
  is under the byte threshold, so it is caught only by `enforce()` at `BufReadPost`,
  after `FileType` and after the `BufReadPre` lspconfig kick. Measurement confirms
  `nvim-lspconfig` and the full cmp chain load for a file that ends up `ft=off`,
  `lsp=0`, `syntax=off`. That is pure waste — ~8 plugin loads for a buffer that is
  then fully stripped.
* Counter-evidence:* `enforce()` does correctly stop treesitter and detach clients, so
  the *steady state* is right; the waste is bounded and mostly one-time (H1).
* Falsifier:* change the guard to `vim.fn.getfsize()` OR a size-independent early
  heuristic (e.g. `> N bytes` for any file, or reading only the first 64 KB and
  counting `\n`), and check whether a 12 k LoC Go file now avoids loading
  `nvim-lspconfig`/cmp. If it still loads them, the `BufReadPre` hooks are the cause,
  not the guard.

### H5 — Statusline/diagnostic evaluation on redraw is a constant tax, not a size tax
**Confidence: LOW-MEDIUM.**
* Evidence:* `REDRAW_MS` 7–11 ms, and `_stl_count_diags` calls `vim.diagnostic.get`
  on cache miss; WIP T6 targets exactly this. `ModeChanged` → `redrawstatus` adds a
  forced redraw per mode change.
* Counter-evidence:* measured redraw time was essentially flat between 1 k and 20 k
  lines, so this cannot explain size-dependent *open* latency — at most it explains
  general sluggishness. Prioritize for feel, not for the reported symptom.
* Falsifier:* `vim.o.statusline = "%f"` and re-measure open latency warm. If the
  27 ms warm open doesn't drop materially, close this branch.

### H6 — `DirChanged` recursion (CdFollow ×2) causes nested opens / re-`cd` storms
**Confidence: LOW.**
* Evidence:* two autocmds on `DirChanged`; one calls `vim.cmd.cd` (global) whenever
  scope is `window`, the other calls `edit` when netrw is the current filetype. Any
  plugin doing `lcd` therefore converts a window-scope change into a global one and
  re-fires. `DirChanged` fires during buffer open whenever a plugin touches cwd.
* Counter-evidence:* no measurement implicates it; the `scope` guard makes plain
  global changes a no-op. Only bites when something does `lcd` — and netrw/`cd` is not
  in the large-Go-file open path.
* Falsifier:* temporarily neuter CdFollow and open a netrw + `lcd` scenario; measure
  `DirChanged` fire count with a counter autocmd during a large-file open.

### Ranking (confidence-weighted)
1. **H1** (HIGH) — fixed lazy-load + autocmd tax explains ~45–70 ms of every open; the size premise is unconfirmed and partly inverted.
2. **H4** (HIGH as defect) — large-file detection cannot fire its line-count guard at `BufReadPre`, so "large" files pay full plugin load and are then stripped.
3. **H2** (MEDIUM-HIGH) — the actual size-dependent cost lives in deferred/idle work invisible to headless measurement.
4. **H3** (MEDIUM) — the 300 ms `VimEnter` watchdog re-serializes everything it was meant to defer.
5. **H5** (LOW-MEDIUM) / **H6** (LOW).

## 6. Windows / weak-VM risk

* **`vim.fn.executable("git")` on a hot path** (gitsigns WIP T3, `CursorHold` × 2 +
  `InsertLeave` + `BufWritePost`): on Windows `executable()` can fall through to
  `where.exe`/PATHEXT resolution per call, i.e. a possible process spawn on a frequent
  event. Hoist to a one-time `M.is_on()`-adjacent cached check. It is *also* called
  before the `gitsigns_deferred` guard is meaningful on the failing path (§3, T3a/T3b).
* **`watch_gitdir` with `follow_files`** on a network/`\\?\` or 9p mount: a 5 s timer
  doing FS stats on a file that may be on a slow share is a classic weak-VM killer.
  Consider `interval = 10000` or disabling under detected-slow-FS.
* **`checktime` on `FocusGained`** (`_wins`): stats every open buffer; on SMB/WSL-mounted
  paths this is a multi-second stall. Not size-dependent but a large-file-session
  magnifier when many large buffers are open.
* **`uv.fs_stat` in `large_file.is_large_file`** on a network path blocks the `BufReadPre`
  hook synchronously. Use `vim.loop.fs_stat` async or skip when `vim.g.distro_nfs` is set.
* **Path handling:** `loader.source_after` uses `vim.fn.glob` + `fnameescape`; correct,
  but globbing on every load is a stat storm over a cold Windows cache. `keymap/statusline`
  uses `fnamemodify(fname, ":.")` per redraw — path normalisation per redraw is real
  work on Windows-style long paths. `DirChanged` uses `fnameescape` correctly.
* **`noautocmd update` in `core/go.lua`** is written for POSIX-style `lcd` semantics and
  assumes `modifiable`; for a readonly Go-lib buffer it `pcall`s, so it degrades quietly
  — but silently, which is a UX bug worth logging.
* **jsregexp build step** (`LuaSnip` `make install_jsregexp`) requires a working
  `make`/`cc` toolchain; on a locked-down Windows VM that build fails and cmp silently
  loses snippet support.

## 7. Highest-value next experiment

**Measure the interactive post-paint curve, not the open call.** Open a 12 k LoC Go
file in a real UI session under (a) the current tree and (b) `NVIM_TURBO=1`, and record
at t = 0 / 100 / 300 / 1000 ms after `BufReadPost`: elapsed, `nvim_list_uis()`,
`vim.tbl_keys(distro.loader.loaded)`, `vim.b.gitsigns_status_dict ~= nil`,
`#vim.lsp.get_clients({bufnr=0})`, and `vim.treesitter.get_parser(0) ~= nil`.
Do it for 1 k and 12 k files, 5 runs, min reported.

This is the single measurement that discriminates H1 (flat after open → the size
premise is wrong and the fix is the fixed cost) from H2/H3 (a post-paint cliff at
300 ms that tracks line count → deferral policy and the watchdog are the fix), and it
is precisely the region where **every measurement in this report is blind** because
headless mode disables the defer queue entirely. It should precede any refactor.

## 8. Confidence and open questions

* High confidence: H1, H4, and the `BufReadPre` line-count blind spot (all directly
  measured or directly read).
* Medium: H2, H3 — mechanism is clear from source, magnitude unmeasured.
* Low: H5, H6.
* Unknowns I could not resolve in budget: interactive redraw cost for large Go files;
  whether gopls itself is the disproportionate cost; actual treesitter tier behavior
  on a 2 k–10 k LoC buffer (never exercised in these runs); whether the T1 static
  capability table changes gopls' server-side behavior in any observable way.
* No files were modified; no git state was altered. Only
  `docs/distro/10-largefile-analysis.md` was created.
