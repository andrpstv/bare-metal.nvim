# distroManager — Corporate / offline mirror mode (Step 10)

Audience: corporate environments with no direct internet, TLS-intercepting proxies,
or an internal artifact mirror (e.g. SberOSC-style `.../github_api/<owner>/<repo>/archive/...`).
Same manager, same confirm-gated flow — only the **source** of curl archives changes.

## 1. Contract

- Mirror mode changes **where** archives come from, never **when**: zero-auto-network still holds.
  No request (not even a version check) fires without the user opening `:Distro`/`:DistroMirror`
  and confirming.
- Token rules:
  - Token lives **only** in env (`DISTRO_MIRROR_TOKEN`) or session memory (`:DistroMirror set-token`,
    lost on exit). **Never** in `distro-mirror.local.json`, never in git, never in logs.
  - Every URL shown in UI previews and written to `tmp/distro/distro.log` is redacted
    (`token:<redacted>`).
- `--insecure` (needed behind MITM proxies) is supported but **explicit**: it must be listed
  in `extra_args`, and every confirm preview shows `TLS verification DISABLED (--insecure)`.
- Fully offline (no mirror reachable): manager degrades to notify-only —
  `[Distro] offline/corporate mirror unreachable. Showing installed plugins only.`

## 2. Configuration (precedence: session > file > env > settings)

`core/settings.lua` defaults:

```lua
settings["distro_mirror"] = {
  enabled = false,
  url_template = "",      -- e.g. corporate (see §3); empty = GitHub codeload
  extra_args = {},        -- e.g. { "--insecure" }
  token_env = "DISTRO_MIRROR_TOKEN",
}
```

Env overrides (set machine-wide by IT):

| Var | Effect |
|---|---|
| `DISTRO_MIRROR=1` | enable corporate mode |
| `DISTRO_MIRROR_URL` | url template (enables when non-empty only if `DISTRO_MIRROR=1`) |
| `DISTRO_MIRROR_ARGS` | space-separated extra curl args, e.g. `--insecure --proxy http://proxy:8080` |
| `DISTRO_MIRROR_TOKEN` | token value (never logged, never stored) |

Local file `<config>/distro-mirror.local.json` (gitignored, **no token ever**):

```json
{ "enabled": true, "url_template": "https://token:{token}@mirror.corp/.../{owner}/{repo}/archive/refs/heads/{branch}.zip", "extra_args": ["--insecure"] }
```

## 3. URL template placeholders

`{owner} {repo} {ref} {branch} {token}`.

- GitHub default: `https://codeload.github.com/{owner}/{repo}/tar.gz/{ref}`.
- Corporate example (zip per branch, token in userinfo):
  `https://token:{token}@sberosc.sigma.sbrf.ru/repo/extras/github_api/{owner}/{repo}/archive/refs/heads/{branch}.zip`
- `{branch}` comes from `manifest` (`branch` field seeded from `lazy-lock.json`).
- Corporate branch zips track a moving tip, not the pinned SHA: the lock records
  `ref` (manifest pin) + `mirror_branch` + `mirror=true`, and the UI shows
  `8d79f24 (mirror:main)` so drift is visible, not hidden.

## 4. Archive formats & cross-platform unpack

- `.tar.gz`/`.tgz` → `tar xzf … --strip-components=1`.
- `.zip` → `tar xf … --strip-components=1` (bsdtar: macOS + Win10+ tar), fallback
  `unzip -q` + single-top-dir hoist, fallback Windows `powershell Expand-Archive`.
- Shell quoting: single quotes on POSIX, **double quotes on Windows** (`cmd.exe`
  does not understand single quotes). Implemented in `install.Q()`.
- `curl`/`curl.exe` and `tar`/`bsdtar` presence is pre-checked with per-OS install hints.

## 5. UI

- `:Distro` gains a `Mirror` section: `mode: github | corporate (host…)` (token redacted),
  `reachability: last test OK/FAIL/never`, hints.
- `:DistroMirror` subcommands: `status | menu | on | off | set-url <tpl> | set-args <a…> |
  clear-args | set-token (session-only, prompt hidden) | test`.
- `M` inside `:Distro` (or `:DistroMirror menu`) opens an interactive submenu:
  `e` enable/disable · `u` set URL (input with current value) · `a` set args ·
  `k` set token (inputsecret, session-only) · `t` test · `b` back. Nothing downloads there.
- `test` = `curl --fail -sI -o <null>` against one small resolved URL, reports HTTP code.
  No body is downloaded.

## 5b. Safety against the wrong source

- Only `https://` URLs are fetched (`allow_http=false` default).
- `distro_mirror.allowed_hosts = { "mirror.corp.example" }` turns the manager into an
  allowlist: any resolved host outside the list is refused **before** confirm and again
  inside `install.download` (defense in depth).
- Every download confirm embeds the unified Source block (origin `github (public
  internet)` vs `corporate (<host>)`, redacted URL, archive format, `--insecure`
  warning) — see `02-ux-english-copy.md`. All four download sites (plugins, tools,
  parsers, `:DistroInstall`) build it via `install.source_lines()`.

## 6. Parsers & tools through the mirror

- Parser tarballs resolve through the same template (`{owner}/{repo}` = parser repo,
  `{ref}` = revision from vendored `nvim-treesitter/lockfile.json`,
  `{branch}` = `master`). Corporate mirrors serving only branch zips still work
  (drift shown as in §3).
- Tool archives (`fzf` releases, corp toolchain zips like `w64devkit`) resolve through
  the same pipeline; per-tool specs may carry an explicit `url` override, also templated.

## 7. Verification

- [ ] `:DistroMirror test` green against corporate host (HTTP 200), token redacted in log.
- [ ] `:DistroInstall <small-plugin>` via mirror → dir appears, no `.git`, lock has `mirror=true`.
- [ ] Same flow with `--insecure` shows TLS warning in preview.
- [ ] `DISTRO_MIRROR_TOKEN` unset → clear error before any request, no partial state.
- [ ] Airplane mode → notify-only, zero curl syscalls.
- [ ] Windows (`cmd.exe` quoting, `curl.exe`, `.zip` via `tar xf`) smoke-tested.
