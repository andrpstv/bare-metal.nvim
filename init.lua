-- Минимальная версия: конфиг использует API Neovim 0.11+
-- (vim.lsp.config/enable, vim.lsp.completion и др.).
-- На старом nvim вместо каскада криптических ошибок — одно понятное сообщение.
if vim.fn.has("nvim-0.11") ~= 1 then
	local ver = vim.fn.execute("version"):match("NVIM v(%S+)") or "?"
	vim.notify("[core] This config requires Neovim >= 0.11 (you have " .. ver .. ")", vim.log.levels.ERROR)
	return
end

if not vim.g.vscode then
	vim.g.start_time = vim.fn.reltime() -- для check_startup в :ConfigHealth
	-- Turbo flag: read FIRST, before require("core") builds anything
	-- (settings merge, DistroLazy autocmds). SYNC keeps determinism.
	if vim.env.NVIM_DISTRO_SYNC ~= "1"
		and (vim.env.NVIM_TURBO == "1" or vim.env.NVIM_TURBO_MODE == "1") then
		vim.g.turbo = true
	end
	require("core")
end
