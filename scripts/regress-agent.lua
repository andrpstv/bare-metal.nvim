-- scripts/regress-agent.lua — dev.agent review session (agent workflow phase 3).
-- Pure parser cases for `git diff -U0` plus a real temp git repo: the base
-- excludes the user's pre-session edits, the tree/index/stash stay untouched,
-- quickfix lists only post-start hunks + new files, gitsigns base is set and
-- restored. distro.loader and gitsigns are stubbed (no plugins under -u NONE).
--
-- Run:  nvim --headless --noplugin -u NONE \
--          --cmd "set rtp+=<repo-root>" -l scripts/regress-agent.lua
-- Exit 0 when all cases pass, 1 otherwise. Git cases SKIP without git.
-- No network, no user config.

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
	notices[#notices + 1] = { msg = tostring(msg), level = level }
end
local function noticed(pat)
	for _, n in ipairs(notices) do
		if n.msg:find(pat) then
			return true
		end
	end
	return false
end

local bases = {}
package.loaded["distro.loader"] = {
	load = function()
		return true
	end,
}
package.loaded["gitsigns"] = {
	change_base = function(base, global)
		bases[#bases + 1] = { base = base, global = global }
	end,
}

local A = require("dev.agent")

-- Parser ----------------------------------------------------------------------
do
	local out = table.concat({
		"diff --git a/a.go b/a.go",
		"index 1..2 100644",
		"--- a/a.go",
		"+++ b/a.go",
		"@@ -3 +3 @@ func x() {",
		"-\told()",
		"+\tnew()",
		"@@ -10,0 +11,2 @@",
		"+++ b/not-a-header",
		"+second",
		"@@ -20,2 +21,0 @@",
		"-gone1",
		"--- a/not-a-header-either",
		"diff --git a/dir with space/b.txt b/dir with space/b.txt",
		"--- a/dir with space/b.txt",
		"+++ b/dir with space/b.txt",
		"@@ -0,0 +1 @@",
		"+first line",
		"\\ No newline at end of file",
		"diff --git a/old.go b/old.go",
		"deleted file mode 100644",
		"--- a/old.go",
		"+++ /dev/null",
		"@@ -1,2 +0,0 @@",
		"-x",
		"-y",
		"diff --git a/img.png b/img.png",
		"Binary files a/img.png and b/img.png differ",
		"",
	}, "\n")
	local it = A._parse_diff(out, "/r")
	check("parser: 6 items", #it == 6)
	check("changed hunk at new line 3 with hint", it[1] and it[1].lnum == 3 and it[1].text == "changed (-1 +1): new()")
	check("added hunk, '+++ ' content not taken as header", it[2] and it[2].lnum == 11 and it[2].text == "added (-0 +2): ++ b/not-a-header")
	check("removed hunk, '--- ' content not taken as header", it[3] and it[3].lnum == 21 and it[3].text == "removed (-2 +0)")
	check("path with spaces", it[4] and it[4].filename == "/r/dir with space/b.txt" and it[4].lnum == 1)
	check("deleted file reported once", it[5] and it[5].filename == "/r/old.go" and it[5].text == "deleted file")
	check("binary file", it[6] and it[6].filename == "/r/img.png" and it[6].text == "binary file changed")
	check("empty diff -> no items", #A._parse_diff("", "/r") == 0)
end

-- Real git ----------------------------------------------------------------------
if vim.fn.executable("git") ~= 1 then
	print("SKIP git cases (no git)")
else
	local function sh(dir, ...)
		local r = vim.system(vim.list_extend({ "git", "-C", dir, "-c", "user.email=t@t", "-c", "user.name=t" }, { ... }), { text = true }):wait()
		return r.code == 0, vim.trim(r.stdout or "")
	end
	local function write(path, lines)
		vim.fn.writefile(lines, path)
	end
	local function in_repo(dir)
		local buf = vim.api.nvim_create_buf(true, false)
		vim.api.nvim_set_current_buf(buf)
		vim.api.nvim_buf_set_name(buf, dir .. "/a.txt")
	end

	-- Not a repo: quiet autostart says nothing, explicit start warns.
	do
		local dir = vim.fn.tempname()
		vim.fn.mkdir(dir, "p")
		-- No project marker -> dev.project falls back to cwd: make cwd non-git too.
		vim.cmd.cd(dir)
		in_repo(dir)
		notices = {}
		A.session = nil
		A.ensure()
		vim.wait(1500, function()
			return false
		end, 50)
		check("ensure() outside git: no session, silent", A.session == nil and #notices == 0)
		A.start()
		vim.wait(1500, function()
			return noticed("not a git repository")
		end)
		check("start() outside git warns", noticed("not a git repository"))
	end

	-- Repo without commits.
	do
		local dir = vim.fn.tempname()
		vim.fn.mkdir(dir, "p")
		sh(dir, "init", "-q")
		in_repo(dir)
		notices = {}
		A.start()
		vim.wait(2000, function()
			return noticed("no commits")
		end)
		check("repo without commits: explained, no session", noticed("no commits") and A.session == nil)
	end

	-- Full cycle.
	local dir = vim.fs.normalize(vim.uv.fs_realpath(vim.fn.tempname()) or vim.fn.tempname())
	vim.fn.mkdir(dir, "p")
	dir = vim.fs.normalize(vim.uv.fs_realpath(dir))
	sh(dir, "init", "-q")
	write(dir .. "/a.txt", { "l1", "l2", "l3", "l4", "l5" })
	write(dir .. "/pre.txt", { "untracked before start" })
	sh(dir, "add", "a.txt")
	sh(dir, "commit", "-qm", "init")
	write(dir .. "/a.txt", { "l1", "USER", "l3", "l4", "l5" }) -- user's own edit before the session
	in_repo(dir)
	local _, status_before = sh(dir, "status", "--porcelain")
	notices, bases = {}, {}
	A.session = nil
	A.start()
	vim.wait(3000, function()
		return A.session ~= nil
	end)
	local s = A.session
	local _, head = sh(dir, "rev-parse", "HEAD")
	check("session started", s ~= nil and noticed("review session started"))
	check("base is a snapshot, not HEAD (user edit included)", s and #s.base == 40 and s.base ~= head)
	check("session root is the repo", s and s.root == dir)
	local _, status_after = sh(dir, "status", "--porcelain")
	local _, stashes = sh(dir, "stash", "list")
	check("working tree untouched by start", status_after == status_before)
	check("stash list untouched", stashes == "")
	check("gitsigns base set globally", bases[1] and bases[1].base == (s and s.base) and bases[1].global == true)

	-- "Agent" edits: line 4 changed, new file created.
	write(dir .. "/a.txt", { "l1", "USER", "l3", "AGENT", "l5" })
	write(dir .. "/new.txt", { "by agent" })
	vim.fn.setqflist({}, " ")
	A.quickfix()
	vim.wait(3000, function()
		return #vim.fn.getqflist() > 0
	end)
	local qf = vim.fn.getqflist()
	local names = {}
	for _, it in ipairs(qf) do
		names[#names + 1] = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(it.bufnr), ":t") .. ":" .. it.lnum .. ":" .. it.text
	end
	check("quickfix: exactly agent hunk + new file (" .. table.concat(names, " | ") .. ")", #qf == 2)
	check("hunk is line 4 only (user's line 2 excluded)", names[1] == "a.txt:4:changed (-1 +1): AGENT")
	check("new file listed, pre-existing untracked not", names[2] == "new.txt:1:new file")
	check("quickfix title names the base", vim.fn.getqflist({ title = 1 }).title:find("agent: changes since", 1, true) ~= nil)

	-- Reset from the quickfix window (current buffer is not a project file).
	check("reset is triggered from the quickfix window", vim.bo.buftype == "quickfix")
	notices = {}
	A.start()
	vim.wait(3000, function()
		return noticed("base reset")
	end)
	check("start() again resets the base", noticed("base reset") and A.session.base ~= s.base)
	vim.fn.setqflist({}, " ")
	notices = {}
	A.quickfix()
	vim.wait(3000, function()
		return noticed("no changes")
	end)
	check("after reset: no changes reported", noticed("no changes since the session started"))

	-- Stop restores gitsigns base.
	bases = {}
	A.stop()
	check("stop clears session", A.session == nil)
	check("stop restores gitsigns base (nil, global)", bases[1] and bases[1].base == nil and bases[1].global == true)
	notices = {}
	A.quickfix()
	check("quickfix without session explains how to start", noticed("<leader>Ab starts one"))
end

print(string.format("total=%d failures=%d", total, failures))
if failures > 0 then
	os.exit(1)
end
