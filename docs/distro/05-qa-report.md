# distroManager — QA report (2026-09-24, migration + vendoring)

Method: real `nvim` + real config + real PTY via `tui-test` (sessions qa/qa2/qa3),
per `neovim-tui-qa` skill. No `--headless` for interactive checks.

## Environment

- Neovim 0.11.4, macOS, terminal 80x30 (plus 100x28 resize).
- 26/26 plugins vendored in `pack/distro/{start,opt}` via curl tarballs, no `.git`, 29MB.
- Parsers (21 `.so`) copied from previous working lazy tree; LuaSnip jsregexp submodules
  fetched via curl + `make install_jsregexp` (see manifest NOTE for SHAs).

## Passed

- Cold start: no errors, no messages, custom statusline renders.
- `:DistroCheck` → `0 item(s) need attention`. `:Distro` UI → 26 rows, versions, 0 missing.
- Go file: `ts=true` (treesitter parser active), `lsp=1` (gopls attached after `go.mod` init).
- Completion E2E: `CmpStatus` → buffer/path/luasnip ready from boot, `nvim_lsp:gopls`
  after first InsertEnter; manual `cmp.complete()` popup with `[BUF]` items, icons, border.
- `:FzfLua files` stub → on-demand load, picker + preview renders, Esc cancels.
- `:Trouble` stub → real command runs (mode picker renders).
- Gitsigns: loads on CursorHold, attaches in git repo (`head=main`, branch in statusline).
- `:ConfigHealth` → theme khold OK, 5/5 keymaps, `Plugins (distro): 26 installed, no errors`,
  LSP servers/fzf/rg/cc OK. (pynvim warning is pre-existing env, unrelated.)
- Startup wall time: 125ms empty, 174ms with Go file.
- Resize 100x28: no corruption (one harness font warning for ⚠️ glyph, cosmetic).
- `distro-lock.json` status: ALL 26 INSTALLED. No network on boot/open (notify-only).

## Bugs found & fixed (code)

1. **Missing `package.path` for short requires** — `require("completion.signature")` failed
   (`core/pack.lua:append_nativertp` did this under lazy).
   Fix: same paths appended in `distro.loader.boot()`. Evidenced by BufReadPre error
   in session qa, gone after fix.
2. **`after/plugin` not sourced by `:packadd`** — cmp sources self-register there
   (`register_source`), lazy.nvim handled it. Symptom: `:CmpStatus` → all 4 sources
   "unknown", `ENTRIES=0`. Fix: `distro.loader.source_after()` after every packadd.

## Known limitations (not bugs)

- `nvim_lsp` source appears only after first InsertEnter (upstream cmp-nvim-lsp design).
- `:Trouble diagnostics` with zero/edge state may render nothing (same pinned commit as lazy setup).
- Parsers/`.so` + jsregexp build outputs are machine-local (gitignored); fresh clones need
  Step 6 (`:DistroParsers`, `:GoInstallBinaries`, make) — documented in 00/03.
- Dead lazy code intentionally kept: `lua/core/pack.lua`, `lua/modules/plugins/*.lua`
  (user has uncommitted DAP experiment in `plugins/lang.lua`). Removal = approved Step 8.
- `lazy-lock.json` kept as migration reference.

## Not tested

- Windows paths (`curl.exe`/bsdtar/`winget` hints), offline airplane-mode boot,
  `:DistroInstall` curl path in UI (only `install_one` logic reviewed, canary was manual script),
  DAP triplet usage (`:Dap*`), diffview, large-file guard interplay.

## Round 2 (2026-09-24, Steps 5/6/8/10)

- `:DistroInstall nvim-web-devicons --yes` end-to-end (rewritten argv-quoted path):
  OK, lock records real `size_kb=237`, token-free tarball URL.
- Mirror resolution (env-driven): github mode → codeload targz; corporate template →
  `…/archive/refs/heads/main.zip`, `archive=zip mirror=true`, token redacted in URL/log/lock.
- fzf release URL resolves (`darwin_arm64.tar.gz`); corp mode honestly refuses release
  assets without explicit `tool.url`.
- Parser source resolves via vendored lockfile (`tree-sitter-go 5e73f47`).
- TUI: `:Distro` shows `Source:` line; `:DistroMirror status` OK; `D` details OK.
- lazy bootstrap deleted (`core/pack.lua`, `modules/plugins/*`); DAP triplet lives on in
  `manifest` (nvim-dap/go/ui/nio). `scripts/install.*` + README updated.
- Not re-tested this round: full `:DistroInstall --all` bulk, `U/C/S/R/X` keys with
  real drift (no drift exists: 26/26 installed), Windows execution, airplane-offline.

## Round 3 (2026-09-24, safety + mirror menu)

- Unified redacted Source block in all four download previews (plugins × bulk,
  `:DistroInstall`, tools, parsers); duplicate `insecure_suffix` helpers removed.
- Guards verified headless: github URL passes, `http://` refused, token userinfo
  redacted (`https://<redacted>@host`), `host_of` handles `user:pass@host:port`.
- Corporate resolution via env: branch `.zip` URL, `archive=zip mirror=true`,
  `--insecure` detected; fzf release URL correct in github mode, honest refusal in
  corp mode without explicit `tool.url`.
- TUI: `M` opens Mirror submenu (mode/template/args/token/hosts + hints);
  `e` with empty template refuses cleanly; `b` returns to main float.
- `:DistroInstall nvim-web-devicons --yes` re-ran through rewritten path: OK,
  `size_kb=237` recorded, lock valid.
- Still open: Windows execution, airplane-offline, bulk `--all`, drift-based U/R/X.

## Round 4 (2026-09-24, Step 11 catalog & binaries)

- 10 catalog pins resolved via API (mini.nvim is a monorepo: vendored whole, 1.9MB).
- mini.nvim end-to-end: vendor → loader.load → config → `<leader>mf` opens mini.pick
  files picker with icons and `Files (rg)` (TUI screenshot). First attempt failed on
  leader timeout in the test harness (unrelated to code).
- Found & fixed: `install.source_lines` rendered `raw` binaries as `.tar.gz`.
- `:DistroBinaries` menu: detects installed (gopls✗ dlv✗ staticcheck✓ lua_ls✓ stylua✗
  shfmt✗ golangci✓ bashls✓ marksman✗) with versions; shfmt installed via key `6`
  (confirm → curl → chmod +x → lock `tools/shfmt`, 3312KB).
- 4 release asset patterns probed HTTP 200 (darwin/arm64): lua-ls 3.19.1, stylua v2.5.2,
  shfmt v3.14.1, golangci-lint v2.14.0.
- Catalog triggers silent while uninstalled; `:DistroInstall` auto-activates after install.
- Open: Windows execution, `go`-method installs, corp-mode tool URLs, bulk `--all`.

## Round 5 (2026-09-24, upstream markers)

- User confusion: X reported "updates available upstream" while rows said "up to date".
  Root cause: two axes — row status = lock-vs-manifest pin (vendored matches pin),
  X = manifest pin vs upstream HEAD. By design (pins are deliberate), but invisible.
- Fix: `install.read_remote_cache/remote_newer` + UI shows `up to date · ↑<sha> upstream`
  per row, header `↑N upstream (X)`, legend line, `outdated` relabeled to
  "differs from pin — press U", D-details shows upstream + bump recipe.
- Verified headless + TUI screenshot (5 upstream markers from existing cache).

## Round 6 (2026-09-24, fzf-lua → mini.pick)

- Removed: manifest entry, configs/tool/fzf.lua, pack/distro/opt/fzf-lua, lock entry,
  fzf binary tool entry; keymaps/health/settings repointed. Only a comment mentions fzf-lua.
- mini.nvim promoted catalog → core (26 plugins). Helpers `_pick/_pick_extra/_pick_lsp`
  (+jump1)/`_pick_grep_visual`; LSP via MiniExtra.pickers.lsp, zero new deps.
- TUI verified: <leader>ff files, <leader>fp live grep (rg), gd jump1 → 5:6,
  gr references picker (2 entries), :ConfigHealth green (picker mini.pick, 5/5 keymaps, 26/26).
- Open: gi/gy/gO/fw pickers (same code path as gr — low risk), visual grep, :DistroBinaries
  after tools-table change.

## Round 7 (2026-09-24, dependency visibility audit)

- Cross-check manifest(26+9) vs lock vs disk vs rtp vs loader.loaded: 0 problems —
  no dupes, no missing deps, no orphans, no ghost commands (FzfLua gone), no rtp strangers.
- Runtime on Go file: 22 loaded, 4 correctly lazy (diffview/trouble/mini/plenary).
- Gap fixed: UI hid dependencies. Rows now show `· N deps` / `[provides]`
  (e.g. `nvim-cmp … up to date · 6 deps`, `mini.nvim … [mini.pick, mini.extra]`);
  D-details gained deps/provides/config/triggers block.
- mini.pick case: entry IS the monorepo dir (mini.nvim), functionality = modules
  mini.pick+mini.extra inside it (new `provides` field documents this); deps=0 correct.

## Round 8 (2026-09-24, production UI + full key matrix)

- UI is cursor-aware: line map (entry/catalog/header), per-row i/u/d/Enter/r/x,
  bulk I/U/C/S/X/D/R, B binaries, M mirror, ? help float, cursor-preserving re-render.
- Matrix (TUI): open/q/Esc, j-navigation, Enter+D details, i-hint on installed,
  ? help, B→binaries→q (floats=1, no stacking), M→mirror→b, x single plenary check
  (confirm → matches HEAD → reopen keeps scroll), R lists only web-devicons, C/U/S
  no-op messages, resize 100x28 clean.
- Live: cursor-`i` on catalog oil.nvim → unified Source preview → installed (136KB) →
  row ○→● → `:Oil` opens (auto-activate). Tree restored afterwards (dir + lock key removed).
- Bugs fixed: manifest syntax error from python edit (missing commas) — plus M.open
  pcall guard so a broken manifest shows one friendly error, never a traceback;
  gopls/dlv `version` (no dashes) ver_args; binaries menu blank-version display.

## Round 9 (2026-09-24, frontend-grade UI)

- Grid: name column sized to content (cap 32), fixed ver column, separators,
  status-colored dots (green/yellow/red via linked hl groups), upstream marker
  highlighted, headers as Title, cursorline + nowrap, width clamped to terminal,
  footer split into two fittable lines.
- Live float title follows cursor ("Distro — <plugin>" / section name).
- New `o` key opens repo page via vim.ui.open (pcall-guarded).
- TUI verified: render, colors, live title, `o` without crash.

## Round 10 (2026-09-24, refactor P0–P3 verification)

- Startup: 49ms empty / 141ms with Go (was 125/174). 18/18 modules load headless.
- Big file (1MB/20k lines JSON): zero errors, `large=true ft=off lsp=0`, notify shown.
- Found & fixed live: `foldmethod` set via `vim.bo` (window-local!) → `vim.wo`;
  loader two-phase `loading[]` short-circuit skipped ALL packadd (nothing on rtp) →
  separate `packing`/`finishing` sets; my own `type()~="function"` guard rejected
  nvim-cmp's callable-table `setup` → `__call` check; `table.unpack` missing on
  LuaJIT → local fallback; nvim-lint `try_lint(names, opts-table)` takes no bufnr →
  skip-if-switched instead; `vim.uv.kill` liveness probe unreliable → age-based stale lock.
- Hang test (`kill -STOP gopls` + `gd`): UI responsive, `[lsp] slow response` after 2s
  (async + watchdog; added after first silent pass).
- Save storm (3× `:w`): 0 errors. Picker/binaries/UI/resize: green.
- Diag cache: `●[ 1 ]` appears after InsertLeave via DiagnosticChanged (no per-redraw get).
- Lock crash matrix: single-corrupt recovers from .bak; double-corrupt → 26 `corrupted`;
  20-min stale `.lock` reclaimed + removed on release.
- Open: Windows execution (code-reviewed only), `go`-method installs live, corp URLs live.

## Round 11 (2026-09-24, async streaming A + B1/B2/B3/B5/B6)

- TUI time-to-content (daemon-restarted A/B, 2 runs each): clean 157/157ms,
  ours-deferred 151/151ms, ours-forced-sync 218/213ms. Paint at parity with clean.
- Headless wall (sync path by design): clean 40/43/45 vs ours 71/152/132
  (empty/go/big). NVIM STARTED 102ms (was 148).
- LSP (cold gopls, best-of-3 RTT): attach ours 53ms vs clean+minimal 32ms
  (+21ms one-time LspAttach chain); definition/references RTT 0/0ms both.
- Races: cold `:w` + `gd` within 2s — graceful, zero tracebacks; STOPped gopls
  + `gd` → responsive UI + `[lsp] slow response` watchdog at 2s (async + defer).
- TUI flicker: highlight + gopls present by ~600ms; save storm 0 errors;
  diag cache shows `●[ 1 ]` post-InsertLeave; picker/binaries/resize green.
- Found & fixed live: `loading[]` short-circuit skipped ALL packadd (nothing on rtp);
  `__call`-table setup; LuaJIT `table.unpack`; nvim-lint opts shape; kill-probe;
  manifest python-edit commas; `ver_args` for go tools.
- `NVIM_DISTRO_SYNC=1` added (deterministic sync override for CI/scripts).

## Round 12 (2026-09-24, medium package: gopls flags, NVIM_MINIMAL, :DistroBench)

- 1.1 theme split SKIPPED honestly: black-metal setup costs 2.6ms and is
  inseparable from the colorscheme itself (setup == colors). No code change.
- gopls diet flags added (codelenses table, semanticTokens, completeUnimported,
  debounce, fieldalignment) — all default to current behavior (verified headless).
- NVIM_MINIMAL=1 verified: inlay/signature/codelens/indent off, clean boot.
- :DistroBench (pure Lua, Windows-safe): session age, child-process open times
  (clean vs ours, .txt to avoid gopls noise), in-session gd/gr RTT. TUI-verified
  with screenshot (small +84ms, big +88ms vs clean; RTT 0/0ms).
- sh bench gained --cold (Linux drop_caches, degrades honestly without sudo).
