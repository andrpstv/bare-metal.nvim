local M = {}

local settings = require("core.settings")
local disabled_workspaces = settings.format_disabled_dirs
local format_on_save = settings.format_on_save
local format_modifications_only = settings.format_modifications_only
local server_formatting_block_list = settings.server_formatting_block_list
local format_timeout = settings.format_timeout
local max_lines_for_format = 5000 -- форматируем только небольшие файлы

-- Команды
vim.api.nvim_create_user_command("Format", function()
	M.format({
		timeout = format_timeout,
		filter = M.format_filter,
	})
end, {})

vim.api.nvim_create_user_command("FormatToggle", function()
	M.toggle_format_on_save()
end, {})

local block_list = settings.formatter_block_list
vim.api.nvim_create_user_command("FormatterToggleFt", function(opts)
	block_list[opts.args] = not block_list[opts.args]
	local status = not block_list[opts.args] and "enabled" or "disabled"
	vim.notify(string.format("[LSP] Formatter for [%s] %s.", opts.args, status), vim.log.levels.INFO)
end, { nargs = 1, complete = "filetype" })

-- Автоформат на сохранении
function M.enable_format_on_save()
	vim.api.nvim_create_augroup("format_on_save", { clear = true })
	vim.api.nvim_create_autocmd("BufWritePre", {
		group = "format_on_save",
		pattern = "*",
		callback = function()
			-- Skip Go files (handled by organizeImports + format in event.lua)
			if vim.bo.filetype == "go" then return end
			if vim.api.nvim_buf_line_count(0) <= max_lines_for_format then
				M.format({ filter = M.format_filter })
			end
		end,
	})
end

function M.disable_format_on_save()
	pcall(vim.api.nvim_del_augroup_by_name, "format_on_save")
end

function M.toggle_format_on_save()
	local autocmds = vim.api.nvim_get_autocmds({ group = "format_on_save", event = "BufWritePre" })
	if #autocmds > 0 then
		M.disable_format_on_save()
	else
		M.enable_format_on_save()
	end
end

-- Фильтр LSP
function M.format_filter(clients)
	return vim.tbl_filter(function(client)
		local ok = pcall(function() return client.supports_method("textDocument/formatting") end)
		if not ok then return false end
		if client.name == "null-ls" then return true end
		if server_formatting_block_list[client.name] then return false end
		return true
	end, clients)
end

function M.configure_format_on_save()
	if format_on_save then
		M.enable_format_on_save()
	else
		M.disable_format_on_save()
	end
end

-- Основная функция форматирования
function M.format(opts)
	local bufnr = opts.bufnr or vim.api.nvim_get_current_buf()
	if vim.api.nvim_buf_line_count(bufnr) > max_lines_for_format then
		return -- не форматируем большие файлы
	end

	local filedir = vim.fn.expand("%:p:h")
	for _, path in ipairs(disabled_workspaces) do
		if vim.regex(vim.fs.normalize(path)):match_str(filedir) then return end
	end

	local clients = vim.lsp.get_clients({ bufnr = bufnr })
	if opts.filter then
		clients = opts.filter(clients)
	end
	clients = vim.tbl_filter(function(client)
		return client.supports_method and client.supports_method("textDocument/formatting")
	end, clients)
	if #clients == 0 then return end

	local params = vim.lsp.util.make_formatting_params()
	for _, client in pairs(clients) do
		if block_list[vim.bo.filetype] then return end

		-- Асинхронное форматирование
		client.request("textDocument/formatting", params, function(err, result)
			if result then
				vim.lsp.util.apply_text_edits(result, bufnr, client.offset_encoding)
			end
		end, bufnr)
	end
end

return M
