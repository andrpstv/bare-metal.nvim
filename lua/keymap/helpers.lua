_G._command_panel = function()
	_G._fzf("commands")
end

-- Безопасный вызов fzf-lua: догружает плагин через lazy, если он ещё спит.
-- Без этого require("fzf-lua") падает с "module not found" до первой загрузки.
---@param fn string @имя пикера, например "files"
---@param opts table|fun(fzf: table):table|nil
_G._fzf = function(fn, opts)
	pcall(function()
		require("lazy").load({ plugins = { "fzf-lua" } })
	end)
	local ok, fzf = pcall(require, "fzf-lua")
	if not ok or type(fzf[fn]) ~= "function" then
		vim.notify("[fzf] picker unavailable: " .. fn, vim.log.levels.ERROR, { title = "fzf" })
		return
	end
	if type(opts) == "function" then
		opts = opts(fzf)
	end
	fzf[fn](opts)
end

_G._flash_esc_or_noh = function()
	local flash_active, state = pcall(function()
		return require("flash.plugins.char").state
	end)
	if flash_active and state then
		state:hide()
	else
		pcall(vim.cmd.noh)
	end
end

_G._toggle_inlayhint = function()
	local is_enabled = vim.lsp.inlay_hint.is_enabled({ bufnr = 0 })
	vim.lsp.inlay_hint.enable(not is_enabled)
	vim.notify(
		(is_enabled and "Inlay hint disabled successfully" or "Inlay hint enabled successfully"),
		vim.log.levels.INFO,
		{ title = "LSP Inlay Hint" }
	)
end

_G._toggle_virtuallines = function()
	local current = vim.diagnostic.config().virtual_lines
	vim.diagnostic.config({ virtual_lines = not current })
	vim.notify(
		"Virtual lines are now " .. (current and "hidden" or "displayed"),
		vim.log.levels.INFO,
		{ title = "LSP Diagnostic" }
	)
end

-- Сегмент статуслайна с LSP: имена приаттаченных к буферу серверов.
-- Вызывается из 'statusline' (%{%}), обновляется при перерисовке.
_G._lsp_status = function()
	local clients = vim.lsp.get_clients({ bufnr = 0 })
	if #clients == 0 then
		return ""
	end
	local names = {}
	for _, c in ipairs(clients) do
		names[#names + 1] = c.name
	end
	return " LSP:" .. table.concat(names, ",")
end

-- Дописываем сегмент к дефолтному статуслайну (ноль плагинов).
vim.opt.statusline:append("%{%v:lua._lsp_status()%}")

-- Сегмент режима (showmode выключен в options, т.к. раньше рисовал lualine).
local mode_names = {
	n = "NORMAL",
	i = "INSERT",
	v = "VISUAL",
	V = "V-LINE",
	["\22"] = "V-BLOCK",
	s = "SELECT",
	S = "S-LINE",
	["\19"] = "S-BLOCK",
	R = "REPLACE",
	c = "COMMAND",
	t = "TERMINAL",
}
_G._mode_status = function()
	return "[" .. (mode_names[vim.api.nvim_get_mode().mode] or "??") .. "] "
end
vim.opt.statusline:prepend("%{%v:lua._mode_status()%}")
