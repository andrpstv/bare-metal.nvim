-- dev.inlinevals — inline-значения локальных переменных (eol virtual text) при остановке дебаггера Go.
--
-- Почему свой: nvim-dap-virtual-text — отдельный плагин + treesitter-запросы; у нас уже есть слой
-- DAP-запросов (dev.inspect), а для Go хватает текстовой эвристики «последнее объявление/присваивание
-- имени выше точки останова внутри функции». Слушатели ставит attach() из debug.ensure(); на стопе —
-- одна асинхронная цепочка stackTrace -> scopes -> variables, на CursorMoved работы нет.
local M = {}

local NS = vim.api.nvim_create_namespace("dev_inlinevals")
local MAX_VARS = 50
local MAX_LEN = 40

local gen = 0 -- поколение: устаревшие async-ответы после continue/нового stop отбрасываем

local function req(sess, command, args, cb)
	local ok, err = pcall(function()
		return sess:request(command, args, function(rerr, res)
			cb(rerr, res)
		end)
	end)
	if not ok then
		cb(tostring(err):sub(1, 120), nil)
	end
end

local function fmt(v)
	local s = tostring(v.value or ""):gsub("\n", " ")
	if (v.variablesReference or 0) > 0 and (s == "" or #s > MAX_LEN) then
		return "{…}"
	end
	if vim.fn.strchars(s) > MAX_LEN then
		s = vim.fn.strcharpart(s, 0, MAX_LEN - 1) .. "…"
	end
	return s
end

-- Объявляет/присваивает ли строка имя name (func-строка — как параметр).
local function declares(line, name, is_func)
	if is_func then
		local sig = line:gsub("{.*$", "")
		return sig:find("%f[%w_]" .. vim.pesc(name) .. "%f[^%w_]") ~= nil
	end
	local rest = line:match("^%s*var%s+(.*)")
	if rest then
		rest = rest:gsub("=.*", "")
		for seg in rest:gmatch("[^,]+") do
			if seg:match("^%s*([%w_]+)") == name then
				return true
			end
		end
		return false
	end
	local lhs = line:match("^%s*(.-)%s*:?=[^=]") or line:match("^%s*(.-)%s*:?=$")
	if not lhs then
		return false
	end
	lhs = lhs:gsub("^for%s+", ""):gsub("^if%s+", ""):gsub("^switch%s+", "")
	if not lhs:match("^[%w_,%s]+$") then
		return false
	end
	for n in lhs:gmatch("[%w_]+") do
		if n == name then
			return true
		end
	end
	return false
end

--- Чистое размещение: lines (1-based таблица строк), stop_row (1-based), vars {{name,value,variablesReference}}.
---@return table<integer,string> row(1-based) -> "a = 1, b = 2"
function M._place(lines, stop_row, vars)
	local start = 1
	for r = stop_row, 1, -1 do
		if (lines[r] or ""):match("^func ") then
			start = r
			break
		end
	end
	local by_row, order = {}, {}
	for i, v in ipairs(vars) do
		if i > MAX_VARS then
			break
		end
		local name = v.name
		if name and name:sub(1, 1) ~= "~" then
			for r = stop_row, start, -1 do
				if declares(lines[r] or "", name, r == start and (lines[r] or ""):match("^func ") ~= nil) then
					if not by_row[r] then
						by_row[r] = {}
						order[#order + 1] = r
					end
					table.insert(by_row[r], name .. " = " .. fmt(v))
					break
				end
			end
		end
	end
	local out = {}
	for _, r in ipairs(order) do
		out[r] = table.concat(by_row[r], ", ")
	end
	return out
end

function M.clear()
	gen = gen + 1
	for _, b in ipairs(vim.api.nvim_list_bufs()) do
		if vim.api.nvim_buf_is_valid(b) then
			vim.api.nvim_buf_clear_namespace(b, NS, 0, -1)
		end
	end
end

local function find_buf(path)
	local want = vim.fs.normalize(path)
	for _, b in ipairs(vim.api.nvim_list_bufs()) do
		if vim.api.nvim_buf_is_loaded(b) and vim.fs.normalize(vim.api.nvim_buf_get_name(b)) == want then
			return b
		end
	end
end

function M._on_stopped(sess, body)
	M.clear()
	local my = gen
	local tid = (body and body.threadId) or sess.stopped_thread_id
	if not tid then
		return
	end
	req(sess, "stackTrace", { threadId = tid, levels = 1 }, function(err, st)
		local f = not err and st and st.stackFrames and st.stackFrames[1]
		local path = f and f.source and f.source.path
		if my ~= gen or not path or not f.line then
			return
		end
		local buf = find_buf(path)
		if not buf then
			return
		end
		req(sess, "scopes", { frameId = f.id }, function(e2, sc)
			if my ~= gen or e2 or not sc or not sc.scopes then
				return
			end
			local scope
			for _, s in ipairs(sc.scopes) do
				if s.name == "Locals" then
					scope = s
				end
			end
			scope = scope or vim.iter(sc.scopes):find(function(s)
				return not s.expensive
			end)
			if not scope or (scope.variablesReference or 0) <= 0 then
				return
			end
			req(sess, "variables", { variablesReference = scope.variablesReference }, function(e3, vs)
				if my ~= gen or e3 or not vs or not vs.variables or not vim.api.nvim_buf_is_valid(buf) then
					return
				end
				local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
				for row, text in pairs(M._place(lines, f.line, vs.variables)) do
					pcall(vim.api.nvim_buf_set_extmark, buf, NS, row - 1, 0, {
						virt_text = { { "  " .. text, "Comment" } },
						virt_text_pos = "eol",
					})
				end
			end)
		end)
	end)
end

function M.attach(dap)
	dap.listeners.after.event_stopped["dev_inlinevals"] = M._on_stopped
	-- dlv не шлёт event_continued после запроса continue/step (клиент и так знает), поэтому
	-- чистим и по самим запросам: пока программа бежит, старые значения врут.
	for _, ev in ipairs({
		"event_continued",
		"event_terminated",
		"event_exited",
		"disconnect",
		"continue",
		"next",
		"stepIn",
		"stepOut",
	}) do
		dap.listeners.after[ev]["dev_inlinevals"] = M.clear
	end
end

return M
