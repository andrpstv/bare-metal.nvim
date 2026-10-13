-- scripts/regress-uxfix.lua — S-Tab fold, float border, gopls hints, diagnostics from go test/check.
-- Run:  nvim --headless -c "luafile scripts/regress-uxfix.lua" -c 'qa!'
local failures = 0
local function check(desc, cond)
	if cond then
		print("OK " .. desc)
	else
		failures = failures + 1
		print("FAIL " .. desc)
	end
end

local m = vim.fn.maparg("<S-Tab>", "n", false, true)
check("S-Tab fold toggle is non-remappable (which-key z trigger can't swallow it)", m.rhs == "za" and m.noremap == 1)

local g = require("modules.configs.completion.servers.gopls").settings.gopls
check("gopls hints: parameterNames + constantValues on", g.hints and g.hints.parameterNames and g.hints.constantValues)
check("gopls hints: noisy type hints stay off", g.hints and not g.hints.assignVariableTypes)

local src = table.concat(vim.fn.readfile(vim.fn.stdpath("config") .. "/lua/modules/configs/completion/lsp.lua"), "\n")
check("diagnostic float has border", src:find('float = { border = "rounded" }', 1, true) ~= nil)

-- cmp: formatting.expandable_indicator и fields order
require("distro.loader").load("nvim-cmp")
local cmp_config = require("cmp").get_config()
check("cmp expandable_indicator is false", cmp_config.formatting.expandable_indicator == false)
check("cmp fields order: kind, abbr, menu", vim.deep_equal(cmp_config.formatting.fields, { "kind", "abbr", "menu" }))

-- cmp: format function output
local fake_entry = { source = { name = "nvim_lsp" } }
local vim_item = { kind = "Method", abbr = "Get", menu = "" }
local formatted = cmp_config.formatting.format(fake_entry, vim_item)
check("cmp format: menu has no '[' (no source tag)", formatted.menu:find("[", 1, true) == nil)
check("cmp format: kind has no letters from kind name", not formatted.kind:find("[A-Za-z]"))

-- telescope: selection_caret
require("distro.loader").load("telescope.nvim")
check("telescope selection_caret is '▍ '", require("telescope.config").values.selection_caret == "▍ ")

local ns = vim.api.nvim_create_namespace("regress_uxfix")
local f = vim.fn.tempname() .. "_x_test.go"
vim.fn.writefile({ "a", "b" }, f)
require("dev.build").publish_diags(ns, { { filename = f, lnum = 2, col = 1, text = "boom" } }, vim.diagnostic.severity.ERROR, "go test")
local d = vim.diagnostic.get(vim.fn.bufadd(f), { namespace = ns })
check("publish_diags: one diagnostic at 0-based line 1", #d == 1 and d[1].lnum == 1 and d[1].message == "boom" and d[1].source == "go test")
require("dev.build").publish_diags(ns, {}, vim.diagnostic.severity.ERROR, "go test")
check("publish_diags: empty list clears namespace", #vim.diagnostic.get(vim.fn.bufadd(f), { namespace = ns }) == 0)

-- qf: стоковая строка выключена, наш статуслайн показывает заголовок списка (с экранированием %).
check("qf_disable_statusline set", vim.g.qf_disable_statusline == 1)
vim.fn.setqflist({}, " ", { title = "go test: 50%", items = { { filename = f, lnum = 1, text = "x" } } })
vim.cmd("copen")
local stl = vim.api.nvim_eval_statusline(vim.o.statusline, { winid = vim.api.nvim_get_current_win() }).str
check("qf statusline shows the list title", stl:find("go test: 50%", 1, true) ~= nil)
vim.cmd("cclose")

print("failures=" .. failures)
if failures > 0 then
	vim.cmd("cquit 1")
end
