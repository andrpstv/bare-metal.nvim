# Config-load audit: is the distro overloaded at runtime?

Branch: `perf/tui-latency` @ `fb2fc7d` · Date: 2026-09-28 · **Read-only investigation — no config edits, no commits**

Question put to the audit: *"Is the config overloaded? Write a BIG report on what can be
simplified or thrown out. Priority is RUNTIME performance, several times higher than their code."*

**Headline answer: no. The config is not overloaded.** 11 of 26 plugins never load at all,
the 9 catalog entries are not even installed, and the measured warm-path costs are
sub-millisecond to low-millisecond. The audit did find **one real defect** — a 21 MB plugin
(`nvim-treesitter`) that is vendored broken and has never once loaded — but that is a *bug*,
not bloat, and "remove it" is the wrong fix. Details in §2 and §4.

---

## 0. Method, and the traps this audit had to avoid

Everything below was measured on a **live UI** through a real PTY (`tui-test run nvim -u
~/.config/nvim/init.lua -i NONE <file>`), never `--headless`, because `defer_enabled()`
(`lua/distro/loader.lua:196-215`) requires `#nvim_list_uis() > 0` and the whole deferral
machinery is inert without it. No `+qa!` counts are quoted, `--startuptime` was not used,
and no verdict rests on a grep for a plugin's name in Lua sources.

Probes are the house in-process pattern: a Lua file loaded with `--cmd luafile`, recording
to append-only JSONL on one `vim.uv.hrtime()` clock, one file per run, never overwriting.
All probe files and their raw output live in `~/.cache/nvim-overload-audit/`.

Three measurement mistakes were made and corrected during the audit; they are recorded
because each would have produced a false headline:

1. **Module attribution via `debug.getinfo` is worthless for this question.** For a module
   that is a *table* — almost all of them — `debug.getinfo(mod,"S")` returns no source file.
   First attempt put 283 of 287 modules in an `UNKNOWN` bucket. Replaced with an
   authoritative method: enumerate each plugin's own `lua/**/*.lua`, derive the module name
   it *would* provide, and test membership in `package.loaded`. That is a fact about module
   identity, not an inference from a code reference.
2. **`jjkk` nets to zero cursor movement.** An early "did my keypresses land?" check read
   cursor `[1,0]` and looked like proof the keystrokes never arrived. They had — `jjkk` moves
   down two and back up two. Any test that infers input delivery from a net-zero key sequence
   is unsound. All later runs use `jjj` (net +3) and assert cursor `[4,0]`.
3. **`CursorHold` fires once per input-idle cycle, and no-input probes never trigger it.**
   A timer-driven probe produces *zero* user input, so the idle-drain path is never
   exercised. This is the single most important methodological point in this report: a
   "settled session" measured without any input is not the session a user works in. §1.2
   gives both states.

---

## 1. The actual inventory

### 1.1 Configured surface (how each count was obtained)

| class | count | how obtained |
|---|---|---|
| plugins `kind=start` | 2 | `lua/distro/manifest.lua` → `M.plugins`, read directly |
| plugins `kind=opt` | 24 | same |
| tools (`M.tools`) | 6 | `curl, tar, rg, gcc, make, go` |
| language servers / linters (`M.binaries`) | 9 | `gopls, dlv, staticcheck, lua-language-server, stylua, shfmt, golangci-lint, bashls, marksman` |
| catalog (`M.catalog`) | 9 | on-demand only, **not loaded, not installed** |
| vendored on disk (`pack/distro/opt`) | 24 dirs | `ls pack/distro/opt` |

Catalog is **not** plugins and is **not** installed: all 9 entries report `present=False`
and load 0 modules. They cost nothing at runtime. This is where the "26 plugins vs 50
entries" contradiction comes from — they are different things.

### 1.2 Two real "settled" states (live UI, `uis=1`, Go buffer)

| state | modules | autocmds | rtp | plugins loaded | evidence |
|---|---|---|---|---|---|
| no user input (timer-driven probe) | 287 | 288 | 25 | 14 | `probe_recon.lua` → `out/recon.jsonl`, tag `noidle_3000` |
| after first `CursorHold` (**the working state**) | **294** | **293** | **26** | **15** | same file, tag `noidle_7000` / `postkey_11000` |

The first `CursorHold` (triggered by real `jjj` input) loads `flash.nvim`: **+7 modules,
+5 autocmds, +1 rtp**. This exactly reconciles the baseline quoted in the brief
(288 modules / 293 autocmds) with the no-input state — the difference is `flash.nvim`, and
nothing else. `probe_events.lua` shows `CursorHold` firing exactly **once** across a 22 s
run with a single keypress, with `updatetime=1000`; it re-arms only on new input.

**180 of the 288 no-input modules are owned by vendored plugins** (glob attribution). The
rest are Neovim builtins and this config's own ~4 `OWN_CONFIG` modules.

### 1.3 Per-plugin module ownership (no-input settled state)

Loaded-count is "modules of this plugin present in `package.loaded`", from
`probe_modules.lua` → `out/modules.jsonl`.

| plugin | kind | loaded/total | note |
|---|---|---|---|
| LuaSnip | opt | 60/82 | largest single consumer; snippet engine behind cmp |
| nvim-cmp | opt | 39/56 | loaded by the VimEnter+300 ms idle preload |
| black-metal-theme-neovim | start | 25/62 | eager |
| gitsigns.nvim | opt | 23/61 | BufReadPost |
| go.nvim | opt | 15/96 | FileType go |
| nvim-web-devicons | start | 8/15 | eager |
| cmp-buffer | opt | 4/4 | |
| cmp-nvim-lsp | opt | 2/2 | |
| cmp_luasnip / cmp-path / cmp-cmdline | opt | 1/1 each | |
| nvim-treesitter-textobjects | opt | 1/8 | **1 module only — see §2** |
| nvim-lspconfig | opt | 0/439 | **but a gopls client IS attached** — implicit pull-in |
| friendly-snippets | opt | 0/0 | data-only (snippets), has no `lua/` tree |
| guihua.lua | opt | 0/58 | on rtp via go.nvim dep, 0 modules |
| nvim-treesitter | opt | 0/20 | **never loads — see §2** |
| flash.nvim | opt | 0/22 | loads on first CursorHold |
| mini.nvim | opt | 0/47 | loads on first picker use |
| plenary / diffview / trouble | opt | 0/80, 0/76, 0/35 | command-triggered |
| nvim-lint | opt | 0/190 | `:Lint` only |
| nvim-dap / -go / -ui / nio | opt | 0/17, 0/2, 0/32, 0/14 | `:Dap*` only |

**11 of 26 plugins never load in an ordinary Go working session.** That is the deferral
machinery working, not failing.

### 1.4 Toolchain (trap A — verified, not grepped)

`command -v` on the live host:

present: `cc`, `gcc`, `rg`, `go`, `gopls`, `tar`, `curl`, `make`, `staticcheck`, `dlv`,
`lua-language-server`.
**missing: `stylua`, `shfmt`** — declared in `M.binaries` as installable, not installed.

None of these are dead weight and none may be recommended for removal:

- `cc`/`gcc` — required to build Treesitter parsers (`build="treesitter"`, `needs={bins={"cc"}}`).
- `rg` — the external-package `gd` fallback greps with ripgrep; this is the fix landed today.
- `go` — `go list` resolves an import path to a real directory in the qualified-symbol `gd` path.
- `gopls` — the Go language server; **a gopls client is attached in every measured session.**
- `tar`/`curl` — the vendoring/extraction pipeline for installs.

A grep-based "no Lua file references `dlv`" test marks `dlv`, `tar`, `staticcheck` dead
because binaries have no Lua surface. That test is worthless and this report does not use it.

### 1.5 Disk footprint

`du -sm pack/distro` → **48 MB total**, of which `opt/nvim-treesitter` is **21 MB**
(14 MB parsers, 5 MB queries, 2 MB tests). `pack/distro/parser` is **empty (0 B)** — the
parsers were installed inside the plugin directory instead. All 21 parsers sit unused
(§2).

---

## 2. The one real defect: `nvim-treesitter` has never loaded

This is the finding worth acting on, and it is **not** a performance problem — it is a
vendoring bug that silently disables a configured feature.

### 2.1 Measured state (live UI, real input, Go buffer)

From `probe_ts.lua` → `out/ts.jsonl`, after confirmed real input (cursor `[4,0]`), stable
from t=3 s to t=21 s:

```
ts_mod_loaded=False   ts_rtp=False   hl_count=0   lang=False
foldmethod=manual     foldexpr_fn=False   syntax=go
```

And from `probe_events.lua`, `flash.nvim` **does** load off that same `CursorHold` — so the
event trigger and the loader are both working. Treesitter specifically is skipped.

### 2.2 Root cause (measured, not inferred)

`loader.load("nvim-treesitter")` returns **`False`** when called explicitly
(`probe_root2.lua` → `out/root2.jsonl`, `load_result`). Replicating the loader's steps
(`probe_why.lua` → `out/why.jsonl`) isolates it:

```
packadd_textobj_ok  False   E5108 … nvim-treesitter-textobjects.vim, line 3
packadd_ts_ok       True
loader_after        False
```

`pack/distro/opt/nvim-treesitter-textobjects/plugin/nvim-treesitter-textobjects.vim`:

```vim
lua << EOF
require "nvim-treesitter-textobjects".init()
EOF
```

The vendored textobjects is the **new** layout — `lua/nvim-treesitter-textobjects.lua` plus
`lua/nvim-treesitter/textobjects/{select,move,swap,attach,shared,repeatable_move,lsp_interop}.lua`
(11 lua files) — and has **no `.init()` module**. The shim calls a removed entry point, so
`packadd` dies with E5108.

The manifest declares it as a dep (`deps = { "nvim-treesitter-textobjects" }`). In
`pack_subtree` (`lua/distro/loader.lua:70-115`) a failed dep sets `ok = false` and returns
before `packadd nvim-treesitter` ever runs. The parent load therefore returns false, the
failure is swallowed, and `:messages` is **empty** — nothing is ever reported to the user.

### 2.3 What the user is silently losing

Everything `lua/modules/configs/editor/treesitter.lua` configures:

- **No Treesitter highlighting.** Colour comes from the classic `syntax=go` path instead.
- **No Treesitter folds.** `foldmethod` stays `manual`, `foldexpr` stays `0`, and
  `nvim_treesitter#foldexpr()` does not exist, so `zx` cannot fold.
- **No textobjects** — the configured `af` / `if` / `ac` / `ic` keymaps never register.
- **No motion keymaps** — `][` `]m` `]]` `]M` `[[` `[m` `[]` `[ [` never register.
- **No Treesitter indent.**
- **21 MB and 21 compiled parsers on disk, loaded never.**

This is why "is it overloaded?" has an unusual answer here: the heaviest single component
contributes **0 ms** to every runtime frame, because it never runs.

### 2.4 Secondary latent issue (separate from the root cause)

`require("user.configs.treesitter")` fails — **`lua/user/` does not exist at all**
(`probe_diag.lua` → `out/diag.jsonl`, `user_cfg_ok=False`; `find lua/user` → no such
directory). In `load_plugin` (`lua/modules/utils/init.lua:404+`) a failed user-config
require falls through to *"Nothing provided… Fallback as default setup of the plugin"*, so
this is **not** fatal and not the treesitter root cause (the dep packadd fails first). Its
consequence is narrower: any user override file for a `load_plugin`-managed config is
silently ignored and the built-in defaults are used instead. Whether that silently drops
user settings for *other* plugins is **not established** — see §5.

---

## 3. Runtime hot spots, ranked (live-UI measurements)

Measured with the config's own instrumentation (`:DistroTrace` → `distro-trace` log), which
breaks `gd` into `keypress_to_request` / `request_to_response` / `response_to_cursor` with
`own_ms` per phase. Trace file `distro-trace-186531539208.log`.

| # | hot spot | measured | verdict |
|---|---|---|---|
| 1 | **First `gd` keypress** (cold) | **≈42.5 ms** synchronous: `loader:load/flash.nvim` 17.144 + `loader:load/mini.nvim` 7.711 + `picker:ensure` 8.003 + gd dispatch 9.642 | one-time, real. Two plugins and the picker are pulled in *on the keypress itself* |
| 2 | Warm `gd` (5 samples) | 2.412 / 1.571 / 0.803 / 1.775 / 1.434 ms — **median 1.571, max 2.412** | fine; not a hot spot |
| 3 | `gd` request→response (warm) | own 0.598–1.715 ms | gopls round-trip, irreducible |
| 4 | Treesitter | **never loads → 0 ms** | not a cost; a missing feature (§2) |

Cold/warm split for `gd` is the whole story: the mechanism is `defer_idle`, and it works.
The 42.5 ms first-press figure is the price of *deferred* loading being paid at the moment
of first use rather than at startup.

### Already fixed today (cited, not re-derived)

Per the brief these are closed; they are listed with their fix commits and are **not**
re-proposed as open findings:

- **H3 watchdog** — `b9b057e` — the VimEnter+300 ms drain no longer flushes `pending` in one
  blocking spike; it is sliced one entry per event-loop tick.
- **`gd` external-package fallback** — `92635b4`, `6faaac5` — goes straight to `rg` for Go
  external packages instead of queueing behind gopls; quickfix made useful, not just fast.
- **`organizeImports` burst** — `985e20b` — coalesced so rapid saves stop queueing gopls.

---

## 4. Concrete removal list, ordered by benefit / risk

The honest finding: **there is almost nothing safe to remove.** The config is already
aggressively lazy. What follows is ranked, with the user-visible consequence stated for each,
as required.

### 4.1 Top candidates

| # | item | benefit | risk | what the user loses | verified how |
|---|---|---|---|---|---|
| 1 | **Fix `nvim-treesitter` vendoring** (re-vendor textobjects against the new API, or drop its stale `plugin/*.vim` shim) | restores highlighting, folds, 8 textobject/motion keymaps, Treesitter indent; makes 21 MB of parsers actually usable | **medium** — enabling a feature that has never run will change every buffer's rendering and will *add* real runtime cost that does not exist today | nothing, if fixed correctly | `probe_why.lua` isolates the failing `packadd`; `probe_ts.lua` shows the current dead state |
| 2 | Delete the **21 MB** `nvim-treesitter` tree as-is | −21 MB disk | **low runtime / high functional** | the *appearance* of Treesitter. It already does nothing, so no runtime regression — but this **discards the intent** of a configured feature and should be an explicit owner decision, not a cleanup | `du -sm`; `ts_mod_loaded=False` across 21 s of live input |
| 3 | `stylua`, `shfmt` in `M.binaries` | none while absent | none | they are already not installed; leaving them declared is a menu affordance, not bloat | `command -v` → both MISSING |
| 4 | The 9 `M.catalog` entries | none | none | **nothing** — verified `present=False`, 0 modules for all 9 | `probe_modules.lua` catalog rows |

**Recommendation: do item 1, not item 2.** Item 2 is the "simplify" move that looks right on
a disk-usage chart and is wrong on the merits — it would delete a feature the owner
configured, on the strength of a bug they did not know about.

### 4.2 Explicitly NOT recommended for removal

| item | why not |
|---|---|
| `nvim-lspconfig` | Loads **0/439** of its own modules yet a **gopls client is attached** in every measured session. The implicit pull-in is the classic trap: a removal recommendation here would break the Go language server outright. |
| `cc`/`gcc` | Builds the Treesitter parsers. No parsers, no Treesitter, once item 1 is fixed. |
| `rg` | The external-package `gd` fallback — the fix landed today. |
| `go`, `gopls` | Language server and `go list` import resolution; gopls client verified attached. |
| `LuaSnip` (60 modules) | Largest module consumer, but it is the snippet engine behind `nvim-cmp`; removal deletes completions. |
| `friendly-snippets` (0/0) | Looks dead because it ships no `lua/` tree — it is snippet *data*. |
| `guihua.lua` (0/58) | On rtp as a `go.nvim` dep; loaded on demand by go.nvim. |
| `nvim-dap` + 3 deps, `nvim-lint`, `diffview`, `trouble`, `plenary` | All command-triggered, all 0 modules when unused. Verified 0 cost. |
| `mini.nvim`, `flash.nvim` | 0 modules until first use, then ~25 ms once. This is correct deferral, not bloat. |

### 4.3 The only genuine simplification available

If the owner wants fewer moving parts, the honest lever is **not** deleting lazy plugins —
it is that `flash.nvim` costs 17.1 ms and `mini.nvim` 7.7 ms **on the first `gd` keypress**
(§3, #1). Those two loads are the only measured first-use spike. Warming them at idle
instead would move 25 ms off the first `gd`; that is a tuning change with a real trade-off,
and it is out of scope for a read-only audit.

---

## 5. Not proven / open questions

Named explicitly, per the brief.

1. **Was Treesitter ever working on this branch?** The failure is a version skew between the
   vendored `nvim-treesitter-textobjects` (new API) and its own `plugin/*.vim` shim (old
   `.init()` call). `pack/distro/opt/nvim-treesitter-textobjects/.distro-ok` is dated
   `2026-09-24T14:16:05Z`. Whether the shim matched at install time, or was always broken, is
   **not established**. Not investigated: no network, and the install path was out of scope.
2. **Do other `load_plugin` configs silently lose user settings?** `lua/user/` does not
   exist, so `require("user.configs.<name>")` fails for every `load_plugin` caller and falls
   back to defaults. gitsigns/cmp/go.nvim load and work, so the fallback path is at least
   not fatal — but whether a *deliberate* user override would be silently dropped for any
   config besides treesitter is **not measured**.
3. **Per-plugin cost in ms.** Module counts are measured; **per-plugin millisecond cost is
   not**, except for `flash.nvim` (17.144), `mini.nvim` (7.711) and the `gd` chain, which
   the built-in trace instruments. Ranking 24 plugins by ms would require wrapping every
   loader span; the trace already emits `loader:pack/*` / `loader:finish/*` and could do it,
   but that was not run to completion.
4. **The external-package `gd` path (brief: ~125 ms) was not re-measured here.** The 42.5 ms
   and 1.571 ms figures are the *local/undiscovered-target* path. My cursor sat on a symbol
   with no target, so warm `gd` figures measure **path overhead, not a successful jump** —
   they are a floor, not a representative latency. The 125 ms figure is the coordinator's
   and is neither confirmed nor contradicted.
5. **File-open / redraw cost was not measured.** The brief marks this out of scope and
   supplies its own numbers (p50 0.71 ms live). The trace module does not instrument
   `BufReadPost`, so I could not have produced a comparable figure without new instrumentation.
6. **Whether `pack/distro/parser` being empty is itself a defect.** The 21 parsers live in
   the plugin's own `parser/` dir instead. `distro.treesitter.missing_langs()` scans *both*
   directories, so it is consistent — but if the plugin is ever removed, the parsers go with
   it. Consequence unverified.
7. **Windows/Linux behaviour.** All measurements are macOS arm64, nvim 0.12.5, one host,
   warm page cache. The 20+ toolchain binaries were checked on this host only.
8. **Working tree was not clean.** The brief stated a clean tree at `fb2fc7d`. `git status`
   showed `?? scripts/tui-latency-bench.lua` (untracked, 16 305 bytes, dated 2026-09-28
   22:07). It was **left untouched** — not deleted, not committed, not staged. Flagged here
   because it contradicts the stated precondition and whoever commits next should decide
   its fate deliberately.

---

## 6. Evidence index

| file | purpose |
|---|---|
| `probe_inventory.lua` → `out/inventory.jsonl` | 3-point settle curve; proved settle by t=4 s |
| `probe_modules.lua` → `out/modules.jsonl` | authoritative glob-based per-plugin module attribution |
| `probe_events.lua` → `out/events.jsonl` | `CursorHold` fires exactly once; updatetime=1000 |
| `probe_ts.lua` → `out/ts.jsonl` | treesitter dead state, 3 s→21 s under real input |
| `probe_why.lua` → `out/why.jsonl` | isolates the failing `packadd` (E5108) |
| `probe_err.lua` → `out/err.jsonl` | full require error, confirms no `.init` module |
| `probe_root2.lua` → `out/root2.jsonl` | `loader.load("nvim-treesitter")` returns `False` |
| `probe_recon.lua` → `out/recon.jsonl` | no-input vs post-`CursorHold` reconciliation |
| `probe_diag.lua` → `out/diag.jsonl` | `:messages` empty; `user.configs.*` missing |
| `distro-trace-186531539208.log` | gd cold 42.5 ms / warm median 1.571 ms |

All raw output under `~/.cache/nvim-overload-audit/`. No file outside that cache directory
and this one report was created or modified.
