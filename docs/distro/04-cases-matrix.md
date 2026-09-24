# distroManager — Cases matrix (friendly handling)

Every row: trigger → expected behavior → exact English string (see `02-ux-english-copy.md`). All rows must hold with network off unless stated.

| # | Case | Behavior |
|---|------|----------|
| 1 | Fresh `git clone`, offline, `nvim` | Opens. Missing items notify once. `Nothing was downloaded.` |
| 2 | `ft=go` without `go.nvim` vendored | No crash. `Filetype 'go' has no local plugin. Open :Distro to install. Nothing downloaded.` |
| 3 | `:Distro` open (offline) | Renders local state. `Showing installed plugins only. You are offline.` No `curl`. |
| 4 | `:Distro` open (online) | Same, plus `X check` badge `2 updates available` only after user presses `X`. |
| 5 | Press `I` | Preview list `old → new + size + url + dest` → `[y/N/all/details]`. |
| 6 | Cancel (`N` / `q` / `<Esc>`) | `Installation canceled. No changes were made.` Tmp cleaned. |
| 7 | Partial download (`curl` killed) | Status `corrupted`. `Partial download detected for 'X'. [Keep / Discard]`. Old dir kept. |
| 8 | Size/sha mismatch | Same as 7, plus `See :DistroLog`. |
| 9 | No `curl` | `curl not found. Install it first: … — then reopen :Distro.` No fallback to git. |
| 10 | No `tar` (old Win) | `tar not found (Windows needs bsdtar…)`. |
| 11 | Offline + `U` | Refuse early: `You are offline…` No retry loop. |
| 12 | GitHub 404 (short SHA) | Manifest must use full SHA/tag; UI shows `Source not found (404). Kept previous version.` |
| 13 | Rate limit 403/429 | `GitHub rate limit reached. Try again in ~12 min or set GITHUB_TOKEN. No changes made.` |
| 14 | Disk full | Pre-check `statvfs`; on `ENOSPC`: `Not enough disk space (need X, have Y). … No changes made.` |
| 15 | No permission (dest) | `Cannot write to pack/distro/opt/X (permission denied). Check ownership. No changes made.` |
| 16 | Concurrent `:DistroInstall` | `Another installation is running (pid …). [Wait / Cancel]` via `tmp/distro/.lock`. |
| 17 | `--headless` without `--yes` | `Refusing: this needs explicit confirmation. Re-run with --yes. No changes were made.` |
| 18 | `gcc` missing + parser install | Block parser, route: `Tool missing: 'gcc' is needed… [Install / Show alternatives / Skip]`. |
| 19 | macOS + `Install gcc` | Honest: `curl cannot provide Apple Command Line Tools. Run: xcode-select --install … [Copy command / Skip]`. |
| 20 | Windows + `Install gcc` | Offer `w64devkit` curl archive → `tools/gcc/` (config-local). `winget` alternative shown. |
| 21 | `fzf` binary missing + `:FzfLua` | Loader hint: `'fzf' binary not found. Install via Tools (:DistroTools) or brew/winget. Picker not started.` |
| 22 | `make` missing + LuaSnip build | `Build requires 'make'. Install it first (see Tools). Build skipped, plugin kept.` |
| 23 | Parser build fail (`cc` exit 1) | `Parser 'go' failed to build (cc exit 1). See :DistroLog. Your previous parser (if any) was kept.` |
| 24 | `go` binaries missing (`:GoInstallBinaries`) | Confirm-gated quickfix/log; failure never blocks `:GoTest` file open. |
| 25 | Update available (`X` → `U`) | Diff `bd67efe → e9f12aa + changelog link` per item; bulk needs one more confirm. |
| 26 | `R` revert | `Revert 'flash.nvim' new → old? [y/N]` via lock `previous_ref`, same curl pipeline. |
| 27 | `C` clean | Lists `*.cloning`, orphan dirs, old `.so`; `Remove N dirs (X MB)? [y/N]`; never auto. |
| 28 | Corrupted dir (user hand-edited) | Status `corrupted` (sentinel `.distro-ok` missing) → `D` details → `R reinstall`. |
| 29 | Hand-edit of `distro-lock.json` (bad JSON) | UI shows `distro-lock.json is invalid JSON (line N). Kept in-memory state; fix or :DistroSync --rebuild-lock?` + backup `.bak`. |
| 30 | Large repo (`pack/` 100MB+) | `S sync` warns `This will add ~X MB to git. Continue? [y/N]`; docs suggest `strip=true`. |
| 31 | `GITHUB_TOKEN` set | Uses `Authorization` header for API + tarball; never logs token (`:DistroLog` redacts). |
| 32 | `NO_COLOR` / `dumb` TERM | UI falls back to plain text (no nerd icons), like `core/init.lua` termguard. |
| 33 | First-run empty `pack/` | Dashboard hint + `[Open :Distro]` keybinding, editor fully usable (netrw, builtin). |

Test commands:

```sh
# offline boot (no network syscalls for plugins expected)
NVIM_DISTRO=1 nvim --startuptime /tmp/distro-startup.log +qa
# loader status only, no downloads
NVIM_DISTRO=1 nvim --headless +"lua print(vim.inspect(require('distro.lock').status()))" +qa
# UI smoke (headless can't float; use --headless only for install --yes in CI)
nvim --headless +"DistroCheck" +qa
```
