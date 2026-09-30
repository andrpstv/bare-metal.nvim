-- scripts/tui-latency-bench.lua — in-nvim probe for KEYSTROKE -> FRAME,
-- TIME TO FIRST FRAME and OPEN -> FRAME, measured through a REAL PTY (tui-test).
--
-- WHY THIS FILE EXISTS
-- scripts/interactive-bench.{sh,lua} already measure the post-open timeline, but
-- on a FIXED grid: they sample `lag` at t = 0/100/300/1000/2000/5000ms after
-- BufReadPost via vim.defer_fn. That answers "was the event loop blocked at this
-- fixed moment", which is NOT "the user pressed a key and a frame appeared". A
-- fixed schedule cannot attribute a paint to a key. So: prior art = event-loop
-- lag; this file = keystroke -> frame. It follows the prior art's conventions
-- (vim.uv.hrtime, vim.defer_fn, JSONL append+flush, a uis>0 precondition).
--
-- HOW A FRAME IS DETECTED  (nvim 0.12.5 — verified empirically, not assumed)
-- The obvious hook does not exist on this version: `redraw`/`redrawstatus` are
-- REJECTED by nvim_create_autocmd ("Invalid 'event': 'redraw'") and by
-- :autocmd ("E216: No such group or event"). So the frame proxy is `SafeState`,
-- which fires when nvim has drained the pending work for this input and is
-- about to block for the next one — the screen for that key has been generated.
--
--   t_key    = instant nvim READ the key, from vim.on_key(), documented as
--              firing "after mappings have been applied but before further
--              processing" — the closest in-process timestamp to the human
--              press. The driver's wall clock is NOT used: it would fold in
--              tui-test's IPC + pty-write latency, the harness's cost, not the
--              distro's. That overhead is measured separately and reported.
--   t_frame  = first SafeState at/after t_frame_deadline whose RENDERED
--              CONTENT CHANGED. See the deadline note below.
--
-- The content gate is load-bearing, not decorative. nvim reaches SafeState
-- whether or not anything was drawn: Ctrl-H in normal mode on a single-window
-- buffer settles in ~0.25ms with a byte-identical screen. That is not a frame
-- anyone saw. We compare a bounded signature of the rendered grid (status line
-- + a spread of cells + mode and cursor) at key time and at SafeState, and only
-- accept a frame when it differs. Unchanged settles are recorded, so a key that
-- never paints shows up as such instead of masquerading as a fast sample.
--
-- DEADLINE. Some keys here are ASYNC (a plugin window opens a beat after the
-- key). The first SafeState after them may still show an unchanged screen, so we
-- do not conclude "no frame" immediately: pending survives unchanged settles
-- until TLB_FRAME_WAIT_MS elapses, and only then is it reported as no_frame.
--
-- KNOWN LIMIT OF THE PROXY (stated, not hidden): SafeState marks the point
-- where the screen update for this key has been GENERATED, a hair before the
-- bytes reach the pty. The residual (the flush itself) is not in these numbers.
-- It is bounded by the only independent timestamp available — the tui-test cast —
-- whose own resolution is ~25ms, the harness's drain interval rather than a
-- sub-ms paint clock. The cast is therefore used to VALIDATE that output
-- happened and the content changed, never as the timer.
--
-- SEQUENCES. Several hot keys here are multi-key (`gt`, `g]`, `<leader>ff`, and
-- `jj` in insert mode). Timing only the final key would discard the real user
-- cost; timing only the first would misattribute the frame. So a watched entry
-- carries a role: "start" stamps the sequence origin without arming detection,
-- "end" arms against that origin, "solo" is a one-key sequence.
--
-- OUTPUT: one JSON object per line to $TLB_OUT (append + flush per record), so
-- a crash mid-run still leaves usable data and never stalls the driver.
--
-- ENV
--   TLB_OUT      output JSONL path (required)
--   TLB_MODE     ttf | keys | open | sanity   (default keys)
--   TLB_FILE     file to open (mode=open)
--   TLB_LABEL    condition name
--   TLB_RUN      repetition index
--   TLB_WATCH    comma-separated `label|typed|key|role` quadruples, pressed in
--                this order by the driver. typed/key are the expected pre-/post-
--                mapping keycodes; either match counts. role: solo|start|end.
--   TLB_HOLD_MS       session lifetime (default 30000)
--   TLB_FRAME_WAIT_MS how long to keep waiting for an async frame (default 2500)

local uv = vim.uv or vim.loop
local hrt = uv.hrtime
local now = uv.gettimeofday -- CLOCK_REALTIME seconds: the same wall clock the
-- driver timestamps with (`date +%s%N`), so harness delivery overhead is
-- measurable exactly, with no cross-clock alignment.

local MODE = vim.env.TLB_MODE or "keys"
local out_path = vim.env.TLB_OUT
local file = vim.env.TLB_FILE
local label = vim.env.TLB_LABEL or "?"
local run_idx = tonumber(vim.env.TLB_RUN or "0") or 0
local SEQ_WINDOW_MS = tonumber(vim.env.TLB_SEQ_WINDOW_MS or "2000") or 2000
local FRAME_WAIT_MS = tonumber(vim.env.TLB_FRAME_WAIT_MS or "2500") or 2500

if not out_path then
	io.stderr:write("[tui-latency-bench] ABORT: TLB_OUT required\n")
	vim.cmd("cquit 3")
end

local out = assert(io.open(out_path, "a"))

local harness_ns = hrt()
local vimenter_ns = nil
local settles = 0
local first_safestate = nil
local first_content_safestate = nil

local meta = {
	mode = MODE,
	label = label,
	run = run_idx,
	nvim = (function()
		local v = vim.version()
		return ("v%d.%d.%d"):format(v.major, v.minor, v.patch)
	end)(),
	file = file,
}

-- ------------------------------------------------------------- instrumentation

--- Emit one JSON record, flushed immediately: the driver paces itself by
--- watching for these lines, so buffering would stall the run.
local function emit(obj)
	obj.kind = obj.kind or "sample"
	for k, v in pairs(meta) do
		if obj[k] == nil then
			obj[k] = v
		end
	end
	for k, v in pairs(obj) do
		if type(v) == "string" then
			obj[k] = (v:gsub("[%z\1-\31\127-\255]", function(c)
				return ("\\x%02X"):format(c:byte())
			end))
		end
	end
	out:write(vim.json.encode(obj) .. "\n")
	out:flush()
end

--- Bounded signature of what is actually RENDERED. Deliberately not a
--- full-screen hash: it runs on every settle, so it must not be O(screen). It
--- samples the status-line row and a spread of grid cells, enough to see a mode
--- change, a cursor or window move, or a newly opened panel. pcall-wrapped:
--- screenstring is best-effort, and on failure we degrade to (mode, cursor) and
--- SAY SO in the record rather than pretending we measured content.
local function sig()
	local okp, parts = pcall(function()
		local p = {}
		p[#p + 1] = vim.fn.mode(1)
		p[#p + 1] = tostring(vim.fn.winline())
		p[#p + 1] = tostring(vim.fn.wincol())
		-- Clamp to the REAL terminal size: tui-test defaults to 80x30, and
		-- sampling columns past the edge yields empty strings that can never
		-- change, which would silently weaken the content gate.
		local rows = math.max(1, vim.o.lines - 1)
		local cols = vim.o.columns
		local cl = function(c) return math.min(c, cols) end
		for _, c in ipairs({ 1, 20, 40, 60, 80, 100, 120 }) do
			p[#p + 1] = vim.fn.screenstring(rows, cl(c))
		end
		for r = 1, math.max(1, rows - 1), 3 do
			for _, c in ipairs({ 1, 30, 60, 90 }) do
				p[#p + 1] = vim.fn.screenstring(r, cl(c))
			end
		end
		return table.concat(p, "\1")
	end)
	if not okp then
		return "degraded|mode=" .. vim.fn.mode(1)
	end
	return parts
end

local sig_at_boot = sig()

-- ---------------------------------------------------------- frame-event stream

local pending = nil -- open measurement awaiting its frame
local seq_start = nil -- origin of an in-progress multi-key sequence

vim.api.nvim_create_autocmd("VimEnter", {
	once = true,
	callback = function()
		vimenter_ns = hrt()
		emit({ kind = "vimenter", since_harness_ms = (hrt() - harness_ns) / 1e6, uis = #vim.api.nvim_list_uis() })
	end,
})

vim.api.nvim_create_autocmd("SafeState", {
	callback = function()
		settles = settles + 1
		local h = hrt()
		if first_safestate == nil then
			first_safestate = h
			emit({ kind = "first_safestate", since_harness_ms = (h - harness_ns) / 1e6, uis = #vim.api.nvim_list_uis() })
		end
		if MODE == "ttf" and first_content_safestate == nil then
			if sig() ~= sig_at_boot then
				first_content_safestate = h
				emit({
					kind = "ttf_result",
					content_changed = true,
					since_harness_ms = (h - harness_ns) / 1e6,
					uis = #vim.api.nvim_list_uis(),
				})
			end
		end
		local _s = sig()
		emit({
			kind = "settle",
			n = settles,
			since_key_ms = pending and ((h - pending.key_ns) / 1e6) or -1,
			degraded = (_s:sub(1, 8) == "degraded"),
			siglen = #_s,
			lines = vim.o.lines,
			cols = vim.o.columns,
			pre_len = pending and #pending.pre_sig or -1,
			changed_vs_pre = pending and (_s ~= pending.pre_sig) or false,
		})
		if not pending then
			return
		end

		local p = pending
		local s = sig()
		local changed = (s ~= p.pre_sig)
		local waited_ms = (h - p.key_ns) / 1e6

		if not changed and waited_ms < FRAME_WAIT_MS then
			-- Async: the screen is unchanged so far but the frame may still be
			-- coming. Keep waiting; record the miss.
			p.settle_nochange = p.settle_nochange + 1
			return
		end

		pending = nil
		if p.deadline then
			p.deadline:stop()
			p.deadline:close()
			p.deadline = nil
		end
		emit({
			kind = "frame",
			key = p.label,
			ord = p.ord,
			cold = p.ord == 1,
			seq_keys = p.seq_keys,
			latency_ms = waited_ms,
			content_changed = changed,
			nochange_settles = p.settle_nochange,
			sig_degraded = (s:sub(1, 8) == "degraded"),
		})
		emit({ kind = changed and "key_done" or "no_frame", key = p.label, ord = p.ord, latency_ms = waited_ms })
	end,
})

-- Arm a one-shot timer that force-closes a measurement that never found a
-- content-changing settle. Without it, a key whose screen never changes (or
-- whose effect is async) stays pending forever and the sample disappears
-- rather than being reported as the no_frame it is.
local function arm_deadline(p)
	if p.deadline then
		return
	end
	local t = uv.new_timer()
	p.deadline = t
	t:start(FRAME_WAIT_MS, 0, vim.schedule_wrap(function()
		t:stop()
		t:close()
		if pending ~= p then
			return
		end
		pending = nil
		local waited = (hrt() - p.key_ns) / 1e6
		emit({
			kind = "no_frame",
			key = p.label,
			ord = p.ord,
			cold = p.ord == 1,
			seq_keys = p.seq_keys,
			latency_ms = waited,
			content_changed = false,
			nochange_settles = p.settle_nochange,
			settles_total = settles,
		})
		emit({ kind = "no_frame_done", key = p.label, ord = p.ord, latency_ms = waited })
	end))
end

-- ----------------------------------------------------------------- key arrival
-- TLB_WATCH: "label|typed|key|role" quadruples in press order.
local watch = {}
do
	local raw = vim.env.TLB_WATCH or ""
	for chunk in raw:gmatch("[^,]+") do
		local lab, typed, key, role = chunk:match("^([^|]*)|([^|]*)|([^|]*)|(.*)$")
		if lab and lab ~= "" then
			watch[#watch + 1] = {
				label = lab,
				typed = (typed and typed ~= "") and typed or nil,
				key = (key and key ~= "") and key or nil,
				role = (role == "start" or role == "end") and role or "solo",
			}
		end
	end
end

-- Counters tag COLD (first press of a key) vs WARM (later presses) in-process,
-- so the split is never guessed by the driver.
local press_count = {}

if #watch > 0 then
	vim.on_key(function(key, typed)
		-- nvim REMOVES an on_key callback that raises, and a removed probe
		-- yields zero samples, which is indistinguishable from "no latency".
		-- So the body is guarded and any failure is recorded, not swallowed.
		local ok, err = pcall(function()
			-- Match on `typed` first: it is the raw key the human pressed, which
			-- is both what we want to timestamp and the field nvim leaves alone.
			-- `key` is post-mapping and canonicalised -- a plain "1" came back
			-- as the byte 0x87 -- so it is only a fallback.
			local hit = nil
			for _, w in ipairs(watch) do
				if w.typed and typed == w.typed then
					hit = w
					break
				end
			end
			if not hit then
				for _, w in ipairs(watch) do
					if w.key and key == w.key then
						hit = w
						break
					end
				end
			end
			if not hit then
				return
			end
			press_count[hit.label] = (press_count[hit.label] or 0) + 1
			local ord = press_count[hit.label]
			local h = hrt()

			if hit.role == "start" then
				seq_start = { ns = h, n = 1 }
				emit({ kind = "key_seen", key = hit.label, ord = ord, cold = ord == 1, role = "start", raw_key = key, raw_typed = typed })
				return
			end

			-- "end"/"solo": arm a measurement, anchored at the sequence origin
			-- when a fresh one is in progress.
			local key_ns, seq_keys, key_rt = h, 1, now()
			if seq_start and (h - seq_start.ns) / 1e6 <= SEQ_WINDOW_MS then
				key_ns, seq_keys = seq_start.ns, seq_start.n + 1
			end
			seq_start = nil

			pending = {
				label = hit.label,
				ord = ord,
				key_ns = key_ns,
				key_realtime = key_rt,
				pre_sig = sig(),
				settle_nochange = 0,
				seq_keys = seq_keys,
			}
			arm_deadline(pending)
			emit({
				kind = "key_seen",
				key = hit.label,
				ord = ord,
				cold = ord == 1,
				role = hit.role,
				raw_key = key,
				raw_typed = typed,
				seq_keys = seq_keys,
				delivery_realtime = key_rt,
			})
		end)
		if not ok then
			emit({ kind = "onkey_error", err = tostring(err), raw_key = key })
		end
		return nil
	end, nil, {})
end

-- ------------------------------------------------------------------ mode open
if MODE == "open" then
	local opened = false
	local function try_open()
		if opened then
			return
		end
		if #vim.api.nvim_list_uis() == 0 then
			vim.defer_fn(try_open, 5)
			return
		end
		opened = true
		local t_cmd = hrt()
		vim.o.swapfile = false
		vim.o.shadafile = "NONE"
		pending = { label = "open", ord = 1, key_ns = t_cmd, pre_sig = "", settle_nochange = 0, seq_keys = 0 }
		arm_deadline(pending)
		vim.cmd("edit " .. vim.fn.fnameescape(file))
	end
	try_open()
end

-- --------------------------------------------------------------- mode sanity
-- Instrument self-check. Plain DIGITS, not F-keys: tui-test `key press C-x` is
-- BROKEN on this version (it emits "C","c",... instead of the control byte) and
-- F-key keycodes are awkward to embed in an env var. Digits are single
-- unambiguous bytes, so this validates the INSTRUMENT rather than the harness's
-- key translation. If frame detection were bogus, `1` would not read ~200ms.
if MODE == "sanity" then
	-- Plain DIGITS, not F-keys: tui-test `key press C-x` is BROKEN on this
	-- version (it emits "C","c",... rather than the control byte) and F-key
	-- keycodes are awkward to embed in an env var. Digits are single
	-- unambiguous bytes, so this validates the INSTRUMENT rather than the
	-- harness's key translation.
	--
	-- Each key must also REPAINT, otherwise the content gate would (correctly)
	-- reject it as no_frame: waiting alone changes nothing on screen. So each
	-- blocks for a known duration and then moves the cursor to a fixed line,
	-- which is a guaranteed visible change.
	local function inject(ms, line)
		vim.wait(ms)
		local n = vim.fn.line("$")
		pcall(vim.api.nvim_win_set_cursor, 0, { math.min(math.max(n, 20), line), 1 })
	end
	vim.keymap.set("n", "1", function() inject(200, 8) end, { desc = "tui-latency-bench: inject 200ms" })
	vim.keymap.set("n", "2", function() inject(0, 4) end, { desc = "tui-latency-bench: inject 0ms" })
	vim.keymap.set("n", "3", function() inject(600, 12) end, { desc = "tui-latency-bench: inject 600ms" })
	emit({ kind = "sanity_ready", injected_ms = { ["1"] = 200, ["2"] = 0, ["3"] = 600 } })
end

-- ------------------------------------------------------------------- validity
-- The single most important check: is a UI actually attached? Without one,
-- lua/distro/loader.lua's defer_enabled() gate is closed, every deferral path is
-- inert, and the numbers would describe the headless path.
vim.defer_fn(function()
	emit({
		kind = "validity",
		uis = #vim.api.nvim_list_uis(),
		watched_keys = #watch,
		settles = settles,
		vimenter_seen = vimenter_ns ~= nil,
		loader_ok = (pcall(require, "distro.loader")),
	})
end, 300)

vim.defer_fn(function()
	emit({ kind = "final", uis = #vim.api.nvim_list_uis(), settles = settles })
	out:close()
	vim.schedule(function()
		vim.cmd("qall!")
	end)
end, tonumber(vim.env.TLB_HOLD_MS or "30000") or 30000)
