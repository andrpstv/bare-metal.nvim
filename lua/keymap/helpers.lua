_G._command_panel = function()
	_G._pick_extra("commands")
end

-- Безопасный вызов mini.pick / mini.extra: догружает mini.nvim через distro loader.
-- Ноль внешних зависимостей (rg/git опционально ускоряют builtin-пикеры).
local function _pick_ensure()
	pcall(function()
		require("distro.loader").load("mini.nvim")
	end)
	local ok, pick = pcall(require, "mini.pick")
	if not ok then
		vim.notify("[pick] mini.pick unavailable", vim.log.levels.ERROR, { title = "pick" })
		return nil
	end
	return pick
end

---Builtin-пикер mini.pick: files, grep_live, buffers, help, oldfiles, resume.
---@param fn string
---@param opts table|nil
_G._pick = function(fn, opts)
	local pick = _pick_ensure()
	if not pick then
		return
	end
	if type(pick.builtin[fn]) ~= "function" then
		vim.notify("[pick] unknown builtin picker: " .. fn, vim.log.levels.ERROR, { title = "pick" })
		return
	end
	pick.builtin[fn](opts)
end

---Пикеры mini.extra (тот же монорепо): commands, buf_lines, git_branches, history...
---@param fn string
---@param opts table|nil
_G._pick_extra = function(fn, opts)
	if not _pick_ensure() then
		return
	end
	local ok, extra = pcall(require, "mini.extra")
	if not ok or type(extra.pickers[fn]) ~= "function" then
		vim.notify("[pick] unknown extra picker: " .. fn, vim.log.levels.ERROR, { title = "pick" })
		return
	end
	extra.pickers[fn](opts)
end

---LSP через mini.extra: definition|references|implementation|type_definition|
---document_symbol|workspace_symbol_live. opts.jump1: один результат — прыгнуть сразу.
---@param scope string
---@param opts table|nil
_G._pick_lsp = function(scope, opts)
	opts = opts or {}
	if not _pick_ensure() then
		return
	end
	if opts.jump1 then
		local method = "textDocument/" .. (scope == "type_definition" and "typeDefinition" or scope == "references" and "references" or scope == "implementation" and "implementation" or "definition")
		if #vim.lsp.get_clients({ bufnr = 0, method = method }) == 0 then
			vim.notify("[lsp] no client for " .. scope .. " here", vim.log.levels.INFO, { title = "lsp" })
			return
		end
		local params = vim.lsp.util.make_position_params(0, "utf-16")
		-- Async: никогда не фризим UI (раньше buf_request_sync(2000) висел на висящем gopls).
		-- Сторож: если ответа нет 2с — предупреждаем (раньше это делал сам timeout sync).
		local req_buf = vim.api.nvim_get_current_buf()
		local responded = false
		vim.defer_fn(function()
			if not responded and vim.api.nvim_buf_is_valid(req_buf) then
				vim.notify("[lsp] slow response (" .. scope .. "), server busy?", vim.log.levels.WARN, { title = "lsp" })
			end
		end, 2000)
		vim.lsp.buf_request(0, method, params, function(err, result)
			responded = true
			if err then
				vim.notify("[lsp] gopls busy (" .. scope .. ")", vim.log.levels.WARN, { title = "lsp" })
				return
			end
			local locs = {}
			if result then
				if result.uri then
					locs[1] = result
				else
					locs = result
				end
			end
			if #locs == 1 then
				local ok_item, item = pcall(vim.lsp.util.locations_to_items, locs, "utf-16")
				item = ok_item and item[1] or nil
				if item then
					vim.cmd.edit(vim.fn.fnameescape(item.filename))
					pcall(vim.api.nvim_win_set_cursor, 0, { item.lnum, item.col - 1 })
					return
				end
			elseif #locs == 0 then
				vim.notify("[lsp] no results for " .. scope, vim.log.levels.INFO, { title = "lsp" })
				return
			end
			-- 2+ результатов: падаем в пикер ниже
			local ok2, extra2 = pcall(require, "mini.extra")
			if ok2 then
				extra2.pickers.lsp({ scope = scope })
			end
		end)
		return
	end
	local ok, extra = pcall(require, "mini.extra")
	if not ok then
		vim.notify("[pick] mini.extra unavailable", vim.log.levels.ERROR, { title = "pick" })
		return
	end
	extra.pickers.lsp({ scope = scope })
end

---Grep по визуальному выделению (первая строка, буквально).
_G._pick_grep_visual = function()
	local pick = _pick_ensure()
	if not pick then
		return
	end
	local a = vim.fn.getpos("v")
	local b = vim.fn.getpos(".")
	local ok, lines = pcall(vim.fn.getregion, a, b, { type = vim.fn.visualmode() })
	local text = ok and lines and lines[1] or nil
	text = text and text:match("^%s*(.-)%s*$") or ""
	if text == "" then
		vim.notify("[pick] select text first", vim.log.levels.WARN, { title = "pick" })
		return
	end
	pick.builtin.grep({ pattern = text, method = "plain" })
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
	if #vim.lsp.get_clients({ bufnr = 0, method = "textDocument/inlayHint" }) == 0 then
		vim.notify("No inlay-hint client here", vim.log.levels.INFO, { title = "LSP Inlay Hint" })
		return
	end
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

-- Go: подставить возвращаемые значения вызова в переменные (как Alt+Enter в GoLand).
-- `load(2)` -> `data, err := load(2)`; вложенный вызов извлекается строкой выше.
-- Нужны treesitter-go и живой gopls; только простые случаи, иначе подскажет.
-- Шаги 3-4 (парсинг сигнатуры -> правка) — чистая функция от sig, вызывается
-- из async hover-цепочки ниже, чтобы UI никогда не блокировался.
local function go_assign_apply(sig, bufnr, node)

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
	local ok_r, sr, sc, er, ec = pcall(function()
		return node:range()
	end)
	if not ok_r then
		return
	end
	local line = vim.api.nvim_buf_get_lines(bufnr, sr, sr + 1, true)[1] or ""
	local before = line:sub(1, sc)
	if before:match("[:=]%s*$") or before:match("=%s*$") or before:match("%f[%w]return%f[%W]") then
		vim.notify("[go] already assigned?", vim.log.levels.INFO, { title = "go" })
		return
	end

	local lhs = table.concat(names, ", ") .. " := "
	local ok_t, calltext = pcall(vim.treesitter.get_node_text, node, bufnr)
	if not ok_t or not calltext then
		return
	end
	local ok_p, parent = pcall(function()
		return node:parent()
	end)
	parent = ok_p and parent or nil
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

_G._go_assign_vars = function()
	local bufnr = vim.api.nvim_get_current_buf()
	if vim.bo[bufnr].filetype ~= "go" then
		vim.notify("[go] assign works in Go files only", vim.log.levels.WARN, { title = "go" })
		return
	end
	if #vim.lsp.get_clients({ bufnr = bufnr, method = "textDocument/hover" }) == 0 then
		vim.notify("[go] no hover client (gopls not attached?)", vim.log.levels.WARN, { title = "go" })
		return
	end

	-- 1. Вызов под курсором (берём самый внутренний).
	local ok_parser, parser = pcall(vim.treesitter.get_parser, bufnr, "go")
	if not ok_parser or not parser then
		vim.notify("[go] no treesitter Go parser (:TSInstall go)", vim.log.levels.WARN, { title = "go" })
		return
	end
	pcall(function()
		parser:parse(true)
	end)
	local ok_node, node = pcall(vim.treesitter.get_node)
	if ok_node and node then
		local ok_walk, top = pcall(function()
			while node and node:type() ~= "call_expression" do
				node = node:parent()
			end
			return node
		end)
		if ok_walk then
			node = top
		else
			node = nil
		end
	end
	if not node then
		vim.notify("[go] no call under cursor", vim.log.levels.WARN, { title = "go" })
		return
	end
	local ok_field, fnodes = pcall(function()
		return node:field("function")
	end)
	local fnode = ok_field and (type(fnodes) == "table" and fnodes[1] or fnodes) or nil
	if not fnode then
		return
	end
	local ok_range, fr, fc, er, ec = pcall(function()
		return fnode:range()
	end)
	if not ok_range then
		return
	end

	-- 2. Сигнатура через hover gopls — async цепочка (UI не блокируется никогда).
	-- Ховерим КОНЕЦ имени функции, затем начало; первая годная сигнатура побеждает.
	local positions = { { line = er, character = ec - 1 }, { line = fr, character = fc } }
	local function sig_of(result)
		local c = result and result.contents
		local text = type(c) == "table" and c.value or type(c) == "string" and c or ""
		for line in text:gmatch("[^\n]+") do
			if line:match("^func%s") then
				return line
			end
		end
		return nil
	end
	local function try_pos(i)
		if i > #positions then
			vim.notify("[go] cannot get signature (cursor on function name?)", vim.log.levels.WARN, { title = "go" })
			return
		end
		local pos = positions[i]
		local params = { textDocument = { uri = vim.uri_from_bufnr(bufnr) }, position = pos }
		local responded = false
		vim.defer_fn(function()
			if not responded and vim.api.nvim_buf_is_valid(bufnr) then
				vim.notify("[go] slow response, gopls busy?", vim.log.levels.WARN, { title = "go" })
			end
		end, 2000)
		vim.lsp.buf_request(bufnr, "textDocument/hover", params, function(err, result)
			responded = true
			if err then
				vim.notify("[go] gopls busy, try again", vim.log.levels.WARN, { title = "go" })
				return
			end
			local sig = sig_of(result)
			if sig then
				if vim.api.nvim_buf_is_valid(bufnr) then
					go_assign_apply(sig, bufnr, node)
				end
			else
				try_pos(i + 1)
			end
		end)
	end
	try_pos(1)
end

-- Статуслайн в духе heirline ramojus (без плагинов):
-- `[NOR] fname [+] | ●[E W] [servers] %= Ln:Col |  branch(+a-r~c) | (lines size)`
-- Цвета — ссылками на группы темы (следуют за сменой colorscheme сами).
local _stl_devicons = {}
local _stl_icon_cache = {}
local function _stl_icon(filename)
	local ext = vim.fn.fnamemodify(filename, ":e")
	local cached = _stl_icon_cache[ext]
	if cached then
		return cached
	end
	local ok, dev = pcall(require, "nvim-web-devicons")
	if not ok then
		_stl_icon_cache[ext] = ""
		return ""
	end
	local icon, hl = dev.get_icon(filename, ext, { default = true })
	if not icon then
		_stl_icon_cache[ext] = ""
		return ""
	end
	if hl and not _stl_devicons[hl] then
		_stl_devicons[hl] = true
	end
	local out = (hl and ("%#" .. hl .. "#") or "") .. icon .. "%* "
	_stl_icon_cache[ext] = out
	return out
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
local _stl_lsp_cache = {}
local _stl_git_cache = {}
-- Счётчики диагностик: единственный дорогой кусок статуслайна (был get() на redraw).
-- Обновляется по DiagnosticChanged, на redraw только читается.
local _stl_diag_cache = {}

-- Нормализация bufnr: callers historically pass 0 (= current), but caches and
-- invalidations must key on the REAL buffer id, otherwise entries never clear.
local function _stl_buf(bufnr)
	if not bufnr or bufnr == 0 then
		return vim.api.nvim_get_current_buf()
	end
	return bufnr
end

local function _stl_count_diags(bufnr)
	local e, w, it, h = 0, 0, 0, 0
	for _, d in ipairs(vim.diagnostic.get(bufnr)) do
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
	return { e, w, it, h }
end

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
	-- держим кэш маленьким (32 последних), таблицу не сносим целиком
	_stl_size_cache[key] = out
	local n = 0
	for _ in pairs(_stl_size_cache) do
		n = n + 1
	end
	if n > 32 then
		_stl_size_cache = { [key] = out }
	end
	return out
end

local function _stl_get_lsp_names(bufnr)
	bufnr = _stl_buf(bufnr)
	local cached = _stl_lsp_cache[bufnr]
	if cached then
		return cached
	end
	local names = {}
	for _, c in ipairs(vim.lsp.get_clients({ bufnr = bufnr })) do
		names[#names + 1] = c.name
	end
	_stl_lsp_cache[bufnr] = names
	return names
end

local function _stl_get_git_status(bufnr)
	bufnr = _stl_buf(bufnr)
	local cached = _stl_git_cache[bufnr]
	if cached then
		return cached
	end
	local gsd = vim.b[bufnr].gitsigns_status_dict
	if not (gsd and gsd.head and gsd.head ~= "") then
		_stl_git_cache[bufnr] = nil
		return nil
	end
	local g = { "  " .. gsd.head }
	local a, r, ch = gsd.added or 0, gsd.removed or 0, gsd.changed or 0
	if a + r + ch > 0 then
		local cnt = {}
		if a > 0 then cnt[#cnt + 1] = "+" .. a end
		if r > 0 then cnt[#cnt + 1] = "-" .. r end
		if ch > 0 then cnt[#cnt + 1] = "~" .. ch end
		g[#g + 1] = " (%#Comment#" .. table.concat(cnt, " ") .. "%*)"
	end
	local result = table.concat(g) .. " "
	_stl_git_cache[bufnr] = result
	return result
end

-- Инвалидация кэшей.
local _stl_augroup = vim.api.nvim_create_augroup("StlCache", { clear = true })
pcall(vim.api.nvim_create_autocmd, { "BufEnter", "BufWritePost" }, {
	group = _stl_augroup,
	callback = function()
		vim.b.stl_size_tick = (vim.b.stl_size_tick or 0) + 1
	end,
})
pcall(vim.api.nvim_create_autocmd, { "LspAttach", "LspDetach" }, {
	group = _stl_augroup,
	callback = function(args)
		_stl_lsp_cache[args.buf] = nil
	end,
})
pcall(vim.api.nvim_create_autocmd, { "BufWritePost", "FocusGained", "BufEnter" }, {
	group = _stl_augroup,
	callback = function(args)
		_stl_git_cache[args.buf] = nil
	end,
})
pcall(vim.api.nvim_create_autocmd, "DiagnosticChanged", {
	group = _stl_augroup,
	callback = function(args)
		_stl_diag_cache[args.buf] = _stl_count_diags(args.buf)
	end,
})
pcall(vim.api.nvim_create_autocmd, { "BufWipeout", "BufDelete" }, {
	group = _stl_augroup,
	callback = function(args)
		_stl_lsp_cache[args.buf] = nil
		_stl_git_cache[args.buf] = nil
		_stl_diag_cache[args.buf] = nil
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
		-- Диагностика: читаем кэш DiagnosticChanged (никаких get() на redraw).
		local bufnr = vim.api.nvim_get_current_buf()
		local dc = _stl_diag_cache[bufnr]
		if not dc then
			dc = _stl_count_diags(bufnr)
			_stl_diag_cache[bufnr] = dc
		end
		local e, w, it, h = dc[1], dc[2], dc[3], dc[4]
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
		-- LSP-серверы (cached).
		local names = _stl_get_lsp_names(0)
		if #names > 0 then
			parts[#parts + 1] = " [" .. table.concat(names, " ") .. "]"
		end
		parts[#parts + 1] = "%="
		-- Ruler + git (cached) + meta.
		parts[#parts + 1] = "%5(%l:%c%) "
		local git_status = _stl_get_git_status(0)
		if git_status then
			parts[#parts + 1] = git_status
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
vim.api.nvim_create_autocmd("ModeChanged", { group = _stl_augroup, command = "redrawstatus" })
