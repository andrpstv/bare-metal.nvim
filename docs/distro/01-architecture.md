# distroManager — Architecture

```
~/.config/nvim/
├── distro-lock.json            # versions (replaces lazy-lock.json)
├── pack/distro/
│   ├── start/<name>/           # eager: theme, devicons only
│   ├── opt/<name>/             # everything else, via `packadd`
│   └── parser/*.so             # built parsers (NOT committed by default)
├── tools/<tool>/               # config-local toolchains (gcc/fzf) — optional, confirm-gated
├── tmp/distro/                 # downloads + unpack staging (gitignored)
└── lua/
    ├── core/distro.lua         # boot loader (replaces core/pack.lua). NO network.
    └── distro/
        ├── init.lua            # user commands :Distro*  (only network entry)
        ├── manifest.lua        # source of truth: 26 plugins + tools + parsers
        ├── lock.lua            # read/write distro-lock.json + status()
        ├── install.lua         # curl → tar → atomic rename. Consent guard.
        ├── loader.lua          # rtp/packadd + event/cmd/ft triggers. NO network.
        ├── ui.lua              # float menu (lazy-parity). Confirm dialogs here.
        ├── tools.lua           # executable() checks + per-OS hints + curl fallback
        └── treesitter.lua      # per-lang parser install via same pipeline
```

## Module contracts

### `manifest.lua` — declarative, no side effects
Each plugin:
```lua
{
  name = "gitsigns.nvim",             -- dir name under pack/distro/{start,opt}/
  repo = "lewis6991/gitsigns.nvim",  -- owner/repo
  ref = "<full sha or tag>",         -- pinned, from lazy-lock.json initially
  kind = "opt",                      -- start = eager, opt = packadd on demand
  event = { "CursorHold", "CursorHoldI" }, -- optional lazy triggers
  cmd = { "Gitsigns" },              -- optional
  ft = { "go" },                     -- optional
  config = "ui.gitsigns",            -- lua module under modules/configs/ to call after load
  build = nil | "make install_jsregexp" | ":GoInstallBinaries" | "treesitter",
  strip = true,                      -- remove tests/docs to keep repo slim
  needs = { bins = { "fzf" } },      -- optional binary requirements
}
```
Also exports `TOOLS` (fzf/rg/gcc/make/go) and `PARSERS` (derived from `settings.treesitter_deps`).

### `lock.lua` — pure JSON I/O + status
- `M.read() -> table`, `M.write(tbl)`, `M.record(name, info)` (sets `previous_ref` automatically).
- `M.status(manifest) -> { [name] = "installed|missing|outdated|corrupted|build-needed" }` by comparing dir existence + `ref` vs lock `ref` + build-output sentinel.
- No network, no notify spam. Used by loader (fast path), UI, health.

### `install.lua` — the ONLY place that runs curl/tar
- `M.tarball_url(repo, ref)`.
- `M.require_consent(opts)` — errors unless `opts.user_confirmed == true`. Headless additionally needs `opts.yes == true`.
- `M.install_one(entry, opts)` — atomic: check curl/tar → download → size check → unpack → sweep `.git*` → rename → `lock.record` → optional `build` (also confirm-gated) → `packadd` if UI open.
- `M.remove_one(entry)` — for `:DistroClean`, also confirm-gated.
- Concurrency: `tmp/distro/.lock` with pid; second caller gets friendly `Another installation is running`.

### `loader.lua` — boot + lazy triggers, ZERO network
- `M.boot()`:
  1. `vim.opt.packpath:prepend(config)` + `rtp` for `pack/distro/*/`.
  2. `packadd` all `kind=start` that exist.
  3. Register `event/cmd/ft` autocmds + `VimEnter`-free user commands that call `packadd` + `config` module.
  4. Missing plugin → `vim.notify_once` with `:Distro` hint. **Return, never download.**
- `M.load(name)` — idempotent `packadd` + run `config` once + cache.
- Used by `core/distro.lua` at startup and by keymaps/commands at runtime.

### `ui.lua` — float, lazy-parity
- Sections: Missing / Installed / Outdated / Tools & Parsers / Help.
- Renders from `manifest + lock.status()`. No network on open.
- Keys: `I install-missing, U update, C clean, S sync-to-lock, X check-remote (only network op, with notice), D diff, R revert, ? help, q quit`.
- Every network key shows `confirm()` preview first (`url/size/dest/version`), supports `y/N/all/details`.

### `tools.lua` — binaries without magic
- `M.check_all() -> { [tool] = { ok, version, hint } }`.
- `M.hint(tool)` per-OS: mac (`xcode-select --install` / `brew install X`), win (`winget install …` / w64devkit curl), linux (`apt/dnf/pacman`).
- `M.install_via_curl(tool, opts)` only for sanctioned archives (fzf releases, w64devkit). gcc-on-mac is guidance-only (honest, see requirements).

### `treesitter.lua` — parsers as data
- `M.installed_langs()`, `M.install_lang(lang, opts)` (needs `cc`; routes to Tools otherwise), `M.install_all(opts)`.
- Output: `pack/distro/parser/<lang>.so` + lock `parsers/<lang>`.
- `.so` never auto-built at startup; large-file guard respected.

### `init.lua` — commands (only network entry)
- `:Distro` (UI), `:DistroInstall [name]`, `:DistroUpdate [name]`, `:DistroClean`, `:DistroCheck`, `:DistroTools`, `:DistroParsers`.
- Each parses `--yes` for headless; otherwise opens confirm UI.
- Registers health: `checkhealth distro`.

### `core/distro.lua` — boot entry
- Requires `distro.loader`, calls `boot()`. Replaces `require("core.pack")` in `core/init.lua` at migration end.
- Creates `ConfigHealth`-adjacent `:DistroHealth` alias (or extends existing).

## Data flow

```
startup: core/distro → loader.boot → packadd start + autocmds (no net)
user:    :Distro → ui.render(manifest + lock.status)
confirm: ui → install.install_one(entry, {user_confirmed=true}) → lock.record
runtime: event/cmd/ft → loader.load(name) → packadd + config (no net)
health:  :checkhealth distro → lock + tools.check_all + parser list
```

## Migration note

`manifest.lua` refs are seeded from `lazy-lock.json` full SHAs. `distro-lock.json` is generated from the same file on day one (see `03-implementation-steps.md` step 2), so versions are byte-identical to today's working setup.
