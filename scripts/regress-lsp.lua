-- scripts/regress-lsp.lua — optional LSP dependency policy.
-- Loads the real completion.lsp setup headless with notify capture and
-- asserts: missing bashls/lua_ls are reported as OPTIONAL with an
-- install hint (never silent, never an error); a missing gopls is NOT
-- marked optional; no secrets leak into the messages; startup proceeds.
--
-- Run:  nvim --headless --noplugin -u NONE \
--          --cmd "set rtp+=<repo-root>" -l scripts/regress-lsp.lua
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
	notices[#notices + 1] = { msg = tostring(msg), level = level }
end

local function msgs_for(name)
	local out = {}
	for _, n in ipairs(notices) do
		if n.msg:find("[" .. name .. "]", 1, true) then
			out[#out + 1] = n
		end
	end
	return out
end

-- Real setup path (registers servers for present binaries, warns for
-- missing ones). Safe headless: no buffer -> no server spawn.
-- NOTE: "completion.*" lives under lua/modules/configs (loader path);
-- mirror that here since -l skips the loader. stdpath("config") works
-- in -l mode too and points at the repo locally / deployed config remotely.
local _repo = vim.fn.stdpath("config")
package.path = _repo .. "/lua/modules/configs/?.lua;" .. _repo .. "/lua/modules/configs/?/init.lua;" .. package.path
local ok, mod = pcall(require, "completion.lsp")
check("lsp setup loads without error", ok and type(mod) == "function")
if not ok then
	print("LOAD-ERR: " .. tostring(mod):sub(1, 160))
else
	-- The module returns the setup function (distro.loader calls it with
	-- no args); calling it runs the real binary-presence path.
	local ok_call, call_err = pcall(mod)
	check("lsp setup runs without error", ok_call)
	if not ok_call then
		print("CALL-ERR: " .. tostring(call_err):sub(1, 200))
	end
end

for _, name in ipairs({ "bashls", "lua_ls" }) do
	local bin = name == "bashls" and "bash-language-server" or "lua-language-server"
	if vim.fn.executable(bin) == 1 then
		print("SKIP " .. name .. " present on this machine")
	else
		local ms = msgs_for(name)
		check(name .. " missing reported", #ms >= 1)
		local optional = false
		for _, m in ipairs(ms) do
			if m.msg:find("optional", 1, true) then
				optional = true
			end
		end
		check(name .. " marked optional", optional)
		local hinted = false
		for _, m in ipairs(ms) do
			if m.msg:find("DistroBinaries", 1, true) or m.msg:find("npm", 1, true) then
				hinted = true
			end
		end
		check(name .. " install hinted", hinted)
	end
end

-- gopls missing must NOT be called optional (Go is the primary workflow).
if vim.fn.executable("gopls") ~= 1 then
	local ms = msgs_for("gopls")
	check("gopls missing reported", #ms >= 1)
	local optional = false
	for _, m in ipairs(ms) do
		if m.msg:find("optional", 1, true) then
			optional = true
		end
	end
	check("gopls not marked optional", not optional)
else
	print("SKIP gopls present on this machine")
end

-- No secrets in any captured message (paths/usernames in PATH are fine;
-- credentials patterns are not).
do
	local bad = false
	for _, n in ipairs(notices) do
		if n.msg:find("://[^@]*@", 1) or n.msg:find("[Tt]oken[:=]%S") then
			bad = true
			print("LEAK: " .. n.msg:sub(1, 120))
		end
	end
	check("no credential patterns in messages", not bad)
end

print(string.format("total=%d failures=%d", total, failures))
if failures > 0 then
	os.exit(1)
end
