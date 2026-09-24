-- distroManager UI — float menu, lazy-parity. Opens with :Distro.
-- Rendering is local-only (manifest + lock.status). Every network action
-- previews (redacted) + confirms first. See docs/distro/02-ux-english-copy.md.

local M = {}

local ST = { missing = "○", outdated = "◐", corrupted = "✖", ["build-needed"] = "⚒", installed = "●" }

-- status -> highlight (linked to builtin groups, so any theme applies)
local ST_HL = { missing = "DistroErr", outdated = "DistroWarn", corrupted = "DistroErr", ["build-needed"] = "DistroWarn", installed = "DistroOk" }

local function ensure_hl()
	for name, link in pairs({
		DistroOk = "DiagnosticOk",
		DistroWarn = "DiagnosticWarn",
		DistroErr = "DiagnosticError",
		DistroDim = "Comment",
		DistroTitle = "Title",
		DistroUp = "DiagnosticWarn",
	}) do
		pcall(vim.api.nvim_set_hl, 0, name, { link = link, default = true })
	end
end
M.ensure_hl = ensure_hl

local function groups()
	local manifest = require("distro.manifest")
	local status = require("distro.lock").status()
	local g = { missing = {}, outdated = {}, installed = {}, order = {} }
	for _, p in ipairs(manifest.plugins) do
		local st = status[p.name] or "missing"
		g.order[#g.order + 1] = { entry = p, st = st }
		if st == "installed" then
			g.installed[#g.installed + 1] = p
		elseif st == "outdated" or st == "build-needed" then
			g.outdated[#g.outdated + 1] = p
		else
			g.missing[#g.missing + 1] = p
		end
	end
	return g
end

--- Build one grid row. Returns text + highlight spans ({col0, col1, group}, byte cols).
---@return string, table
local function build_row(p, st, extra, NW, suffix)
	local short = p.ref:sub(1, 7)
	local lock = require("distro.lock").read()[p.name]
	-- "up to date" means: matches the pinned distro version (lock == manifest).
	-- Upstream may still be ahead — that is shown as ↑<sha> (press X to refresh).
	local up = require("distro.install").remote_newer(p.name, p.ref)
	local label = st == "missing" and "not installed"
		or st == "outdated" and "differs from pin — press U"
		or st == "corrupted" and "corrupted — press R"
		or st == "build-needed" and "build needed"
		or (up and ("up to date · ↑" .. up .. " upstream") or "up to date")
	-- dependencies are resolved by the loader before the parent: make them visible
	local ndeps = #(p.deps or {})
	if ndeps > 0 then
		label = label .. " · " .. ndeps .. " dep" .. (ndeps > 1 and "s" or "")
	end
	if p.provides then
		label = label .. " [" .. table.concat(p.provides, ", ") .. "]"
	end
	if lock and lock.mirror then
		label = label .. " (mirror:" .. (lock.mirror_branch or "?") .. ")"
	end
	if suffix and suffix ~= "" then
		label = label .. " · " .. suffix
	end
	local icon = ST[st] or "?"
	-- layout: 3sp + icon(3B) + 1sp + name(NW) + 2sp + ver(7) + 2sp + label
	local text = string.format("   %s %-" .. NW .. "s  %-7s  %s", icon, p.name, short, extra or label)
	local spans = { { 3, 6, ST_HL[st] or "DistroDim" } }
	local up_at = text:find("↑", 1, true)
	if up_at then
		spans[#spans + 1] = { up_at - 1, up_at + 9, "DistroUp" } -- ↑ + 7 hex + space-ish
	end
	return text, spans
end

--- Count of rows whose cached X-check found a newer upstream HEAD.
local function upstream_count()
	local n = 0
	for _, p in ipairs(require("distro.manifest").plugins) do
		if require("distro.install").remote_newer(p.name, p.ref) then
			n = n + 1
		end
	end
	return n
end

function M.render()
	local manifest = require("distro.manifest")
	local g = groups()
	local mirror = require("distro.mirror")
	local up_n = upstream_count()
	-- line -> { type = "header"|"entry"|"catalog"|"text", section = ..., entry = ... }
	-- Cursor-aware keys (i/u/d/r/x/Enter) resolve through this map.
	local map = {}
	local lines = {}
	local hls = {}
	-- grid: name column sized to content (cap 32), everything else fixed
	local NW = 12
	for _, p in ipairs(manifest.plugins) do
		NW = math.min(32, math.max(NW, #p.name))
	end
	for _, p in ipairs(manifest.catalog or {}) do
		NW = math.min(32, math.max(NW, #p.name))
	end
	local function add(text, target, hl)
		lines[#lines + 1] = text
		map[#lines] = target
		if hl then
			for _, s in ipairs(hl) do
				hls[#hls + 1] = { line = #lines - 1, col0 = s[1], col1 = s[2], group = s[3] }
			end
		end
	end
	local function sep()
		add(string.rep("─", 60), { type = "text" }, { { 0, -1, "DistroDim" } })
	end
	local function header(text, section)
		add(" " .. text, { type = "header", section = section }, { { 1, -1, "DistroTitle" } })
	end
	add(
		" Distro ── "
			.. #manifest.plugins
			.. " plugins · "
			.. #g.missing
			.. " missing · "
			.. #g.outdated
			.. " need attention"
			.. (up_n > 0 and (" · ↑" .. up_n .. " upstream (X)") or ""),
		{ type = "text" }
	)
	add(" Nothing is downloaded or updated automatically — ever.", { type = "text" })
	add(" 'up to date' = matches the pinned distro version. ↑sha = upstream moved (X to refresh).", { type = "text" })
	add(" Source: " .. mirror.label(), { type = "text" })
	sep()
	header(string.format("Missing (%d)   [I] Install", #g.missing), "missing")
	for _, p in ipairs(g.missing) do
		local text, spans = build_row(p, (require("distro.lock").status()[p.name]), nil, NW)
		add(text, { type = "entry", section = "missing", entry = p }, spans)
	end
	sep()
	header(string.format("Needs attention (%d)   [U] Sync to pin  [R] Revert", #g.outdated), "outdated")
	for _, p in ipairs(g.outdated) do
		local text, spans = build_row(p, (require("distro.lock").status()[p.name]), nil, NW)
		add(text, { type = "entry", section = "outdated", entry = p }, spans)
	end
	sep()
	header(string.format("Installed (%d)", #g.installed), "installed")
	for _, p in ipairs(g.installed) do
		local text, spans = build_row(p, "installed", nil, NW)
		add(text, { type = "entry", section = "installed", entry = p }, spans)
	end
	sep()
	header("Catalog (on demand — :DistroInstall <name>)", "catalog")
	local loader = require("distro.loader")
	for _, p in ipairs(manifest.catalog or {}) do
		local present = loader.is_present(p)
		local text, spans = build_row(p, present and "installed" or "missing", nil, NW, p.desc)
		add(text, { type = "catalog", section = "catalog", entry = p }, spans)
	end
	sep()
	header("Binaries   [B] Menu — gopls, bashls, lua_ls, stylua, …", "bins")
	add("", { type = "text" })
	header("Mirror   [M] Open mirror menu — switch source, token, test", "mirror")
	local eff = require("distro.mirror").effective()
	add("   mode: " .. mirror.label() .. (eff.enabled and "" or "  (github = public internet)"), { type = "text" })
	if eff.enabled and require("distro.mirror").insecure(eff.extra_args) then
		add("   ! TLS verification DISABLED (--insecure)", { type = "text" }, { { 3, -1, "DistroWarn" } })
	end
	add("", { type = "text" })
	add(" row: i install · u sync · d/Enter details · r revert · x check · o open", { type = "text" })
	add(" all: I install · U sync · C clean · S adopt · X check · D input", { type = "text" })
	add("      R revert · B bins · M mirror · ? help · q quit", { type = "text" })
	M._map = map
	M._hl = hls
	M._width = 0
	for _, l in ipairs(lines) do
		M._width = math.min(100, math.max(M._width, vim.fn.strdisplaywidth(l)))
	end
	return lines
end

local current_win, current_buf

local function close()
	if current_win and vim.api.nvim_win_is_valid(current_win) then
		vim.api.nvim_win_close(current_win, true)
	end
	current_win, current_buf = nil, nil
end

--- Entry (or section header) under the UI cursor. The heart of cursor-aware keys.
---@return table? { type=..., section=..., entry=...? }
local function cur_target()
	if not (current_win and vim.api.nvim_win_is_valid(current_win)) then
		return nil
	end
	local line = vim.api.nvim_win_get_cursor(current_win)[1]
	return (M._map or {})[line]
end

local function reopen()
	local line = nil
	if current_win and vim.api.nvim_win_is_valid(current_win) then
		line = vim.api.nvim_win_get_cursor(current_win)[1]
	end
	close()
	M.open()
	if line and current_win and vim.api.nvim_win_is_valid(current_win) then
		local count = vim.api.nvim_buf_line_count(current_buf)
		pcall(vim.api.nvim_win_set_cursor, current_win, { math.min(line, count), 0 })
	end
end

local function confirm_or_cancel(text)
	return vim.fn.confirm(text, "&Yes\n&No", 2) == 1
end

--- Shared single-entry installer (preview with Source block + confirm).
---@return boolean ok
local function install_single(p)
	local install = require("distro.install")
	local src, err = install.resolve_source(p)
	if not src then
		vim.notify(err, vim.log.levels.ERROR)
		return false
	end
	local lines = { string.format("Install '%s' (%s)?", p.name, p.ref:sub(1, 7)) }
	lines[#lines + 1] = "To: pack/distro/" .. p.kind .. "/" .. p.name
	lines[#lines + 1] = "Version will be recorded in distro-lock.json."
	for _, l in ipairs(install.source_lines(src)) do
		lines[#lines + 1] = l
	end
	if not confirm_or_cancel(table.concat(lines, "\n")) then
		vim.notify("Installation canceled. No changes were made.", vim.log.levels.INFO)
		return false
	end
	local ok, msg = install.install_one(p, { user_confirmed = true })
	vim.notify(msg, ok and vim.log.levels.INFO or vim.log.levels.ERROR)
	if ok then
		require("distro.loader").load(p.name) -- activate immediately
	end
	return ok
end

--- i: install the entry under the cursor (missing) or hint what to press instead.
function M.do_install_cursor()
	local t = cur_target()
	if t and (t.type == "entry" or t.type == "catalog") and t.entry then
		local st = t.type == "entry" and (require("distro.lock").status()[t.entry.name]) or nil
		if st == "installed" then
			vim.notify("'" .. t.entry.name .. "' is already installed (u reinstalls, r reverts). No changes made.", vim.log.levels.INFO)
			return
		end
		if install_single(t.entry) then
			reopen()
		end
		return
	end
	if t and t.type == "header" and t.section == "missing" then
		M.do_install_missing()
		return
	end
	M.do_install_missing()
end

--- u: reinstall the entry under the cursor to its pin.
function M.do_sync_cursor()
	local t = cur_target()
	if t and (t.type == "entry" or t.type == "catalog") and t.entry then
		if install_single(t.entry) then
			reopen()
		end
		return
	end
	if t and t.type == "header" and t.section == "outdated" then
		M.do_sync_outdated()
		return
	end
	M.do_sync_outdated()
end

--- r: revert the entry under the cursor to its previous_ref.
function M.do_revert_cursor()
	local t = cur_target()
	if t and t.type == "entry" and t.entry then
		local l = require("distro.lock").read()[t.entry.name]
		local prev = l and l.previous_ref
		if not (type(prev) == "string" and prev ~= "") then
			vim.notify("No previous version recorded for '" .. t.entry.name .. "'. No changes made.", vim.log.levels.INFO)
			return
		end
		if not confirm_or_cancel("Revert '" .. t.entry.name .. "' to " .. prev:sub(1, 7) .. "?") then
			vim.notify("Revert canceled. No changes were made.", vim.log.levels.INFO)
			return
		end
		local e = vim.tbl_extend("force", {}, t.entry, { ref = prev })
		local ok, msg = require("distro.install").install_one(e, { user_confirmed = true })
		vim.notify(msg, ok and vim.log.levels.INFO or vim.log.levels.ERROR)
		if ok then
			reopen()
		end
		return
	end
	M.do_revert()
end

--- x: check upstream HEAD for the entry under the cursor (1 API call, confirm-gated).
function M.do_check_cursor()
	local t = cur_target()
	if not (t and (t.type == "entry" or t.type == "catalog") and t.entry) then
		M.do_check_remote()
		return
	end
	local p = t.entry
	local eff = require("distro.mirror").effective()
	if eff.enabled then
		vim.notify("Remote check needs the GitHub API, unavailable via corporate mirror. No changes made.", vim.log.levels.WARN)
		return
	end
	if not confirm_or_cancel("Query api.github.com for '" .. p.repo .. "' HEAD?\nDownloads nothing.") then
		vim.notify("Check canceled. No changes were made.", vim.log.levels.INFO)
		return
	end
	local install = require("distro.install")
	local sha, err = install.remote_head_sha(p.repo, p.branch or "main")
	if not sha then
		vim.notify(err or "API unreachable. No changes made.", vim.log.levels.ERROR)
		return
	end
	local cache = install.read_remote_cache()
	cache[p.name] = { remote_sha = sha, checked_at = os.date("!%Y-%m-%dT%H:%M:%SZ") }
	local f = io.open(install.remote_cache_path(), "w")
	if f then
		f:write(vim.json.encode(cache))
		f:close()
	end
	if sha == p.ref then
		vim.notify("'" .. p.name .. "' matches upstream HEAD (" .. sha:sub(1, 7) .. ").", vim.log.levels.INFO)
	else
		vim.notify("'" .. p.name .. "' upstream moved: " .. p.ref:sub(1, 7) .. " → " .. sha:sub(1, 7) .. " (pin unchanged — edit manifest to bump).", vim.log.levels.WARN)
	end
	reopen()
end

--- I: install all missing (preview + one confirm, sequential).
function M.do_install_missing()
	local missing = groups().missing
	if #missing == 0 then
		vim.notify("Nothing missing. No changes made.", vim.log.levels.INFO)
		return
	end
	local install = require("distro.install")
	local lines = { "Install " .. #missing .. " item(s)? [y = install all]" }
	for _, p in ipairs(missing) do
		local src, err = install.resolve_source(p)
		if not src then
			vim.notify(err, vim.log.levels.ERROR)
			return
		end
		lines[#lines + 1] = string.format("  %s (%s) → pack/distro/%s/%s", p.name, p.ref:sub(1, 7), p.kind, p.name)
		for _, l in ipairs(install.source_lines(src)) do
			lines[#lines + 1] = "    " .. l
		end
	end
	if not confirm_or_cancel(table.concat(lines, "\n")) then
		vim.notify("Installation canceled. No changes were made.", vim.log.levels.INFO)
		return
	end
	local done, failed = 0, {}
	for _, p in ipairs(missing) do
		local ok, msg = install.install_one(p, { user_confirmed = true })
		if ok then
			done = done + 1
			require("distro.loader").load(p.name) -- activate immediately
		else
			failed[#failed + 1] = p.name .. ": " .. msg
		end
	end
	vim.notify(
		string.format("Installed %d/%d. %s", done, #missing, #failed > 0 and ("Failed: " .. table.concat(failed, "; ")) or "Version(s) recorded in distro-lock.json."),
		#failed > 0 and vim.log.levels.WARN or vim.log.levels.INFO
	)
	reopen()
end

--- U: sync outdated entries back to the manifest pin (re-download pin). Preview + confirm.
function M.do_sync_outdated()
	local outdated = groups().outdated
	if #outdated == 0 then
		vim.notify("Everything matches the manifest pin. No changes made.", vim.log.levels.INFO)
		return
	end
	local lock = require("distro.lock").read()
	local lines = { "Re-install " .. #outdated .. " item(s) to manifest pin?" }
	for _, p in ipairs(outdated) do
		local old = lock[p.name] and lock[p.name].ref:sub(1, 7) or "?"
		lines[#lines + 1] = string.format("  %s  %s → %s", p.name, old, p.ref:sub(1, 7))
	end
	if not confirm_or_cancel(table.concat(lines, "\n")) then
		vim.notify("Sync canceled. No changes were made.", vim.log.levels.INFO)
		return
	end
	local install = require("distro.install")
	local done = 0
	for _, p in ipairs(outdated) do
		local ok, msg = install.install_one(p, { user_confirmed = true })
		if ok then
			done = done + 1
			require("distro.loader").load(p.name)
		else
			vim.notify(msg, vim.log.levels.ERROR)
		end
	end
	vim.notify(string.format("Synced %d/%d to manifest pins.", done, #outdated), vim.log.levels.INFO)
	reopen()
end

--- S: adopt manifest pins into the lock without downloading (trust current dirs).
function M.do_adopt_pins()
	local outdated = groups().outdated
	if #outdated == 0 then
		vim.notify("Lock already matches the manifest. No changes made.", vim.log.levels.INFO)
		return
	end
	if not confirm_or_cancel("Adopt manifest pins for " .. #outdated .. " item(s) WITHOUT downloading?\nUse only if the dirs are known-good.") then
		vim.notify("Adopt canceled. No changes were made.", vim.log.levels.INFO)
		return
	end
	local lockmod = require("distro.lock")
	for _, p in ipairs(outdated) do
		lockmod.record(p.name, {
			repo = p.repo,
			ref = p.ref,
			tarball = lockmod.read()[p.name] and lockmod.read()[p.name].tarball or "",
			kind = p.kind,
			size_kb = require("distro.install").dir_size_kb(require("distro.loader").pack_dir(p)),
		})
		lockmod.mark_ok(require("distro.loader").pack_dir(p))
	end
	vim.notify("Adopted " .. #outdated .. " pin(s) into distro-lock.json.", vim.log.levels.INFO)
	reopen()
end

--- C: clean unmanaged dirs under pack/distro + tmp staging + data-dir lazy leftovers.
function M.do_clean()
	local cfg = vim.fn.stdpath("config")
	local manifest = require("distro.manifest")
	local known = {}
	for _, p in ipairs(manifest.plugins) do
		known[p.kind .. "/" .. p.name] = true
	end
	local victims = {}
	for _, kind in ipairs({ "start", "opt" }) do
		local h = vim.uv.fs_scandir(cfg .. "/pack/distro/" .. kind)
		if h then
			while true do
				local n, t = vim.uv.fs_scandir_next(h)
				if not n then
					break
				end
				if t == "directory" and not known[kind .. "/" .. n] then
					victims[#victims + 1] = "pack/distro/" .. kind .. "/" .. n
				end
			end
		end
	end
	-- previous-manager leftovers in the data dir (*.cloning etc.)
	local datadir = vim.fn.stdpath("data") .. "/site/lazy"
	local h = vim.uv.fs_scandir(datadir)
	if h then
		while true do
			local n, t = vim.uv.fs_scandir_next(h)
			if not n then
				break
			end
			if t == "directory" and (n:match("%.cloning$") or n:match("%.tmp$")) then
				victims[#victims + 1] = "site/lazy/" .. n .. "  (old manager leftover)"
			end
		end
	end
	if #victims == 0 then
		vim.notify("Nothing to clean. No changes made.", vim.log.levels.INFO)
		return
	end
	if not confirm_or_cancel("Remove " .. #victims .. " unused dir(s)?\n  " .. table.concat(victims, "\n  ")) then
		vim.notify("Clean canceled. No changes were made.", vim.log.levels.INFO)
		return
	end
	for _, v in ipairs(victims) do
		local rel = v:gsub("  %(old manager leftover%)", "")
		if rel:match("^pack/") then
			vim.fn.delete(cfg .. "/" .. rel, "rf")
		else
			vim.fn.delete(vim.fn.stdpath("data") .. "/" .. rel, "rf")
		end
	end
	vim.notify("Removed " .. #victims .. " dir(s).", vim.log.levels.INFO)
	reopen()
end
--- d/Enter: details for the entry under the cursor (falls back to input).
function M.do_details_cursor()
	local t = cur_target()
	if t and (t.type == "entry" or t.type == "catalog") and t.entry then
		M.do_details_name(t.entry.name)
		return
	end
	M.do_details()
end

--- D: details for one plugin (name via input).
function M.do_details()
	local name = vim.fn.input("Distro details for plugin: ")
	if name == "" then
		return
	end
	M.do_details_name(name)
end

---@param name string
function M.do_details_name(name)
	local entry = require("distro.manifest").get(name)
	if not entry then
		vim.notify("Unknown plugin '" .. name .. "'.", vim.log.levels.ERROR)
		return
	end
	local lock = require("distro.lock").read()[name] or {}
	local install = require("distro.install")
	local src, err = install.resolve_source(entry)
	local up = install.remote_newer(entry.name, entry.ref)
	local triggers = {}
	if entry.event then
		triggers[#triggers + 1] = "event:" .. table.concat(type(entry.event) == "string" and { entry.event } or entry.event, ",")
	end
	if entry.ft then
		triggers[#triggers + 1] = "ft:" .. table.concat(entry.ft, ",")
	end
	if entry.cmd then
		triggers[#triggers + 1] = "cmd:" .. table.concat(type(entry.cmd) == "string" and { entry.cmd } or entry.cmd, ",")
	end
	if entry.kind == "start" then
		triggers[#triggers + 1] = "eager(start)"
	end
	vim.notify(
		table.concat({
			name .. "  (" .. entry.repo .. ")",
			"  pin:        " .. entry.ref,
			"  installed:  " .. (lock.ref or "—"),
			"  status:     " .. (require("distro.lock").status()[name] or "?") .. " (= matches pin)",
			"  upstream:   " .. (up and ("↑" .. up .. " — edit manifest ref to bump, then :DistroInstall " .. name) or "same as pin (press X to re-check)"),
			"  deps:       " .. (#(entry.deps or {}) > 0 and table.concat(entry.deps, ", ") or "(none)"),
			"  provides:   " .. (entry.provides and table.concat(entry.provides, ", ") or name),
			"  config:     " .. (entry.config or "(none)"),
			"  triggers:   " .. (#triggers > 0 and table.concat(triggers, " ") or "(on demand only)"),
			"  source:     " .. (src and require("distro.mirror").redact(src.url) or err),
			"  dest:       pack/distro/" .. entry.kind .. "/" .. name,
		}, "\n"),
		vim.log.levels.INFO
	)
end

--- R: revert entries with a previous_ref to it (download previous pin).
function M.do_revert()
	local lock = require("distro.lock").read()
	local manifest = require("distro.manifest")
	local cands = {}
	for _, p in ipairs(manifest.plugins) do
		local l = lock[p.name]
		if l and l.previous_ref and type(l.previous_ref) == "string" and l.previous_ref ~= "" then
			cands[#cands + 1] = { entry = p, prev = l.previous_ref }
		end
	end
	if #cands == 0 then
		vim.notify("No previous versions recorded. No changes made.", vim.log.levels.INFO)
		return
	end
	local lines = { "Revert to previous version(s)?" }
	for _, c in ipairs(cands) do
		lines[#lines + 1] = string.format("  %s  → %s", c.entry.name, c.prev:sub(1, 7))
	end
	if not confirm_or_cancel(table.concat(lines, "\n")) then
		vim.notify("Revert canceled. No changes were made.", vim.log.levels.INFO)
		return
	end
	local install = require("distro.install")
	for _, c in ipairs(cands) do
		local e = vim.tbl_extend("force", {}, c.entry, { ref = c.prev })
		local ok, msg = install.install_one(e, { user_confirmed = true })
		vim.notify(msg, ok and vim.log.levels.INFO or vim.log.levels.ERROR)
	end
	reopen()
end

local function remote_cache_path()
	return require("distro.install").remote_cache_path()
end

local function read_remote_cache()
	return require("distro.install").read_remote_cache()
end

--- X: check GitHub for newer branch HEADs (github mode only, confirm-gated network).
function M.do_check_remote()
	local eff = require("distro.mirror").effective()
	if eff.enabled then
		vim.notify("Remote check needs the GitHub API, unavailable via corporate mirror. Lock-vs-manifest drift is shown above. No changes made.", vim.log.levels.WARN)
		return
	end
	if not confirm_or_cancel("Query api.github.com for newer commits (one request per plugin)?\nThis is the only network read in :Distro, and it downloads nothing.") then
		vim.notify("Check canceled. No changes were made.", vim.log.levels.INFO)
		return
	end
	local manifest = require("distro.manifest")
	local install = require("distro.install")
	local cache, newer = {}, {}
	for _, p in ipairs(manifest.plugins) do
		local sha, err = install.remote_head_sha(p.repo, p.branch or "main")
		if sha then
			cache[p.name] = { remote_sha = sha, checked_at = os.date("!%Y-%m-%dT%H:%M:%SZ") }
			if sha ~= p.ref then
				newer[#newer + 1] = string.format("  %s  %s → %s", p.name, p.ref:sub(1, 7), sha:sub(1, 7))
			end
		else
			cache[p.name] = { error = err }
		end
	end
	local f = io.open(remote_cache_path(), "w")
	if f then
		f:write(vim.json.encode(cache))
		f:close()
	end
	if #newer == 0 then
		vim.notify("All pins match upstream HEADs. To bump a pin, edit its ref in lua/distro/manifest.lua, then :DistroInstall <name>.", vim.log.levels.INFO)
	else
		vim.notify("Updates available upstream (pins unchanged — edit manifest to bump):\n" .. table.concat(newer, "\n"), vim.log.levels.WARN)
	end
end

local function open_float(lines)
	require("distro.ui").ensure_hl()
	local content_w = (require("distro.ui")._width or 88) + 2
	local width = math.min(math.max(80, content_w), math.max(40, vim.o.columns - 4))
	local height = math.min(#lines, vim.o.lines - 4)
	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.api.nvim_buf_set_option(buf, "modifiable", false)
	vim.api.nvim_buf_set_option(buf, "filetype", "distro")
	current_win = vim.api.nvim_open_win(buf, true, {
		relative = "editor",
		width = width,
		height = height,
		row = math.max(1, (vim.o.lines - height) / 2 - 1),
		col = math.max(1, (vim.o.columns - width) / 2),
		style = "minimal",
		border = "rounded",
		title = "Distro",
	})
	current_buf = buf
	pcall(function()
		vim.wo[current_win].cursorline = true
		vim.wo[current_win].wrap = false
	end)
	-- status colors (namespace per buffer, applied once per render)
	local ns = vim.api.nvim_create_namespace("distro_ui")
	for _, h in ipairs(require("distro.ui")._hl or {}) do
		pcall(vim.api.nvim_buf_add_highlight, buf, ns, h.group, h.line, h.col0, h.col1)
	end
	-- live title follows the cursor: "Distro — <plugin>" on rows
	local group = vim.api.nvim_create_augroup("DistroUITitle", { clear = true })
	vim.api.nvim_create_autocmd("CursorMoved", {
		group = group,
		buffer = buf,
		callback = function()
			if not (current_win and vim.api.nvim_win_is_valid(current_win)) then
				return
			end
			local line = vim.api.nvim_win_get_cursor(current_win)[1]
			local t = (require("distro.ui")._map or {})[line]
			local title = "Distro"
			if t and t.entry then
				title = "Distro — " .. t.entry.name
			elseif t and t.type == "header" then
				title = "Distro — " .. (t.section or "")
			end
			pcall(vim.api.nvim_win_set_config, current_win, { title = title })
		end,
		desc = "distro: live float title",
	})
	local map = function(key, fn, desc)
		vim.keymap.set("n", key, fn, { buffer = buf, nowait = true, desc = desc })
	end
	map("q", close, "Close")
	map("<Esc>", close, "Close")
	map("?", M.open_help, "Help")
	-- cursor row actions (lowercase): act on the entry under the cursor
	map("i", M.do_install_cursor, "Install this")
	map("u", M.do_sync_cursor, "Sync this to pin")
	map("d", function()
		M.do_details_cursor()
	end, "Details of this")
	map("<CR>", function()
		M.do_details_cursor()
	end, "Details of this")
	map("r", M.do_revert_cursor, "Revert this")
	map("x", M.do_check_cursor, "Check upstream of this")
	map("o", function()
		local t = cur_target()
		if t and t.entry then
			local url = "https://github.com/" .. t.entry.repo
			local ok, err = pcall(vim.ui.open, url)
			if not ok then
				vim.notify("[Distro] cannot open browser: " .. tostring(err):sub(1, 120), vim.log.levels.WARN)
			end
		else
			vim.notify("No plugin under cursor. Move to a plugin row first.", vim.log.levels.INFO)
		end
	end, "Open repo in browser")
	-- bulk actions (uppercase/global)
	map("I", M.do_install_missing, "Install all missing")
	map("U", M.do_sync_outdated, "Sync all to pin")
	map("C", M.do_clean, "Clean")
	map("S", M.do_adopt_pins, "Adopt pins")
	map("X", M.do_check_remote, "Check all remote")
	map("D", M.do_details, "Details (input)")
	map("R", M.do_revert, "Revert all")
	map("B", function()
		close()
		require("distro.tools").open_binaries()
	end, "Binaries menu")
	map("M", M.open_mirror, "Mirror menu")
	return buf, current_win
end

--- Full key reference (production help, not a one-line notify).
function M.open_help()
	local lines = {
		" Distro keys — every network action previews + confirms first.",
		"",
		" Cursor row (a plugin line):",
		"   i ......... install this entry (missing/corrupted)",
		"   u ......... reinstall this entry to its pin",
		"   d / Enter . details: pin, upstream, deps, config, triggers, source",
		"   r ......... revert this entry to its previous version",
		"   x ......... check upstream HEAD of this entry (1 API call)",
		"   o ......... open repo page in browser",
		"",
		" Whole distro (anywhere):",
		"   I ......... install all missing        U .. sync all outdated to pins",
		"   C ......... clean unmanaged dirs       S .. adopt pins without download",
		"   X ......... check all upstream HEADs   D .. details by name (input)",
		"   R ......... revert all with previous   B .. binaries menu (LSP/tools)",
		"   M ......... corporate mirror menu      ? .. this help   q .. close",
		"",
		" 'up to date' = matches the pinned distro version.",
		" ↑sha = upstream moved ahead (press x/X to refresh the check).",
		" Nothing is downloaded or updated automatically — ever.",
	}
	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.api.nvim_buf_set_option(buf, "modifiable", false)
	vim.api.nvim_buf_set_option(buf, "filetype", "distro-help")
	local win = vim.api.nvim_open_win(buf, true, {
		relative = "editor",
		width = 82,
		height = math.min(#lines, vim.o.lines - 4),
		row = 2,
		col = math.max(1, (vim.o.columns - 82) / 2),
		style = "minimal",
		border = "rounded",
		title = "Distro keys",
	})
	local function back()
		pcall(vim.api.nvim_win_close, win, true)
		if current_win and vim.api.nvim_win_is_valid(current_win) then
			pcall(vim.api.nvim_set_current_win, current_win)
		end
	end
	vim.keymap.set("n", "q", back, { buffer = buf, nowait = true })
	vim.keymap.set("n", "<Esc>", back, { buffer = buf, nowait = true })
	vim.keymap.set("n", "?", back, { buffer = buf, nowait = true })
end

--- Interactive corporate-mirror menu (no :DistroMirror typing needed).
function M.open_mirror()
	close() -- avoid stacking on the main float; b/q returns via M.open()
	local mirror = require("distro.mirror")
	local eff = mirror.effective()
	local tok = mirror.token()
	local lines = {
		" Mirror setup — same manager, different source. Nothing downloads here.",
		"",
		"   mode:     " .. (eff.enabled and "corporate" or "github (codeload, public internet)"),
		"   template: " .. (eff.url_template ~= "" and mirror.redact(eff.url_template) or "(empty — github)"),
		"   args:     " .. (#eff.extra_args > 0 and table.concat(eff.extra_args, " ") or "(none)"),
		"   token:    " .. (tok and "set (session/env, never stored)" or "MISSING (" .. eff.token_env .. " empty)"),
		"   hosts:    "
			.. (#eff.allowed_hosts > 0 and ("only: " .. table.concat(eff.allowed_hosts, ", ")) or "(any https host)"),
	}
	if mirror.insecure(eff.extra_args) then
		lines[#lines + 1] = "   ! TLS verification DISABLED (--insecure) — corporate proxy only"
	end
	lines[#lines + 1] = ""
	lines[#lines + 1] = " e enable/disable · u set URL · a set args · k set token (session) · t test · b back"
	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.api.nvim_buf_set_option(buf, "modifiable", false)
	vim.api.nvim_buf_set_option(buf, "filetype", "distro-mirror")
	local win = vim.api.nvim_open_win(buf, true, {
		relative = "editor",
		width = 82,
		height = math.min(#lines, vim.o.lines - 4),
		row = 2,
		col = math.max(1, (vim.o.columns - 82) / 2),
		style = "minimal",
		border = "rounded",
		title = "Distro mirror",
	})
	-- pause the main window underneath; restore on back
	local function back()
		pcall(vim.api.nvim_win_close, win, true)
		M.open()
	end
	local function act(sub)
		pcall(vim.api.nvim_win_close, win, true)
		require("distro.mirror_cmd").run(sub)
		-- re-open submenu to show the new state (run() only notifies)
		vim.schedule(function()
			if vim.api.nvim_win_is_valid(win) then
				return
			end
			M.open_mirror()
		end)
	end
	local map = function(key, fn, desc)
		vim.keymap.set("n", key, fn, { buffer = buf, nowait = true, desc = desc })
	end
	map("b", back, "Back")
	map("q", back, "Back")
	map("<Esc>", back, "Back")
	map("e", function()
		act(require("distro.mirror").effective().enabled and "off" or "on")
	end, "Toggle enable")
	map("u", function()
		local cur = require("distro.mirror").effective().url_template
		local url = vim.fn.input("Mirror URL template: ", cur)
		if url == nil then
			M.open_mirror()
			return
		end
		pcall(vim.api.nvim_win_close, win, true)
		require("distro.mirror_cmd").run("set-url" .. (url ~= "" and (" " .. url) or ""))
		vim.schedule(function()
			M.open_mirror()
		end)
	end, "Set URL")
	map("a", function()
		local cur = table.concat(require("distro.mirror").effective().extra_args, " ")
		local args = vim.fn.input("Mirror curl args (space-separated, empty clears): ", cur)
		if args == nil then
			M.open_mirror()
			return
		end
		pcall(vim.api.nvim_win_close, win, true)
		if args:match("^%s*$") then
			require("distro.mirror_cmd").run("clear-args")
		else
			require("distro.mirror_cmd").run("set-args " .. args)
		end
		vim.schedule(function()
			M.open_mirror()
		end)
	end, "Set args")
	map("k", function()
		act("set-token")
	end, "Set token")
	map("t", function()
		require("distro.mirror_cmd").test()
	end, "Test")
end

function M.open()
	-- production guard: a broken manifest (e.g. bad edit) must not explode
	-- into a traceback; show one friendly error instead.
	local ok, lines_or_err = pcall(M.render)
	if not ok then
		vim.notify("[Distro] cannot render: " .. tostring(lines_or_err):gsub("^.-: ", ""):sub(1, 200) .. " — fix lua/distro/manifest.lua.", vim.log.levels.ERROR)
		return
	end
	open_float(lines_or_err)
end

return M
