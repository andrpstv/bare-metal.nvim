# Refactor plan: hangs/crashes → perf → Windows → hygiene (Step 12)

Target: mid-weak PC (4 cores/8GB). Behavior changes allowed. Windows fixed in the
same pass. Source: 4 independent audits (startup / file-open / redraw+background /
robustness); every item points at `file:line` in real code.

## Phase P0 — hangs & crashes (must)

| # | File:lines | Problem | Fix |
|---|---|---|---|
| P0-1 [x] | `keymap/helpers.lua:61` | `buf_request_sync(...,2000)` on `gd/gy` freezes UI | async `buf_request` + `locations_to_items` in callback (or 500ms timeout) |
| P0-2 [x] | `keymap/helpers.lua:195-200` | double `hover(2000)` in `_go_assign_vars` — up to 4s block | single async `client.request` + early exit without hover client |
| P0-3 [x] | `keymap/helpers.lua:169,175,396` | `parser:parse` / `get_node` / `get_node_text` without `pcall` | wrap all in `pcall`, early return |
| P0-4 [x] | `keymap/helpers.lua:124`, `modules/utils/init.lua:304` | `inlay_hint` / `register_server` without guards | client check + `pcall(config/enable)` |
| P0-5 [x] | `modules/utils/init.lua:410` | `require(plugin).setup` without `pcall` | `pcall(require)` + clear notify |
| P0-6 [x] | `modules/configs/completion/formatting.lua:94-95` | `supports_method` without `pcall` (race with `:LspRestart`) | unify on `pcall` + `is_stopped()` |
| P0-7 [x] | `distro/lock.lua:18-46` | non-atomic `write`, unread `.bak`, `invalid` silently counts as `installed` | `tmp+rename` write, `.bak` fallback read, `corrupted` status on invalid |
| P0-8 [x] | `distro/install.lua:71` | `acquire()` without stale detection — crash = eternal lock | store `{pid, started}`, recreate when stale/dead |
| P0-9 [x] | `distro/loader.lua:44-48` | `loaded=true` before dep success — partial state forever | mark after success, rollback `nil` on dep/`packadd` failure |
| P0-10 [x] | `distro/install.lua:356` + lock | reinstall downloads same ref; `remove_one` leaves lock ghost | early `already installed`, clean lock on remove |
| P0-11 [x] | `core/event.lua:53,259` | `buf_detach_client` / `execute_command` without `pcall` (E5113) | wrap |

## Phase P1 — weak-PC perf (behavior changes allowed)

| # | File:lines | Problem | Fix |
|---|---|---|---|
| P1-1 [x] | `keymap/helpers.lua:557-569` | `diagnostic.get(0)` on EVERY redraw | cache counters on `DiagnosticChanged`; fix cache keys `0 vs args.buf`; cache devicons; delete dead `_lsp_status` append (`:155`) |
| P1-2 [x] | `core/event.lua:103-116` | line-count large-file detection dead on `BufReadPre` | re-check in `BufReadPost`/`FileType`: `>10000 lines → large_file` |
| P1-3 [x] | `configs/editor/treesitter.lua:4-15` | global `foldexpr=expr`, highlight/indent without guard | `disable` on `large_file/line_count`, `manual` fold for big files |
| P1-4 [x] | `configs/completion/signature.lua:260` | `defer_fn(200)` swarm on every `CursorMovedI` | single `uv` timer `stop+start`, `large_file` guard in `refresh()` |
| P1-5 [x] | `configs/completion/cmp.lua:174,47` | `get_bufnrs` scans all buffers per keystroke; `keyword_length=1` | `keyword_length=2`, bound `buffer` source |
| P1-6 [x] | `keymap/completion.lua:217` | `codelens.refresh` on BufEnter/InsertLeave/BufWritePost, no debounce | 500ms debounce + `large_file` guard |
| P1-7 [x] | `configs/ui/gitsigns.lua:17,21` | `update_debounce=100`, `watch_gitdir interval=2000` | `200` / `5000` |
| P1-8 [x] | `distro/loader.lua:80,99` | `glob(after/)` even without `after/`; `rtp:append(*)` wildcard | `fs_stat` guard; append concrete dirs |
| P1-9 [x] | `configs/lang/lint.lua:39`, `formatting.lua:109` | lint spawn + format request without guards/changedtick | `large_file` guard, save debounce |
| P1-10 [x] | `lsp.lua:16-53` | first open pulls full cmp stack + gopls spawn | accept + early large-file skip before spawn |
| P1-11 [x] | `event.lua`/`helpers.lua` autocmds without `group` | re-source duplicates Go chain, invalidations, redrawstatus | `augroup(...,{clear=true})` + `group=` everywhere |

## Phase P2 — Windows & cross-platform (same pass, extra focus)

| # | What | Fix |
|---|---|---|
| P2-1 [x] | `distro/install.lua` `os.execute` shell quoting, no timeout | `vim.system(argv,{timeout})` everywhere |
| P2-2 [x] | hardcoded `/tmp` (`event.lua:182`, `options.lua:11`) | add `$TEMP/$TMP` patterns |
| P2-3 [x] | `HOME/USERPROFILE` nil, `expand` literals (`global.lua:14`, `init.lua:163,191`) | `expand("~")` fallback, checks + `confirm` before writing foreign configs |
| P2-4 [x] | `cc()` misses `cl` (MSVC), `check_prereqs` lets Windows through without `tar` | add `cl`, require `tar` everywhere |
| P2-5 [x] | `chmod` (`editor.lua:73`), `a.out` (`dap.lua:9`), `grepprg` without `executable`, health `system` without timeout | guards + `vim.system` with 5s timeout |
| P2-6 [x] | `tmpdir=config.."/tmp/distro"` pollutes repo, breaks on readonly config | move staging to `stdpath("cache")/distro` (pack stays) |
| P2-7 [x] | `unpack_zip` tries `unzip` before PowerShell on Windows | order: `tar` → PowerShell → `unzip` on win32 |

## Phase P3 — hygiene (cheap)

- `themes/black-metal-khold.lua` — single load path (drop double setup via `colors/khold.lua`)
- `loader.lua:57-90` — `once` guard against double-sourcing `after/plugin` for `start` plugins
- `settings.format_timeout` — wire into autosave or drop the mention

## Verification matrix (after each phase)

1. Startup: `nvim --startuptime` before/after (empty + with Go file); no worse than 125/174ms
2. File open: cold `nvim big.go` (1MB / 20k-line minified JSON) — instant, `large_file` notify, no LSP/treesitter
3. Redraw: 500+ diagnostics file, `hjkl` spam + mode switches — no jitter
4. Save storm: 5 fast `:w` in Go — 1 lint, 1 format, no races
5. Hang test: `kill -STOP gopls` + `gd` — ≤500ms, `gopls busy` notify
6. Lock crash: corrupted `distro-lock.json` → `corrupted`; stale `.lock` recreated
7. TUI matrix via tui-test: `:Distro` (26/26), picker, `gd/gr`, `:DistroBinaries`, resize
8. Windows review: paths with spaces/non-ASCII, `curl.exe`, `.zip`, no `cl`
