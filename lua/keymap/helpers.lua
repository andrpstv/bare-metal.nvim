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

-- Тоггл quickfix одним хоткеем вместо пары открыть/закрыть.
_G._toggle_qf = function()
	for _, win in ipairs(vim.api.nvim_list_wins()) do
		if vim.fn.getwininfo(win)[1].quickfix == 1 then
			vim.cmd("cclose")
			return
		end
	end
	vim.cmd("copen")
end

-- Дописываем сегмент к дефолтному статуслайну (ноль плагинов).
vim.opt.statusline:append("%{%v:lua._lsp_status()%}")

-- Go: подставить возвращаемые значения вызова в переменные (как Alt+Enter в GoLand).
-- `load(2)` -> `data, err := load(2)`; вложенный вызов извлекается строкой выше.
-- Нужны treesitter-go и живой gopls; только простые случаи, иначе подскажет.
_G._go_assign_vars = function()
	local bufnr = vim.api.nvim_get_current_buf()
	if vim.bo[bufnr].filetype ~= "go" then
		vim.notify("[go] assign works in Go files only", vim.log.levels.WARN, { title = "go" })
		return
	end

	-- 1. Вызов под курсором (берём самый внутренний).
	-- Парсер может спать (headless/первый вызов) — будим явно.
	local ok_parser, parser = pcall(vim.treesitter.get_parser, bufnr, "go")
	if not ok_parser or not parser then
		vim.notify("[go] no treesitter Go parser (:TSInstall go)", vim.log.levels.WARN, { title = "go" })
		return
	end
	parser:parse(true)
	local node = vim.treesitter.get_node()
	while node and node:type() ~= "call_expression" do
		node = node:parent()
	end
	if not node then
		vim.notify("[go] no call under cursor", vim.log.levels.WARN, { title = "go" })
		return
	end
	local fnodes = node:field("function")
	local fnode = type(fnodes) == "table" and fnodes[1] or fnodes
	if not fnode then
		return
	end

	-- 2. Сигнатура через hover gopls (точный источник типов).
	local fr, fc = fnode:range()
	local resp = vim.lsp.buf_request_sync(
		bufnr,
		"textDocument/hover",
		{ textDocument = { uri = vim.uri_from_bufnr(bufnr) }, position = { line = fr, character = fc } },
		2000
	)
	local sig = nil
	for _, res in pairs(resp or {}) do
		local c = res.result and res.result.contents
		local text = type(c) == "table" and c.value or type(c) == "string" and c or ""
		for line in text:gmatch("[^\n]+") do
			if line:match("^func%s") then
				sig = line
				break
			end
		end
		if sig then
			break
		end
	end
	if not sig then
		vim.notify("[go] cannot get signature (cursor on function name?)", vim.log.levels.WARN, { title = "go" })
		return
	end

	-- 3. Парсим возвращаемые: всё после закрывающей скобки параметров.
	local i = sig:find("%(")
	if not i then
		return
	end
	local depth, j = 0, i
	while j <= #sig do
		local ch = sig:sub(j, j)
		if ch == "(" then
			depth = depth + 1
		elseif ch == ")" then
			depth = depth - 1
			if depth == 0 then
				break
			end
		end
		j = j + 1
	end
	local rets = sig:sub(j + 1):match("^%s*(.-)%s*$")
	if rets == "" then
		vim.notify("[go] function returns nothing", vim.log.levels.INFO, { title = "go" })
		return
	end
	if rets:sub(1, 1) == "(" then
		rets = rets:sub(2, -2)
	end
	-- Делим по запятым верхнего уровня (map/chan/func внутри не рвём).
	local parts, cur, d2 = {}, "", 0
	for k = 1, #rets + 1 do
		local ch = rets:sub(k, k)
		if ch == "" or (ch == "," and d2 == 0) then
			if cur:match("%S") then
				parts[#parts + 1] = cur:match("^%s*(.-)%s*$")
			end
			cur = ""
		else
			if ch == "(" or ch == "[" or ch == "{" then
				d2 = d2 + 1
			elseif ch == ")" or ch == "]" or ch == "}" then
				d2 = d2 - 1
			end
			cur = cur .. ch
		end
	end

	-- 4. Имена переменных: объявленные берём, остальные генерим из типов.
	local builtins = {
		string = 1, bool = 1, any = 1, byte = 1, rune = 1,
		int = 1, int8 = 1, int16 = 1, int32 = 1, int64 = 1,
		uint = 1, uint8 = 1, uint16 = 1, uint32 = 1, uint64 = 1, uintptr = 1,
		float32 = 1, float64 = 1, complex64 = 1, complex128 = 1,
	}
	local function var_for(typ)
		local t = typ:gsub("^%s*%*+", ""):gsub("^%s*%.%.%.%s*", "")
		t = t:gsub("^%s*%[%]%s*", ""):gsub("^%s*chan%s+", "")
		t = t:match("%.([%w_]+)$") or t:match("^([%w_]+)") or ""
		if t:lower() == "error" then
			return "err"
		end
		if t == "" or builtins[t] or builtins[t:lower()] then
			return "result"
		end
		return t:sub(1, 1):lower() .. t:sub(2)
	end
	local names, used, pending = {}, {}, {}
	local function take(name)
		if name == "_" then
			names[#names + 1] = "_"
			return
		end
		local base, k = name, 0
		while used[name] do
			k = k + 1
			name = base .. k
		end
		used[name] = true
		names[#names + 1] = name
	end
	for _, p in ipairs(parts) do
		local toks = {}
		for w in p:gmatch("%S+") do
			toks[#toks + 1] = w
		end
		if #toks == 0 then
			-- pass
		elseif #toks == 1 and toks[1]:match("^[%w_]+$") then
			-- Голый идентификатор: имя (если дальше `b int`) или тип
			-- (если в конце) — решаем позже, пока копим.
			pending[#pending + 1] = toks[1]
		elseif #toks == 2 and toks[1]:match("^[%w_]+$") then
			-- `x int`: накопленное — имена под этот тип.
			for _, n in ipairs(pending) do
				take(n)
			end
			pending = {}
			take(toks[1])
		else
			-- Часть со знаками (`*Data`, `[]byte`, `map[string]int`) —
			-- всегда безымянный тип; накопленное перед ней — тоже типы.
			for _, n in ipairs(pending) do
				take(var_for(n))
			end
			pending = {}
			take(var_for(p))
		end
	end
	for _, n in ipairs(pending) do
		take(var_for(n))
	end
	if #names == 0 then
		return
	end
	-- Уже присвоено? (`x := f()`, `return f()`)
	local sr, sc, er, ec = node:range()
	local line = vim.api.nvim_buf_get_lines(bufnr, sr, sr + 1, true)[1] or ""
	local before = line:sub(1, sc)
	if before:match("[:=]%s*$") or before:match("=%s*$") or before:match("%f[%w]return%f[%W]") then
		vim.notify("[go] already assigned?", vim.log.levels.INFO, { title = "go" })
		return
	end

	local lhs = table.concat(names, ", ") .. " := "
	local calltext = vim.treesitter.get_node_text(node, bufnr)
	local parent = node:parent()
	if parent and parent:type() == "expression_statement" then
		-- Отдельный стейтмент: `load(2)` -> `data, err := load(2)`
		vim.api.nvim_buf_set_text(bufnr, sr, sc, er, ec, { lhs .. calltext })
	else
		-- Вложенный вызов и только 1 результат: извлекаем строкой выше.
		if #names ~= 1 then
			vim.notify("[go] nested multi-return call: assign manually", vim.log.levels.WARN, { title = "go" })
			return
		end
		local indent = line:match("^(%s*)") or ""
		vim.api.nvim_buf_set_lines(bufnr, sr, sr, true, { indent .. lhs .. calltext })
		-- Диапазон съехал на строку вниз после вставки.
		vim.api.nvim_buf_set_text(bufnr, sr + 1, sc, er + 1, ec, { names[1] })
	end
end

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
