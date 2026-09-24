-- distroManager tools — executable() checks + per-OS hints + curl fallback.
-- No downloads without explicit confirm (routes through install.require_consent).

local M = {}

local HINTS = {
	curl = { mac = "brew install curl", win = "winget install curl.curl", linux = "sudo apt install curl" },
	tar = { mac = "bsdtar ships with macOS", win = "tar ships with Windows 10+; otherwise: winget install libarchive", linux = "sudo apt install tar" },
	fzf = { mac = "brew install fzf", win = "winget install junegunn.fzf", linux = "sudo apt install fzf", curl = "junegunn/fzf" },
	rg = { mac = "brew install ripgrep", win = "winget install BurntSushi.ripgrep", linux = "sudo apt install ripgrep" },
	gcc = {
		mac = "curl cannot provide Apple Command Line Tools. Run: xcode-select --install (or: brew install gcc make)",
		win = "winget install BrechtSanders.WinLibs.POSIX.UCRT — or install w64devkit via :DistroTools (config-local tools/gcc/)",
		linux = "sudo apt install gcc make (or dnf/pacman equivalent)",
	},
	make = { mac = "xcode-select --install (or: brew install make)", win = "w64devkit includes make — see :DistroTools", linux = "sudo apt install make" },
	go = { mac = "brew install go", win = "winget install GoLang.Go", linux = "sudo apt install golang" },
}

function M.check_all()
	local manifest = require("distro.manifest")
	local out = {}
	for _, t in ipairs(manifest.tools) do
		local bin = t.check
		local ok = vim.fn.executable(bin) == 1
		local ver = nil
		if ok then
			-- cheap, single spawn only when UI/health explicitly opened (never on startup)
			local obj = vim.system({ bin, "--version" }, { text = true, timeout = 2000 }):wait()
			ver = obj and obj.stdout and obj.stdout:gsub("\n.*", ""):sub(1, 60) or ""
		end
		local alt_ok = false
		if not ok and t.name == "gcc" then
			alt_ok = vim.fn.executable("cc") == 1 or vim.fn.executable("clang") == 1
		end
		out[t.name] = { ok = ok or alt_ok, version = ver or "", hint = HINTS[t.name] }
	end
	return out
end

function M.hint(name)
	return HINTS[name]
end

--- Install a tool via sanctioned curl archive into tools/<name>/ (config-local).
--- Only for tools with manifest curl_fallback. gcc-on-mac is guidance-only.
function M.install_via_curl(name, opts)
	require("distro.install").require_consent(opts)
	if name == "gcc" and vim.uv.os_uname().sysname == "Darwin" then
		return false, "curl cannot provide Apple Command Line Tools. Run: xcode-select --install [Copy command]"
	end
	return M.install_tool(name, opts)
end

-- forward declarations (used by resolve_tool_source above)
local fill_placeholders, archive_of

--- Resolve a tool archive source through the active mirror when possible.
---@return table? src ({url, archive, extra_args, insecure}), string? err
function M.resolve_tool_source(tool)
	local mirror = require("distro.mirror")
	local install = require("distro.install")
	local eff = mirror.effective()
	if tool.url then
		-- explicit (possibly templated) archive URL — corporate toolchains go here
		if mirror.needs_token(tool.url) and not mirror.token() then
			return nil, "Tool needs a mirror token (" .. eff.token_env .. " is empty). No changes made."
		end
		local url = fill_placeholders(tool.url, tool)
		return { url = url, archive = archive_of(url), extra_args = eff.extra_args, insecure = mirror.insecure(eff.extra_args) }
	end
	if not tool.repo or not tool.asset then
		return nil, "No curl source for tool '" .. tool.name .. "'. See :DistroTools hints. No changes made."
	end
	if eff.enabled then
		return nil, "Corporate mirror has no release-asset mapping for '" .. tool.name .. "'. Ask IT for a tool archive URL (manifest tools[].url). No changes made."
	end
	return M.github_release_source(tool)
end

local function asset_os_name(tool)
	local sys = vim.uv.os_uname().sysname
	local std = sys == "Darwin" and "darwin" or (sys == "Windows_NT" and "windows" or "linux")
	if tool.asset_os then
		return tool.asset_os[std] or std
	end
	return std
end

local function asset_arch_name(tool)
	local arch = (vim.uv.os_uname().machine or ""):lower()
	local std = (arch:match("arm64") or arch:match("aarch64")) and "arm64" or ((arch:match("x86_64") or arch:match("amd64")) and "amd64" or nil)
	if not std then
		return nil
	end
	if tool.asset_arch then
		return tool.asset_arch[std] or std
	end
	return std
end

local function asset_ext(tool)
	local std = vim.uv.os_uname().sysname == "Darwin" and "darwin"
		or (vim.uv.os_uname().sysname == "Windows_NT" and "windows" or "linux")
	if type(tool.asset_ext) == "table" then
		return tool.asset_ext[std] or ""
	end
	return tool.asset_ext or ""
end

fill_placeholders = function(tpl, tool, ver)
	local v = ver or tool.pin or ""
	return tpl:gsub("{ver}", v):gsub("{vernov}", v:gsub("^v", "")):gsub("{os}", asset_os_name(tool) or ""):gsub("{arch}", asset_arch_name(tool) or ""):gsub("{ext}", asset_ext(tool)):gsub("{exewin}", asset_os_name(tool) == "windows" and ".exe" or "")
end

archive_of = function(url)
	local lower = url:lower()
	if lower:match("%.zip%s*$") then
		return "zip"
	elseif lower:match("%.tar%.gz%s*$") or lower:match("%.tgz%s*$") or lower:match("%.tar%.xz%s*$") then
		return "targz"
	end
	return "raw" -- single binary, no archive
end

--- Resolve latest release tag via GitHub API (github mode only, called after confirm).
function M.latest_tag(repo)
	local install = require("distro.install")
	local argv = { "curl", "-fSL", "--proto", "=https", "--tlsv1.2", string.format("https://api.github.com/repos/%s/releases/latest", repo) }
	local obj = vim.system(argv, { text = true, timeout = 15000 }):wait()
	if not obj or obj.code ~= 0 then
		return nil, "Release API unreachable (rate limit? offline?). No changes made."
	end
	local tag = obj.stdout and obj.stdout:match('"tag_name"%s*:%s*"([^"]+)"')
	return tag, tag and nil or "Unexpected release API response. No changes made."
end

-- expose placeholder helpers for tests/callers
M.fill_placeholders = fill_placeholders
M.archive_of = archive_of

--- GitHub release asset source (pin or latest-resolved tag).
function M.github_release_source(tool)
	local ver = tool.pin
	if not ver then
		local tag, err = M.latest_tag(tool.repo)
		if not tag then
			return nil, err
		end
		ver = tag
	end
	if not asset_arch_name(tool) then
		return nil, "Unsupported CPU arch for '" .. tool.name .. "'. No changes made."
	end
	local url = "https://github.com/" .. tool.repo .. "/releases/download/" .. ver .. "/" .. fill_placeholders(tool.asset, tool, ver)
	return { url = url, archive = archive_of(url), extra_args = {}, insecure = false, version = ver }
end

--- Install/update a tool binary into tools/<name>/ (config-local). Confirm-gated.
function M.install_tool(name, opts)
	require("distro.install").require_consent(opts)
	local manifest = require("distro.manifest")
	local tool = manifest.get_tool and manifest.get_tool(name) or nil
	if not tool then
		for _, t in ipairs(manifest.tools) do
			if t.name == name then
				tool = t
				break
			end
		end
	end
	if not tool then
		return false, "Unknown tool '" .. name .. "'. No changes made."
	end
	local install = require("distro.install")
	local mirror = require("distro.mirror")
	local src, err = M.resolve_tool_source(tool)
	if not src then
		return false, err
	end
	local preview_lines = {
		"Install tool '" .. name .. "'" .. (tool.pin and (" " .. tool.pin) or "") .. "?",
		"To: tools/" .. name .. "/ (config-local, does not touch system)",
		"Afterwards add tools/" .. name .. " to PATH or symlink the binary.",
	}
	for _, l in ipairs(install.source_lines(src)) do
		preview_lines[#preview_lines + 1] = l
	end
	local preview = table.concat(preview_lines, "\n")
	if vim.fn.confirm(preview, "&Yes\n&No", 2) ~= 1 then
		return false, "Tool install canceled. No changes were made."
	end
	local tmp = install.tmpdir() .. "/tool-" .. name
	local archive = tmp .. (src.archive == "zip" and ".zip" or (src.archive == "raw" and ".bin" or ".tar.gz"))
	local stage = tmp .. ".unpacked"
	local dest = vim.fn.stdpath("config") .. "/tools/" .. name
	local is_win = vim.fn.has("win32") == 1
	vim.fn.delete(archive)
	vim.fn.delete(stage, "rf")
	vim.fn.mkdir(stage, "p")
	local ok_dl, dl_err = install.download(src.url, archive, src.extra_args)
	if not ok_dl then
		return false, dl_err
	end
	if src.archive == "raw" then
		-- single binary, no archive: move straight into place
		local bin_name = (tool.bin or name) .. (is_win and ".exe" or "")
		vim.fn.delete(dest, "rf")
		vim.fn.mkdir(dest, "p")
		if not os.rename(archive, dest .. "/" .. bin_name) then
			return false, "Cannot write to " .. dest .. " (permission denied). No changes made."
		end
	else
		if not install.unpack_flat(archive, stage, tool.strip) then
			return false, "Unpack failed for tool '" .. name .. "'. No changes made."
		end
		vim.fn.delete(dest .. ".old", "rf")
		if vim.uv.fs_stat(dest) then
			os.rename(dest, dest .. ".old")
		end
		if not os.rename(stage, dest) then
			if vim.uv.fs_stat(dest .. ".old") then
				os.rename(dest .. ".old", dest)
			end
			return false, "Cannot write to " .. dest .. " (permission denied). No changes made."
		end
		vim.fn.delete(dest .. ".old", "rf")
		vim.fn.delete(archive)
	end
	-- ensure executable bit on POSIX (luv chmod: no spawn, Windows-safe no-op guard)
	local bin = dest .. "/" .. (tool.bin or name) .. (is_win and ".exe" or "")
	if vim.uv.fs_stat(bin) and not is_win then
		pcall(vim.uv.fs_chmod, bin, 493) -- 0755
	end
	require("distro.lock").record("tools/" .. name, {
		repo = tool.repo or tool.url or name,
		ref = src.version or tool.pin or "unpinned",
		tarball = mirror.redact(src.url),
		kind = "tool",
		size_kb = install.dir_size_kb(dest),
	})
	return true, "Tool '" .. name .. "' installed to tools/" .. name .. "/. Add it to PATH to use. Recorded in distro-lock.json."
end

--- Install a Go binary via `go install <pkg>` (needs Go + module reachability).
function M.install_go(bin, opts)
	require("distro.install").require_consent(opts)
	local spec = nil
	for _, b in ipairs(require("distro.manifest").binaries or {}) do
		if b.name == bin then
			spec = b
			break
		end
	end
	if not spec or spec.method ~= "go" then
		return false, "Unknown go binary '" .. bin .. "'. No changes made."
	end
	if vim.fn.executable("go") ~= 1 then
		return false, "'go' not found. Install Go first (see :DistroTools hints). No changes made."
	end
	if vim.fn.confirm("Run `go install " .. spec.pkg .. "`?\nUses your GOPROXY/GOPATH (outside the config).", "&Yes\n&No", 2) ~= 1 then
		return false, "Go install canceled. No changes were made."
	end
	local install = require("distro.install")
	install.log("go install " .. spec.pkg)
	local obj = vim.system({ "go", "install", spec.pkg }, { text = true, timeout = 120000 }):wait()
	if not obj or obj.code ~= 0 then
		return false, "`go install` failed: " .. tostring(obj and obj.stderr or "?"):sub(1, 200) .. " No changes made."
	end
	if vim.fn.executable(spec.check) ~= 1 then
		return false, "Installed but '" .. spec.check .. "' not in PATH (check GOPATH/bin). No changes made."
	end
	require("distro.lock").record("bin/" .. bin, { repo = spec.pkg, ref = "go-install", kind = "bin", size_kb = 0 })
	return true, "'" .. bin .. "' installed via go. Recorded in distro-lock.json."
end

--- Version probe for one binary (best effort, never errors).
function M.bin_version(spec)
	if vim.fn.executable(spec.check) ~= 1 then
		return nil
	end
	local argv = { spec.check }
	for _, a in ipairs(spec.ver_args or { "--version" }) do
		argv[#argv + 1] = a
	end
	local obj = vim.system(argv, { text = true, timeout = 3000 }):wait()
	if not obj or obj.code ~= 0 then
		return ""
	end
	return ((obj.stdout or ""):gsub("\n.*", ""):sub(1, 60))
end

--- Separate binaries menu: LSP servers, linters, formatters.
function M.open_binaries()
	local manifest = require("distro.manifest")
	local items = manifest.binaries or {}
	local lines = {
		" Binaries — LSP servers, linters, formatters. Nothing installs itself.",
		" go = `go install` (GOPROXY) · release = curl archive → tools/ · system = hint only",
		"",
	}
	for i, b in ipairs(items) do
		local ver = M.bin_version(b)
		local mark = ver ~= nil and "●" or "○"
		local state = ver == nil and ("missing — " .. b.desc) or (ver ~= "" and ver or "installed")
		lines[#lines + 1] = string.format(" %d. %s %-18s %-7s  %s", i, mark, b.name, b.method, state)
	end
	lines[#lines + 1] = ""
	lines[#lines + 1] = " <number> install · q back"
	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.api.nvim_buf_set_option(buf, "modifiable", false)
	vim.api.nvim_buf_set_option(buf, "filetype", "distro-bins")
	local win = vim.api.nvim_open_win(buf, true, {
		relative = "editor",
		width = 82,
		height = math.min(#lines, vim.o.lines - 4),
		row = 2,
		col = math.max(1, (vim.o.columns - 82) / 2),
		style = "minimal",
		border = "rounded",
		title = "Distro binaries",
	})
	local function back()
		pcall(vim.api.nvim_win_close, win, true)
		require("distro.ui").open()
	end
	local map = function(key, fn, desc)
		vim.keymap.set("n", key, fn, { buffer = buf, nowait = true, desc = desc })
	end
	map("q", back, "Back")
	map("<Esc>", back, "Back")
	for i, b in ipairs(items) do
		local name, method = b.name, b.method
		map(tostring(i % 10), function()
			pcall(vim.api.nvim_win_close, win, true)
			local ok, msg
			if method == "go" then
				ok, msg = M.install_go(name, { user_confirmed = true })
			elseif method == "release" then
				-- find matching tools spec (release binaries live there too)
				local tool = (require("distro.manifest").get_tool or function() end)(name)
				if not tool then
					-- ad-hoc tool spec from the binaries entry
					tool = { name = name, check = b.check, repo = b.repo, asset = b.asset, asset_os = b.asset_os, asset_arch = b.asset_arch, asset_ext = b.asset_ext, bin = b.bin, strip = b.strip, url = b.url }
				end
				ok, msg = M.install_tool_ad_hoc(tool)
			else
				ok, msg = false, M.system_hint(name)
			end
			vim.notify(msg, ok and vim.log.levels.INFO or vim.log.levels.WARN)
			vim.schedule(function()
				M.open_binaries()
			end)
		end, "Install " .. name)
	end
end

--- Install from an ad-hoc tool spec (binaries entries), confirm-gated.
function M.install_tool_ad_hoc(tool)
	-- temporarily expose as a tool spec for install_tool
	local manifest = require("distro.manifest")
	manifest.tools = manifest.tools or {}
	local known = manifest.get_tool and manifest.get_tool(tool.name)
	if known then
		return M.install_tool(tool.name, { user_confirmed = true })
	end
	manifest.tools[#manifest.tools + 1] = tool
	local ok, msg = M.install_tool(tool.name, { user_confirmed = true })
	-- keep it registered for the session so status stays consistent
	return ok, msg
end

--- Hint text for system-managed binaries.
function M.system_hint(name)
	local hints = {
		bashls = "npm i -g bash-language-server (needs node) · macOS: brew install bash-language-server · Windows: winget install mirrors? use npm.",
		marksman = "macOS: brew install marksman · Windows: winget install Marksman.Marksman · or download from github.com/artempyanykh/marksman/releases.",
	}
	return hints[name] or ("Install '" .. name .. "' via your system package manager. No changes made.")
end

return M
