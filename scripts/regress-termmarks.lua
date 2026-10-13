-- scripts/regress-termmarks.lua — dev.termmarks: разбор OSC 133;C/D, формат длительности и
-- сквозной прогон в настоящем :terminal (метки ✓/✗, exit-текст, нет длительности у быстрых).
--
-- Run:  nvim --headless --noplugin -u NONE \
--          --cmd "set rtp+=<repo-root>" -l scripts/regress-termmarks.lua
-- Exit 0 when all cases pass, 1 otherwise. No network, no user config.

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

local tm = require("dev.termmarks")

-- ---------------------------------------------------------------- _parse
local p = tm._parse("\027]133;C")
check("parse C", p and p.kind == "C")
p = tm._parse("\027]133;D;2")
check("parse D;2", p and p.kind == "D" and p.code == 2)
p = tm._parse("\027]133;D;0")
check("parse D;0", p and p.kind == "D" and p.code == 0)
check("parse D without code -> nil", tm._parse("\027]133;D") == nil)
check("parse D; empty code -> nil", tm._parse("\027]133;D;") == nil)
check("parse A -> nil (builtin)", tm._parse("\027]133;A") == nil)
check("parse garbage -> nil", tm._parse("hello") == nil and tm._parse("\027]7;file:///x") == nil)

-- ---------------------------------------------------------------- _fmt_duration
check("0.85s hidden", tm._fmt_duration(0.85) == nil)
check("3.4s", tm._fmt_duration(3.4) == "3.4s")
check("125s -> 2m05s", tm._fmt_duration(125) == "2m05s")

-- ---------------------------------------------------------------- real terminal
tm.setup()
tm.setup() -- идемпотентно
check("one TermRequest autocmd", #vim.api.nvim_get_autocmds({ group = "dev_termmarks", event = "TermRequest" }) == 1)

local script = table.concat({
	-- D без C: так шлёт zsh-хук на самом первом промпте — метки быть не должно.
	[[printf '\033]133;D;0\007';]],
	[[printf '\033]133;A\007$ '; printf '\033]133;C\007'; echo out1; printf '\033]133;D;3\007';]],
	[[printf '\033]133;A\007$ '; printf '\033]133;C\007'; echo out2; printf '\033]133;D;0\007';]],
	"sleep 1",
}, " ")
local buf = vim.api.nvim_create_buf(true, false)
vim.api.nvim_set_current_buf(buf)
vim.fn.jobstart({ "sh", "-c", script }, { term = true })

local ns = vim.api.nvim_create_namespace("dev_termmarks")
local function marks()
	return vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })
end
local ok = vim.wait(5000, function()
	return #marks() >= 2
end, 20)
check("two marks appear (TermRequest fires headless)", ok)

-- содержимое терминала в буфере обновляется лениво, позже extmark-ов
vim.wait(3000, function()
	return vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] ~= ""
end, 20)
local m = marks()
check("D without C (first prompt) leaves no mark", #m == 2)
if #m >= 2 then
	local d1, d2 = m[1][4], m[2][4]
	local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
	check("first mark is x on prompt row", vim.trim(d1.sign_text) == "✗" and lines[m[1][2] + 1]:find("^%$"))
	check("first mark has exit 3", d1.virt_text and d1.virt_text[2][1] == "exit 3")
	check("second mark is check on prompt row", vim.trim(d2.sign_text) == "✓" and lines[m[2][2] + 1]:find("^%$"))
	check("success without duration has no virt_text", d2.virt_text == nil)
	check("fast failure has no duration part", d1.virt_text and #d1.virt_text == 2)
	check("marks on distinct rows", m[1][2] ~= m[2][2])
end

print(string.format("total=%d failures=%d", total, failures))
os.exit(failures > 0 and 1 or 0)
