-- scripts/regress-dbg-running.lua — the reported incident as a test:
-- invoking Continue on an already-RUNNING session must NOT open the
-- generic vim.ui.select menu. Uses a select spy + fake dap session.
--
-- Run:  nvim --headless --noplugin -u NONE \
--          --cmd "set rtp+=<repo-root>" -l scripts/regress-dbg-running.lua
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

local notices = {}
---@diagnostic disable-next-line: duplicate-set-field
vim.notify = function(msg, level)
	notices[#notices + 1] = tostring(msg)
end

local select_calls = 0
local real_select = vim.ui.select
---@diagnostic disable-next-line: duplicate-set-field
vim.ui.select = function(...)
	select_calls = select_calls + 1
end

local dbg = require("dev.debug")

local function fake_dap(sess)
	local sess_ref = sess
	local continued = 0
	return {
		session = function()
			return sess_ref
		end,
		continue = function()
			continued = continued + 1
		end,
		continued = function()
			return continued
		end,
	}
end

local function said(pat)
	for _, m in ipairs(notices) do
		if m:find(pat, 1, true) then
			return true
		end
	end
	return false
end

-- Running session: no continue, no select menu, actionable hint.
do
	notices = {}
	select_calls = 0
	local dap = fake_dap({ stopped_thread_id = nil, initialized = true })
	dbg.smart_continue(dap)
	check("running not continued", dap.continued() == 0)
	check("running opens no select menu", select_calls == 0)
	check("running hint names stop", said("dx"))
	check("running hint names pause", said("dp"))
end

-- Initializing session: wait hint, no continue, no menu.
do
	notices = {}
	select_calls = 0
	local dap = fake_dap({ stopped_thread_id = nil, initialized = nil })
	dbg.smart_continue(dap)
	check("initializing not continued", dap.continued() == 0)
	check("initializing opens no menu", select_calls == 0)
	check("initializing hint", said("starting"))
end

-- Stopped session: resumes via continue (may legitimately use select
-- downstream in real nvim-dap; here the fake records the call).
do
	notices = {}
	select_calls = 0
	local dap = fake_dap({ stopped_thread_id = 5, initialized = true })
	dbg.smart_continue(dap)
	check("stopped resumes", dap.continued() == 1)
end

vim.ui.select = real_select

print(string.format("total=%d failures=%d", total, failures))
if failures > 0 then
	os.exit(1)
end
