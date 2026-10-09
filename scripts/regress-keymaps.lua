-- scripts/regress-keymaps.lua — keymap registration + collision audit.
-- Runs with the FULL config headless (-c luafile, NOT -l: mappings need
-- the real startup). Asserts: expected debug/Go/Git/Telescope/terminal
-- mappings exist with descs; no duplicate (mode,lhs) globals with
-- different targets; builtin gc comment operator untouched.
--
-- Run:  nvim --headless -c "luafile scripts/regress-keymaps.lua"
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

local function has_map(lhs, mode)
	local m = vim.fn.maparg(lhs, mode or "n", false, true)
	return type(m) == "table" and (m.rhs ~= nil or m.callback ~= nil)
end

local function desc_of(lhs, mode)
	local m = vim.fn.maparg(lhs, mode or "n", false, true)
	if type(m) == "table" then
		return m.desc or ""
	end
	return ""
end

-- Debugger controls (dev.debug setup_keymaps; needs no session to register?
-- dapmap() maps unconditionally at setup — setup runs on first debug key via
-- loader; force it here for the audit).
do
	local ok, dbg = pcall(require, "dev.debug")
	if ok and dbg.setup_keymaps then
		pcall(dbg.setup_keymaps)
	end
end

for _, lhs in ipairs({ " db", " dB", " dc", " dn", " di", " do", " dx", " dl", " dr", " de", " dw", " df", " dt", " du", " dW", " dp" }) do
	check("debug map " .. lhs, has_map(lhs, "n"))
end
check("dc desc", desc_of(" dc", "n"):find("Continue") ~= nil)
check("du desc", desc_of(" du", "n"):find("[Ii]nspector") ~= nil)

-- Go workflow (global maps; <leader>cl is buffer-local to LSP buffers —
-- checked statically below; proven live elsewhere).
for _, lhs in ipairs({ " gt", " ta", " at", " tr", " tb", " tc", " gm", " gf", " rr", " rb" }) do
	check("go map " .. lhs, has_map(lhs, "n"))
end
do
	-- Static: buffer-local LSP maps must be declared in keymap/completion.lua.
	local fh = io.open(vim.fn.stdpath("config") .. "/lua/keymap/completion.lua", "r")
	local content = fh and fh:read("*a") or ""
	if fh then
		fh:close()
	end
	for _, lhs in ipairs({ "<leader>cl", '"gd"', '"gr"', '"K"', '"ga"', '"gy"' }) do
		check("lsp map declared " .. lhs, content:find(lhs, 1, true) ~= nil)
	end
end

-- Git (global entries; buffer-local gitsigns covered by regress-gitmaps).
for _, lhs in ipairs({ " G", " gd", " gD", " gh" }) do
	check("git map " .. lhs, has_map(lhs, "n"))
end

-- Telescope / terminal / replace / project.
for _, lhs in ipairs({ " ff", " fp", " fb", " tt", " sr", " sl", " fm" }) do
	check("tool map " .. lhs, has_map(lhs, "n"))
end

-- Builtin gc comment operator must not be shadowed BY US: scan our own
-- keymap sources for a gc mapping (Neovim itself ships gc "Toggle
-- comment" by default — that one is expected and must stay working).
do
	local ours = {}
	-- Absolute config path: full-config runs may start in any CWD
	-- (Windows rendez-vous runs start in system32).
	local cfg = vim.fn.stdpath("config")
	local files = vim.fn.globpath(cfg .. "/lua/keymap", "*.lua", false, true)
	for _, f in ipairs(vim.fn.globpath(cfg .. "/lua/modules", "**/*.lua", false, true)) do
		files[#files + 1] = f
	end
	for _, f in ipairs(files) do
		local fh = io.open(f, "r")
		if fh then
			local content = fh:read("*a") or ""
			fh:close()
			if content:find([["gc"]], 1, true) then
				ours[#ours + 1] = f
			end
		end
	end
	check("gc not shadowed by distro", #ours == 0)
	if #ours > 0 then
		print("GC-SHADOW: " .. table.concat(ours, ", "))
	end
end

-- No duplicate global normal mappings with different targets.
do
	local seen, dupes = {}, {}
	for _, m in ipairs(vim.api.nvim_get_keymap("n")) do
		if m.lhs and (m.rhs or m.callback) then
			local key = m.lhs
			local target = m.rhs or ("lua:" .. tostring(m.callback):sub(1, 24))
			if seen[key] and seen[key] ~= target then
				dupes[#dupes + 1] = key
			end
			seen[key] = target
		end
	end
	check("no conflicting global dupes", #dupes == 0)
	if #dupes > 0 then
		print("DUPES: " .. table.concat(dupes, ","))
	end
end

print(string.format("total=%d failures=%d", total, failures))
if failures > 0 then
	os.exit(1)
end
