_G._command_panel = function()
	_G._fzf("commands")
end

-- Безопасный вызов fzf-lua: догружает плагин через lazy, если он ещё спит.
-- Без этого require("fzf-lua") падает с "module not found" до первой загрузки.
---@param fn string @имя пикера, например "files"
---@param opts table|fun(fzf: table):table|nil
_G._fzf = function(fn, opts)
	pcall(function()
		require("lazy").load({ plugins = { "fzf-lua" } })
	end)
	local ok, fzf = pcall(require, "fzf-lua")
	if not ok or type(fzf[fn]) ~= "function" then
		vim.notify("[fzf] picker unavailable: " .. fn, vim.log.levels.ERROR, { title = "fzf" })
		return
	end
	if type(opts) == "function" then
		opts = opts(fzf)
	end
	fzf[fn](opts)
end

_G._flash_esc_or_noh = function()
	local flash_active, state = pcall(function()
		return require("flash.plugins.char").state
	end)
	if flash_active and state then
		state:hide()
	else
		pcall(vim.cmd.noh)
	end
end

_G._toggle_inlayhint = function()
	local is_enabled = vim.lsp.inlay_hint.is_enabled({ bufnr = 0 })
	vim.lsp.inlay_hint.enable(not is_enabled)
	vim.notify(
		(is_enabled and "Inlay hint disabled successfully" or "Inlay hint enabled successfully"),
		vim.log.levels.INFO,
		{ title = "LSP Inlay Hint" }
	)
end

_G._toggle_virtuallines = function()
	local current = vim.diagnostic.config().virtual_lines
	vim.diagnostic.config({ virtual_lines = not current })
	vim.notify(
		"Virtual lines are now " .. (current and "hidden" or "displayed"),
		vim.log.levels.INFO,
		{ title = "LSP Diagnostic" }
	)
end

-- Статуслайн в духе heirline ramojus (без плагинов):
-- `[NOR] fname [+] | ●[E W] [servers] %= Ln:Col |  branch(+a-r~c) | (lines size)`
-- Цвета — ссылками на группы темы (следуют за сменой colorscheme сами).
local _stl_devicons = {}
local function _stl_icon(filename)
	local ok, dev = pcall(require, "nvim-web-devicons")
	if not ok then
		return ""
	end
	local icon, hl = dev.get_icon(filename, vim.fn.fnamemodify(filename, ":e"), { default = true })
	if not icon then
		return ""
	end
	if hl and not _stl_devicons[hl] then
		_stl_devicons[hl] = true
	end
	return (hl and ("%#" .. hl .. "#") or "") .. icon .. "%* "
end

local _stl_modes = {
	n = "NOR", no = "NOR", nov = "NOR", niI = "NOR", niR = "NOR", niV = "NOR",
	v = "VIS", vs = "VIS", V = "VIl", Vs = "VIS", ["\22"] = "VIb", ["\22s"] = "VIb",
	s = "SEL", S = "SEl", ["\19"] = "SEb",
	i = "INS", ic = "INS", ix = "INS",
	R = "REP", Rc = "REP", Rx = "REP", Rv = "REP", Rvc = "REP", Rvx = "REP",
	c = "CMD", cv = "CMD", r = "···", rm = "···", ["r?"] = "···", ["!"] = "···",
	t = "TER",
}
local _stl_mode_hl = {
	n = "Comment", i = "String", v = "Keyword", V = "Keyword", ["\22"] = "Keyword",
	s = "Constant", S = "Constant", ["\19"] = "Constant",
	R = "DiagnosticWarn", r = "DiagnosticWarn", c = "Type", t = "DiagnosticError",
}

local function _stl_human_size()
	local suffix = { "b", "k", "M", "G" }
	local fsize = vim.fn.getfsize(vim.api.nvim_buf_get_name(0))
	fsize = (fsize < 0 and 0) or fsize
	if fsize < 1024 then
		return fsize .. suffix[1]
	end
	local i = math.floor(math.log(fsize) / math.log(1024))
	return string.format("%.2g%s", fsize / math.pow(1024, i), suffix[i + 1])
end

_G._statusline = function()
	local ok, line = pcall(function()
		local parts = {}
		-- Режим-пилюля.
		local m = vim.api.nvim_get_mode().mode
		local m1 = m:sub(1, 1)
		local grp = _stl_mode_hl[m] or _stl_mode_hl[m1] or "Comment"
		parts[#parts + 1] = "%#" .. grp .. "# " .. (_stl_modes[m] or m) .. " %*"
		-- Файл: иконка + имя + флаги.
		local fname = vim.api.nvim_buf_get_name(0)
		if vim.bo.filetype == "netrw" then
			parts[#parts + 1] = "Files"
		elseif fname == "" then
			parts[#parts + 1] = "[No Name]"
		else
			parts[#parts + 1] = _stl_icon(fname) .. vim.fn.fnamemodify(fname, ":.")
			if vim.bo.modified then
				parts[#parts + 1] = " [+]"
			end
			if not vim.bo.modifiable or vim.bo.readonly then
				parts[#parts + 1] = "%#DiagnosticError#[-]%*"
			end
		end
		parts[#parts + 1] = "%<"
		-- Диагностика: ●[ E W I H ] (только ненулевые).
		local e = #vim.diagnostic.get(0, { severity = vim.diagnostic.severity.ERROR })
		local w = #vim.diagnostic.get(0, { severity = vim.diagnostic.severity.WARN })
		local it = #vim.diagnostic.get(0, { severity = vim.diagnostic.severity.INFO })
		local h = #vim.diagnostic.get(0, { severity = vim.diagnostic.severity.HINT })
		if e + w + it + h > 0 then
			local d = { "%#DiagnosticError#●%*" .. "[" }
			if e > 0 then
				d[#d + 1] = "%#DiagnosticError# " .. e .. "%*"
			end
			if w > 0 then
				d[#d + 1] = "%#DiagnosticWarn# " .. w .. "%*"
			end
			if it > 0 then
				d[#d + 1] = "%#DiagnosticInfo# " .. it .. "%*"
			end
			if h > 0 then
				d[#d + 1] = "%#DiagnosticHint# " .. h .. "%*"
			end
			d[#d + 1] = " ]"
			parts[#parts + 1] = " " .. table.concat(d)
		end
		-- LSP-серверы.
		local names = {}
		for _, c in ipairs(vim.lsp.get_clients({ bufnr = 0 })) do
			names[#names + 1] = c.name
		end
		if #names > 0 then
			parts[#parts + 1] = " [" .. table.concat(names, " ") .. "]"
		end
		parts[#parts + 1] = "%="
		-- Ruler + git + meta.
		parts[#parts + 1] = "%5(%l:%c%) "
		local gsd = vim.b.gitsigns_status_dict
		if gsd and gsd.head and gsd.head ~= "" then
			local g = { "  " .. gsd.head }
			local a, r, ch = gsd.added or 0, gsd.removed or 0, gsd.changed or 0
			if a + r + ch > 0 then
				local cnt = {}
				if a > 0 then
					cnt[#cnt + 1] = "+" .. a
				end
				if r > 0 then
					cnt[#cnt + 1] = "-" .. r
				end
				if ch > 0 then
					cnt[#cnt + 1] = "~" .. ch
				end
				g[#g + 1] = " (%#Comment#" .. table.concat(cnt, " ") .. "%*)"
			end
			parts[#parts + 1] = table.concat(g) .. " "
		end
		parts[#parts + 1] = "(%L " .. _stl_human_size() .. ")"
		return table.concat(parts, " ")
	end)
	if ok then
		return line
	end
	return " %f %l:%c "
end

vim.opt.statusline = "%!v:lua._statusline()"

-- Как у ramojus: перерисовывать статуслайн при смене режима.
vim.api.nvim_create_autocmd("ModeChanged", { command = "redrawstatus" })
