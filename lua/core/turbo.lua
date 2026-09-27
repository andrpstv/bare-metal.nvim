-- core.turbo — DEPRECATED shim over core/perf (perf 4->2).
-- Каноника: settings.perf_defer. Этот модуль сохранён для совместимости:
-- :TurboOn/:TurboOff/:TurboStatus работают как раньше, но дергают perf.
-- Zero-cost: require("core.perf") только внутри вызовов.
local M = {}

local function perf()
	local ok, p = pcall(require, "core.perf")
	if ok then
		return p
	end
	return nil
end

--- True when deferred behavior is active (== perf.defer_on()).
---@return boolean
function M.is_on()
	local p = perf()
	if p then
		return p.defer_on()
	end
	if vim.env.NVIM_DISTRO_SYNC == "1" then
		return false
	end
	if vim.env.NVIM_TURBO == "1" or vim.env.NVIM_TURBO_MODE == "1" then
		return true
	end
	return vim.g.turbo == true or vim.g.turbo == 1
end

function M.enable()
	local p = perf()
	if p then
		p.defer_enable()
		return
	end
	vim.g.turbo = true
	vim.notify("[turbo] ON — applies to future loads (new buffers)", vim.log.levels.INFO)
end

function M.disable()
	local p = perf()
	if p then
		p.defer_disable()
		return
	end
	vim.g.turbo = false
	local ok_loader, loader = pcall(require, "distro.loader")
	if ok_loader and loader and loader.drain_all then
		pcall(loader.drain_all)
	end
	local ok_theme, theme = pcall(require, "themes.black-metal-khold")
	if ok_theme and theme and theme.apply_pending then
		pcall(theme.apply_pending)
	end
	vim.notify("[turbo] OFF — deferred work drained", vim.log.levels.INFO)
end

---@return string "TURBO ON" | "TURBO OFF"
function M.status()
	return M.is_on() and "TURBO ON" or "TURBO OFF"
end

function M.setup()
	vim.api.nvim_create_user_command("TurboOn", function()
		M.enable()
	end, { desc = "turbo: enable deferred mode for future loads" })
	vim.api.nvim_create_user_command("TurboOff", function()
		M.disable()
	end, { desc = "turbo: disable + drain deferred work synchronously" })
	vim.api.nvim_create_user_command("TurboStatus", function()
		local env = vim.env.NVIM_TURBO or vim.env.NVIM_TURBO_MODE or "-"
		vim.notify(M.status() .. " (env=" .. env .. ")", vim.log.levels.INFO)
	end, { desc = "turbo: show ON/OFF (no side effects)" })
end

return M
