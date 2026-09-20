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
	-- Ховерим КОНЕЦ имени функции: у методов поле function — селектор
	-- `p.Talk`, и начало указывает на переменную, а не на метод.
	local fr, fc, er, ec = fnode:range()
	local resp = nil
	for _, pos in ipairs({ { line = er, character = ec - 1 }, { line = fr, character = fc } }) do
		resp = vim.lsp.buf_request_sync(
			bufnr,
			"textDocument/hover",
			{ textDocument = { uri = vim.uri_from_bufnr(bufnr) }, position = pos },
			2000
		)
		local got = false
		for _, res in pairs(resp or {}) do
			local c = res.result and res.result.contents
			local text = type(c) == "table" and c.value or type(c) == "string" and c or ""
			if text:find("\nfunc%s") or text:match("^func%s") then
				got = true
				break
			end
		end
		if got then
			break
		end
		resp = nil
	end
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
	-- Пропускаем ресивер `func (p T)` и type-параметры `func F[T any]`.
	local function skip_balanced(s, open_c, close_c)
		local depth, k = 0, 1
		while k <= #s do
			local ch = s:sub(k, k)
			if ch == open_c then
				depth = depth + 1
			elseif ch == close_c then
				depth = depth - 1
				if depth == 0 then
					return s:sub(k + 1):match("^%s*(.*)$")
				end
			end
			k = k + 1
		end
		return nil
	end
	local rest = sig:match("^func%s*(.-)%s*$")
	if not rest then
		return
	end
	if rest:sub(1, 1) == "(" then -- receiver `(p Person)`
		rest = skip_balanced(rest, "(", ")")
		if not rest then
			return
		end
	end
	-- rest = `Name...`: пропускаем имя до `(` параметров, по пути
	-- скипая `[...]` generic-параметров (`Min[T any](a T) T`).
	local i, sqd = nil, 0
	for k = 1, #rest do
		local ch = rest:sub(k, k)
		if ch == "[" then
			sqd = sqd + 1
		elseif ch == "]" then
			sqd = sqd - 1
		elseif ch == "(" and sqd == 0 then
			i = k
			break
		end
	end
	if not i then
		return
	end
	local depth, j = 0, i
	while j <= #rest do
		local ch = rest:sub(j, j)
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
	local rets = rest:sub(j + 1):match("^%s*(.-)%s*$")
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

-- Статуслайн в духе heirline ramojus (без плагинов):
-- `[NOR] fname [+] | ●[E W] [servers] %= Ln:Col |  branch(+a-r~c) | (lines size)`
-- Цвета — ссылками на группы темы (следуют за сменой colorscheme сами).
local _stl_devicons = {}
local function _stl_icon(filename)
	local ok, dev = pcall(require, "nvim-web-devicons")
	if not ok then
		return ""
	end
	local icon, hl = dev.get_icon(filename, vim.fn.fnamemodify(filename, ":e"), { default = true })
	if not icon then
		return ""
	end
	if hl and not _stl_devicons[hl] then
		_stl_devicons[hl] = true
	end
	return (hl and ("%#" .. hl .. "#") or "") .. icon .. "%* "
end

local _stl_modes = {
	n = "NOR", no = "NOR", nov = "NOR", niI = "NOR", niR = "NOR", niV = "NOR",
	v = "VIS", vs = "VIS", V = "VIl", Vs = "VIS", ["\22"] = "VIb", ["\22s"] = "VIb",
	s = "SEL", S = "SEl", ["\19"] = "SEb",
	i = "INS", ic = "INS", ix = "INS",
	R = "REP", Rc = "REP", Rx = "REP", Rv = "REP", Rvc = "REP", Rvx = "REP",
	c = "CMD", cv = "CMD", r = "···", rm = "···", ["r?"] = "···", ["!"] = "···",
	t = "TER",
}
local _stl_mode_hl = {
	n = "Comment", i = "String", v = "Keyword", V = "Keyword", ["\22"] = "Keyword",
	s = "Constant", S = "Constant", ["\19"] = "Constant",
	R = "DiagnosticWarn", r = "DiagnosticWarn", c = "Type", t = "DiagnosticError",
}

local _stl_size_cache = {}
local function _stl_human_size()
	local bufname = vim.api.nvim_buf_get_name(0)
	-- Кэш на BufEnter/BufWritePost: getfsize = stat syscall на каждый redraw.
	local tick = (vim.b.stl_size_tick or 0)
	local key = bufname .. ":" .. tick
	local cached = _stl_size_cache[key]
	if cached then
		return cached
	end
	local suffix = { "b", "k", "M", "G" }
	local fsize = vim.fn.getfsize(bufname)
	fsize = (fsize < 0 and 0) or fsize
	local out
	if fsize < 1024 then
		out = fsize .. suffix[1]
	else
		local i = math.floor(math.log(fsize) / math.log(1024))
		out = string.format("%.2g%s", fsize / math.pow(1024, i), suffix[i + 1])
	end
	-- держим кэш маленьким
	_stl_size_cache = { [key] = out }
	return out
end
-- Инвалидация кэша размера на входе/записи буфера.
pcall(vim.api.nvim_create_autocmd, { "BufEnter", "BufWritePost" }, {
	callback = function()
		vim.b.stl_size_tick = (vim.b.stl_size_tick or 0) + 1
	end,
})

_G._statusline = function()
	local ok, line = pcall(function()
		local parts = {}
		-- Режим-пилюля.
		local m = vim.api.nvim_get_mode().mode
		local m1 = m:sub(1, 1)
		local grp = _stl_mode_hl[m] or _stl_mode_hl[m1] or "Comment"
		parts[#parts + 1] = "%#" .. grp .. "# " .. (_stl_modes[m] or m) .. " %*"
		-- Файл: иконка + имя + флаги.
		local fname = vim.api.nvim_buf_get_name(0)
		if vim.bo.filetype == "netrw" then
			parts[#parts + 1] = "Files"
		elseif fname == "" then
			parts[#parts + 1] = "[No Name]"
		else
			parts[#parts + 1] = _stl_icon(fname) .. vim.fn.fnamemodify(fname, ":.")
			if vim.bo.modified then
				parts[#parts + 1] = " [+]"
			end
			if not vim.bo.modifiable or vim.bo.readonly then
				parts[#parts + 1] = "%#DiagnosticError#[-]%*"
			end
		end
		parts[#parts + 1] = "%<"
		-- Диагностика: один get() + подсчёт в Lua (было 4 скана на redraw).
		local diags = vim.diagnostic.get(0)
		local e, w, it, h = 0, 0, 0, 0
		for _, d in ipairs(diags) do
			if d.severity == vim.diagnostic.severity.ERROR then
				e = e + 1
			elseif d.severity == vim.diagnostic.severity.WARN then
				w = w + 1
			elseif d.severity == vim.diagnostic.severity.INFO then
				it = it + 1
			elseif d.severity == vim.diagnostic.severity.HINT then
				h = h + 1
			end
		end
		if e + w + it + h > 0 then
			local d = { "%#DiagnosticError#●%*" .. "[" }
			if e > 0 then
				d[#d + 1] = "%#DiagnosticError# " .. e .. "%*"
			end
			if w > 0 then
				d[#d + 1] = "%#DiagnosticWarn# " .. w .. "%*"
			end
			if it > 0 then
				d[#d + 1] = "%#DiagnosticInfo# " .. it .. "%*"
			end
			if h > 0 then
				d[#d + 1] = "%#DiagnosticHint# " .. h .. "%*"
			end
			d[#d + 1] = " ]"
			parts[#parts + 1] = " " .. table.concat(d)
		end
		-- LSP-серверы.
		local names = {}
		for _, c in ipairs(vim.lsp.get_clients({ bufnr = 0 })) do
			names[#names + 1] = c.name
		end
		if #names > 0 then
			parts[#parts + 1] = " [" .. table.concat(names, " ") .. "]"
		end
		parts[#parts + 1] = "%="
		-- Ruler + git + meta.
		parts[#parts + 1] = "%5(%l:%c%) "
		local gsd = vim.b.gitsigns_status_dict
		if gsd and gsd.head and gsd.head ~= "" then
			local g = { "  " .. gsd.head }
			local a, r, ch = gsd.added or 0, gsd.removed or 0, gsd.changed or 0
			if a + r + ch > 0 then
				local cnt = {}
				if a > 0 then
					cnt[#cnt + 1] = "+" .. a
				end
				if r > 0 then
					cnt[#cnt + 1] = "-" .. r
				end
				if ch > 0 then
					cnt[#cnt + 1] = "~" .. ch
				end
				g[#g + 1] = " (%#Comment#" .. table.concat(cnt, " ") .. "%*)"
			end
			parts[#parts + 1] = table.concat(g) .. " "
		end
		parts[#parts + 1] = "(%L " .. _stl_human_size() .. ")"
		return table.concat(parts, " ")
	end)
	if ok then
		return line
	end
	return " %f %l:%c "
end

vim.opt.statusline = "%!v:lua._statusline()"

-- Как у ramojus: перерисовывать статуслайн при смене режима.
vim.api.nvim_create_autocmd("ModeChanged", { command = "redrawstatus" })
