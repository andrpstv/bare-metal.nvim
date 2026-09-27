# distroManager — Catalog & binaries (Step 11)

> 2026-09-24 update: **fzf-lua удалён полностью**, mini.nvim повышен из каталога в
> ядро (26-й core-плагин). Единственный пикер — mini.pick/mini.extra, ноль внешних
> зависимостей. LSP-пикеры: `gd/gr/gi/gy/gO/<leader>fw` через `MiniExtra.pickers.lsp`,
> файлы/grep/буферы — builtin mini.pick. Бинарник `fzf` из `tools` тоже удалён
> (mini.pick использует rg/git/fd).

`:Distro` is two shops in one: **plugins** (Lua) and **binaries** (LSP, linters, formatters).

## 1. Plugin catalog (`manifest.catalog`)

10 curated on-demand plugins. They are NOT vendored by default, NOT loaded at boot,
NOT in lock status — the `:Distro` Catalog section shows `○/●` by directory presence.

| name | desc | trigger |
|---|---|---|
| mini.nvim | mini.pick picker (+ all mini modules) | `<leader>mf/mg/mb/mh` (guard loads first) |
| telescope.nvim | fuzzy finder | `:Telescope` stub |
| oil.nvim | file manager as buffer | `:Oil` stub |
| toggleterm.nvim | terminal windows | `:ToggleTerm` stub |
| which-key.nvim | keymap popup | CursorHold |
| todo-comments.nvim | TODO highlights | BufReadPre |
| lualine.nvim | statusline (replaces builtin) | after install |
| indent-blankline.nvim | indent guides | BufReadPre |
| neogit | git UI | `:Neogit` stub |
| nvim-tree.lua | file tree | `:NvimTreeToggle` stub |

Flow: `:DistroInstall <name>` (completion included) → preview → download →
**auto-activate** via `loader.load` (config + keymaps/commands work immediately).
Catalog triggers stay silent while uninstalled (no missing-spam on every buffer).

To add one: append `{ catalog = true, name, repo, ref, branch, kind = "opt", … }`
to `M.catalog` + a small `lua/modules/configs/<area>/<file>.lua` (function calling
`load_plugin`), then `:DistroInstall <name>`.

## 2. Binaries (`:DistroBinaries`, `manifest.binaries`)

Separate float: number per row, version probe (or `missing — desc`), `<number>`
installs with confirm, `q` back.

| name | method | notes |
|---|---|---|
| gopls, dlv, staticcheck | `go` | `go install <pkg>@latest` (GOPROXY); verifies binary in PATH |
| lua-language-server, stylua, shfmt, golangci-lint | `release` | curl release asset → `tools/<name>/`; pin or latest-resolved tag; `.tar.gz/.zip/raw`, `strip` where needed; chmod +x on POSIX |
| bashls, marksman | `system` | hint only (npm/brew/winget) — no fake download |

Release assets resolve through the mirror too when the tool carries explicit `url`;
GitHub release API has no corporate equivalent, so corp mode + release-without-url
refuses with a pointer to `tools[].url`. Every install records `bin/<name>` or
`tools/<name>` in the lock. `tools/` contents are gitignored (platform-specific);
reinstall via the menu on a fresh clone.

Asset placeholders: `{ver} {vernov} {os} {arch} {ext} {exewin}`, with per-tool
`asset_os`/`asset_arch`/`asset_ext` maps. All four release patterns verified
HTTP 200 (darwin/arm64, round-3 QA).
