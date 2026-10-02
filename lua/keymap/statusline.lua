-- Статуслайн-каомодзи (без плагинов):
-- `ʕ ᵔᴥᵔ ʔ NOR fname [+] | ●[E W] [servers] %< %= Ln:Col %P | branch | (lines size)`
-- Морда зависит от режима: normal ʕ ᵔᴥᵔ ʔ, insert ʕ •ᴥ• ʔ, visual ʕ ◕ᴥ◕ ʔ,
-- select ʕ ￣ᴥ￣ ʔ, replace ʕ ºᴥº ʔ, command ʕ oᴥo ʔ, prompt ʕ ?ᴥ? ʔ, terminal ʕ >ᴥ< ʔ.
-- Цвета — ссылками на группы темы (следуют за сменой colorscheme сами).
-- PerfDefer-флаг: defer_on() дёргает settings + nvim_list_uis() — на каждый
-- redraw дорого. Кэшируем по ключу из дешёвых vim.g/vim.env проб; ключ меняется
-- только на PerfDefer toggle (defer_enable/defer_disable пишут vim.g.perf_defer),
-- тогда и пересчитываем. require кэшируется один раз сверху.
-- В статуслайне UI всегда есть, так что list_uis в ключ не входит.
local _perf_ok, _perf = pcall(require, "core.perf")
local _stl_defer_key = nil
local _stl_defer_val = false
local function _stl_defer_on()
	local key = tostring(vim.g.perf_defer)
		.. ":"
		.. tostring(vim.env.NVIM_PERF_DEFER)
		.. ":"
		.. tostring(vim.env.NVIM_DISTRO_SYNC)
	if key == _stl_defer_key then
		return _stl_defer_val
	end
	local ok = false
	if _perf_ok and _perf then
		ok = _perf.defer_on()
	end
	_stl_defer_key = key
	_stl_defer_val = ok
	return ok
end
local _stl_devicons = {}
local _stl_icon_cache = {}
local function _stl_icon(filename)
	local ext = vim.fn.fnamemodify(filename, ":e")
	local cached = _stl_icon_cache[ext]
	if cached then
		return cached
	end
	local ok, dev = pcall(require, "nvim-web-devicons")
	if not ok then
		_stl_icon_cache[ext] = ""
		return ""
	end
	local icon, hl = dev.get_icon(filename, ext, { default = true })
	if not icon then
		_stl_icon_cache[ext] = ""
		return ""
	end
	if hl and not _stl_devicons[hl] then
		_stl_devicons[hl] = true
	end
	local out = (hl and ("%#" .. hl .. "#") or "") .. icon .. "%* "
	_stl_icon_cache[ext] = out
	return out
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
-- Каомодзи-морда на режим. Ключи — точные значения mode(), фолбэк по первой
-- букве там же, где выбирается цвет (ниже). Только литералы: на redraw ни
-- одного вызова, одна табличная подстановка.
local _stl_faces = {
	n = "ʕ ᵔᴥᵔ ʔ", no = "ʕ ᵔᴥᵔ ʔ", nov = "ʕ ᵔᴥᵔ ʔ", niI = "ʕ ᵔᴥᵔ ʔ", niR = "ʕ ᵔᴥᵔ ʔ", niV = "ʕ ᵔᴥᵔ ʔ",
	v = "ʕ ◕ᴥ◕ ʔ", vs = "ʕ ◕ᴥ◕ ʔ", V = "ʕ ◕ᴥ◕ ʔ", Vs = "ʕ ◕ᴥ◕ ʔ", ["\22"] = "ʕ ◕ᴥ◕ ʔ", ["\22s"] = "ʕ ◕ᴥ◕ ʔ",
	s = "ʕ ￣ᴥ￣ ʔ", S = "ʕ ￣ᴥ￣ ʔ", ["\19"] = "ʕ ￣ᴥ￣ ʔ",
	i = "ʕ •ᴥ• ʔ", ic = "ʕ •ᴥ• ʔ", ix = "ʕ •ᴥ• ʔ",
	R = "ʕ ºᴥº ʔ", Rc = "ʕ ºᴥº ʔ", Rx = "ʕ ºᴥº ʔ", Rv = "ʕ ºᴥº ʔ", Rvc = "ʕ ºᴥº ʔ", Rvx = "ʕ ºᴥº ʔ",
	c = "ʕ oᴥo ʔ", cv = "ʕ oᴥo ʔ",
	r = "ʕ ?ᴥ? ʔ", rm = "ʕ ?ᴥ? ʔ", ["r?"] = "ʕ ?ᴥ? ʔ", ["!"] = "ʕ ?ᴥ? ʔ",
	t = "ʕ >ᴥ< ʔ",
}
-- Свои группы в палитре khold (чёрный металл: серые + тёмно-красный + teal),
-- жирным — бар «больше» визуально (высоту строки Neovim не меняет, поэтому
-- крупность даём жирностью, блоками-разделителями и паддингами).
-- fg-only (bg=NONE наследует StatusLine): переживает любой тёмный фон.
-- :colorscheme сносит кастомные группы — переопределяем на каждом ColorScheme.
local _stl_khold = {
	-- Сдержанный fg-стиль под black-metal: бар остаётся чёрным (фон темы),
	-- цвет — только акценты текстом. Режимы — приглушёнными khold-тонами:
	-- NOR/TER — teal, INS — бумага, VIS — тёмно-красный, REP — красный,
	-- CMD — серебро, SEL/prompt — серые. Жирным — только пилюля режима.
	StlMN = { fg = "#5f8787", bold = true },
	StlMI = { fg = "#c1c1c1", bold = true },
	StlMV = { fg = "#974b46", bold = true },
	StlMS = { fg = "#888888", bold = true },
	StlMR = { fg = "#af3a3a", bold = true },
	StlMC = { fg = "#aaaaaa", bold = true },
	StlMT = { fg = "#5f8787", bold = true },
	StlMP = { fg = "#666666", bold = true },
	StlFile = { fg = "#c1c1c1" },
	StlMeta = { fg = "#666666" },
	StlDim = { fg = "#888888" },
	StlSep = { fg = "#2a2a2a" },
}
local function _stl_apply_hl()
	for grp, spec in pairs(_stl_khold) do
		pcall(vim.api.nvim_set_hl, 0, grp, spec)
	end
end
-- Глобально: тема black-metal в apply_custom_body делает свой load() (hi clear
-- БЕЗ события ColorScheme) — она же и зовёт это обратно в конце кастома.
-- Иначе Stl* бута применяются, сносятся темой и остаются cleared навсегда
-- (диагноз 2026-10-02: `:hi StlModeN` → cleared, бар монохромный).
_G._stl_apply_hl = _stl_apply_hl
_stl_apply_hl()
local _stl_mode_hl = {
	n = "StlMN", i = "StlMI", v = "StlMV", V = "StlMV", ["\22"] = "StlMV",
	s = "StlMS", S = "StlMS", ["\19"] = "StlMS",
	R = "StlMR", r = "StlMR", c = "StlMC", t = "StlMT",
}

local _stl_size_cache = {}
local _stl_lsp_cache = {}
local _stl_git_cache = {}
-- Счётчики диагностик: единственный дорогой кусок статуслайна (был get() на redraw).
-- Обновляется по DiagnosticChanged, на redraw только читается.
local _stl_diag_cache = {}

-- Нормализация bufnr: callers historically pass 0 (= current), but caches and
-- invalidations must key on the REAL buffer id, otherwise entries never clear.
local function _stl_buf(bufnr)
	if not bufnr or bufnr == 0 then
		return vim.api.nvim_get_current_buf()
	end
	return bufnr
end

local function _stl_count_diags(bufnr)
	local e, w, it, h = 0, 0, 0, 0
	for _, d in ipairs(vim.diagnostic.get(bufnr)) do
		if d.severity == vim.diagnostic.severity.ERROR then
			e = e + 1
		elseif d.severity == vim.diagnostic.severity.WARN then
			w = w + 1
		elseif d.severity == vim.diagnostic.severity.INFO then
			it = it + 1
		elseif d.severity == vim.diagnostic.severity.HINT then
			h = h + 1
		end
	end
	return { e, w, it, h }
end

local function _stl_human_size()
	local bufname = vim.api.nvim_buf_get_name(0)
	-- Кэш на BufEnter/BufWritePost: getfsize = stat syscall на каждый redraw.
	local tick = (vim.b.stl_size_tick or 0)
	local key = bufname .. ":" .. tick
	local cached = _stl_size_cache[key]
	if cached then
		return cached
	end
	local suffix = { "b", "k", "M", "G" }
	local fsize = vim.fn.getfsize(bufname)
	fsize = (fsize < 0 and 0) or fsize
	local out
	if fsize < 1024 then
		out = fsize .. suffix[1]
	else
		local i = math.floor(math.log(fsize) / math.log(1024))
		-- %g давал экспоненту ("2.3e+02k" на 6002-строчном go): фиксированный
		-- формат с отрезанием ".0".
		out = string.format("%.1f", fsize / math.pow(1024, i)):gsub("%.0$", "") .. suffix[i + 1]
	end
	-- держим кэш маленьким: счётчик вместо pairs-подсчёта
	-- на каждом redraw + эвикция одной записи вместо сноса таблицы.
	if _stl_size_cache[key] == nil then
		_stl_size_n = (_stl_size_n or 0) + 1
	end
	_stl_size_cache[key] = out
	if (_stl_size_n or 0) > 64 then
		local drop = next(_stl_size_cache)
		if drop ~= nil then
			_stl_size_cache[drop] = nil
			_stl_size_n = _stl_size_n - 1
		end
	end
	return out
end

local function _stl_get_lsp_names(bufnr)
	bufnr = _stl_buf(bufnr)
	local cached = _stl_lsp_cache[bufnr]
	if cached then
		return cached
	end
	local names = {}
	for _, c in ipairs(vim.lsp.get_clients({ bufnr = bufnr })) do
		names[#names + 1] = c.name
	end
	_stl_lsp_cache[bufnr] = names
	return names
end

local function _stl_get_git_status(bufnr)
	bufnr = _stl_buf(bufnr)
	local cached = _stl_git_cache[bufnr]
	if cached then
		return cached
	end
	local gsd = vim.b[bufnr].gitsigns_status_dict
	if not (gsd and gsd.head and gsd.head ~= "") then
		_stl_git_cache[bufnr] = nil
		return nil
	end
	local g = { "  " .. gsd.head }
	local a, r, ch = gsd.added or 0, gsd.removed or 0, gsd.changed or 0
	if a + r + ch > 0 then
		local cnt = {}
		if a > 0 then cnt[#cnt + 1] = "+" .. a end
		if r > 0 then cnt[#cnt + 1] = "-" .. r end
		if ch > 0 then cnt[#cnt + 1] = "~" .. ch end
		g[#g + 1] = " (%#Comment#" .. table.concat(cnt, " ") .. "%*)"
	end
	local result = table.concat(g) .. " "
	_stl_git_cache[bufnr] = result
	return result
end

-- Инвалидация кэшей.
local _stl_augroup = vim.api.nvim_create_augroup("StlCache", { clear = true })
pcall(vim.api.nvim_create_autocmd, { "BufEnter", "BufWritePost" }, {
	group = _stl_augroup,
	callback = function()
		vim.b.stl_size_tick = (vim.b.stl_size_tick or 0) + 1
	end,
})
pcall(vim.api.nvim_create_autocmd, { "LspAttach", "LspDetach" }, {
	group = _stl_augroup,
	callback = function(args)
		_stl_lsp_cache[args.buf] = nil
	end,
})
pcall(vim.api.nvim_create_autocmd, { "BufWritePost", "FocusGained", "BufEnter", "CursorHold" }, {
	group = _stl_augroup,
	callback = function(args)
		_stl_git_cache[args.buf] = nil
	end,
})
pcall(vim.api.nvim_create_autocmd, "DiagnosticChanged", {
	group = _stl_augroup,
	callback = function(args)
		_stl_diag_cache[args.buf] = _stl_count_diags(args.buf)
	end,
})
pcall(vim.api.nvim_create_autocmd, { "BufWipeout", "BufDelete" }, {
	group = _stl_augroup,
	callback = function(args)
		_stl_lsp_cache[args.buf] = nil
		_stl_git_cache[args.buf] = nil
		_stl_diag_cache[args.buf] = nil
	end,
})

_G._statusline = function()
	local ok, line = pcall(function()
		local parts = {}
		-- Режим-пилюля: морда + код. Морда — по точному режиму, фолбэк по
		-- первой букве (как у цвета): неизвестный режим не роняет пилюлю.
		local m = vim.api.nvim_get_mode().mode
		local m1 = m:sub(1, 1)
		local grp = _stl_mode_hl[m] or _stl_mode_hl[m1] or "StlMN"
		local face = _stl_faces[m] or "ʕ ᵔᴥᵔ ʔ"
		-- Пилюля: цветной чип-столбик + морда + код, всё в цвете режима.
		-- Никаких фоновых блоков — бар чёрный, как любит black-metal.
		parts[#parts + 1] = "%#" .. grp .. "#▊ " .. face .. " " .. (_stl_modes[m] or m) .. " %*%#StlSep#│%*"
		-- Запись макроса: reg_recording() — дешёвый C-вызов, на redraw можно.
		local rec = vim.fn.reg_recording()
		if rec ~= "" then
			parts[#parts + 1] = " " .. "%#DiagnosticError#●REC @" .. rec .. "%*"
		end
		-- Файл: иконка + имя + флаги.
		local fname = vim.api.nvim_buf_get_name(0)
		if vim.bo.filetype == "netrw" then
			parts[#parts + 1] = "Files"
		elseif fname == "" then
			parts[#parts + 1] = "[No Name]"
		else
			local icon = _stl_icon(fname)
			if icon == "" then
				-- devicons молчит (неизвестное расширение): показываем filetype,
				-- иначе сегмент немой.
				local ft = vim.bo.filetype
				if ft ~= "" then
					icon = "[" .. ft .. "] "
				end
			end
			parts[#parts + 1] = icon .. "%#StlFile#" .. vim.fn.fnamemodify(fname, ":.") .. "%*"
			if vim.bo.modified then
				parts[#parts + 1] = " [+]"
			end
			if not vim.bo.modifiable or vim.bo.readonly then
				parts[#parts + 1] = "%#DiagnosticError#[-]%*"
			end
			-- Только нестандарт: spell, не-utf8, не-unix. Пустой буфер молчит.
			if vim.wo.spell then
				parts[#parts + 1] = " [SPELL]"
			end
			local fe = vim.bo.fileencoding
			if fe ~= "" and fe ~= "utf-8" then
				parts[#parts + 1] = " [" .. fe .. "]"
			end
			if vim.bo.fileformat ~= "unix" then
				parts[#parts + 1] = " [" .. vim.bo.fileformat .. "]"
			end
		end
		-- Диагностика: читаем кэш DiagnosticChanged (никаких get() на redraw).
		-- TURBO (T6): на промахе кэша fallback get() пропускаем и кладём нули.
		-- Кэшируем: DiagnosticChanged для буфера БЕЗ диагностики не приходит,
		-- так что без записи кэша баг-буфер светился бы «чистым» до
		-- следующего публикующего события.
		local bufnr = vim.api.nvim_get_current_buf()
		local dc = _stl_diag_cache[bufnr]
		if not dc then
			if _stl_defer_on() then
				dc = { 0, 0, 0, 0 }
				_stl_diag_cache[bufnr] = dc
			else
				dc = _stl_count_diags(bufnr)
				_stl_diag_cache[bufnr] = dc
			end
		end
		local e, w, it, h = dc[1], dc[2], dc[3], dc[4]
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
		-- LSP-серверы (cached).
		local names = _stl_get_lsp_names(0)
		if #names > 0 then
			parts[#parts + 1] = " [" .. table.concat(names, " ") .. "]"
		end
		-- Truncation point — ПОСЛЕ серверов: раньше голый %< перед длинным
		-- путём съедал "[lua_ls]" до "<ua_ls]".
		parts[#parts + 1] = "%<"
		parts[#parts + 1] = "%="
		-- Ruler + git (cached) + meta. Ruler и мета — правым тёмным блоком,
		-- %P бесплатен (считает сам статуслайн).
		parts[#parts + 1] = "%#StlMeta# %5(%l:%c%) %P "
		local git_status = _stl_get_git_status(0)
		if git_status then
			parts[#parts + 1] = git_status
		end
		parts[#parts + 1] = "%#StlMeta#(%L " .. _stl_human_size() .. ") %*"
		return table.concat(parts, " ")
	end)
	if ok then
		return line
	end
	return " %f %l:%c "
end

vim.opt.statusline = "%!v:lua._statusline()"

-- Как у ramojus: перерисовывать статуслайн при смене режима.
vim.api.nvim_create_autocmd("ModeChanged", { group = _stl_augroup, command = "redrawstatus" })
-- :colorscheme сносит кастомные группы (включая Stl*): реаплай.
pcall(vim.api.nvim_create_autocmd, "ColorScheme", {
	group = _stl_augroup,
	callback = function()
		_stl_apply_hl()
	end,
})
