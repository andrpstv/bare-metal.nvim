# 17 — Independent verification of today's four commits

Analytical check of the coordinator's work on `7c7a9fb`, `570b66c`, `452c6f1`, `6fa8fde`.
Repo `/Users/16prom1/.config/nvim`, nvim 0.11.4, measured on macOS 26.3 arm64 **SSD, warm**.
**No code written, no config changed, no commits.** Every macOS number is labelled; Windows/HDD
is never presented as measured.

**Verdict up front:** the main finding is **correct and independently reproduced**. Two of the
three trace defects are confirmed, the third is mischaracterised. `452c6f1` is a correct
de-blocking change but introduces a **silent-failure regression** the commit message does not
mention. And the trace fix left one real "sorting lies" case, which I name below.

---

## 1. The main finding — verified

### 1.1 Arithmetic: CONFIRMED

```
keypress_to_request   0.207    1.3%   (sum 16.144)
request_to_response   1.584    9.8%   ← claim 9.6%  (rounding, fine)
response_to_cursor   14.353   88.9%   ← claim 89%
delta k->r            1.377             ← claim 1.38
delta r->c           12.769             ← claim 12.77
```

All five figures reconcile exactly. **The percentages are of the 16.144ms total; the deltas are
the phase costs.** The conclusion "gopls is ~10% of a warm gd" is sound.

### 1.2 Independent reproduction of the response→cursor cost

I measured the actual work in that phase — `vim.cmd.edit()` into `go/pkg/mod` — 5 runs in one
session, per-event stamps, with `nvim -u NONE` control:

| | median | min | max | n |
|---|---|---|---|---|
| **ours** | **14.91ms** | 8.28ms | 203.27ms | 5 |
| **clean (`-u NONE`)** | **0.56ms** | 0.08ms | 0.72ms | 5 |

**Delta = 14.35ms** against the coordinator's **12.769ms** — from a completely separate
instrument, on a different file, in a different session. The finding is solid, and the delta is
almost entirely ours (stock nvim does this work in 0.56ms).

The cold run is the important number and it is much larger than the warm median:
`run1 total=203.27ms`, of which `BufEnter=202.8ms` and `Syntax=74.5ms`.

### 1.3 Which events actually fire — and the coordinator's list is slightly off

Per-event stamps, first (cold) open of a `go/pkg/mod` Go file, ours:

```
EDIT_TOTAL 58.018          (single-shot, first open in a fresh session)
  + 18.256  BufReadPre
  + 37.256  Syntax        ← DOMINANT
  +  0.006  FileType      ← ~0, as the coordinator implies
  +  2.279  BufReadPost
  +  0.182  BufEnter
  +  0.039  EDIT_RETURNED
```

**`FileType` costs 0.006ms — effectively nothing.** The coordinator names
"FileType, BufReadPost, LspAttach, treesitter" as the cost of this phase. Measured, the ranking
is different:

1. **Syntax — 37.3ms of 58ms (64%).** Not on the coordinator's list at all, and it is the
   single largest item. This is Vim's own syntax engine, not treesitter.
2. BufReadPre — 18.3ms (the file read itself, from `go/pkg/mod`).
3. BufReadPost — 2.3ms.
4. FileType — 0.006ms.
5. **LspAttach did not fire in my headless run** (`lsp: 0` — gopls does not attach headless to
   this file). So **the coordinator's LspAttach contribution is NOT MEASURED by me**; on a real
   consumer session it fires and adds more.

`is_go_lib` returns true for this path (`is_go_lib: /go/pkg/mod/`), which only suppresses
inlay hints (`lua/core/event.lua:74-80`) — LSP itself still attaches.

### 1.4 Scaling to a consumer HDD + Defender + slow CPU — reasoned, not measured

The 12.77ms decomposes into parts that scale **differently**, and this matters because the
consumer's "500ms–5s" is ~40–400× larger — a factor that is impossible to attribute to a
uniform slowdown.

| component | measured (SSD) | scales with | honest multiplier for a weak HDD box |
|---|---|---|---|
| file read from `go/pkg/mod` | 18.3ms (BufReadPre) | **disk** | 5–50× if the module cache is on a slow/network disk → 90–900ms |
| Syntax | 37.3ms | **CPU** (regex VM) | 3–10× on a weak CPU → 110–370ms |
| treesitter parse | (not isolated here; 4–19ms measured in doc 15) | **CPU** | 3–10× → 12–190ms |
| BufReadPost / autocmd fanout | 2.3ms | CPU + FS | ~3× → 7ms |
| **gopls attach** | **NOT MEASURED (headless)** | **CPU + process spawn + disk** | **the largest single suspect — see §4.1** |

**A uniform "5× slower machine" does not explain 500ms–5s from a 14ms warm delta.** It needs at
least one component that is orders of magnitude worse, not 5×. The honest answer: the 89% share
is right, *but the scaling is not uniform*, and the one component nobody measured — **gopls
attaching to a `pkg/mod` buffer, cold** — is the strongest candidate for reaching seconds. A cold
gopls must load the module graph (`go.mod`, `go list`) and parse the target package; on a slow
disk with a large module cache that is seconds, not milliseconds. This is consistent with the
owner's intuition ("gopls probably isn't to blame") being *directionally* right about the warm
path while the cold path may still be gopls-dominated.

**НЕ ИЗМЕРЕНО:** anything on Windows/HDD. The multipliers above are reasoning from which
subsystem each part belongs to, not measurements.

### 1.5 What else rides in this phase that the coordinator did not name

- **`gitsigns` on `BufReadPost`** — spawns git and stats the worktree. On a slow disk with a
  large repo, real. Measured in doc 15: attach is synchronous on the default profile
  (`gitsigns.lua:22`).
- **The `distro.loader` lazy-load drain on `BufReadPost`** — up to 11 plugins were in
  `loader.loaded` after a Go open in doc 15; a module *still arriving* inside this window is
  charged to `response_to_cursor`.
- **`_G._statusline` on `BufEnter`/redraw** — evaluated on every repaint of the new buffer.
- **`spellfile`/`fold`/`matchparen`** on the new buffer (Netrw-era runtime plugins).

---

## 2. `452c6f1` — correct de-blocking, but it has a real regression

### 2.1 The transition itself: correct

`vim.fn.systemlist({...})` → `vim.system({...}, { text = true, timeout = 10000 }, cb)`.
`lua/keymap/pick.lua:75-118`. Verified: **no blocking call remains on the keypress path.** Full
audit of the config:

```
$ grep -rnE 'vim\.fn\.system|fn\.systemlist|jobsync|fn\.jobwait|io\.popen|os\.execute|fn\.jobstart' lua
lua/keymap/pick.lua:71:   -- (a comment mentioning the old call)
→ no live call sites
```

Every remaining `vim.system(...):wait()` is a **blocking** call, and all of them are off the
keypress path:

| site | reachable from | blocking? |
|---|---|---|
| `core/health.lua:90,309,365` | `:checkhealth core` only | yes, but not on keypress |
| `distro/install.lua:182,476,488` | `:DistroInstall` (consent-gated) | yes, by design |
| `distro/tools.lua:29,130,266,286` | `:DistroTools` (consent-gated) | yes, by design |
| `distro/bench.lua:23` | `:DistroBench` | yes — analysed in doc 16 |

**This is a clean result: the keypress path has zero blocking process calls.** Nothing in §4
should be a `system()`.

### 2.2 The regression the commit message does not mention

`lib_grep_fallback` returns `true` to mean "handled", and the caller does:

```lua
if not lib_grep_fallback(req_buf, req_symbol) then
    vim.notify("[lsp] no results for " .. scope, ...)
end
```

Before the change, `true` meant "results are already in quickfix". After it, `true` means "a
scan was launched" and **the result may never arrive**. The callback then does:

```lua
if not obj or obj.code ~= 0 or not obj.stdout or obj.stdout == "" then
    return                      -- <-- silent: no notify
end
```

Consequences on a consumer box:

1. **Silent failure.** rg missing, rg failing (exit 2 on a non-UTF-8 cache file — the very case
   the commit mentions), timeout at 10s, or genuinely zero matches ⇒ the user pressed `gd`,
   got no jump, **no quickfix, and no message at all**. Previously a failed `systemlist` returned
   `false` and the user got `[lsp] no results for definition`. This is a straight UX regression
   and it is invisible in a smoke test because nothing throws.
2. **Focus theft, asynchronously.** `vim.cmd("copen")` now runs in a callback, potentially
   seconds after the keypress and while the user is typing. The same function goes to explicit
   trouble to avoid exactly this (`lua/keymap/pick.lua:155-158`: "курсор ушёл, пока gopls думал:
   не телепортируем, показываем пикер" / "result arrived after you moved"). The async fallback
   **violates the anti-surprise rule the surrounding code enforces.**
3. **`lib_searching` can latch on.** It is set `true` before the call and cleared only in the
   callback. If `vim.system` itself raises (binary vanished between the `executable()` check and
   the spawn, resource exhaustion), the flag is never cleared and **every later lib fallback is
   permanently disabled for the session**.
4. Minor: `lib_searching` is module-global, not per-buffer — two `gd` presses on two different
   packages in quick succession: the second is silently dropped, and the user is not told.

None of these are fatal, but #1 and #2 are user-visible on exactly the consumer profile this
release targets. **Suggested (not applied — no code changes permitted):** notify on the failure
branches, and suppress `copen` if the cursor moved since the keypress.

### 2.3 On the withdrawn attribution

I agree with the withdrawal. The scope is one package directory, not the whole module cache —
`lua/keymap/pick.lua:90` passes `dir` (the file's own directory), not the cache root, and my
own trace instrumentation in doc 15 recorded a `lib_grep_fallback` scope of ~2.5MB / 222 files.
`rg` over that on an SSD is ~10ms. **It cannot produce 500ms–5s by itself.** Keeping the change
as de-blocking a genuine `vim.fn.systemlist` is correct; counting it as the cause is not.

---

## 3. `6fa8fde` — two of three confirmed, one mischaracterised, one defect left in

### 3.1 (a) `M.sub` wrote the elapsed time as a detail string — **CONFIRMED**

Before: `M.log(name .. "/" .. stage, nil, detail)` — `duration_ms = nil`.
After: `M.log(name .. "/" .. stage, ms, detail)`.
`git show 6fa8fde -- lua/distro/trace.lua` shows exactly this, and the new comment states the
consequence correctly. Sub-stages had `dur=nil` ⇒ `dur or -1` ⇒ sorted to the bottom of a
longest-first list. **Real defect, correctly fixed.**

### 3.2 (b) "total" measured only the synchronous dispatch — **CONFIRMED**

Before: `trace.log(ev, el(), "total (requests: "..n..")")` immediately after `pcall(orig)`
returned. `M.wrap_pick` restores `vim.lsp.buf_request` and returns the shim's result; the shim
(`lua/keymap/pick.lua:145`) calls `vim.lsp.buf_request` and returns immediately. So `el()` at
that point covers only the send. The fix moves the honest end-to-end row into the response
handler, after `handler(...)` returns — which is after the jump. **Real defect, correctly
fixed**, and the "dispatch only" rename is the right call: one name, one meaning.

### 3.3 (c) "sorting went by the row's own write duration" — **MISCHARACTERISED**

The pre-fix sort was:

```lua
table.sort(rows, function(a, b) return (a.dur or -1) > (b.dur or -1) end)
```

That already sorted by the `dur` **column** — the right column. The bug was that the column was
*empty* for sub-stages (a) and *wrongly small* for the total row (b). So (c) is not a third
independent defect; it is a restatement of (a)+(b). The fix to the sort itself (adding the
`seq` mode) is still a genuine improvement, but calling the old sort wrong is not accurate.

### 3.4 The defect the fix LEFT: `dur` now holds two incompatible meanings

This is the real answer to "не осталось ли где-то ещё, где сортировка врёт?": **yes.**

- `M.span` writes **own cost** into `dur` (`lua/distro/trace.lua:107`: `dt = hrtime - t0`).
- `M.sub` now writes **cumulative elapsed since the span start** into `dur`
  (`lua/distro/tracehooks.lua:47`: `el()` returns `hrtime - t0` where `t0` is the span start).

Both are the same column, and `M.rows` sorts them together
(`lua/distro/traceui.lua:116`). So a sub-stage at 14.353ms cumulative is ranked as if it were a
14.353ms self-cost event, and the headline line **"slowest event: X ms"**
(`lua/distro/traceui.lua:209-215`) mixes both semantics and will happily name a cumulative
sub-stage as the slowest event in the session. The displayed value is not wrong — the *label* is.

Worse, the detail view **actively mislabels it**: `lua/distro/traceui.lua:318` prints
`"(own dur %.3f)"` for a sub-stage, where that number is cumulative, not own. That is the one
place where the viewer now tells the reader something untrue.

### 3.5 Do instant events (`dur=nil`) get lost? No — but they do sort to the bottom

An instant event cannot be slow, so bottoming in a "slowest first" list is defensible. They
remain visible in `seq` mode, and the detail view prints `n/a (instant event)`
(`lua/distro/traceui.lua:291`). **Nothing is lost.** The three-mode question: a third global sort
is *not* needed. What is needed is a per-span **phase breakdown** (the three phases of one `gd`
side by side, with deltas) — the data is already correct, it just is not the shape the list view
gives you. In `time` sort, the three phases of a single span are separated from each other and
interleaved with other spans; in `seq` sort they are contiguous but a slow hop is visually buried.
The current answer to "which phase hurt" is "open the detail view of the TOTAL row" — which is
reasonable, and the detail view's delta math is correct (`traceui.lua:307-313` computes
`x.at - prev_at`, which for cumulative sub-stages *is* the phase cost).

**UX judgement:** sorting by cumulative `at` (as opposed to `dur`) is not offered and should not
be — `at` is an absolute position, and a list sorted by it is just a slightly-off chronological
view. The `time`/`seq` pair is the right pair.

---

## 4. What else can produce 500ms–5s on the keypress path (not found by the coordinator)

Ordered by my estimate of likelihood on the target profile. **None of these is measured on
Windows — all are code-path findings with a stated verification method.**

### 4.1 gopls attaching to a `pkg/mod` buffer, cold — highest suspicion
`lua/core/event.lua:48-83` (LspAttach) + `lua/modules/configs/completion/servers/gopls.lua`.
Every new buffer gets a gopls client; for a file under `go/pkg/mod` the server must load the
module graph. Cold, on a slow disk, with a large module cache, this is **seconds**. The
`is_go_lib` guard only disables inlay hints. **How to verify:** `:DistroTrace on`, press `gd`
into a lib file on the target machine, read the `LspAttach` row's `dur`. That is a 2-minute check
and it is the single highest-value measurement still missing.

### 4.2 The file read itself out of the module cache
`BufReadPre = 18.3ms` measured on an SSD for a 3,080-line file. If a consumer's `go/pkg/mod`
lives on a spinning disk or a network share, **this one number is 5–50× worse** and it is on the
critical path of every jump into a library file. **Verify:** time `:e <pkg/mod file>` with the
cache on local vs network storage.

### 4.3 gitsigns on `BufReadPost`
`lua/modules/configs/ui/gitsigns.lua:22` — `auto_attach` is synchronous unless turbo is on.
gitsigns spawns git and stats the worktree on every open. On a big repo on an HDD, real.
`watch_gitdir.interval = 5000` (`gitsigns.lua:37`) adds a 5s background stat loop.
**Verify:** `:DistroTrace on`, open a file, read the gitsigns rows; or run with `NVIM_TURBO=1`
and compare.

### 4.4 `executable()` on the open path — 15 calls per `:edit`
Measured in doc 15: 3 at startup, **15 on the `:edit` path**. Each is a `$PATH` scan. On Windows
with a long `%PATH%` and Defender on every `CreateFile`, 15 per open is the single most
plausible *repeatable* cost. **Verify:** count with an `executable` hook and time it on Windows;
a session-scoped positive cache (doc 15 E-2) is the fix.

### 4.5 CursorHold fan-out on an idle cursor
Measured: 3 `CursorHold` + 2 `CursorHoldI` autocmds; at `updatetime = 1000`
(`lua/core/options.lua:81`) that is up to **300 invocations per minute** of doing nothing, each a
candidate lazy-load trigger (`lua/distro/loader.lua:347`, `flash`, `which-key`).
**Verify:** a synthetic pty run that idles for 60s and counts fired autocmds.

### 4.6 Large-buffer work: treesitter + Syntax
`Syntax` is 64% of the open path measured in §1.3. For a file just under the large-file guard
(`lua/core/settings.lua:92` = 10,000 lines) full treesitter still runs. **Verify:** open a
9,000-line file and read the Syntax/TS rows.

### 4.7 (ruled out) blocking process calls on the keypress path
See §2.1 — there are none. Do not spend time here.

---

## 5. Release readiness — honest assessment

**Ready to ship:**
- `570b66c` (grepprg) — correct, tiny, platform-correct, and it *fixes* a real Windows bug
  (`:grep` was broken because `/dev/null` does not exist under cmd.exe). No risk.
- `7c7a9fb` (dap/lint on demand) — correct mechanism (the loader's command-stub), measured by
  the coordinator at 302→256 modules after settle with the first frame unchanged. My doc 15
  reached the same conclusion independently and measured the same ~60 modules.
- `6fa8fde` — the two real defects are genuinely fixed and the tool is finally able to answer
  "what is slow". The `dur`-semantics issue in §3.4 is a labelling defect, not a wrong number.

**Blocking / should fix before a consumer release:**
1. **`452c6f1`'s silent-failure path (§2.2)** — a consumer whose `gd` finds nothing gets *no
   feedback at all*, and `copen` can steal focus mid-typing. Both are on the exact profile this
   release targets. Not a crash, but it is a worse experience than the bug it fixed.
2. **The `gd`-into-`pkg/mod` path is still unexplained for 5s.** §4.1 (gopls cold attach) is the
   leading candidate and is **unmeasured on the target hardware**. Shipping a fix aimed at a
   10ms rg scan while a seconds-long gopls attach sits unexamined would repeat the error the
   coordinator just corrected.

**Recommended next step, highest effect per unit of effort:**
Send the consumer **one command** that answers §4.1 and §4.2 in their environment — the
`:DistroTrace` machinery now works, so `:DistroTrace on`, press `gd` into a `pkg/mod` symbol,
`:DistroTrace open time`. That returns `LspAttach`, `Syntax`, `BufReadPre` and the gopls
round-trip as separate rows **on the machine that actually has the problem**. Everything in this
report about the consumer profile is inference; this one command replaces the inference with
data, and it is a single keystroke more than what they already did to produce the 9–14ms log.

---

## 6. What is NOT measured here

- Any Windows/HDD/Defender number. All multipliers in §1.4 are reasoning, labelled as such.
- `LspAttach` cost — gopls does not attach headless in my runs, so this row is absent from all
  my measurements. **It is the gap that matters most.**
- Real cold cache (no sudo → cannot drop the macOS page cache); my "cold" run1 is only
  partially cold.
- The `lib_grep_fallback` end-to-end before/after — reproducing it needs gopls to answer empty
  for a `pkg/mod` symbol, which is a cold-metadata-cache state (the coordinator flagged this
  too; I did not attempt it).
