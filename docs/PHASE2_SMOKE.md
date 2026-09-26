# PHASE2 smoke test

`scripts/smoke-test.sh` automates the sanity checks that were previously run by
hand on commit `4513f1b`. Before this existed, the only way to know whether a
change broke the config was to type the commands one by one.

## Running it

```sh
./scripts/smoke-test.sh            # all checks, including the startup benchmark
./scripts/smoke-test.sh --quick    # skip check 6 (startup), ~1s instead of ~10s
./scripts/smoke-test.sh -h         # usage
```

Exit code is `0` when every executed check passed, `1` on any failure, `2` if
the harness itself could not start (no `nvim` in `PATH`). Each check prints
`PASS` / `FAIL` / `SKIP` with a one-line reason; a summary block repeats the
verdicts at the end. No network, no package installs, no git writes, no secrets.

Portability: bash + `set -euo pipefail`, no GNU-only flags. The millisecond
clock used by check 6 comes from `python3` if present, otherwise `perl`; with
neither, check 6 reports `SKIP` instead of guessing.

## What is checked

| # | Check | How |
|---|-------|-----|
| 1 | Config loads | `nvim --headless -c 'qa!'` must exit 0 with **empty** stderr |
| 2 | Bootstrap version guard | `vim.fn.has("nvim-0.11") == 1` on the running binary, plus a grep that the guard still exists in `init.lua` or `lua/core/health.lua` |
| 3 | 9 new modules load | `pcall(require, m)` for `core.turbo`, `core.weak_hw`, `core.term_guard`, `core.git_colors`, `distro.trace`, `distro.tracehooks`, `distro.traceui`, `distro.bench`, `distro.benchui`; the Lua error text is printed on failure |
| 4 | User commands exist | static grep for `nvim_create_user_command("<name>"` **and** runtime `vim.fn.exists(":Name") == 2` |
| 5 | gopls on valid Go | temp fixture with `go.mod`, wait for `vim.lsp.get_clients()`, require >= 1 client and exactly 0 diagnostics |
| 6 | Startup sanity | median of 5 runs ours vs `nvim --clean`, fail only above 5x |

### Notes on the two non-obvious parts

**Check 4 — how the commands are verified.** `nvim_get_commands({builtin=false})`
returns an empty table under `--headless`, so that API is useless here. Two
methods that do work are used instead:

- *Static*: `grep -r "nvim_create_user_command(\"Name\"" lua init.lua`. This is
  the source of truth and covers all 24 names.
- *Runtime*: `vim.fn.exists(":Name") == 2`. This works in headless for every
  command whose file has already been evaluated. `TreesitterTier` is declared in
  `lua/modules/configs/editor/treesitter.lua`, which is only reached through the
  lazy module loader, so under `--headless` it is not registered yet and
  `exists()` returns 0. The script classifies any command that is missing at
  runtime but present under `lua/modules/` as "lazily loaded, expected" and only
  fails on a genuine miss.

The brief called this "the 25 commands" but the list contains **24** unique
names; the script counts the list instead of hardcoding a number.

**Check 5 — the fixture needs a `go.mod`.** With a bare `main.go` in a temp dir,
gopls attaches but emits `go list | No packages found for open file ...` (source
`go list`, severity 2). That is a property of the fixture, not of the config, so
the script writes a minimal `go.mod` next to `main.go` and only then expects 0
diagnostics. The fixture lives in `mktemp -d`, never in the repo, and is removed
by the `EXIT` trap.

## Relationship to CI (style_check.yml, lint_code.yml)

Both workflows are Lua-only and neither can see a shell script:

- `style_check.yml` runs `JohnnyMorganz/stylua-action@v4` with
  `--check --config-path=stylua.toml .`
- `lint_code.yml` runs `lunarmodules/luacheck@v1` with
  `args: . --std luajit --max-line-length 150 --no-config --globals vim ...`

Neither stylua nor luacheck parses bash, so `scripts/smoke-test.sh` is covered
by **neither** check — it can be committed with tabs, 300-character lines or a
`set -u` landmine and CI will stay green. The same is true of `docs/`.

**What a consumer gets today:** formatting feedback only for Lua, and only after
a push. Locally there is no way to reproduce what CI will say, because stylua and
luacheck are not installed on this machine and installing them is out of scope
for the smoke test (no package installs, no network). The practical gap is
"commit-time formatting feedback", not correctness: a reviewer relying on CI to
catch shell style problems will never get that signal.

**Proposed fix (not implemented here, deliberately):**

1. Add a third job to a workflow — e.g. `.github/workflows/smoke_test.yml`,
   `runs-on: macos-latest` (matching the local platform) or a matrix of
   `macos-latest` + `ubuntu-latest` to exercise the portability claim —
   running `bash -n scripts/smoke-test.sh` and then `./scripts/smoke-test.sh
   --quick` on every push and PR, with gopls preinstalled or the check allowed
   to `SKIP` when it is absent.
2. Add `shellcheck` as a fourth job (`lunixbochs/vt-action` or a plain
   `sudo apt-get install shellcheck && shellcheck scripts/*.sh`). This is the
   smallest change that gives the new file any automated review at all, and
   needs no config file.
3. Optionally, document a local escape hatch for Lua formatting — a pinned
   `nix develop` / `mise` / `brew` one-liner in `AGENTS.md` — so the Lua half of
   the two existing workflows can at least be reproduced before pushing. That
   one is a documentation change, not a tooling change, and should be a separate
   decision.

The smoke test itself deliberately does not run stylua or luacheck: they are not
installed, and a script that silently skips checks it cannot perform is worse
than one that reports the checks it did run.
