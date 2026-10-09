-- scripts/regress-gomod.lua — regression tests for dev.gomod.tidy()
-- error paths (missing go.mod, malformed module) and the success path.
--
-- Run:  nvim --headless --noplugin -u NONE \
--          --cmd "set rtp+=<repo-root>" -l scripts/regress-gomod.lua
-- Exit 0 when all cases pass, 1 otherwise. Cases needing a real `go`
-- binary are skipped (SKIP, still exit 0) when it is unavailable.
-- No network, no user config.

local failures = 0
local total = 0
local skipped = 0

local function check(desc, cond)
	total = total + 1
	if cond then
		print("OK " .. desc)
	else
		failures = failures + 1
		print("FAIL " .. desc)
	end
end

local G = require("dev.gomod")
local has_go = vim.fn.executable("go") == 1

-- Capture notify calls made by tidy().
local notices = {}
---@diagnostic disable-next-line: duplicate-set-field
vim.notify = function(msg, level)
	notices[#notices + 1] = { msg = tostring(msg), level = level }
end

local function buf_with_file(path)
	local buf = vim.api.nvim_create_buf(false, false)
	vim.api.nvim_set_current_buf(buf)
	vim.api.nvim_buf_set_name(buf, path)
	return buf
end

local function last_notice_match(pat)
	for i = #notices, 1, -1 do
		if notices[i].msg:find(pat) then
			return true
		end
	end
	return false
end

-- Case 1: no go.mod above the file (needs no `go` binary).
do
	local dir = vim.fn.tempname()
	vim.fn.mkdir(dir, "p")
	local f = dir .. "/lonely.txt"
	local fh = assert(io.open(f, "w"))
	fh:write("x")
	fh:close()
	buf_with_file(f)
	notices = {}
	G.tidy()
	check("missing go.mod warns", last_notice_match("no go.mod above"))
end

-- Case 2: malformed go.mod (needs `go`).
if not has_go then
	skipped = skipped + 1
	print("SKIP malformed go.mod reports failure (no go binary)")
else
	local dir = vim.fn.tempname()
	vim.fn.mkdir(dir, "p")
	local fh = assert(io.open(dir .. "/go.mod", "w"))
	fh:write("module example.com/bad\n\ngo 1.24\n\nrequire !!!\n")
	fh:close()
	buf_with_file(dir .. "/main.go")
	notices = {}
	G.tidy()
	vim.wait(30000, function()
		return last_notice_match("tidy FAILED")
	end, 200)
	check("malformed go.mod reports failure", last_notice_match("tidy FAILED"))
end

-- Case 3: valid module tidies clean (needs `go`).
if not has_go then
	skipped = skipped + 1
	print("SKIP valid module tidies clean (no go binary)")
else
	local dir = vim.fn.tempname()
	vim.fn.mkdir(dir, "p")
	local fh = assert(io.open(dir .. "/go.mod", "w"))
	fh:write("module example.com/fine\n\ngo 1.24\n")
	fh:close()
	buf_with_file(dir .. "/main.go")
	notices = {}
	G.tidy()
	vim.wait(60000, function()
		return last_notice_match("tidy clean")
	end, 200)
	check("valid module tidies clean", last_notice_match("tidy clean"))
end

print(string.format("total=%d failures=%d skipped=%d", total, failures, skipped))
if failures > 0 then
	os.exit(1)
end
