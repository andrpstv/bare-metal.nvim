-- scripts/regress-gitmaps.lua — gitsigns buffer-local mappings.
-- Full config headless (-c luafile): temp git repo + committed file,
-- modify a line, assert gitsigns attaches (buffer maps ]g/[g appear);
-- non-git scratch file asserts no maps and no errors.
--
-- Run:  nvim --headless -c "luafile scripts/regress-gitmaps.lua"
--   (from the repo root; uses the repo as its own config)
-- Exit 0 when all cases pass, 1 otherwise. No network.

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

local function has_bmap(lhs)
	local m = vim.fn.maparg(lhs, "n", false, true)
	return type(m) == "table" and m.buffer == 1 and (m.rhs ~= nil or m.callback ~= nil)
end

local function shell(cmd)
	local ok = os.execute(cmd)
	return ok == true or ok == 0
end

-- Temp git repo with one committed file.
local root = vim.fn.tempname()
vim.fn.mkdir(root, "p")
local f = root .. "/tracked.txt"
local fh = assert(io.open(f, "w"))
fh:write("one\ntwo\nthree\n")
fh:close()
local null = vim.uv.os_uname().sysname == "Windows_NT" and "NUL" or "/dev/null"
-- NOTE: quote with double quotes for cmd.exe: the distro sets shell=
-- powershell, so shellescape() emits PowerShell single-quotes, but
-- os.execute() always runs through COMSPEC (cmd) which chokes on them.
local function git(args)
	return shell('git -C "' .. root .. '" ' .. args .. " 2>" .. null)
end
local setup_ok = git("init -q") and git("add tracked.txt") and git("-c user.email=t@t -c user.name=t commit -qm init")
check("fixture repo ready", setup_ok)

if setup_ok then
	vim.cmd("edit " .. vim.fn.fnameescape(f))
	-- Modify a line so there is a hunk to navigate.
	vim.api.nvim_buf_set_lines(0, 2, 3, false, { "TWO" })
	local ok_gs, gs = pcall(require, "gitsigns")
	local hunks_ready = false
	if ok_gs and gs.get_hunks then
		hunks_ready = vim.wait(30000, function()
			local h = gs.get_hunks()
			return h ~= nil and #h > 0
		end, 200)
	end
	check("gitsigns computes hunks", hunks_ready)
	local attached = has_bmap("]g") and has_bmap("[g")
	check("gitsigns hunk maps present", attached)
	if attached and hunks_ready then
		vim.api.nvim_win_set_cursor(0, { 1, 0 })
		vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("]g", true, false, true), "mx!", false)
		vim.wait(5000, function()
			return vim.api.nvim_win_get_cursor(0)[1] == 3
		end, 100)
		check("hunk jump lands on hunk", vim.api.nvim_win_get_cursor(0)[1] == 3)
	end
	vim.cmd("bwipeout!")
end

-- Non-git scratch: no gitsigns maps, no errors.
do
	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_set_current_buf(buf)
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "scratch" })
	vim.bo[buf].filetype = "text"
	vim.wait(3000)
	check("no gitsigns maps outside repo", not has_bmap("]g"))
	vim.cmd("bwipeout!")
end

print(string.format("total=%d failures=%d", total, failures))
if failures > 0 then
	os.exit(1)
end
