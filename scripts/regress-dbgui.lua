-- scripts/regress-dbgui.lua — unit tests for dev.inspect._render_with()
-- using a canned fake session (no DAP, no UI). Covers: empty state,
-- frames/scopes/watches rendering, evaluate errors vs nil, missing
-- scopes, running (non-stopped) state without stale values.
--
-- Run:  nvim --headless --noplugin -u NONE \
--          --cmd "set rtp+=<repo-root>" -l scripts/regress-dbgui.lua
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

local function has(lines, pat)
	for _, l in ipairs(lines) do
		if l:find(pat, 1, true) then
			return true
		end
	end
	return false
end

local inspect = require("dev.inspect")

-- Canned session double: mimics the fake-dlv canned responses.
local function fake_session(o)
	o = o or {}
	return {
		id = o.id or 7,
		stopped_thread_id = o.stopped,
		current_frame = o.frame,
		request = function(_, command, args, cb)
			-- NB: real Session:request returns (err, result); keep order.
			-- With a callback (the inspector's main-thread path) answer
			-- synchronously through it, like a fast local adapter would.
			local err, res
			if command == "stackTrace" then
				if o.no_frames then
					err, res = nil, {}
				else
					err, res = nil, {
						stackFrames = {
							{ id = 11, name = "main.main", line = 7, source = { name = "main.go" } },
							{ id = 12, name = "main.helper", line = 3, source = { name = "main.go" } },
						},
					}
				end
			elseif command == "scopes" then
				if o.no_scopes then
					err, res = nil, { scopes = {} }
				else
					err, res = nil, { scopes = { { name = "Locals", variablesReference = 1 } } }
				end
			elseif command == "variables" then
				if args.variablesReference == 1 then
					err, res = nil, {
						variables = {
							{ name = "x", value = "42", variablesReference = 0 },
							{
								name = "cfg",
								value = "struct{...}",
								variablesReference = 2,
							},
						},
					}
				elseif args.variablesReference == 2 then
					err, res = nil, { variables = { { name = "Port", value = "8080", variablesReference = 0 } } }
				else
					err, res = { message = "unknown ref" }, nil
				end
			elseif command == "evaluate" then
				local e = args.expression
				if e == "boom" then
					err, res = { message = "could not evaluate" }, nil
				elseif e == "nothing" then
					err, res = nil, { result = nil, variablesReference = 0 }
				elseif e == "cfg" then
					err, res = nil, { result = "struct{...}", variablesReference = 2 }
				else
					err, res = nil, { result = "42", variablesReference = 0 }
				end
			else
				err, res = { message = "unsupported " .. command }, nil
			end
			if cb then
				cb(err, res)
				return nil
			end
			return err, res
		end,
	}
end

-- Render helper: _render_with is async (done callback); the double answers
-- synchronously so this returns the finished product.
local function render(sess)
	local got_lines, got_marks
	inspect._render_with(sess, function(lines, marks)
		got_lines, got_marks = lines, marks
	end)
	return got_lines, got_marks or {}
end

-- 1. No session -> explicit hint, no values.
do
	local lines = render(nil)
	check("no-session hint", has(lines, "no active session"))
	check("no-session no values", not has(lines, "42"))
end

-- 2. Stopped session: frames + scopes + watch values.
do
	inspect._test_set_watches({ "x" })
	local sess = fake_session({ stopped = 1, frame = { id = 11 } })
	local lines, marks = render(sess)
	check("frames header", has(lines, "frames (thread 1)"))
	check("current frame marked", has(lines, "→ main.main"))
	check("second frame listed", has(lines, "main.helper"))
	check("scope locals", has(lines, "Locals"))
	check("var x value", has(lines, "x: 42"))
	check("watch evaluated", has(lines, "x = 42"))
	local nmarks = 0
	local has_path_mark = false
	for _, m in pairs(marks) do
		nmarks = nmarks + 1
		if m.kind == "expand" and m.path == "Locals/cfg" then
			has_path_mark = true
		end
	end
	check("frame/watch marks present", nmarks >= 3)
	check("expand keyed by stable path", has_path_mark)
end

-- 3. Evaluate failure vs nil are distinct.
do
	inspect._test_set_watches({ "boom", "nothing" })
	local sess = fake_session({ stopped = 1, frame = { id = 11 } })
	local lines = render(sess)
	check("eval error shown", has(lines, "boom = <error: could not evaluate>"))
	check("eval nil shown", has(lines, "nothing = <nil>"))
end

-- 4. Missing scopes handled gracefully.
do
	inspect._test_set_watches({})
	local sess = fake_session({ stopped = 1, frame = { id = 11 }, no_scopes = true })
	local lines = render(sess)
	check("no-scopes message", has(lines, "(no scopes)"))
end

-- 5. Running (not stopped): no stale frame/var values.
do
	inspect._test_set_watches({ "x" })
	local sess = fake_session({ stopped = nil, frame = nil })
	local lines = render(sess)
	check("running header", has(lines, "running (no stopped thread)"))
	check("no stale frames", not has(lines, "main.main"))
	check("no stale vars", not has(lines, "x: 42"))
	check("watch waiting", has(lines, "x = (waiting for stop)"))
end

-- 6. Watches persist across renders (module state), values refresh.
do
	inspect._test_set_watches({ "x" })
	local sess = fake_session({ stopped = 1, frame = { id = 11 } })
	render(sess)
	check("watches persist", #inspect._test_watches() == 1)
	inspect._test_reset()
	check("reset clears", #inspect._test_watches() == 0)
end

print(string.format("total=%d failures=%d", total, failures))
if failures > 0 then
	os.exit(1)
end
