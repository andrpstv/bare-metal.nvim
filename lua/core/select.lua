-- core.select — native vim.ui.select / vim.ui.input provider (zero deps).
--
-- Почему свой, а не dressing/telescope-ui-select: оба тянут лишнее
-- (плагин + lazy-загрузка + свои keymap-конвенции) ради меню из N строк,
-- а input всё равно нужен отдельно. Наш: ~140 строк, centered float,
-- клавиатурный (j/k/<CR>/<Esc>/цифры для select; редактируемая строка,
-- <CR>/<Esc> для input), работает и в headless (флоаты существуют на
-- уровне API), фокус возвращается, колбэк зовётся ровно раз.
--
-- Установка — один раз при старте (core.init, после keymap): цена ноль
-- до первого использования, окон не создаём. Повторный setup() безопасен.

local M = {}

local active = nil -- {win, buf, prev_win, cancel} занятый промпт

local function close_active()
	if active then
		local a = active
		active = nil
		pcall(vim.api.nvim_win_close, a.win, true)
		if a.prev_win and vim.api.nvim_win_is_valid(a.prev_win) then
			pcall(vim.api.nvim_set_current_win, a.prev_win)
		end
	end
end

--- Supersede any open prompt: its caller gets nil (cancelled), never
--- a hang. Normal completion goes through finish() which is idempotent.
local function supersede()
	if active and active.cancel then
		active.cancel()
	end
end

local function center_geom(width, height)
	local cols, lines = vim.o.columns, vim.o.lines
	width = math.min(width or 60, math.max(20, cols - 4))
	height = math.min(height or 10, math.max(3, lines - 4))
	return {
		relative = "editor",
		width = width,
		height = height,
		row = math.max(0, math.floor((lines - height) / 2) - 1),
		col = math.max(0, math.floor((cols - width) / 2)),
		style = "minimal",
		border = "rounded",
	}
end

local function new_float(lines, title, height)
	close_active()
	local buf = vim.api.nvim_create_buf(false, true)
	vim.bo[buf].bufhidden = "wipe"
	vim.bo[buf].swapfile = false
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	local width = 0
	for _, l in ipairs(lines) do
		width = math.max(width, vim.fn.strdisplaywidth(l))
	end
	if title then
		width = math.max(width, vim.fn.strdisplaywidth(title) + 4)
	end
	local win = vim.api.nvim_open_win(buf, true, center_geom(width + 4, height or #lines))
	if title then
		pcall(vim.api.nvim_win_set_config, win, { title = " " .. title .. " ", title_pos = "center" })
	end
	-- prev_win выставляет вызыватель (он знает фокус до open_win).
	active = { win = win, buf = buf, prev_win = nil }
	return win, buf
end

--- vim.ui.select replacement. on_choice(item|nil, idx|nil) — ровно раз.
---@param items any[]
---@param opts table? {prompt, format_item, kind}
---@param on_choice fun(item: any?, idx: integer?)
function M.select(items, opts, on_choice)
	opts = opts or {}
	local done = false
	local function finish(item, idx)
		if done then
			return
		end
		done = true
		close_active()
		vim.schedule(function()
			on_choice(item, idx)
		end)
	end
	if not items or #items == 0 then
		vim.notify("[select] nothing to choose", vim.log.levels.INFO, { title = "select" })
		finish(nil, nil)
		return
	end
	supersede()
	local fmt = opts.format_item or tostring
	local lines = {}
	for i, it in ipairs(items) do
		local ok, text = pcall(fmt, it)
		lines[i] = string.format("%d: %s", i, ok and tostring(text) or "?")
	end
	local prev = vim.api.nvim_get_current_win()
	local win, buf = new_float(lines, opts.prompt or "Select:", math.min(#lines, 12))
	active.prev_win = prev
	active.cancel = function()
		finish(nil, nil)
	end
	vim.wo[win].cursorline = true
	vim.api.nvim_win_set_cursor(win, { 1, 0 })
	local function choose_at(lnum)
		local it = items[lnum]
		if it == nil then
			return
		end
		finish(it, lnum)
	end
	vim.keymap.set("n", "<CR>", function()
		choose_at(vim.api.nvim_win_get_cursor(0)[1])
	end, { buffer = buf, noremap = true, silent = true, desc = "select: choose" })
	vim.keymap.set("n", "<Esc>", function()
		finish(nil, nil)
	end, { buffer = buf, noremap = true, silent = true, desc = "select: cancel" })
	vim.keymap.set("n", "q", function()
		finish(nil, nil)
	end, { buffer = buf, noremap = true, silent = true, desc = "select: cancel" })
	vim.keymap.set("n", "j", "j", { buffer = buf, noremap = true, silent = true })
	vim.keymap.set("n", "k", "k", { buffer = buf, noremap = true, silent = true })
	for d = 1, math.min(9, #items) do
		local idx = d
		vim.keymap.set("n", tostring(d), function()
			choose_at(idx)
		end, { buffer = buf, noremap = true, silent = true, desc = "select: choose N" })
	end
end

--- vim.ui.input replacement. on_confirm(text|nil) — ровно раз.
---@param opts table? {prompt, default, completion}
---@param on_confirm fun(text: string?)
function M.input(opts, on_confirm)
	opts = opts or {}
	local done = false
	local function finish(text)
		if done then
			return
		end
		done = true
		close_active()
		vim.schedule(function()
			on_confirm(text)
		end)
	end
	local prev = vim.api.nvim_get_current_win()
	local buf = vim.api.nvim_create_buf(false, true)
	vim.bo[buf].bufhidden = "wipe"
	vim.bo[buf].swapfile = false
	vim.bo[buf].buftype = "prompt"
	supersede()
	close_active()
	local win = vim.api.nvim_open_win(buf, true, center_geom(60, 1))
	if opts.prompt then
		pcall(vim.api.nvim_win_set_config, win, { title = " " .. opts.prompt .. " ", title_pos = "center" })
	end
	active = { win = win, buf = buf, prev_win = prev }
	active.cancel = function()
		finish(nil, nil)
	end
	vim.fn.prompt_setprompt(buf, "")
	if opts.default and opts.default ~= "" then
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, { opts.default })
	end
	-- Курсор в конец префилла явно: если startinsert ниже не сработает
	-- (headless), ввод через вставку всё равно ляжет куда надо.
	pcall(vim.api.nvim_win_set_cursor, win, { 1, #(opts.default or "") })
	vim.cmd("startinsert!")
	local function confirm()
		local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
		finish(table.concat(lines, "\n"))
	end
	local function cancel()
		finish(nil)
	end
	vim.keymap.set("i", "<CR>", confirm, { buffer = buf, noremap = true, silent = true, desc = "input: confirm" })
	vim.keymap.set("i", "<Esc>", cancel, { buffer = buf, noremap = true, silent = true, desc = "input: cancel" })
	-- Нормальный режим тоже подтверждает/отменяет: в headless startinsert
	-- может не перевести в insert, а paste-флоу и тесты жмут клавиши так.
	vim.keymap.set("n", "<CR>", confirm, { buffer = buf, noremap = true, silent = true, desc = "input: confirm" })
	vim.keymap.set("n", "<Esc>", cancel, { buffer = buf, noremap = true, silent = true, desc = "input: cancel" })
	-- Страховка: если окно закрыли снаружи (q/:close) — колбэк с nil,
	-- а не висящий промпт.
	vim.api.nvim_create_autocmd({ "WinClosed", "BufWipeout" }, {
		buffer = buf,
		once = true,
		callback = function()
			finish(nil)
		end,
	})
end

--- Установить провайдер (идемпотентно).
function M.setup()
	if M._installed then
		return
	end
	M._installed = true
	vim.ui.select = M.select
	vim.ui.input = M.input
end

-- Тестовый шов: активный промпт (тип/строки) без привязки к UI-кадру.
function M._test_active()
	if not active or not vim.api.nvim_win_is_valid(active.win) then
		return nil
	end
	return {
		buf = active.buf,
		lines = vim.api.nvim_buf_get_lines(active.buf, 0, -1, false),
	}
end

return M
