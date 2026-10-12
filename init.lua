-- Минимальная версия: 0.12.5 — текущая рабочая версия дистрибутива; sidekick.nvim
-- требует >= 0.11.2, ниже по API (vim.lsp.config/enable, vim.lsp.completion) — 0.11.
-- На старом nvim вместо каскада криптических ошибок — одно понятное сообщение.
if vim.fn.has("nvim-0.12.5") ~= 1 then
	local ver = vim.fn.execute("version"):match("NVIM v(%S+)") or "?"
	vim.notify("[core] This config requires Neovim >= 0.12.5 (you have " .. ver .. ")", vim.log.levels.ERROR)
	return
end

if not vim.g.vscode then
	vim.g.start_time = vim.fn.reltime() -- для check_startup в :ConfigHealth
	-- Perf flags: read FIRST, before require("core") builds anything
	-- (settings merge, DistroLazy autocmds). SYNC keeps determinism.
	-- Каноника: NVIM_PERF_DEFER / NVIM_PERF_LEAN. Deprecated-алиасы:
	-- NVIM_TURBO / NVIM_TURBO_MODE -> perf_defer, NVIM_WEAK_HW=1 -> perf_lean.
	if vim.env.NVIM_DISTRO_SYNC ~= "1" then
		local defer_env = vim.env.NVIM_PERF_DEFER
		if defer_env == "1"
			or vim.env.NVIM_TURBO == "1"
			or vim.env.NVIM_TURBO_MODE == "1" then
			vim.g.perf_defer = true
			vim.g.turbo = true
		elseif defer_env == "0" then
			vim.g.perf_defer = false
			vim.g.turbo = false
		end
		if vim.env.NVIM_PERF_LEAN == "1" or vim.env.NVIM_WEAK_HW == "1" then
			vim.g.perf_lean = true
			vim.g.weak_hw = true
		elseif vim.env.NVIM_PERF_LEAN == "0" then
			vim.g.perf_lean = false
			vim.g.weak_hw = false
		end
	end
	require("core")
end
