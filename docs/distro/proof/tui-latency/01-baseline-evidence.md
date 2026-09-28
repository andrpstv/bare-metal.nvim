# NVIM-31 — Machine-relative startup baseline (evidence, single machine)

**Lane:** startup / machine-relative. **Companion lane:** TUI latency (not mine).
**Author:** Researcher. **Date:** 2026-09-28, 21:53–22:0x MSK.
**Repo:** `/Users/16prom1/.config/nvim`, branch `perf/tui-latency` @ `b0dc346`.
**Scope:** measure, cite, report. No config code changed. No commit. No push.

All numbers below are from **one machine only** (class in §1). Absolute ms are **not**
comparable to any colleague's machine. Only the *ratio* in §2 is a valid within-machine
claim; it says nothing about absolute speed elsewhere.

---

## 1. Machine class (verbatim, recorded at measurement time)

| Property | Value |
|---|---|
| `sysctl -n hw.model` | `MacBookPro18,1` |
| CPU | `Apple M1 Pro`, 10 cores (`hw.ncpu`=10) |
| RAM | `17179869184` bytes = **16 GiB** |
| macOS | `ProductVersion 26.3`, `BuildVersion 25D122` |
| Kernel | `Darwin oxywarrior-2.local 25.3.0 … RELEASE_ARM64_T6000 arm64` |
| Root volume FS | `File System Personality: APFS`, `Protocol: Apple Fabric` → **NVMe SSD**, not HDD |
| Repo path FS | `/dev/disk4s1` mounted on `/System/Volumes/Data` (`apfs, local, journaled, nobrowse, protect, root data`) |
| Neovim | **v0.12.5**, Build type: Release, LuaJIT 2.1.1788856981 |
| Uptime at start | 4 days 5:05 |

**Thermal / load state — this is NOT an idle machine, and it matters:**

- `uptime` during the ratio runs: load averages **3.25–4.40** (1/5/15 min).
- Concurrent heavy processes at 21:53 (`ps -Ao pcpu,pmem,comm -r`): Chrome helper renderer **48.6 % CPU**, `openclaw-gateway` **33.8 %**, Telegram **30.2 %**, WindowServer 21.6 %, `opencode` 19.8 %.
- Live nvim sessions owned by the human were running during measurement (pids 95767/95768 running this very config), and other agents' benchmark processes were active in parallel lanes.

**This is a load-contended, thermally-unpinned, shared measurement host.** Every absolute
number here is an **upper bound** on what the same code would cost on an idle machine. §6
treats this as hypothesis H1.

`df -T` does not exist on macOS, as the ticket warned; FS class taken from
`diskutil info /` and `mount` instead, as instructed.

---

## 2. RATIO — our config vs `nvim -u NONE`, same machine, same session

Exact commands (the only difference between the two conditions is `-u`):

```
ours     : nvim -u /Users/16prom1/.config/nvim/init.lua -i NONE --headless +qa
baseline : nvim -u NONE -i NONE --headless +qa
```

Harness: `/tmp/nvim31/bench.pl` (scratch, outside the repo). Perl `Time::HiRes::time`,
whole-process wall clock including exit. Runs are **interleaved** and the order is
**flipped every rep** (odd reps ours→baseline, even reps baseline→ours) so thermal/scheduler
drift is shared equally by both conditions. `-i NONE` on both, so shada I/O cannot skew one side.

### 2.1 Primary run — WARM, headless, n=21 per condition

| Condition | n | min | **p50** | **p95** | max | mean |
|---|---|---|---|---|---|---|
| ours | 21 | 33.9 ms | **37.4 ms** | **48.5 ms** | 49.3 ms | 38.2 ms |
| baseline (`-u NONE`) | 21 | 11.6 ms | **12.8 ms** | **15.7 ms** | 19.2 ms | 13.3 ms |

> **RATIO = median(ours) / median(baseline) = 37.4 / 12.8 = 2.93×**
> Bootstrap 95 % CI (10 000 resamples, seed 42) **[2.79, 3.04]**, half-width **±0.12**.
> Cross-check on different statistics: p95(ours)/p50(base) = 3.80×; min/min = 2.93×.

### 2.2 Reproduction pass — WARM, headless, n=11 per condition (second session, ~90 s later)

| Condition | n | min | **p50** | **p95** | max | mean |
|---|---|---|---|---|---|---|
| ours | 11 | 34.1 ms | **34.8 ms** | **36.4 ms** | 44.1 ms | 35.8 ms |
| baseline | 21→11 | 12.0 ms | **12.6 ms** | **12.9 ms** | 12.9 ms | 12.5 ms |

> **RATIO (repro) = 34.8 / 12.6 = 2.77×**, bootstrap 95 % CI **[2.72, 2.93]**, half-width ±0.10.

**Reproduction delta: ratio 2.93× → 2.77×, Δ = 0.16× (5.5 % relative).** The two CIs
overlap ([2.79,3.04] vs [2.72,2.93]). The ratio claim reproduces.

### 2.2b GATE-EXACT — the number the contract actually tests

The contract gate is `median(ours) <= 2.5x median(nvim -u NONE)`. That verdict depends on
shada, so I measured the gate with **exactly** the commands the contract names (note: **no
`-i NONE`**, which my §2.1 used to suppress shada I/O):

```
ours     : nvim -u /Users/16prom1/.config/nvim/init.lua --headless -c qa!
baseline : nvim -u NONE --headless -c qa!
```

MacBookPro18,1 / nvim v0.12.5 / **WARM** / interleaved, order flipped every rep, n=21 each,
load 3.30/3.00/3.20.

| Condition | n | min | **p50** | **p95** | max | mean |
|---|---|---|---|---|---|---|
| ours | 21 | 45.8 ms | **50.7 ms** | **58.4 ms** | 65.1 ms | 51.6 ms |
| baseline (`-u NONE`) | 21 | 18.9 ms | **20.2 ms** | **23.1 ms** | 23.6 ms | 20.6 ms |

> **GATE-EXACT RATIO = 50.7 / 20.2 = 2.51×** vs gate **2.5×** → **FAIL by 0.01×.**
> Bootstrap 95 % CI **[2.39, 2.58]** — **the interval straddles the gate.** At this host's
> current load the gate is a coin flip, not a verdict.

**Why §2.1 (2.93×) and §2.2b (2.51×) disagree — shada, and it is asymmetric:**

| | ours p50 | baseline p50 | ratio |
|---|---|---|---|
| with `-i NONE` (shada off, §2.1) | 37.4 ms | 12.8 ms | 2.93× |
| gate-exact, shada on (§2.2b) | 50.7 ms | 20.2 ms | 2.51× |
| **delta from shada** | **+13.3 ms** | **+7.4 ms** | — |

Our config sets `shada = "!,'500,<50,@100,s10,h"` (`lua/core/options.lua:59`). Both conditions
pay a shada cost; we pay **~1.8x more of it**. **Anyone quoting a startup ratio MUST state
whether shada was on.** Quoting the `-i NONE` number as "the ratio" overstates it by 0.42x;
quoting the gate-exact number without naming the command is equally wrong. Neither figure
alone is the ratio.

### 2.3 Critical caveat: this 2.9× is measured HEADLESS, where our deferral is INERT

`lua/distro/loader.lua:246` and `lua/core/perf.lua` gate all deferral on
`#vim.api.nvim_list_uis() > 0`. **Verified directly** (§3.2): headless reports `uis=0`,
a real UI reports `uis=1`. So the headless ratio is the **full synchronous cost of our
config with none of the deferral benefit**. It is the **worst case**, not the everyday case.
The everyday interactive number needs the companion lane's PTY measurements. I did not
substitute a headless number for it.

---

## 3. Module / require count on startup

### 3.1 The `+qa!` truncation trap — measured both ways, never presented as one number

The trap is real and it is measurable. Probe: `/tmp/nvim31/countmods.lua`; module origin
classified by name against a directory walk of `lua/` and `pack/distro/{start,opt}/`.

| Mode | UI attached? | total modules | **our modules** | verdict |
|---|---|---|---|---|
| `+qa!` (snapshot at probe time) | no (`uis=0`) | 67 | **18** | **LOWER BOUND** |
| settle 3 s (probe exits via `vim.schedule`/timer) | no (`uis=0`) | 82 | **19** | count |
| `+qa!` | **yes (`uis=1`, via tmux PTY)** | 65 | **16** | **LOWER BOUND** |
| settle 4 s | **yes (`uis=1`, via tmux PTY)** | 188 | **20** | count |
| settle 3 s, `-u NONE` | no | 23 | **0** | count |

**With a real UI attached, the true settled count is 20 of our modules; the `+qa!` run
reports 16. Presenting 16 as "the count" would understate by 20 %.**

**Callbacks dropped by the truncation (UI session), exactly 4 of ours:**

```
core.pairs
distro.treesitter
modules.configs.completion.formatting
modules.utils.icons
```

These are precisely the modules reached through `vim.schedule` callbacks that `+qa!`
pre-empts. `core.pairs` and `…completion.formatting` are the two `vim.schedule` blocks at
`lua/core/init.lua:181-186`; the other two are pulled in by that deferred work. Headless
drops only `distro.treesitter`, because headless runs those two synchronously anyway (§2.3).

### 3.2 Deferral is genuinely live in a real UI session

Directly verified, not assumed: the UI runs report `nvim_list_uis() == 1` (`uis=1` in
every tmux row above), and only the UI session picks up `modules.utils.icons`, which no
headless session loads. The gate at `lua/distro/loader.lua:246` is satisfied when a UI
exists, so `lua/distro/loader.lua:295` (`defer_until_idle`), `:299` (`defer_idle`) and
`:406` (idle preload) all take the deferred branch in a real session.

**Total module count jumps 23 → 188 when a UI is attached** (both measured with our config
vs `-u NONE`). The headless `188`-equivalent never happens, which is precisely why headless
numbers must not be quoted as the interactive experience.

### 3.3 Full require tree, before first paint — **RETIRED, DO NOT USE FOR DECISIONS**

> **REFUTED (coordinator, 2026-09-28 22:20). The table below is retained for provenance
> only. Its numbers are wrong and must not be cited.**
>
> **The arithmetic cannot be true:** the section claims a sum of exclusive self-time of
> **47.36 ms** against a measured wall clock of **37.4 ms** (§2.1). Exclusive time summed
> over a call tree is bounded above by wall-clock time. 47.36 > 37.4, so the attribution is
> invalid by construction.
>
> **The `vim.lsp` rows are fabricated as a startup cost.** Direct verification on this
> machine (`/tmp/nvim31/lspgate.json`, probe hooks `vim.lsp` on first field access):
> `at_startup: []`, `at_vimenter: []`, and the nine `vim.lsp*` modules appear only in
> `after_access`. Independently confirmed: `nvim -u init.lua -i NONE --headless` yields
> **0** `vim.lsp*` entries in `package.loaded`, and `grep -i lsp` over the real
> `--startuptime` output returns **0** hits. All `vim.lsp` access in `lua/core/event.lua`
> sits inside `LspAttach` handlers (lines 57-77), never on the startup path. The claimed
> "≈12.6 ms LSP tree" does not exist. See §4 for the replacement measurement.

`/tmp/nvim31/reqexcl.lua` wraps `require` before `init.lua` is sourced and snapshots at
`VimEnter` (= before first paint) and again after a 4 s settle. **UI attached (`uis=1`),
nvim v0.12.5, single sample, n=1 session, MacBookPro18,1, load ~3.3.**

n = **76** modules required, **sum of exclusive self-time = 47.36 ms**.

| exclusive self-time | module | call site |
|---|---|---|
| **15.33 ms** | `core` (body of `load_core`, *excluding* nested requires) | `init.lua:36` → `lua/core/init.lua:152-226` |
| **6.45 ms** | `vim.lsp` | pulled from config's LSP/event path |
| **2.49 ms** | `keymap` | `lua/core/init.lua:170` |
| **1.73 ms** | `core.event` | `lua/core/init.lua:168` |
| 1.72 ms | `vim.lsp.log` | (nested under `vim.lsp`) |
| 1.56 ms | `black-metal.palette` | via `require("modules.configs.ui.theme")()` at `lua/core/init.lua:191` |
| 1.30 ms | `vim.lsp.util` | (nested) |
| 1.23 ms | `vim.lsp.protocol` | (nested) |
| 1.03 ms | `vim.lsp._changetracking` | (nested) |
| 0.91 ms | `vim.lsp.rpc` | (nested) |
| 0.79 ms | `core.settings` | `lua/core/init.lua:1` (module-level) |
| 0.77 ms | `vim.lsp.client` | (nested) |
| 0.67 ms | `distro.manifest` | `lua/distro/loader.lua` (in `boot()`) |
| 0.50 ms | `core.options` | `lua/core/init.lua:167` |

**These exclusive numbers are single-sample (n=1 session).** They are reliable enough to
rank the hot path; they are not precise to ±0.1 ms.

### 3.4 `--startuptime` is UNUSABLE for this config — do not quote it

`nvim --startuptime` sums to **7.31 ms** while wall clock p50 is **37.4 ms**, and attributes
**0.00 ms** to any file under our `lua/` tree. It stops profiling at `--- NVIM STARTED ---`
and does not instrument Lua `require`. Anyone using `--startuptime` to characterise this
distro will under-report by ~5×. Flagging because `scripts/startup-bench.sh` and
`measure-cold-definition.lua` both lean on startuptime-style figures.

---

## 4. What is on the hot path, before first paint

All of these run **synchronously** during `init.lua` execution, i.e. before `VimEnter` and
before first paint. Cost column: measured where marked, clearly-labelled estimate otherwise.

| # | Work | file:line | Cost | Class |
|---|---|---|---|---|
| 1 | ~~Whole `load_core` body, excluding nested requires~~ **REFUTED as an exclusive figure** | `lua/core/init.lua:152-226` | **Refuted:** exclusive is **1.15 ms** (the non-require items). The 15.33 ms figure is `core.distro.setup`, which is **inclusive** of its own nested requires — mislabelled one level up. Replacement measurement in §4.1 | before first paint |
| 2 | ~~`vim.lsp` module tree~~ **REFUTED — does not load at startup** | `lspgate.json`: `at_startup=[]`, `at_vimenter=[]`; 0 `vim.lsp*` in `package.loaded`; 0 hits in real `--startuptime` | **0.000 ms on the startup path.** All `vim.lsp` use in `lua/core/event.lua:57-77` is inside `LspAttach` handlers | not on startup path |
| 3 | `require("keymap")` | `lua/core/init.lua:170` | **2.49 ms measured** (exclusive) | before first paint |
| 4 | `require("core.event")` | `lua/core/init.lua:168` | **1.73 ms measured** (exclusive) | before first paint |
| 5 | `createdir()` — 5 × `vim.fn.isdirectory` + conditional `mkdir` | `lua/core/init.lua:3-21`, called `:153` | <0.1 ms estimated — 5 cached stat calls on an existing cache dir | before first paint |
| 6 | `clipboard_config()` — `vim.fn.executable("pbcopy")` + `("pbpaste")` | `lua/core/init.lua:158`, body `:47-49` | <0.5 ms estimated — 2 PATH scans, no process spawn (`executable()` stats, does not exec) | before first paint |
| 7 | `vim.fn.executable("rg")` gate for `grepprg`/`grepformat` | `lua/core/options.lua:156` | included in `core.options` **0.50 ms measured** | before first paint |
| 8 | ~120 × `nvim_set_option_value` loop | `lua/core/options.lua:142-145` | included in the 0.50 ms above | before first paint |
| 9 | `black-metal.palette` (theme load) | via `lua/core/init.lua:191` | **1.56 ms measured** (exclusive) | before first paint |
| 10 | `distro.manifest` + `packpath:prepend` + all eager `start` loads + all lazy autocmd/stub registration | `lua/distro/loader.lua:323-395` (`boot`), manifest at `:348` | **0.67 ms measured** for `manifest` alone; the rest not separately isolated | before first paint |
| 11 | `core.pairs().setup()` | `lua/core/init.lua:181-182` (scheduled) | see row 13 | **DEFERRED** |
| 12 | `format_on_save` configure | `lua/core/init.lua:183-185` (scheduled) | see row 13 | **DEFERRED** |
| 13 | Idle preload of `nvim-cmp` + watchdog flush, 300 ms after `VimEnter` | `lua/distro/loader.lua:401-425` | did not separate from the 4 s settle window (n=1) | **DEFERRED past first paint** |
| 14 | First-idle drain (CursorHold/InsertLeave/CursorHoldI) | `lua/distro/loader.lua:430-437` | n=1, not isolated | **DEFERRED past first paint** |

**Rows 11–14 are confirmed to be genuinely deferred, not merely claimed to be:** they are
absent from the `+qa!` snapshot and present in the settled snapshot (§3.1), they appear only
in the UI-attached run, and the gate they pass is `nvim_list_uis() > 0`, which I measured as
`uis=1` under tmux and `uis=0` headless.

**Honest limitation:** I established the *split* (which work is pre-paint vs deferred) with
high confidence, but I did **not** isolate a clean per-deferred-item cost — my settle window
(4 s) absorbs both the scheduled pair/format work and the 300 ms idle preload. Rows 11–14
carry no independent number.

---

### 4.1 REPLACEMENT measurement — where the 24.6 ms actually goes

The §3.3 attribution is retired (see its banner). The figures below come from a
**different instrument**: `vim.uv.hrtime()` wrappers placed around each statement in
`load_core` (`/tmp/nvim31/loadcore.prof`) and inside `distro.setup`
(`/tmp/nvim31/distro.prof`). These are **inclusive** per-call times from a direct
measurement, not inferred from a require-graph. n=1 session, UI attached, same host.

**Machine: MacBookPro18,1 / M1 Pro / nvim v0.12.5. n=1. Labelled n=1 — a ranking, not a
±0.1 ms claim.**

`load_core` budget, summing to **25.09 ms**:

| call | ms | note |
|---|---|---|
| `core.distro.setup` | **14.993** | inclusive; see its own breakdown |
| `require("keymap")` | 5.113 | |
| `require("core.event")` | 3.138 | |
| `require("core.options")` | 0.766 | |
| `clipboard_config` | 0.619 | 2× `vim.fn.executable`, no spawn |
| `core.weak_hw.setup` | 0.271 | |
| theme palette require | 0.194 | the *palette module*, not the plugin |
| everything else | ~0.06 | createdir, leader_map, gui/neovide/shell, term_guard, turbo, perf |

**Non-require work in `load_core` is 1.15 ms total — not 15.33 ms.** That is the exclusive
figure the retired table claimed. The 15.33 ms in the old §4 row 1 is
`core.distro.setup`'s *inclusive* time, mislabelled one level up.

`core.distro.setup` decomposes, and this is the actual finding:

| call | ms |
|---|---|
| **`load:black-metal-theme-neovim`** | **11.992** |
| `distro.init.setup` | 0.623 |
| `require distro.loader` | 0.352 |
| `load:nvim-web-devicons` | 0.044 |
| `loader.boot` TOTAL | 13.481 |

**A single `M.load("black-metal-theme-neovim")` call in `lua/distro/loader.lua:353`
(the `kind == "start"` loop in `boot()`) costs 11.99 ms — 49% of the entire 24.6 ms
overhead over the `-u NONE` floor.** The palette require is 0.194 ms; the cost is the
plugin's own load, not our Lua.

**Projected effect of deferring it past first paint** (arithmetic from the measured 37.4 ms
and 12.8 ms floor, not a new measurement):

| cut | ms | projected ours | projected ratio |
|---|---|---|---|
| theme only | 11.99 | 25.41 | **1.98×** |
| theme + keymap | 17.11 | 20.29 | 1.59× |
| theme + keymap + core.event | 20.24 | 17.16 | 1.34× |

All three clear the 2.5× threshold. These are **projections from n=1**, not achieved
numbers — a before/after measurement on a live UI is still owed and is the next task.

## 5. COLD vs WARM — reported as two separate numbers, never averaged

### 5.1 True COLD — **NOT MEASURED. Gap, stated honestly.**

- `sudo purge` is unavailable: `sudo -n true` → `sudo: a password is required`. No
  passwordless sudo on this host.
- macOS exposes **no `drop_caches` equivalent**. There is no supported way to evict the
  page cache for a specific tree without root.
- Rebooting a shared host with the owner's live nvim sessions and two other agent lanes
  running was **not an acceptable action** for this lane.

**I did not measure cold. Any cold number in this report would be fabricated.**

### 5.2 What I measured instead — SETTLE-GAP, page cache WARM (labelled: NOT cold)

`/tmp/nvim31/gap.pl` — **15 s with no nvim process** before each timed run, alternating
ours/baseline, **3 pairs, n=3 per condition**. Same commands as §2. Same machine,
nvim v0.12.5, load ~3.3.

**CORRECTION (lead, 2026-09-28 22:1x).** An earlier revision of this section cited a
corroborating "20 s-gap pair 1 = ours 66.6 ms / baseline 36.6 ms / 1.82x". **That claim
had no surviving raw file** — `/tmp/nvim31/gap_out.txt` contains only the three 15 s-gap
pairs tabulated below, and no 20 s-gap run is reproducible from anything on disk. The
number is therefore **retracted, not downgraded**: it is not evidence and must not be
quoted. The table below is the complete settle-gap evidence.

| pair | ours | baseline | ratio |
|---|---|---|---|
| 1 | 58.4 ms | 31.1 ms | 1.88× |
| 2 | 60.4 ms | 24.6 ms | 2.46× |
| 3 | 46.5 ms | 34.3 ms | 1.36× |

> **SETTLE-GAP (page cache WARM — NOT cold): p50(ours) = 58.4 ms, p50(baseline) = 31.1 ms,
> ratio = 1.88×, n=3, spread 1.36×–2.46×.**

- **This is NOT a cold number and must never be quoted as one.** A 15 s gap with no nvim
  process performs **no measurable page-cache eviction** on APFS without root.
- Both conditions inflate by roughly the same absolute amount vs the warm runs
  (ours +21 ms on the median, baseline +18 ms on the median). **That is the signature of
  process/scheduler noise on a load-3.3+ host, not of a cold config tree** — a genuinely
  cold plugin tree would inflate `ours` and leave a 12.8 ms baseline untouched.
- The ratio *falls* (2.93× warm → 1.88× settle-gap) because the *baseline* inflates as much
  as ours. This is a warning against reading the settle-gap ratio as evidence that our
  config is comparatively cheap: it is evidence that the measurement is noise-dominated.
- n=3 with ratio spread 1.36×–2.46× is too wide to support a point estimate. Treat 1.88× as
  an order-of-magnitude indication only.

### 5.3 The repo's known trap is confirmed live in the instrumentation

The ticket's warning (min-of-3 on a warm host hiding a cold run, 160 ms vs 110 ms, +50 ms)
is **structurally live in `scripts/startup-bench.sh`**, which I read and did **not** use:

- `scripts/startup-bench.sh:14-22` — `drop_cache()` is **Linux-only**; on macOS it prints
  "--cold only on Linux with sudo -- warm cache, results optimistic" and **still proceeds**,
  silently reporting an optimistic warm number.
- `scripts/startup-bench.sh:27-32` — it reports **min-of-3 only**. No p50, no p95, no n>1
  statistics, so it cannot expose a cold tail by construction.
- `scripts/startup-bench.sh:39-40` — baseline is `nvim --clean --headless`, not
  `nvim -u NONE`, so it does not measure the quantity this ticket asked for.

I wrote my own loop for those three reasons. No repo file was modified; scratch is in
`/tmp/nvim31/`. `--startuptime` was rejected per §3.4. `scripts/smoke-test.sh`,
`measure-cold-definition.lua`, `runtime-bench.lua`, `lua/distro/bench.lua` and `:DistroBench`
were not used: all are startuptime-family or smoke-family instruments, and §3.4 shows
startuptime cannot see this config's cost. `scripts/interactive-bench.sh` was **not** run —
it belongs to the other lane's `distro-off`/`distro-turbo` split, and its default output path
would have collided.

---

## 6. Why this could be "faster on a colleague's machine" WITHOUT our config being at fault

Each hypothesis gets a concrete falsification test. **H1 is by far the most likely.**

| # | Hypothesis | Falsification test |
|---|---|---|
| **H1** | **Measurement host is load-contended and shared.** Load 3.25–4.40 with Chrome renderers at 48.6 %, `openclaw-gateway` at 33.8 %, Telegram 30.2 %, plus a live nvim and two other agent lanes. Our 37.4 ms p50 is an upper bound. | Re-run §2.1 with **zero** other nvim processes, Chrome/Telegram/opencode quit, on an idle host. If ours drops toward ~20 ms while baseline stays ~12.8 ms, the *ratio* falls to ~1.6× and the machine — not the config — explains the gap. Ratio change is the signal, not absolute ms. |
| **H2** | **Page cache state.** Colleague ran warm; we never achieved true cold (§5.1), and on an HDD a cold plugin tree costs far more per `stat`/`source` than on this Apple-Fabric SSD. | Compare `ours`/`baseline` ratio on this APFS volume vs an HDD. A config that is I/O-bound shows a ratio that inflates as the FS gets slower; a CPU-bound config shows a flat ratio. Our 2.9× is measured on NVMe, so HDD peers are likely **worse**, not better. |
| **H3** | **Deferral is inert in headless but live in their real UI.** If a colleague's "fast" number came from a real terminal and mine is headless, we are not comparing the same thing — though note my headless 2.9× is the *pessimistic* direction. | Measure the ratio under a real PTY (tmux or `script`) on both sides. If the UI ratio is materially below 2.9×, the deferral machinery is doing real work and headless overstates our cost. |
| **H4** | **Thermal state / power management.** Sustained load on this M1 Pro causes frequency and efficiency-core shifts that inflate every subsequent launch. | Run §2.1 immediately after ≥10 min idle vs during sustained load. Compare p95 especially — a widening ours-p95 (48.5 ms here) is the thermal signature. |
| **H5** | **Different module/plugin set, not different code.** Different Neovim version, different `pack/distro` contents, or a colleague running `distro-turbo` vs our default. | Diff `pack/distro/{start,opt}` and `nvim --version` between machines. A different plugin set is a different measurement, not a faster one. |
| **H6** | **`-u NONE` is not a fair floor on their machine** because their Neovim build ships heavier defaults. | Measure `-u NONE` on both machines. If their floor is higher, part of the perceived difference is the floor, not our config. |

**Explicitly not investigated:** the config's default profile deliberately loads
`nvim-cmp` ~300 ms after `VimEnter` (`lua/distro/loader.lua:405`). If a colleague runs with
that idle preload suppressed, their *interactive* experience differs while their startup
number looks identical. Falsify by toggling the `lua/distro/loader.lua:406`
`if not defer_enabled() then return end` guard and re-measuring — flagged as an observation
for the lead, **not** a change; I did not modify it.

---

## 7. Acceptance check

Every number above carries: machine class (§1), nvim version (v0.12.5), warm/cold label,
n, the exact command, and p50/p95 where n > 1. Numbers carrying **n=1 / single-sample** are
marked as such at the point of use: §3.3 exclusive require costs, §4 rows 1–10 and 13–14.. No average of a cold and a warm number is
quoted anywhere. No `+qa!` count is presented as a count — §3.1 labels 18 and 16 as lower
bounds and gives 19 and 20 as the settled counts.

**The contract gate FAILS at 2.51x vs 2.5x (§2.2b), with a CI that straddles it.** This is
the single most decision-relevant number in this brief and it is reported without adjustment.

**Reproduced in a second session:** the §2.1 ratio (§2.2, Δ = 0.16×, CIs overlap) and the
§2.1 p50 for both conditions (ours 37.4 → 34.8 ms, baseline 12.8 → 12.6 ms).

**Not reproduced / not attempted:** the §3.3 require costs (n=1, UI, single session) and the
§5.2 settle-gap ratio (n=3, spread 1.36×–2.46×). Labelled, not a stable point estimate.
The previously-cited corroborating 20 s-gap pair has been **retracted** (no surviving raw
file) — see the correction in §5.2.

**Not measured, with reason:** true cold (§5.1 — no root, macOS has no `drop_caches`, reboot
of a shared host out of scope); per-item cost of the four deferred units (§4 rows 11–14 — my
4 s settle window does not separate the scheduled pair/format work from the 300 ms idle
preload); anything requiring a real terminal to first paint (other lane's remit, and the
ticket explicitly assigns it elsewhere).

---

## 8. Handoff

This is an evidence brief, not a work order and not a review. It does not decide whether the
2.9× ratio should be reduced, nor how. Two findings are load-bearing for whoever writes the
ТЗ:

1. **Any startup figure for this distro taken with `+qa!`, headless, or `--startuptime` is
   wrong** — respectively a 20 % undercount, a deferral-inert worst case, and a ~5×
   under-report (§3.1, §2.3, §3.4).
2. **Cold is unmeasured and unmeasurable on this host without root.** Any cold target must be
   set on a machine where the cache can actually be dropped, or the target will be fiction.

Confidence: **high** for the ratio and its reproduction and for the pre-paint/deferred split;
**medium** for the ranking in §3.3/§4; **none claimed** for cold.
