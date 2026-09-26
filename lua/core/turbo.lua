-- core.turbo — Turbo-mode flag + commands. Zero-cost by design:
-- no requires, no executable()/stat probes, only env/g reads.
-- Callers MUST query M.is_on() lazily (never cache): :TurboOn in-session
-- affects FUTURE loads without restart.
local M = {}

--- True when turbo behavior is active.
--- Priority: NVIM_DISTRO_SYNC=1 (headless/CI determinism) overrides → false.
--- Env NVIM_TURBO=1 or NVIM_TURBO_MODE=1 enables; otherwise vim.g.turbo.
---@return boolean
function M.is_on()
	if vim.env.NVIM_DISTRO_SYNC == "1" then
		return false
	end
	if vim.env.NVIM_TURBO == "1" or vim.env.NVIM_TURBO_MODE == "1" then
		return true
	end
	return vim.g.turbo == true or vim.g.turbo == 1
end

--- Enable turbo for FUTURE loads. Already-loaded modules are NOT unloaded
--- (unloading cmp/lspconfig would break gd/gr).
function M.enable()
	vim.g.turbo = true
	vim.notify("[turbo] ON — applies to future loads (new buffers)", vim.log.levels.INFO)
end

--- Disable turbo + synchronously drain deferred work so behavior
--- returns to the current 1-to-1 path.
function M.disable()
	vim.g.turbo = false
	-- Drain distro idle/deferred queues synchronously (best-effort, pcall).
	local ok_loader, loader = pcall(require, "distro.loader")
	if ok_loader and loader and loader.drain_all then
		pcall(loader.drain_all)
	end
	-- Apply khold custom highlights now if still pending (best-effort).
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

--- Register :TurboOn / :TurboOff / :TurboStatus. Called from core/init.lua
--- load_core (next to :ConfigHealth). No side effects on load order.
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
