-- scripts/regress-stc.lua — кастомная statuscolumn rendering (core.stc).
--
-- Run:  cd /Users/16prom1/.config/nvim && \
--       nvim --headless --noplugin -u NONE \
--           --cmd "set rtp+=$PWD" -l scripts/regress-stc.lua
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

local stc = require("core.stc")

-- ================================================================ setup: buffer, window
-- Создаём буфер с 10 строками.
local buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
	"line 1",
	"line 2",
	"line 3",
	"line 4",
	"line 5",
	"line 6",
	"line 7",
	"line 8",
	"line 9",
	"line 10",
})

local win = vim.api.nvim_get_current_win()
vim.api.nvim_win_set_buf(win, buf)

-- Включаем number и relativenumber.
vim.wo[win].number = true
vim.wo[win].relativenumber = true

-- ================================================================ basic rendering tests
check("render with no args succeeds", type(stc.render()) == "string")
check("render with args succeeds", type(stc.render(win, 1, 0, 0)) == "string")

-- ================================================================ number rendering
-- На строке 5 курсор: должен показать абсолютный номер 5 с CursorLineNr.
vim.api.nvim_win_set_cursor(win, { 5, 0 })
local render_at_5 = stc.render(win, 5, 0, 0)
check("cursor line shows absolute number", render_at_5:find("5") ~= nil)
check("cursor line has CursorLineNr hl", render_at_5:find("%#CursorLineNr#") ~= nil)

-- На строке 1 (не курсор, но relnum=4): должен показать relnum.
local render_at_1 = stc.render(win, 1, 4, 0)
check("non-cursor line shows relnum when relativenumber on", render_at_1:find("4") ~= nil)
check("non-cursor line has LineNr hl", render_at_1:find("%#LineNr#") ~= nil)

-- ================================================================ sign rendering
-- Создаём namespace для диагностики (не gitsigns).
local diag_ns = vim.api.nvim_create_namespace("test_diagnostics")
-- Создаём namespace для gitsigns.
local git_ns = vim.api.nvim_create_namespace("gitsigns_signs_test")

-- Помещаем диагностический знак на строку 3.
vim.api.nvim_buf_set_extmark(buf, diag_ns, 2, 0, {
	sign_text = "E ",
	sign_hl_group = "DiagnosticSignError",
	priority = 100,
})

-- Помещаем гит-знак на ту же строку 3.
vim.api.nvim_buf_set_extmark(buf, git_ns, 2, 0, {
	sign_text = "▎",
	sign_hl_group = "GitSignsChangeInline",
	priority = 10,
})

-- Рендер строки 3 должен показать оба знака.
local render_with_both = stc.render(win, 3, 2, 0)
check("diagnostic sign appears in left cell", render_with_both:find("E") ~= nil)
check("git sign appears (▎ marker)", render_with_both:find("▎") ~= nil)
check("both signs on same line visible", render_with_both:find("E") ~= nil and render_with_both:find("▎") ~= nil)

-- На строке 2 только диагностический знак.
vim.api.nvim_buf_set_extmark(buf, diag_ns, 1, 0, {
	sign_text = "W",
	sign_hl_group = "DiagnosticSignWarn",
	priority = 90,
})
local render_diag_only = stc.render(win, 2, 3, 0)
check("diagnostic only: sign visible", render_diag_only:find("W") ~= nil)

-- На строке 4 только гит-знак.
vim.api.nvim_buf_set_extmark(buf, git_ns, 3, 0, {
	sign_text = "▎",
	sign_hl_group = "GitSignsAdd",
	priority = 10,
})
local render_git_only = stc.render(win, 4, 1, 0)
check("git only: ▎ marker visible", render_git_only:find("▎") ~= nil)
check("git only: has GitSign hl", render_git_only:find("GitSignsAdd") ~= nil)

-- ================================================================ priority test
-- На строке 6 два диагностических знака: один с priority 100, один с 50.
-- Должен выигрывать 100.
vim.api.nvim_buf_set_extmark(buf, diag_ns, 5, 0, {
	sign_text = "E1",
	sign_hl_group = "DiagnosticSignError",
	priority = 100,
})
local diag_ns_low = vim.api.nvim_create_namespace("test_diag_low")
vim.api.nvim_buf_set_extmark(buf, diag_ns_low, 5, 0, {
	sign_text = "W2",
	sign_hl_group = "DiagnosticSignWarn",
	priority = 50,
})
local render_priority = stc.render(win, 6, 0, 0)
check("higher priority sign wins the 1-cell sign slot", render_priority:find("E", 1, true) ~= nil and not render_priority:find("W", 1, true))

-- ================================================================ virtual line test
-- virtnum ~= 0 → только пробелы.
local render_virtual = stc.render(win, 1, 0, 1)
check("virtual line returns padding only", render_virtual:gsub(" ", "") == "")
check("virtual line width >= 4", #render_virtual >= 4)

-- ================================================================ fold test
-- Включаем fold на строке 7.
vim.cmd("7,8fold")
local render_fold = stc.render(win, 7, 0, 0)
check("closed fold shows › in git cell", render_fold:find("›") ~= nil)
check("fold › has Folded highlight", render_fold:find("%#Folded#") ~= nil)

-- ================================================================ performance benchmark
-- Вызываем render 2000 раз и замеряем время.
local hrtime_start = vim.uv.hrtime()
for i = 1, 2000 do
	stc.render(win, 5, 0, 0)
end
local hrtime_end = vim.uv.hrtime()
local elapsed_ns = hrtime_end - hrtime_start
local elapsed_us = elapsed_ns / 1000
local us_per_call = elapsed_us / 2000

print(string.format("BENCH: %d calls in %.0f µs (%.1f µs/call)", 2000, elapsed_us, us_per_call))
check("render <= 30 µs per call", us_per_call <= 30)

-- ================================================================ edge cases
-- Отключаем number: render не должен выводить цифры.
vim.wo[win].number = false
vim.wo[win].relativenumber = false
local render_no_number = stc.render(win, 5, 0, 0)
-- После выключения number/relativenumber остаются только знаки и гит.
check("no number when disabled", not render_no_number:find("%d"))

-- Настоящий путь statuscolumn (g:statusline_winid + v:lnum), а не явные аргументы:
-- раньше render() без аргументов читал несуществующий vim.v.statusline_winid и давал "".
vim.wo[win].number = true
vim.wo[win].relativenumber = true
vim.o.statuscolumn = "%!v:lua.require'core.stc'.render()"
local function stc_at(l)
	return vim.api.nvim_eval_statusline(vim.o.statuscolumn, { winid = win, use_statuscol_lnum = l, highlights = true })
end
check("real statuscolumn context renders a number", stc_at(5).str:find("%d") ~= nil)
-- Многобайтный знак (точка останова «●») не режется по байтам; numhl красит номер.
local ns_bp = vim.api.nvim_create_namespace("regress_stc_bp")
vim.api.nvim_buf_set_extmark(buf, ns_bp, 8, 0, { sign_text = "●", sign_hl_group = "Error", number_hl_group = "DiagnosticError", priority = 50 })
local r9 = stc_at(9)
check("multibyte sign intact", r9.str:find("●", 1, true) ~= nil)
local has_numhl = false
for _, h in ipairs(r9.highlights) do
	has_numhl = has_numhl or h.group == "DiagnosticError"
end
check("number_hl_group colours the number", has_numhl)
check("wrapped line keeps the same width", vim.api.nvim_strwidth(stc.render(win, 5, 0, 1)) == vim.api.nvim_strwidth(stc_at(5).str))

print(string.format("total=%d failures=%d", total, failures))
os.exit(failures > 0 and 1 or 0)
