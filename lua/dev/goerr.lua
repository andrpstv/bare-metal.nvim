-- dev.goerr — тихая обработка ошибок в Go: блок `if err != nil { <один оператор> }` рисуется
-- цветом Comment, а по тумблеру 3-строчный блок схлопывается в одну строку (conceal_lines + eol-текст).
-- Почему свой: в ядре есть treesitter и extmarks, а плагин ради одного запроса и пары extmark-ов
-- был бы тяжелее и не знал бы про наши large_file/дебаунс.

local M = {}

local ns = vim.api.nvim_create_namespace("dev_goerr")
local MAX_LINES = 20000
local DEBOUNCE = 200
local MAX_STMT = 60

local QUERY = [[
(if_statement
  condition: (binary_expression
    left: (identifier) @l
    operator: "!="
    right: (nil))
  consequence: (block (statement_list) @list)
  !alternative) @if
]]

---@type table<integer, { timer: uv.uv_timer_t, collapse: boolean, saved: table<integer, table> }>
local state = {}

---@param buf integer
---@return { srow: integer, erow: integer, stmt: string }[]
function M._blocks(buf)
	local out = {}
	local ok, parser = pcall(vim.treesitter.get_parser, buf, "go", { error = false })
	if not ok or not parser then
		return out
	end
	local tree = parser:parse()[1]
	if not tree then
		return out
	end
	local qok, query = pcall(vim.treesitter.query.parse, "go", QUERY)
	if not qok then
		return out
	end
	for _, match in query:iter_matches(tree:root(), buf, 0, -1) do
		local function node(name)
			for id, n in pairs(match) do
				if query.captures[id] == name then
					return type(n) == "table" and n[1] or n
				end
			end
		end
		local l, list, ifn = node("l"), node("list"), node("if")
		if l and list and ifn and vim.treesitter.get_node_text(l, buf) == "err" then
			local stmts = {}
			for child in list:iter_children() do
				if child:named() and child:type() ~= "comment" then
					stmts[#stmts + 1] = child
				end
			end
			if #stmts == 1 then
				local srow, _, erow = ifn:range()
				local text = vim.treesitter.get_node_text(stmts[1], buf):gsub("%s*\n%s*", " ")
				out[#out + 1] = { srow = srow, erow = erow, stmt = vim.trim(text) }
			end
		end
	end
	return out
end

-- Свои значения окна запоминаем только при включении, чтобы выключение вернуло именно их.
local function apply_win(buf, w)
	local st = state[buf]
	if not st or not vim.api.nvim_win_is_valid(w) or vim.api.nvim_win_get_buf(w) ~= buf then
		return
	end
	local function set(name, v)
		vim.api.nvim_set_option_value(name, v, { scope = "local", win = w })
	end
	local function get(name)
		return vim.api.nvim_get_option_value(name, { scope = "local", win = w })
	end
	if st.collapse then
		if not st.saved[w] then
			st.saved[w] = { conceallevel = get("conceallevel"), concealcursor = get("concealcursor") }
		end
		-- concealcursor="" иначе строка под курсором осталась бы скрытой и править блок было бы нельзя
		set("conceallevel", 2)
		set("concealcursor", "")
	elseif st.saved[w] then
		set("conceallevel", st.saved[w].conceallevel)
		set("concealcursor", st.saved[w].concealcursor)
		st.saved[w] = nil
	end
end

local function render(buf)
	if not vim.api.nvim_buf_is_valid(buf) then
		return
	end
	vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
	if vim.api.nvim_buf_line_count(buf) > MAX_LINES then
		return
	end
	local st = state[buf]
	for _, b in ipairs(M._blocks(buf)) do
		local last = vim.api.nvim_buf_get_lines(buf, b.erow, b.erow + 1, false)[1] or ""
		vim.api.nvim_buf_set_extmark(buf, ns, b.srow, 0, {
			end_row = b.erow,
			end_col = #last,
			hl_group = "Comment",
			priority = 130,
			hl_eol = false,
		})
		if st and st.collapse and b.erow - b.srow == 2 then
			local stmt = b.stmt
			if vim.fn.strdisplaywidth(stmt) > MAX_STMT then
				stmt = vim.fn.strcharpart(stmt, 0, MAX_STMT - 1) .. "…"
			end
			vim.api.nvim_buf_set_extmark(buf, ns, b.srow, 0, {
				virt_text = { { " ⤶ " .. stmt, "Comment" } },
				virt_text_pos = "eol",
			})
			-- по одному extmark на строку: conceal_lines действует на строку старта
			for r = b.srow + 1, b.erow do
				vim.api.nvim_buf_set_extmark(buf, ns, r, 0, { conceal_lines = "" })
			end
		end
	end
	if st then
		for _, w in ipairs(vim.fn.win_findbuf(buf)) do
			apply_win(buf, w)
		end
	end
end

---@param buf integer
function M.attach(buf)
	buf = buf == 0 and vim.api.nvim_get_current_buf() or buf
	if state[buf] or vim.bo[buf].filetype ~= "go" or vim.b[buf].large_file then
		return
	end
	local timer = assert(vim.uv.new_timer())
	state[buf] = { timer = timer, collapse = false, saved = {} }
	local function schedule()
		timer:stop()
		timer:start(
			DEBOUNCE,
			0,
			vim.schedule_wrap(function()
				render(buf)
			end)
		)
	end
	local group = vim.api.nvim_create_augroup("dev_goerr_" .. buf, { clear = true })
	vim.api.nvim_create_autocmd({ "TextChanged", "InsertLeave" }, { group = group, buffer = buf, callback = schedule })
	vim.api.nvim_create_autocmd("BufWinEnter", {
		group = group,
		buffer = buf,
		callback = function()
			schedule()
			apply_win(buf, vim.api.nvim_get_current_win())
		end,
	})
	vim.api.nvim_create_autocmd("BufWipeout", {
		group = group,
		buffer = buf,
		callback = function()
			timer:stop()
			if not timer:is_closing() then
				timer:close()
			end
			state[buf] = nil
			pcall(vim.api.nvim_del_augroup_by_id, group)
		end,
	})
	-- attach зовётся из FileType, то есть внутри открытия файла: полный разбор и обход дерева
	-- там нарушили бы бюджет «Go-файл до editable» — первая отрисовка тоже через дебаунс.
	schedule()
end

---@param buf? integer
function M.toggle(buf)
	buf = (not buf or buf == 0) and vim.api.nvim_get_current_buf() or buf
	M.attach(buf)
	local st = state[buf]
	if not st then
		return
	end
	st.collapse = not st.collapse
	st.timer:stop()
	render(buf)
	vim.notify("[goerr] collapse " .. (st.collapse and "on" or "off"))
end

return M
