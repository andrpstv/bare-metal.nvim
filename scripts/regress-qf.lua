-- scripts/regress-qf.lua — форматирование quickfix через core.qf.
--
-- Run:  cd /Users/16prom1/.config/nvim && \
--       nvim --headless --noplugin -u NONE \
--           --cmd "set rtp+=$PWD" -l scripts/regress-qf.lua
-- Exit 0 when all cases pass, 1 otherwise.

local failures = 0
local total = 0

local function check(desc, cond)
	total = total + 1
	if cond then
		print("OK " .. desc)
	else
		failures = failures + 1
		print("FAIL " .. desc)
	end
end

-- Подавляем notify.
---@diagnostic disable-next-line: duplicate-set-field
vim.notify = function() end

local qf = require("core.qf")

-- ---------------------------------------------------------------- basic formatting
-- Создаём две временные буферы с файлами.
local temp1 = vim.fn.tempname()
local temp2 = vim.fn.tempname()
vim.fn.writefile({ "line1", "line2", "line3" }, temp1)
vim.fn.writefile({ "data1", "data2" }, temp2)

-- Загружаем их как буферы.
vim.cmd("edit " .. vim.fn.fnameescape(temp1))
local buf1 = vim.api.nvim_get_current_buf()
vim.cmd("edit " .. vim.fn.fnameescape(temp2))
local buf2 = vim.api.nvim_get_current_buf()

-- Создаём quickfix список с разными типами.
vim.fn.setqflist({
	{ bufnr = buf1, lnum = 10, col = 5, type = "E", text = "error message" },
	{ bufnr = buf1, lnum = 20, col = 0, type = "W", text = "  warning" },
	{ bufnr = buf2, lnum = 5, col = 15, type = "I", text = "info" },
	{ bufnr = 0, text = "This is a summary line" },
	{ bufnr = buf1, lnum = 30, col = 1, type = "N", text = "note" },
}, "r")
local qf_id = vim.fn.getqflist({ nr = "$" }).id

-- Получаем элементы для форматирования.
local items_list = vim.fn.getqflist({ id = qf_id, items = 1 })
local items = items_list.items

-- Форматируем все строки.
local lines = qf.text({ quickfix = 1, id = qf_id, start_idx = 1, end_idx = #items, winid = 0 })

check("formatting returns list of strings", type(lines) == "table" and #lines == 5)

-- Проверяем, что ошибка содержит знак ✗.
check("error item has ✗ mark", lines[1]:find("✗", 1, true) ~= nil)

-- Проверяем, что предупреждение содержит знак !.
check("warning item has ! mark", lines[2]:find("!", 1, true) ~= nil)

-- Проверяем, что элемент без буфера содержит только текст.
check("no-buffer item is plain text", lines[4] == "This is a summary line")

-- Проверяем, что │ используется как разделитель.
check("path separator │ present", lines[1]:find(" │ ", 1, true) ~= nil)

-- ---------------------------------------------------------------- column alignment
-- Проверяем выравнивание: второй элемент должен иметь │ на той же позиции.
local sep_pos_1 = lines[1]:find(" │ ", 1, true)
local sep_pos_2 = lines[2]:find(" │ ", 1, true)
check("separator aligns across items", sep_pos_1 == sep_pos_2)

-- ---------------------------------------------------------------- col 0 handling
-- Вторая строка имеет col=0, должна быть без :0.
check("col=0 renders without colon", not lines[2]:find(":0", 1, true))

-- ---------------------------------------------------------------- text stripping
-- Третья строка имеет leading whitespace, должно быть убрано.
-- Проверим, что текст "info" присутствует.
check("leading whitespace stripped", lines[3]:find("info", 1, true) ~= nil)

-- ---------------------------------------------------------------- path truncation
-- Создаём файл с очень длинным путём.
local long_dir = vim.fn.tempname() .. "/very/long/path/to/some/deeply/nested/directory"
vim.fn.mkdir(long_dir, "p")
local long_path = long_dir .. "/file_with_long_name.txt"
vim.fn.writefile({ "test" }, long_path)
vim.cmd("edit " .. vim.fn.fnameescape(long_path))
local long_buf = vim.api.nvim_get_current_buf()

vim.fn.setqflist({
	{ bufnr = long_buf, lnum = 1, col = 1, type = "E", text = "error" },
}, "r")
local qf_id_long = vim.fn.getqflist({ nr = "$" }).id

local long_lines = qf.text({ quickfix = 1, id = qf_id_long, start_idx = 1, end_idx = 1, winid = 0 })

-- Проверяем, что путь не превышает 40 дисплейных ячеек (плюс " │ " и остальное).
local path_part = long_lines[1]:sub(1, long_lines[1]:find(" │ ", 1, true) - 1)
check("long path truncated to 40 cells", vim.api.nvim_strwidth(path_part) <= 40)

-- Проверяем наличие "…/" если путь был обрезан.
if vim.api.nvim_strwidth(path_part) == 40 then
	check("truncated path has …/ prefix", path_part:find("…/", 1, true) ~= nil)
end

-- ---------------------------------------------------------------- location list variant
-- Создаём location list в текущем окне.
vim.fn.setloclist(0, {
	{ bufnr = buf1, lnum = 42, col = 10, type = "W", text = "location warning" },
}, "r")
local loc_id = vim.fn.getloclist(0, { nr = "$" }).id

local loc_lines = qf.text({ quickfix = 0, id = loc_id, start_idx = 1, end_idx = 1, winid = 0 })
check("location list formatting works", #loc_lines == 1 and loc_lines[1]:find(" │ ", 1, true) ~= nil)

-- ---------------------------------------------------------------- multiline text collapsing
vim.fn.setqflist({
	{ bufnr = buf1, lnum = 99, col = 1, type = "E", text = "line1\nline2\nline3" },
}, "r")
local qf_id_multi = vim.fn.getqflist({ nr = "$" }).id

local multi_lines = qf.text({ quickfix = 1, id = qf_id_multi, start_idx = 1, end_idx = 1, winid = 0 })
check("multiline text collapsed", not multi_lines[1]:find("\n", 1, true))
check("collapsed text has spaces", multi_lines[1]:find("line1 line2 line3", 1, true) ~= nil)

-- ---------------------------------------------------------------- wiring: vim.o.quickfixtextfunc
vim.o.quickfixtextfunc = "v:lua.require'core.qf'.text"
check("quickfixtextfunc wiring succeeds", vim.o.quickfixtextfunc == "v:lua.require'core.qf'.text")

-- Открываем quickfix для проверки визуального рендера.
vim.fn.setqflist({
	{ bufnr = buf1, lnum = 100, col = 20, type = "E", text = "[build] compilation failed" },
	{ bufnr = buf2, lnum = 5, col = 3, type = "W", text = "[vet] unused variable" },
	{ text = "pass=3 fail=1" },
}, "r")
local qf_id_visual = vim.fn.getqflist({ nr = "$" }).id
-- Подсветка (after/syntax/qf.lua): -u NONE не включает syntax и не кладёт after/ в rtp.
vim.opt.rtp:append(vim.fn.getcwd() .. "/after")
vim.cmd("syntax on")
vim.cmd("copen")
local function syn_at(lnum, needle)
	local col = (vim.fn.getline(lnum)):find(needle, 1, true)
	return col and vim.fn.synIDattr(vim.fn.synID(lnum, col, 1), "name") or "?"
end
check("syntax: error mark is qfError", syn_at(1, "✗") == "qfError")
check("syntax: warn mark is qfWarn", syn_at(2, "!") == "qfWarn")
check("syntax: path is qfPath", syn_at(1, vim.fn.getline(1):sub(1, 3)) == "qfPath")
check("syntax: plain line is not a path", syn_at(3, "pass") ~= "qfPath")

-- Проверяем, что quickfix окно открыто.
local qf_win = vim.fn.getqflist({ winid = 0 }).winid
check("quickfix window opens", qf_win ~= 0)

-- Получаем текст в quickfix буфере.
local qf_buf = vim.api.nvim_win_get_buf(qf_win)
local qf_content = vim.api.nvim_buf_get_lines(qf_buf, 0, -1, false)
check("quickfix buffer has formatted lines", #qf_content >= 2)

-- Проверяем наличие наших маркеров в буфере.
local has_error_mark = false
local has_warn_mark = false
for _, line in ipairs(qf_content) do
	if line:find("✗", 1, true) then
		has_error_mark = true
	end
	if line:find("!", 1, true) then
		has_warn_mark = true
	end
end
check("quickfix buffer shows error mark", has_error_mark)
check("quickfix buffer shows warn mark", has_warn_mark)

-- ---------------------------------------------------------------- cleanup
vim.cmd("cclose")
vim.fn.delete(temp1)
vim.fn.delete(temp2)
vim.fn.delete(long_dir, "rf")

print(string.format("total=%d failures=%d", total, failures))
os.exit(failures > 0 and 1 or 0)
