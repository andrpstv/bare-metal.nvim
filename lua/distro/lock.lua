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
	if ok and type(data) == "table" then
		return data
	end
	-- corrupted main file: fall back to the backup written before every write
	local bf = io.open(p .. ".bak", "r")
	if bf then
		local bok, bdata = pcall(vim.json.decode, bf:read("*a"))
		bf:close()
		if bok and type(bdata) == "table" then
			return bdata, "recovered"
		end
	end
	return {}, "invalid"
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
	-- atomic: tmp file + rename, so a crash can never leave a half-written lock
	local tmp = p .. ".tmp"
	local f = io.open(tmp, "w")
	if not f then
		return false, "Cannot write to " .. p .. " (permission denied). Check ownership. No changes made."
	end
	f:write(vim.json.encode(tbl))
	f:close()
	if vim.uv.fs_stat(tmp) and not os.rename(tmp, p) then
		return false, "Cannot replace " .. p .. " (permission denied). No changes made."
	end
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
---@param pre_read table? optional lock.read() result (avoids double parse)
---@return table<string,string> map name -> installed|missing|outdated|corrupted|build-needed
function M.status(pre_read)
	local manifest = require("distro.manifest")
	local lock, lock_err
	if pre_read then
		lock, lock_err = pre_read, nil
	else
		lock, lock_err = M.read()
	end
	if lock_err == "invalid" then
		-- lock unreadable AND backup unreadable: everything is suspect, say so loudly
		local out = {}
		for _, p in ipairs(manifest.plugins) do
			out[p.name] = "corrupted"
		end
		return out
	end
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
		-- old-arch nvim-treesitter keeps compiled parsers in its own parser/ dir.
		-- ALL settings.treesitter_deps must be present, not just go.
		local dir = cfg .. "/pack/distro/opt/nvim-treesitter/parser"
		for _, lang in ipairs(require("core.settings").treesitter_deps or {}) do
			if not dir_exists(dir .. "/" .. lang .. ".so") then
				return false
			end
		end
		return true
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
