-- dev.scrollbar — полоса меток у правого края (overview ruler в VS Code, error stripe в
-- JetBrains): где во всём файле ошибки, предупреждения, правки git, последняя внешняя
-- правка, и какая часть файла сейчас на экране. Одна колонка-флоат у текущего окна.
--
-- Почему свой: satellite.nvim / nvim-scrollview — плагины с десятком обработчиков ради одной
-- колонки. Метки (O(диагностик + ханков)) считаются по событиям и кэшируются по буферу;
-- прокрутка только раскладывает их по строкам полосы (O(высоты окна)), не чаще раза за тик.

local M = {}

local ns = vim.api.nvim_create_namespace("dev_scrollbar")
-- kind -> { символ, группа, приоритет }: в одну строку полосы попадает самый важный.
local KIND = {
	error = { "━", "DiagnosticError", 5 },
	warn = { "━", "DiagnosticWarn", 4 },
	edit = { "●", "StlMV", 3 },
	add = { "▎", "GitSignsAdd", 2 },
	change = { "▎", "GitSignsChange", 2 },
	delete = { "▁", "GitSignsDelete", 2 },
}
local marks = {} -- buf -> { {line 0-based, kind} } (nil — пересчитать)
local bar = { win = nil, buf = nil }
local pending = false

--- Метки буфера: диагностика, ханки gitsigns (если загружен), последняя внешняя правка.
local function collect(buf)
	local list = {}
	for _, d in ipairs(vim.diagnostic.get(buf, { severity = { min = vim.diagnostic.severity.WARN } })) do
		list[#list + 1] = { d.lnum, d.severity == vim.diagnostic.severity.ERROR and "error" or "warn" }
	end
	local gs = package.loaded["gitsigns"]
	local ok, hunks = pcall(function()
		return gs and gs.get_hunks(buf)
	end)
	for _, h in ipairs(ok and hunks or {}) do
		local kind = KIND[h.type] and h.type or "change"
		list[#list + 1] = { math.max(h.added.start - 1, 0), kind }
	end
	local ext = package.loaded["core.external"]
	local le = ext and ext.last_edit
	if le and le.buf == buf and le.row then
		list[#list + 1] = { le.row, "edit" }
	end
	return list
end

--- Строки полосы для окна: { [row 0-based] = kind }, диапазон «ползунка». Чистая — для тестов.
---@param list table метки { line, kind }
---@param total integer строк в буфере
---@param height integer высота окна
---@param top integer первая видимая строка (1-based)
---@param bot integer последняя видимая строка (1-based)
function M._layout(list, total, height, top, bot)
	local rows = {}
	for _, m in ipairs(list) do
		local r = math.min(height - 1, math.floor(m[1] / total * height))
		if not rows[r] or KIND[m[2]][3] > KIND[rows[r]][3] then
			rows[r] = m[2]
		end
	end
	local t1 = math.floor((top - 1) / total * height)
	local t2 = math.max(t1, math.min(height - 1, math.floor((bot - 1) / total * height)))
	return rows, t1, t2
end

local function hide()
	if bar.win and vim.api.nvim_win_is_valid(bar.win) then
		vim.api.nvim_win_hide(bar.win)
	end
	bar.win = nil
end

local function eligible(win)
	if vim.api.nvim_win_get_config(win).relative ~= "" then
		return false
	end
	local buf = vim.api.nvim_win_get_buf(win)
	return vim.bo[buf].buftype == "" and not vim.b[buf].large_file
end

function M.render()
	pending = false
	local win = vim.api.nvim_get_current_win()
	if not eligible(win) then
		return hide()
	end
	local buf = vim.api.nvim_win_get_buf(win)
	local total, height = vim.api.nvim_buf_line_count(buf), vim.api.nvim_win_get_height(win)
	-- Файл целиком на экране — полоса ничего не добавляет к тому, что и так видно.
	if total <= height or height < 3 then
		return hide()
	end
	marks[buf] = marks[buf] or collect(buf)
	local top, bot = vim.fn.line("w0", win), vim.fn.line("w$", win)
	local rows, t1, t2 = M._layout(marks[buf], total, height, top, bot)

	if not (bar.buf and vim.api.nvim_buf_is_valid(bar.buf)) then
		bar.buf = vim.api.nvim_create_buf(false, true)
		vim.bo[bar.buf].bufhidden = "hide"
	end
	local cfg = {
		relative = "win",
		win = win,
		row = 0,
		col = vim.api.nvim_win_get_width(win) - 1,
		width = 1,
		height = height,
		focusable = false,
		style = "minimal",
		zindex = 40,
	}
	if bar.win and vim.api.nvim_win_is_valid(bar.win) then
		vim.api.nvim_win_set_config(bar.win, cfg)
	else
		cfg.noautocmd = true
		bar.win = vim.api.nvim_open_win(bar.buf, false, cfg)
		vim.wo[bar.win].winhighlight = "NormalFloat:Normal"
	end
	local lines = {}
	for r = 0, height - 1 do
		lines[r + 1] = rows[r] and KIND[rows[r]][1] or " "
	end
	vim.api.nvim_buf_set_lines(bar.buf, 0, -1, false, lines)
	vim.api.nvim_buf_clear_namespace(bar.buf, ns, 0, -1)
	for r = 0, height - 1 do
		local opts = {}
		if rows[r] then
			opts.end_col = #lines[r + 1]
			opts.hl_group = KIND[rows[r]][2]
		end
		if r >= t1 and r <= t2 then
			opts.line_hl_group = "PmenuThumb"
		end
		if next(opts) then
			vim.api.nvim_buf_set_extmark(bar.buf, ns, r, 0, opts)
		end
	end
end

-- Пачка событий за один тик (прокрутка колесом, :windo) — одна перерисовка.
local function schedule()
	if not pending then
		pending = true
		vim.schedule(M.render)
	end
end

function M.setup()
	if M._grp then
		return
	end
	M._grp = vim.api.nvim_create_augroup("DevScrollbar", { clear = true })
	vim.api.nvim_create_autocmd({ "WinScrolled", "WinResized", "WinEnter", "BufWinEnter", "VimResized" }, {
		group = M._grp,
		desc = "scrollbar: follow the viewport",
		callback = schedule,
	})
	vim.api.nvim_create_autocmd({ "DiagnosticChanged", "TextChanged", "InsertLeave", "BufWritePost" }, {
		group = M._grp,
		desc = "scrollbar: recollect marks",
		callback = function(a)
			marks[a.buf] = nil
			schedule()
		end,
	})
	vim.api.nvim_create_autocmd("User", {
		group = M._grp,
		pattern = { "GitSignsUpdate" },
		desc = "scrollbar: git hunks changed",
		callback = function(a)
			marks[a.buf] = nil
			marks[vim.api.nvim_get_current_buf()] = nil
			schedule()
		end,
	})
	vim.api.nvim_create_autocmd("BufWipeout", {
		group = M._grp,
		callback = function(a)
			marks[a.buf] = nil
		end,
	})
	schedule()
end

--- Внешняя правка (core.external) — метка «●» на полосе этого буфера.
function M.invalidate(buf)
	marks[buf] = nil
	schedule()
end

return M
