-- scripts/regress-goerr.lua — dev.goerr: поиск однооператорных `if err != nil` блоков (treesitter),
-- dim-extmark-и, схлопывание conceal_lines + eol-текст, опции окна, перерисовка после правки.
--
-- Run:  nvim --headless --noplugin -u NONE \
--          --cmd "set rtp+=<repo-root>" -l scripts/regress-goerr.lua
-- Exit 0 when all cases pass, 1 otherwise. SKIP (exit 0), если нет парсера go. No network.

local failures, total = 0, 0
local function check(desc, cond)
	total = total + 1
	if cond then
		print("OK " .. desc)
	else
		failures = failures + 1
		print("FAIL " .. desc)
	end
end

---@diagnostic disable-next-line: duplicate-set-field
vim.notify = function() end

if not pcall(vim.treesitter.language.add, "go") then
	vim.opt.rtp:append(vim.fn.stdpath("data") .. "/site")
	if not pcall(vim.treesitter.language.add, "go") then
		print("SKIP regress-goerr: go parser not installed")
		vim.cmd("qa!")
	end
end

local goerr = require("dev.goerr")
local ns = vim.api.nvim_create_namespace("dev_goerr")

local function mkbuf(src)
	local b = vim.api.nvim_create_buf(true, false)
	vim.api.nvim_buf_set_lines(b, 0, -1, false, vim.split(src, "\n"))
	vim.bo[b].filetype = "go"
	return b
end
local function wrap(body)
	return "package a\nfunc f() error {\n" .. body .. "\n\treturn nil\n}"
end

local plain = mkbuf(wrap('\tif err != nil {\n\t\treturn fmt.Errorf("load: %w", err)\n\t}'))
local bl = goerr._blocks(plain)
check("plain block matched", #bl == 1 and bl[1].srow == 2 and bl[1].erow == 4)
check("stmt text trimmed", bl[1] and bl[1].stmt == 'return fmt.Errorf("load: %w", err)')
bl = goerr._blocks(mkbuf(wrap("\tif err := g(); err != nil {\n\t\treturn err\n\t}")))
check("initializer block matched", #bl == 1)
bl = goerr._blocks(mkbuf(wrap("\tif err != nil {\n\t\tlog.Println(err)\n\t\treturn err\n\t}")))
check("multi-statement not matched", #bl == 0)
bl = goerr._blocks(mkbuf(wrap("\tif err == nil {\n\t\treturn err\n\t}")))
check("err == nil not matched", #bl == 0)
bl = goerr._blocks(mkbuf(wrap("\tif err != nil {\n\t\treturn err\n\t} else {\n\t\tx()\n\t}")))
check("else branch not matched", #bl == 0)
bl = goerr._blocks(mkbuf(wrap("\tif e != nil {\n\t\treturn e\n\t}")))
check("other name not matched", #bl == 0)

local one = mkbuf(wrap("\tif err != nil { return err }"))
goerr.attach(one)
local function marks(b, details)
	return vim.api.nvim_buf_get_extmarks(b, ns, 0, -1, { details = details })
end
check("attach does not render synchronously (FileType is inside file open)", #marks(one) == 0)
vim.wait(1000, function()
	return #marks(one) > 0
end)
local m = marks(one, true)
check("one-line dimmed", #m == 1 and m[1][4].hl_group == "Comment")
goerr.toggle(one)
local conceal = 0
for _, x in ipairs(marks(one, true)) do
	if x[4].conceal_lines then
		conceal = conceal + 1
	end
end
check("one-line not collapsed", conceal == 0)

vim.api.nvim_set_current_buf(plain)
goerr.attach(plain)
vim.wait(1000, function()
	return #marks(plain) > 0
end)
check("dim extmark after attach", #marks(plain, true) == 1)
check("attach idempotent", (goerr.attach(plain) or true) and #marks(plain, true) == 1)

local win = vim.api.nvim_get_current_win()
local cl0, cc0 = vim.wo[win].conceallevel, vim.wo[win].concealcursor
goerr.toggle(plain)
local rows, virt = {}, nil
for _, x in ipairs(marks(plain, true)) do
	if x[4].conceal_lines then
		rows[#rows + 1] = x[2]
	end
	if x[4].virt_text then
		virt = x
	end
end
table.sort(rows)
check("conceal_lines on rows 3-4", #rows == 2 and rows[1] == 3 and rows[2] == 4)
check("eol virt_text on row 2", virt and virt[2] == 2 and virt[4].virt_text[1][1]:find("⤶ return fmt.Errorf", 1, true))
check("window conceallevel=2, concealcursor empty", vim.wo[win].conceallevel == 2 and vim.wo[win].concealcursor == "")

goerr.toggle(plain)
check("toggle off removes conceal/virt", #marks(plain, true) == 1)
check("toggle off restores window options", vim.wo[win].conceallevel == cl0 and vim.wo[win].concealcursor == cc0)

-- перерисовка после правки: добавляем второй блок и имитируем TextChanged
vim.api.nvim_buf_set_lines(plain, 5, 5, false, { "\tif err != nil {", "\t\treturn err", "\t}" })
vim.api.nvim_exec_autocmds("TextChanged", { buffer = plain })
vim.wait(1000, function()
	return #marks(plain, false) == 2
end, 20)
check("re-render after edit", #marks(plain, false) == 2)

print(("total=%d failures=%d"):format(total, failures))
vim.cmd(failures == 0 and "qa!" or "cq!")
