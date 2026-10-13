-- scripts/regress-inlinevals.lua — dev.inlinevals: правило размещения (_place), усечение и
-- сквозной прогон с fake-сессией (stackTrace/scopes/variables) + очистка по continued.
--
-- Run:  nvim --headless --noplugin -u NONE \
--          --cmd "set rtp+=<repo-root>" -l scripts/regress-inlinevals.lua
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

local iv = require("dev.inlinevals")
local function V(n, v, ref)
	return { name = n, value = v, variablesReference = ref or 0 }
end

local src = {
	"package main", -- 1
	"func other() {", -- 2
	"	x := 1", -- 3
	"}", -- 4
	"func run(p int, q string) error {", -- 5
	"	n := 1", -- 6
	"	n = 2", -- 7
	"	a, b := 3, 4", -- 8
	"	var v int", -- 9
	"	for _, it := range items {", -- 10
	"		if n == 2 {", -- 11
	"			_ = it", -- 12
	"		}", -- 13
	"	}", -- 14
	"	return nil", -- 15
	"}", -- 16
}
local p = iv._place(src, 15, {
	V("p", "9"), V("q", '"hi"'), V("n", "2"), V("a", "3"), V("b", "4"), V("v", "0"), V("it", "7"),
	V("x", "1"), V("ghost", "0"), V("~r0", "nil"),
})
check("param on func line", p[5] == "p = 9, q = " .. '"hi"')
check("last assignment wins (n = 2 at row 7)", p[7] == "n = 2" and not p[6])
check("multi-assign joined on one line", p[8] == "a = 3, b = 4")
check("var decl", p[9] == "v = 0")
check("range loop var", p[10] == "it = 7")
check("not found skipped, == not an assignment", not p[11])
check("stops at function start (x from other func skipped)", not p[3])
check("~ internals skipped", not vim.tbl_contains(vim.tbl_values(p), "~r0 = nil"))
local cnt = 0
for _ in pairs(p) do
	cnt = cnt + 1
end
check("only expected rows", cnt == 5)

local long = string.rep("x", 60)
local t = iv._place({ "func f() {", "	s := 1" }, 2, { V("s", long), V("m", "map[...]", 5), V("big", long, 6) })
check("long scalar truncated with ellipsis", t[2]:find("…", 1, true) and vim.fn.strchars(t[2]) <= #"s = " + 40)
check("long structured -> {…}", not t[2]:find("big", 1, true) and true)
t = iv._place({ "func f() {", "	big := mk()" }, 2, { V("big", long, 6) })
check("structured huge -> {…}", t[2] == "big = {…}")

-- ------------------------------------------------------------ end-to-end
local path = vim.fs.normalize(vim.fn.tempname() .. "/main.go")
local buf = vim.api.nvim_create_buf(true, false)
vim.api.nvim_buf_set_name(buf, path)
vim.api.nvim_buf_set_lines(buf, 0, -1, false, src)
local sess = {
	stopped_thread_id = 1,
	request = function(_, cmd, args, cb)
		if cmd == "stackTrace" then
			cb(nil, { stackFrames = { { id = 11, line = 15, source = { path = path } } } })
		elseif cmd == "scopes" then
			cb(nil, { scopes = { { name = "Arguments", variablesReference = 3 }, { name = "Locals", variablesReference = 1 } } })
		elseif cmd == "variables" and args.variablesReference == 1 then
			cb(nil, { variables = { V("n", "2"), V("a", "3"), V("b", "4") } })
		else
			cb({ message = "unexpected" }, nil)
		end
	end,
}
local ns = vim.api.nvim_create_namespace("dev_inlinevals")
local function marks()
	return vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })
end
iv._on_stopped(sess, { threadId = 1 })
local m = marks()
local rows = {}
for _, e in ipairs(m) do
	rows[e[2] + 1] = e[4].virt_text[1][1]
end
check("e2e: two extmarks", #m == 2)
check("e2e: n at row 7", rows[7] == "  n = 2")
check("e2e: a,b at row 8", rows[8] == "  a = 3, b = 4")
check("e2e: Comment highlight", m[1][4].virt_text[1][2] == "Comment")
iv.clear()
check("cleared", #marks() == 0)

-- attach: listeners ставятся, continued очищает
local dap = { listeners = { after = setmetatable({}, { __index = function(t, k) t[k] = {} return t[k] end }) } }
iv.attach(dap)
dap.listeners.after.event_stopped["dev_inlinevals"](sess, { threadId = 1 })
check("attach: stopped draws", #marks() == 2)
dap.listeners.after.event_continued["dev_inlinevals"](sess, {})
check("attach: continued clears", #marks() == 0)
dap.listeners.after.event_stopped["dev_inlinevals"](sess, { threadId = 1 })
dap.listeners.after.continue["dev_inlinevals"](sess, {})
check("attach: continue request clears (dlv sends no continued event)", #marks() == 0)

print(("inlinevals: total=%d failures=%d"):format(total, failures))
os.exit(failures == 0 and 0 or 1)
