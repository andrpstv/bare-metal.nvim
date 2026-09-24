# distroManager — Implementation steps

Execution order. Each step ends with a verification. Stop on red.

## Step 0 — Skeleton (this change)

Create without touching boot path:

- [ ] `lua/distro/{init,manifest,lock,install,loader,ui,tools,treesitter}.lua`
- [ ] `lua/core/distro.lua` (requires loader, exposes `setup()`, NOT wired into `core/init.lua` yet)
- [ ] `distro-lock.json` seeded from `lazy-lock.json`
- [ ] `pack/distro/{start,opt,parser}/.gitkeep`, `tools/.gitkeep` (staging lives in stdpath cache)
- [ ] `.gitignore`: add `*.tar.gz`, `pack/distro/parser/*.so`

Verify: `nvim --headless -c "lua require('distro.manifest'); require('distro.lock')" -c "qa"` → no errors; `git status` shows only new files.

## Step 1 — Manifest (26 plugins, refs frozen)

Translate `lua/modules/plugins/{completion,editor,ui,tool,lang}.lua` + `lazy-lock.json` SHAs into `lua/distro/manifest.lua`.
`kind=start`: `black-metal-theme-neovim`, `nvim-web-devicons`. Rest `kind=opt` with `event/cmd/ft/config/build` preserved for the loader.

Verify: `:lua print(#require('distro.manifest').plugins)` → `26`; every `ref` is 40-hex or tag; no `lazy.nvim` entry.

## Step 2 — Lock seeding

One-off: generate `distro-lock.json` from `lazy-lock.json` (repo → ref → tarball URL, `installed_at=now`, `kind` from manifest). Keep `previous_ref=null`.

Verify: `python3 -m json.tool distro-lock.json` parses; `diff <(jq -r keys)` covers all 26.

## Step 3 — Loader (offline boot)

Implement `loader.boot/load` + `core/distro.lua`. Wire behind a flag first:

```lua
-- core/init.lua (temporary)
if vim.env.NVIM_DISTRO == "1" then require("core.distro").setup()
else require("core.pack") end
```

Verify matrix (with `NVIM_DISTRO=1`, airplane mode):
`nvim --startuptime /tmp/a.log` opens; `:lua require('distro.loader').status()` shows missing (not errors); triggering `FzfLua` with vendored dir present loads via `packadd`.

## Step 4 — Installer (curl, confirm-gated)

Implement `install.tarball_url/require_consent/install_one/remove_one` + tmp lock. Test on ONE canary plugin (`nvim-web-devicons`, small):

```vim
:DistroInstall nvim-web-devicons
```

Verify: dir appears at `pack/distro/start/nvim-web-devicons` with no `.git`; lock updated; cancel path leaves `No changes were made`; second concurrent run shows `Another installation is running`.

## Step 5 — UI (`:Distro`)

Float with sections + keys `I U C S X D R ? q`. `X` (check remote) is the only auto-network read and must announce itself first. All others preview → confirm.

Verify: open/close, `?`, `I` on canary, `C` dry-run lists garbage (`*.cloning` leftovers), no network on open (watch with `NVIM_DISTRO_DEBUG=1` log or firewall).

## Step 6 — Tools & Treesitter

`tools.check_all/hint/install_via_curl` (fzf, rg, gcc, make, go) + `treesitter.install_lang` for 2 canary langs (`lua`, `bash`) → then all 20 from `settings.treesitter_deps`.

Verify: without `gcc`, parser install routes to Tools with guidance; with gcc, `.so` lands in `pack/distro/parser/` + lock `parsers/<lang>`; `:TSEnable`-equivalent highlight works after `packadd nvim-treesitter`.

## Step 7 — Vendor all 26

```vim
:DistroInstall --all   " confirm once, atomic per plugin
```

Verify: `ls pack/distro/opt | wc -l` ≈ 25, `pack/distro/start` = 2; `git status --short pack | head`; repo size delta sane (`du -sh pack`); no `.git` inside (`find pack -name .git -maxdepth 4` empty).

## Step 8 — Cutover (delete lazy)

- [ ] `core/init.lua`: `require("core.pack")` → `require("core.distro")`, remove flag.
- [ ] Delete `lazy.nvim` bootstrap; keep `lazy-lock.json` one release as reference, then delete.
- [ ] Update `scripts/install.{sh,ps1}`, `README`, `:ConfigHealth`/`checkhealth distro`.
- [ ] `:DistroClean` removes `site/lazy/` leftovers (`*.cloning`).

Verify (the acceptance suite):
1. Fresh `git clone` to `/tmp/nvim-test`, `nvim` offline → works.
2. `:checkhealth distro` green (or hinted).
3. Triggers: `CursorHold` (gitsigns/flash), `:FzfLua`, `:Trouble`, `:DiffviewOpen`, `ft=go` — all offline.
4. `startup.log` vs lazy baseline — no regression.
5. mac + win smoke (paths, `curl.exe`/`tar`, `winget` hints).

## Step 9 — Docs & release

- [ ] `README` section `Distro (offline)` + `docs/distro/*` link.
- [ ] `?` help text = `02-ux-english-copy.md` Help block verbatim.
- [ ] Tag release; keep `lazy` branch pointer for a week.

## Step 10 — Corporate / offline mirror mode [done 2026-09-24]

Full spec: [`06-corporate-mirror.md`](06-corporate-mirror.md). Same manager and
confirm-gated flow, only the curl **source** changes (internal mirror, token, `--insecure`).

- [x] `distro.mirror`: resolve `github|corporate` (session > `distro-mirror.local.json` >
      env `DISTRO_MIRROR*/DISTRO_MIRROR_TOKEN` > `settings.distro_mirror`); token redaction.
- [x] `install`: templated URL (`{owner}{repo}{ref}{branch}{token}`), `.zip` unpack
      (bsdtar → unzip → Expand-Archive), Windows double-quote quoting, real `size_kb`.
- [x] `manifest`: `branch` per plugin (seeded from `lazy-lock.json`); tool pins (fzf release).
- [x] UI: `Mirror` section in `:Distro` + `:DistroMirror` (`status|menu|on|off|set-url|set-args|set-token|test`)
      + interactive `M` submenu.
- [x] Parsers/tools resolve through the same template (Step 6 completion).
- [x] Safety: https-only, `allowed_hosts` allowlist, unified redacted Source block in all
      four download previews, re-verification inside `download()`.

Verify: `:DistroMirror test` → HTTP 200 with redacted log; install via mirror records
`mirror=true`; `--insecure` shows TLS warning in preview; no token ⇒ clean pre-request
error; airplane ⇒ notify-only; Windows quoting + `.zip` smoke.

## Step 11 — Catalog & binaries [done 2026-09-24]

Full spec: [`07-catalog-binaries.md`](07-catalog-binaries.md).

- [x] `manifest.catalog`: 10 curated on-demand plugins (mini.pick, telescope, oil,
      toggleterm, which-key, todo-comments, lualine, ibl, neogit, nvim-tree), pins via API.
- [x] Loader/UI: catalog in `get()`, triggers registered with silent-skip while missing,
      Catalog section in `:Distro`, completion in `:DistroInstall`, auto-activate after install.
- [x] `manifest.binaries`: 9 entries (go×3, release×4, system×2); `:DistroBinaries` menu
      with version probes + number-key install; `raw`/`tar.xz`/`strip` support.
- [x] Proof: mini.nvim vendored, `<leader>mf` opens mini.pick files picker (TUI);
      shfmt installed to `tools/` (3.3MB, +x, locked); 4 release patterns probed HTTP 200.

## Rollback plan (any step)

- Loader flag back to `core.pack`; `git checkout -- distro-lock.json`; `rm -rf pack/distro <cache>/distro`. Boot path untouched until Step 8, so rollback is one env var + checkout.
