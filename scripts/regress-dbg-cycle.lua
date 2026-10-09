-- scripts/regress-dbg-cycle.lua — unit tests for the debug continue
-- state machine (dev.debug.smart_continue) and exit feedback
-- (dev.debug._on_exited) with a fake dap object. No DAP, no UI.
--
-- Run:  nvim --headless --noplugin -u NONE \
--          --cmd "set rtp+=<repo-root>" -l scripts/regress-dbg-cycle.lua
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

-- No session -> launch path (continue invoked, may open config selector).
do
	notices = {}
	local dap = fake_dap(nil)
	dbg.smart_continue(dap)
	check("no-session launches", dap.continued() == 1)
end

-- Stopped session -> resume via continue, no hint.
do
	notices = {}
	local dap = fake_dap({ stopped_thread_id = 3, initialized = true })
	dbg.smart_continue(dap)
	check("stopped resumes", dap.continued() == 1)
	check("stopped no hint", not said("already running"))
end

-- Exit feedback: code 0 notifies exactly once per session.
do
	notices = {}
	dbg._exit_notified = {}
	dbg._on_exited({ id = 101 }, { exitCode = 0 })
	dbg._on_exited({ id = 101 }, { exitCode = 0 })
	dbg._on_exited({ id = 102 }, { exitCode = 0 })
	local n = 0
	for _, m in ipairs(notices) do
		if m:find("exited %(code 0%)") then
			n = n + 1
		end
	end
	check("exit feedback once per session", n == 2)
end

-- Exit feedback: non-zero / missing code stays silent (other paths report).
do
	notices = {}
	dbg._exit_notified = {}
	dbg._on_exited({ id = 201 }, { exitCode = 1 })
	dbg._on_exited({ id = 202 }, nil)
	check("exit failure silent", #notices == 0)
end

print(string.format("total=%d failures=%d", total, failures))
if failures > 0 then
	os.exit(1)
end
