-- distroManager loader — boot + lazy triggers. ZERO network by design.
-- This module must never require distro.install. It only does packadd + config.

local M = {}

M.loaded = {}

-- DistroTrace integration. Trace only, no behaviour: `enabled` is read once
-- per call and every helper below is a no-op table index when the trace is off.
local function trace()
	if not M._trace then
		local t = package.loaded["distro.trace"]
		if not t then
			local ok, mod = pcall(require, "distro.trace")
			t = ok and mod or false
		end
		M._trace = t
	end
	return M._trace
end

--- Re-entry depth of M.load. A plugin's config/setup() may load another
--- plugin, so the outer frame is marked with an aggregate row; inner frames
--- still emit their own pack/finish rows (see pack_subtree/finish_subtree),
--- which is where the real cost of the 121-module first frame shows up.
local load_depth = 0

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
local pack_subtree_body -- forward: тело ниже, wrapper зовёт по имени
local function pack_subtree(entry)
	if M.loaded[entry.name] then
		return true
	end
	if packing[entry.name] then
		return true -- cycle: the outer frame packs it
	end
	packing[entry.name] = true
	-- F5: finally-guard — ошибка ниже (битый manifest, trace) обязана снять
	-- флаг, иначе все будущие load отдают cycle-заглушку до рестарта.
	local ok, res = xpcall(pack_subtree_body, function(e)
		return debug.traceback(tostring(e), 2)
	end, entry)
	packing[entry.name] = nil
	if not ok then
		vim.notify("[Distro] pack '" .. entry.name .. "' failed: " .. tostring(res):sub(1, 200), vim.log.levels.ERROR)
		return false
	end
	return res
end

pack_subtree_body = function(entry)
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
		-- kind="start" уже в rtp и его plugin/*.vim уже sourced при старте
		-- (pack/distro/start подхватывается Neovim автоматически). Повторный
		-- :packadd ре-источ��л plugin/ — отсюда был 3-й дубль nvim-web-devicons.vim
		-- (3 x 0.016-0.140 мс тёплых, заметнее на HDD). Пропускаем только
		-- САМ entry; его deps по-прежнему обходятся и packadd'ятся выше.
		-- Ошибки логики загрузки не трогаем: start никогда не был fatal
		-- (см. ветку ниже), поведение ok=false не меняется.
		if entry.kind == "start" then
			-- уже на rtp — nothing to do
		else
			-- packadd only: rtp, no after/plugin, no config. This is the
			-- dominant cost of the first frame on a spinning disk.
			--
			-- Фолбэк rtp-only: чей-то plugin/*.vim требует модули, которых
			-- ещё нет в rtp (н-р textobjects требует nvim-treesitter.configs,
			-- а пакуется раньше родителя). Полный packadd тогда падает и
			-- валит всё поддерево (был мёртвый treesitter+textobjects).
			-- packadd! кладёт только rtp; поведение довязывается фазой
			-- finish/config. Молча by design: путь штатный и проверенный
			-- (см. отчёт C8), а WARN на каждый запуск — спам. Диагностика —
			-- только если упал и rtp-only (ниже таких нет: ok=false).
			local function do_pack()
				local pok = pcall(vim.cmd, "packadd " .. entry.name)
				if not pok then
					pok = pcall(vim.cmd, "packadd! " .. entry.name)
				end
				return pok
			end
			local t = trace()
			if t and t.enabled then
				t.span("loader:pack/" .. entry.name, function()
					if not do_pack() then
						ok = false
					end
				end)
			else
				if not do_pack() then
					ok = false
				end
			end
		end
	end
	packing[entry.name] = nil
	return ok
end

--- Phase 2: after/plugin + config, deps first.
---@return boolean
local finish_subtree_body -- forward: см. pack_subtree выше
local function finish_subtree(entry)
	if M.loaded[entry.name] then
		return true
	end
	if finishing[entry.name] then
		return true -- cycle: the outer frame finishes it
	end
	finishing[entry.name] = true
	local ok, res = xpcall(finish_subtree_body, function(e)
		return debug.traceback(tostring(e), 2)
	end, entry)
	finishing[entry.name] = nil
	if not ok then
		vim.notify("[Distro] finish '" .. entry.name .. "' failed: " .. tostring(res):sub(1, 200), vim.log.levels.ERROR)
		return false
	end
	return res
end

finish_subtree_body = function(entry)
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
		local t = trace()
		-- :packadd sources plugin/ but NOT after/plugin (lazy.nvim did that part).
		-- Several plugins self-register there (e.g. all cmp sources), so source them.
		-- after/plugin + require(config) + cfg.setup(): everything a user's
		-- first file open can pay for. Traced as one span per plugin, never
		-- per require inside it — an inner require flood would drown the log.
		local function do_finish()
			M.source_after(M.pack_dir(entry))
			if entry.config then
				local cfg_mod = entry.config:match("^themes%.") and entry.config or ("modules.configs." .. entry.config)
				local ok_req, cfg = pcall(require, cfg_mod)
				if not ok_req then
					-- F7: раньше несуществующий config молча пропускался
					-- (опечатка = «плагин загрузился», поведения нет).
					vim.notify("[Distro] config '" .. cfg_mod .. "' not found for '" .. entry.name .. "'", vim.log.levels.ERROR)
				elseif type(cfg) == "function" then
					local ok_call, err = pcall(cfg)
					if not ok_call then
						vim.notify("[Distro] config '" .. cfg_mod .. "' failed: " .. tostring(err), vim.log.levels.ERROR)
					end
				elseif type(cfg) == "table" and cfg.setup then
					local ok_setup, err_setup = pcall(cfg.setup)
					if not ok_setup then
						vim.notify("[Distro] config '" .. cfg_mod .. ".setup()' failed: " .. tostring(err_setup), vim.log.levels.ERROR)
					end
				end
			end
		end
		if t and t.enabled then
			t.span("loader:finish/" .. entry.name, do_finish)
		else
			do_finish()
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
	load_depth = load_depth + 1
	-- F5: finally-guard парой к флагам выше: load_depth и loading[name]
	-- всегда возвращаются, иначе одна ошибка косит счётчик и все циклы.
	local function load_body()
		local outer = load_depth == 1
		local t = trace()
		local ok
		if outer and t and t.enabled then
			-- Aggregate row for the top-level load only. pack/finish rows above
			-- are the breakdown; this is the single "what did that gd cost"
			-- number. A nested M.load (plugin config loading another plugin) must
			-- not emit its own aggregate — that is the spam case.
			ok = t.span("loader:load/" .. name, function()
				return pack_subtree(entry) and finish_subtree(entry)
			end)
		else
			ok = pack_subtree(entry) and finish_subtree(entry)
		end
		return ok
	end
	local ok, res = xpcall(load_body, function(e)
		return debug.traceback(tostring(e), 2)
	end)
	load_depth = load_depth - 1
	loading[name] = nil
	if not ok then
		vim.notify("[Distro] load '" .. name .. "' failed: " .. tostring(res):sub(1, 200), vim.log.levels.ERROR)
		return false
	end
	return res
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
			local ok_src, err_src = pcall(vim.cmd, "source " .. vim.fn.fnameescape(f))
			if not ok_src then
				vim.notify("[Distro] after/plugin failed: " .. f .. ": " .. tostring(err_src), vim.log.levels.ERROR)
			end
		end
	end
end

--- Forward-declared: stub creator (defined below, used on load-failure restore).
local boot_cmd_stub

-- Variant A streaming: deferred-load queue. Triggers don't load synchronously —
-- they kick a deduped scheduled M.load, so first paint is never blocked.
local pending = {}

local function defer_enabled()
	local ok, perf = pcall(require, "core.perf")
	if ok and perf and perf.defer_on then
		return perf.defer_on()
	end
	-- Fallback без perf: NVIM_DISTRO_SYNC + settings.perf_defer + UI.
	-- NVIM_DISTRO_SYNC=1: принудительно синхронно (CI, скрипты, детерминизм)
	if vim.env.NVIM_DISTRO_SYNC == "1" then
		return false
	end
	if require("core.settings").perf_defer == false then
		return false
	end
	-- headless/scripts: fully synchronous for determinism
	return #vim.api.nvim_list_uis() > 0
end

local function kick_deferred(name)
	if M.loaded[name] or pending[name] then
		return
	end
	pending[name] = true
	vim.schedule(function()
		pending[name] = nil
		M.load(name)
	end)
end

--- Trigger entry point for event/ft paths (cmd stubs call M.load directly:
--- an explicit user command loads NOW, not scheduled).
---
--- B2: entries with `defer_until_idle` wait for the first idle moment
--- (CursorHold/InsertLeave/VimEnter-timer) — never parse mid-typing.
local idle_queue = {}
local idle_fired = false

local function drain_idle()
	if idle_fired then
		return
	end
	idle_fired = true
	-- MINIMAL trace: один спан на idle-drain (внутренние M.load уже
	-- трейсятся сами; каждый require внутри не трогаем).
	local t = trace()
	if t and t.enabled then
		t.span("loader:idle-drain", function()
			for name in pairs(idle_queue) do
				idle_queue[name] = nil
				M.load(name)
			end
		end)
	else
		for name in pairs(idle_queue) do
			idle_queue[name] = nil
			M.load(name)
		end
	end
end

function M.kick(p)
	if p.catalog and not M.is_present(p) then
		return
	end
	if p.defer_until_idle and defer_enabled() and not idle_fired then
		idle_queue[p.name] = true
		return
	end
	if p.defer_idle and defer_enabled() then
		kick_deferred(p.name)
	else
		M.load(p.name)
	end
end

--- Perf: synchronously drain everything deferred so far (scheduled kicks
--- + idle queue). Idempotent: M.load short-circuits on M.loaded, and the
--- still-queued vim.schedule callbacks become no-ops afterwards.
--- Called by :PerfDeferOff (core.perf). Zero network by construction.
function M.drain_all()
	for name in pairs(pending) do
		pending[name] = nil
		M.load(name)
	end
	drain_idle()
	-- Гейт одноразовый только до :PerfDeferOff — возвращаем его в исходное
	-- «не сработал» состояние, иначе все последующие defer_until_idle
	-- грузились бы сразу и навсегда мимо очереди «не парсить при наборе».
	idle_fired = false
end

--- Boot: rtp + eager start plugins + lazy autocmds/commands. No network.
function M.boot()
	local cfg = cfg_path()
	vim.opt.packpath:prepend(cfg)
	-- NOTE: без wildcard (rtp:append(".../*") замедлял каждый :runtime-поиск);
	-- packadd сам правит rtp при загрузке, eager-старту хватает packpath.
	-- Отключаем неиспользуемые builtin runtime-плагины (порт lazy.nvim
	-- performance.rtp.disabled_plugins; сверено с кодом — ничего их не требует):
	-- gzip/tarPlugin/zipPlugin (правка внутри архивов), tohtml (:TOhtml),
	-- matchit (расширенный %; обычный matchparen жив и нужен).
	-- netrw/spell/tutor/matchparen НЕ трогаем (используются).
	for _, name in ipairs({ "gzip", "tarPlugin", "zipPlugin", "tohtml", "matchit" }) do
		vim.g["loaded_" .. name] = 1
	end
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
						M.kick(p)
					end,
					desc = "distro: lazy-load " .. p.name,
				})
			end
			if p.ft then
				vim.api.nvim_create_autocmd("FileType", {
					group = group,
					pattern = p.ft,
					callback = function()
						M.kick(p)
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

	-- Phase 2 (variant A): one-shot idle preload. Warms the cmp chain ~300ms
	-- after startup so the first InsertEnter is instant. Invisible if unused.
	--
	-- H3 FIX. This watchdog used to drain `pending` in ONE synchronous loop inside
	-- a single scheduled callback: every still-pending plugin was loaded back-to-
	-- back, so ~300ms after startup the user paid the whole deferred bill as a
	-- single blocking spike, usually while already typing or moving the cursor.
	-- That is the 'freezes for no visible reason' symptom (docs/distro/
	-- 10-largefile-analysis.md, hypothesis H3).
	--
	-- The tail is now drained one entry per event-loop tick. Total work is
	-- unchanged, but no single frame pays for all of it, so the editor stays
	-- responsive between slices. nvim-cmp stays on the watchdog tick because it is
	-- the first-insert path; whatever is queued behind it spills onto later ticks.
	local function flush_pending_slice()
		local name = next(pending)
		if not name then
			-- queue empty; the idle queue is a separate list, drain it as before
			drain_idle()
			return
		end
		pending[name] = nil
		M.load(name)
		vim.schedule(flush_pending_slice)
	end

	local idle_timer = vim.uv.new_timer()
	vim.api.nvim_create_autocmd("VimEnter", {
		group = group,
		once = true,
		callback = function()
			idle_timer:start(300, 0, vim.schedule_wrap(function()
				if not defer_enabled() then
					return
				end
				-- MINIMAL trace: один спан на idle-preload (внутри M.load /
				-- drain_idle уже свои спены; каждый require не трогаем).
				local t = trace()
				if t and t.enabled then
					t.span("loader:idle-preload", function()
						M.load("nvim-cmp")
						vim.schedule(flush_pending_slice)
					end)
				else
					M.load("nvim-cmp")
					vim.schedule(flush_pending_slice)
				end
			end))
		end,
		desc = "distro: idle preload",
	})
	-- B2: first idle moment drains the idle queue (highlight attach etc.).
	-- CursorHold/InsertLeave = user paused/typed-done; never mid-keystroke.
	vim.api.nvim_create_autocmd({ "CursorHold", "CursorHoldI", "InsertLeave" }, {
		group = group,
		once = true,
		callback = function()
			vim.schedule(drain_idle)
		end,
		desc = "distro: idle drain",
	})
	vim.api.nvim_create_autocmd("VimLeavePre", {
		group = group,
		once = true,
		callback = function()
			pcall(function()
				idle_timer:stop()
			end)
			pcall(function()
				idle_timer:close()
			end)
		end,
		desc = "distro: cancel idle preload",
	})
end

--- Create (or recreate) a lazy stub user command for a plugin command.
---@param c string command name, e.g. "FzfLua"
---@param p table manifest entry
boot_cmd_stub = function(c, p)
	pcall(vim.api.nvim_create_user_command, c, function(opts)
		-- Drop the stub so the plugin can register the real command.
		-- Recursion guard: if the re-dispatch below somehow re-enters this
		-- stub we must not delete-and-recreate forever.
		if vim.g["_distro_stub_inflight_" .. c] then
			vim.notify("[Distro] '" .. c .. "' stub re-entered unexpectedly", vim.log.levels.ERROR)
			return
		end
		vim.g["_distro_stub_inflight_" .. c] = true
		pcall(vim.api.nvim_del_user_command, c)
		local loaded = M.load(p.name)
		if not loaded then
			-- load failed (missing): restore stub for the next attempt.
			vim.g["_distro_stub_inflight_" .. c] = nil
			boot_cmd_stub(c, p)
			return
		end
		-- Re-dispatch to the real command now provided by the plugin.
		-- Any failure (plugin still not registering the name, bad args,
		-- runtime error inside the plugin) must put the stub back --
		-- otherwise the second invocation of the command hits a bare E492.
		local ok, err = pcall(vim.cmd, c .. " " .. (opts.args or ""))
		vim.g["_distro_stub_inflight_" .. c] = nil
		if ok then
			-- success: leave the stub gone for good
			return
		end
		boot_cmd_stub(c, p)
		vim.notify("[Distro] '" .. c .. "' failed after load: " .. tostring(err), vim.log.levels.ERROR)
	end, { nargs = "*", bang = true, complete = "command", desc = "distro lazy stub: " .. p.name })
end

--- Non-blocking status for health/UI. No network.
function M.status()
	return require("distro.lock").status()
end

return M
