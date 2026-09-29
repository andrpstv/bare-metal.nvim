-- core.perf — канонические perf-флаги 4->2 (Researcher-B).
-- D (откладывание): perf_defer покрывает distro_defer + turbo + theme-custom-idle.
-- C (урезание): perf_lean покрывает weak_hw + gopls_weak_hw + F5-мутации +
--   defer_theme как ось theme.
-- Zero-cost by design: ноль require вне вызова. Все require — внутри функций,
-- вызывающие обязаны читать лениво (не кэшировать): :PerfDeferOn в сессии влияет
-- на БУДУЩИЕ загрузки без рестарта (тот же контракт, что у turbo).
local M = {}

local DEFAULT_LEAN_AXES = {
	gopls = true,
	theme = true,
	treesitter = true,
	debounce = true,
}

local function sync_on()
	return vim.env.NVIM_DISTRO_SYNC == "1"
end

local function get_settings()
	local ok, s = pcall(require, "core.settings")
	if ok and type(s) == "table" then
		return s
	end
	return nil
end

---@return boolean
function M.defer_on()
	if sync_on() then
		return false
	end
	-- Каноника: NVIM_PERF_DEFER=0 выключает, =1 включает (deprecated-алиасы ниже).
	local env = vim.env.NVIM_PERF_DEFER
	if env == "0" then
		return false
	end
	if env == "1" then
		return #vim.api.nvim_list_uis() > 0
	end
	-- Deprecated-алиасы turbo: NVIM_TURBO / NVIM_TURBO_MODE.
	if vim.env.NVIM_TURBO == "1" or vim.env.NVIM_TURBO_MODE == "1" then
		return #vim.api.nvim_list_uis() > 0
	end
	-- Session overrides (init.lua ставит рано, :PerfDeferOn — в сессии).
	if vim.g.perf_defer == false or vim.g.perf_defer == 0 then
		return false
	end
	if vim.g.perf_defer == true or vim.g.perf_defer == 1 then
		return #vim.api.nvim_list_uis() > 0
	end
	-- Deprecated session alias.
	if vim.g.turbo == true or vim.g.turbo == 1 then
		return #vim.api.nvim_list_uis() > 0
	end
	if vim.g.turbo == false or vim.g.turbo == 0 then
		-- Явный отказ в сессии гасит defer даже при perf_defer=true.
		return false
	end
	local s = get_settings()
	local base = true
	if s ~= nil and s.perf_defer ~= nil then
		base = s.perf_defer
	end
	if not base then
		return false
	end
	return #vim.api.nvim_list_uis() > 0
end

---@return boolean
function M.lean_on()
	if sync_on() then
		return false
	end
	local env = vim.env.NVIM_PERF_LEAN
	if env == "0" then
		return false
	end
	if env == "1" then
		return true
	end
	-- Deprecated: NVIM_WEAK_HW=1 форсит perf_lean.
	if vim.env.NVIM_WEAK_HW == "1" then
		return true
	end
	if vim.g.perf_lean == true or vim.g.perf_lean == 1 then
		return true
	end
	if vim.g.perf_lean == false or vim.g.perf_lean == 0 then
		return false
	end
	-- Deprecated session alias.
	if vim.g.weak_hw == true or vim.g.weak_hw == 1 then
		return true
	end
	if vim.g.weak_hw == false or vim.g.weak_hw == 0 then
		-- Явный отказ гасит lean, если нет явного perf_lean=true выше.
		-- Проверяем settings ниже только если нет явного vim.g.perf_lean.
		local s0 = get_settings()
		if s0 ~= nil and (s0.perf_lean == true) then
			return true
		end
		return false
	end
	local s = get_settings()
	if s ~= nil and s.perf_lean == true then
		return true
	end
	return false
end

-- Алиасы глобального lean-чека (старый weak_hw.is_on контракт).
M.is_lean = M.lean_on
M.lean_is_on = M.lean_on

-- Была ли новая ось задана юзером явно (per-key)? Читается из user.settings
-- напрямую: merged-настройки уже содержат дефолты, по ним явность не отличить.
-- user.settings статичен после старта, require закэширован — дёшево.
---@param name string
---@return boolean
local function user_axis_explicit(name)
	local ok, u = pcall(require, "user.settings")
	if not ok or type(u) ~= "table" then
		return false
	end
	local ua = u.perf_lean_axes
	if type(ua) == "function" then
		-- Кастомная функция-мерж: считаем новую таблицу явной целиком.
		return true
	end
	return type(ua) == "table" and ua[name] ~= nil
end

---@param name string ось: gopls|theme|treesitter|debounce
---@return boolean
function M.lean_axis(name)
	if not M.lean_on() then
		return false
	end
	local s = get_settings()
	if s == nil then
		return DEFAULT_LEAN_AXES[name] ~= false
	end
	local axes = s.perf_lean_axes
	-- Новый явный false гасит ось всегда: это либо выбор юзера, либо
	-- merge-сужение под одиночные legacy-флаги (settings.lua).
	if type(axes) == "table" and axes[name] == false then
		return false
	end
	-- Deprecated-маппинг weak_hw_axes (пережитки user-конфигов): legacy false
	-- уважаем, только если новая ось НЕ задана юзером явно. Иначе дефолтная
	-- новая таблица (вся true) молча перебивала бы старый выбор.
	local old = s.weak_hw_axes
	if type(old) == "table" and old[name] == false then
		if user_axis_explicit(name) then
			-- Юзер явно задал новую ось, а выше она не false — новая побеждает.
			return true
		end
		return false
	end
	if type(axes) ~= "table" then
		return DEFAULT_LEAN_AXES[name] ~= false
	end
	return axes[name] ~= false
end

-- Снимок настроек ДО включения lean, чтобы disable был обратимым.
local saved = nil

local function lean_axes_snapshot()
	local s = get_settings()
	local out = {}
	if type(s) ~= "table" then
		return out
	end
	-- Оси без прямых читателей (мутации F5) + deprecated-ключи для совместимости.
	for _, k in ipairs({
		"treesitter_indent",
		"treesitter_full_lines",
		"gopls_debounce",
		"gopls_weak_hw",
		"defer_theme",
	}) do
		out[k] = s[k]
	end
	return out
end

local function apply_lean_axes()
	local s = get_settings()
	if type(s) ~= "table" then
		return
	end
	if M.lean_axis("treesitter") then
		s.treesitter_indent = false
		s.treesitter_full_lines = math.min(s.treesitter_full_lines or 2000, 500)
	end
	if M.lean_axis("debounce") then
		s.gopls_debounce = math.max(s.gopls_debounce or 150, 250)
	end
	-- Совместимость: старые читатели (внешние конфиги) всё ещё смотрят
	-- gopls_weak_hw/defer_theme — выставляем их вслед за осями.
	if M.lean_axis("gopls") then
		s.gopls_weak_hw = true
	end
	if M.lean_axis("theme") then
		s.defer_theme = true
	end
end

--- Включить defer для БУДУЩИХ загрузок.
function M.defer_enable()
	vim.g.perf_defer = true
	-- Deprecated-алиас для старых читателей vim.g.turbo.
	vim.g.turbo = true
	vim.notify("[perf] DEFER ON — applies to future loads (new buffers)", vim.log.levels.INFO)
end

--- Выключить defer + синхронно слить отложенное.
function M.defer_disable()
	vim.g.perf_defer = false
	vim.g.turbo = false
	local ok_loader, loader = pcall(require, "distro.loader")
	if ok_loader and loader and loader.drain_all then
		pcall(loader.drain_all)
	end
	local ok_theme, theme = pcall(require, "themes.black-metal-khold")
	if ok_theme and theme and theme.apply_pending then
		pcall(theme.apply_pending)
	end
	vim.notify("[perf] DEFER OFF — deferred work drained", vim.log.levels.INFO)
end

--- Включить lean. Действует на будущие загрузки.
function M.lean_enable()
	local s = get_settings()
	if type(s) == "table" and not saved then
		saved = lean_axes_snapshot()
	end
	vim.g.perf_lean = true
	vim.g.weak_hw = true
	-- Мутации применяются ПОСЛЕ установки флага, иначе lean_axis() вернёт false.
	apply_lean_axes()
	-- lean тянет defer (старый контракт weak_hw): perf_defer и так true
	-- по умолчанию, но явный :PerfLeanOn должен чинить предшествующий
	-- :PerfDeferOff. Исключение: legacy weak_hw_axes.turbo=false —
	-- тогда defer НЕ тянем.
	local turbo_off = type(s) == "table"
		and type(s.weak_hw_axes) == "table"
		and s.weak_hw_axes.turbo == false
	if not turbo_off then
		M.defer_enable()
	end
	vim.notify(
		"[perf] LEAN ON — gopls/treesitter/theme/debounce ослаблены (будущие загрузки)",
		vim.log.levels.INFO
	)
end

--- Выключить lean и синхронно слить отложенное.
function M.lean_disable()
	vim.g.perf_lean = false
	vim.g.weak_hw = false
	local s = get_settings()
	if type(s) == "table" and saved then
		for k, v in pairs(saved) do
			s[k] = v
		end
		saved = nil
	end
	pcall(M.defer_disable)
	vim.notify("[perf] LEAN OFF — отложенная работа слита, настройки возвращены", vim.log.levels.INFO)
end

---@return string "PERF_DEFER ON" | "PERF_DEFER OFF"
function M.defer_status()
	return M.defer_on() and "PERF_DEFER ON" or "PERF_DEFER OFF"
end

---@return string
function M.lean_status()
	if not M.lean_on() then
		return "PERF_LEAN OFF"
	end
	local s = get_settings()
	local axes = {}
	if type(s) == "table" and type(s.perf_lean_axes) == "table" then
		for k, v in pairs(s.perf_lean_axes) do
			if v ~= false then
				axes[#axes + 1] = k
			end
		end
	else
		for k in pairs(DEFAULT_LEAN_AXES) do
			axes[#axes + 1] = k
		end
	end
	table.sort(axes)
	return "PERF_LEAN ON (axes: " .. table.concat(axes, ", ") .. ")"
end

---@return string combined
function M.status()
	return M.defer_status() .. " + " .. M.lean_status()
end

function M.setup()
	-- Канонические команды perf (единственные; :Turbo*/:WeakHw* удалены).
	-- Env-алиасы прошлого (NVIM_TURBO, NVIM_TURBO_MODE, NVIM_WEAK_HW) читаются
	-- в defer_on()/lean_on() и статусах ниже — совместимость без шимов.
	vim.api.nvim_create_user_command("PerfDeferOn", function()
		M.defer_enable()
	end, { desc = "perf: enable defer for future loads" })
	vim.api.nvim_create_user_command("PerfDeferOff", function()
		M.defer_disable()
	end, { desc = "perf: disable + drain deferred work synchronously" })
	vim.api.nvim_create_user_command("PerfDeferStatus", function()
		local env = vim.env.NVIM_PERF_DEFER or vim.env.NVIM_TURBO or vim.env.NVIM_TURBO_MODE or "-"
		vim.notify(M.defer_status() .. " (env=" .. env .. ")", vim.log.levels.INFO)
	end, { desc = "perf: show defer ON/OFF (no side effects)" })
	vim.api.nvim_create_user_command("PerfLeanOn", function()
		M.lean_enable()
	end, { desc = "perf: enable lean preset for future loads" })
	vim.api.nvim_create_user_command("PerfLeanOff", function()
		M.lean_disable()
	end, { desc = "perf: disable lean + drain deferred work" })
	vim.api.nvim_create_user_command("PerfLeanStatus", function()
		local env = vim.env.NVIM_PERF_LEAN or vim.env.NVIM_WEAK_HW or "-"
		vim.notify(M.lean_status() .. " (env=" .. env .. ")", vim.log.levels.INFO)
	end, { desc = "perf: show lean state and axes (no side effects)" })
end

return M
