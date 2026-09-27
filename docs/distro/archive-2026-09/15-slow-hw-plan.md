# 15 — Slow-HW / HDD plan: runtime latency audit and ranked optimization ideas

Profile: **very weak PC, no SSD (HDD / network profile / Windows)**. Goal: fast runtime,
responsiveness, render speed.
Repo `/Users/16prom1/.config/nvim`, nvim 0.11.4, measured on macOS 26.3 arm64 (SSD, warm cache).
Date 2026-09-27. **Config not modified** — `git status` unchanged apart from pre-existing
uncommitted `lua/core/settings.lua`, `lua/modules/configs/completion/lsp.lua`, and the docs
I was asked to produce. No commits.

Read (not re-opened for analysis): `docs/distro/12`, `13`, `14`.

---

## 0. Calibration (printed, because every number below depends on it)

**Tool:** `/tmp/hd/pty_latency.py` — `pty.openpty()` + `subprocess.Popen` with the pty as
stdin/stdout/stderr, 50×200 window, `TERM=xterm-256color`. The parent drains the master so the
child never blocks. For each key: `t0` = write of the key byte; then read until the stream is
quiet for 120ms; latency = `t1 - t0` where `t1` is the last byte before the quiet gap. That is
"key pressed → last byte of the resulting frame".

Two calibration arms, run **before** any config number:

| arm | n | min | median | p90 | max | stddev |
|---|---|---|---|---|---|---|
| `synth-floor` — synthetic responder, no editor at all | 64 | 0.030 | **0.151** | 0.241 | 2.883 | 0.366 |
| `clean-none` — `nvim -i NONE -u NONE` | 64 | 0.296 | **0.707** | 1.175 | 1.969 | 0.369 |

**Calibration result: the harness floor is 0.151ms.** Every keystroke figure below is that plus
real work. Noise: `clean-none` stddev 0.369ms, so a difference under ~0.5ms is not resolvable
with this harness. I state this rather than hiding it.

The FS-counting hook (`/tmp/hd/fshook.lua`, wraps `uv.fs_*` + `vim.fn.executable`) was also
calibrated against a no-hook control, because instrumenting by wrapping adds cost:

| arm | n | min | median | max |
|---|---|---|---|---|
| control (no hook) | 12 | 31.4 | 33.7 | 50.4 |
| hooked | 12 | 30.2 | 32.3 | 35.6 |

**Hook overhead: 0 (within noise, hooked was if anything faster).** The wrapped-call counts are
therefore trustworthy as counts.

---

## (A) HDD / IO map

### A.1 The premise "4745 files in pack/ are each stat'd at startup" is FALSE

Measured with `--startuptime`:

```
$ nvim --headless --startuptime /tmp/hd/st.log -i NONE -u init.lua +qa
startuptime lines: 124
sourced files from pack/distro: 4
   3 start/black-metal-theme-neovim
   1 start/nvim-web-devicons
```

**Four files are sourced from `pack/` at startup.** The other 4741 files in 48MB of `pack/` are
never opened. `distro.loader` is lazy (`packadd` per plugin on its event) and the two eager
`kind=start` plugins are tiny. `pack/distro/opt/*` is not on the rtp glob for startup.

**Win: nothing to win here.** The "48MB / 4745 files" framing is a false alarm for startup.
It is *not* a false alarm for the **first open of a file**, see A.2.

### A.2 Sync FS syscalls — measured, per phase

Same hook, counting the whole run:

**Startup (to `+qa`):**
```
fs_stat 4   fs_realpath 1   isdirectory 1   executable 3
FS_TOTAL 5
executable args: pbcopy 1, pbpaste 1, rg 1
first caller fs_stat    -> lua/distro/loader.lua:137
first caller fs_realpath -> lua/core/global.lua:18
```

**`:edit <file>` path (16KB Go file), delta after the edit:**
```
fs_stat 37   fs_realpath 1   fs_lstat 1   executable 15
```

**Interpretation.** Startup is 5 syscalls — there is no sync-IO tax at startup, on SSD or HDD.
The real IO is on **file open: 37 `fs_stat` + 15 `executable()`**. On an HDD at ~0.1ms per
metadata op versus ~1µs on SSD, 37 stats ≈ **3.7ms**, and 15 `executable()` calls (each a
`$PATH` scan, each touching every `$PATH` directory) can be **10–100ms on Windows** with a long
`%PATH%` and Defender hooks on `CreateFile`. This is the most HDD-relevant number in the audit.

**File:line.** `lua/core/init.lua:50-117` (`clipboard_config`, the `executable()` probes),
`lua/core/options.lua:32` (`rg` probe for `grepprg`), `lua/distro/loader.lua:137` (presence
`fs_stat` per manifest entry), `lua/core/global.lua:18` (`fs_realpath` for `vim_path`).

**What each startup stat checks and whether it can be deferred:**

| probe | what it checks | deferrable? |
|---|---|---|
| `fs_realpath` (global.lua:18) | realpath of the config dir, once | No — needed for every path later. 1 op. |
| `fs_stat` ×4 (loader.lua:137) | presence of eager `kind=start` entries | No — that IS the boot. 4 ops. |
| `isdirectory` (core/init.lua:13) | cache dir existence | No. 1 op. |
| `executable` ×3 | pbcopy/pbpaste (macOS clipboard), `rg` (grepprg) | **Yes — cacheable**, see E-2. |

### A.3 `executable()` — the 35 calls in source, 18 executed

35 call sites in `lua/`; **3 execute at startup, 15 on the `:edit` path, 0 elsewhere in a
plain txt/Go session**. The `:edit`-path 15 are almost certainly the loader probing plugin
prerequisites. On Windows each is a `$PATH` scan; 15 of them on every file open is the concrete
"Windows consumers feel it slower" mechanism.

### A.4 Where the config writes — network path risk

- Lock file: `lua/distro/lock.lua:5` → `vim.fn.stdpath("config") .. "/distro-lock.json"` —
  **inside the config repo**. On a network/redirected `%USERPROFILE%` this is a network write,
  but only on `:DistroUpdate`/`:DistroInstall`, never at startup.
- Staging: `lua/distro/install.lua` `tmpdir()` → `stdpath("cache")` — correct, not the config dir.
- `fs_fsync`: exactly one, `lua/distro/lock.lua:60`, on lock write only.
- Trace: `lua/distro/trace.lua` → `stdpath("cache")/distro-trace/`, `M.enabled = false` by default.
- Shada: not disabled by the config; the bench harness passes `-i NONE` to keep runs
  deterministic, but **a real consumer session does write shada on `VimLeave`**
  (`lua/core/event.lua` `VimLeave` → `wshada`). On a network profile that is a network write
  at exit. Small, one file.

**No fsync, no lock write, no state file on the startup or file-open path.** Confirmed by the
hook: `fs_fsync 0, fs_open 0, fs_write 0, fs_rename 0, fs_mkdir 0` in the whole startup run.

---

## (B) Render thread

### B.1 Keystroke → frame, measured in a real pty (the release metric)

| arm | file | n | min | median | p90 | max | stddev |
|---|---|---|---|---|---|---|---|
| `clean-none` (floor) | txt | 64 | 0.296 | 0.707 | 1.175 | 1.969 | 0.369 |
| `clean-go` (floor) | sample.go | 80 | 0.410 | 0.849 | 1.496 | 6.698 | 0.798 |
| **`ours-default`** | txt | 80 | 0.207 | **1.987** | **4.266** | 10.800 | 1.752 |
| `ours-turbo` | txt | 80 | 0.392 | 2.061 | 3.268 | 7.515 | 1.227 |
| `ours-weakhw` | txt | 80 | 0.396 | 2.021 | 3.403 | 12.486 | 1.581 |
| `ours-256` (`notermguicolors`) | txt | 80 | 0.216 | **1.583** | 3.039 | 8.702 | 1.375 |
| `ours-early06` (keys at t>0.6s) | sample.go | 80 | 0.651 | 2.639 | **7.288** | **23.291** | 3.895 |
| `ours-settled6s` (keys at t>6s) | sample.go | 80 | 0.205 | 2.419 | 4.079 | 8.608 | 1.604 |

**This is the owner's reported symptom, measured.** Per keypress, this config costs
**+1.28ms median** over `nvim -u NONE` (1.987 vs 0.707) and **+3.09ms at p90** (4.266 vs 1.175).

Three findings that change the plan:

1. **The gap does not heal with time.** `ours-early06` (t>0.6s) median 2.639ms vs
   `ours-settled6s` (t>6s) median 2.419ms. Waiting for deferred work to finish removes ~0.2ms of
   median. **The cost is a persistent per-key price, not settling debt.** That kills the
   "just wait for idle" family of fixes.
2. **The first seconds carry a real hitch tail**: p90 7.288ms and **max 23.291ms** while deferred
   work (198→327 modules) is still landing, versus p90 4.079ms settled. On a weak PC, 23ms is
   the visible "stutter".
3. **`notermguicolors` is worth 0.404ms median** (1.583 vs 1.987) on a 44-line ASCII file. On a
   real file with colour, and on a Windows console emitting truecolor ANSI per cell, the true
   win is larger — but on *this* file the measured effect is 0.4ms, i.e. **below the owner's 2ms
   bar**. I am not selling it as a win; see E-4.

### B.2 CursorHold fan-out

Measured autocmd registrations per event in a live pty session:

```
CursorHold 3   CursorHoldI 2   InsertLeave 2   BufEnter 6   BufReadPost 6
VimEnter 5     WinEnter 2     FocusGained 2   InsertEnter 2  TextChanged 1
```

With `updatetime = 1000` (`lua/core/options.lua:81`), an idle cursor fires **3 CursorHold + 2
CursorHoldI callbacks per second**, i.e. up to **5 × 60 = 300 callback invocations per minute**
of doing nothing. The three CursorHold handlers are
`lua/distro/loader.lua:347` (deferred-load drain), `flash.nvim` (`lua/distro/manifest.lua:44`),
and `which-key.nvim` (`lua/distro/manifest.lua:89`); the gitsigns turbo attach
(`lua/modules/configs/ui/gitsigns.lua:43`) also lists CursorHold/CursorHoldI.

Once a plugin is loaded these are cheap no-ops, so the cost is concentrated in the first
minutes — consistent with B.1's early tail. **I did not measure per-invocation cost of an idle
CursorHold round** (would need a synthetic idle pty run); flagged as NOT MEASURED, but the
replacement (idle timers) is cheap and risk-free.

### B.3 Highlight groups

767 groups defined after a Go open (measured, `nvim_get_hl(0,{})`). Scanning the table is
0.117ms, so the count is not itself the cost — the cost is re-emitting 767 attribute
definitions to the terminal on repaint. **Not measurable on macOS without a real terminal
paint**; NOT MEASURED as a latency figure.

---

## (C) Hotkey → screen response

From B.1: median +1.28ms, p90 +3.09ms over stock. What sits on that path:

| item | sync? | file:line |
|---|---|---|
| gitsigns attach | **synchronous on the default profile** — `auto_attach = not turbo_defer`; turbo is off by default | `lua/modules/configs/ui/gitsigns.lua:22` |
| statusline eval | every redraw; `_G._statusline` from `keymap/statusline.lua`, no `vim.defer_fn` | `lua/keymap/statusline.lua:1` |
| BufEnter handlers | 6 registered; cursorline toggles + statusline | `lua/core/event.lua` `_wins` group |
| CursorHold | 3+2 per second at `updatetime=1000` | B.2 |
| `vim.wait` in config | **none** — `grep -rn 'vim\.wait(' lua` → 0 matches | — |
| plenary / job join | **none** — plenary never required from `lua/` | — |
| mason | **none** — by design, binaries are system-wide | `lua/core/settings.lua:171` |
| update checks at startup | **none** — no lazy.nvim at all; `:TSUpdate` does not exist (E492) | `lua/distro/treesitter.lua` |

So the response path is clean of blocking calls; the cost is *volume* (autocmds, hl groups,
statusline) rather than a hidden `vim.wait`.

---

## (D) The 220-module delta — what actually loads

Module census in a real pty on `sample.go` (`/tmp/hd/census.lua`):

```
first-frame  t=  52ms  modules=198
t500         t= 500ms  modules=319
t1500        t=1500ms  modules=327
t5000        t=5001ms  modules=327
final        t=6001ms  modules=327
```

**+129 modules land after the first frame** (198 → 327, converged by ~1.5s). The prior stage's
"302 → 220" is the same phenomenon with different counting; mine is a direct
`package.loaded` count at t=52ms vs t=6001ms. By module family:

| family | count | why it loads |
|---|---|---|
| `cmp.*` | ~38 | completion engine, loaded on first InsertEnter |
| `luasnip.*` (+ jsregexp, lpeg) | ~50 | snippet engine pulled in by cmp |
| `dapui.*` + `dap.*` + `dap-go` + `go.*` + `lint` | ~60 | **debugger and linter load on a plain Go open, before any DAP/lint command** |
| `gitsigns.*` | ~27 | git signs |
| `flash.*` | 5 | CursorHold |
| `nio.*` | 16 | async helper (pulled by go.nvim / treesitter-textobjects) |

**The actionable part: `dapui`, `dap`, `dap-go`, `go.*` and `lint` are in the after-first-frame
set on a file that is merely opened.** That is ~60 modules of debugger+linter UI that a user
may never invoke. `lua/modules/configs/lang/dap.lua:1` even says in its own header
"ТЕСТ (не коммитить итог без ок)" — it is a test file that shipped.

---

## (E) Ranked ideas (never propose <2ms on HDD; say so when there is no measurable win)

Ordered by expected effect for the stated goal. "Confidence" = how sure I am the effect is real.

### E-1. Make `nvim-dap` / `dapui` / `dap-go` / `go.nvim` / `lint` demand-loaded — **~60 modules, one-time**
**Effect:** removes ~60 modules and their parsing from the post-first-frame window. On macOS I
measure the first-frame→settle window shrinking; the p90/max tail (7.288 / 23.291ms) is where
this lands, because the tail is *deferred work landing while the user types*. Expected p90
improvement: **order of 1–3ms on SSD, larger on a weak CPU** (module require is CPU-bound, so
it scales with CPU, not disk). **Risk:** low — these are only needed on `:DapContinue`/lint
commands; make them `event = { "User DapContinue", ... }` or a `cmd` trigger. **Rollback:**
delete the event from `lua/distro/manifest.lua`; loader is table-driven, no code change.
**Implementation cost:** small (manifest-only). **Confidence: HIGH** that modules disappear;
**MEDIUM** on the ms figure, since I cannot measure a weak CPU.

### E-2. Cache `executable()` results per session, with an honest invalidation — **0–2ms on SSD, 10–100ms on Windows**
**Effect:** 3 calls at startup, 15 on the file-open path. On SSD this is sub-ms. On Windows with
a long `%PATH%` + Defender it is the single biggest HDD/Windows IO item in this audit. **This is
the idea that matters *specifically for the target profile*, and it is worth ~0ms on my machine
— I say that plainly rather than inflating it.** **Risk:** medium — a cached "binary missing"
must not permanently hide a binary installed later in the session. Honest invalidation: cache
only *positive* results (a binary found once stays found for the session; the OS does not
uninstall things mid-session), and re-probe negatives once per N seconds. **Rollback:** one
`local function has(bin)` helper in `lua/core/global.lua`, delete to revert. **Cost:** tiny.
**Confidence: HIGH** on mechanism, **LOW** on magnitude (unmeasurable here).

### E-3. Drop the `go.nvim` + `gitsigns` double attach on open — **0.5–2ms, borderline**
`gitsigns.lua:22` attaches synchronously on the default profile while the turbo path
(`gitsigns.lua:43`) already defers it. **Measured effect on this machine: `ours-turbo` median
2.061ms vs `ours-default` 1.987ms — turbo is *not* faster here (difference 0.07ms, inside
noise).** So: **no measurable win**, do not ship this expecting a p90 improvement. Keeping it
as a documented "already tried, no effect" result is more useful than repeating the change.
**Confidence: HIGH that it does nothing measurable on this profile.**

### E-4. `notermguicolors` on the slow profile — **measured 0.404ms median, below bar**
Measured (B.1): 1.583 vs 1.987ms on a 44-line ASCII file. On a colourised real file and a
Windows console the emission cost scales with coloured cells, so the real number is plausibly
larger — but **I measured 0.4ms and will not claim more**. Worth exposing as a `weak_hw` toggle
with a `TERM=dumb/screen` auto-detect (the guard in `lua/core/term_guard.lua:29` already
exists for the broken-output case); do not make it the default. **Confidence: LOW-MEDIUM.**

### E-5. Replace the 5-per-second CursorHold drain with `vim.defer_fn`/idle timers — **0–1ms steady, removes the early tail**
**Effect:** steady-state cost is near zero once plugins are loaded (B.2 analysis), so the win is
in the first minutes, where B.1 shows p90 7.288ms / max 23.291ms. Replaces a 300-callback/min
idle tax with a bounded set of one-shot timers. **Risk:** medium — CursorHold-based laziness
also serves "user paused, safe to load now"; moving to timers must preserve the same
"never mid-keystroke" guarantee. **Rollback:** revert `lua/distro/loader.lua:347`.
**Confidence: MEDIUM** on mechanism, **LOW** on ms.

### E-6. HDD preset: a real `hdd` profile, not just `weak_hw` — **targeted at the actual profile**
`lua/core/weak_hw.lua` currently tunes turbo/gopls/theme/treesitter/debounce. An `hdd` profile
should add: cached `executable()` (E-2), deferred dap/lint (E-1), `notermguicolors` optional
(E-4), and `updatetime` left at 1000. **Risk:** low; it is additive to the existing preset
machinery. **Confidence: HIGH** that it is the right shape, **LOW** on the aggregate ms.

### E-7. Shada/state writes off the network path — **0ms locally, correctness on network profiles**
`VimLeave → wshada` writes to `stdpath("state")`; on a redirected profile that is a network
write at exit. One-shot, not a latency item, but it is a "consumer feels slow" moment. **Risk:**
low. **Confidence: HIGH** it matters on a network profile, **N/A** locally.

### Ideas explicitly NOT proposed
- Caching options/keymaps: prior stage measured the entire startup surface at 0.5–0.6ms. Below
  bar, and it is a maintenance trap. **No win.**
- Highlight-table caching: prior stage measured ~1.5ms and a regression risk on every theme
  change. Below bar on HDD. **No win.**
- Any change to the large-file guard (`lua/core/large_file.lua`, 10k lines / 1024KB): its own
  comment documents that lowering the threshold is a degradation. **Do not touch.**
- Cold-start "optimisation": cold start is not measurable here (no sudo) and the owner is
  asking for runtime, not startup.

---

## (F) Do NOT touch

- **`vim.schedule_wrap` on treesitter** (`lua/modules/configs/editor/treesitter.lua:1`).
  Already the correct design; unwrapping puts 4–19ms of parse back on `:edit`.
- **Large-file guard** (`lua/core/large_file.lua`; thresholds `lua/core/settings.lua:92,95`).
  Measured firing on a 22,735-line Go file. The 5000-line idea in its own comment is a
  degradation.
- **`updatetime = 1000`** (`lua/core/options.lua:81`). Above 500 most plugins misbehave
  (comment in-file). Already the conservative value.
- **Async `core/go.lua`** organize/format. The comment records a prior 4s UI freeze from the
  synchronous version. Do not regress it.
- **`core/term_guard.lua`** — idempotent, no-op on normal terminals, and deliberately does not
  force-disable truecolor under `tmux-256color` (documented product decision).
- **Pinned manifest refs** — frozen 2026-09-24; 0.93ms table, not worth re-resolving.
- **`cmp_defer_caps`** (uncommitted) — prior stage proved the claimed 78.4→14.9ms cannot exist
  (nvim-cmp is already deferred by the loader). My census confirms cmp loads after first frame
  regardless. Do not commit it expecting a win.

---

## (G) Language audit (owner-visible strings)

No Spanish, German, or other non-English UI copy found: the `notify`/`desc`/`error` string
extract is entirely English. **5 lines carry Cyrillic in user-visible strings** and should be
translated for a consumer release:

- `lua/core/weak_hw.lua:123` — `notify "[weak-hw] OFF — отложенная работа слита, настройки возвращены"`
- `lua/core/weak_hw.lua:143` — `desc "weak-hw: включить пресет слабого железа (будущие загрузки)"`
- `lua/core/weak_hw.lua:146` — `desc "weak-hw: выключить пресет + слить отложенное"`
- `lua/core/weak_hw.lua:150` — `desc "weak-hw: показать состояние (без побочных эффектов)"`
- `lua/core/pairs.lua:186` — `desc "pairs: показать статус встроенных автопар"`

(Russian *comments* elsewhere are fine — not user-visible.)

## (H) What I could NOT measure

1. **Any Windows or real-HDD number.** All figures are macOS SSD. Every HDD/Windows projection
   (E-2 especially) is inference, labelled.
2. **Cold cache.** No sudo; page cache cannot be dropped.
3. **Terminal paint cost of 767 highlight groups / truecolor ANSI.** Needs a real Windows
   console; B.1's `notermguicolors` delta (0.404ms) is the only render-side datapoint.
4. **Per-invocation cost of an idle CursorHold round.**
5. **Gopls attach, first LSP diagnostic** — measured in Phase 1 (~190ms), not re-measured here.
6. **The `:edit`-path 37 `fs_stat`s broken down by caller** — I counted them, not attributed
   each; A.2 attributes the startup ones only.

## (I) Method notes (reproducibility)

- pty latency harness: `/tmp/hd/pty_latency.py`; results appended to `/tmp/hd/pty.jsonl`
  (includes raw per-sample arrays).
- FS counter: `/tmp/hd/fshook.lua` (control-calibrated, overhead 0).
- Edit-path probe: `/tmp/hd/edit_probe.lua`.
- Module census (UI-attached): `/tmp/hd/census.lua` → `/tmp/hd/census.jsonl`.
- Corpus: `/tmp/rtbench/sample.go` (16KB, ~500 lines) and `/tmp/hd/small.txt` (44 lines).
- Keystrokes: `j,j,k,k,h,h,l,l` — guaranteed redraws; keys producing 0 bytes are discarded as
  non-samples (recorded in raw arrays so the count is auditable).
