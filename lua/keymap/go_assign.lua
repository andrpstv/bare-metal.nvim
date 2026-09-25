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
				local m = err and (err.message or (err.code and ("code " .. tostring(err.code)) or nil)) or nil
				m = tostring(m or "unknown error"):gsub("%s+", " "):sub(1, 140)
				vim.notify("[go] hover failed: " .. m, vim.log.levels.WARN, { title = "go" })
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
