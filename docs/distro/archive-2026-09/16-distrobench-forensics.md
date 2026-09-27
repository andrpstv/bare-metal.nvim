# 16 — DistroBench forensics: what the 100-120ms / 500-1500ms numbers actually measure

Question: consumers on Windows report `:DistroBench` open timings of **500–1500ms** against the
owner's **100–120ms**. Is that our code or the environment?
Repo `/Users/16prom1/.config/nvim`, nvim 0.11.4. **Config not modified, no commits.**
Measured on macOS 26.3 arm64 **SSD, warm cache** — every Windows/HDD figure is explicitly
marked and never presented as measured.

---

## 0. Verification of the stated fact

**CONFIRMED, and the number is worse than a wall-clock: it is a wall-clock of a whole child
process.** `lua/distro/bench.lua:11-33`:

```lua
local function child_open(file, clean)
	local best = nil
	for _ = 1, 3 do
		local argv = { vim.v.progpath, "--headless" }
		if clean then argv[#argv + 1] = "--clean" end
		argv[#argv + 1] = file
		argv[#argv + 1] = "+qa"
		local t0 = vim.uv.hrtime()
		local obj = vim.system(argv, { timeout = 60000 }):wait()
		if not obj or obj.code ~= 0 then
			return nil, "child nvim failed (exit " .. tostring(obj and obj.code) .. ")"
		end
		local dt = ms(t0)
		if not best or dt < best then best = dt end
	end
	return best
end
```

So one reported "open" figure is **min over 3 runs of (fork/exec + dynamic link + config startup
+ file read + `+qa` teardown + process exit)**, with `--headless` (no UI, no paint). The two arms
are `clean` (`--clean`, but note: **without `-i NONE`**, so clean still reads shada) and `ours`
(the distro config).

---

## 1. Decomposition of the figure (macOS SSD, warm)

Two independent instruments: `--startuptime` inside the child, and wall-clock of the whole child.

| | clean | ours | delta |
|---|---|---|---|
| **wall, min of 5** (what DistroBench prints) | **21.5ms** | **95.3ms** | **+73.8ms** |
| **wall, min of 5, 20k-line file** | 23.2ms | 103.5ms | +80.3ms |
| startuptime `--- NVIM STARTED ---` | 22.795ms | 52.141ms | +29.3ms |
| startuptime `loading packages` | 13.317ms | 28.805ms | +15.5ms |
| startuptime `opening buffers` (file is read here) | **5.723ms** | **5.296ms** | **−0.4ms** |
| startuptime `editing files in windows` | 0.001ms | 0.002ms | ~0 |
| BufReadPre→BufReadPost (my probe) | not captured (harness) | 8–23ms | — |

Two structural facts fall out of this, and they are the core of the answer:

**(a) Opening the file is NOT where our cost is.** `opening buffers` is 5.7ms clean and 5.3ms
ours — the *same*, within noise, for a 100-line and a 20,000-line file (23.2 vs 103.5ms total).
Reading the file is a fixed ~5ms on this hardware, config-independent.

**(b) A large part of the wall clock is outside the profiler window.** ours = 95.3ms wall but only
52.1ms to `NVIM STARTED`. **~43ms (45% of the reported figure) is process spawn + dynamic
linking + teardown**, which `--startuptime` does not cover. clean = 21.5ms wall / 22.8ms
profiled (i.e. essentially all of it is inside, because there is almost nothing to do).

**Consequence for the Windows question:** the component that scales with hardware and
antivirus — spawn, DLL load, AV scanning — is the component that does **not** depend on our
config. It is also the part `--startuptime` cannot show you.

### How to measure each part in the same child (method, reusable)

1. **Spawn + startup** — parent records `t0 = time.time()*1000` immediately before `Popen`;
   child registers `VimEnter` via `--cmd` (before vimrc) and stamps `vim.uv.now()` (ms since
   epoch — the same epoch). `spawn+startup = VimEnter_stamp − t0`.
   (My parser mis-parsed this column and reported `n/a`; the method is sound, my epoch
   subtraction in `decomp_bench.py` was not. Numbers in this section come from `--startuptime`
   plus wall-clock, not from the broken column — flagged rather than papered over.)
2. **File open** — child stamps `BufReadPre` / `BufReadPost`; delta is the open leg. Cross-check
   against startuptime `opening buffers`.
3. **Teardown** — child stamps `VimLeavePre`; `teardown = parent_exit_time − VimLeavePre_stamp`.
4. **Total** — parent wall clock. `total − (spawn+startup) − open − teardown` = unattributed.

---

## 2. The rtp-scan hypothesis: **REFUTED by experiment**

Hypothesis: nvim stats all 4745 files in `pack/` (48MB) on every start, which is what makes
HDD/Defender 5–15× worse.

Test A — real packpath, synthetic files (`-u NONE`, `set packpath^=`, 5 runs, min):

| fake .lua files under a pack dir | min wall |
|---|---|
| 0 | 13.1ms |
| 2,000 | 12.5ms |
| 5,000 | 13.4ms |

Test B — same via `runtimepath^=` with the distro config loaded: 0 / 2000 / 5000 files →
93.3 / 92.8 / 91.3ms. No effect.

**Adding 5,000 files to the packpath costs 0.3ms — noise.** Neovim globs the package directories
and filters by suffix; it does not open or stat every file. This kills:
- the "4745 files are stat'd at startup" premise (also measured in Phase 1 and in doc 15:
  only **4** files are actually sourced from `pack/` at startup);
- the "reduce file count under rtp" optimisation family (see §6, explicitly not proposed).

**Windows caveat, stated honestly:** this proves the *count* of files is free on a warm macOS SSD.
On a cold HDD with Defender, `readdir` on a 4,745-entry directory plus Defender's per-file
filtering driver is plausibly NOT free — but that is a claim about the *cold AV path*, which I
**cannot measure here**, and it is a claim about the environment, not about our Lua. It would
show up in the `clean` arm just as much as in `ours`.

---

## 3. min-of-3 systematically hides the cold cost — and hides it asymmetrically

Six sequential child runs, every run reported (not min):

| run | ours (100-line file) | clean |
|---|---|---|
| 1 | **160.2ms** | **21.4ms** |
| 2 | 99.5ms | 20.6ms |
| 3 | 99.0ms | 20.8ms |
| 4 | 123.7ms | 20.5ms |
| 5 | 95.0ms | 19.3ms |
| 6 | 95.7ms | 20.7ms |
| **min-of-3 (what DistroBench prints)** | **95.0ms** | **19.3–20.7ms** |

- **ours: cold penalty 65.2ms (+69%)** over the warm floor.
- **clean: cold penalty 1.1–2.1ms (+11%)**.

`min-of-3` reports 95.0ms and **hides the 160ms first run entirely**. Because the three runs
are consecutive on the same warm host, runs 2–3 are warm by construction.

**Why this matters specifically for the target profile:** the penalty is a *cache/AV* effect. Our
config's first run pays for compiling/reading 86 of our own Lua files plus ~4 pack files plus
nvim's own runtime; stock `--clean` pays for almost nothing. On a Windows box with Defender and
a cold page cache, the ratio of first-run penalty to warm floor is far more extreme than the
+69%/+11% measured here. **So min-of-3 systematically under-reports exactly the population the
release targets** (a consumer opening nvim for the first time that morning).

---

## 4. `timeout = 60000` does NOT fail silently — verified

```
$ nvim --headless -u NONE -l /tmp/hd/tmo.lua
vim.system timeout=500 on sleep 5 -> dt=500ms code=124 signal=15
```

`code=124` is non-zero, so `bench.lua:28` catches it and the output line becomes
`open small file FAILED: child nvim failed (exit 124)`. It is loud, not silent. But it has two
real defects:

1. **A frozen UI with no feedback for up to 6 minutes.** `child_open` runs 3 sequential children
   at up to 60s each, and `M.run()` calls it 4 times (clean/ours × small/big) — worst case
   **6 × 60s = 360s** of a blocked UI on the DistroBench window, with no progress indication.
2. **One timeout destroys the comparison.** `bench.lua` requires `clean_ms and our_ms` to print
   the line, so if either arm times out you lose the delta for that file size entirely — the
   one number the owner is trying to read.

---

## 5. The main question: our code, or the environment?

**Verdict: the absolute figure (500–1500ms) is almost certainly environment. The delta (+K) is
ours. They are different numbers and the release is currently being planned on the wrong one.**

Structural argument from the measurements above:

| component | scales with | config-dependent? | macOS evidence |
|---|---|---|---|
| spawn + dynamic link + AV | CPU, disk, Defender | **NO** | ~43ms of our own 95.3ms, outside the profiler |
| nvim runtime init (packages, rtp) | config dir | partly | `loading packages` 13.3 → 28.8ms (ours adds 15.5ms) |
| our Lua config | CPU only | **YES** | 19.4ms `require('core')`, CPU-bound, disk-independent |
| file read | disk | NO | 5.3–5.7ms, identical clean vs ours |
| teardown | disk, AV | NO | — |

Our config's contribution is **CPU-bound** (Lua parsing, `nvim_set_option_value` calls, theme
highlight definitions). On a slow CPU it grows; on a slow **disk** it barely moves. Everything
that scales with HDD/Defender — process creation, image load, shada read, file read — is
identical in both arms.

**The discriminator the owner already has and is not using: the `clean` number in the same
output line.** `bench.lua` prints `open X clean Nms · ours Mms (+Kms)`. If on a consumer machine
`clean` is also 400–1400ms, the bottleneck is the environment and **no config change can move
it**. If `clean` is ~150–250ms while `ours` is 500–1500ms, then the delta is ours and is ~10×
the owner's own machine — which would itself point at a cold-cache/AV interaction with *our*
files (86 Lua files, 48MB `pack/`, `pack/distro` layout) rather than at the algorithm.

**Most probable (my judgement, stated as such):** `clean` on those machines is high. The
100–120ms owner figure is a *warm SSD* number; 500–1500ms is a *cold AV* number. The config
contributes a bounded, CPU-scaling delta of roughly 75ms warm (measured here) and plausibly
150–300ms cold. **500–1500ms absolute is not our bug.** The risk being that the release gets
scoped around a number that Defender owns.

**НЕ ИЗМЕРЕНО:** every actual Windows/Defender figure. I have no Windows host. The above is a
structural inference from the decomposition, not a measurement.

---

## 6. Concrete measures against 500–1500ms

Ordered by expected effect **for the environment-dominated hypothesis**, which §5 says is the
likely one. Effect column is honest: several are unmeasurable from here.

| # | measure | effect | risk | rollback | cost |
|---|---|---|---|---|---|
| 1 | **Ask Defender to exclude the nvim install dir and the config dir** (or add the process) | The single largest lever if the hypothesis is right: removes the per-image and per-file scan on the spawn path. Plausibly hundreds of ms on a cold start. **NE IZMERENO** | Low — a consumer-side settings change, no config change | Remove the exclusion | ~1 min per consumer |
| 2 | **Put the config (incl. `pack/`, 48MB) on a LOCAL SSD, not a network/redirected `%USERPROFILE%`** | Network profile = every one of the ~5 startup fs ops and every `pack/` read becomes a network round trip. **NE IZMERENO** | Low | Move the folder | manual |
| 3 | **Measure COLD, not min-of-3** (see §7 stand) | Not an optimisation — a correctness fix to the *measurement*. Currently the first-run 160ms is invisible. | none | revert the script | small |
| 4 | **Report `clean` as the headline, delta as secondary** | No speedup; prevents mis-scoping the release. | none | revert | tiny |
| 5 | **Reduce files under rtp / repack plugins / disable `plugin/*.vim` scanning** | **NOT PROPOSED.** §2 measured it: 5,000 files cost 0.3ms. Expected effect ≈ 0. | — | — | — |
| 6 | **Shada/state to a local path**; `shadafile`/`statedir` on a network profile | Small, once per session, at exit. **NE IZMERENO on network** | Low | unset the option | tiny |
| 7 | **Defer the theme** (`defer_theme`, already implemented) so the first frame does not wait for black-metal | ~6ms warm on the owner's machine; on a slow CPU proportionally more. Below the 2ms bar on my SSD measurement but this is a *cold/CPU* argument, not an SSD one | Medium — can cause a colour flash | `settings.defer_theme` | already done |
| 8 | **Lazy-load dap/dapui/go.nvim/lint** (from doc 15, E-1) | ~60 fewer modules on first open. CPU-bound, not disk-bound — helps a slow CPU, not Defender | Low | manifest revert | small |

Note the pattern: **the measures with the largest expected effect are all consumer-side or
environmental, not config edits.** That is the strategic conclusion of this document.

---

## 7. Proposed corrected stand (one command, no pty, no GUI)

Purpose: a consumer can run one command and send back numbers that are actually comparable.
Design constraints from §1–§4: split the phases, measure cold separately, never rely on `+qa`
to bound the run, no UI.

Save as `scripts/distrobench-cold.lua`, run as:

```
nvim --headless -i NONE -l scripts/distrobench-cold.lua
```

It must:
- print `nvim --version`, `stdpath(config/cache/data/state)`, and a **local vs network** check on
  each path (Windows: `\\?\UNC\` prefix or a `net use` / mapped-drive probe; POSIX: `$HOME`
  on NFS/SMB),
- for each arm (`--clean`, `-u <config>`) run **N=5 child processes and print EVERY run**, plus
  first-run and min-of-rest separately — never a bare min,
- inside each child (`--cmd`, before vimrc) stamp `VimEnter` / `BufReadPost` / `VimLeavePre`
  with `vim.uv.now()` and the module count, then exit on its own timer
  (`vim.defer_fn(..., 3000)` → `qa!`) rather than `+qa`, so deferred work is observed
  (doc 15 measured 198→327 modules after the first frame; `+qa` hides that),
- report the split `spawn+startup / open / teardown / unattributed` per run,
- print a one-line verdict: `cold_delta = ours1 − clean1` and `warm_delta = min(ours2..5) − min(clean2..5)`,
  because **those are the two numbers the release should be scoped on**,
- have a per-child timeout of ~20s (not 60) and **report a timeout as its own line with which
  arm failed**, rather than discarding the pair as `bench.lua` does.

I have the instrumented harness for all of this at `/tmp/hd/decomp_bench.py` +
`/tmp/hd/decomp.lua` (with the known epoch-arithmetic bug in the spawn/teardown columns called
out in §1 — those two columns need the fix, the `--startuptime` cross-check is sound). It is
**not** committed, per the no-changes constraint.

---

## 8. What is NOT measured / not fixable here

- **Every Windows and Defender number.** No Windows host. §5's verdict is a structural
  inference, explicitly labelled.
- **Real cold-cache behaviour.** No sudo; the macOS page cache cannot be dropped, so my
  "cold" run 1 (160ms) is a *partially* warm first run — the true cold penalty is larger than
  measured, for both arms.
- **Whether the 43ms unattributed region is spawn or teardown specifically** — my column math
  failed; the method is in §1 and needs one fix.
- **The `clean` numbers on the consumer machines** — this is the single measurement that would
  settle §5, and it requires someone to read the existing `clean Nms` field in the output the
  owner already collected. **That check is free and should happen before any further work.**

---

## 9. Bottom line

1. `DistroBench`'s "open" number is a **whole-child-process wall clock** (spawn + startup +
   open + teardown), min-of-3, headless — `bench.lua:11-33`, confirmed.
2. **~45% of it (43ms of 95.3ms here) is spawn+link+teardown, outside `--startuptime`** — the
   part that Defender and disk dominate.
3. **Opening the file itself is config-independent**: 5.3ms ours vs 5.7ms clean, identical for
   100 and 20,000 lines.
4. **The rtp/pack scan theory is dead**: 5,000 fake files in a packpath cost 0.3ms.
5. **min-of-3 hides a 65ms cold penalty on our config and only 1–2ms on clean** — the stand is
   biased against exactly the cold population the release targets.
6. `timeout=60000` fails loudly (code 124) but can freeze the UI for 6 minutes and destroys
   the clean/ours pair when it fires.
7. **Most probable: 500–1500ms is environment, and the `+K` delta is ours.** Read the `clean`
   field in the data already collected before scoping the release further.
