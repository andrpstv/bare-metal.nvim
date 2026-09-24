# distroManager — Requirements (frozen)

Source: discussion 2026-09-24. This file is the contract. Any behavior change must update it first.

## 1. Goal

Self-contained Neovim distro:

```sh
git clone <config> ~/.config/nvim
nvim   # works offline, zero downloads
```

- Plugins live **inside the repo**: `pack/distro/{start,opt}/<name>` (+ `pack/distro/parser/` for Treesitter `.so`).
- No submodules (they need `--recurse-submodules` + network). Vendored copies, **no `.git` inside plugin dirs**.
- No `lazy.nvim`, no `vim.pack` (we are on nvim 0.11; `vim.pack` is 0.12+ and git-based anyway).

## 2. Zero-auto-network (hard rule)

- **Neovim never downloads or updates anything on its own.**
- Forbidden network triggers: `VimEnter`, `BufReadPre`, `BufNewFile`, `InsertEnter`, `CmdlineEnter`, `CursorHold`, `LspAttach`, `require()` side effects.
- The ONLY network entry points (all via `curl`, all after explicit confirmation):
  `:Distro`, `:DistroInstall`, `:DistroUpdate`, `:DistroClean`, `:DistroCheck`, `:DistroTools`, `:DistroParsers`
  plus keys `I/U/S` inside the `:Distro` UI.
- All of them funnel through `install.lua :: require_consent()` — without `user_confirmed=true` the `curl` path refuses to run (including `--headless`, which additionally needs `--yes`).
- Missing plugin on startup = notify only, no download:
  `[Distro] 'gitsigns.nvim' is missing. Open :Distro and press I to install. Nothing was downloaded.`
- Settings (hardcoded safe defaults, see `core/settings.lua`):
  `distro_auto_install=false`, `distro_auto_update=false`, `distro_confirm="always"`.
- The old auto-clone pattern (`core/pack.lua` → `!git clone lazy.nvim` on startup) is **deleted** with the lazy removal.

## 3. Download method: curl-only GitHub archives

- URL form only: `https://codeload.github.com/{owner}/{repo}/tar.gz/{ref}` where `ref` = full commit SHA or tag.
- Flags: `curl -fSL --proto '=https' --tlsv1.2`.
- No `git`, no `wget`, no `ssh`, no third-party hosts. No silent fallback.
- Corporate environments: same flow against an internal mirror instead of codeload —
  templated URL (`{owner}{repo}{ref}{branch}{token}`), `.zip` support, token from env only,
  `--insecure` explicit with TLS warning. Full spec: `06-corporate-mirror.md` (Step 10).
- Atomic install: `tmp/distro/<name>.tar.gz` → unpack to `tmp/distro/<name>.unpacked` → `tar xzf --strip-components=1` → sweep `/.git*`, `tests/`, `docs/` (optional per manifest `strip`) → `rename tmp → pack/distro/{start,opt}/<name>`. Old working dir untouched until success.
- Every install/update writes `distro-lock.json` (see §5).

## 4. Scope: all plugins at once (26 vendored + manager itself)

From `lazy-lock.json` (27 entries) minus `lazy.nvim` itself = **26** to vendor.
`kind=start` (eager, minimal for startup): `black-metal-theme-neovim`, `nvim-web-devicons`.
`kind=opt` (lazy via `packadd`): everything else (see `01-architecture.md` + `manifest.lua`).

Build hooks (also confirm-gated, status `build-needed` if output missing):
- `LuaSnip`: `make install_jsregexp`
- `nvim-treesitter`: parser compilation (see §6)
- `go.nvim`: `:GoInstallBinaries`

## 5. Version tracking

`distro-lock.json` replaces `lazy-lock.json`. Per entry:

```json
"gitsigns.nvim": {
  "repo": "lewis6991/gitsigns.nvim",
  "ref": "8d79f2410c76e62b92e51c28c82e28c1c5a3daeb",
  "tarball": "https://codeload.github.com/lewis6991/gitsigns.nvim/tar.gz/8d79f24...",
  "installed_at": "2026-09-24T...",
  "size_kb": 0,
  "kind": "opt",
  "previous_ref": null
}
```

Same shape for `tools/*` (e.g. `tools/gcc`, `tools/fzf`) and `parsers/*` (e.g. `parsers/go`).
UI columns: `name | version(ref-short) | status | size`.
Statuses: `installed / missing / outdated / corrupted / build-needed`.
Rollback: `previous_ref` powers `R revert`.

## 6. Tools & Treesitter via the same pipeline

- `tools.lua` table: `fzf`, `rg`, `gcc/cc`, `make`, `go` (+ per-lang compilers later).
- Each: `check = vim.fn.executable()`, per-OS hint, optional curl fallback for sanctioned release archives.
- `gcc` special case (honest UX):
  - Linux: `sudo apt install gcc make` / distro equivalent, or curl portable toolchain into `tools/gcc/` (config-local, PATH prepend for builds only).
  - macOS: `curl` **cannot** provide Apple CLT → show `xcode-select --install` + `brew install gcc make`, offer `[Copy command]`.
  - Windows: `winget install ...` or curl `w64devkit` archive into `tools/gcc/`.
- `treesitter.lua`: language-agnostic. Source list = `settings.treesitter_deps` (20 langs: bash c cpp css go gomod html javascript json jsonc latex lua make markdown markdown_inline rust typescript vimdoc vue yaml). Per lang: curl parser source tarball → `cc` build → `.so` into `pack/distro/parser/` → version recorded. Without `gcc` → do not download parser, route user to Tools.
- Without `gcc`, parser install is blocked with guidance (never silent fail).

## 7. UI: friendly, English, lazy-parity

- One entry point: `:Distro` float (sections `Missing / Installed / Outdated / Tools & Parsers`), keys `I U C S X D R ? q` (see `02-ux-english-copy.md`).
- Research baseline: `lazy.nvim` `lua/lazy/view/{render,sections,float,text}.lua` + `manage/` + `status/state` — copy the *idea* (sections, float, keys, statuses), not the code.
- All destructive/network actions show preview first: `old → new + size + url + dest`, per-item or bulk `[y/N/all/details]`.
- Errors always carry a next step. No bare `failed`.
- Audience: many consumers incl. non-experts → `:checkhealth distro`, `?` help inside UI, dashboard hint on first run with empty `pack/`.

## 8. Portability

- macOS arm64 + Windows x64 (+ Linux best-effort).
- `curl`/`tar` presence checked (`curl.exe` + builtin `tar` on modern Win/`pwsh`).
- `.so` parsers are per-OS → **not committed** by default; installed on demand with confirm. Only Lua sources are committed.
- Paths via `stdpath("config")`, never hardcoded `$HOME`.

## 9. Repo hygiene

- Commit `pack/distro/{start,opt}/*` working trees (no `.git` inside).
- Do NOT commit: `tmp/distro/`, `*.tar.gz`, `.so` (default), `distro/.lock`, logs (`*.log` already ignored? verify).
- Keep `lazy-lock.json` as migration reference until green offline test, then delete.
- Delete `core/pack.lua` lazy bootstrap at the end (replaced by `core/distro.lua`).

## 10. Acceptance

- [ ] `git clone` to temp dir, airplane mode, `nvim` starts with zero network syscalls for plugins.
- [ ] `:checkhealth distro` green (minus knowingly-missing optional tools with hints).
- [ ] `:Distro` shows 26 rows with versions.
- [ ] `event=CursorHold` (gitsigns/flash), `cmd=FzfLua/Trouble/Diffview*`, `ft=go` (go.nvim/lint/dap) all load via `packadd` offline.
- [ ] `curl` install of one plugin + one parser + `tools` hint verified on mac; Windows path smoke-tested.
- [ ] Startup time not regressed vs lazy baseline (`startup.log` comparison).
