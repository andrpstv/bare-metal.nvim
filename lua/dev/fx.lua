-- dev.fx — ASCII-анимации интерфейса: тикер кадров, рампа плотности, след внешних правок.
--
-- Почему свой: анимационные плагины (mini.animate, smear-cursor) двигают курсор и
-- скролл и тикают постоянно, а нам нужны короткие разовые эффекты. Таймер живёт
-- ровно столько кадров, сколько длится эффект, потом закрывается — в простое ноль работы.
-- Анимации выключаются settings.ui_animations = false (reduced motion): эффекты
-- остаются статичными, информация не теряется.

local M = {}

--- ASCII-рампа плотности, от пустого к плотному: шум стартового экрана и затухание следа.
M.RAMP = " .:-=+*#%@"

--- Движение разрешено: живой UI (headless — детерминизм тестов) и настройка.
function M.enabled()
	if #vim.api.nvim_list_uis() == 0 then
		return false
	end
	return require("core.settings").ui_animations ~= false
end

--- Кадры по таймеру: fn(i) на i-м кадре (с 1); вернул false или упал — стоп.
--- Возвращает stop(); после стопа таймер закрыт.
---@param ms integer
---@param fn fun(i: integer): boolean?
---@return fun()
function M.ticker(ms, fn)
	local timer = vim.uv.new_timer()
	local i = 0
	local function stop()
		if timer then
			local t = timer
			timer = nil
			t:stop()
			t:close()
		end
	end
	if not timer then
		return stop
	end
	timer:start(
		0,
		ms,
		vim.schedule_wrap(function()
			if not timer then
				return
			end
			i = i + 1
			local ok, more = pcall(fn, i)
			if not ok or more == false then
				stop()
			end
		end)
	)
	return stop
end

-- След: больше строк не красим — переписанный целиком файл выглядит так же, а кадр дешевле.
local TRAIL_MAX_ROWS = 1000
local TRAIL_MS = 110
-- Кадр следа: знак в колонке спускается по рампе, фон строки гаснет от красного khold к чёрному.
local TRAIL = {
	{ "@", 1 }, { "@", 1 }, { "#", 1 }, { "*", 2 }, { "+", 2 }, { "=", 3 }, { "-", 3 }, { ":", 4 }, { ".", 4 },
}
local TRAIL_HL = {
	{ line = "#4f1a1a", sign = "#af3a3a" },
	{ line = "#351111", sign = "#974b46" },
	{ line = "#200a0a", sign = "#5a2a28" },
	{ line = "#0e0505", sign = "#2d1514" },
}
local trail_ns = vim.api.nvim_create_namespace("dev_fx_trail")
local trail_stop = {} -- bufnr -> stop() текущего следа
local trail_gen = {} -- bufnr -> номер следа: отложенная очистка не стирает следующий

--- Строки (0-based) нового текста, которые задела внешняя правка. Чистая — для тестов.
--- Удаление помечает строку, после которой оно случилось.
---@param before string[]
---@param after string[]
---@return integer[]
function M.changed_rows(before, after)
	local hunks = vim.text.diff(table.concat(before, "\n") .. "\n", table.concat(after, "\n") .. "\n", {
		result_type = "indices",
	})
	local rows = {}
	for _, h in ipairs(hunks) do
		local start, count = h[3], h[4]
		if count == 0 then
			rows[#rows + 1] = math.max(start, 1) - 1
		else
			for r = start, math.min(start + count, start + TRAIL_MAX_ROWS - #rows) - 1 do
				rows[#rows + 1] = r - 1
			end
		end
		if #rows >= TRAIL_MAX_ROWS then
			break
		end
	end
	return rows
end

local function clear_trail(buf)
	if trail_stop[buf] then
		trail_stop[buf]()
		trail_stop[buf] = nil
	end
	if vim.api.nvim_buf_is_valid(buf) then
		vim.api.nvim_buf_clear_namespace(buf, trail_ns, 0, -1)
	end
end

local beacon_ns = vim.api.nvim_create_namespace("dev_fx_beacon")
local beacon_colors = { "#3a1a18", "#24100f", "#140808" }

--- Вспышка строки при дальном прыжке: линия гаснет из красного в чёрное за ~250ms.
---@param win integer
function M.beacon(win)
	-- reduced motion: вспышка — чистое украшение, информации в ней нет; без анимаций её нет вовсе.
	if not M.enabled() or not vim.api.nvim_win_is_valid(win) then
		return
	end
	local buf = vim.api.nvim_win_get_buf(win)
	if not vim.api.nvim_buf_is_valid(buf) then
		return
	end
	local row = (vim.api.nvim_win_get_cursor(win))[1] - 1

	-- Создаём highlight группы (один раз)
	for i, color in ipairs(beacon_colors) do
		vim.api.nvim_set_hl(0, "FxBeacon" .. i, { bg = color })
	end

	-- Очищаем старые маркеры в этом окне
	vim.api.nvim_buf_clear_namespace(buf, beacon_ns, 0, -1)

	-- Создаём extmark на первом шаге
	vim.api.nvim_buf_set_extmark(buf, beacon_ns, row, 0, {
		line_hl_group = "FxBeacon1",
		priority = 10,
	})

	-- Анимируем затухание через шаги
	M.ticker(85, function(i)
		if not vim.api.nvim_buf_is_valid(buf) or not vim.api.nvim_win_is_valid(win) then
			return false
		end
		vim.api.nvim_buf_clear_namespace(buf, beacon_ns, 0, -1)
		if i <= #beacon_colors then
			vim.api.nvim_buf_set_extmark(buf, beacon_ns, row, 0, {
				line_hl_group = "FxBeacon" .. i,
				priority = 10,
			})
			return true
		end
		return false
	end)
end

--- След внешней правки: изменённые строки вспыхивают и гаснут за ~1с.
--- Без анимаций — статичная подсветка на 1.5с. Возвращает затронутые строки (0-based).
---@param buf integer
---@param before string[] текст буфера до перезагрузки
---@return integer[]
function M.trail(buf, before)
	if not vim.api.nvim_buf_is_valid(buf) then
		return {}
	end
	local rows = M.changed_rows(before, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
	if #rows == 0 then
		return rows
	end
	for i, c in ipairs(TRAIL_HL) do
		vim.api.nvim_set_hl(0, "FxTrail" .. i, { bg = c.line })
		vim.api.nvim_set_hl(0, "FxTrailSign" .. i, { fg = c.sign, bg = c.line, bold = true })
	end
	clear_trail(buf)
	trail_gen[buf] = (trail_gen[buf] or 0) + 1
	local gen = trail_gen[buf]
	local function paint(frame)
		local sign, level = frame[1], frame[2]
		local n = vim.api.nvim_buf_line_count(buf)
		vim.api.nvim_buf_clear_namespace(buf, trail_ns, 0, -1)
		for _, r in ipairs(rows) do
			if r < n then
				-- priority выше gitsigns (6): на время следа знак правки агента поверх.
				vim.api.nvim_buf_set_extmark(buf, trail_ns, r, 0, {
					line_hl_group = "FxTrail" .. level,
					sign_text = sign,
					sign_hl_group = "FxTrailSign" .. level,
					priority = 20,
				})
			end
		end
	end
	pcall(function()
		require("dev.bear").wow()
	end)
	if not M.enabled() then
		paint(TRAIL[1])
		vim.defer_fn(function()
			if trail_gen[buf] == gen then
				clear_trail(buf)
			end
		end, 1500)
		return rows
	end
	trail_stop[buf] = M.ticker(TRAIL_MS, function(i)
		if not vim.api.nvim_buf_is_valid(buf) or i > #TRAIL then
			trail_stop[buf] = nil
			clear_trail(buf)
			return false
		end
		paint(TRAIL[i])
	end)
	return rows
end

local flash_ns = vim.api.nvim_create_namespace("dev_fx_flash")
local flash_stop = {} -- bufnr -> stop() текущей вспышки

--- Вспышка строк: затухание за ≤400ms с цветами из TRAIL_HL (как M.trail).
--- Без анимаций — статичная подсветка 400ms. Кэпит 200 строк, пропускает large_file.
---@param buf integer
---@param srow integer 0-based inclusive
---@param erow integer 0-based inclusive
function M.flash_rows(buf, srow, erow)
	if not vim.api.nvim_buf_is_valid(buf) or vim.b[buf].large_file then
		return
	end
	if srow < 0 or erow < srow then
		return
	end
	-- Очищаем старую вспышку в буфере
	if flash_stop[buf] then
		flash_stop[buf]()
		flash_stop[buf] = nil
	end
	if vim.api.nvim_buf_is_valid(buf) then
		vim.api.nvim_buf_clear_namespace(buf, flash_ns, 0, -1)
	end
	-- Кэпим на 200 строк
	local count = math.min(erow - srow + 1, 200)
	if count <= 0 then
		return
	end
	-- Подготавливаем группы из TRAIL_HL
	for i, c in ipairs(TRAIL_HL) do
		vim.api.nvim_set_hl(0, "FxFlash" .. i, { bg = c.line })
	end
	if not M.enabled() then
		-- Статичная подсветка: первый уровень, потом очистка
		local n = vim.api.nvim_buf_line_count(buf)
		vim.api.nvim_buf_clear_namespace(buf, flash_ns, 0, -1)
		for r = srow, math.min(erow, n - 1) do
			vim.api.nvim_buf_set_extmark(buf, flash_ns, r, 0, {
				line_hl_group = "FxFlash1",
				priority = 10,
			})
		end
		vim.defer_fn(function()
			if vim.api.nvim_buf_is_valid(buf) then
				vim.api.nvim_buf_clear_namespace(buf, flash_ns, 0, -1)
			end
		end, 400)
		return
	end
	-- Анимированная вспышка: 3 шага по ~130ms
	local steps = { { level = 1 }, { level = 2 }, { level = 3 } }
	flash_stop[buf] = M.ticker(130, function(i)
		if not vim.api.nvim_buf_is_valid(buf) then
			flash_stop[buf] = nil
			return false
		end
		if i <= #steps then
			local level = steps[i].level
			local n = vim.api.nvim_buf_line_count(buf)
			vim.api.nvim_buf_clear_namespace(buf, flash_ns, 0, -1)
			for r = srow, math.min(erow, n - 1) do
				vim.api.nvim_buf_set_extmark(buf, flash_ns, r, 0, {
					line_hl_group = "FxFlash" .. level,
					priority = 10,
				})
			end
			return true
		end
		flash_stop[buf] = nil
		vim.api.nvim_buf_clear_namespace(buf, flash_ns, 0, -1)
		return false
	end)
end

local badge_ns = vim.api.nvim_create_namespace("dev_fx_badge")
-- Одна живая метка на редактор: новая гасит прежнюю целиком (иначе при быстрых ]q старые
-- таймеры дорисовывали свои метки на прошлых строках и те залипали).
local badge = { stop = nil, buf = nil, gen = 0 }

local function badge_clear()
	if badge.stop then
		badge.stop()
		badge.stop = nil
	end
	if badge.buf and vim.api.nvim_buf_is_valid(badge.buf) then
		vim.api.nvim_buf_clear_namespace(badge.buf, badge_ns, 0, -1)
	end
end

--- Значок у курсора: virt_text в конце строки, гаснет за ~1с; без анимаций — статично 1.5с.
---@param win integer 0 — текущее окно
---@param chunks string|(string|string[])[] строки или пары {text, hl}; hl вида FxBadgeN угасают на ступень за кадр
function M.badge(win, chunks)
	win = win == 0 and vim.api.nvim_get_current_win() or win
	if not vim.api.nvim_win_is_valid(win) then
		return
	end
	badge_clear()
	vim.api.nvim_set_hl(0, "FxBadge1", { fg = "#eceee3" })
	vim.api.nvim_set_hl(0, "FxBadge2", { fg = "#888888" })
	vim.api.nvim_set_hl(0, "FxBadge3", { fg = "#3a3a3a" })
	local norm = {}
	for _, c in ipairs(type(chunks) == "string" and { chunks } or chunks) do
		norm[#norm + 1] = type(c) == "string" and { c, "FxBadge1" } or c
	end
	local buf = vim.api.nvim_win_get_buf(win)
	local row = vim.api.nvim_win_get_cursor(win)[1] - 1
	badge.buf, badge.gen = buf, badge.gen + 1
	local gen = badge.gen
	local function place(shift)
		local out = {}
		for _, c in ipairs(norm) do
			local n = tonumber((c[2] or ""):match("^FxBadge(%d)$"))
			out[#out + 1] = { c[1], n and ("FxBadge" .. math.min(n + shift, 3)) or c[2] }
		end
		vim.api.nvim_buf_clear_namespace(buf, badge_ns, 0, -1)
		vim.api.nvim_buf_set_extmark(buf, badge_ns, row, 0, { virt_text = out, virt_text_pos = "eol", priority = 10 })
	end
	place(0)
	if not M.enabled() then
		vim.defer_fn(function()
			if badge.gen == gen then
				badge_clear()
			end
		end, 1500)
		return
	end
	-- Кадр 1 — сразу (уже нарисован), 2–3 — угасание, 4 — снять: ~1с.
	badge.stop = M.ticker(330, function(i)
		if not vim.api.nvim_buf_is_valid(buf) or i >= 4 then
			badge.stop = nil
			badge_clear()
			return false
		end
		if i > 1 then
			place(i - 1)
		end
	end)
end

return M
