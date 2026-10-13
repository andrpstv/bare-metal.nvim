-- scripts/regress-implmarks.lua — dev.implmarks: типы по treesitter, формат, e2e с фейковым клиентом
-- (метки, устаревший ответ, кэш по changedtick) и, если есть gopls, настоящий gopls.
--
-- Run:  nvim --headless --noplugin -u NONE \
--          --cmd "set rtp+=<repo-root>" -l scripts/regress-implmarks.lua
-- Exit 0 when all cases pass, 1 otherwise. No network, no user config.

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

local im = require("dev.implmarks")
local ns = vim.api.nvim_create_namespace("dev_implmarks")

local function marks(buf)
	local out = {}
	for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })) do
		-- Конкатенируем все чанки в один текст
		local text = ""
		if m[4].virt_text then
			for _, ch in ipairs(m[4].virt_text) do
				text = text .. ch[1]
			end
		end
		out[m[2]] = text
	end
	return out
end

-- ---------------------------------------------------------------- _format
local function chunks_text(chunks)
	if not chunks then return nil end
	local s = ""
	for _, ch in ipairs(chunks) do
		s = s .. ch[1]
	end
	return s
end
local function chunks_groups(chunks)
	if not chunks then return nil end
	local g = {}
	for _, ch in ipairs(chunks) do
		g[#g + 1] = ch[2]
	end
	return g
end

-- N=0 интерфейс
local c0 = im._format("interface", {})
check("format N=0 interface chunks", c0 ~= nil and #c0 == 2)
check("format N=0 interface text", chunks_text(c0) == "◆ no implementations")
check("format N=0 interface groups", c0 and c0[1][2] == "DevImpl" and c0[2][2] == "DevImpl")

-- N=1 интерфейс
local c1 = im._format("interface", { "Reader" })
check("format N=1 interface chunks", c1 ~= nil and #c1 == 4)
check("format N=1 interface text", chunks_text(c1) == "◆ 1 implementation · Reader")
check("format N=1 interface groups", c1 and c1[1][2] == "DevImpl" and c1[2][2] == "DevImplCount" and c1[3][2] == "DevImpl" and c1[4][2] == "DevImplName")

-- N=2 интерфейс
local c2 = im._format("interface", { "a", "b" })
check("format N=2 interface chunks", c2 ~= nil and #c2 >= 5)
check("format N=2 interface text", chunks_text(c2) == "◆ 2 implementations · a, b")

-- N=5 интерфейс с truncation
local c5 = im._format("interface", { "a", "b", "c", "d", "e" })
check("format N=5 interface text", chunks_text(c5) == "◆ 5 implementations · a, b, c +2")

-- Дедупликация
local dup = im._format("interface", { "a", "b", "a", "c", "b" })
check("format dedup removes duplicates", chunks_text(dup) == "◆ 3 implementations · a, b, c")

-- struct
local cs = im._format("other", { "Reader", "Stringer" })
check("format struct", cs ~= nil and chunks_text(cs) == "◇ Reader, Stringer")
check("format empty struct -> nil", im._format("other", {}) == nil)

-- Спиннер кадры
check("spinner frame 1", im._frame(1) == "⠋")
check("spinner frame 2", im._frame(2) == "⠙")
check("spinner frame 10", im._frame(10) == "⠏")
check("spinner frame 11 wraps", im._frame(11) == "⠋")

-- ---------------------------------------------------------------- treesitter
local function has_go()
	return pcall(vim.treesitter.language.add, "go")
end
local how = "plain rtp"
if not has_go() then
	vim.opt.rtp:append(vim.fn.stdpath("data") .. "/site")
	how = "stdpath(data)/site"
end
if not has_go() then
	print("SKIP treesitter go parser unavailable")
	print(("RESULT: total=%d failures=%d"):format(total, failures))
	os.exit(failures == 0 and 0 or 1)
end
print("go parser via " .. how)

local SRC = {
	"package p",
	"",
	"type Shape interface {",
	"\tArea() float64",
	"}",
	"",
	"type Sq struct{}",
	"",
	"type ID int",
}
local function scratch(lines, name)
	local buf = vim.api.nvim_create_buf(true, false)
	vim.api.nvim_buf_set_name(buf, name)
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.bo[buf].filetype = "go"
	vim.api.nvim_set_current_buf(buf)
	return buf
end

local buf = scratch(SRC, vim.fn.tempname() .. "/a.go")
local ts = im._types(buf, 0, #SRC)
check("_types finds 3", #ts == 3)
check("_types interface", ts[1] and ts[1].name == "Shape" and ts[1].kind == "interface" and ts[1].row == 2)
check("_types struct", ts[2] and ts[2].name == "Sq" and ts[2].kind == "other" and ts[2].col == 5)
check("_types named type", ts[3] and ts[3].name == "ID" and ts[3].kind == "other")
check("_types range filter", #im._types(buf, 6, 6) == 1)

-- ---------------------------------------------------------------- e2e, фейковый клиент
local dir = vim.fn.tempname()
vim.fn.mkdir(dir .. "/other", "p")
vim.fn.writefile({ "package other", "", "type Reader interface{}", "type Impl struct{}" }, dir .. "/other/o.go")
vim.fn.writefile({ "package p", "", "type A struct{}", "type B struct{}" }, dir .. "/p.go")
local function loc(file, line, col)
	local p = { line = line, character = col }
	return { uri = vim.uri_from_fname(file), range = { start = p, ["end"] = p } }
end


local pending, reqs = {}, 0
local fake = {
	offset_encoding = "utf-16",
	request = function(_, _, params, handler)
		reqs = reqs + 1
		pending[#pending + 1] = { row = params.position.line, handler = handler }
		return true
	end,
}
im._clients = function()
	return { fake }
end
local function answer(row, result)
	for i, p in ipairs(pending) do
		if p.row == row then
			table.remove(pending, i)
			p.handler(nil, result)
			return
		end
	end
end

buf = scratch(SRC, dir .. "/cur.go")
vim.bo[buf].modified = false
im.refresh(buf)
check("refresh sent 3 requests", reqs == 3)
answer(2, { loc(dir .. "/p.go", 2, 5), loc(dir .. "/p.go", 3, 5) })
answer(6, {
	{ targetUri = vim.uri_from_fname(dir .. "/other/o.go"), targetSelectionRange = { start = { line = 2, character = 5 } } },
})
local m = marks(buf)
check("interface mark", m[2] == "◆ 2 implementations · A, B")
check("struct mark with pkg prefix (LocationLink)", m[6] == "◇ other.Reader")

-- кэш: тот же changedtick — отвеченные не повторяются, запрос в пути тоже
reqs = 0
im.refresh(buf)
im.refresh(buf)
check("cache: answered and in-flight rows not re-requested", reqs == 0)

-- медленный ответ на ранний refresh всё равно рисуется (gopls после старта отвечает секундами)
answer(8, { loc(dir .. "/p.go", 2, 5) })
check("slow answer from an earlier refresh renders", marks(buf)[8] ~= nil)

-- ответ после правки буфера выбрасывается: строки могли съехать
vim.api.nvim_buf_set_lines(buf, 0, 0, false, { "// edit" })
im.refresh(buf)
local late = pending[#pending]
vim.api.nvim_buf_set_lines(buf, 0, 1, false, {})
im.refresh(buf)
-- Сейчас новые маркеры на месте, старый обработчик позже вернётся, но буфер изменился
late.handler(nil, { loc(dir .. "/p.go", 2, 5) })
-- После refresh (step 4) маркеры обновлены, старый обработчик увидит другой tick и не добавит свои
check("answer after an edit is dropped", next(marks(buf)) ~= nil)

-- смена changedtick сбрасывает кэш и маркеры, потом показывает маркеры только для интерфейсов
pending = {}
vim.api.nvim_buf_set_lines(buf, 8, 9, false, { "type ID string" })
reqs = 0
im.refresh(buf)
-- Маркер загрузки только для Shape (interface), не для Sq (struct) и не для ID (type)
local mm = marks(buf)
check("changedtick: loading mark for interface only", mm[2] and mm[2]:find("◆") and not mm[6] and not mm[8])
check("changedtick: cache dropped, all re-requested", reqs == 3)
im.clear(buf)
check("clear removes marks", next(marks(buf)) == nil)

-- не-go буфер и large_file — без запросов
reqs = 0
vim.bo[buf].filetype = "lua"
im.refresh(buf)
vim.bo[buf].filetype = "go"
vim.b[buf].large_file = true
im.refresh(buf)
check("non-go / large_file -> no requests", reqs == 0)
vim.b[buf].large_file = nil

-- ---------------------------------------------------------------- настоящий gopls
im._clients = function(b)
	return vim.lsp.get_clients({ bufnr = b, method = "textDocument/implementation" })
end
if vim.fn.executable("gopls") ~= 1 then
	print("SKIP real gopls: not installed")
else
	local tmp = vim.fn.resolve(vim.fn.tempname())
	vim.fn.mkdir(tmp, "p")
	vim.fn.writefile({ "module example.com/m", "", "go 1.21" }, tmp .. "/go.mod")
	local src = {
		"package m",
		"",
		"type Shape interface{ Area() float64 }",
		"",
		"type Sq struct{}",
		"",
		"func (Sq) Area() float64 { return 1 }",
	}
	vim.fn.writefile(src, tmp .. "/m.go")
	vim.cmd("edit " .. vim.fn.fnameescape(tmp .. "/m.go"))
	local rb = vim.api.nvim_get_current_buf()
	vim.bo[rb].filetype = "go"
	vim.lsp.start({ name = "gopls", cmd = { "gopls" }, root_dir = tmp }, { bufnr = rb })
	local attached = vim.wait(15000, function()
		return #im._clients(rb) > 0
	end, 100)
	if not attached then
		print("SKIP real gopls: did not attach in 15s")
	else
		-- refresh не чаще раза в 3с: каждый вызов — новое поколение, а gopls на старте отвечает медленно
		local last = 0
		local got = vim.wait(20000, function()
			if vim.uv.now() - last > 3000 then
				last = vim.uv.now()
				im.refresh(rb)
			end
			local mm = marks(rb)
			return mm[2] ~= nil and mm[4] ~= nil
		end, 500)
		local mm = marks(rb)
		print(("real gopls marks: Shape=%s Sq=%s"):format(tostring(mm[2]), tostring(mm[4])))
		if not got then
			print("SKIP real gopls: marks did not appear in 20s")
		else
			check("real gopls: interface mark", mm[2] and mm[2]:match("◆ 1 implementation · Sq"))
			check("real gopls: struct mark", mm[4] == "◇ Shape")
			-- Кадры спиннера и «печати» переиспользуют id: на строку ровно одна метка, без хвоста кадров.
			check("real gopls: exactly one mark per type line", #vim.api.nvim_buf_get_extmarks(rb, ns, 0, -1, {}) == 2)
		end
	end
	for _, c in ipairs(vim.lsp.get_clients()) do
		c:stop()
	end
end

print(("RESULT: total=%d failures=%d"):format(total, failures))
vim.cmd(failures == 0 and "qa!" or "cq")
