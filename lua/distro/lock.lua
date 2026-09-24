-- distroManager lock — pure JSON I/O + status. No network, no notify spam.
-- Lock file: <config>/distro-lock.json (replaces lazy-lock.json).

local M = {}

function M.path()
	return vim.fn.stdpath("config") .. "/distro-lock.json"
end

function M.read()
	local p = M.path()
	local f = io.open(p, "r")
	if not f then
		return {}
	end
	local raw = f:read("*a")
	f:close()
	local ok, data = pcall(vim.json.decode, raw)
	if not ok or type(data) ~= "table" then
		return {}, "invalid"
	end
	return data
end

function M.write(tbl)
	local p = M.path()
	local bak = p .. ".bak"
	-- keep one backup before overwrite
	local old = io.open(p, "r")
	if old then
		local raw = old:read("*a")
		old:close()
		local b = io.open(bak, "w")
		if b then
			b:write(raw)
			b:close()
		end
	end
	local f = io.open(p, "w")
	if not f then
		return false, "Cannot write to " .. p .. " (permission denied). Check ownership. No changes made."
	end
	f:write(vim.json.encode(tbl))
	f:close()
	return true
end

--- Record one install/update. Sets previous_ref automatically.
---@param name string @"gitsigns.nvim" | "tools/gcc" | "parsers/go"
---@param info table @{repo,ref,tarball,kind,size_kb}
function M.record(name, info)
	local lock = M.read()
	local prev = lock[name]
	info = vim.tbl_extend("force", {
		installed_at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
		previous_ref = prev and prev.ref or vim.NIL,
	}, info)
	lock[name] = info
	local ok, err = M.write(lock)
	return ok, err
end

local function dir_exists(path)
	return vim.uv.fs_stat(path) ~= nil
end

local function sentinel_ok(dir)
	return vim.uv.fs_stat(dir .. "/.distro-ok") ~= nil
end

--- Fast local status. Never touches network.
---@return table<string,string> map name -> installed|missing|outdated|corrupted|build-needed
function M.status()
	local manifest = require("distro.manifest")
	local lock = M.read()
	local cfg = vim.fn.stdpath("config")
	local out = {}
	for _, p in ipairs(manifest.plugins) do
		local dir = string.format("%s/pack/distro/%s/%s", cfg, p.kind, p.name)
		if not dir_exists(dir) then
			out[p.name] = "missing"
		elseif not sentinel_ok(dir) then
			out[p.name] = "corrupted"
		elseif lock[p.name] and lock[p.name].ref ~= p.ref then
			out[p.name] = "outdated"
		elseif p.build and not M.build_done(p) then
			out[p.name] = "build-needed"
		else
			out[p.name] = "installed"
		end
	end
	return out
end

--- Build-output sentinel per plugin (cheap file probes, no process spawn).
function M.build_done(p)
	local cfg = vim.fn.stdpath("config")
	if p.name == "LuaSnip" then
		-- produced by `make install_jsregexp` (copies .so next to lua/ + deps/)
		local dir = cfg .. "/pack/distro/opt/LuaSnip"
		return dir_exists(dir .. "/deps/luasnip-jsregexp.so") or dir_exists(dir .. "/lua/luasnip-jsregexp.lua")
	elseif p.name == "nvim-treesitter" then
		-- old-arch nvim-treesitter keeps compiled parsers in its own parser/ dir
		-- (mirrors the previous working lazy setup; see Step 6 for relocation)
		return dir_exists(cfg .. "/pack/distro/opt/nvim-treesitter/parser/go.so")
	end
	return true
end

--- Mark a dir as healthy after successful install (called by install.lua).
function M.mark_ok(dir)
	local f = io.open(dir .. "/.distro-ok", "w")
	if f then
		f:write(os.date("!%Y-%m-%dT%H:%M:%SZ") .. "\n")
		f:close()
	end
end

return M
