# 12 — Runtime latency audit (P0/P1/P2)

Profile: weak hardware / Windows. Priority = **runtime** latency, not startup.
Repo: `/Users/16prom1/.config/nvim` · nvim 0.11.4 · macOS 26.3 arm64 · date 2026-09-26.
**No config file was modified.** `git status` before/after is identical apart from the two
pre-existing uncommitted files (`lua/core/settings.lua`, `lua/modules/configs/completion/lsp.lua`)
and the two docs I was asked to produce.

`docs/PHASE1_ARCH.md` was not opened (banned). Commit refs quoted are from `git log --oneline -6`:
`0fef284`, `4513f1b`, `76fc78c`, `6fa6263`, `260dc5d`, `e87f309`.

---

## 0. Baseline re-measured (warm cache, 20 runs each, `time.perf_counter` around `nvim --headless … +qa`)

```
ours  n=20 min=42.4ms median=45.1ms p90=48.5ms max=66.1ms
clean n=20 min=14.1ms median=14.7ms p90=15.7ms max=15.9ms
none  n=20 min=17.4ms median=18.3ms p90=20.3ms max=21.9ms   (nvim -u NONE)
```

> **`-u NONE` measured SLOWER than `--clean` (18.3 vs 14.7ms).** That is a measurement artefact,
> not a config property: `--clean` and `-u NONE` differ in plugin/package loading, and on a warm
> cache the 3.6ms gap is inside process-spawn variance. **Treat 15–18ms as the single floor** and
> do not cite a `-u NONE` figure more precise than that.

The brief's baseline (startup 25ms, `require('core')` 19.1ms, cold cache) is **not reproducible on
this machine** — I cannot drop the macOS page cache (no sudo), so everything below is warm. My
warm `require('core')` graph (21.4ms cumulative) is *close* to the brief's 19.1ms, so the
decomposition below is representative even though the absolute cold numbers are not mine.

### Require graph, `require('core')` = **21.390ms cumulative / 6.718ms self**
(`--cmd "lua dofile('/tmp/rl_hook.lua')"`, wraps `require`, attributes self time as
cumulative minus nested requires; top 45 of the graph)

```
 self_ms  cum_ms  module
  6.718  21.390  core
  0.930   0.930  distro.manifest
  0.694   0.694  vim.iter
  0.607   2.050  core.event
  0.559   0.559  black-metal.palette.darkthrone
  0.553   0.553  themes.black-metal-khold
  0.525   0.525  keymap.editor
  0.451   0.451  black-metal.highlights.plugin
  0.413   0.413  vim.version
  0.375   0.498  core.options
  0.344   0.620  black-metal
  0.325   0.325  black-metal.highlights.syntax
  0.314   0.314  keymap.lang
  0.307   0.465  black-metal.highlights.common
  0.284   0.284  distro.loader
  0.276   0.276  black-metal.config
  0.275   0.275  modules.utils
  0.273   0.273  keymap.ui
  0.271   0.271  distro.init
  0.254   0.254  black-metal.palette.dark-funeral
  0.243   3.241  black-metal.palette
  0.237   2.475  keymap
  0.236   0.236  black-metal.terminal
  0.227   0.227  keymap.statusline
  0.219   0.656  core.settings
  0.219   0.219  keymap.go_assign
  0.209   0.209  keymap.completion
  0.202   0.202  black-metal.palette.taake
  0.202   0.202  keymap.pick
  0.192   0.192  black-metal.palette.thyrfing
  0.189   0.189  keymap.tool
  0.184   0.184  core.pairs
  0.180   0.180  black-metal.highlights
  0.170   0.170  black-metal.palette.emperor
  0.168   0.168  modules.configs.completion.formatting
  0.165   0.165  black-metal.palette.bathory
  0.164   0.164  black-metal.palette.windir
  0.163   0.163  black-metal.palette.khold
  0.162   0.162  user.settings
  0.159   0.159  user.keymap.init
  0.158   0.158  black-metal.util
  0.157   0.157  core.large_file
  0.156   0.156  core.global
  0.153   0.153  black-metal.palette.nile
  0.152   0.152  core.go
```

Grouped:

| Group | cum_ms | modules |
|---|---|---|
| black-metal (theme + 15 palettes + highlights) | **~6.4** | palette 3.241, highlights.plugin 0.451, syntax 0.325, common 0.465, terminal 0.236, config 0.276, util 0.158, black-metal 0.620, themes.black-metal-khold 0.553 |
| `keymap` subtree | **2.475** | editor 0.525, lang 0.314, ui 0.273, statusline 0.227, go_assign 0.219, completion 0.209, pick 0.202, tool 0.189 |
| `core.event` subtree | 2.050 | includes keymap.completion 0.209, core.large_file 0.157, core.go 0.152 |
| `distro` subtree | ~1.485 | manifest 0.930, loader 0.284, init 0.271 |
| settings+global+options | 1.150 | settings 0.656 (incl. user.settings 0.162), options 0.498, global 0.156 |
| `core` self (load_core body) | 6.718 | the biggest single line |

---

## P0 — biggest runtime wins

### P0-1. `:colorscheme` re-apply costs 15–24ms **with everything already warm**
**Measurement** (inside the real config, `uv.hrtime`, script `/tmp/rl_cs2.lua`):

```
:colorscheme khold #2 (all warm)     23.722 ms
:colorscheme habamax (builtin base)  10.674 ms
:colorscheme khold #3 (re-apply)     15.427 ms
highlight groups now                 633
scan highlight table                  0.117 ms
```

**This contradicts the brief's "khold.lua 6.06ms" reading and is the most important finding of
this audit.** `--startuptime` attributes ~6ms to `sourcing colors/khold.lua` *plus* ~4ms to the
palette requires; it does not attribute the *highlight-table rebuild* that a colorscheme command
also triggers. Isolated in a fresh process (`/tmp/rl_cs.lua`):

```
black-metal.palette (all 15)   3.301 ms   (39 modules pulled)
black-metal.config             0.326 ms
black-metal.highlights         0.271 ms
require themes.black-metal-khold 0.233 ms
:colorscheme khold (WARM)     23.145 ms
```

So the palette/require part really is only ~3.5–4ms. The remaining **~10.7ms is the builtin
baseline** (`habamax` = 10.674ms), i.e. Neovim's own colorscheme machinery over **633 highlight
groups**, not this config's palette. Any `:colorscheme` in this profile costs ≥10ms.

**File:line.** `lua/core/init.lua:190` (`require("modules.configs.ui.theme")()`),
`lua/modules/configs/ui/theme.lua:1-39`, `lua/core/options.lua:72` (`termguicolors = true`).
**Win:** ~10ms off *every* theme switch today; more if the group count is trimmed. Not removable
at startup without changing the first frame.
**Confidence: HIGH** (measured 3×, both themes, fresh process + real config).

### P0-2. 633 highlight groups is the real paint cost on a GPU-less Windows console
**Measurement:** 633 groups live after startup; scanning the table is 0.117ms (so the count is
not the cost by itself — the cost is the *redraw* of 633 attributes on a truecolor terminal).
**File:line:** `lua/themes/black-metal-khold.lua` (loads all 15 palettes),
`pack/distro/start/nvim-web-devicons/plugin/nvim-web-devicons.vim` (eager `kind=start` plugin,
`lua/distro/manifest.lua:12`), `lua/core/options.lua:72`.
**Win:** not a latency figure I can honestly produce — see "NOT MEASURED" §7. Expected effect is
on redraw time, which I could not measure headless.
**Confidence: MEDIUM** (group count measured; redraw impact not).

### P0-3. First `InsertEnter` cannot complete in headless — and the `cmp_defer_caps` claim does not reproduce
**Measurement** (`/tmp/rl_hot.lua`, `.txt` file, 500 lines, no LSP):

```
### cmp_defer_caps = true   (working-tree default)
BufReadPre->BufReadPost            0.13 ms
total :edit cmd wall               1.24 ms
modules loaded during :edit        0
first InsertEnter + 300ms settle 301.32 ms
cmp loaded after InsertEnter       303.55 ms
cmp requireable = false
luasnip requireable = false

### cmp_defer_caps = false  (greedy path, forced via -c)
BufReadPre->BufReadPost            0.16 ms
modules loaded during :edit        0
cmp requireable = false
```

**The claimed 78.4 → 14.9ms win does NOT reproduce here, and the reason is that neither variant
loads anything.** `distro.loader` never fires in headless:

```
loaded distro.loader = true
loaded nvim-cmp = false
loader.loaded table = {}
NVIM_DISTRO_SYNC=nil turbo=nil
```

`loader.loaded` stays empty, so the `cmp_defer_caps` branch in
`lua/modules/configs/completion/lsp.lua:44` is never reached — the measurement cannot distinguish
the two paths. **The uncommitted change is plausibly correct, but it is UNVERIFIED in this
environment**; it must be re-measured with a UI attached (see §7).
**File:line:** `lua/core/settings.lua:232-243` (new `cmp_defer_caps`),
`lua/modules/configs/completion/lsp.lua:44` (`local defer_caps = …`).
**Win:** claimed 63ms, measured **NOT REPRODUCED / NOT MEASURED**.
**Confidence: LOW.** Do not bank this number.

---

## P1

### P1-1. `updatetime = 1000` and 6 CursorHold-driven plugin triggers — the hot-path tail
**Measurement:** not directly measurable headless. Structural fact from `--startuptime` and grep.
**File:line:**
- `lua/core/options.lua:81` — `updatetime = 1000` (was 200; the comment credits 5× fewer
  CursorHold batches).
- `lua/distro/loader.lua:347` — `{"CursorHold","CursorHoldI","InsertLeave"}` deferred-load trigger.
- `lua/distro/manifest.lua:44` — flash.nvim on `CursorHold`+`CursorHoldI`.
- `lua/distro/manifest.lua:89` — which-key on `CursorHold`.
- `lua/modules/configs/ui/gitsigns.lua:43` — turbo gitsigns attach on
  `BufReadPost,InsertEnter,CursorHold,CursorHoldI,InsertLeave,BufWritePost`.

So a cursor that sits still for 1s can fire 4 independent lazy-load triggers. `gitsigns.lua:34`
sets `watch_gitdir = { interval = 5000 }`, a 5s background git stat loop.
**Win:** bounded but unquantified — each trigger is one lazy load; on a weak box the *first*
one after a pause is a visible hitch. **Confidence: MEDIUM** (structure certain, size unknown).

### P1-2. gitsigns is already deferred, but only under turbo
**File:line:** `lua/modules/configs/ui/gitsigns.lua:22` — `auto_attach = not turbo_defer`.
On the default profile `turbo_defer` is false, so gitsigns attaches **synchronously** on open via
its own autocmds, and `update_debounce = 200` (line 34) with `word_diff=false` and
`current_line_blame=false` already trimmed.
**Win:** the turbo path already removes it; making it default is a *profile* decision, not a bug.
**Confidence: MEDIUM.** Related commit: `6fa6263` (moved gitsigns to BufReadPost).

### P1-3. Treesitter is `vim.schedule_wrap`d — correct, keep it
**File:line:** `lua/modules/configs/editor/treesitter.lua:1` — the whole config module is wrapped,
so parsing never blocks `:edit`. **Measurement** (`/tmp/tsrun.lua`): go 3,080 lines
`start 5.2ms / parse 8.3ms`; lua 5,976 lines `start 0.1ms (warm) / parse 4.0ms`; json 10,135
lines `start 0.9ms / parse 19.4ms` — and that json buffer had `filetype=off` (large-file guard).
**Win:** already deferred. **Confidence: HIGH.**

---

## P2

### P2-1. `distro.manifest` costs 0.930ms to build a table nothing reads at startup
**File:line:** `lua/distro/manifest.lua:6` (`M.plugins = { … 35 entries … }`).
`distro.loader.boot()` needs it, so this is only deferrable if boot is too. **Win:** ≤0.93ms.
**Confidence: HIGH** (measured), **low value**.

### P2-2. `core.pairs` + `format_on_save` scheduled only under turbo+UI
**File:line:** `lua/core/init.lua:178-189` — `vim.schedule` when `turbo_on and #nvim_list_uis() > 0`,
otherwise synchronous. `core.pairs` self 0.184ms, `modules.configs.completion.formatting` 0.168ms.
**Win:** ~0.35ms. **Confidence: HIGH** (measured), **low value**.

### P2-3. `keymap` subtree 2.475ms is irreducible without losing mappings
**File:line:** `lua/keymap/init.lua:1-4` eagerly requires helpers/pick/go_assign/statusline, then
sets every mapping. Each submodule is 0.19–0.53ms. **Win:** ~0.2ms by lazifying
`go_assign` (0.219) + `statusline` (0.227). **Confidence: HIGH** (measured), **low value**.

---

## 4. Sync-blockers audit — the requested checklist

| Suspect | Verdict | Evidence |
|---|---|---|
| `vim.wait` in config | **CLEAN — zero occurrences** | `grep -rn 'vim\.wait(' lua --include='*.lua'` → no matches |
| plenary / job join | **CLEAN — plenary not used** | `grep -rn plenary lua` → no matches; vendored under `pack/` but never required by `lua/` |
| mason | **CLEAN — not used by design** | `lua/core/settings.lua:171` "Бинарники ставятся системно (go install / brew), без mason" |
| update checker at startup | **CLEAN — no lazy.nvim at all** | `grep -rniE 'lazy%.update|checker|check_for_update' lua` → no matches |
| treesitter updater at startup | **CLEAN** | `ensure_installed` at `lua/modules/configs/editor/treesitter.lua:27` is inside a `vim.schedule_wrap`; `:TSUpdate` does not exist (measured `E492: Not an editor command`). 41 parsers are prebuilt `.so` in `~/.local/share/nvim/site/parser/` |
| health check at startup | **CLEAN** | `lua/core/health.lua` (445 lines) is only reached via `:checkhealth core` (`lua/core/init.lua:215`); `core.git_colors` (266 lines) is default-off (`settings.sync_git_colors = false`) |
| spell | **CLEAN** | `spellfile` is just an option path (`lua/core/options.lua:65`); spell is toggled manually via `<leader>o` (`lua/keymap/editor.lua:69`) |
| sync `uv.fs_*` | **CLEAN on the startup path** | 19×`fs_stat`, 7×`fs_scandir`, 1×`fs_realpath` — all metadata, all cheap. The only `fs_fsync` is `lua/distro/lock.lua:60`, reached only when **writing** the lock (`:DistroUpdate/Install`), never at startup. `lua/distro/trace.lua:136` `fs_open` is behind `M.enabled = false` and its own comment says writes are async/scheduled |
| sync shell-outs at startup | **CLEAN** | `grep vim.wait` empty; `core/health.lua:88` uses `vim.system(...):wait()` with a 5s timeout but only under `:checkhealth` |

**Conclusion for §4/§5: there is no sync-update-check tax at startup.** That whole class of
Windows/HDD penalty is already absent by construction (no lazy.nvim, no mason, no plenary,
no startup `:TSUpdate`). The startup cost is Lua sourcing, not I/O — consistent with the Phase 1
result that a `sync` after a 3000-append burst moved the median by +1.0ms only.

## 5. Windows / weak-hardware risks

1. **Highlight count × no GPU** (P0-2). 633 groups, `termguicolors = true`
   (`lua/core/options.lua:72`). On Windows Terminal the repaint is CPU-side ANSI emission.
   **Highest unmeasured risk** — I could not measure redraw headless.
2. **`:colorscheme` is ≥10ms even for `habamax`** (P0-1) — a budget item for any theme work.
3. **`Clipboard` provider probing** — `lua/core/init.lua:50-117` calls `vim.fn.executable()`
   up to ~8 times per platform branch at startup. `executable()` is a `$PATH` scan; on Windows
   with a long `$PATH` and antivirus hooks this is the most plausible slow spot in
   `core`'s 6.718ms self time. **Not separately measured** — a per-call breakdown of
   `load_core` would be needed.
4. **19 `fs_stat` calls** on the loader path — trivial on SSD, non-trivial on a spinning disk or
   a network/home-redirected profile dir (`stdpath("config")` on a redirected `%USERPROFILE%`).
5. **Unicode/truecolor + Nerd Fonts** — `lua/modules/utils/icons.lua` glyph tables plus devicons;
   if the terminal lacks the patched font, missing glyphs force per-cell fallback, which shows up
   as slow redraw, not slow startup.
6. **Deferred work is wall-clock sensitive.** `distro.loader`'s idle/CursorHold triggers
   (`lua/distro/loader.lua:347`) mean a *slow* machine simply pays later and more often — the same
   work, but during editing instead of at startup. The turbo profile is the documented lever
   (`lua/core/weak_hw.lua`).

## 6. Do NOT touch (already good / regression risk)

- **`vim.schedule_wrap` on the whole treesitter config** (`lua/modules/configs/editor/treesitter.lua:1`).
  Already the right design; unwrapping it would put 4–19ms of parse back on `:edit`.
- **The large-file guard** (`lua/core/large_file.lua`, thresholds at
  `lua/core/settings.lua:92,95` = 10,000 lines / 1024 KB). Measured firing on a 22,735-line Go file
  and disabling LSP+TS+undo+swap. Its own comment (`settings.lua:86-90`) documents that lowering
  the threshold to 5000 is a **degradation**, not an optimisation. Leave it.
- **gitsigns already-trimmed options** (`gitsigns.lua:34-38`): `word_diff=false`,
  `current_line_blame=false`, `update_debounce=200`. These are the expensive ones, already off.
- **`updatetime = 1000`** (`lua/core/options.lua:81`): the comment notes most plugins break above
  500; this is a deliberate, already-conservative value. Raising it further shrinks CursorHold
  batches but risks plugin regressions.
- **Async-by-design `core/go.lua`** (organize-imports + format on save, every step guarded by
  `changedtick`, throttled 1/3s notifications). The comment records that the previous
  `buf_request_sync` froze the UI up to 4s. Do not make it synchronous.
- **`core/term_guard.lua`** — idempotent, no side effects on a normal terminal, and the comment
  documents the deliberate decision *not* to force-disable truecolor under `tmux-256color`
  (would break users' truecolor tmux).
- **Pinned manifest refs** (`lua/distro/manifest.lua`) — refs frozen from `lazy-lock.json` on
  2026-09-24; a 0.93ms table is not worth re-resolving commits.

## 7. Explicitly NOT MEASURED

1. **Cold start.** Warm only; no sudo, cannot drop the page cache. The brief's 25ms/19.1ms/6.06ms
   cold figures are **not mine** and I could not reproduce them.
2. **The 78.4 → 14.9ms `cmp_defer_caps` win.** `distro.loader` never fires headless
   (`loader.loaded = {}`), so both settings values measure identically (0.13 vs 0.16ms). Needs a UI.
3. **Hotkey → redraw latency.** Requires a terminal; every number in this file is headless.
4. **Time from `:edit` to first painted frame.** Headless has no paint.
5. **First InsertEnter cost (cmp/LuaSnip).** `cmp requireable = false` after a 300ms settle in
   both variants — the deferred path never completed headless.
6. **First LSP attach.** Measured in Phase 1 (~190ms median, warm) but not re-measured here.
7. **Redraw cost of 633 highlight groups.** Needs a terminal.
8. **Per-call breakdown of `core`'s 6.718ms self time** (e.g. the `executable()` probes in
   `clipboard_config`). Not isolated.
9. **Anything on Windows / real HDD.** All measurements are macOS on an SSD. Every Windows
   projection in §5 is inference, labelled as such.

## 8. Recommended order

1. Re-run P0-3 with a UI attached — it decides whether `cmp_defer_caps` is a real 63ms win or
   noise. Until then it is an unverified change sitting in the tree.
2. Attack the ~10.7ms builtin colorscheme floor (P0-1) — it is the only *measured* multi-ms
   runtime cost in this profile, and it is Neovim's own, not the palette's.
3. Only then consider P1-1 (CursorHold trigger fan-out). It is the biggest remaining structural
   risk on weak hardware but I have no number for it, so it should not outrank a measured item.
