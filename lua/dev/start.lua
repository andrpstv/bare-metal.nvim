-- dev.start — стартовый экран при голом `nvim`: ASCII-логотип, время старта, ключи.
--
-- Почему свой: dashboard-плагины (alpha, dashboard-nvim) — это плагин на старте ради
-- одного экрана; здесь ~200 строк в scratch-буфере. Логотип «проявляется» из шума
-- рампы dev.fx, затем с букв стекают капли — ~0.8с, потом таймера нет. Модуль
-- грузится только из VimEnter при голом старте с UI (core/init.lua).

local M = {}

local fx = require("dev.fx")

-- figlet standard, «bare-metal».
M.LOGO = {
	[[ _                                         _        _ ]],
	[[| |__   __ _ _ __ ___       _ __ ___   ___| |_ __ _| |]],
	[[| '_ \ / _` | '__/ _ \_____| '_ ` _ \ / _ \ __/ _` | |]],
	[[| |_) | (_| | | |  __/_____| | | | | |  __/ || (_| | |]],
	[[|_.__/ \__,_|_|  \___|     |_| |_| |_|\___|\__\__,_|_|]],
}
local LOGO_W = #M.LOGO[1]
-- Капли под нижней строкой логотипа: { колонка (0-based), длина }.
M.DRIPS = { { 0, 2 }, { 12, 1 }, { 21, 3 }, { 31, 1 }, { 37, 2 }, { 51, 1 }, { 53, 3 } }
local DRIP_ROWS = 3
M.DECRYPT_FRAMES = 14
M.FRAMES = M.DECRYPT_FRAMES + DRIP_ROWS
local FRAME_MS = 45
-- Цель «холодный старт пустого» из docs/distro/11-speed-program.md. Меряем от init.lua
-- до VimEnter — это меньше полного времени процесса, так что красное значит «точно мимо».
local SLO_MS = 60

M.ITEMS = {
	{ key = "e", label = "new file", run = function() vim.cmd("enew") end },
	{ key = "f", label = "find file", run = function() _G._pick("files") end },
	{ key = "r", label = "recent files", run = function() _G._pick_extra("oldfiles") end },
	{ key = "p", label = "projects", run = function() require("dev.project").switch() end },
	{ key = "s", label = "restore session", session = true, run = function() require("dev.project").load() end },
	{ key = "t", label = "tutor", run = function() vim.cmd("Tutor") end },
	{ key = "q", label = "quit", run = function() vim.cmd("qa") end },
}

-- Группы статуслайна (палитра khold): тема после своего hi clear без события
-- ColorScheme переустанавливает их сама (_G._stl_apply_hl), свои бы слетели.
local HL = {
	logo = "StlMI",
	noise = "StlMV",
	drip = "StlMR",
	key = "StlMR",
	label = "StlDim",
	meta = "StlMeta",
	fast = "StlMT",
	slow = "StlMR",
}

local function drip_char(k, len)
	if k < len then
		return k == 1 and "|" or ":"
	end
	return len == 1 and "'" or "."
end

--- Кадр, на котором символ логотипа «проявится»: случайный, пробелы — сразу.
---@param rand fun(m: integer, n: integer): integer
function M.settle_map(rand)
	local map = {}
	for r, line in ipairs(M.LOGO) do
		map[r] = {}
		for c = 1, #line do
			map[r][c] = line:sub(c, c) == " " and 0 or rand(2, M.DECRYPT_FRAMES)
		end
	end
	return map
end

--- Чистая раскладка кадра: строки, подсветки { row, col_start, col_end, group } (байты),
--- строка курсора. frame > M.FRAMES — финальный статичный вид.
---@param width integer
---@param height integer
---@param info {project: string, version: string, ms: number, session: boolean}
---@param frame integer
---@param settle table<integer, table<integer, integer>>
---@param rand fun(m: integer, n: integer): integer
function M.render(width, height, info, frame, settle, rand)
	local lines, hls = {}, {}
	local items = {}
	for _, it in ipairs(M.ITEMS) do
		if not it.session or info.session then
			items[#items + 1] = it
		end
	end
	local menu_rows = math.ceil(#items / 2)
	local logo_rows = #M.LOGO + DRIP_ROWS + 1
	-- Узкое или низкое окно: без логотипа, только строка медведя и меню.
	local with_logo = width >= LOGO_W + 4 and height >= logo_rows + 2 + menu_rows + 2
	local total = (with_logo and logo_rows or 0) + 2 + menu_rows
	for _ = 1, math.max(0, math.floor((height - total) / 2)) do
		lines[#lines + 1] = ""
	end
	local pad = string.rep(" ", math.max(0, math.floor((width - LOGO_W) / 2)))

	local function add_runs(text, groups)
		-- groups[i] — группа i-го байта; склеиваем соседние одинаковые в один extmark.
		local row = #lines
		lines[#lines + 1] = pad .. text
		local s = 1
		for i = 2, #text + 1 do
			if groups[i] ~= groups[s] then
				if groups[s] then
					hls[#hls + 1] = { row, #pad + s - 1, #pad + i - 1, groups[s] }
				end
				s = i
			end
		end
	end

	if with_logo then
		local noise = fx.RAMP
		for r, line in ipairs(M.LOGO) do
			local out, groups = {}, {}
			for c = 1, #line do
				local ch = line:sub(c, c)
				if ch == " " then
					out[c] = " "
				elseif frame >= settle[r][c] then
					out[c], groups[c] = ch, HL.logo
				else
					local k = rand(2, #noise)
					out[c], groups[c] = noise:sub(k, k), HL.noise
				end
			end
			add_runs(table.concat(out), groups)
		end
		local grown = math.max(0, frame - M.DECRYPT_FRAMES)
		for k = 1, DRIP_ROWS do
			local out, groups = {}, {}
			for c = 1, LOGO_W do
				out[c] = " "
			end
			for _, d in ipairs(M.DRIPS) do
				local col, len = d[1] + 1, d[2]
				if k <= len and k <= grown then
					out[col], groups[col] = drip_char(k, len), HL.drip
				end
			end
			add_runs((table.concat(out):gsub("%s+$", "")), groups)
		end
		lines[#lines + 1] = ""
	end

	-- Строка медведя: морда · проект · версия · время старта.
	local face = "ʕ ᵔᴥᵔ ʔ"
	local meta = "  " .. info.project .. " · nvim " .. info.version .. " · ready in "
	local ms = string.format("%d ms", math.floor(info.ms + 0.5))
	local text = face .. meta .. ms
	local tpad = string.rep(" ", math.max(0, math.floor((width - vim.api.nvim_strwidth(text)) / 2)))
	local row = #lines
	lines[#lines + 1] = tpad .. text
	hls[#hls + 1] = { row, #tpad, #tpad + #face, HL.logo }
	hls[#hls + 1] = { row, #tpad + #face, #tpad + #face + #meta, HL.meta }
	hls[#hls + 1] = { row, #tpad + #face + #meta, #tpad + #text, info.ms <= SLO_MS and HL.fast or HL.slow }
	lines[#lines + 1] = ""

	-- Меню в две колонки по ширине логотипа.
	local col_w = math.floor(LOGO_W / 2)
	local cursor_row
	for i = 1, #items, 2 do
		local line, mrow = "", #lines
		for j = i, math.min(i + 1, #items) do
			local it = items[j]
			local cell = "[" .. it.key .. "]  " .. it.label
			local start = #pad + #line
			hls[#hls + 1] = { mrow, start, start + 3, HL.key }
			hls[#hls + 1] = { mrow, start + 3, start + #cell, HL.label }
			line = line .. cell .. (j == i and string.rep(" ", col_w - #cell) or "")
		end
		cursor_row = cursor_row or mrow
		lines[#lines + 1] = pad .. line
	end
	return lines, hls, cursor_row, #pad + 1
end

local ns = vim.api.nvim_create_namespace("dev_start")
local state = nil -- { buf, win, info, settle, stop }

local function paint(frame)
	local s = state
	if not s or not vim.api.nvim_buf_is_valid(s.buf) or not vim.api.nvim_win_is_valid(s.win) then
		return false
	end
	if vim.api.nvim_win_get_buf(s.win) ~= s.buf then
		return false
	end
	local w, h = vim.api.nvim_win_get_width(s.win), vim.api.nvim_win_get_height(s.win)
	local lines, hls, crow, ccol = M.render(w, h, s.info, frame, s.settle, math.random)
	vim.bo[s.buf].modifiable = true
	vim.api.nvim_buf_set_lines(s.buf, 0, -1, false, lines)
	vim.bo[s.buf].modifiable = false
	vim.api.nvim_buf_clear_namespace(s.buf, ns, 0, -1)
	for _, hl in ipairs(hls) do
		vim.api.nvim_buf_set_extmark(s.buf, ns, hl[1], hl[2], { end_col = hl[3], hl_group = hl[4] })
	end
	-- Курсор всегда на первом пункте: после ресайза строки сдвигаются.
	if crow then
		pcall(vim.api.nvim_win_set_cursor, s.win, { crow + 1, ccol })
	end
	return true
end

local function stop_anim()
	if state and state.stop then
		state.stop()
		state.stop = nil
	end
end

-- Оборвать анимацию на финальном кадре: иначе после отмены пикера логотип остался бы шумом.
local function finish()
	stop_anim()
	paint(M.FRAMES + 1)
end

--- Показать стартовый экран в текущем окне вместо пустого буфера.
function M.open()
	local win = vim.api.nvim_get_current_win()
	local old = vim.api.nvim_win_get_buf(win)
	local buf = vim.api.nvim_create_buf(false, true)
	vim.bo[buf].bufhidden = "wipe"
	vim.bo[buf].filetype = "bmstart"
	vim.api.nvim_win_set_buf(win, buf)
	-- setlocal: следующий буфер в этом окне получит глобальные значения.
	for opt, val in pairs({
		number = false,
		relativenumber = false,
		list = false,
		signcolumn = "no",
		cursorline = false,
		foldcolumn = "0",
		colorcolumn = "",
		statuscolumn = "",
		spell = false,
		wrap = false,
	}) do
		vim.api.nvim_set_option_value(opt, val, { scope = "local", win = win })
	end
	-- Пустой буфер старта больше не нужен: иначе он висит в :ls безымянным.
	if old ~= buf and vim.api.nvim_buf_get_name(old) == "" and not vim.bo[old].modified then
		pcall(vim.api.nvim_buf_delete, old, {})
	end

	local proj_ok, proj = pcall(require, "dev.project")
	local root = proj_ok and proj.root() or vim.fn.getcwd()
	local v = vim.version()
	local started = vim.g.start_time and vim.fn.reltimefloat(vim.fn.reltime(vim.g.start_time)) * 1000 or 0
	state = {
		buf = buf,
		win = win,
		settle = M.settle_map(math.random),
		info = {
			project = vim.fs.basename(root),
			version = string.format("%d.%d.%d", v.major, v.minor, v.patch),
			ms = started,
			session = proj_ok and vim.fn.filereadable(proj.session_file(root)) == 1,
		},
	}

	for _, it in ipairs(M.ITEMS) do
		if not it.session or state.info.session then
			vim.keymap.set("n", it.key, function()
				finish()
				it.run()
			end, { buffer = buf, nowait = true, silent = true, desc = "start: " .. it.label })
		end
	end

	local grp = vim.api.nvim_create_augroup("DevStart", { clear = true })
	vim.api.nvim_create_autocmd({ "VimResized", "WinResized" }, {
		group = grp,
		desc = "start: re-center the start screen",
		callback = finish,
	})
	vim.api.nvim_create_autocmd("BufWipeout", {
		group = grp,
		buffer = buf,
		desc = "start: drop state with the buffer",
		callback = function()
			stop_anim()
			state = nil
			pcall(vim.api.nvim_del_augroup_by_id, grp)
		end,
	})

	if not fx.enabled() then
		paint(M.FRAMES + 1)
		return
	end
	paint(1)
	state.stop = fx.ticker(FRAME_MS, function(i)
		if i > M.FRAMES then
			return false
		end
		return paint(i + 1)
	end)
end

return M
