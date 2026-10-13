-- scripts/regress-lspwait.lua — тесты модуля dev.lspwait (спиннер LSP-запросов).
--
-- Run:  cd /Users/16prom1/.config/nvim && \
--       nvim --headless --noplugin -u NONE \
--           --cmd "set rtp+=$PWD" -l scripts/regress-lspwait.lua
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

local lspwait = require("dev.lspwait")

-- ================================================================ _tracked()
check("_tracked: textDocument/definition is tracked", lspwait._tracked("textDocument/definition") == true)
check("_tracked: textDocument/references is tracked", lspwait._tracked("textDocument/references") == true)
check("_tracked: textDocument/hover is tracked", lspwait._tracked("textDocument/hover") == true)
check("_tracked: textDocument/implementation is tracked", lspwait._tracked("textDocument/implementation") == true)
check("_tracked: textDocument/typeDefinition is tracked", lspwait._tracked("textDocument/typeDefinition") == true)
check("_tracked: textDocument/rename is tracked", lspwait._tracked("textDocument/rename") == true)
check("_tracked: textDocument/prepareRename is tracked", lspwait._tracked("textDocument/prepareRename") == true)
check("_tracked: textDocument/codeAction is tracked", lspwait._tracked("textDocument/codeAction") == true)
check("_tracked: signatureHelp is NOT tracked (auto-sent while typing)", lspwait._tracked("textDocument/signatureHelp") == false)
check("_tracked: textDocument/prepareCallHierarchy is tracked", lspwait._tracked("textDocument/prepareCallHierarchy") == true)
check("_tracked: callHierarchy/incomingCalls is tracked", lspwait._tracked("callHierarchy/incomingCalls") == true)
check("_tracked: callHierarchy/outgoingCalls is tracked", lspwait._tracked("callHierarchy/outgoingCalls") == true)
check("_tracked: workspace/symbol is tracked", lspwait._tracked("workspace/symbol") == true)
check("_tracked: textDocument/semanticTokens/full is NOT tracked", lspwait._tracked("textDocument/semanticTokens/full") == false)
check("_tracked: textDocument/inlayHint is NOT tracked", lspwait._tracked("textDocument/inlayHint") == false)
check("_tracked: textDocument/documentHighlight is NOT tracked", lspwait._tracked("textDocument/documentHighlight") == false)
check("_tracked: textDocument/codeLens is NOT tracked", lspwait._tracked("textDocument/codeLens") == false)
check("_tracked: textDocument/diagnostic is NOT tracked", lspwait._tracked("textDocument/diagnostic") == false)

-- ================================================================ _frame()
check("_frame: frame 1 is ⠋", lspwait._frame(1) == "⠋")
check("_frame: frame 2 is ⠙", lspwait._frame(2) == "⠙")
check("_frame: frame 10 is ⠏", lspwait._frame(10) == "⠏")
check("_frame: frame 11 cycles back to ⠋", lspwait._frame(11) == "⠋")
check("_frame: frame 21 is ⠋", lspwait._frame(21) == "⠋")

-- ================================================================ on_request() with extmarks
local ns = vim.api.nvim_create_namespace("dev_lspwait")

-- Тест 1: pending -> extmark должен появиться через ~150ms
local buf1 = vim.api.nvim_create_buf(false, true)
vim.api.nvim_set_current_buf(buf1)
vim.api.nvim_buf_set_lines(buf1, 0, -1, false, { "test line 1", "test line 2" })
lspwait.on_request(buf1, 1, 1, "pending", "textDocument/definition")
vim.wait(250)
local marks = vim.api.nvim_buf_get_extmarks(buf1, ns, 0, -1, { details = true })
local has_pending_mark = #marks > 0 and marks[1][4].virt_text ~= nil
check("on_request: pending -> extmark appears after 150ms", has_pending_mark)
vim.api.nvim_buf_delete(buf1, { force = true })

-- Тест 2: pending -> complete -> extmark исчезает сразу
local buf2 = vim.api.nvim_create_buf(false, true)
vim.api.nvim_set_current_buf(buf2)
vim.api.nvim_buf_set_lines(buf2, 0, -1, false, { "test line 1", "test line 2" })
lspwait.on_request(buf2, 1, 2, "pending", "textDocument/definition")
vim.wait(100)  -- Даём время на 150ms отложенный вызов
lspwait.on_request(buf2, 1, 2, "complete", "textDocument/definition")
vim.wait(50)
marks = vim.api.nvim_buf_get_extmarks(buf2, ns, 0, -1, { details = true })
check("on_request: complete -> extmark removed immediately", #marks == 0)
vim.api.nvim_buf_delete(buf2, { force = true })

-- Тест 3: pending -> complete(быстро) -> никогда не было extmark
local buf3 = vim.api.nvim_create_buf(false, true)
vim.api.nvim_set_current_buf(buf3)
vim.api.nvim_buf_set_lines(buf3, 0, -1, false, { "test line 1", "test line 2" })
lspwait.on_request(buf3, 1, 3, "pending", "textDocument/definition")
lspwait.on_request(buf3, 1, 3, "complete", "textDocument/definition")
vim.wait(250)
marks = vim.api.nvim_buf_get_extmarks(buf3, ns, 0, -1, { details = true })
check("on_request: quick complete -> no extmark ever shown", #marks == 0)
vim.api.nvim_buf_delete(buf3, { force = true })

-- Тест 4: два pending, одно complete -> спиннер остаётся
local buf4 = vim.api.nvim_create_buf(false, true)
vim.api.nvim_set_current_buf(buf4)
vim.api.nvim_buf_set_lines(buf4, 0, -1, false, { "test line 1", "test line 2" })
lspwait.on_request(buf4, 1, 4, "pending", "textDocument/definition")
vim.wait(100)
lspwait.on_request(buf4, 1, 5, "pending", "textDocument/references")
vim.wait(100)
marks = vim.api.nvim_buf_get_extmarks(buf4, ns, 0, -1, { details = true })
local has_mark_before = #marks > 0
lspwait.on_request(buf4, 1, 4, "complete", "textDocument/definition")
vim.wait(50)
marks = vim.api.nvim_buf_get_extmarks(buf4, ns, 0, -1, { details = true })
local has_mark_after = #marks > 0
check("on_request: two pending, one complete -> mark still shown", has_mark_before and has_mark_after)

-- Тест 5: два pending, оба complete -> спиннер исчезает
lspwait.on_request(buf4, 1, 5, "complete", "textDocument/references")
vim.wait(50)
marks = vim.api.nvim_buf_get_extmarks(buf4, ns, 0, -1, { details = true })
check("on_request: second complete -> mark removed", #marks == 0)
vim.api.nvim_buf_delete(buf4, { force = true })

-- request_id уникален только внутри клиента: одинаковый id у двух серверов — два разных запроса.
local buf5 = vim.api.nvim_create_buf(false, true)
vim.api.nvim_set_current_buf(buf5)
vim.api.nvim_buf_set_lines(buf5, 0, -1, false, { "x" })
lspwait.on_request(buf5, 1, 7, "pending")
lspwait.on_request(buf5, 2, 7, "pending")
lspwait.on_request(buf5, 1, 7, "complete")
vim.wait(250)
check("on_request: same request_id from another client keeps the mark", #vim.api.nvim_buf_get_extmarks(buf5, ns, 0, -1, {}) == 1)
lspwait.on_request(buf5, 2, 7, "complete")
check("on_request: both clients done -> mark removed", #vim.api.nvim_buf_get_extmarks(buf5, ns, 0, -1, {}) == 0)

print(string.format("total=%d failures=%d", total, failures))
os.exit(failures > 0 and 1 or 0)
