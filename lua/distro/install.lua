-- distroManager install — the ONLY place that runs curl/tar.
-- Hard rule: no call below touches network unless opts.user_confirmed == true.
-- Headless additionally requires opts.yes == true.
-- Sources: GitHub codeload by default, corporate mirror when enabled
-- (see distro.mirror + docs/distro/06-corporate-mirror.md).

local M = {}

local function is_win()
	return vim.fn.has("win32") == 1
end

--- Shell-quote one argument. cmd.exe understands double quotes only.
function M.Q(s)
	s = tostring(s)
	if is_win() then
		return '"' .. s:gsub('"', '""') .. '"'
	end
	return "'" .. s:gsub("'", "'\\''") .. "'"
end

function M.null_dev()
	return is_win() and "NUL" or "/dev/null"
end

function M.tarball_url(repo, ref)
	return string.format("https://codeload.github.com/%s/tar.gz/%s", repo, ref)
end

function M.tmpdir()
	-- Staging lives in stdpath("cache"), NOT in the config repo: keeps
	-- `git status` clean and works with a readonly config dir (Windows: ~/AppData).
	return vim.fn.stdpath("cache") .. "/distro"
end

local function ensure_tmp()
	vim.fn.mkdir(M.tmpdir(), "p")
end

--- Consent guard. Errors (never notifies + downloads).
function M.require_consent(opts)
	opts = opts or {}
	if opts.user_confirmed ~= true then
		error("Refusing: this needs explicit confirmation. Open :Distro and confirm. No changes were made.", 0)
	end
	if vim.fn.has("nvim-0.11") == 0 then
		error("distroManager requires Neovim >= 0.11.", 0)
	end
	if #vim.api.nvim_list_uis() == 0 and opts.yes ~= true then
		error("Refusing: this needs explicit confirmation. Re-run with --yes. No changes were made.", 0)
	end
end

local function has_bin(bin)
	return vim.fn.executable(bin) == 1
end

function M.check_prereqs()
	if not has_bin("curl") then
		return false, "curl not found. Install it first: macOS: 'brew install curl' · Windows: 'winget install curl.curl' · Linux: 'sudo apt install curl' — then reopen :Distro."
	end
	-- tar is mandatory everywhere (.tar.gz unpack + bsdtar zip support);
	-- unzip/PowerShell are only fallbacks for .zip.
	if not has_bin("tar") then
		return false, "tar not found. macOS/Windows ship bsdtar built-in; Linux: 'sudo apt install tar'. Then reopen :Distro."
	end
	return true
end

local function lock_path()
	return M.tmpdir() .. "/.lock"
end

--- Best-effort single-instance guard. Returns release fn or nil+msg.
--- Locks older than 10 minutes are treated as stale (crashed nvim) and reclaimed.
function M.acquire()
	ensure_tmp()
	local lp = lock_path()
	local st = vim.uv.fs_stat(lp)
	if st then
		local age = st.mtime and (os.time() - st.mtime.sec) or 0
		if age <= 600 then
			return nil, "Another installation is running. Wait a bit and retry. No changes made."
		end
		os.remove(lp)
	end
	local f = io.open(lp, "w")
	if f then
		f:write(tostring(vim.fn.getpid()) .. "\n" .. os.time() .. "\n")
		f:close()
	end
	return function()
		os.remove(lp)
	end
end

function M.log(msg)
	local p = M.tmpdir() .. "/distro.log"
	ensure_tmp()
	local f = io.open(p, "a")
	if f then
		f:write(os.date("[%Y-%m-%d %H:%M:%S] ") .. require("distro.mirror").redact(msg) .. "\n")
		f:close()
	end
end

--- Unified safety preview lines for any resolved source (redacted).
--- Every download confirm in the codebase must include these.
---@return string[] lines
function M.source_lines(src)
	local mirror = require("distro.mirror")
	local host = mirror.host_of(src.url) or "?"
	local fmt = src.archive == "zip" and ".zip" or (src.archive == "raw" and "single binary" or ".tar.gz/.tar.xz")
	local lines = {
		"Source: " .. (src.mirror and ("corporate (" .. host .. ")") or "github (public internet: codeload.github.com)"),
		"From:   " .. mirror.redact(src.url),
		"Format: " .. fmt,
	}
	if src.insecure then
		lines[#lines + 1] = "WARNING: TLS verification DISABLED (--insecure). Use only behind a trusted corporate proxy."
	end
	return lines
end

--- Resolve a download source for a plugin entry.
---@return { url: string, archive: "targz"|"zip", extra_args: string[], insecure: boolean, mirror: boolean, mirror_branch: string? }
---@return string? err (token missing etc.)
function M.resolve_source(entry)
	local mirror = require("distro.mirror")
	local eff = mirror.effective()
	if not eff.enabled then
		return {
			url = M.tarball_url(entry.repo, entry.ref),
			archive = "targz",
			extra_args = eff.extra_args,
			insecure = mirror.insecure(eff.extra_args),
			mirror = false,
		}
	end
	if mirror.needs_token(eff.url_template) and not mirror.token() then
		return nil, "Mirror needs a token (" .. eff.token_env .. " is empty). Export it or run :DistroMirror set-token. No changes made."
	end
	local parts = vim.split(entry.repo, "/", { plain = true })
	local url = mirror.fill(eff.url_template, {
		owner = parts[1] or "",
		repo = parts[2] or entry.repo,
		ref = entry.ref,
		branch = entry.branch or "main",
	})
	local archive = url:lower():match("%.zip%s*$") and "zip" or "targz"
	local src = {
		url = url,
		archive = archive,
		extra_args = eff.extra_args,
		insecure = mirror.insecure(eff.extra_args),
		mirror = true,
		mirror_branch = entry.branch or "main",
	}
	local ok_url, url_err = mirror.verify_url(src.url)
	if not ok_url then
		return nil, url_err
	end
	return src
end

local function curl_base(extra_args)
	local parts = { "curl", "-fSL", "--proto", "=https", "--tlsv1.2" }
	for _, a in ipairs(extra_args or {}) do
		parts[#parts + 1] = a
	end
	return parts
end

--- Run a command given as argv list. No shell involved (safe for spaces and
--- non-ASCII paths on Windows), with a timeout so a hung child can't freeze UI.
---@param argv string[]
---@param timeout_ms integer?
---@return integer exit code (0 = ok)
function M.run_argv(argv, log_label, timeout_ms)
	local mirror = require("distro.mirror")
	M.log((log_label or "exec") .. " :: " .. mirror.redact(table.concat(argv, " ")))
	local obj = vim.system(argv, { text = true, timeout = timeout_ms or 120000 }):wait()
	if not obj then
		return 1
	end
	return obj.code or 1
end

local function run_argv(argv, log_label)
	return M.run_argv(argv, log_label)
end

--- Download a URL to a file. Returns true or false+err.
--- Safety: the URL is re-verified here (defense in depth — callers preview first).
function M.download(url, dest, extra_args)
	local mirror = require("distro.mirror")
	local ok_url, url_err = mirror.verify_url(url)
	if not ok_url then
		return false, url_err
	end
	local argv = curl_base(extra_args)
	argv[#argv + 1] = "-o"
	argv[#argv + 1] = dest
	argv[#argv + 1] = url
	local rc = run_argv(argv, "download")
	if rc ~= 0 then
		if rc == 22 then
			return false, "Source not found (HTTP 22/404). Kept previous version. No changes made."
		end
		return false, "Download failed (curl exit " .. tostring(rc) .. "). Check network/mirror and retry. No changes made."
	end
	return true
end

--- Unpack .tar.gz into stage dir (must exist, must be empty).
local function unpack_targz(archive, stage)
	return run_argv({ "tar", "xzf", archive, "-C", stage, "--strip-components=1" }, "unpack targz") == 0
end

-- forward declaration (defined below, after unpack_flat)
local hoist_single_child

--- Unpack an archive flat into stage dir (tools/binaries: no strip unless asked).
---@param archive string path to .tar.gz/.tgz/.zip/.tar.xz
---@param stage string existing empty dir
---@param strip boolean pass --strip-components=1 (tarballs with a top dir)
---@return boolean ok
function M.unpack_flat(archive, stage, strip)
	local lower = archive:lower()
	local is_zip = lower:match("%.zip%s*$")
	local args
	if is_zip then
		if vim.fn.executable("tar") ~= 1 then
			return false
		end
		args = { "tar", "xf", archive, "-C", stage }
	else
		if vim.fn.executable("tar") ~= 1 then
			return false
		end
		-- tar auto-detects gzip/xz (bsdtar everywhere incl. Win/mac; GNU tar too)
		args = { "tar", "xf", archive, "-C", stage }
	end
	if strip and not is_zip then
		args[#args + 1] = "--strip-components=1"
	end
	if strip and is_zip and vim.fn.executable("tar") == 1 then
		args[#args + 1] = "--strip-components=1" -- bsdtar supports it for zips
	end
	if M.run_argv(args, "unpack flat", 60000) ~= 0 then
		return false
	end
	if strip and is_zip then
		-- GNU tar ignores --strip for zips; hoist single top dir instead
		return hoist_single_child(stage)
	end
	return true
end

--- Move single top-level child of stage up one level (for unzip fallback).
hoist_single_child = function(stage)
	local handle = vim.uv.fs_scandir(stage)
	if not handle then
		return false
	end
	local names = {}
	while true do
		local n = vim.uv.fs_scandir_next(handle)
		if not n then
			break
		end
		names[#names + 1] = n
	end
	if #names ~= 1 then
		return #names > 0 -- zero or many: keep as-is only if non-empty
	end
	local child = stage .. "/" .. names[1]
	local st = vim.uv.fs_stat(child)
	if not st or st.type ~= "directory" then
		return true -- single file: nothing to hoist
	end
	local h2 = vim.uv.fs_scandir(child)
	if not h2 then
		return false
	end
	while true do
		local n = vim.uv.fs_scandir_next(h2)
		if not n then
			break
		end
		if not os.rename(child .. "/" .. n, stage .. "/" .. n) then
			return false
		end
	end
	vim.fn.delete(child, "rf")
	return true
end

--- Unpack .zip into stage dir.
--- Order: bsdtar first everywhere; then PowerShell on Windows (built-in),
--- `unzip` last (third-party). Each step confirms success before moving on.
local function unpack_zip(archive, stage)
	if has_bin("tar") and run_argv({ "tar", "xf", archive, "-C", stage, "--strip-components=1" }, "unpack zip(tar)") == 0 then
		return true
	end
	if is_win() then
		local ps = "Expand-Archive -Path "
			.. "'"
			.. archive:gsub("'", "''")
			.. "' -DestinationPath '"
			.. stage:gsub("'", "''")
			.. "' -Force"
		if run_argv({ "powershell", "-NoProfile", "-NonInteractive", "-Command", ps }, "unpack zip(ps)") == 0 then
			return hoist_single_child(stage)
		end
	end
	if has_bin("unzip") then
		if run_argv({ "unzip", "-q", archive, "-d", stage }, "unpack zip(unzip)") == 0 then
			return hoist_single_child(stage)
		end
		return false
	end
	return false
end

--- Recursive directory size in KB (portable, no process spawn).
function M.dir_size_kb(dir)
	local total = 0
	local function walk(d)
		local h = vim.uv.fs_scandir(d)
		if not h then
			return
		end
		while true do
			local name, t = vim.uv.fs_scandir_next(h)
			if not name then
				break
			end
			local p = d .. "/" .. name
			if t == "directory" then
				walk(p)
			elseif t == "file" then
				local st = vim.uv.fs_stat(p)
				if st and st.size then
					total = total + st.size
				end
			end
		end
	end
	walk(dir)
	return math.floor(total / 1024)
end

--- Download + unpack one plugin atomically. opts = { user_confirmed=true, yes? }.
function M.install_one(entry, opts)
	M.require_consent(opts)
	local ok, err = M.check_prereqs()
	if not ok then
		return false, err
	end
	-- skip redundant re-downloads of the exact same pin (healthy dir + same ref)
	do
		local lock = require("distro.lock").read()
		local l = lock[entry.name]
		local cfg0 = vim.fn.stdpath("config")
		local dest0 = string.format("%s/pack/distro/%s/%s", cfg0, entry.kind, entry.name)
		if l and l.ref == entry.ref and vim.uv.fs_stat(dest0 .. "/.distro-ok") then
			return true, "Already installed '" .. entry.name .. "' (" .. entry.ref:sub(1, 7) .. "). No changes made."
		end
	end
	local src, src_err = M.resolve_source(entry)
	if not src then
		return false, src_err
	end
	local release, lock_err = M.acquire()
	if not release then
		return false, lock_err
	end
	ensure_tmp()
	local cfg = vim.fn.stdpath("config")
	local ext = src.archive == "zip" and ".zip" or ".tar.gz"
	local slug = entry.name .. "-" .. entry.ref:sub(1, 7)
	local archive = M.tmpdir() .. "/" .. slug .. ext
	local stage = M.tmpdir() .. "/" .. slug .. ".unpacked"
	local dest = string.format("%s/pack/distro/%s/%s", cfg, entry.kind, entry.name)

	vim.fn.delete(archive)
	vim.fn.delete(stage, "rf")
	vim.fn.mkdir(stage, "p")

	local ok_dl, dl_err = M.download(src.url, archive, src.extra_args)
	if not ok_dl then
		release()
		M.log("download FAILED " .. entry.name)
		return false, dl_err
	end

	local ok_unpack = src.archive == "zip" and unpack_zip(archive, stage) or unpack_targz(archive, stage)
	if not ok_unpack then
		release()
		return false, "Unpack failed for '" .. entry.name .. "' (archive seems incomplete). Old version kept. [Retry / Discard tmp file]"
	end

	-- sweep: no .git ever, optional strip of heavy dirs
	vim.fn.delete(stage .. "/.git", "rf")
	vim.fn.delete(stage .. "/.github", "rf")
	if entry.strip then
		for _, d in ipairs({ "tests", "test", "docs", "docsrc" }) do
			vim.fn.delete(stage .. "/" .. d, "rf")
		end
	end

	-- atomic rename
	vim.fn.delete(dest .. ".old", "rf")
	if vim.uv.fs_stat(dest) then
		os.rename(dest, dest .. ".old")
	end
	local ok_mv = os.rename(stage, dest)
	if not ok_mv then
		if vim.uv.fs_stat(dest .. ".old") then
			os.rename(dest .. ".old", dest)
		end
		release()
		return false, "Cannot write to " .. dest .. " (permission denied). Check ownership. No changes made."
	end
	vim.fn.delete(dest .. ".old", "rf")
	vim.fn.delete(archive)

	local size_kb = M.dir_size_kb(dest)
	require("distro.lock").mark_ok(dest)
	local rec = {
		repo = entry.repo,
		ref = entry.ref,
		-- redacted: the lock file is committed, a token must never land here
		tarball = require("distro.mirror").redact(src.url),
		kind = entry.kind,
		size_kb = size_kb,
	}
	if src.mirror then
		rec.mirror = true
		rec.mirror_branch = src.mirror_branch
	end
	require("distro.lock").record(entry.name, rec)
	release()
	M.log("installed " .. entry.name .. " " .. entry.ref:sub(1, 7))
	return true, "Installed '" .. entry.name .. "' (" .. entry.ref:sub(1, 7) .. (src.mirror and ", mirror:" .. src.mirror_branch or "") .. "). Version recorded in distro-lock.json."
end

--- Remove one vendored dir (clean). Also confirm-gated.
function M.remove_one(entry, opts)
	M.require_consent(opts)
	local cfg = vim.fn.stdpath("config")
	local dest = string.format("%s/pack/distro/%s/%s", cfg, entry.kind, entry.name)
	vim.fn.delete(dest, "rf")
	-- drop the lock ghost too, otherwise status() reports stale data
	local lock = require("distro.lock").read()
	if lock[entry.name] ~= nil then
		lock[entry.name] = nil
		require("distro.lock").write(lock)
	end
	return true, "Removed '" .. entry.name .. "'. No other changes made."
end

--- HEAD-check a URL (no body download). Returns true+code or false+err.
function M.probe(url, extra_args)
	local argv = curl_base(extra_args)
	argv[#argv + 1] = "-sI"
	argv[#argv + 1] = "-o"
	argv[#argv + 1] = M.null_dev()
	argv[#argv + 1] = "-w"
	argv[#argv + 1] = "%{http_code}"
	argv[#argv + 1] = url
	-- capture stdout: use vim.system (portable, no shell)
	local mirror = require("distro.mirror")
	M.log("probe :: " .. mirror.redact(table.concat(argv, " ")))
	local obj = vim.system(argv, { text = true, timeout = 15000 }):wait()
	local code = obj and obj.stdout and obj.stdout:match("(%d%d%d)%s*$") or nil
	if obj and obj.code == 0 and code and code:sub(1, 1) == "2" then
		return true, code
	end
	return false, (code and ("HTTP " .. code) or ("curl exit " .. tostring(obj and obj.code)))
end

--- Query GitHub API for a branch HEAD sha (github mode only). Returns sha or nil+err.
function M.remote_head_sha(repo, branch)
	local url = string.format("https://api.github.com/repos/%s/commits/%s", repo, branch or "main")
	local argv = { "curl", "-fSL", "--proto", "=https", "--tlsv1.2", url }
	local obj = vim.system(argv, { text = true, timeout = 15000 }):wait()
	if not obj or obj.code ~= 0 then
		return nil, "API unreachable (rate limit? offline?). No changes made."
	end
	local sha = obj.stdout and obj.stdout:match('"sha"%s*:%s*"([0-9a-f]+)"')
	return sha, sha and nil or "Unexpected API response. No changes made."
end

function M.remote_cache_path()
	return M.tmpdir() .. "/remote.json"
end

--- Last `X` check results ({ [name] = { remote_sha?, checked_at?, error? } }).
function M.read_remote_cache()
	local f = io.open(M.remote_cache_path(), "r")
	if not f then
		return {}
	end
	local ok, data = pcall(vim.json.decode, f:read("*a"))
	f:close()
	return (ok and type(data) == "table") and data or {}
end

--- Short upstream sha when the cached X-check found a newer HEAD, else nil.
function M.remote_newer(name, pin)
	local e = M.read_remote_cache()[name]
	if e and e.remote_sha and e.remote_sha ~= pin then
		return e.remote_sha:sub(1, 7)
	end
	return nil
end

return M
