-- Ручная замена lsp_signature.nvim: липкое окно сигнатуры.
-- Встроенный vim.lsp.buf.signature_help() закрывается на движении курсора,
-- поэтому рисуем свой флоат: открывается на `(`/`,`, обновляется при
-- движении внутри аргументов (debounce), умирает вне вызова / в normal.
-- Активный параметр подсвечиваем экстмарком. Ноль плагинов.
local M = {}

local state = { win = nil, buf = nil, gen = 0 }
local ns = vim.api.nvim_create_namespace("LspSignatureHint")

pcall(vim.api.nvim_set_hl, 0, "LspSignatureActiveParameter", { bold = true, underline = true })

local function sig_clients(bufnr)
	return vim.lsp.get_clients({ bufnr = bufnr or 0, method = "textDocument/signatureHelp" })
end

-- Будим парсер (в headless/первый раз дерево может спать).
local function ensure_parser(bufnr)
	local ok, parser = pcall(vim.treesitter.get_parser, bufnr, vim.bo[bufnr].filetype)
	if ok and parser then
		pcall(function()
			parser:parse(true)
		end)
	end
end

local function close()
	if state.win and vim.api.nvim_win_is_valid(state.win) then
		pcall(vim.api.nvim_win_close, state.win, true)
	end
	state.win, state.buf = nil, nil
end

-- Внутри аргументов вызова? (любой язык: ищем *argument* вверх по дереву)
local function in_call_args()
	local ok, node = pcall(vim.treesitter.get_node)
	while ok and node do
		local t = node:type()
		if t:find("argument", 1, true) then
			return true
		end
		node = node:parent()
	end
	return false
end

-- Внутри строки/коммента? (там сигнатуры нет — только шум)
local function in_string_or_comment()
	local ok, node = pcall(vim.treesitter.get_node)
	while ok and node do
		local t = node:type()
		if t:find("string", 1, true) or t:find("comment", 1, true) then
			return true
		end
		node = node:parent()
	end
	return false
end

-- Строим строки + подсветку активного параметра из ответа сервера.
-- Возвращает lines, range? (range: {row0, col0, col1-exclusive}).
function M._render(result)
	local sigs = result and result.signatures
	local sig = sigs and (sigs[(result.activeSignature or 0) + 1] or sigs[1])
	if not sig or type(sig.label) ~= "string" then
		return nil
	end
	local lines = {}
	for l in (sig.label .. "\n"):gmatch("([^\n]*)\n") do
		lines[#lines + 1] = l
	end
	local doc = sig.documentation
	local doctext = type(doc) == "table" and doc.value or doc
	if type(doctext) == "string" and doctext ~= "" then
		lines[#lines + 1] = ""
		for l in (doctext .. "\n"):gmatch("([^\n]*)\n") do
			lines[#lines + 1] = l
		end
	end
	local range = nil
	local active = result.activeParameter or 0
	local p = sig.parameters and sig.parameters[active + 1]
	if p then
		if type(p.label) == "table" then
			range = { 0, p.label[1], p.label[2] }
		elseif type(p.label) == "string" then
			local s, e = sig.label:find(p.label, 1, true)
			if s then
				range = { 0, s - 1, e }
			end
		end
	end
	return lines, range
end

local function place(lines, range)
	local width, height = 0, 0
	for _, l in ipairs(lines) do
		width = math.max(width, vim.fn.strdisplaywidth(l))
	end
	width = math.min(math.max(width, 20), 80)
	height = math.min(#lines, 10)
	local cfg = {
		relative = "cursor",
		row = 1,
		col = 0,
		width = width,
		height = height,
		style = "minimal",
		border = "rounded",
		title = " Signature ",
		focusable = false,
	}
	if state.win and vim.api.nvim_win_is_valid(state.win) then
		vim.api.nvim_win_set_config(state.win, cfg)
	else
		if not (state.buf and vim.api.nvim_buf_is_valid(state.buf)) then
			state.buf = vim.api.nvim_create_buf(false, true)
			vim.bo[state.buf].filetype = "markdown"
		end
		state.win = vim.api.nvim_open_win(state.buf, false, cfg)
	end
	vim.bo[state.buf].modifiable = true
	vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, lines)
	vim.bo[state.buf].modifiable = false
	vim.api.nvim_buf_clear_namespace(state.buf, ns, 0, -1)
	if range then
		pcall(vim.api.nvim_buf_set_extmark, state.buf, ns, range[1], range[2], {
			end_row = range[1],
			end_col = range[3],
			hl_group = "LspSignatureActiveParameter",
		})
	end
end

-- Запрос + отрисовка (асинхронно, ввод не блокируем).
local function refresh()
	local bufnr = vim.api.nvim_get_current_buf()
	if #sig_clients(bufnr) == 0 then
		close()
		return
	end
	local params = vim.lsp.util.make_position_params(0, "utf-16")
	local clients = sig_clients(bufnr)
	clients[1].request("textDocument/signatureHelp", params, function(err, result)
		if err or not result or not result.signatures or #result.signatures == 0 then
			close()
			return
		end
		-- Пока шёл ответ, могли уйти: проверяем заново.
		if vim.fn.mode() ~= "i" or not in_call_args() then
			close()
			return
		end
		local lines, range = M._render(result)
		if not lines then
			close()
			return
		end
		place(lines, range)
	end, bufnr)
end

-- Умный gs для normal mode: внутри строки/коммента курсор бесполезен —
-- переставляемся к началу аргументов ближайшего вызова, показываем,
-- возвращаем курсор (синхронно, прыжка не видно).
function M.show_smart()
	local bufnr = vim.api.nvim_get_current_buf()
	if #sig_clients(bufnr) == 0 then
		return
	end
	ensure_parser(bufnr)
	local ok, node = pcall(vim.treesitter.get_node)
	local in_bad = false
	local call = nil
	while ok and node do
		local t = node:type()
		if t:find("string", 1, true) or t:find("comment", 1, true) then
			in_bad = true
		end
		if t:find("call", 1, true) or t:find("invocation", 1, true) then
			call = node
			break
		end
		node = node:parent()
	end
	if not in_bad or not call then
		pcall(vim.lsp.buf.signature_help)
		return
	end
	-- Ищем дочерний *argument* — его начало (сама `(`; на ней gopls отвечает).
	local target = nil
	for child in call:iter_children() do
		if child:type():find("argument", 1, true) then
			local sr, sc = child:range()
			target = { sr + 1, sc }
			break
		end
	end
	if not target then
		pcall(vim.lsp.buf.signature_help)
		return
	end
	local win = vim.api.nvim_get_current_win()
	local cur = vim.api.nvim_win_get_cursor(win)
	vim.api.nvim_win_set_cursor(win, target)
	pcall(vim.lsp.buf.signature_help)
	vim.api.nvim_win_set_cursor(win, cur)
end

function M.setup()
	local group = vim.api.nvim_create_augroup("LspSignatureSticky", { clear = true })

	-- Триггеры `(` / `,`: как раньше (позиционные правила + veto),
	-- но открываем через менеджер.
	vim.api.nvim_create_autocmd("InsertCharPre", {
		group = group,
		callback = function()
			local char = vim.v.char
			if char ~= "(" and char ~= "," then
				return
			end
			if vim.fn.mode() ~= "i" then
				return
			end
			if #sig_clients(0) == 0 then
				return
			end
			if in_string_or_comment() then
				return
			end
			local line, col = unpack(vim.api.nvim_win_get_cursor(0))
			local prefix = vim.api.nvim_buf_get_lines(0, line - 1, line, true)[1]:sub(1, col)
			if char == "(" then
				if not prefix:match("[%w_%)%]]$") then
					return
				end
			else -- ",": нужна незакрытая `(` на строке
				local open, close = 0, 0
				for c in prefix:gmatch("[()]") do
					if c == "(" then
						open = open + 1
					else
						close = close + 1
					end
				end
				if open <= close then
					return
				end
			end
			vim.schedule(refresh)
		end,
	})

	-- Движение в инсерте: обновляем (debounce) или гасим вне вызова.
	-- Всё тело под pcall: любая ошибка обязана гасить окно, а не сиротить его.
	vim.api.nvim_create_autocmd("CursorMovedI", {
		group = group,
		callback = function()
			state.gen = state.gen + 1
			local g = state.gen
			vim.defer_fn(function()
				if g ~= state.gen then
					return
				end
				local ok, res = pcall(function()
					if vim.fn.mode() ~= "i" then
						return "close"
					end
					if #sig_clients(0) == 0 then
						return "close"
					end
					if in_call_args() then
						return "refresh"
					end
					return "close"
				end)
				if not ok or res ~= "refresh" then
					close()
				elseif res == "refresh" then
					refresh()
				end
			end, 200)
		end,
	})

	-- Уход: гасим всегда. CursorMoved (нормал) страхует случаи,
	-- когда флоат пережил insert (смена окна на тот же буфер и т.п.).
	vim.api.nvim_create_autocmd({ "InsertLeave", "BufLeave", "WinLeave" }, {
		group = group,
		callback = close,
	})
	vim.api.nvim_create_autocmd("CursorMoved", {
		group = group,
		callback = function()
			if vim.fn.mode() ~= "i" then
				close()
			end
		end,
	})
end

return M
