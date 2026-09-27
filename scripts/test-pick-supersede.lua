-- Прямой тест гарда in-flight для _G._pick_lsp (PERF-1B).
--
-- Проверяет ровно то, что чинили: второй gd во время первого запроса
-- (а) отменяет первый на проводе и (б) гасит его ПОЗДНИЙ ответ, чтобы
-- тот не открыл пикер/прыжок поверх свежего.
--
-- Реальный gopls не нужен и не поднимается: vim.lsp.buf_request подменяется
-- заглушкой, которая запоминает колбэки и отдаёт настоящий cancel-замыкание
-- (его возвращает и настоящий buf_request, lsp.lua:1298).
--
-- Запуск:
--   nvim --headless --clean -c 'luafile scripts/test-pick-supersede.lua'
-- Выход: 0 = все проверки прошли, 1 = есть проваленная.

local failures = {}
local checks = 0

local function check(ok, label)
	checks = checks + 1
	if not ok then
		failures[#failures + 1] = label
		print("  FAIL: " .. label)
	else
		print("  ok: " .. label)
	end
end

-- Файл нужен, чтобы vim.cmd.edit в проверке прыжка был не разрушителен.
local probe = vim.fn.tempname() .. ".lua"
vim.fn.writefile({ "one", "two", "three", "four", "five" }, probe)
vim.cmd.edit(vim.fn.fnameescape(probe))

-- ---- заглушки внешнего мира ----------------------------------------------
local pending = {} -- [{ cancel = fn, cb = fn }]
local picker_opens = 0

package.loaded["distro.loader"] = { load = function() end }
package.loaded["mini.pick"] = { builtin = {} }
package.loaded["mini.extra"] = {
	pickers = {
		lsp = function()
			picker_opens = picker_opens + 1
		end,
	},
}

vim.lsp.get_clients = function()
	return { { id = 1 } }
end
vim.lsp.util.make_position_params = function()
	return {}
end
vim.lsp.buf_request = function(_, _, _, cb)
	local rec = { cb = cb, cancelled = false }
	rec.cancel = function()
		rec.cancelled = true
	end
	pending[#pending + 1] = rec
	return { [1] = #pending }, rec.cancel
end
-- Единственный результат: прыжок в пределах текущего файла, курсор виден.
vim.lsp.util.locations_to_items = function()
	return { { filename = probe, lnum = 5, col = 3 } }
end

_G.__probe = probe
dofile(vim.fn.fnamemodify("lua/keymap/pick.lua", ":p"))
_G.__locations_to_items_file = probe

local function press_gd()
	vim.api.nvim_win_set_cursor(0, { 2, 0 })
	picker_opens = 0
	_G._pick_lsp("definition", { jump1 = true })
end

-- Ответ сервера на запрос с индексом i (1-based).
local function respond(i)
	local rec = pending[i]
	rec.cb(nil, { { uri = "file://probe" } })
	return rec
end

print("== 1. один gd: прыжок работает (гард не сломал обычный путь) ==")
press_gd()
check(#pending == 1, "после одного gd создан ровно один запрос")
respond(1)
local cur = vim.api.nvim_win_get_cursor(0)
check(cur[1] == 5 and cur[2] == 2, "прыжок выполнен на строку 5 (получено " .. cur[1] .. "," .. cur[2] .. ")")

print("== 2. два gd: первый отменён ==")
pending = {}
press_gd()
local first = pending[1]
press_gd()
check(#pending == 2, "создано два запроса")
check(first.cancelled == true, "cancel() первого запроса вызван при втором gd")

print("== 3. Поздний ответ первого (устаревшего) запроса игнорируется ==")
vim.api.nvim_win_set_cursor(0, { 2, 0 })
local before = vim.api.nvim_win_get_cursor(0)
respond(1) -- сервер ответил на ОТМЕНЁННЫЙ запрос
local after = vim.api.nvim_win_get_cursor(0)
check(after[1] == before[1] and after[2] == before[2], "устаревший ответ не телепортировал курсор (было " .. before[1] .. "," .. before[2] .. " стало " .. after[1] .. "," .. after[2] .. ")")
check(picker_opens == 0, "устаревший ответ не открыл пикер")

print("== 4. Ответ свежего запроса обрабатывается ==")
respond(2)
cur = vim.api.nvim_win_get_cursor(0)
check(cur[1] == 5 and cur[2] == 2, "свежий ответ прыгнул на строку 5 (получено " .. cur[1] .. "," .. cur[2] .. ")")

print("== 5. НЕ регрессия: ветка без jump1 не вытесняется ==")
pending = {}
picker_opens = 0
_G._pick_lsp("references", {}) -- completion.lua:96, без jump1
_G._pick_lsp("references", {})
check(picker_opens == 2, "оба references открыли пикер (вытеснения быть не должно), получено " .. picker_opens)

print("== 6. НЕ регрессия: гард переживает запрос с нулём клиентов ==")
local get_clients = vim.lsp.get_clients
vim.lsp.get_clients = function()
	return {}
end
pending = {}
press_gd()
check(#pending == 0, "без клиента запрос не создаётся (как и раньше)")
vim.lsp.get_clients = get_clients

print("")
print(string.format("RESULT: %d проверок, провалено: %d", checks, #failures))
for _, f in ipairs(failures) do
	print("  - " .. f)
end
vim.fn.delete(probe)
if #failures > 0 then
	vim.cmd("cquit 1")
end
print("ALL PASS")
vim.cmd("qa!")
