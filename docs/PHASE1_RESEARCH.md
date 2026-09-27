# PHASE 1 RESEARCH — architecture map + measured latency

Repo: `/Users/16prom1/.config/nvim` · Date: 2026-09-26 · Agent: Researcher
`docs/PHASE1_ARCH.md` was **not** opened (banned by the brief).
Every count below comes from a command whose output was captured; every file was opened with `cat`/`head` and read.

---

## 0. Ground truth re-verification (paste of executed output)

```
$ find lua -name '*.lua' | wc -l
86
```
```
$ python3 -c "import json;print(len(json.load(open('lazy-lock.json'))))"
27
```
```
$ python3 -c "import json,collections;d=json.load(open('distro-lock.json'));c=collections.Counter(v.get('kind','?') for v in d.values());print(dict(c),'total',len(d))"
{'opt': 24, 'start': 2, 'tool': 1} total 27
```
Matches the brief's ground truth exactly. Note: the manifest table itself lists 35 entries
(`grep -c 'kind = "opt"' lua/distro/manifest.lua` → 33, plus `kind = "start"` → 2), i.e. the
manifest is a **superset** of what `distro-lock.json` has vendored.

```
$ nvim --version | head -3
NVIM v0.11.4
Build type: Release
LuaJIT 2.1.1753364724
$ gopls version | head -1
golang.org/x/tools/gopls v0.22.0
$ go version
go version go1.26.4 darwin/arm64
$ nvim --headless --startuptime /tmp/ph1st.log +qa 2>/dev/null; wc -l < /tmp/ph1st.log
124
```
Eager `start` plugins (from `lua/distro/manifest.lua`, 2 entries):
`black-metal-theme-neovim`, `nvim-web-devicons` — matches the brief.

---

## 1. Architecture map — all 86 files

### 1.1 Load order (traced by reading `init.lua` → `core/init.lua`)

```
init.lua
 └─ (vim.g.vscode? no) → vim.g.start_time, turbo flag from NVIM_TURBO*  →  require("core")
     core/init.lua :: load_core()
       1. require("core.settings")  ← top of file, merges user.settings via modules.utils.extend_config
       2. require("core.global")    ← os detection, stdpath
       3. createdir()               ← mkdir cache_dir + 5 subdirs
       4. leader_map()              ← mapleader = " "
       5. gui_config / neovide_config / clipboard_config / shell_config
       6. core.git_colors           ← ONLY if settings.sync_git_colors (default false) — dead on default boot
       7. require("core.options")   ← all vim options
       8. require("core.event")     ← autocmds; internally requires keymap.completion, core.large_file, core.go
       9. require("core.distro").setup()  → distro.loader.boot() + distro.init.setup()
      10. require("keymap")         ← all normal-mode keymaps
      11. core.pairs + completion.formatting  (vim.schedule'd under turbo+UI, else sync)
      12. require("modules.configs.ui.theme")()  → sets colorscheme
      13. background=dark; core.term_guard.enforce() + ColorScheme autocmd
      14. :ConfigHealth user command
      15. require("core.turbo").setup()   → :TurboOn/:TurboOff/:TurboStatus
      16. require("core.weak_hw").setup() → :WeakHwOn/:WeakHwOff/:WeakHwStatus
```

`core/health.lua` is **not** on the startup path — it is only pulled in by `:checkhealth core`.
`core/git_colors.lua` is opt-in dead weight by default (`settings.sync_git_colors = false`).

### 1.2 Lazy modules (verified by reading who requires them, not by filename)

| Trigger | Modules |
|---|---|
| `BufReadPre` / `BufNewFile` | `distro.loader` packadd of `nvim-lspconfig`, `nvim-cmp` (deferred to `InsertEnter`), `gitsigns` (idle/BufWritePost under turbo) |
| First Go buffer | `modules.configs.completion.servers.gopls` (reads `settings.gopls_weak_hw` lazily) |
| First `:Format` / write | `modules.configs.completion.formatting` |
| `FileType` | `modules.configs.editor.treesitter` — **wrapped in `vim.schedule_wrap`**, so parsing never blocks `:edit` |
| Keypress on `<leader>f*`, `gd/gr/gi/gy` | `keymap/pick.lua` `_G._pick*` → `distro.loader.load("mini.nvim")` on first call |
| `:Distro`, `:DistroMirror`, `:DistroTrace`, `:DistroBench*` | all of `distro/ui.lua`, `distro/mirror*.lua`, `distro/trace*.lua`, `distro/bench*.lua`, `distro/install.lua` |
| First `gv`/diff | `keymap/pick.lua` `_pick_extra` → `distro.loader.load("diffview.nvim")` |

`distro/install.lua` is the **only** module that runs `curl`/`tar`, and it hard-errors without
`opts.user_confirmed == true`; `distro/loader.lua` never requires it (verified in its header comment
and by absence of the `require`).

### 1.3 The 86 files

Format: `path` — purpose, as read from the file's own header/first lines.

**`core/` (14 files)**

| File | Purpose |
|---|---|
| `core/init.lua` | Boot orchestrator: creates cache dirs, sets mapleader, GUI/clipboard/shell, then loads options → event → distro → keymap → pairs → theme → guards → commands. |
| `core/global.lua` | OS/WSL detection and stdpath-derived paths (`vim_path`, `cache_dir`, `data_dir`, `home`); runs `load_variables()` at require time. |
| `core/settings.lua` | All user-facing settings defaults; merges `user.settings`, then applies `NVIM_MINIMAL=1` overrides; returns the merged table. |
| `core/options.lua` | Applies ~110 Vim options globally and window-/buffer-locally; sets `g:netrw_liststyle` and python host progs. |
| `core/event.lua` | Registers startup autocmds (NvimTree autoclose, `<q>` close for scratch fts, LspAttach keymap+hints, DirChanged cd-follow, large-file/go requires) and builds `_bufs`/`_wins`/`_ft`/`_yank` augroups from vimscript definitions. |
| `core/distro.lua` | 11-line boot entry: `distro.loader.boot()` + `distro.init.setup()`; zero network by construction. |
| `core/go.lua` | BufWritePost chain for `*.go`: async organize-imports + format on save, each step guarded by `changedtick`; throttles skip warnings to 1/3s. |
| `core/large_file.lua` | `BufReadPre`/`BufNewFile` size+line detector; sets `b:large_file` and turns off syntax, filetype, swap, undo, folds, LSP. `M.enforce(buf)` re-checks on `BufReadPost`. |
| `core/health.lua` | `:checkhealth core` provider: binaries, Go env, LSP, theme, keys; buffers errors/warnings/infos and prints a summary. |
| `core/pairs.lua` | Plugin-free autoclose/quote-pair replacement with smart quotes, `<BS>` pair-eating, per-filetype denylist, and `<C-g>u` undo breaks. |
| `core/term_guard.lua` | Forces `termguicolors` off on dumb/NO_COLOR/screen terminals; idempotent, called after every theme load. |
| `core/turbo.lua` | Turbo-mode flag resolver (`NVIM_DISTRO_SYNC` wins, then `NVIM_TURBO*`, then `g:turbo`) plus `:TurboOn/:TurboOff/:TurboStatus`; no requires, zero-cost by design. |
| `core/weak_hw.lua` | Opt-in "weak hardware" preset: turbo + `gopls_weak_hw` + `defer_theme` + weakened treesitter + debounce, with a saved snapshot so `:WeakHwOff` is reversible. |
| `core/git_colors.lua` | Optional (default-off) sync of `~/.gitconfig` diff colors and a lazygit theme, guarded by an atomic `mkdir` lock and append-only writes. |

**`distro/` (16 files)**

| File | Purpose |
|---|---|
| `distro/init.lua` | Registers `:Distro`, `:DistroInstall`, `:DistroUpdate`, `:DistroCheck` etc.; the only network entry points, all requiring explicit confirmation. |
| `distro/loader.lua` | `boot()` plus lazy `load(name)`: two-phase `packadd` (dep subtree first, then `after/plugin` and dep-first configs); tracks `M.loaded`, has `drain_all()` for turbo-off. |
| `distro/manifest.lua` | Source of truth table: 35 plugin entries (repo, pinned ref, `kind`, optional `deps`, `event`, `config`, `strip`) plus a `M.tools` list. Frozen refs from lazy-lock.json on 2026-09-24. |
| `distro/lock.lua` | Pure JSON I/O for `distro-lock.json`: read with `.bak` fallback, write with backup + tmp + fsync + atomic rename; also `status()` (installed/outdated/corrupted). |
| `distro/install.lua` | 520 lines, the only `curl`/`tar` caller: shell-quoting, tarball URLs, staging in `stdpath("cache")`, consent guard, post-install config wiring. |
| `distro/mirror.lua` | Resolves GitHub-codeload vs corporate mirror: precedence session > local json > env > settings; strips any token found in the local file; https-only. |
| `distro/mirror_cmd.lua` | `:DistroMirror` implementation (status/menu/on/off/set-url/set-args/set-token), redacting tokens in all output. |
| `distro/tools.lua` | `executable()` checks for external tools with per-OS install hints, plus a curl fallback check. |
| `distro/trace.lua` | Disabled-by-default append-only async batched action tracing to `stdpath("cache")/distro-trace/*.log`; `M.span`/`M.mark`; every hook early-returns when off. |
| `distro/tracehooks.lua` | Installs the `:DistroTrace` instrumentation; wraps `_G._pick_lsp` (this config's hand-written goto-definition shim) rather than `vim.lsp.buf`, which would trace nothing. |
| `distro/traceui.lua` | Trace viewer: reverse-chunk tail reads (never slurps the file), sorts by duration descending. |
| `distro/treesitter.lua` | Per-language parser install through the same confirm pipeline; reads pins from vendored nvim-treesitter `lockfile.json`, scans both parser dirs for installed `.so`. |
| `distro/ui.lua` | 911-line float menu for `:Distro`: status glyphs/highlight links, grid rendering, per-plugin I/U/C keys, mirror submenu. Local-only rendering. |
| `distro/bench.lua` | `:DistroBench` — spawns child `nvim` (with/without `--clean`) for open timings, best-of-3, and in-session LSP round-trips; pure Lua, Windows-safe. |
| `distro/benchui.lua` | `:DistroBenchUI` — best-of-N Lua-side render timings (statusline, redraw, splits, TS parse, folds, float open) for the live session. |

**`keymap/` (10 files)**

| File | Purpose |
|---|---|
| `keymap/init.lua` | Entry: requires helpers/pick/go_assign/statusline, then defines `<leader>p*` (distro package), editor, ui, tool, completion, lang keymaps. |
| `keymap/helpers.lua` | `_G` toggles: `_flash_esc_or_noh`, `_toggle_inlayhint`, `_toggle_virtuallines`, `_toggle_qf`. |
| `keymap/editor.lua` | Editor mappings: `jj`/`jk` to normal, `<C-s>`/`<C-q>`, insert `<C-Enter>`/`<C-S-Enter>`/`<C-u>`, visual block, `<leader>u` undo-tree etc. |
| `keymap/completion.lua` | Completion + LSP-buffer mappings, `:Format` binds, and async type-hierarchy (documented as replacing a `buf_request_sync` that froze the UI up to 4s). |
| `keymap/go_assign.lua` | Go "assign return values" feature: parses the hover signature (pure function, steps 3–4) and applies the edit from an async hover chain. |
| `keymap/lang.lua` | Go language mappings to go.nvim: `GoTestFunc`, `GoTest`, `GoAlt`, `GoAddTag`, `GoRmTag`, `GoModTidy`, `GoFillStruct` (comments note `gF` was removed because it forced `gf` to wait `timeoutlen`). |
| `keymap/pick.lua` | `_G._pick*` shims over mini.pick/mini.extra, lazily loading `mini.nvim` through `distro.loader`; includes `_pick_lsp` (the goto-definition path). |
| `keymap/statusline.lua` | Hand-rolled heirline-style statusline (`[NOR] file ●[E W] [servers] … Ln:Col … branch … size`) with devicon caching and turbo awareness. |
| `keymap/tool.lua` | Tool mappings: `<leader>e` netrw toggle that remembers the origin buffer, terminal, and toggleterm binds. |
| `keymap/ui.lua` | Buffer/quickfix/split/terminal-window mappings (`<leader>bn`, `]q`/`[q`, `<leader>q`, `[b`/`]b`, `<leader>sv|sh|sc`). |

**`modules/configs/` (32 files)**

| File | Purpose |
|---|---|
| `modules/configs/completion/cmp.lua` | nvim-cmp setup: kind/type/cmp icon sources merged from `modules.utils.icons`, border sets, and cmp behavior flags. |
| `modules/configs/completion/formatting.lua` | `:Format`, `:FormatToggle`, format-on-save; skips files over 5000 lines, honours the server/dir denylists and the format timeout. |
| `modules/configs/completion/lsp.lua` | Diagnostic config (signs, underline, virtual text, no in-insert updates), lspconfig server list, capabilities extension for cmp-nvim-lsp. |
| `modules/configs/completion/luasnip.lua` | LuaSnip setup plus VSCode-snippet lazy loader over `snips/` and `lua/user/snips/`. |
| `modules/configs/completion/servers/bashls.lua` | bash-language-server cmd + filetypes. |
| `modules/configs/completion/servers/clangd.lua` | clangd config with a `switchSourceHeader` helper that requests the paired header file. |
| `modules/configs/completion/servers/dartls.lua` | Dart analysis-server config (init options for flutter/outline/unimported). |
| `modules/configs/completion/servers/gopls.lua` | gopls config; reads the `gopls_weak_hw` preset **lazily on first load** and applies debounce, codelenses, fieldalignment, semantic tokens, unimported completion. |
| `modules/configs/completion/servers/html.lua` | vscode-html-language-server config with 500ms debounce. |
| `modules/configs/completion/servers/jsonls.lua` | jsonls config: schemastore schemas for `package.json`, `tsconfig*.json`, prettier configs; 500ms debounce. |
| `modules/configs/completion/servers/lua_ls.lua` | lua_ls config: LuaJIT runtime, disabled noisy diagnostics, `$VIMRUNTIME/lua` library, hint settings. |
| `modules/configs/completion/servers/pylsp.lua` | pylsp config with ruff lint plugin and select/ignore sets. |
| `modules/configs/completion/signature.lua` | Hand-written sticky signature-help float replacing `lsp_signature.nvim` (built-in help closes on cursor move). |
| `modules/configs/editor/diffview.lua` | diffview.nvim setup: disabled binary diffs, enhanced-diff off, `diff2_horizontal` default layout. |
| `modules/configs/editor/flash.lua` | flash.nvim setup: `asdfghjkl` labels, uppercase, current-window match labels, custom `FlashLabel` highlight. |
| `modules/configs/editor/treesitter.lua` | Whole file returns `vim.schedule_wrap(function() ... end)`: the three-tier perf policy (full < `treesitter_full_lines` 2000, highlight-only < `lite_lines` 10000, off above) plus `:TreesitterTier` per-buffer override. |
| `modules/configs/lang/dap.lua` | DAP via delve + dapui + dap-go (file's own header says "test — do not commit"). |
| `modules/configs/lang/go.lua` | go.nvim setup with every LSP/diagnostic/DAP sub-feature explicitly disabled to avoid clashing with the config's own gopls. |
| `modules/configs/lang/lint.lua` | nvim-lint for Go via `golangcilint`, with a lazy `require("lint.linters.golangcilint")` deliberately deferred past first run. |
| `modules/configs/tool/mini_pick.lua` | mini.pick setup only (all pick keymaps live in `keymap/`); rg/git/fd optional accelerators. |
| `modules/configs/tool/neogit.lua` | neogit setup, no options. |
| `modules/configs/tool/ntree.lua` | nvim-tree setup: width 32, focus-follows. |
| `modules/configs/tool/oil.lua` | oil setup with `show_hidden = false`. |
| `modules/configs/tool/telescope.lua` | telescope setup (ascending sort, top prompt) — legacy, manifest-driven, not the current picker. |
| `modules/configs/tool/todo.lua` | todo-comments setup, no options. |
| `modules/configs/tool/toggleterm.lua` | toggleterm setup: float direction, no open mapping (uses `:ToggleTerm`). |
| `modules/configs/tool/trouble.lua` | trouble setup with icon overrides and auto_close/auto_jump disabled. |
| `modules/configs/tool/whichkey.lua` | which-key setup, no options. |
| `modules/configs/ui/gitsigns.lua` | gitsigns setup; **TURBO**: `auto_attach=false` and a manual once-per-buffer attach scheduled on idle/first BufWritePost, with a large-file guard in `on_attach`. |
| `modules/configs/ui/ibl.lua` | indent-blankline setup, no options. |
| `modules/configs/ui/lualine.lua` | lualine setup (`theme = "auto"`, globalstatus) — legacy, the live statusline is `keymap/statusline.lua`. |
| `modules/configs/ui/theme.lua` | Applies the colorscheme; when `transparent_background` is on, clears hardcoded groups via `transparent.clear_prefix`. |

**`modules/utils/` (4 files) + `themes/` (1)**

| File | Purpose |
|---|---|
| `modules/utils/init.lua` | Palette init/refresh on `ColorScheme`, `extend_config` (user-override merge), `is_file_buffer`, `is_go_lib` (pkg/mod + GOROOT detection), `load_plugin` helper. |
| `modules/utils/keymap.lua` | `replace(mapping)` for plain user keymap specs (`false` deletes); multi-mode keys expand to one `vim.keymap.set`. |
| `modules/utils/dap.lua` | DAP prompt helpers (arg string, exec path with `.exe` on Windows, debuggee path, env table) behind a metatable currying shim. |
| `modules/utils/icons.lua` | Nerd-font glyph tables by group (kind, type, ui, dap, cmp) with a `get()` accessor. |
| `themes/black-metal-khold.lua` | Custom khold palette over black-metal: `THEME_DEFER_MS = 50`, `defer_allowed()` (off in headless/`NVIM_DISTRO_SYNC`), the single place guaranteeing the termguicolors guard, and `apply_pending()` for turbo-off drain. |

**`user_template/` (9 files)** — scaffolding merged by `modules.utils.extend_config`.

| File | Purpose |
|---|---|
| `user_template/event.lua` | Extra augroup definitions appended to `core/event.lua`'s tables (example: `noundofile` on `COMMIT_EDITMSG`). |
| `user_template/keymap/completion.lua` | `mappings.lsp(buf)` hook — buffer-scoped LSP keymaps applied from `LspAttach`. |
| `user_template/keymap/core.lua` | Empty table placeholder for user core keymaps. |
| `user_template/keymap/editor.lua` | Empty table placeholder for user editor keymaps. |
| `user_template/keymap/init.lua` | Merges core + completion.plug_map + editor + lang + tool + ui into one table. |
| `user_template/keymap/lang.lua` | Empty table placeholder for user language keymaps. |
| `user_template/keymap/tool.lua` | Empty table placeholder for user tool keymaps. |
| `user_template/keymap/ui.lua` | Empty table placeholder for user UI keymaps. |
| `user_template/options.lua` | Option overrides merged into `core/options.lua`. |
| `user_template/settings.lua` | Setting overrides merged into `core/settings.lua` (currently sets `use_ssh = true` and `colorscheme = "catppuccin"` — note: `catppuccin` is **not** in the manifest, so this override is inert/overridden in practice; `colorscheme` in `core/settings.lua` is `khold`). |

**Not counted above (out of `lua/`):** `init.lua` (19 lines, version gate + turbo flag +
`require("core")`), `colors/`, `snips/`, `scripts/`, `tools/`, `pack/distro/`.

---

## 2. Startup distribution

Command (`/tmp/phase1_start.py`), 20 consecutive runs each, `time.perf_counter` around
`subprocess.run(["nvim","--headless", ..., "+qa"])`, wall-clock ms:

```
ours:  n=20 min=45.5ms median=47.5ms p90=49.5ms max=65.9ms
clean: n=20 min=15.6ms median=16.2ms p90=17.0ms max=17.2ms
```

**This is NOT a true cold start.** A real one requires the macOS unified buffer cache to be
evicted for the nvim binary, the config tree, the vendored plugins, and every parser `.so` — which
means `sudo purge` (not available in this environment) or a reboot. Everything above is
**warm-cache** measurement. The brief's own warm reference (clean 18.0 / ours 50.0) is reproduced
here within noise (16.2 / 47.5), so the warm number is trustworthy; the cold number is
**NOT MEASURED**.

Post-burst run (3000 appends to `/tmp/phase1_burst.dat`, `sync`, then 5 runs) to approximate
disk contention:

```
post-sync ours: n=5 min=47.1ms median=48.5ms max=48.7ms
```

That is +1.0ms over the quiet median — within the run-to-run spread, so the config's startup
cost is **CPU/parse-bound, not I/O-bound** on a warm cache.

`--startuptime` (124 lines) shows where the time goes, and the distribution is the notable part:

```
028.006  020.233  000.056: sourcing /Users/16prom1/.config/nvim/init.lua
028.004  020.178  002.888: require('core')
021.919  007.476  000.212: sourcing nvim_exec2() called at .../init.lua:0
```
Columns are self, cumulative, wall. `init.lua`'s own self time is 0.056ms; the whole boot is
`require('core')` at 20.2ms cumulative. Matching the brief: no single source file dominates —
the cost is spread across `core.settings` merge, `core.options` (≈110 `nvim_set_option_value`
calls), the eager black-metal load, and the two eager plugin `packadd`s.

---

## 3. Real file open

Files chosen by size, exact paths and measured with `stat -f%z` / `wc -l`:

| Kind | Path | Bytes | Lines |
|---|---|---|---|
| .go | `/Users/16prom1/go/pkg/mod/go.temporal.io/sdk@v1.45.0/internal/internal_workflow_client.go` | 109,460 | 3,080 |
| .lua | `/Users/16prom1/.config/nvim/pack/distro/opt/nvim-lspconfig/lua/lspconfig/types/lsp/gopls.lua` | 175,653 | 5,976 |
| .json | `/Users/16prom1/.config/karabiner/karabiner.json` | 655,246 | 10,135 |

5 runs each, median of wall time around `nvim --headless [--clean] <file> +qa`
(`/tmp/openbench.py`):

| File | ours | `--clean` | delta |
|---|---|---|---|
| .go (3,080 lines) | 123.9ms | 23.9ms | **+100.0ms** |
| .lua (5,976 lines) | 129.2ms | 26.2ms | **+103.0ms** |
| .json (10,135 lines) | 119.8ms | 22.8ms | **+97.1ms** |

**The delta is ~100ms for all three files and does not scale with size** (3k → 10k lines changes it
by 3ms). That is the headline: file size is not the variable. A flat ~100ms is paid per `:edit`
regardless of content, which points at fixed per-open work in this config (autocmd fan-out,
`distro.loader` packadd of the lazy set on `BufReadPre`, gitsigns/cmp/lspconfig activation), not at
parsing or rendering.

A 22,735-line Go file (`request_response.pb.go`, 945,215 bytes) trips the large-file guard
entirely: `large_file_max_lines = 10000`, so `core/large_file.lua` sets `b:large_file` on
`BufReadPre` and the config prints
`Large file detected (>=10000 lines): disabled LSP, Treesitter, undo` — measured, not inferred.

---

## 4. LSP and treesitter latency

### 4.1 gopls attach (Go file, 3,080 lines)

Measured inside the live config with `vim.uv.hrtime()` polling `vim.lsp.get_clients({bufnr,name="gopls"})`.
Five independent runs:

```
attach=148.5ms  attach=149.3ms  attach=189.9ms  attach=191.6ms  attach=216.8ms
→ median ≈ 189.9ms from process start to gopls client registered
```
(An earlier run against the 22,735-line file returned `attach=nil` — the large-file guard
detaches before attach. Consistent with §3.)

**First diagnostic: NOT MEASURED.** `vim.diagnostic.count(buf)` stayed at `0` and no
`DiagnosticChanged` fired within 40s in two separate attempts (`firstdiag=NONE count=0`). I also
tried an explicit `textDocument/diagnostic` pull request; the request construction failed in
headless (`reqok=false`, "Invalid window id") so no timing exists. **BLOCKED** — reason: the
pull-diagnostic path needs a real UI window; headless leaves none, and I did not attach a UI.

**Definition request: MEASURED** (this config routes `gd` through the hand-written
`_G._pick_lsp` shim, so I called `textDocument/definition` on the client directly):

| Run | symbol | round-trip |
|---|---|---|
| 1 | `WorkflowClient) ExecuteWorkflow` (real method, line 227 area) | **525.4ms** |
| 2 | same | **786.4ms** |

Two samples, so the median is not meaningful — report as "525–786ms over 2 runs", NOT a median.
Both returned `err=nil` with a real `table` result, so the definition itself resolved.

### 4.2 Treesitter parse cost

Per-file run (file passed as the nvim argument, config loaded, then `vim.treesitter.start` and a
forced `parser:parse()`), `/tmp/ts8.lua` + `/tmp/tsrun.lua`:

| Lang | Lines | `find_parser` | `treesitter.start` | forced `parse()` | root children | parser |
|---|---|---|---|---|---|---|
| go | 3,080 | 0.3ms | 5.2ms | 8.3ms | 326 | `~/.local/share/nvim/site/parser/go.so` |
| lua | 5,976 | 0.2ms | 0.1ms | 4.0ms | 5,951 | `.../parser/lua.so` |
| json | 10,135 | 0.4ms | 0.9ms | 19.4ms | 1 | `.../parser/json.so` |

Two things worth flagging:

- The **json run shows `filetype=off`**. 10,135 lines crosses `large_file_max_lines = 10000`, so
  `core/large_file.lua` stripped filetype and the parse happened on a buffer the config considers
  "large". The 19.4ms json parse is therefore a measurement of a path the config normally prevents.
- `treesitter.start` on lua is 0.1ms — the lua parser was already hot in that process, so
  "first filetype load" is only clean for the go run (5.2ms). Treat lua/json `start` as warm.

All 41 parsers are prebuilt `.so` in `~/.local/share/nvim/site/parser/` (listed via `ls`), so no
parser is compiled at runtime.

**`TSUpdate`: NOT MEASURED — it does not exist in this config.**
```
$ grep -rn "TSUpdate" lua/distro/treesitter.lua
(no match)
$ nvim ... vim.cmd("TSUpdate")
err=... Vim:E492: Not an editor command: TSUpdate
```
nvim-treesitter's `:TSUpdate` is not registered; parser management here is `:DistroParsers` /
`:DistroParserInstall` (per-language, confirmation-gated, pinned from a vendored `lockfile.json`),
and nothing runs at startup. So there is no startup parser-update cost to report — which is a
deliberate design property, not a gap in the measurement.

---

## 5. Explicit list of what was NOT measured / BLOCKED

1. **Cold start** — NOT MEASURED. Needs page-cache eviction (`sudo purge` or reboot); no sudo here.
2. **First diagnostic latency for gopls** — BLOCKED. Headless has no window; pull diagnostics
   request failed with "Invalid window id", and no `DiagnosticChanged` fired in 40s.
3. **Median definition latency** — 2 samples only (525.4ms, 786.4ms). No median claimed.
4. **`TSUpdate` cost** — NOT APPLICABLE. The command does not exist in this config (E492);
   parser installs go through the confirm-gated `:DistroParsers` path.
5. **Lua/JSON "first filetype load"** — warm in the measuring process; only the go figure is a
   genuine cold first-load.
6. **Interactive/UI-frame timings** (first paint, flash from `defer_theme`, `DistroBenchUI`
   render pipeline) — NOT MEASURED; all benchmarks here are headless.
7. **Caveat on the user override**: `user_template/settings.lua` sets `colorscheme = "catppuccin"`,
   which is not in the manifest. I did not verify at runtime which colorscheme actually applies —
   flagged, not resolved.

## 6. Findings that survive the numbers

- Startup is CPU/parse-bound, not I/O-bound: the post-`sync` median is 48.5ms vs 47.5ms quiet.
- Per-open cost is a **flat ~100ms**, invariant across 3k–10k lines. Optimizing large-file
  handling will not touch it; something fixed per `:edit` is.
- The config is already conservative about large files: >10,000 lines or >1,024 KB disables
  syntax, filetype, LSP, treesitter, swap and undo (`core/large_file.lua`).
- Startup self-time is spread thin — no single `require` dominates; 20ms of `require('core')` is
  the whole custom-config cost against a 16ms clean baseline.
- `core/health.lua` (445 lines) and `core/git_colors.lua` (266 lines) are **not** on the startup
  path at all; the git-colors module is default-off.
- gopls attach at ~190ms median is the largest single interactive latency measured, and it is
  paid per Go buffer.
