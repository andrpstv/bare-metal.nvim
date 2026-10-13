-- core.qf — читаемый quickfix/loclist через 'quickfixtextfunc': `путь │ строка:кол ✗ текст`.
--
-- Почему свой: quickfix — главный канал конфига (go test/build/vet/lint, ревью агента,
-- замены rg), а стоковый `file|42 col 3| msg` не выровнен и не показывает тип. Встроенная
-- опция + ~60 строк вместо nvim-bqf. Зовётся на каждую перерисовку списка: без I/O.

local M = {}

local PATH_W = 40
local MARK = { E = "✗", W = "!", I = "i", N = "·" }

-- Длинный путь — хвостом: «…/pkg/file.go» влезает в колонку и остаётся узнаваемым.
local function shorten(path)
	if vim.api.nvim_strwidth(path) <= PATH_W then
		return path
	end
	local tail = path
	while vim.api.nvim_strwidth(tail) > PATH_W - 2 and tail:find("/") do
		tail = tail:gsub("^[^/]*/", "", 1)
	end
	if vim.api.nvim_strwidth(tail) > PATH_W - 2 then
		tail = vim.fn.strcharpart(tail, vim.fn.strchars(tail) - (PATH_W - 2))
	end
	return "…/" .. tail
end

local function pos(item)
	return item.col > 0 and (item.lnum .. ":" .. item.col) or tostring(item.lnum)
end

---@param info {quickfix: integer, winid: integer, id: integer, start_idx: integer, end_idx: integer}
---@return string[]
function M.text(info)
	local what = { id = info.id, items = 1 }
	local items = (info.quickfix == 1 and vim.fn.getqflist(what) or vim.fn.getloclist(info.winid, what)).items
	-- Ширины по всему списку, а не по диапазону: при дописывании пунктов колонки не прыгают.
	local paths, path_w, pos_w = {}, 0, 0
	for i, item in ipairs(items) do
		if item.bufnr ~= 0 and item.valid ~= 0 then
			paths[i] = shorten(vim.fn.fnamemodify(vim.api.nvim_buf_get_name(item.bufnr), ":."))
			path_w = math.max(path_w, vim.api.nvim_strwidth(paths[i]))
			pos_w = math.max(pos_w, #pos(item))
		end
	end
	local out = {}
	for i = info.start_idx, info.end_idx do
		local item = items[i]
		local text = (item.text or ""):gsub("^%s+", ""):gsub("\n+", " ")
		if paths[i] then
			local p = paths[i] .. string.rep(" ", path_w - vim.api.nvim_strwidth(paths[i]))
			local l = pos(item)
			text = p .. " │ " .. l .. string.rep(" ", pos_w - #l) .. " " .. (MARK[item.type] or " ") .. " " .. text
		end
		out[#out + 1] = text
	end
	return out
end

-- Высота окна по числу пунктов: один пункт не должен открывать 10 строк.
function M._qf_height(n)
	return math.max(2, math.min(n, 10))
end

--- Подогнать высоту только что открытого qf/loclist-окна (зовётся при открытии, не при ресайзе).
function M.fit(win)
	if not vim.api.nvim_win_is_valid(win) or vim.api.nvim_win_get_width(win) < vim.o.columns then
		return -- vertical: высота не наша забота
	end
	local what = { size = 0 }
	local n = (vim.fn.getwininfo(win)[1].loclist == 1 and vim.fn.getloclist(win, what) or vim.fn.getqflist(what)).size
	vim.api.nvim_win_set_height(win, M._qf_height(n))
end

return M
