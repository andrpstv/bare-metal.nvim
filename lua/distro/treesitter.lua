-- distroManager treesitter — per-language parser installs via the same confirm pipeline.
-- Pins come from the vendored nvim-treesitter/lockfile.json; sources resolve through
-- the active mirror (github codeload or corporate template). No auto-build on startup.

local M = {}

function M.parser_dir()
	return vim.fn.stdpath("config") .. "/pack/distro/parser"
end

function M.plugin_parser_dir()
	return vim.fn.stdpath("config") .. "/pack/distro/opt/nvim-treesitter/parser"
end

function M.plugin_info_dir()
	return vim.fn.stdpath("config") .. "/pack/distro/opt/nvim-treesitter/parser-info"
end

function M.installed_langs()
	local out, seen = {}, {}
	for _, dir in ipairs({ M.parser_dir(), M.plugin_parser_dir() }) do
		local handle = vim.uv.fs_scandir(dir)
		if handle then
			while true do
				local name, t = vim.uv.fs_scandir_next(handle)
				if not name then
					break
				end
				if t == "file" and name:sub(-3) == ".so" and not seen[name] then
					seen[name] = true
					out[#out + 1] = name:sub(1, -4)
				end
			end
		end
	end
	table.sort(out)
	return out
end

function M.is_installed(lang)
	local set = {}
	for _, l in ipairs(M.installed_langs()) do
		set[l] = true
	end
	return set[lang] == true
end

local function lockfile_revisions()
	local p = vim.fn.stdpath("config") .. "/pack/distro/opt/nvim-treesitter/lockfile.json"
	local f = io.open(p, "r")
	if not f then
		return nil, "nvim-treesitter lockfile.json not vendored. Reinstall nvim-treesitter first. No changes made."
	end
	local ok, data = pcall(vim.json.decode, f:read("*a"))
	f:close()
	if not ok or type(data) ~= "table" then
		return nil, "Cannot parse nvim-treesitter lockfile.json. No changes made."
	end
	return data
end

local function cc()
	if vim.fn.executable("cc") == 1 then
		return "cc"
	elseif vim.fn.executable("gcc") == 1 then
		return "gcc"
	elseif vim.fn.executable("clang") == 1 then
		return "clang"
	elseif vim.fn.executable("cl") == 1 then
		return "cl" -- MSVC (Windows): flags below are gcc-style, may need tuning per setup
	end
	return nil
end

local function split_owner_repo(url)
	-- https://github.com/<owner>/<repo>(.git) — non-github hosts are refused
	local owner, repo = url:match("^https?://github%.com/([^/]+)/([^/]+)")
	if not owner then
		return nil
	end
	repo = repo:gsub("%.git$", "")
	return owner, repo
end

--- Resolve parser source through the active mirror (no download).
---@return table? src, string? err
function M.resolve_parser_source(lang)
	require("distro.loader").load("nvim-treesitter")
	local ok, parsers = pcall(function()
		return require("nvim-treesitter.parsers").get_parser_configs()
	end)
	if not ok or not parsers or not parsers[lang] then
		return nil, "Unknown parser '" .. lang .. "'. No changes made."
	end
	local info = parsers[lang].install_info or {}
	local owner, repo = split_owner_repo(info.url or "")
	if not owner then
		return nil, "Parser '" .. lang .. "' is not hosted on github (" .. tostring(info.url) .. "). No changes made."
	end
	local revs, err = lockfile_revisions()
	if not revs then
		return nil, err
	end
	local rev = revs[lang] and revs[lang].revision
	if not rev then
		return nil, "No pinned revision for '" .. lang .. "' in lockfile.json. No changes made."
	end
	local mirror = require("distro.mirror")
	local install = require("distro.install")
	local eff = mirror.effective()
	if eff.enabled then
		if mirror.needs_token(eff.url_template) and not mirror.token() then
			return nil, "Mirror needs a token (" .. eff.token_env .. " is empty). No changes made."
		end
		local url = mirror.fill(eff.url_template, { owner = owner, repo = repo, ref = rev, branch = "master" })
		return {
			url = url,
			archive = url:lower():match("%.zip%s*$") and "zip" or "targz",
			extra_args = eff.extra_args,
			insecure = mirror.insecure(eff.extra_args),
			mirror = true,
			revision = rev,
			files = info.files,
		}
	end
	return {
		url = install.tarball_url(owner .. "/" .. repo, rev),
		archive = "targz",
		extra_args = eff.extra_args,
		insecure = false,
		mirror = false,
		revision = rev,
		files = info.files,
	}
end

function M.install_lang(lang, opts, skip_preview)
	require("distro.install").require_consent(opts)
	local compiler = cc()
	if not compiler then
		return false, "Tool missing: a C compiler (cc/gcc/clang/cl) is needed to build Treesitter parsers. Open :DistroTools to install it. No changes made."
	end
	local src, err = M.resolve_parser_source(lang)
	if not src then
		return false, err
	end
	local install = require("distro.install")
	local mirror = require("distro.mirror")
	local preview_lines = {
		"Build parser '" .. lang .. "' (rev " .. src.revision:sub(1, 7) .. ")?",
		"Compiler: " .. compiler,
		"Output: pack/distro/parser/" .. lang .. ".so",
	}
	for _, l in ipairs(install.source_lines(src)) do
		preview_lines[#preview_lines + 1] = l
	end
	local preview = table.concat(preview_lines, "\n")
	if not skip_preview and vim.fn.confirm(preview, "&Yes\n&No", 2) ~= 1 then
		return false, "Parser install canceled. No changes were made."
	end
	local tmp = install.tmpdir() .. "/parser-" .. lang
	local archive = tmp .. (src.archive == "zip" and ".zip" or ".tar.gz")
	local stage = tmp .. ".unpacked"
	vim.fn.delete(archive)
	vim.fn.delete(stage, "rf")
	vim.fn.mkdir(stage, "p")
	local ok_dl, dl_err = install.download(src.url, archive, src.extra_args)
	if not ok_dl then
		return false, dl_err
	end
	-- unpack: keep tree, strip single top dir (both codeload and github zips have one)
	local ucmd
	if src.archive == "zip" then
		ucmd = { "tar", "xf", archive, "-C", stage, "--strip-components=1" }
	else
		ucmd = { "tar", "xzf", archive, "-C", stage, "--strip-components=1" }
	end
	if install.run_argv(ucmd, "unpack parser " .. lang, 60000) ~= 0 then
		return false, "Unpack failed for parser '" .. lang .. "'. No changes made."
	end
	-- compile listed sources (usually src/parser.c [+ src/scanner.c])
	local files = {}
	for _, f in ipairs(src.files or { "src/parser.c" }) do
		if vim.uv.fs_stat(stage .. "/" .. f) then
			files[#files + 1] = stage .. "/" .. f
		end
	end
	if #files == 0 then
		return false, "Parser sources not found in archive for '" .. lang .. "'. No changes made."
	end
	vim.fn.mkdir(M.parser_dir(), "p")
	local out = M.parser_dir() .. "/" .. lang .. ".so"
	-- .so name is nvim-treesitter convention on all OSes (PE/ELF both load via libuv).
	-- MSVC uses its own flags; mingw-gcc (w64devkit, see :DistroTools) is preferred on Windows.
	local argv
	if compiler == "cl" then
		argv = { compiler, "/nologo", "/O2", "/LD", "/I" .. stage .. "/src", "/Fe" .. out }
	else
		argv = { compiler, "-O2", "-shared", "-fPIC", "-I", stage .. "/src", "-o", out }
	end
	for _, f in ipairs(files) do
		argv[#argv + 1] = f
	end
	if install.run_argv(argv, "build parser " .. lang, 120000) ~= 0 or not vim.uv.fs_stat(out) then
		return false, "Compiler failed for parser '" .. lang .. "'. Previous parser (if any) kept. See :Distro log."
	end
	vim.fn.delete(archive)
	vim.fn.delete(stage, "rf")
	require("distro.lock").record("parsers/" .. lang, {
		repo = "parser/" .. lang,
		ref = src.revision,
		tarball = mirror.redact(src.url),
		kind = "parser",
		size_kb = install.dir_size_kb(M.parser_dir()),
	})
	return true, "Parser '" .. lang .. "' built (" .. src.revision:sub(1, 7) .. "). Recorded in distro-lock.json."
end

function M.install_all(opts)
	require("distro.install").require_consent(opts)
	local deps = require("core.settings").treesitter_deps
	local missing = {}
	for _, lang in ipairs(deps) do
		if not M.is_installed(lang) then
			missing[#missing + 1] = lang
		end
	end
	if #missing == 0 then
		return true, "All " .. #deps .. " parsers already installed. Nothing was downloaded."
	end
	if vim.fn.confirm("Build " .. #missing .. " missing parser(s)?\n" .. table.concat(missing, ", ") .. "\n[This downloads + compiles each one.]", "&Yes\n&No", 2) ~= 1 then
		return false, "Parser install canceled. No changes were made."
	end
	local done, failed = 0, {}
	for _, lang in ipairs(missing) do
		-- bulk confirm already given above; skip per-item preview
		local ok, msg = M.install_lang(lang, opts, true)
		if ok then
			done = done + 1
		else
			failed[#failed + 1] = lang .. ": " .. msg
		end
	end
	if #failed > 0 then
		return false, string.format("Built %d/%d. Failed: %s", done, #missing, table.concat(failed, "; "))
	end
	return true, string.format("Built %d/%d parsers. Recorded in distro-lock.json.", done, #missing)
end

return M
