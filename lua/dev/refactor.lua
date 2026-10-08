-- dev.refactor — LSP-рефакторинг без плагинов: call hierarchy + selection range.
--
-- gopls отдаёт оба метода из коробки; не хватало только тонкого клиента
-- в стиле существующего type_hierarchy (async, quickfix, честные нотифаи).
-- Keymaps — buffer-local в keymap.completion.lsp (аддитивно, старые не тронуты).

local M = {}

--- Call hierarchy: prepare → incoming/outgoing → quickfix.
---@param kind "incoming"|"outgoing"
function M.calls(kind)
	local bufnr = vim.api.nvim_get_current_buf()
	local params = vim.lsp.util.make_position_params(0, "utf-16")
	local method = kind == "incoming" and "callHierarchy/incomingCalls" or "callHierarchy/outgoingCalls"
	vim.lsp.buf_request(bufnr, "textDocument/prepareCallHierarchy", params, function(err, result)
		if err or not result or vim.tbl_isempty(result) then
			vim.notify("[lsp] no call hierarchy here", vim.log.levels.INFO, { title = "lsp" })
			return
		end
		local pending, items = 0, {}
		local done = function()
			pending = pending - 1
			if pending == 0 then
				if #items == 0 then
					vim.notify("[lsp] empty " .. kind .. " calls", vim.log.levels.INFO, { title = "lsp" })
					return
				end
				vim.fn.setqflist({}, " ", { title = "LSP " .. kind .. " calls", items = items })
				vim.cmd("copen")
			end
		end
		for _, item in ipairs(result) do
			pending = pending + 1
			vim.lsp.buf_request(bufnr, method, { item = item }, function(err2, res2)
				if not err2 and res2 then
					for _, call in ipairs(res2) do
						local loc = call.fromRanges and { uri = call.from.uri, range = call.fromRanges[1] }
							or (call.to and { uri = call.to.uri, range = call.to.selectionRange or call.to.range })
						if loc then
							vim.list_extend(items, vim.lsp.util.locations_to_items({ loc }, "utf-16"))
						end
					end
				end
				done()
			end)
		end
	end)
end

-- Selection range: стек родительских диапазонов на буфер.
-- Expand в normal-mode от курсора; shrink откатывает. Visual не трогаем
-- (там живёт свой select-механизм сниппетов/текст-объектов).

---@param dir 1|-1
local function shift_selection(dir)
	local bufnr = vim.api.nvim_get_current_buf()
	vim.b[bufnr].dev_sel_stack = vim.b[bufnr].dev_sel_stack or {}
	local stack = vim.b[bufnr].dev_sel_stack
	-- Визуально выделить диапазон {start_line(0-based), start_char, end_line, end_char}.
	-- NOTE: vim.b[bufnr].key возвращает КОПИЮ таблицы при каждом чтении —
	-- мутации локала теряются, поэтому после push/pop пишем стек обратно.
	local function apply(r)
		stack[#stack + 1] = { r.start.line, r.start.character, r["end"].line, r["end"].character }
		vim.b[bufnr].dev_sel_stack = stack
		-- Курсор в начало, v + в конец.
		pcall(vim.api.nvim_win_set_cursor, 0, { r.start.line + 1, r.start.character })
		vim.cmd("normal! v")
		pcall(vim.api.nvim_win_set_cursor, 0, { r["end"].line + 1, math.max(0, r["end"].character - 1) })
	end
	if dir < 0 then
		local cur = table.remove(stack)
		vim.b[bufnr].dev_sel_stack = stack
		if not cur then
			vim.notify("[lsp] nothing to shrink", vim.log.levels.INFO, { title = "lsp" })
			return
		end
		local prev = stack[#stack]
		if not prev then
			pcall(vim.api.nvim_win_set_cursor, 0, { cur[1] + 1, cur[2] })
			return
		end
		-- Перевыделить предыдущий уровень.
		pcall(vim.api.nvim_win_set_cursor, 0, { prev[1] + 1, prev[2] })
		vim.cmd("normal! v")
		pcall(vim.api.nvim_win_set_cursor, 0, { prev[3] + 1, math.max(0, prev[4] - 1) })
		return
	end
	local params
	if #stack == 0 then
		local pos = vim.api.nvim_win_get_cursor(0)
		params = { textDocument = vim.lsp.util.make_text_document_params(bufnr), positions = { { line = pos[1] - 1, character = pos[2] } } }
	else
		local top = stack[#stack]
		params = { textDocument = vim.lsp.util.make_text_document_params(bufnr), positions = { { line = top[1], character = top[2] } } }
	end
	vim.lsp.buf_request(bufnr, "textDocument/selectionRange", params, function(err, result)
		if err or not result or vim.tbl_isempty(result) or not result[1] or not result[1].range then
			vim.notify("[lsp] no selection range here", vim.log.levels.INFO, { title = "lsp" })
			return
		end
		-- Цепочка parent идёт от innermost к outermost. Первый expand
		-- берёт innermost (result[1]), следующие — первый диапазон,
		-- СТРОГО содержащий текущий (иначе один ve сразу выделял весь файл).
		local function strictly_contains(outer, inner)
			local os, oe = outer.start, outer["end"]
			local is_, ie = inner.start, inner["end"]
			local starts_before = os.line < is_.line or (os.line == is_.line and os.character < is_.character)
			local ends_after = oe.line > ie.line or (oe.line == ie.line and oe.character > ie.character)
			return starts_before or ends_after
		end
		local cur = nil
		if #stack > 0 then
			local top = stack[#stack]
			cur = {
				start = { line = top[1], character = top[2] },
				["end"] = { line = top[3], character = top[4] },
			}
		end
		local node = result[1]
		local target = nil
		if not cur then
			target = node.range
		else
			while node do
				if node.range and strictly_contains(node.range, cur) then
					target = node.range
					break
				end
				node = node.parent
			end
		end
		if not target then
			vim.notify("[lsp] already at outermost", vim.log.levels.INFO, { title = "lsp" })
			return
		end
		apply(target)
	end)
end

function M.expand()
	shift_selection(1)
end

function M.shrink()
	shift_selection(-1)
end

--- Переименование с записью затронутых файлов.
--- Проблема голого vim.lsp.buf.rename(): правки в ДРУГИХ файлах остаются
--- в скрытых несохранённых буферах без единого хинта — пользователь
--- запускает тесты по старому коду и думает, что rename не сработал.
--- Пишем ровно те буферы, которые rename и запачкал (уже грязные до нас —
--- не трогаем, только считаем для хинта). Не Jalopy: :wa писал бы вообще всё.
function M.rename()
	local bufnr = vim.api.nvim_get_current_buf()
	local clients = vim.lsp.get_clients({ bufnr = bufnr, method = "textDocument/rename" })
	if #clients == 0 then
		vim.notify("[lsp] no rename client here", vim.log.levels.WARN, { title = "lsp" })
		return
	end
	local cur = vim.fn.expand("<cword>")
	vim.ui.input({ prompt = "New Name: ", default = cur }, function(name)
		if not name or name == "" or name == cur then
			return
		end
		-- Снимок ДО: пишем только буферы, которые rename реально тронул
		-- (changedtick), из них — только чистые до нас. Чужие грязные
		-- буферы не трогаем вообще (даже не считаем).
		local before = {}
		for _, b in ipairs(vim.api.nvim_list_bufs()) do
			if vim.api.nvim_buf_is_loaded(b) then
				before[b] = { tick = vim.api.nvim_buf_get_changedtick(b), dirty = vim.bo[b].modified }
			end
		end
		local params = vim.lsp.util.make_position_params(0, "utf-16")
		params.newName = name
		vim.lsp.buf_request(bufnr, "textDocument/rename", params, function(err, result)
			if err then
				vim.notify(
					"[lsp] rename failed: " .. tostring(err.message or err.code),
					vim.log.levels.ERROR,
					{ title = "lsp" }
				)
				return
			end
			if not result then
				vim.notify("[lsp] rename: server declined", vim.log.levels.WARN, { title = "lsp" })
				return
			end
			local ok_a, err_a = pcall(vim.lsp.util.apply_workspace_edit, result, "utf-16")
			if not ok_a then
				vim.notify("[lsp] rename apply failed: " .. tostring(err_a):sub(1, 160), vim.log.levels.ERROR, { title = "lsp" })
				return
			end
			-- Запись затронутого (и только его). Буферы, созданные самим
			-- apply (их не было в снимке) — тоже rename-тронутые: пишем.
			local saved, skipped = 0, 0
			for _, b in ipairs(vim.api.nvim_list_bufs()) do
				local snap = before[b]
				local touched = snap and vim.api.nvim_buf_get_changedtick(b) ~= snap.tick
					or (not snap and vim.api.nvim_buf_is_loaded(b) and vim.bo[b].modified)
				if touched then
					if snap and snap.dirty then
						skipped = skipped + 1
					else
						local ok_w = pcall(vim.api.nvim_buf_call, b, function()
							vim.cmd("silent! update")
						end)
						if ok_w and not vim.bo[b].modified then
							saved = saved + 1
						else
							skipped = skipped + 1
						end
					end
				end
			end
			local msg = "[lsp] renamed → " .. name .. " (saved " .. saved .. " file(s)"
			if skipped > 0 then
				msg = msg .. ", " .. skipped .. " left unsaved (were dirty)"
			end
			vim.notify(msg .. ")", vim.log.levels.INFO, { title = "lsp" })
		end)
	end)
end

return M
