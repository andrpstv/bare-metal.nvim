-- scripts/regress-lspvis.lua — подсветка вхождений символа (documentHighlight) с полным
-- конфигом: обработчик LspAttach в core/event.lua ставит CursorHold/CursorMoved только
-- серверу с documentHighlightProvider; по CursorHold приходит подсветка (запись — своим
-- видом), по CursorMoved снимается. Сервер — фейковый, внутри процесса: без gopls и сети.
--
-- Run:  nvim --headless -c "luafile scripts/regress-lspvis.lua" -c 'qa!'
-- Exit 1 on failure (prints FAIL lines).

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

local requests = {}
-- Минимальный LSP-сервер: initialize + documentHighlight (строка 1 — запись, строка 2 — чтение).
local function fake(caps)
	return function(dispatchers)
		local closing = false
		return {
			request = function(method, params, callback)
				requests[#requests + 1] = method
				local res
				if method == "initialize" then
					res = { capabilities = caps }
				elseif method == "textDocument/documentHighlight" then
					res = {
						{ range = { start = { line = 0, character = 6 }, ["end"] = { line = 0, character = 7 } }, kind = 3 },
						{ range = { start = { line = 1, character = 0 }, ["end"] = { line = 1, character = 1 } }, kind = 2 },
					}
				end
				vim.schedule(function()
					callback(nil, res)
				end)
				return true, #requests
			end,
			notify = function(method)
				if method == "exit" then
					dispatchers.on_exit(0, 15)
				end
				return true
			end,
			is_closing = function()
				return closing
			end,
			terminate = function()
				closing = true
			end,
		}
	end
end

local dir = vim.fn.tempname()
vim.fn.mkdir(dir, "p")
local path = dir .. "/x.txt"
vim.fn.writefile({ "local x = 1", "x = x + 1" }, path)
vim.cmd("edit " .. vim.fn.fnameescape(path))
local buf = vim.api.nvim_get_current_buf()
local id = vim.lsp.start({
	name = "fake-hl",
	cmd = fake({ documentHighlightProvider = true, textDocumentSync = 1 }),
	root_dir = dir,
}, { bufnr = buf })
vim.wait(3000, function()
	return #vim.lsp.get_clients({ bufnr = buf }) > 0
end)
check("fake server attached", id ~= nil and #vim.lsp.get_clients({ bufnr = buf }) > 0)
check("LspAttach set up the highlight autocmds", #vim.api.nvim_get_autocmds({ group = "LspDocHighlight" .. buf }) >= 2)

local refs = vim.api.nvim_get_namespaces()["nvim.lsp.references"]
local function marks()
	return refs and vim.api.nvim_buf_get_extmarks(buf, refs, 0, -1, { details = true }) or {}
end
vim.api.nvim_win_set_cursor(0, { 1, 6 })
vim.api.nvim_exec_autocmds("CursorHold", { buffer = buf })
vim.wait(2000, function()
	refs = refs or vim.api.nvim_get_namespaces()["nvim.lsp.references"]
	return #marks() >= 2
end)
local m = marks()
check("CursorHold -> documentHighlight request", vim.tbl_contains(requests, "textDocument/documentHighlight"))
check("both occurrences highlighted", #m >= 2)
local kinds = {}
for _, x in ipairs(m) do
	kinds[x[4].hl_group] = true
end
check("write occurrence uses LspReferenceWrite", kinds["LspReferenceWrite"] == true)
check("read occurrence uses LspReferenceRead", kinds["LspReferenceRead"] == true)
vim.api.nvim_exec_autocmds("CursorMoved", { buffer = buf })
check("CursorMoved clears the highlight", #marks() == 0)

-- Сервер без documentHighlightProvider — автокоманд нет (иначе каждая пауза слала бы пустой запрос).
local path2 = dir .. "/y.txt"
vim.fn.writefile({ "y" }, path2)
vim.cmd("edit " .. vim.fn.fnameescape(path2))
local buf2 = vim.api.nvim_get_current_buf()
vim.lsp.start({ name = "fake-plain", cmd = fake({ textDocumentSync = 1 }), root_dir = dir }, { bufnr = buf2 })
vim.wait(3000, function()
	return #vim.lsp.get_clients({ bufnr = buf2 }) > 0
end)
local ok_g, au = pcall(vim.api.nvim_get_autocmds, { group = "LspDocHighlight" .. buf2 })
check("no highlight autocmds without the capability", not ok_g or #au == 0)

for _, c in ipairs(vim.lsp.get_clients()) do
	c:stop(true)
end
vim.fn.delete(dir, "rf")
print(string.format("total=%d failures=%d", total, failures))
if failures > 0 then
	vim.cmd("cquit 1")
end
