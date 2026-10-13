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

return M
