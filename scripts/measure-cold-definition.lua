-- =============================================================================
-- cold/warm definition RTT for a symbol living in the Go module cache
-- =============================================================================
-- WHAT   Closes PERF-1C item 3 (docs/distro/30-cold-jump-measurement.md 5).
--        Measures the round trip of `textDocument/definition` aimed at a
--        symbol DEFINED IN THE MODULE CACHE (pkg/mod), in two states:
--          (B) cold - gopls freshly started, first request ever for the package
--          (A) warm - the same gopls already worked with that package
--        Prints both numbers, the delta, and an HONEST verdict on whether the
--        delta matches the ~5237 ms seen in the original trace.
-- HOW
--   nvim --clean -l scripts/measure-cold-definition.lua \
--     --workspace /Users/16prom1/sdk-go \
--     --file main.go --symbol Client --qualified mongo.Client
--
--   Optional:
--     --rounds N        cold/warm pairs per run (default 3)
--     --gopls PATH      gopls binary (default: $GOPLS, else `which gopls`)
--     --expect-mod STR  substring the resolved target must contain
--                       (default /pkg/mod/ - proves the jump left the workspace)
--     --timeout-ms N    per-request / per-initialize ceiling (default 120000)
--     --settle-ms N     pause after killing a client (default 1500)
--     --with-config     also load the owner init.lua (default: not loaded)
--     --dry-run         resolve the aim point, start no gopls
--     -h | --help       this text
--
-- EXIT   0  measured (both states, delta, verdict)
--        2  bad usage
--        3  --file not found / not a regular file
--        4  symbol (or its qualified context) not found in --file
--        5  gopls not found, not started, or did not initialize
--        6  definition empty, or target outside the module cache
--        7  a request did not answer within --timeout-ms
--
-- NOTES  * READ-ONLY. Writes nothing, clears no cache, changes no setting.
--         Owner config is only READ, and only with --with-config.
--       * Defaults to a clean start: measures the gopls side of the jump.
--         Use --with-config to include our own wrapper.
--       * Median, never min-of-N: min-of-3 on a warm host hides the cold run.
--       * No shell `timeout` (absent on this machine) and no global `sleep`
--         (E5108 in nvim) - all waiting goes through vim.wait.
--       * Refuses to measure when the aim falls in an import statement, a
--         comment or a string literal, and prints the declaration it landed on.
--       * Reports the aim point (file, line, byte column, source line). A
--         request aimed at a package identifier resolves to the importing file
--         and still returns a valid-looking, meaningless number.
--       * Measures RTT only. It confirms and refutes no hypothesis about root
--         markers, background analyses, or client-attach policy.
-- =============================================================================

local SCRIPT_PATH = debug.getinfo(1, "S").source:sub(2)

local function die(code, msg)
	io.stderr:write("FAIL: " .. msg .. "\n")
	os.exit(code)
end

local function info(k, v) print(string.format("  %-24s %s", k, tostring(v))) end

-- --------------------------------------------------------------- arg parsing --
-- `nvim -l script.lua a b` delivers arguments in vim.v.argv, NOT in `...`.
local function script_args()
	local argv = vim.v.argv or {}
	for i = 1, #argv do
		if argv[i] == SCRIPT_PATH then
			local out = {}
			for j = i + 1, #argv do
				out[#out + 1] = argv[j]
			end
			return out
		end
	end
	return {}
end

local function print_help()
	local n = 0
	for line in io.lines(SCRIPT_PATH) do
		n = n + 1
		if n > 1 and line:match("^%-%-+ ") then
			break
		end
		print(line)
	end
end

local VALUE_OPTS = {
	["--workspace"] = "workspace",
	["--file"] = "file",
	["--symbol"] = "symbol",
	["--qualified"] = "qualified",
	["--rounds"] = "rounds",
	["--gopls"] = "gopls",
	["--expect-mod"] = "expect_mod",
	["--timeout-ms"] = "timeout_ms",
	["--settle-ms"] = "settle_ms",
}

local opts = { rounds = 3, timeout_ms = 120000, settle_ms = 1500, expect_mod = "/pkg/mod/" }
local args = script_args()
local i = 1
while i <= #args do
	local a = args[i]
	if a == "-h" or a == "--help" then
		print_help()
		os.exit(0)
	elseif a == "--with-config" then
		opts.with_config = true
	elseif a == "--dry-run" then
		opts.dry_run = true
	elseif VALUE_OPTS[a] then
		local v = args[i + 1]
		if v == nil then
			die(2, a .. " needs a value")
		end
		opts[VALUE_OPTS[a]] = v
		i = i + 1
	else
		die(2, "unknown argument: " .. tostring(a) .. " (try --help)")
	end
	i = i + 1
end

for _, n in ipairs({ "rounds", "timeout_ms", "settle_ms" }) do
	opts[n] = tonumber(opts[n])
	if opts[n] == nil or opts[n] < 1 then
		die(2, "--" .. n:gsub("_", "-") .. " must be a positive number")
	end
end

local function need(name)
	local v = opts[name]
	if v == nil or v == "" then
		die(2, "missing required option " .. name:gsub("_", "%-") .. " (try --help)")
	end
	return v
end

-- ------------------------------------------------------------------ aim point -
local workspace = need("workspace")
local file_arg = need("file")
local symbol = need("symbol")
local qualified = opts.qualified

local function isdir(p)
	local st = vim.uv.fs_stat(p)
	return st ~= nil and st.type == "directory"
end

if not isdir(workspace) then
	die(2, "workspace is not a directory: " .. workspace)
end

local target_file = file_arg
if not target_file:match("^/") then
	target_file = workspace .. "/" .. target_file
end
local st = vim.uv.fs_stat(target_file)
if st == nil then
	die(3, "--file not found: " .. target_file)
end
if st.type ~= "file" then
	die(3, "--file is not a regular file: " .. target_file)
end

local buf = vim.fn.bufadd(target_file)
vim.fn.bufload(buf)
vim.bo[buf].filetype = "go"

-- Locate the aim point with a plain text scan: no cursor and no search(),
-- which is unreliable headless. The qualified form separates the symbol from
-- its package qualifier - the exact defect that made the earlier stand report
-- a valid-looking jump into the importing file instead of the library.
-- A match landing inside a string literal is a package PATH, not a symbol use.
-- A request aimed there still answers and can still land in pkg/mod, so the
-- number looks plausible while measuring nothing (PERF-1C 3.3).
local function in_string(text, idx)
	local open = false
	for i = 1, #text do
		if text:sub(i, i) == '"' and (i == 1 or text:sub(i - 1, i - 1) ~= "\\") then
			open = not open
		end
		if i == idx then
			return open
		end
	end
	return false
end

local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
local needle = qualified or symbol
local aim, why = nil, nil
local in_import = false
for ln, text in ipairs(lines) do
	if text:match("^%s*import%s*%(") then
		in_import = true
	elseif in_import and text:match("^%s*%)") then
		in_import = false
	end
	local sidx = text:find(needle, 1, true)
	if sidx then
		if in_import or text:match("^%s*import%s+") then
			why = "first match is inside an import statement (package path, not a symbol use)"
			break
		end
		if text:match("^%s*//") then
			why = "first match is a comment"
			break
		end
		if in_string(text, sidx) then
			why = "first match is inside a string literal (package path, not a symbol use)"
			break
		end
		if qualified then
			local off = qualified:find(symbol, 1, true)
			-- find() is 1-based: the symbol ends at off + #symbol - 1
			if not off or off + #symbol - 1 > #qualified then
				why = "qualified text does not contain the symbol"
				break
			end
			aim = { line = ln, byte_col = sidx + off - 1, text = text }
		else
			aim = { line = ln, byte_col = sidx, text = text }
		end
		break
	end
end

if not aim then
	die(
		4,
		"could not aim at symbol '"
			.. symbol
			.. "'"
			.. (qualified and (" inside '" .. qualified .. "'") or "")
			.. " in "
			.. target_file
			.. (why and ("\n       reason: " .. why) or "\n       symbol not present in the file")
			.. "\n       hint: pass --qualified <pkg.Symbol> to disambiguate from import lines/comments"
	)
end

local pos = { line = aim.line - 1, character = aim.byte_col - 1 }

print("== aim point ==")
info("--file", target_file)
info("line : byte_col", string.format("%d : %d", aim.line, aim.byte_col))
info("source line", string.format("%q", aim.text))
info("lsp position", string.format("line=%d character=%d (0-based)", pos.line, pos.character))
info("workspace (root_dir)", workspace)

if opts.dry_run then
	print("dry run: aim resolved; gopls not started")
	os.exit(0)
end

if opts.with_config then
	local cfg = vim.fn.stdpath("config")
	local init = cfg .. "/init.lua"
	if vim.uv.fs_stat(init) == nil then
		die(5, "--with-config: no init.lua at " .. init)
	end
	-- `nvim -l` starts with a bare runtimepath, so the distro's own lua/ is not
	-- on it and require("core") misses. Prepend; never replace what nvim has.
	vim.opt.runtimepath:prepend(cfg)
	vim.g.distro_home = cfg
	local ok, err = pcall(dofile, init)
	if not ok then
		die(5, "owner config failed to load: " .. tostring(err))
	end
end

-- --------------------------------------------------------------------- gopls --
local gopls = opts.gopls or vim.env.GOPLS
if not gopls or gopls == "" then
	local ok = pcall(function()
		gopls = vim.trim(vim.system({ "which", "gopls" }, { text = true }):wait().stdout or "")
	end)
	if not ok or gopls == nil or gopls == "" then
		die(5, "gopls not found on PATH: pass --gopls PATH")
	end
end
gopls = vim.trim(gopls)
if vim.uv.fs_stat(gopls) == nil then
	die(5, "gopls binary not found: " .. gopls)
end
info("gopls", gopls)
info("owner config", opts.with_config and "loaded" or "not loaded (default)")

local uri = vim.uri_from_bufnr(buf)

local function start_client()
	local id = vim.lsp.start({ name = "gopls-measure", cmd = { gopls }, root_dir = workspace }, { bufnr = buf })
	if not id then
		die(5, "vim.lsp.start returned no client id")
	end
	local ok = vim.wait(opts.timeout_ms, function()
		local c = vim.lsp.get_client_by_id(id)
		return c ~= nil and c.initialized
	end, 50)
	if not ok then
		die(5, "gopls did not initialize within " .. opts.timeout_ms .. " ms")
	end
	return id
end

local function stop_client(id)
	vim.lsp.stop_client(id, true)
	-- vim.wait doubles as the sleep: `sleep` is not a global nvim function.
	vim.wait(opts.settle_ms, function()
		return false
	end, 100)
end

-- The metric: buf_request -> handler callback, as in docs/distro/30 3.1.
-- Returns ms, resolved_path, kind ("timeout" | "empty" | "lsp" | nil)
local function request_definition()
	local t0 = vim.uv.hrtime()
	local done, err, res = false, nil, nil
	vim.lsp.buf_request(buf, "textDocument/definition", {
		textDocument = { uri = uri },
		position = pos,
	}, function(e, r)
		done, err, res = true, e, r
	end)
	if not vim.wait(opts.timeout_ms, function()
		return done
	end, 20) then
		return nil, nil, "timeout"
	end
	if err then
		return nil, nil, "lsp error: " .. vim.inspect(err)
	end
	local r = res
	if type(r) == "table" and r.uri == nil and r.targetUri == nil and r[1] ~= nil then
		r = r[1] -- Location[] / LocationLink[]
	end
	if type(r) ~= "table" or r == vim.NIL then
		return nil, nil, "empty response (symbol did not resolve)"
	end
	local path = r.targetUri or r.uri
	if type(path) ~= "string" or path == "" then
		return nil, nil, "response carried no location"
	end
	path = path:gsub("^file://", "")
	local rng = r.targetSelectionRange or r.range or {}
	local rline = rng.start and rng.start.line
	return (vim.uv.hrtime() - t0) / 1e6, path, rline, nil
end

local function fail_on(kind, path)
	if kind == "timeout" then
		die(7, "definition did not answer within " .. opts.timeout_ms .. " ms")
	end
	if path and not path:find(opts.expect_mod, 1, true) then
		die(6, "target is outside the module cache (expected '"
			.. opts.expect_mod
			.. "' in the path): "
			.. path
			.. "\n       the aim point resolved to a different location - fix the aim, not the number")
	end
	die(6, "definition failed: " .. tostring(kind))
end

-- ------------------------------------------------------------------- measure --
print("== run ==")
info("rounds", opts.rounds)
info("settle between clients", opts.settle_ms .. " ms")
info("aggregation", "median (min-of-N hides the cold run)")

local cold, warm, last_path, last_line = {}, {}, nil, nil
for round = 1, opts.rounds do
	-- (B) cold: fresh gopls, first request for this package
	local c1 = start_client()
	local cms, cpath, _, cerr = request_definition()
	if not cms then
		stop_client(c1)
		fail_on(cerr, cpath)
	end
	if not cpath:find(opts.expect_mod, 1, true) then
		stop_client(c1)
		fail_on(nil, cpath)
	end
	-- (A) warm: same gopls, package already loaded
	local wms, wpath, wline, werr = request_definition()
	if not wms then
		stop_client(c1)
		fail_on(werr, wpath)
	end
	table.insert(cold, cms)
	table.insert(warm, wms)
	last_path, last_line = wpath, wline
	stop_client(c1)
end

if #cold == 0 or #warm == 0 then
	die(7, "no samples collected")
end

local function stats(label, samples)
	local sorted = vim.deepcopy(samples)
	table.sort(sorted)
	local rendered = {}
	for _, v in ipairs(samples) do
		rendered[#rendered + 1] = string.format("%.1f", v)
	end
	print("== " .. label .. " ==")
	info("samples (ms)", table.concat(rendered, " / "))
	info("median (ms)", string.format("%.1f", sorted[math.ceil(#sorted / 2)]))
	info("min / max (ms)", string.format("%.1f / %.1f", sorted[1], sorted[#sorted]))
	return sorted[math.ceil(#sorted / 2)]
end

local cmed = stats("B) gopls freshly started (cold)", cold)
local wmed = stats("A) gopls already warm", warm)
info("resolved target", string.format("%s:%d", last_path, (last_line or 0) + 1))
do
	local fh = io.open(last_path, "r")
	if fh then
		local n = 0
		for l in fh:lines() do
			n = n + 1
			if n == (last_line or 0) + 1 then
				info("declaration there", string.format("%q", vim.trim(l)))
				break
			end
		end
		fh:close()
	end
end

local delta = cmed - wmed
print("== delta ==")
info("cold - warm", string.format("%.1f ms", delta))

local REFERENCE = 5237.0
local ratio = math.abs(delta) / REFERENCE
print("== verdict ==")
info("reference (seq 123)", string.format("%.0f ms", REFERENCE))
info("delta / reference", string.format("%.3f", ratio))
if ratio >= 0.5 then
	print(string.format("VERDICT: the %.0f ms cold/warm gap is CONSISTENT with the 5237 ms reference.", delta))
else
	print(string.format("VERDICT: the %.0f ms gap does NOT account for the 5237 ms reference (%.2fx).", delta, ratio))
	print(string.format("         %.0f ms of the reference remain unexplained by package warm-up in THIS workspace.", REFERENCE - math.abs(delta)))
	print("         This neither refutes nor confirms the original observation: that one")
	print("         had a different workspace, client state and configuration.")
end
print()
print("RTT only. This run did not test root markers, background analyses or")
print("client-attach policy; those remain untested hypotheses.")
os.exit(0)
