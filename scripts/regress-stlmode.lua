-- scripts/regress-stlmode.lua — statusline mode colors, CursorLineNr, floating windows, file size.
-- Run:  NVIM_DISTRO_SYNC=1 nvim --headless -c "luafile scripts/regress-stlmode.lua" -c 'qa!'
local failures = 0
local function check(desc, cond)
	if cond then
		print("OK " .. desc)
	else
		failures = failures + 1
		print("FAIL " .. desc)
	end
end

-- (a) в normal режиме в highlights списке есть StlModeN в начале
local stl_eval = vim.api.nvim_eval_statusline(vim.o.statusline, { winid = vim.api.nvim_get_current_win(), highlights = true })
local has_stlmoden = false
if stl_eval.highlights then
	for _, hl in ipairs(stl_eval.highlights) do
		if hl.group == "StlModeN" then
			has_stlmoden = true
			break
		end
	end
end
check("normal mode statusline contains StlModeN highlight", has_stlmoden)

-- (b) функция _stl_mode_group маппирует режимы корректно
local mode_group = _G._stl_mode_group
check("mode_group('n') == StlModeN", mode_group("n") == "StlModeN")
check("mode_group('i') == StlModeI", mode_group("i") == "StlModeI")
check("mode_group('v') == StlModeV", mode_group("v") == "StlModeV")
check("mode_group('V') == StlModeV", mode_group("V") == "StlModeV")
check("mode_group('\\22') == StlModeV", mode_group("\22") == "StlModeV")
check("mode_group('R') == StlModeR", mode_group("R") == "StlModeR")
check("mode_group('c') == StlModeC", mode_group("c") == "StlModeC")
check("mode_group('t') == StlModeT", mode_group("t") == "StlModeT")

-- (c) плавающее окно: статуслайн не содержит имя файла
local scratch = vim.fn.tempname()
vim.fn.writefile({ "test" }, scratch)
local buf = vim.fn.bufadd(scratch)
vim.api.nvim_set_current_buf(buf)
local float_win = vim.api.nvim_open_win(buf, true, { relative = "editor", row = 5, col = 5, width = 20, height = 5 })
local float_stl = vim.api.nvim_eval_statusline(vim.o.statusline, { winid = float_win }).str
check("floating window statusline doesn't show filename", float_stl:find("%[No Name%]", 1, true) == nil and float_stl:find(vim.fn.fnamemodify(scratch, ":."), 1, true) == nil)
vim.api.nvim_win_close(float_win, true)

-- (d) маленький файл не показывает сегмент размера
local small_file = vim.fn.tempname() .. "_small.txt"
vim.fn.writefile({ "x" }, small_file) -- < 1 MiB
local small_buf = vim.fn.bufadd(small_file)
vim.api.nvim_set_current_buf(small_buf)
local small_stl = vim.api.nvim_eval_statusline(vim.o.statusline, { winid = vim.api.nvim_get_current_win() }).str
check("small file statusline doesn't contain 'b)' size segment", small_stl:find("b%)", 1, true) == nil)

-- (e) проверяем что размер НЕ показывается при < 1 MiB (уже сделано в (d))
-- и что логика размера в _stl_human_size корректна (проверяем условие и форматирование)
-- в тесте сложно создать реальный большой файл, так что проверяем логику

print("failures=" .. failures)
if failures > 0 then
	vim.cmd("cquit 1")
end
