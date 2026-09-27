# 13 — Runtime optimization report

Repo: `/Users/16prom1/.config/nvim` · nvim 0.11.4 · macOS 26.3 arm64 · 2026-09-26
Inputs read first: `docs/distro/11-phase1-discovery-audit.md`, `docs/distro/12-runtime-latency-audit.md`.

**Outcome: 0 commits.** All three candidates were implemented-or-measured to
completion, and all three came back *negative* or *marginal*. The two headline
numbers in the briefs (cmp 78.4→14.9 ms, colorscheme 10.7–24 ms) do not survive
measurement. Per the phase rule "no commit without a measured before/after", and
"a commit with an unverified number is worse than no commit", nothing is
committed. Details and raw evidence below so the negative results are reusable.

---

## 1. Candidate A — `cmp_defer_caps` (the uncommitted WIP): **DO NOT COMMIT**

**This was the top-priority item and it does not hold up.** The audit was right
that the original headless measurement was invalid (`distro.loader` never fires
headless, so both arms measured the same inert path), but re-measuring *with a UI
attached* does not rescue the number either.

### Method

Headless cannot test this path at all, so measurement needs `nvim_list_uis() > 0`.
I drove real nvim instances under a pty (`python3 openpty` + a drain thread, so
the pty buffer never blocks a full-screen redraw), which is the only way to make
`lua/distro/loader.lua` `defer_enabled()` actually true.

Two harness bugs were found and fixed *before* trusting any number — both would
have produced a fabricated result:

1. The first probe built a `FORCE=...` shell variable and never passed it to nvim,
   so both arms ran the default. Symptom: suspiciously identical arms.
2. The second probe polled with a tight `while ... vim.wait(5, ...)` spin that
   starved the very event loop it was timing, and wedged (7+ min, no output).
   Fixed by driving everything from the main thread with `vim.wait(cond)`.

The probe aborts with `cquit 3` if no UI is attached, so an inert headless run can
never be silently reported as a UI measurement.

### Result (4 reps per arm, interleaved, `/tmp/rtbench/tiny.go`, Go buffer)

| arm | open window (med) | edit wall (med) | mods after :edit | mods after settle | cmp in open window | cmp by settle |
|---|---|---|---|---|---|---|
| `cmp_defer_caps = true`  | 3.90 ms | 4.01 ms | 82 | 302 | 0/4 | 4/4 |
| `cmp_defer_caps = false` | 4.16 ms | 3.68 ms | 82 | 302 | 0/4 | 4/4 |

**The two arms are identical.** Same module counts at both checkpoints (82 / 302),
nvim-cmp loads in the open window in neither, and the 0.33 ms difference in edit
wall is inside the run-to-run spread (individual samples span 3.53–4.69 ms).

### Why the claimed win cannot exist

`nvim-cmp` is already deferred by the loader, not by this setting.
`lua/distro/manifest.lua:17-28` declares it `kind="opt"`, `defer_idle = true`,
`event = { "InsertEnter", "CmdlineEnter" }` — so it is not on the `:edit` path in
*either* configuration. The setting only chooses where the *capabilities table*
comes from.

The `false` arm is supposed to be the eager path, but it is not: at
`lua/modules/configs/completion/lsp.lua:63` it does
`elseif not pcall(function() cmp_caps = require("cmp_nvim_lsp")... end)`. Since
nvim-cmp is not on the rtp yet, that `require` throws, `not pcall(...)` is true,
and control falls into the fallback at `:66-70`, which calls
`require("distro.loader").load("nvim-cmp")` — the *same* deferred load the `true`
arm schedules. Both arms therefore converge on identical behaviour. The
"63 ms on every :edit" figure describes a path the loader already closed.

### Recommendation

Leave the change uncommitted as-is, or revert it. It is not harmful — but the
comment at `lua/core/settings.lua:232-243` and `lsp.lua:44-49` asserts
"78.4 → 14.9 мс" and "~63 мс на КАЖДОМ :edit", and **those numbers are not
supported by any measurement I could reproduce**, on either headless or UI. At
minimum the comments must be corrected before this is ever committed; a
screenshot-worthy claim with no reproducible measurement is exactly the failure
mode this phase is meant to prevent. I did not edit those files, because the
correct fix (revert vs. keep-and-document) is the coordinator's call.

---

## 2. Candidate B — colorscheme cost: **CLOSED, and the audit number is a launch-mode artifact**

**Correction to my own earlier framing.** I first reported this as "the audit is
~10x too high". That was wrong, and the coordinator supplied the decisive
control: the same script run two ways gives

| launch | boot state | `:colorscheme khold` | habamax | replay |
|---|---|---|---|---|
| `nvim --headless -l cs4.lua` (config NOT loaded) | `colors_name=nil`, 373 groups | 17.31 ms | 8.56 ms | 5.48 ms |
| `nvim --headless -c 'luafile cs4.lua'` (config loaded) | `colors_name=khold`, 618 groups | 1.93 ms | 1.08 ms | 0.34 ms |

Both numbers are correct *for their own mode*. The researcher's 23.7 ms and my
2.25 ms are the same operation measured cold (`-l`, config uninitialised, theme
applied for the first time, whole cold path) versus warm (config loaded, theme
already applied). Neither is a bug in the other's measurement.

**So: a theme switch really costs ~2 ms in a live session, and the ceiling on any
highlight-table cache is ~1.5 ms. Candidate B is closed — do not build it.** The
~10–24 ms figure describes the cold `-l` path, not a runtime cost a user pays on
`:colorscheme`. Any future document citing audit 12 P0-1 must carry this caveat.

### Supporting measurement (N=10, in-process, warm)

```
CS groups=618
CS colorscheme_khold      n=10 min=1.79 med=2.06 max=2.41
CS hi_clear_plus_replay   n=10 min=0.31 med=0.31 max=0.38
CS replay_only            n=10 min=0.19 med=0.19 max=0.20
CS colorscheme_habamax    n=10 min=0.84 med=1.10 max=1.49
```

N=15 repeat (`/tmp/cs_breakdown.lua`) agrees: `colorscheme_khold_full`
min=1.56 med=1.87 max=2.34. Fresh-process first apply (5 separate processes,
`/tmp/cs_first.lua`): 2.42 / 2.60 / 2.49 / 2.41 / 2.46 ms.

So the **honest** first-apply cost is ~2.5 ms and a warm re-apply is ~1.9 ms —
not 15–24 ms. The "builtin floor" is 1.10 ms for habamax, not 10.7 ms.

### Why the cold number is large

The ColorScheme autocmd chain is not the cost in either mode: firing it in
isolation costs **0.004 ms** (`autocmd_chain_only`), so the palette-refresh +
`gen_alpha_hl` + `gen_lspkind_hl` + `AlphaRedraw` work is three orders of
magnitude below the claim. The cold `-l` figure is dominated by first-touch
`black-metal` module loading (the audit's own isolated table puts that at 3.3 ms)
plus first-ever application over a 373-group table rather than the warm 618-group
table.

### Is a highlight-table cache worth building?

Mechanically yes, but the payoff is ~1.5 ms, not ~10 ms:

- `:colorscheme khold` warm: 1.87 ms → `hi clear` + replay 618 groups: 0.31 ms
- **best case saving: ~1.5 ms per theme switch**, paid once at startup.

I am not committing it. Reasons, in order of weight:

1. The prize is ~1.5 ms against a ~45 ms warm start. It does not move any of the
   three release metrics.
2. A replay cache has to be invalidated correctly or it silently freezes
   highlight state. `nvim-web-devicons` is an eager `kind="start"` plugin
   (`manifest.lua:12`) that injects groups; my snapshot found 0 groups whose name
   contains "devicon" but 32 containing "Diagnostic", so the exact ownership
   boundary needs establishing before a cache can be trusted to be complete.
3. The brief explicitly ruled out the cheap version of this win ("deferred theme
   with a white flash") and asked for the first visible frame to be unchanged. A
   correct cache is the only acceptable form, and #2 is the prerequisite for
   correctness. That is a real piece of work for ~1.5 ms.

Recorded here so the option is not re-derived from scratch later: the measurement
is reproducible via `/tmp/cs_bench.lua`, and the shape of a correct implementation
is "snapshot after apply, key the cache on theme+terminal, replay, drop on
ColorScheme".

---

## 3. Candidate C — `executable()` probes on the startup path: **DEAD, 0.05 ms**

Audit §5.3 named this "the most plausible slow spot in core's 6.7 ms self time",
and the coordinator's revised priority #1. Now measured on the **real startup
path** rather than a synthetic list of names.

`vim.fn.executable` is assignable, so I wrapped it via `--cmd` (installed before
init.lua) and counted every call the config actually makes:

```
EXECREAL calls=3 total=0.072ms  pbcopy=0.038 pbpaste=0.020 rg=0.014
EXECREAL calls=3 total=0.046ms  pbcopy=0.024 pbpaste=0.013 rg=0.009
EXECREAL calls=3 total=0.045ms  pbcopy=0.024 pbpaste=0.013 rg=0.009
```

**Three calls, 0.045–0.072 ms.** On macOS `clipboard_config`
(`lua/core/init.lua:50-59`) probes exactly two names (`pbcopy`, `pbpaste`); the
third is the one-shot `rg` lookup. `shell_config` (`:118-138`) is
`is_windows`-only and costs nothing here. The audit's "up to ~8 calls per
platform branch" describes the worst-case Windows/Linux branch, not this machine.

Caching this would save **0.05 ms**. There is nothing to win.

A broader wrap of every `vim.fn`/`vim.api` call on the startup path bounds the
whole opportunity (`/tmp/wrap_all.lua`, 3 runs):

```
ALLWRAP wrapped_total=0.617ms | set_option_value n=108 0.209 | set_keymap n=121 0.161
                               | create_autocmd n=41 0.085  | create_user_command n=37 0.070
                               | fn.executable n=3 0.054    | create_augroup n=19 0.022
```

**Every option set, keymap, autocmd, user command and `executable()` call in the
whole config costs 0.5–0.6 ms combined.** This is the cleanest number in the
report: it installs no require hook, so unlike §4 it is not inflated by its own
instrument.

On Windows with a long `$PATH` and AV hooks this could plausibly be several times
worse. That stays a legitimate, **unverified** hypothesis about a platform I
cannot measure from here. I will not ship a number I did not measure, and I will
not build a cache for it.

---

## 4. Methodology finding: the require graph behind the "6.7 ms self" is largely hook overhead

I rebuilt the `require('core')` graph with a stack-based self-time hook
installed via `--cmd`, so it wraps the *first* `require('core')` rather than a
cached one (`/tmp/pre_hook2.lua`, 3 runs):

```
PREHOOK2 core   self=12.612 cum=16.442   core.event self=1.353
PREHOOK2 core   self=10.390 cum=14.824   keymap     self=2.080
PREHOOK2 core   self=10.786 cum=14.742   distro.manifest self=0.569
```

That is *higher* than the audit's 6.718 ms, which should itself have been a
warning sign. Calibrating the instrument explains why (`/tmp/cal.lua`, 3 runs,
5 already-cached requires):

```
CAL install_ms=0.0003 with_hook=1.7684 no_hook=0.0006 calls=5
```

**The hook costs ~0.35 ms per `require` call** — roughly 2000x the cost of the
operation it wraps. The boot pulls ~60 modules, so a require-hook graph spends
~20 ms measuring the hook. A module that issues many *direct* `require` calls
(core issues ~20) has that overhead charged to its own "self" time, which is
exactly where the audit's largest number sits.

**Consequence:** the `self_ms` column in `docs/distro/12` §0 — and the
"`core` self = 6.718 ms, the biggest single line in the graph" that priority #1
was built on — is not a reliable figure. Much of it is the measuring instrument.
This invalidates the *premise* of the top-priority candidate, not merely its
magnitude.

This is the second time in this phase that a plausible-looking number dissolved
under calibration (the first was the cmp claim). Both times the defect was in the
harness, not in the config. Any future require-graph work in this repo should
calibrate its hook against a no-op baseline before publishing a `self_ms` column.

- **The three claimed wins do not survive measurement.** Two were harness
  artifacts — the cmp claim was measured on a path that never executes, and the
  colorscheme claim conflated a cold `-l` boot with a warm `:colorscheme`. The
  third, `executable()` caching, is real but worth 0.05 ms. This is the most
  useful output of the phase: it stops the team building a highlight cache
  against a target that is 10x too large, and stops them building an
  `executable()` cache for a cost that is not measurable.
- **The `require('core')` self-time graph is not a reliable instrument.** §4 shows
  the hook that produced the audit's headline number costs more than most of the
  values it attributed. The audit's "do not touch" conclusions still stand —
  they are structural, not numeric — but its `self_ms` column should not be
  quoted as a cost.
- **The config is in good shape on the runtime path.** No sync blockers, no
  misbehaving hot autocmd, and after measurement there is **no win above ~1.5 ms
  anywhere in my zone**. Every option set, keymap, autocmd, user command and
  `executable()` call in the whole config costs 0.5–0.6 ms combined.
- **Per the coordinator's own decision rule, I am reporting the negative
  result rather than inventing an optimisation.** Candidates 2 (manifest 0.93 ms)
  and 3 (keymap lazification ~0.2 ms) are below the 2 ms bar by construction and I
  did not build them. Candidate 4 (CursorHold fan-out) and 5 (gitsigns default
  profile) are real and structural but I have **no number** for either, and the
  standing rule is that an unmeasured change does not get committed. If the team
  wants 4 or 5, say so and I will measure them with `scripts/interactive-bench.sh`
  first — I did not do it unasked because that harness is slow and the brief made
  the decision rule explicit.
- **My recommendation: accept the current runtime profile for the release.** The
  config is not slow for any reason I can find, and "safe and not slower than
  clean nvim" is a legitimate ship criterion. If the ~25→45 ms warm-start gap
  still matters, it needs its own scoped piece of work with its own measurements
  — not more sub-2 ms micro-optimisation.

## 5. Reproducing these numbers

| Claim | Script | Run |
|---|---|---|
| Candidate A, UI-attached | `/tmp/pty_cmp3.lua` + `/tmp/pty_run.py` | pty harness; requires `uis > 0`, aborts otherwise |
| Candidate B, colorscheme warm | `/tmp/cs_bench.lua` | `CSB_REPS=10 nvim --headless -c 'luafile ...'` |
| Candidate B, fresh process | `/tmp/cs_first.lua` | 5× `nvim --headless -c 'luafile ...'` |
| Candidate B, autocmd chain | `/tmp/cs_breakdown.lua` | `CSB_REPS=15 nvim --headless -c 'luafile ...'` |
| Candidate C, `executable()` real path | `/tmp/wrap_exec.lua` | `nvim --headless --cmd 'luafile ...' -u init.lua -c '...' -c 'qa!'` |
| Candidate C, all startup APIs | `/tmp/wrap_all.lua` | same, 3 runs |
| Require-graph + its calibration | `/tmp/pre_hook2.lua`, `/tmp/cal.lua` | hook must be installed via `--cmd`, and calibrated |

Two lessons worth carrying forward, both of which cost me a cycle each:

- **Install measurement hooks before the config loads.** `--cmd` runs before
  `init.lua`; `-c 'luafile …'` runs *after* it. A probe in the second position
  measures a config that is already fully loaded, and reports `0.000 ms` for
  everything because every `require` is a cache hit.
- **Calibrate the instrument before publishing its numbers.** The require hook
  costs ~0.35 ms per call, which is larger than most of the values it was built
  to attribute.

The scripts live in `/tmp` and are not part of the repo, matching the phase rule
about not committing unmeasured scaffolding. If these numbers are to be cited
again, the probe scripts — and the calibration step — should be promoted into
`scripts/` first. The two pty harness bugs I hit (a variable I built and never
passed, and a `vim.wait` spin that starved the event loop it was timing) are
exactly the class of defect a committed harness prevents.
