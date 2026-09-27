-- scripts/interactive-bench.lua — post-open (post-paint) timeline probe.
--
-- WHY THIS FILE EXISTS
-- Every existing benchmark in this repo (lua/distro/bench.lua,
-- lua/distro/benchui.lua, scripts/startup-bench.sh) runs HEADLESS. Headless
-- means nvim_list_uis() == 0, and lua/distro/loader.lua:157 `defer_enabled()`
-- returns false in that case — so EVERY interactive-only deferral path
-- (defer_idle / defer_until_idle, the turbo gitsigns attach, the idle khold
-- highlight apply) is INERT under those benchmarks. They measure the
-- synchronous path only. This probe measures the part nobody measured: the
-- milliseconds AFTER BufReadPost in a real UI-attached session.
--
-- CONTRACT
--   * REQUIRES a UI-attached nvim. If #nvim_list_uis() == 0 the probe writes
--     an `abort` record and exits non-zero (`:cquit 3`). It never silently
--     measures the inert headless path — that failure mode is what produced
--     the current zero-evidence gap on branch refactor/simplify-and-harden.
--   * Emits one JSON object per line to $IBENCH_OUT (append, flushed at once)
--     so a crash mid-run still leaves usable data.
--
-- ENV
--   IBENCH_OUT     output JSONL path            (required)
--   IBENCH_FILE    file to open inside the UI   (required)
--   IBENCH_LABEL   condition name, e.g. "distro-turbo"          (default "?")
--   IBENCH_RUN     repetition index (for raw-sample correlation)
--   IBENCH_TS=1    condition (d): clean nvim + vendored nvim-treesitter ONLY
--   IBENCH_BOOT_REQUIRE=1  require distro.loader to be present, else abort
--                          (use for distro conditions: catches a distro that
--                          failed to boot inside the pty)

local uv = vim.uv or vim.loop
local hrt = uv.hrtime

local out_path = vim.env.IBENCH_OUT
local target = vim.env.IBENCH_FILE
local label = vim.env.IBENCH_LABEL or "?"
local run_idx = tonumber(vim.env.IBENCH_RUN or "0") or 0
local turbo_env = vim.env.NVIM_TURBO or vim.env.NVIM_TURBO_MODE or "-"
-- Каноника 4->2: пишем и новые env рядом со старыми, иначе A/B метки
-- (NVIM_PERF_DEFER=0/1 vs NVIM_TURBO=1) разъезжаются в агрегаторе.
local perf_defer_env = vim.env.NVIM_PERF_DEFER or "-"
local perf_lean_env = vim.env.NVIM_PERF_LEAN or "-"
local weak_hw_env = vim.env.NVIM_WEAK_HW or "-"
local sync_env = vim.env.NVIM_DISTRO_SYNC or "-"
local ts_only = vim.env.IBENCH_TS == "1"
local boot_required = vim.env.IBENCH_BOOT_REQUIRE == "1"

if not out_path or not target then
	io.stderr:write("[interactive-bench] ABORT: IBENCH_OUT and IBENCH_FILE are required\n")
	vim.cmd("cquit 3")
end

local out = assert(io.open(out_path, "a"))

local meta = {
	kind = "sample",
	label = label,
	run = run_idx,
	file = target,
	uis = #vim.api.nvim_list_uis(),
	nvim_turbo = turbo_env,
	nvim_perf_defer = perf_defer_env,
	nvim_perf_lean = perf_lean_env,
	nvim_weak_hw = weak_hw_env,
	distro_sync = sync_env,
	ts_only = ts_only,
}

local function emit(obj)
	for k, v in pairs(meta) do
		if obj[k] == nil then
			obj[k] = v
		end
	end
	out:write(vim.json.encode(obj) .. "\n")
	out:flush()
end

local function die(reason, extra)
	emit({ kind = "abort", reason = reason, t_ms = -1, extra = extra or {} })
	local msg = table.concat({
		"",
		"  ============================================================",
		"  [interactive-bench] ABORT: " .. reason,
		"  The interactive post-paint curve CANNOT be measured here.",
		"  Re-run through scripts/interactive-bench.sh (pty/tmux wrapper).",
		"  ============================================================",
		"",
	}, "\n")
	io.stderr:write(msg)
	-- NOTE: the human-readable banner goes to a sidecar, never into the JSONL
	-- (the aggregator parses that file line-by-line and must stay valid).
	local side = io.open(out_path .. ".aborts", "a")
	if side then
		side:write(msg)
		side:close()
	end
	out:flush()
	pcall(function()
		-- surface on the real screen too, in case stderr is swallowed by the pty
		vim.schedule(function()
			vim.api.nvim_echo({ { "[interactive-bench] ABORT: " .. reason, "ErrorMsg" } }, true, {})
			vim.cmd("cquit 3")
		end)
	end)
end

-- ---------------------------------------------------------------- preconditions
-- NOTE: the TUI attaches AFTER `-c` startup commands, so a probe that checks
-- nvim_list_uis() synchronously at startup would always see 0 and always abort.
-- We therefore poll for a genuine UI attach (bounded), and only then proceed.
local loader_ok, loader = pcall(require, "distro.loader")

-- Empirical proof that the deferral path is live, not just that a UI exists.
-- defer_enabled() is local to loader.lua, so we probe its observable effect:
-- under a live UI, a BufReadPost-deferred plugin must be loaded *after*
-- BufReadPost, not during it.
local t0_ns = nil
local boot_to_bufread = nil
local harness_ns = hrt()
local first_sample = nil
local last_sample = nil

local function plugins_loaded()
	if not (loader_ok and type(loader.loaded) == "table") then
		return -1, ""
	end
	local n, names = 0, {}
	for k in pairs(loader.loaded) do
		n = n + 1
		names[#names + 1] = k
	end
	table.sort(names)
	return n, table.concat(names, ",")
end

--- Snapshot of every observable the evidence doc needs, at time `t_ms`.
local function snapshot(t_ms, lag_ms)
	local buf = vim.api.nvim_get_current_buf()
	local n, names = plugins_loaded()

	local lsp = -1
	local lok, clients = pcall(vim.lsp.get_clients, { bufnr = buf })
	if lok and type(clients) == "table" then
		lsp = #clients
	end

	-- treesitter: a parser object only exists once the language is loaded AND
	-- parsing has been started for this buffer.
	local ts = false
	local tok, parser = pcall(vim.treesitter.get_parser, buf)
	if tok and parser ~= nil then
		ts = true
	end

	-- gitsigns: `package.loaded` = the plugin code is in memory; the buffer
	-- variable `gitsigns_head` = actually attached to THIS buffer (this is the
	-- bit turbo defers, and the bit that costs time on a large file).
	local gs_loaded = package.loaded["gitsigns"] ~= nil
	local gs_attached = vim.b[buf].gitsigns_head ~= nil

	local s = {
		kind = "sample",
		t_ms = t_ms,
		lag_ms = lag_ms,
		plugins = n,
		plugin_names = names,
		gitsigns_loaded = gs_loaded,
		gitsigns_attached = gs_attached,
		lsp_clients = lsp,
		ts_parser = ts,
		buf = buf,
	}
	emit(s)
	if first_sample == nil then
		first_sample = s
	end
	last_sample = s
	return s
end

--- Sample at absolute offset `ms` after BufReadPost. `lag_ms` is how late the
--- event loop actually delivered the callback: a positive burst at 100/300 is
--- the signature of a post-paint stall (the "300ms cliff").
local function sample_at(ms)
	-- defer_fn wakes the loop; recompute the true delta so a stalled loop is
	-- visible in the data instead of being hidden by the nominal schedule.
	vim.defer_fn(function()
		local elapsed = (hrt() - t0_ns) / 1e6
		snapshot(math.floor(elapsed + 0.5), math.floor(elapsed - ms + 0.5))
		if ms >= horizon then
			emit({
				kind = "done",
				t_ms = math.floor(elapsed + 0.5),
				plugins_first = first_sample and first_sample.plugins or -1,
				plugins_last = last_sample and last_sample.plugins or -1,
				-- deferral_inert == true  =>  nothing was deferred past the
				-- paint: the interactive curve is NOT being exercised and the
				-- run must not be read as interactive evidence.
				deferral_inert = (first_sample and last_sample) and (first_sample.plugins == last_sample.plugins) or nil,
				boot_to_bufread_ms = boot_to_bufread and math.floor(boot_to_bufread + 0.5) or -1,
			})
			out:close()
			vim.schedule(function()
				vim.cmd("qall!")
			end)
		end
	end, ms)
end

-- ------------------------------------------------------- condition (d) support
-- "clean nvim + nvim-treesitter ONLY": isolates the Go parse cost — the
-- dominant size-dependent mechanism — from the rest of the distro stack.
local ts_setup_ok = false
if ts_only then
	local cfg = vim.fn.stdpath("config")
	vim.opt.rtp:prepend(cfg .. "/pack/distro/opt/nvim-treesitter")
	local tok, ts = pcall(require, "nvim-treesitter")
	if tok then
		pcall(ts.setup, {})
		ts_setup_ok = true
		vim.api.nvim_create_autocmd("BufReadPre", {
			pattern = "*.go",
			callback = function()
				pcall(function()
					vim.treesitter.start(0, "go")
				end)
			end,
			desc = "interactive-bench: treesitter-only start",
		})
	end
end
meta.ts_setup_ok = ts_setup_ok

-- ------------------------------------------------------------------- open file
vim.api.nvim_create_autocmd("BufReadPost", {
	once = true,
	callback = function()
		-- NOTE: runs at BufReadPost *entry*, i.e. before vim.schedule() drains
		-- any deferred loader work. That is the pre-paint baseline.
		t0_ns = hrt()
		boot_to_bufread = (t0_ns - harness_ns) / 1e6
		-- read line count for the size-dependence axis
		local lines = 0
		local ok, c = pcall(function()
			return #vim.api.nvim_buf_get_lines(0, 0, -1, false)
		end)
		if ok then
			lines = c
		end
		meta.lines = lines
		snapshot(0, 0)
		-- Horizon is configurable: the 1000ms default is the post-paint
		-- window, longer values are used to check whether deferred work
		-- (notably the turbo gitsigns attach, which waits for an idle moment)
		-- EVER lands.
		local horizon = tonumber(vim.env.IBENCH_HORIZON or "1000") or 1000
		for _, ms in ipairs({ 100, 300, 1000, 2000, 5000 }) do
			if ms <= horizon then
				sample_at(ms)
			end
		end
	end,
})

-- Hard stop: if BufReadPost never fires (bad path, unreadable file) we must not
-- hang the driver forever.
local function open_target()
	-- Set AFTER the UI attaches, never via `--cmd` (see scripts/interactive-bench.sh):
	-- a startup `--cmd` perturbs the very path under measurement.
	vim.o.swapfile = false
	vim.o.shadafile = "NONE"
	vim.defer_fn(function()
		if t0_ns == nil then
			die("BufReadPost never fired for " .. target)
		end
	end, 5000)
	vim.cmd("edit " .. vim.fn.fnameescape(target))
end

-- Bounded poll for a real UI attach, then enforce every precondition and only
-- then open the file. A headless context must never produce a sample line.
local ATTACH_TIMEOUT_MS = tonumber(vim.env.IBENCH_ATTACH_TIMEOUT or "5000") or 5000
local waited = 0

local function wait_for_ui()
	local uis = #vim.api.nvim_list_uis()
	if uis > 0 then
		meta.uis = uis
		if boot_required and not loader_ok then
			die("distro.loader not loadable under label '" .. label
				.. "' — the distro did not boot in this UI session (t=" .. waited .. "ms).")
		end
		emit({ kind = "attached", t_ms = -1, attach_wait_ms = waited, extra = { uis = uis } })
		open_target()
		return
	end
	waited = waited + 10
	if waited >= ATTACH_TIMEOUT_MS then
		die("no UI attached after " .. ATTACH_TIMEOUT_MS
			.. "ms (nvim_list_uis() == 0) — refusing to measure the inert headless path. "
			.. "This process was not started under a pty/tmux by scripts/interactive-bench.sh.")
	end
	vim.defer_fn(wait_for_ui, 10)
end

wait_for_ui()
