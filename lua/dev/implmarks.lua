-- dev.implmarks — метки «implements» у Go-типов: спиннер при запросе, затем расширение имён за ~150ms.
--   type X interface { ->  ◆ 2 implementations · A, B   (к-во типов в порядке gopls, ≤3 имён +N)
--   type X struct {    ->  ◇ Reader, Stringer             (интерфейсы; не больше 3, дальше +N)
--
-- Почему свой: готовых плагинов нет, а gopls уже отвечает на textDocument/implementation — нужен только
-- тонкий слой: запросы асинхронно, только по видимому диапазону, с кэшем по changedtick. Один ticker на буфер.
-- Анимация отключена в headless (determinism) или при disabled animations.

local M = {}

local ns = vim.api.nvim_create_namespace("dev_implmarks")
local MARGIN = 50 -- строк сверх видимого диапазона
local MAX_REQ = 20 -- запросов за один refresh
local MAX_NAMES = 3
local METHOD = "textDocument/implementation"
local SPINNER_FRAMES = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }
local SPINNER_MS = 80

-- Инициализация highlight-групп с fallback на Comment
vim.api.nvim_set_hl(0, "DevImpl", { link = "Comment", default = true })
vim.api.nvim_set_hl(0, "DevImplCount", { link = "Comment", default = true })
vim.api.nvim_set_hl(0, "DevImplName", { link = "Comment", default = true })

---@type table<integer, { tick: integer, done: table<integer, boolean>, pending: table<integer, boolean>, loading: table<integer, boolean>, ids: table<integer, integer> }>
local state = {}
local spin = {} -- buf -> stop() общего спиннера буфера

local function spin_stop(buf)
	if spin[buf] then
		spin[buf]()
		spin[buf] = nil
	end
end


--- Спиннер кадр по индексу (циклический).
---@param i integer
---@return string
function M._frame(i)
	return SPINNER_FRAMES[((i - 1) % #SPINNER_FRAMES) + 1]
end

--- Подмена источника клиентов в тестах.
---@type fun(buf: integer): table[]
function M._clients(buf)
	return vim.lsp.get_clients({ bufnr = buf, method = METHOD })
end

--- Объявления типов в строках [srow, erow] (0-based) по treesitter.
---@return { row: integer, col: integer, name: string, kind: "interface"|"other" }[]
function M._types(buf, srow, erow)
	local ok, parser = pcall(vim.treesitter.get_parser, buf, "go")
	if not ok or not parser then
		return {}
	end
	parser:parse({ srow, erow + 1 })
	local ok_q, query = pcall(vim.treesitter.query.parse, "go", "(type_spec name: (type_identifier) @n type: (_) @t)")
	if not ok_q then
		return {}
	end
	local res = {}
	for _, tree in ipairs(parser:trees()) do
		for _, match in query:iter_matches(tree:root(), buf, srow, erow + 1) do
			local n, t = match[1], match[2]
			-- с 0.11 в матчах списки нод
			n = type(n) == "table" and n[1] or n
			t = type(t) == "table" and t[1] or t
			if n and t then
				local row, col = n:range()
				res[#res + 1] = {
					row = row,
					col = col,
					name = vim.treesitter.get_node_text(n, buf),
					kind = t:type() == "interface_type" and "interface" or "other",
				}
			end
		end
	end
	table.sort(res, function(a, b)
		return a.row < b.row
	end)
	return res
end

--- Чанки метки: { {text, group}, ... }; nil — нечего показывать.
---@param kind "interface"|"other"
---@param names string[]  для interface — реализации, для other — интерфейсы
---@return table?  список {text, highlight_group} или nil
function M._format(kind, names)
	-- Дедупликация
	local seen = {}
	local deduped = {}
	for _, n in ipairs(names) do
		if not seen[n] then
			seen[n] = true
			deduped[#deduped + 1] = n
		end
	end
	names = deduped

	if #names == 0 then
		if kind == "interface" then
			return { { "◆", "DevImpl" }, { " no implementations", "DevImpl" } }
		end
		return nil
	end
	if kind == "interface" then
		local count_text = #names == 1 and "1 implementation" or ("%d implementations"):format(#names)
		local chunks = { { "◆", "DevImpl" }, { " " .. count_text, "DevImplCount" }, { " · ", "DevImpl" } }
		local shown = vim.list_slice(names, 1, MAX_NAMES)
		for i, name in ipairs(shown) do
			if i > 1 then
				table.insert(chunks, { ", ", "DevImpl" })
			end
			table.insert(chunks, { name, "DevImplName" })
		end
		if #names > MAX_NAMES then
			table.insert(chunks, { " +" .. (#names - MAX_NAMES), "DevImpl" })
		end
		return chunks
	end
	local chunks = { { "◇ ", "DevImpl" }, { table.concat(vim.list_slice(names, 1, MAX_NAMES), ", "), "DevImplName" } }
	if #names > MAX_NAMES then
		chunks[#chunks + 1] = { (" +%d"):format(#names - MAX_NAMES), "DevImpl" }
	end
	return chunks
end

function M.clear(buf)
	buf = (buf and buf ~= 0) and buf or vim.api.nvim_get_current_buf()
	spin_stop(buf)
	if vim.api.nvim_buf_is_valid(buf) then
		vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
	end
	state[buf] = nil
end

--- Строка цели: из загруженного буфера, иначе читаем с диска только до нужной строки.
local function line_at(path, lnum)
	-- bufnr(path) ищет по шаблону — сверяем имя точно.
	local b = vim.fn.bufnr(path)
	if b > 0 and vim.api.nvim_buf_is_loaded(b) and vim.api.nvim_buf_get_name(b) == path then
		return vim.api.nvim_buf_get_lines(b, lnum, lnum + 1, false)[1]
	end
	local ok, lines = pcall(vim.fn.readfile, path, "", lnum + 1)
	return ok and lines[lnum + 1] or nil
end

--- Имена типов из результата implementation (Location | LocationLink, список или одиночный).
local function names_from(result, cur_dir)
	if result and (result.uri or result.targetUri) then
		result = { result }
	end
	local names = {}
	for _, loc in ipairs(result or {}) do
		local uri = loc.uri or loc.targetUri
		local pos = (loc.range or loc.targetSelectionRange or loc.targetRange or {}).start
		if uri and pos then
			local path = vim.uri_to_fname(uri)
			local line = line_at(path, pos.line)
			local name
			if line then
				-- shortcut: колонка LSP как байтовая; для ASCII-идентификаторов после `type ` верно
				name = line:sub(pos.character + 1):match("^[%w_]+")
			end
			if name then
				local dir = vim.fs.dirname(path)
				-- Нормализуем пути для корректного сравнения (особенно на macOS с /private)
				if vim.fn.resolve(dir) ~= vim.fn.resolve(cur_dir) then
					name = vim.fs.basename(dir) .. "." .. name
				end
				names[#names + 1] = name
			end
		end
	end
	return names
end

local function ensure_highlights()
	-- Переустанавливаем highlights после hi clear темы (идемпотентно)
	vim.api.nvim_set_hl(0, "DevImpl", { link = "Comment", default = true })
	vim.api.nvim_set_hl(0, "DevImplCount", { link = "Comment", default = true })
	vim.api.nvim_set_hl(0, "DevImplName", { link = "Comment", default = true })
end

-- Одна метка на строку: id переиспользуется, кадры заменяют друг друга, а не копятся.
local function put(buf, st, row, chunks)
	if row < vim.api.nvim_buf_line_count(buf) then
		st.ids[row] = vim.api.nvim_buf_set_extmark(buf, ns, row, 0, { id = st.ids[row], virt_text = chunks, virt_text_pos = "eol" })
	end
end

local function drop(buf, st, row)
	if st.ids[row] then
		pcall(vim.api.nvim_buf_del_extmark, buf, ns, st.ids[row])
		st.ids[row] = nil
	end
end

-- Пока gopls считает — у интерфейса крутится «◆ ⠹»: один тикер на буфер, сам гаснет, когда ждать нечего.
local function loading(buf, st, t)
	if t.kind ~= "interface" then
		return -- у структур метка появляется только с ответом
	end
	ensure_highlights()
	local fx = require("dev.fx")
	st.loading[t.row] = true
	put(buf, st, t.row, { { "◆ " .. (fx.enabled() and M._frame(1) or "…"), "DevImpl" } })
	if spin[buf] or not fx.enabled() then
		return
	end
	spin[buf] = fx.ticker(SPINNER_MS, function(i)
		local cur = state[buf]
		if not cur or not next(cur.loading) or not vim.api.nvim_buf_is_valid(buf) then
			spin[buf] = nil
			return false
		end
		for row in pairs(cur.loading) do
			put(buf, cur, row, { { "◆ " .. M._frame(i), "DevImpl" } })
		end
	end)
end

-- Ответ «печатается» слева направо за ~150 мс; режем по символам, не байтам («◆», «·»).
local function reveal(buf, st, t, names)
	st.loading[t.row] = nil
	ensure_highlights()
	local chunks = M._format(t.kind, names)
	if not chunks then
		drop(buf, st, t.row)
		return
	end
	local fx = require("dev.fx")
	if not fx.enabled() then
		put(buf, st, t.row, chunks)
		return
	end
	local total = 0
	for _, c in ipairs(chunks) do
		total = total + vim.fn.strchars(c[1])
	end
	fx.ticker(50, function(i)
		if state[buf] ~= st or not vim.api.nvim_buf_is_valid(buf) then
			return false -- буфер правили: метки уже сброшены
		end
		local out, left = {}, i >= 3 and total or math.ceil(total * i / 3)
		for _, c in ipairs(chunks) do
			if left <= 0 then
				break
			end
			local len = vim.fn.strchars(c[1])
			out[#out + 1] = { len <= left and c[1] or vim.fn.strcharpart(c[1], 0, left), c[2] }
			left = left - len
		end
		put(buf, st, t.row, out)
		return i < 3
	end)
end

function M.refresh(buf)
	buf = (buf and buf ~= 0) and buf or vim.api.nvim_get_current_buf()
	if not vim.api.nvim_buf_is_valid(buf) or vim.bo[buf].filetype ~= "go" or vim.b[buf].large_file then
		return
	end
	local client = M._clients(buf)[1]
	if not client then
		return
	end
	local tick = vim.api.nvim_buf_get_changedtick(buf)
	local st = state[buf]
	if not st or st.tick ~= tick then
		spin_stop(buf)
		vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
		st = { tick = tick, done = {}, pending = {}, loading = {}, ids = {} }
		state[buf] = st
	end

	-- окно буфера: текущее, иначе первое показывающее его
	local win = vim.api.nvim_get_current_win()
	if vim.api.nvim_win_get_buf(win) ~= buf then
		win = vim.fn.win_findbuf(buf)[1]
	end
	local top, bot = 1, vim.api.nvim_buf_line_count(buf)
	if win then
		top = vim.api.nvim_win_call(win, function()
			return vim.fn.line("w0")
		end)
		bot = vim.api.nvim_win_call(win, function()
			return vim.fn.line("w$")
		end)
	end
	local srow = math.max(0, top - 1 - MARGIN)
	local erow = math.min(vim.api.nvim_buf_line_count(buf) - 1, bot - 1 + MARGIN)
	local cur_dir = vim.fs.dirname(vim.api.nvim_buf_get_name(buf))
	local enc = client.offset_encoding or "utf-16"

	local sent = 0
	for _, t in ipairs(M._types(buf, srow, erow)) do
		if sent >= MAX_REQ then
			break
		end
		if not st.done[t.row] and not st.pending[t.row] then
			sent = sent + 1
			st.pending[t.row] = true
			loading(buf, st, t)
			local line = vim.api.nvim_buf_get_lines(buf, t.row, t.row + 1, false)[1] or ""
			local ok, ch = pcall(vim.str_utfindex, line, enc, t.col, false)
			local params = {
				textDocument = { uri = vim.uri_from_bufnr(buf) },
				position = { line = t.row, character = ok and ch or t.col },
			}
			client:request(METHOD, params, function(err, result)
				local cur = state[buf]
				-- ответ устарел: буфер правили (строки съехали) или закрыли
				if not cur or cur.tick ~= tick or not vim.api.nvim_buf_is_valid(buf) then
					return
				end
				cur.pending[t.row] = nil
				if err then
					cur.loading[t.row] = nil
					drop(buf, cur, t.row) -- не оставлять крутящийся спиннер на ошибке
					return
				end
				cur.done[t.row] = true
				reveal(buf, cur, t, names_from(result, cur_dir))
			end, buf)
		end
	end
end

return M
