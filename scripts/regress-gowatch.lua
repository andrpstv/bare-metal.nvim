-- scripts/regress-gowatch.lua — gopls must keep file watching enabled.
-- Regression for the stale-diagnostic incident: an earlier workaround
-- advertised workspace.didChangeWatchedFiles.dynamicRegistration=false,
-- which stopped gopls learning about go.mod/go.sum changes, so after
-- `go get` the "could not import" diagnostic persisted until the user
-- touched a buffer (verified 2026-10-10: stale 40s+ with the opt-out,
-- auto-cleared with default caps, no ENOENT noise on nvim 0.12 + gopls
-- 0.22). The preset must not reintroduce the opt-out.
--
-- Run:  nvim --headless --noplugin -u NONE \
--          --cmd "set rtp+=<repo-root>" -l scripts/regress-gowatch.lua
-- Exit 0 when all cases pass, 1 otherwise. No network, no gopls spawn.

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

local _repo = vim.fn.stdpath("config")
package.path = _repo .. "/lua/modules/configs/?.lua;" .. _repo .. "/lua/modules/configs/?/init.lua;" .. package.path

local ok, preset = pcall(require, "completion.servers.gopls")
check("gopls preset loads without error", ok and type(preset) == "table")
if not ok then
	print("LOAD-ERR: " .. tostring(preset):sub(1, 160))
	print(string.format("total=%d failures=%d", total, failures))
	os.exit(1)
end

local caps = preset.capabilities or {}
local watched = vim.tbl_get(caps, "workspace", "didChangeWatchedFiles", "dynamicRegistration")
check("no didChangeWatchedFiles opt-out (nil or true)", watched ~= false)

-- Spot-check the preset still carries what the distro relies on.
check("gopls cmd intact", preset.cmd and preset.cmd[1] == "gopls")
check("go filetypes intact", vim.tbl_contains(preset.filetypes or {}, "go"))
check(
	"completion capabilities intact",
	vim.tbl_get(caps, "textDocument", "completion", "completionItem", "snippetSupport") == true
)

-- Static guard: the opt-out must not reappear anywhere in the preset source.
local src = table.concat(vim.fn.readfile(_repo .. "/lua/modules/configs/completion/servers/gopls.lua"), "\n")
check(
	"no dynamicRegistration=false in preset source",
	not src:find("dynamicRegistration%s*=%s*false")
)

print(string.format("total=%d failures=%d", total, failures))
if failures > 0 then
	os.exit(1)
end
