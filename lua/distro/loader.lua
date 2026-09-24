-- distroManager loader — boot + lazy triggers. ZERO network by design.
-- This module must never require distro.install. It only does packadd + config.

local M = {}

M.loaded = {}

local function cfg_path()
	return vim.fn.stdpath("config")
end

function M.pack_dir(entry)
	return string.format("%s/pack/distro/%s/%s", cfg_path(), entry.kind, entry.name)
end

function M.is_present(entry)
	return vim.uv.fs_stat(M.pack_dir(entry)) ~= nil
end

local function notify_missing(entry)
	local msg = string.format(
		"[Distro] '%s' is missing. Open :Distro and press I to install. Nothing was downloaded.",
		entry.name
	)
	vim.schedule(function()
		vim.notify_once(msg, vim.log.levels.WARN)
	end)
end

--- Idempotent local load. Two phases: (1) packadd the whole dep subtree so
--- requires resolve, (2) after/plugin + configs deps-first. Returns true if usable.
--- `loaded` is set only on full success so a broken dep never poisons the parent.
local loading = {}
local packing = {}
local finishing = {}

--- Phase 1: ensure entry + all deps are packadd'ed (rtp). No configs yet.
---@return boolean
local function pack_subtree(entry)
	if M.loaded[entry.name] then
		return true
	end
	if packing[entry.name] then
		return true -- cycle: the outer frame packs it
	end
	packing[entry.name] = true
	local manifest = require("distro.manifest")
	local ok = true
	for _, dep in ipairs(entry.deps or {}) do
		local d = manifest.get(dep)
		if not d or not M.is_present(d) then
			notify_missing(d or { name = dep })
			ok = false
			break
		end
		if not pack_subtree(d) then
			ok = false
			break
		end
	end
	if ok then
		local pok = pcall(vim.cmd, "packadd " .. entry.name)
		if not pok and entry.kind ~= "start" then
			-- start/ plugins are already on rtp; treat packadd error as non-fatal
			ok = false
		end
	end
	packing[entry.name] = nil
	return ok
end

--- Phase 2: after/plugin + config, deps first.
---@return boolean
local function finish_subtree(entry)
	if M.loaded[entry.name] then
		return true
	end
	if finishing[entry.name] then
		return true -- cycle: the outer frame finishes it
	end
	local manifest = require("distro.manifest")
	finishing[entry.name] = true
	local ok = true
	for _, dep in ipairs(entry.deps or {}) do
		local d = manifest.get(dep)
		if d and not finish_subtree(d) then
			ok = false
			break
		end
	end
	if ok then
		-- :packadd sources plugin/ but NOT after/plugin (lazy.nvim did that part).
		-- Several plugins self-register there (e.g. all cmp sources), so source them.
		M.source_after(M.pack_dir(entry))
		if entry.config then
			local cfg_mod = entry.config:match("^themes%.") and entry.config or ("modules.configs." .. entry.config)
			local ok_req, cfg = pcall(require, cfg_mod)
			if ok_req then
				if type(cfg) == "function" then
					local ok_call, err = pcall(cfg)
					if not ok_call then
						vim.notify("[Distro] config '" .. cfg_mod .. "' failed: " .. tostring(err), vim.log.levels.ERROR)
					end
				elseif type(cfg) == "table" and cfg.setup then
					pcall(cfg.setup)
				end
			end
		end
		M.loaded[entry.name] = true
	end
	finishing[entry.name] = nil
	return ok
end

function M.load(name)
	if M.loaded[name] then
		return true
	end
	if loading[name] then
		return false -- cycle: bail out instead of recursing forever
	end
	local manifest = require("distro.manifest")
	local entry = manifest.get(name)
	if not entry then
		return false
	end
	if not M.is_present(entry) then
		notify_missing(entry)
		return false
	end
	loading[name] = true
	local ok = pack_subtree(entry) and finish_subtree(entry)
	loading[name] = nil
	return ok
end

--- Source after/plugin files of a vendored plugin dir (see M.load).
---@param dir string absolute plugin dir
function M.source_after(dir)
	-- 99% плагинов без after/: лишний glob на каждый load ни к чему
	if vim.uv.fs_stat(dir .. "/after") == nil then
		return
	end
	local files = vim.fn.glob(dir .. "/after/plugin/**/*.{lua,vim}", false, true)
	for _, f in ipairs(files) do
		if f:sub(-4) == ".lua" then
			local ok_af, err_af = pcall(vim.cmd, "luafile " .. vim.fn.fnameescape(f))
			if not ok_af then
				vim.notify("[Distro] after/plugin failed: " .. f .. ": " .. tostring(err_af), vim.log.levels.ERROR)
			end
		else
			pcall(vim.cmd, "source " .. vim.fn.fnameescape(f))
		end
	end
end

--- Forward-declared: stub creator (defined below, used on load-failure restore).
local boot_cmd_stub

--- Boot: rtp + eager start plugins + lazy autocmds/commands. No network.
function M.boot()
	local cfg = cfg_path()
	vim.opt.packpath:prepend(cfg)
	-- NOTE: без wildcard (rtp:append(".../*") замедлял каждый :runtime-поиск);
	-- packadd сам правит rtp при загрузке, eager-старту хватает packpath.
	-- short requires used across configs: require("completion.lsp"),
	-- require("editor.treesitter"), etc. (was append_nativertp in core/pack.lua)

	-- short requires used across configs: require("completion.lsp"),
	-- require("editor.treesitter"), etc. (was append_nativertp in core/pack.lua)
	package.path = package.path
		.. string.format(
			";%s;%s;%s",
			cfg .. "/lua/modules/configs/?.lua",
			cfg .. "/lua/modules/configs/?/init.lua",
			cfg .. "/lua/user/?.lua"
		)

	local manifest = require("distro.manifest")

	for _, p in ipairs(manifest.plugins) do
		if p.kind == "start" then
			M.load(p.name)
		end
	end

	local group = vim.api.nvim_create_augroup("DistroLazy", { clear = true })

	local all = {}
	for _, p in ipairs(manifest.plugins) do
		all[#all + 1] = p
	end
	for _, p in ipairs(manifest.catalog or {}) do
		all[#all + 1] = p
	end
	for _, p in ipairs(all) do
		if p.kind ~= "start" then
			if p.event then
				local ev = type(p.event) == "string" and { p.event } or p.event
				vim.api.nvim_create_autocmd(ev, {
					group = group,
					once = false,
					callback = function()
						-- catalog items stay silent until explicitly installed
						if p.catalog and not M.is_present(p) then
							return
						end
						M.load(p.name)
					end,
					desc = "distro: lazy-load " .. p.name,
				})
			end
			if p.ft then
				vim.api.nvim_create_autocmd("FileType", {
					group = group,
					pattern = p.ft,
					callback = function()
						if p.catalog and not M.is_present(p) then
							return
						end
						M.load(p.name)
					end,
					desc = "distro: ft-load " .. p.name,
				})
			end
			if p.cmd then
				local cmds = type(p.cmd) == "string" and { p.cmd } or p.cmd
				for _, c in ipairs(cmds) do
					boot_cmd_stub(c, p)
				end
			end
		end
	end
end

--- Create (or recreate) a lazy stub user command for a plugin command.
---@param c string command name, e.g. "FzfLua"
---@param p table manifest entry
boot_cmd_stub = function(c, p)
	pcall(vim.api.nvim_create_user_command, c, function(opts)
		-- drop the stub so the plugin can register the real command
		pcall(vim.api.nvim_del_user_command, c)
		if M.load(p.name) then
			-- re-dispatch to the real command now provided by the plugin
			local ok, err = pcall(vim.cmd, c .. " " .. (opts.args or ""))
			if not ok then
				vim.notify("[Distro] '" .. c .. "' failed after load: " .. tostring(err), vim.log.levels.ERROR)
			end
		else
			-- load failed (missing): restore stub for next attempt
			boot_cmd_stub(c, p)
		end
	end, { nargs = "*", bang = true, complete = "command", desc = "distro lazy stub: " .. p.name })
end

--- Non-blocking status for health/UI. No network.
function M.status()
	return require("distro.lock").status()
end

return M
