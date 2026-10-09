-- scripts/regress-gitui.lua — Neogit/Diffview availability and loading.
-- Full config headless (-c luafile): manifest pins exist, loader can
-- load both plugins without error, user commands register. Opening full
-- UIs is TUI-only and explicitly NOT claimed here (see TUI validation).
--
-- Run:  nvim --headless -c "luafile scripts/regress-gitui.lua"
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

-- Manifest pins present (static, deterministic).
local function manifest_has(name)
	local fh = io.open(vim.fn.stdpath("config") .. "/lua/distro/manifest.lua", "r")
	if not fh then
		return false
	end
	local content = fh:read("*a") or ""
	fh:close()
	return content:find('name = "' .. name .. '"', 1, true) ~= nil
end

check("manifest pins neogit", manifest_has("neogit"))
check("manifest pins diffview", manifest_has("diffview.nvim"))

-- Loader can load both without error.
do
	local ok_loader, loader = pcall(require, "distro.loader")
	check("loader available", ok_loader and loader ~= nil)
	if ok_loader then
		local ok_neo = pcall(loader.load, "neogit")
		check("neogit loads", ok_neo)
		local ok_dv = pcall(loader.load, "diffview.nvim")
		check("diffview loads", ok_dv)
	end
end

-- User commands registered after load.
check("Neogit command exists", vim.fn.exists(":Neogit") == 2)
check("DiffviewOpen exists", vim.fn.exists(":DiffviewOpen") == 2)
check("DiffviewClose exists", vim.fn.exists(":DiffviewClose") == 2)

print(string.format("total=%d failures=%d", total, failures))
if failures > 0 then
	os.exit(1)
end
