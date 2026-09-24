# distroManager — English UX copy (final strings)

All user-facing prompts are English. Russian stays only in dev docs. Copy uses sentence case, states what happens + where + version, and always ends with an explicit choice. No destructive or network action without it.

## Core reassurances (header / empty states / footer)

- `Nothing was downloaded or updated automatically.`
- `Network is used only after your confirmation.`
- `Showing installed plugins only. You are offline.`
- `Open :Distro and press I to install. Nothing was downloaded.`

## Startup notices (notify_once, never blocking)

- Missing: `[Distro] 'gitsigns.nvim' is missing. Open :Distro and press I to install. Nothing was downloaded.`
- Corrupted: `[Distro] 'fzf-lua' looks corrupted (size mismatch). Open :Distro → D for details, R to reinstall.`
- Build needed: `[Distro] 'LuaSnip' needs a build step (make install_jsregexp). Open :Distro to run it.`
- First run: `[Distro] Welcome! 3 of 26 plugins are vendored. Open :Distro to install the rest. No downloads start on their own.`

## Confirm dialogs (the only gateway to curl)

Every download confirm includes a Source block (identical everywhere):

```
Source: github (public internet: codeload.github.com)   |  corporate (<host>)
From:   https://<redacted>@<host>/…                      (token never shown)
Format: .tar.gz | .zip
WARNING: TLS verification DISABLED (--insecure). …       (only when set)
```

- Single: `Install 'gitsigns.nvim' v0.9.0 (8d79f24)?\n<Source block>\nTo: ~/.config/nvim/pack/distro/opt/gitsigns.nvim\nVersion will be recorded in distro-lock.json. [y/N]`
- Safety refusals (shown instead of any confirm, nothing touched):
  - `Refusing non-HTTPS source. Only https:// is accepted (allow_http=false). No changes made.`
  - `Refusing host '<host>' — not in distro_mirror.allowed_hosts. No changes made.`
  - `Mirror needs a token (<ENV> is empty). Export it or run :DistroMirror set-token. No changes made.`
- Bulk: `Install 3 items (1.2MB total)? [y/N/all/details]`
- Update: `Update 'trouble.nvim' bd67efe → e9f12aa (42KB)? See changelog: github.com/folke/trouble.nvim/compare/bd67efe…e9f12aa [y/N]`
- Tool: `Download gcc via curl?\nSource: <url>\nSize: ~85MB\nInstall to: ~/.config/nvim/tools/gcc (config-local, does not touch system)\nUsed only to build Treesitter parsers. [y/N]`
- macOS honesty: `curl cannot provide Apple Command Line Tools.\nRun: xcode-select --install\nAlternative: brew install gcc make\n[Copy command / Skip]`
- Build: `Build step required: 'make install_jsregexp' for LuaSnip. Run it now? [y/N]`
- Clean: `Remove 2 unused dirs (14MB)? [y/N]`
- Revert: `Revert 'flash.nvim' e9f12aa → 5f0f270? [y/N]`
- Headless guard: `Refusing: this needs explicit confirmation. Re-run with --yes. No changes were made.`

## Progress & results

- `Downloading 'fzf-lua' (1/3, 420KB)…`
- `Installed 'flash.nvim' (5f0f270). Version recorded in distro-lock.json.`
- `Updated 'trouble.nvim' bd67efe → e9f12aa. Restart or :DistroReload to apply.`
- `Installation canceled. No changes were made.`
- `Partial download detected for 'fzf-lua'. [Keep / Discard]`
- `Another installation is running (pid 1234). [Wait / Cancel]`

## Failures (always with next step)

- `You are offline. Showing installed plugins only. Connect and press 'X' to check for updates.`
- `curl not found. Install it first: macOS: 'brew install curl' · Windows: 'winget install curl.curl' — then reopen :Distro.`
- `tar not found (Windows needs bsdtar — ships with Win10+; otherwise 'winget install libarchive').`
- `GitHub rate limit reached. Try again in ~12 min or set GITHUB_TOKEN. No changes made.`
- `Not enough disk space (need 85MB, have 12MB). Free space and retry. No changes made.`
- `Tool missing: 'gcc' is needed to build Treesitter parsers. [Install / Show alternatives / Skip]`
- `Parser 'go' failed to build (cc exit 1). See :DistroLog. Your previous parser (if any) was kept.`

## Help (`?` inside :Distro — full key reference float)

```
Distro keys — every network action previews + confirms first.

Cursor row (a plugin line):
  i ......... install this entry (missing/corrupted)
  u ......... reinstall this entry to its pin
  d / Enter . details: pin, upstream, deps, config, triggers, source
  r ......... revert this entry to its previous version
  x ......... check upstream HEAD of this entry (1 API call)
  o ......... open repo page in browser

Whole distro (anywhere):
  I ......... install all missing        U .. sync all outdated to pins
  C ......... clean unmanaged dirs       S .. adopt pins without download
  X ......... check all upstream HEADs   D .. details by name (input)
  R ......... revert all with previous   B .. binaries menu (LSP/tools)
  M ......... corporate mirror menu      ? .. this help   q .. close
```

Layout: dynamic grid (name column sized to content), `─` section separators,
status-colored dots (green/yellow/red), cursorline, live float title
(`Distro — <plugin>` follows the cursor), width clamped to the terminal.

```
Distro — self-contained plugin manager (curl-only, confirm-gated)

  I install missing    U update      C clean unused
  S sync to lock       X check remote (uses network, asks first)
  D diff / details     R revert      ? help   q quit

Nothing is downloaded or updated automatically — ever.
Versions are pinned in distro-lock.json.
Tools (gcc/fzf) and Treesitter parsers install the same way.
```

## Tone rules for contributors

1. Say what + where + version before asking.
2. One question per dialog; default is always `N` (safe).
3. After cancel/failure, state `No changes were made` explicitly.
4. Never use `error` alone — append `Next step: …`.
5. No jargon (`codeload`, `strip-components`) in UI; keep it in logs.
