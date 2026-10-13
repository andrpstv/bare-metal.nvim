-- dev.implmarks — метки «implements» у Go-типов (как значки на полях в GoLand), виртуальным текстом в конце строки:
--   type X interface {  ->  ◆ 3 impl           (сколько типов её реализуют)
--   type X struct {     ->  ◇ Reader, Stringer (какие интерфейсы реализует; не больше 3, дальше +N)
--
-- Почему свой: готовых плагинов нет, а gopls уже отвечает на textDocument/implementation — нужен только
-- тонкий слой: запросы асинхронно, только по видимому диапазону, с кэшем по changedtick. Запрос в пути
-- не повторяется, а не выбрасывается: gopls после старта отвечает секундами, дольше паузы CursorHold. Триггер (CursorHold/BufEnter с дебаунсом) подключает вызывающий.
-- Только существующие highlight-группы (Comment): отложенный `hi clear` темы стирает кастомные.

local M = {}

local ns = vim.api.nvim_create_namespace("dev_implmarks")
local MARGIN = 50 -- строк сверх видимого диапазона
local MAX_REQ = 20 -- запросов за один refresh
local MAX_NAMES = 3
local METHOD = "textDocument/implementation"

---@type table<integer, { tick: integer, done: table<integer, boolean>, pending: table<integer, boolean> }>
local state = {}

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

--- Текст метки; nil — нечего показывать.
---@param kind "interface"|"other"
---@param names string[]  для interface — реализации (важна длина), для other — интерфейсы
function M._format(kind, names)
	if #names == 0 then
		return nil
	end
	if kind == "interface" then
		return ("◆ %d impl"):format(#names)
	end
	local shown = vim.list_slice(names, 1, MAX_NAMES)
	local s = "◇ " .. table.concat(shown, ", ")
	if #names > MAX_NAMES then
		s = s .. (" +%d"):format(#names - MAX_NAMES)
	end
	return s
end

function M.clear(buf)
	buf = (buf and buf ~= 0) and buf or vim.api.nvim_get_current_buf()
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
				if dir ~= cur_dir then
					name = vim.fs.basename(dir) .. "." .. name
				end
				names[#names + 1] = name
			end
		end
	end
	return names
end

local function render(buf, t, names)
	local text = M._format(t.kind, names)
	if not text or t.row >= vim.api.nvim_buf_line_count(buf) then
		return
	end
	vim.api.nvim_buf_set_extmark(buf, ns, t.row, 0, { virt_text = { { text, "Comment" } }, virt_text_pos = "eol" })
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
		vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
		st = { tick = tick, done = {}, pending = {} }
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
					return
				end
				cur.done[t.row] = true
				render(buf, t, names_from(result, cur_dir))
			end, buf)
		end
	end
end

return M
