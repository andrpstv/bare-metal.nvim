-- scripts/regress-sidekick.lua — sidekick.nvim integration (agent workflow phase 2).
-- Full config headless (-c luafile): manifest pin, loader + config, NES stays
-- unloaded, distro overrides applied, and <leader>As in x-mode reaches
-- sidekick while visual mode is still active (otherwise only the cursor
-- position is sent — the phase-0 finding). cli.send is stubbed: starting a
-- real agent CLI is TUI-only and NOT claimed here.
--
-- Run:  nvim --headless -c "luafile scripts/regress-sidekick.lua"
--   (from the repo root; uses the repo as its own config)
-- Exit 0 when all cases pass, 1 otherwise. No network, no agent process.

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

local manifest = require("distro.manifest")
local entry = manifest.get("sidekick.nvim")
check("manifest pins sidekick.nvim", entry ~= nil and #(entry.ref or "") == 40)
check("no startup trigger (cmd only)", entry ~= nil and entry.event == nil and entry.ft == nil and entry.kind == "opt")
check("not loaded at startup", package.loaded["sidekick"] == nil)

local ok_load = require("distro.loader").load("sidekick.nvim")
check("loader loads sidekick", ok_load == true)
check(":Sidekick command exists", vim.fn.exists(":Sidekick") == 2)

-- setup() finishes its work in vim.schedule.
vim.wait(100)
local Config = require("sidekick.config")
check("NES disabled", Config.nes.enabled == false)
check("NES module not loaded", package.loaded["sidekick.nes"] == nil)
check("sidekick watcher off (core.external owns reloads)", Config.cli.watch == false)
check("split width is a screen share", Config.cli.win.split.width == 0.4)
check("picker keys disabled", Config.cli.win.keys.files == false and Config.cli.win.keys.buffers == false)

-- x-mode send: capture what sidekick would see at call time.
local seen = {}
local cli = require("sidekick.cli")
cli.send = function(opts)
	seen = { msg = opts and opts.msg, mode = vim.fn.mode() }
end
local buf = vim.api.nvim_create_buf(true, false)
vim.api.nvim_set_current_buf(buf)
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "a", "b", "c" })
vim.api.nvim_feedkeys(vim.keycode("Vj<Space>As"), "x", false)
check("x-mode <leader>As sends {this}", seen.msg == "{this}")
check("x-mode <leader>As runs while still in visual mode", seen.mode == "V")
seen = {}
vim.api.nvim_feedkeys(vim.keycode("<Esc>Vj<Space>Av"), "x", false)
check("x-mode <leader>Av quotes ref + text", seen.msg == "{this}\n{selection}")
vim.api.nvim_feedkeys(vim.keycode("<Esc>"), "x", false)

-- Statusline segment of the review session (dev.agent, phase 4).
check("statusline: no agent segment without dev.agent", not (_G._statusline() or ""):find("agent:", 1, true))
local agent = require("dev.agent")
agent.session, agent.changed = { root = "/x", base = string.rep("0", 40), untracked = {} }, 3
check("statusline: agent segment with a session", (_G._statusline() or ""):find("agent:3", 1, true) ~= nil)
agent.session, agent.changed = nil, nil
check("statusline: segment gone after session", not (_G._statusline() or ""):find("agent:", 1, true))

print(string.format("total=%d failures=%d", total, failures))
if failures > 0 then
	os.exit(1)
end
