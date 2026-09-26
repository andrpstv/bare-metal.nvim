-- core.weak_hw — пресет «слабое железо» ОДНИМ переключателем.
--
-- Зачем: у владельца на слабом ПК было два разрозненных рычага (turbo и
-- gopls_weak_hw) плюс заготовки defer_theme/treesitter/debounce. Это разные оси,
-- и знать про все нужно вручную. Здесь они собраны в один opt-in пресет.
--
-- ЧТО ЭТО НЕ ЯВЛЯЕТСЯ: не «ускорением без издержек». Каждая ось чего-то стоит —
-- turbo откладывает, gopls_weak_hw отключает диагностические фичи, defer_theme
-- допускает вспышку первого кадра, treesitter_ослабляет подсветку.
--
-- ПРО ДЕФОЛТЫ: settings.weak_hw = false. Пока флаг выключен, ни один модуль этого
-- не читает и поведение конфига побайтово прежнее.
--
-- ПРО ЧТЕНИЕ ФЛАГА: is_on() читается ЛЕНИВО и НИГДЕ НЕ КЭШИРУЕТСЯ — так же, как
-- core.turbo. Переключение в середине сессии влияет на БУДУЩИЕ загрузки; уже
-- поднятые клиенты/буферы не перенастраиваются (тот же контракт, что у turbo).
local M = {}

local settings = require("core.settings")

-- Снимок настроек ДО включения пресета, чтобы :WeakHwOff их вернул.
-- Без этого «переключатель» был бы необратимым: enable() мутирует settings, и
-- после выключения оси остались бы включёнными (проверено: gopls_weak_hw=true
-- переживал :WeakHwOff).
local saved = nil

--- Оси пресета. Каждую можно выключить отдельно через settings.weak_hw_axes —
--- тогда пресет включит остальные, а выключенную ось не тронет.
local DEFAULT_AXES = {
	turbo = true, -- отложить пары/format_on_save/cursorline/gitsigns/тему-кастом
	gopls = true, -- gopls_weak_hw: фон gopls на минимум
	theme = true, -- defer_theme: базовая тема после первого кадра
	treesitter = true, -- treesitter_indent=false, treesitter_full_lines ниже
	debounce = true, -- gopls_debounce выше
}

---@return table<string, boolean>
local function axes()
	local a = settings.weak_hw_axes
	if type(a) ~= "table" then
		return DEFAULT_AXES
	end
	local out = {}
	for k, v in pairs(DEFAULT_AXES) do
		out[k] = a[k] ~= false -- отсутствующий ключ = ось включена
	end
	return out
end

---@return boolean
function M.is_on()
	if vim.env.NVIM_DISTRO_SYNC == "1" then
		return false
	end
	if vim.env.NVIM_WEAK_HW == "1" then
		return true
	end
	return vim.g.weak_hw == true or vim.g.weak_hw == 1
end

--- Активна ли конкретная ось (для тех, кто хочет часть без пресета).
---@param axis string
---@return boolean
function M.axis_on(axis)
	return M.is_on() and axes()[axis] == true
end

local function apply_axes()
	local a = axes()
	if a.gopls then
		settings.gopls_weak_hw = true
	end
	if a.theme then
		settings.defer_theme = true
	end
	if a.treesitter then
		settings.treesitter_indent = false
		settings.treesitter_full_lines = math.min(settings.treesitter_full_lines or 2000, 500)
	end
	if a.debounce then
		settings.gopls_debounce = math.max(settings.gopls_debounce or 150, 250)
	end
end

--- Включить пресет. Действует на будущие загрузки.
function M.enable()
	if not saved then
		saved = {
			gopls_weak_hw = settings.gopls_weak_hw,
			defer_theme = settings.defer_theme,
			treesitter_indent = settings.treesitter_indent,
			treesitter_full_lines = settings.treesitter_full_lines,
			gopls_debounce = settings.gopls_debounce,
		}
	end
	vim.g.weak_hw = true
	apply_axes()
	if axes().turbo then
		require("core.turbo").enable()
	end
	vim.notify(
		"[weak-hw] ON — turbo + gopls/treesitter/theme/debounce ослаблены (будущие загрузки)",
		vim.log.levels.INFO,
		{ title = "weak-hw" }
	)
end

--- Выключить пресет и синхронно слить отложенное (как :TurboOff).
function M.disable()
	vim.g.weak_hw = false
	-- Вернуть оси в состояние до включения пресета: выключатель обязан быть
	-- обратимым, иначе второй :WeakHwOn уже не восстановит исходные значения.
	if saved then
		for k, v in pairs(saved) do
			settings[k] = v
		end
		saved = nil
	end
	local ok, turbo = pcall(require, "core.turbo")
	if ok and turbo then
		pcall(turbo.disable)
	end
	vim.notify("[weak-hw] OFF — отложенная работа слита, настройки возвращены", vim.log.levels.INFO, { title = "weak-hw" })
end

---@return string
function M.status()
	if not M.is_on() then
		return "WEAK-HW OFF"
	end
	local on = {}
	for k in pairs(axes()) do
		on[#on + 1] = k
	end
	table.sort(on)
	return "WEAK-HW ON (axes: " .. table.concat(on, ", ") .. ")"
end

--- Регистрация :WeakHwOn / :WeakHwOff / :WeakHwStatus.
function M.setup()
	vim.api.nvim_create_user_command("WeakHwOn", function()
		M.enable()
	end, { desc = "weak-hw: включить пресет слабого железа (будущие загрузки)" })
	vim.api.nvim_create_user_command("WeakHwOff", function()
		M.disable()
	end, { desc = "weak-hw: выключить пресет + слить отложенное" })
	vim.api.nvim_create_user_command("WeakHwStatus", function()
		local env = vim.env.NVIM_WEAK_HW or "-"
		vim.notify(M.status() .. " (env=" .. env .. ")", vim.log.levels.INFO, { title = "weak-hw" })
	end, { desc = "weak-hw: показать состояние (без побочных эффектов)" })
end

return M
