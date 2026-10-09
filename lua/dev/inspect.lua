-- dev.inspect — native unified debug inspector (NO dap-ui, NO nio).
--
-- Один персистентный правый сплит с тремя секциями:
--   Frames  — стек текущего треда (current помечен, <CR> прыгает к коду)
--   Scopes  — переменные текущего фрейма (узлы с [+] раскрываются <CR>)
--   Watches — выражения пользователя (пересчитываются на каждый refresh)
-- Обновление событийное (stopped/terminated/exited/disconnect + вручную),
-- без поллинга и таймеров. Перерендер дешёвый: запросы только видимых
-- уровней (глубина/количество ограничены). Когда отладчик неактивен —
-- нулевая цена (слушатели ставятся лениво при первом открытии).
local M = {}

local PANEL_WIDTH = 40
local MAX_DEPTH = 3
local MAX_VARS = 50

local panel = nil -- {buf, win, marks}
local watches = {} -- {expr,...} переживают сессии (значения — нет)
local expanded = {} -- variablesReference -> true (сбрасывается на новый stop)
local listeners_on = false
local rendered_session = nil

local function dap_ok()
	local ok, dap = pcall(require, "dap")
	if not ok then
		return nil
	end
	return dap
end

---@return any? session
local function live_session()
	local dap = dap_ok()
	if not dap then
		return nil
	end
	return dap.session()
end

-- Синхронный DAP-запрос с аккуратным результатом (никаких assert наружу:
-- ошибки показываем инлайн, а не роняем рендер).
-- NOTE: Session:request без колбэка из main-потока — fire-and-forget
-- (результат приходит только в корутине или в on_result). Поэтому везде
-- ниже — явная callback-форма: одинаково работает с живым delve и с
-- синхронными fake-сессиями в регрессиях.
local function req(sess, command, arguments, cb)
	local ok, err = pcall(function()
		return sess:request(command, arguments, function(rerr, res)
			cb(rerr, res)
		end)
	end)
	if not ok then
		cb(tostring(err):sub(1, 120), nil)
	end
end

local function req_err(err)
	if err == nil then
		return nil
	end
	if type(err) == "table" then
		return err.message or vim.inspect(err):sub(1, 120)
	end
	return tostring(err)
end

local function current_frame_id(sess)
	local cf = sess.current_frame
	if cf and cf.id then
		return cf.id
	end
	return nil
end

local function fmt_val(v)
	if v == nil then
		return "<nil>"
	end
	v = tostring(v):gsub("\n", "\\n")
	if #v > 120 then
		return v:sub(1, 117) .. "..."
	end
	return v
end

-- lines: аккумулятор строк; marks: [lnum] -> action {kind, ...}.
-- Асинхронная цепочка (запросы идут через колбэки — только так корректно
-- из main-потока); done() зовём ровно раз, когда всё собрано.
-- expanded ключуем ПУТЁМ (scope/var/...), а не variablesReference: delve
-- выдаёт свежие номера на каждый запрос, числовой ключ протухает сразу
-- после первого же перерендера.
local function fetch_variables(sess, ref, indent, lines, marks, depth, basepath, done)
	req(sess, "variables", { variablesReference = ref }, function(err, res)
		if err or not res or not res.variables then
			lines[#lines + 1] = string.rep(" ", indent) .. "<error: " .. (req_err(err) or "no variables") .. ">"
			done()
			return
		end
		local vars = res.variables
		local i = 0
		local function next_var()
			i = i + 1
			local v = vars[i]
			if not v then
				done()
				return
			end
			if i > MAX_VARS then
				lines[#lines + 1] = string.rep(" ", indent) .. ("… +%d more"):format(#vars - MAX_VARS)
				done()
				return
			end
			local has_kids = (v.variablesReference or 0) > 0
			local vpath = basepath .. "/" .. (v.name or "?")
			local prefix = has_kids and (expanded[vpath] and "[-] " or "[+] ") or "    "
			lines[#lines + 1] = string.rep(" ", indent) .. prefix .. (v.name or "?") .. ": " .. fmt_val(v.value)
			if has_kids then
				marks[#lines] = { kind = "expand", path = vpath, ref = v.variablesReference }
				if expanded[vpath] and depth < MAX_DEPTH then
					fetch_variables(sess, v.variablesReference, indent + 2, lines, marks, depth + 1, vpath, next_var)
					return
				end
			end
			next_var()
		end
		next_var()
	end)
end

local function fetch_frames(sess, tid, lines, marks, ctx, done)
	lines[#lines + 1] = "-- frames (thread " .. tid .. ") --"
	req(sess, "stackTrace", { threadId = tid }, function(err, fr)
		if err or not fr or not fr.stackFrames then
			lines[#lines + 1] = "<error: " .. (req_err(err) or "no frames") .. ">"
		elseif #fr.stackFrames == 0 then
			lines[#lines + 1] = "(no frames)"
		else
			-- Frame ids у delve свежие на каждый stackTrace (1008, 1009…),
			-- а sess.current_frame хранит id прошлого запроса — сравнивать
			-- id в лоб нельзя. Якоримся по (name, line); не нашли — верх.
			-- Выбранный id из ЭТОЙ выборки всегда валиден для scopes/eval.
			local want_name = sess.current_frame and sess.current_frame.name
			local want_line = sess.current_frame and sess.current_frame.line
			local cur = fr.stackFrames[1]
			for _, f in ipairs(fr.stackFrames) do
				if want_name and f.name == want_name and f.line == want_line then
					cur = f
					break
				end
			end
			ctx.top_frame = cur.id
			for i, f in ipairs(fr.stackFrames) do
				if i > 20 then
					lines[#lines + 1] = ("… +%d more"):format(#fr.stackFrames - 20)
					break
				end
				local iscur = f.id == cur.id
				local src = (f.source and f.source.name or "?") .. ":" .. (f.line or "?")
				lines[#lines + 1] = (iscur and "→ " or "  ") .. (f.name or "?") .. "  " .. src
				marks[#lines] = { kind = "frame", frame = f }
			end
		end
		done()
	end)
end

local function fetch_scopes(sess, lines, marks, ctx, done)
	lines[#lines + 1] = ""
	lines[#lines + 1] = "-- scopes --"
	local fid = (ctx and ctx.top_frame) or current_frame_id(sess)
	req(sess, "scopes", fid and { frameId = fid } or nil, function(err, sc)
		if err or not sc or not sc.scopes then
			lines[#lines + 1] = "<error: " .. (req_err(err) or "no scopes") .. ">"
			done()
			return
		end
		if #sc.scopes == 0 then
			lines[#lines + 1] = "(no scopes)"
			done()
			return
		end
		local i = 0
		local function next_scope()
			i = i + 1
			local scope = sc.scopes[i]
			if not scope then
				done()
				return
			end
			lines[#lines + 1] = scope.name or "?"
			if scope.variablesReference and scope.variablesReference > 0 then
				fetch_variables(sess, scope.variablesReference, 2, lines, marks, 1, scope.name or "?", next_scope)
			else
				lines[#lines + 1] = "  (empty)"
				next_scope()
			end
		end
		next_scope()
	end)
end

local function fetch_watches(sess, lines, marks, ctx, done)
	lines[#lines + 1] = ""
	lines[#lines + 1] = "-- watches (<leader>dW add, d remove) --"
	if #watches == 0 then
		lines[#lines + 1] = "(none)"
		done()
		return
	end
	local fid = (ctx and ctx.top_frame) or current_frame_id(sess)
	local i = 0
	local function next_watch()
		i = i + 1
		local expr = watches[i]
		if not expr then
			done()
			return
		end
		local args = { expression = expr, context = "repl" }
		if fid then
			args.frameId = fid
		end
		req(sess, "evaluate", args, function(err, ev)
			if err then
				lines[#lines + 1] = expr .. " = <error: " .. req_err(err) .. ">"
			elseif not ev then
				lines[#lines + 1] = expr .. " = <error: empty response>"
			else
				lines[#lines + 1] = expr .. " = " .. fmt_val(ev.result)
			end
			marks[#lines] = { kind = "watch", index = i }
			local wpath = "watch:" .. expr
			if ev and (ev.variablesReference or 0) > 0 and expanded[wpath] then
				fetch_variables(sess, ev.variablesReference, 2, lines, marks, 1, wpath, next_watch)
			else
				if ev and (ev.variablesReference or 0) > 0 then
					marks[#lines] = { kind = "watchexpand", index = i, path = wpath, ref = ev.variablesReference }
				end
				next_watch()
			end
		end)
	end
	next_watch()
end

-- Чистый рендер в (lines, marks) по сессии. Нет сессии — явный хинт,
-- никаких stale-значений. Вынесено отдельно ради headless-регрессий
-- (туда подают fake-сессию с canned request()). Асинхронно: done(lines,
-- marks) зовётся ровно раз, когда все запросы завершились.
function M._render_with(sess, done)
	local lines, marks = {}, {}
	if not sess then
		done({
			"-- no active session --",
			"",
			"start with <leader>dc (continue)",
			"debug a test with <leader>dt",
		}, {})
		return
	end
	if rendered_session ~= sess.id then
		rendered_session = sess.id
		expanded = {}
	end
	local tid = sess.stopped_thread_id
	if tid then
		local ctx = {}
		fetch_frames(sess, tid, lines, marks, ctx, function()
			fetch_scopes(sess, lines, marks, ctx, function()
				fetch_watches(sess, lines, marks, ctx, function()
					done(lines, marks)
				end)
			end)
		end)
	else
		lines[#lines + 1] = "-- running (no stopped thread) --"
		lines[#lines + 1] = ""
		lines[#lines + 1] = "-- scopes --"
		-- Без stopped-треда настоящий адаптер на scopes/evaluate отвечает
		-- ошибкой; не показываем ничего, что выглядело бы как значения.
		lines[#lines + 1] = "(waiting for stop)"
		lines[#lines + 1] = ""
		lines[#lines + 1] = "-- watches (<leader>dW add, d remove) --"
		if #watches == 0 then
			lines[#lines + 1] = "(none)"
		else
			for _, expr in ipairs(watches) do
				lines[#lines + 1] = expr .. " = (waiting for stop)"
			end
		end
		done(lines, marks)
	end
end

local function render()
	if not panel or not vim.api.nvim_buf_is_valid(panel.buf) then
		return
	end
	local buf = panel.buf
	M._render_with(live_session(), function(lines, marks)
		if not vim.api.nvim_buf_is_valid(buf) then
			return
		end
		vim.api.nvim_buf_set_option(buf, "modifiable", true)
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
		vim.api.nvim_buf_set_option(buf, "modifiable", false)
		if panel and panel.buf == buf then
			panel.marks = marks
		end
	end)
end

local function win_open()
	if not panel then
		return false
	end
	for _, w in ipairs(vim.api.nvim_list_wins()) do
		if vim.api.nvim_win_get_buf(w) == panel.buf then
			return true
		end
	end
	return false
end

function M.refresh()
	if not win_open() then
		return -- панель закрыта: нечего обновлять, запросов нет
	end
	render()
end

local function ensure_listeners()
	if listeners_on then
		return
	end
	local dap = dap_ok()
	if not dap then
		return
	end
	listeners_on = true
	local function on_change()
		M.refresh()
	end
	dap.listeners.after.event_stopped["dev_inspect"] = on_change
	dap.listeners.after.event_terminated["dev_inspect"] = on_change
	dap.listeners.after.event_exited["dev_inspect"] = on_change
	dap.listeners.after.disconnect["dev_inspect"] = on_change
end

local function buf_maps(buf)
	local function act()
		local lnum = vim.api.nvim_win_get_cursor(0)[1]
		local a = panel.marks and panel.marks[lnum]
		if not a then
			return
		end
		if a.kind == "frame" then
			local sess = live_session()
			if sess and a.frame then
				-- Тот же путь, что у встроенного frames-виджета.
				pcall(function()
					sess:_frame_set(a.frame)
				end)
			end
			M.refresh()
		elseif a.kind == "expand" then
			if expanded[a.path] then
				expanded[a.path] = nil
			else
				expanded[a.path] = true
			end
			M.refresh()
		elseif a.kind == "watchexpand" then
			expanded[a.path] = true
			M.refresh()
		end
	end
	vim.keymap.set("n", "<CR>", act, { buffer = buf, noremap = true, silent = true, desc = "inspect: jump / expand" })
	vim.keymap.set("n", "r", function()
		M.refresh()
	end, { buffer = buf, noremap = true, silent = true, desc = "inspect: refresh" })
	vim.keymap.set("n", "d", function()
		local lnum = vim.api.nvim_win_get_cursor(0)[1]
		local a = panel.marks and panel.marks[lnum]
		if a and a.kind == "watch" then
			table.remove(watches, a.index)
			M.refresh()
		end
	end, { buffer = buf, noremap = true, silent = true, desc = "inspect: remove watch" })
	vim.keymap.set("n", "q", function()
		M.close()
	end, { buffer = buf, noremap = true, silent = true, desc = "inspect: close" })
end

function M.open()
	if #vim.api.nvim_list_uis() == 0 then
		vim.notify("[debug] inspector needs a UI (headless has no windows)", vim.log.levels.WARN, { title = "debug" })
		return nil
	end
	ensure_listeners()
	if not panel or not vim.api.nvim_buf_is_valid(panel.buf) then
		local buf = vim.api.nvim_create_buf(false, true)
		vim.bo[buf].filetype = "devdbg-inspect"
		vim.bo[buf].bufhidden = "hide"
		vim.bo[buf].swapfile = false
		vim.bo[buf].modifiable = false
		panel = { buf = buf, marks = {} }
		buf_maps(buf)
	end
	if not win_open() then
		vim.cmd("botright " .. PANEL_WIDTH .. "vsplit")
		vim.api.nvim_win_set_buf(0, panel.buf)
		vim.wo.wrap = false
		vim.wo.number = false
		vim.wo.signcolumn = "no"
	end
	render()
	return panel.buf
end

function M.close()
	if not panel then
		return
	end
	for _, w in ipairs(vim.api.nvim_list_wins()) do
		if vim.api.nvim_win_get_buf(w) == panel.buf then
			pcall(vim.api.nvim_win_close, w, true)
		end
	end
end

function M.toggle()
	if win_open() then
		M.close()
	else
		M.open()
	end
end

--- Добавить watch-выражение (prompt; по умолчанию слово под курсором).
function M.add_watch()
	local dap = dap_ok()
	if not dap or not dap.session() then
		vim.notify("[debug] no active session — start with <leader>dc", vim.log.levels.INFO, { title = "debug" })
		return
	end
	local cur = vim.fn.expand("<cword>")
	vim.ui.input({ prompt = "Watch expression: ", default = cur }, function(expr)
		if not expr or expr == "" then
			return
		end
		watches[#watches + 1] = expr
		vim.notify("[debug] watching: " .. expr, vim.log.levels.INFO, { title = "debug" })
		M.refresh()
	end)
end

-- Тестовые швы для headless-регрессий (состояние, не UI).
function M._test_watches()
	return watches
end
function M._test_set_watches(list)
	watches = list or {}
end
function M._test_reset()
	watches = {}
	expanded = {}
	rendered_session = nil
end

return M
