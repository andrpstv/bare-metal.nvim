-- scripts/regress-select.lua — unit tests for the native vim.ui
-- select/input provider (lua/core/select.lua). Headless-safe: floats
-- exist API-wise; keys driven via feedkeys; callbacks pumped.
--
-- Run:  nvim --headless --noplugin -u NONE \
--          --cmd "set rtp+=<repo-root>" -l scripts/regress-select.lua
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

local sel = require("core.select")
sel.setup()
check("setup installs select", vim.ui.select ~= nil)
check("setup installs input", vim.ui.input ~= nil)

local function press(keys)
	-- "x" (flush+execute) обязателен, иначе клавиши висят в typeahead.
	-- НО: "mx!" виснет, если клавиши уводят в insert в minimal-headless,
	-- поэтому ввод текста идёт отдельно через флаг "i" (см. input-тесты).
	vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), "mx!", false)
end

local function wins()
	return #vim.api.nvim_list_wins()
end

local function settled()
	vim.wait(3000, function()
		return false
	end, 50)
end

-- select: choose second item via j + CR.
do
	local base = wins()
	local got, goti, ncalls = nil, nil, 0
	vim.ui.select({ "alpha", "beta", "gamma" }, { prompt = "Pick:" }, function(item, idx)
		ncalls = ncalls + 1
		got, goti = item, idx
	end)
	press("j<CR>")
	settled()
	check("select j+CR value", got == "beta" and goti == 2)
	check("select callback once", ncalls == 1)
	check("select window closed", wins() == base)
end

-- select: digit shortcut.
do
	local got = nil
	vim.ui.select({ "a", "b", "c" }, {}, function(item)
		got = item
	end)
	press("3")
	settled()
	check("select digit", got == "c")
end

-- select: Esc cancels with nil.
do
	local ncalls, got = 0, "unset"
	vim.ui.select({ "a", "b" }, {}, function(item)
		ncalls = ncalls + 1
		got = item
	end)
	press("<Esc>")
	settled()
	check("select cancel nil", got == nil and ncalls == 1)
end

-- select: empty list calls back nil immediately, no UI left.
do
	local base = wins()
	local ncalls, got = 0, "unset"
	vim.ui.select({}, {}, function(item)
		ncalls = ncalls + 1
		got = item
	end)
	settled()
	check("select empty nil", got == nil and ncalls == 1)
	check("select empty no window", wins() == base)
end

-- input: prefill + append + CR. Appending done via buffer API (what
-- typed keys produce); headless -l cannot enter insert mode, and real
-- typing is Vim's own machinery, already covered by live TUI flows.
do
	local got, ncalls = "unset", 0
	vim.ui.input({ prompt = "Name: ", default = "ab" }, function(text)
		ncalls = ncalls + 1
		got = text
	end)
	local st = require("core.select")._test_active()
	check("input prefill", st and st.lines[1] == "ab")
	vim.api.nvim_buf_set_lines(st.buf, 0, -1, false, { "abc" })
	press("<CR>")
	settled()
	check("input append+confirm", got == "abc")
	check("input callback once", ncalls == 1)
end

-- input: Esc cancels with nil.
do
	local ncalls, got = 0, "unset"
	vim.ui.input({ prompt = "X: ", default = "zz" }, function(text)
		ncalls = ncalls + 1
		got = text
	end)
	press("<Esc>")
	settled()
	check("input cancel nil", got == nil and ncalls == 1)
end

-- input: empty confirm yields "" (distinct from cancelled nil).
do
	local got = "unset"
	vim.ui.input({ prompt = "Y: " }, function(text)
		got = text
	end)
	press("<CR>")
	settled()
	check("input empty string", got == "")
end

-- focus restoration: select opened from a known window returns there.
do
	local prev = vim.api.nvim_get_current_win()
	vim.ui.select({ "a" }, {}, function() end)
	press("<Esc>")
	settled()
	check("focus restored", vim.api.nvim_get_current_win() == prev)
end

-- single-slot: second prompt replaces the first; first caller cancelled.
do
	local first, second = "unset", "unset"
	vim.ui.select({ "a", "b" }, {}, function(item)
		first = item
	end)
	vim.ui.select({ "x" }, {}, function(item)
		second = item
	end)
	press("<CR>")
	settled()
	check("second wins", second == "x")
	check("first cancelled", first == nil)
end

print(string.format("total=%d failures=%d", total, failures))
if failures > 0 then
	os.exit(1)
end
