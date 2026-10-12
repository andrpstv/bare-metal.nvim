-- scripts/regress-pkg.lua — unit tests for dev.build package targeting.
-- Covers pkg_dir() across layouts (single module, nested package,
-- multi-package repo, nested module, go.work workspace) plus argv/cwd
-- construction for build/run with vim.system stubbed, and the missing-go
-- / non-go-buffer / unnamed-buffer error paths (notify capture).
--
-- Run:  nvim --headless --noplugin -u NONE \
--          --cmd "set rtp+=<repo-root>" -l scripts/regress-pkg.lua
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

local build = require("dev.build")

local function mktree(files)
	local root = vim.fn.tempname()
	vim.fn.mkdir(root, "p")
	for rel, content in pairs(files) do
		local p = root .. "/" .. rel
		vim.fn.mkdir(vim.fn.fnamemodify(p, ":h"), "p")
		local fh = assert(io.open(p, "w"))
		fh:write(content)
		fh:close()
	end
	return root
end

local function open_file(path)
	-- Drop any previous buffer with the same file (one -l process).
	-- Compare realpaths: set_name resolves symlinks (/tmp -> /private/tmp).
	local ok_r, want = pcall(vim.uv.fs_realpath, path)
	want = (ok_r and want) or path
	for _, b in ipairs(vim.api.nvim_list_bufs()) do
		local ok_n, have = pcall(vim.uv.fs_realpath, vim.api.nvim_buf_get_name(b))
		if have and (ok_n and have or vim.api.nvim_buf_get_name(b)) == want then
			pcall(vim.api.nvim_buf_delete, b, { force = true })
		end
	end
	local buf = vim.api.nvim_create_buf(false, false)
	vim.api.nvim_set_current_buf(buf)
	vim.api.nvim_buf_set_name(buf, path)
	vim.bo[buf].filetype = "go"
	return buf
end

-- NOTE: nvim_buf_set_name resolves symlinks (/tmp -> /private/tmp), so
-- expectations derive from the buffer's own resolved name, not from the
-- pre-image path string.
local function bufdir(buf)
	return vim.fn.fnamemodify(vim.api.nvim_buf_get_name(buf), ":p:h")
end

-- Fixture: single module + nested pkg + second pkg + nested module + workspace.
local root = mktree({
	["go.mod"] = "module example.com/mono\n\ngo 1.24\n",
	["main.go"] = "package main\n\nfunc main() {}\n",
	["inner/inner.go"] = "package inner\n",
	["other/other.go"] = "package other\n",
	["nested/go.mod"] = "module example.com/nested\n\ngo 1.24\n",
	["nested/n.go"] = "package nested\n",
	["go.work"] = "go 1.24\n\nuse .\nuse ./nested\n",
})

-- pkg_dir: nested package resolves to its own dir.
do
	local buf = open_file(root .. "/inner/inner.go")
	local dir = build.pkg_dir(buf)
	check("nested pkg dir", dir == bufdir(buf) and dir:find("inner$") ~= nil)
end
-- pkg_dir: top-level file resolves to module root dir.
do
	local buf = open_file(root .. "/main.go")
	local dir = build.pkg_dir(buf)
	check("root pkg dir", dir == bufdir(buf))
end
-- pkg_dir: nested module member resolves inside the nested module.
do
	local buf = open_file(root .. "/nested/n.go")
	local dir = build.pkg_dir(buf)
	check("nested module dir", dir == bufdir(buf) and dir:find("nested$") ~= nil)
end
-- pkg_dir: workspace member resolves to its own dir (go tooling walks
-- up to the member go.mod; go.work needs no special handling here).
do
	local wroot = mktree({
		["go.work"] = "go 1.24\n\nuse ./m1\nuse ./m2\n",
		["m1/go.mod"] = "module example.com/m1\n\ngo 1.24\n",
		["m1/a.go"] = "package m1\n",
		["m2/go.mod"] = "module example.com/m2\n\ngo 1.24\n",
		["m2/sub/b.go"] = "package sub\n",
	})
	local buf = open_file(wroot .. "/m2/sub/b.go")
	local dir = build.pkg_dir(buf)
	check("workspace member dir", dir == bufdir(buf) and dir:find("sub$") ~= nil)
end
-- pkg_dir: unnamed buffer errors cleanly.
do
	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_set_current_buf(buf)
	local dir, err = build.pkg_dir(buf)
	check("unnamed buffer errors", dir == nil and err ~= nil)
end

-- argv/cwd construction with vim.system stubbed (no real go run).
local real_system = vim.system
local calls = {}
---@diagnostic disable-next-line: duplicate-set-field
vim.system = function(argv, opts, cb)
	calls[#calls + 1] = { argv = argv, cwd = opts and opts.cwd }
	cb({ code = 0, stdout = "", stderr = "" })
	return nil
end
local function last_call()
	return calls[#calls]
end

do
	calls = {}
	local buf = open_file(root .. "/inner/inner.go")
	local exp = bufdir(buf)
	build.build()
	local c = last_call()
	check("build argv", c and c.argv[1] == "go" and c.argv[2] == "build" and c.argv[3] == ".")
	check("build cwd is package dir", c and c.cwd == exp)
end
do
	calls = {}
	local buf = open_file(root .. "/other/other.go")
	local exp = bufdir(buf)
	build.run()
	local c = last_call()
	check("run argv", c and c.argv[1] == "go" and c.argv[2] == "run" and c.argv[3] == ".")
	check("run cwd is package dir", c and c.cwd == exp)
end

-- Failure diagnostics: go build error lines land in quickfix.
do
	calls = {}
	open_file(root .. "/main.go")
	---@diagnostic disable-next-line: duplicate-set-field
	vim.system = function(argv, opts, cb)
		cb({ code = 1, stdout = "", stderr = "main.go:3: undefined: wat\n" })
		return nil
	end
	build.build()
	-- execute() completes via vim.schedule: pump the loop first.
	vim.wait(5000, function()
		return #vim.fn.getqflist() > 0
	end, 50)
	local qf = vim.fn.getqflist()
	local found = false
	for _, it in ipairs(qf) do
		if it.lnum == 3 then
			found = true
		end
	end
	check("build failure to quickfix", found)
	check("build failure notified", (function()
		for _, m in ipairs(notices) do
			if m:find("FAILED") then
				return true
			end
		end
		return false
	end)())
end

-- Module check (agent workflow phase 5): steps, cwd, chain break, columns.
local has_lint = vim.fn.executable("golangci-lint") == 1
local function run_check(reply)
	calls, notices = {}, {}
	vim.fn.setqflist({}, " ")
	---@diagnostic disable-next-line: duplicate-set-field
	vim.system = function(argv, opts, cb)
		calls[#calls + 1] = { argv = argv, cwd = opts and opts.cwd }
		cb(reply(argv))
		return nil
	end
	build.check()
	vim.wait(3000, function()
		for _, m in ipairs(notices) do
			if m:find("check clean") or m:find("issue%(s%)") then
				return true
			end
		end
		return false
	end, 20)
end
do
	local buf = open_file(root .. "/inner/inner.go")
	local mod = vim.fn.fnamemodify(bufdir(buf), ":h") -- inner/ has no go.mod -> module root
	run_check(function()
		return { code = 0, stdout = "", stderr = "" }
	end)
	check("check: build ./... first, output discarded", calls[1] and calls[1].argv[2] == "build" and calls[1].argv[3] == "-o" and calls[1].argv[5] == "./...")
	check("check: vet ./... second", calls[2] and calls[2].argv[2] == "vet" and calls[2].argv[3] == "./...")
	check("check: lint only when installed", #calls == (has_lint and 3 or 2))
	check("check: cwd is module root", calls[1] and calls[1].cwd == mod)
	check("check: clean notified", (function()
		for _, m in ipairs(notices) do
			if m:find("check clean") then
				return true
			end
		end
		return false
	end)())

	run_check(function(argv)
		if argv[2] == "build" then
			return { code = 1, stdout = "", stderr = "# example.com/mono\n./main.go:3:9: undefined: wat\n" }
		end
		return { code = 0, stdout = "", stderr = "" }
	end)
	local qf = vim.fn.getqflist()
	check("check: broken build stops the chain", #calls == 1)
	check("check: build error with column", qf[1] and qf[1].lnum == 3 and qf[1].col == 9 and qf[1].text == "[build] undefined: wat")

	run_check(function(argv)
		if argv[2] == "vet" then
			return { code = 1, stdout = "", stderr = "# example.com/mono\n./main.go:3:2: fmt.Printf format %d has arg s of wrong type string\n" }
		end
		return { code = 0, stdout = "", stderr = "" }
	end)
	qf = vim.fn.getqflist()
	check("check: vet issue tagged", qf[1] and qf[1].text:find("^%[vet%] fmt.Printf") ~= nil and qf[1].col == 2)
	check("check: vet issue notified", (function()
		for _, m in ipairs(notices) do
			if m:find("1 issue%(s%) — vet failed") then
				return true
			end
		end
		return false
	end)())

	run_check(function(argv)
		if argv[2] == "build" then
			return { code = 1, stdout = "", stderr = "go: cannot find main module\n" }
		end
		return { code = 0, stdout = "", stderr = "" }
	end)
	check("check: failure without file lines explains itself", (function()
		for _, m in ipairs(notices) do
			if m:find("build failed: go: cannot find main module", 1, true) then
				return true
			end
		end
		return false
	end)())
end
vim.system = real_system

-- Real `go vet` (lint hidden via PATH so the run stays fast and deterministic).
if vim.fn.executable("go") == 1 then
	local real_path = vim.env.PATH
	vim.env.PATH = vim.fn.fnamemodify(vim.fn.exepath("go"), ":h") .. ":/usr/bin:/bin"
	local vroot = mktree({
		["go.mod"] = "module example.com/vetme\n\ngo 1.22\n",
		["main.go"] = 'package main\n\nimport "fmt"\n\nfunc main() {\n\tfmt.Printf("%d\\n", "s")\n}\n',
	})
	open_file(vroot .. "/main.go")
	notices = {}
	vim.fn.setqflist({}, " ")
	build.check()
	vim.wait(60000, function()
		for _, m in ipairs(notices) do
			if m:find("check clean") or m:find("issue%(s%)") then
				return true
			end
		end
		return false
	end, 100)
	local qf = vim.fn.getqflist()
	check("real go vet: Printf issue in quickfix at line 6", qf[1] ~= nil and qf[1].lnum == 6 and qf[1].text:find("^%[vet%]") ~= nil)
	check("real go build leaves no binary in the module", vim.uv.fs_stat(vroot .. "/vetme") == nil)
	vim.env.PATH = real_path
else
	print("SKIP real go vet (no go)")
end

-- Non-go buffer refused with guidance.
do
	notices = {}
	local buf = vim.api.nvim_create_buf(false, false)
	vim.api.nvim_set_current_buf(buf)
	vim.api.nvim_buf_set_name(buf, root .. "/notes.txt")
	vim.bo[buf].filetype = "text"
	build.build()
	check("non-go refused", (function()
		for _, m in ipairs(notices) do
			if m:find("Go buffers only") then
				return true
			end
		end
		return false
	end)())
end

print(string.format("total=%d failures=%d", total, failures))
if failures > 0 then
	os.exit(1)
end
