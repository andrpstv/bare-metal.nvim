-- core.weak_hw — DEPRECATED shim over core/perf (perf 4->2).
-- Каноника: settings.perf_lean + perf_lean_axes. Этот модуль сохранён для
-- совместимости: :WeakHwOn/:WeakHwOff/:WeakHwStatus работают как раньше,
-- но дергают perf. Мутации F5 (treesitter/debounce) живут в core/perf.
local M = {}

local function perf()
	local ok, p = pcall(require, "core.perf")
	if ok then
		return p
	end
	return nil
end

---@return boolean
function M.is_on()
	local p = perf()
	if p then
		return p.lean_on()
	end
	if vim.env.NVIM_DISTRO_SYNC == "1" then
		return false
	end
	if vim.env.NVIM_WEAK_HW == "1" then
		return true
	end
	return vim.g.weak_hw == true or vim.g.weak_hw == 1
end

---@param axis string
---@return boolean
function M.axis_on(axis)
	local p = perf()
	if p then
		if axis == "turbo" then
			-- Legacy weak_hw_axes.turbo=false: ось выключена даже при lean —
			-- старый контракт axes().turbo (lean_enable тогда и defer не тянет).
			local ok_s, s = pcall(require, "core.settings")
			if ok_s and type(s) == "table" and type(s.weak_hw_axes) == "table" and s.weak_hw_axes.turbo == false then
				return false
			end
			return p.defer_on()
		end
		return p.lean_axis(axis)
	end
	return M.is_on()
end

function M.enable()
	local p = perf()
	if p then
		p.lean_enable()
		return
	end
	vim.g.weak_hw = true
	vim.notify("[weak-hw] ON — (fallback, perf unavailable)", vim.log.levels.WARN)
end

function M.disable()
	local p = perf()
	if p then
		p.lean_disable()
		return
	end
	vim.g.weak_hw = false
	vim.notify("[weak-hw] OFF — (fallback, perf unavailable)", vim.log.levels.WARN)
end

---@return string
function M.status()
	local p = perf()
	if p then
		if not p.lean_on() then
			return "WEAK-HW OFF"
		end
		-- Показываем оси через perf, но с прежним префиксом для совместимости.
		local lean_st = p.lean_status()
		local axes = lean_st:match("%(axes: (.*)%)") or ""
		if axes ~= "" then
			return "WEAK-HW ON (axes: " .. axes .. ")"
		end
		return "WEAK-HW ON"
	end
	return M.is_on() and "WEAK-HW ON" or "WEAK-HW OFF"
end

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
