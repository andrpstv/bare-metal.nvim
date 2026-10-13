-- dev.termmarks — статус команд в :terminal (как декорации shell-integration в VS Code):
-- ✓/✗ в signcolumn на строке приглашения + виртуальный текст (`exit 2 · 3.4s`).
-- Почему свой: ядро (defaults.lua) разбирает только OSC 133;A (метки приглашений для [[ / ]]),
-- а C/D (старт вывода / код возврата) не трогает; плагин ради ~60 строк не нужен.
-- Цена на TermRequest — один string.match по префиксу; остальные OSC отбрасываются сразу.
local M = {}

local ns = vim.api.nvim_create_namespace("dev_termmarks")
local prompt_ns -- namespace меток приглашений ядра, создаётся лениво (get_namespaces)
local started = {} ---@type table<integer, {t: integer, row: integer}> буфер -> момент/строка OSC C
local augroup

---@param seq string
---@return {kind: "C"}|{kind: "D", code: integer}|nil
function M._parse(seq)
	if seq:sub(1, 6) ~= "\027]133;" then
		return nil
	end
	local kind = seq:sub(7, 7)
	if kind == "C" then
		return { kind = "C" }
	elseif kind == "D" then
		local code = seq:match("^D;(%-?%d+)", 7)
		-- D без кода = неизвестный итог: метку не ставим
		return code and { kind = "D", code = tonumber(code) } or nil
	end
end

---@param sec number
---@return string|nil -- nil для < 1с: быстрые команды не шумят
function M._fmt_duration(sec)
	if sec < 1 then
		return nil
	elseif sec < 60 then
		return string.format("%.1fs", sec)
	end
	return string.format("%dm%02ds", math.floor(sec / 60), math.floor(sec % 60))
end

---@param buf integer
---@param code integer
---@param sec number|nil
---@param fallback_row integer 1-based строка курсора на D
local function mark(buf, code, sec, fallback_row)
	prompt_ns = prompt_ns or vim.api.nvim_get_namespaces()["nvim.terminal.prompt"]
	local row = fallback_row - 1
	local st = started[buf]
	if st and prompt_ns then
		-- последнее приглашение на/выше строки старта команды = приглашение этой команды
		local m = vim.api.nvim_buf_get_extmarks(buf, prompt_ns, { st.row - 1, 0 }, 0, { limit = 1 })[1]
		row = m and m[2] or row
	end
	if row < 0 or row >= vim.api.nvim_buf_line_count(buf) then
		return
	end
	local ok = code == 0
	local dur = sec and M._fmt_duration(sec)
	local virt = {}
	if not ok then
		virt[#virt + 1] = { "exit " .. code, "DiagnosticError" }
	end
	if dur then
		virt[#virt + 1] = { (#virt > 0 and " · " or "") .. dur, "Comment" }
	end
	if #virt > 0 then
		table.insert(virt, 1, { "  ", "Normal" })
	end
	pcall(vim.api.nvim_buf_set_extmark, buf, ns, row, 0, {
		id = row + 1, -- повтор D на той же строке заменяет метку
		sign_text = ok and "✓" or "✗",
		sign_hl_group = ok and "DiagnosticOk" or "DiagnosticError",
		virt_text = #virt > 0 and virt or nil,
		priority = 200,
	})
end

function M.setup()
	if augroup then
		return
	end
	augroup = vim.api.nvim_create_augroup("dev_termmarks", { clear = true })
	vim.api.nvim_create_autocmd("TermRequest", {
		group = augroup,
		desc = "[term] command status marks from OSC 133;C/D",
		callback = function(ev)
			local p = M._parse(ev.data.sequence)
			if not p then
				return
			end
			local buf = ev.buf
			if p.kind == "C" then
				started[buf] = { t = vim.uv.hrtime(), row = ev.data.cursor[1] }
			elseif started[buf] then
				-- D без C (первый промпт, пустой Enter — zsh не зовёт preexec) не относится ни к
				-- одной команде: без C метка встала бы на случайную строку.
				local st = started[buf]
				mark(buf, p.code, (vim.uv.hrtime() - st.t) / 1e9, ev.data.cursor[1])
				started[buf] = nil
			end
		end,
	})
	vim.api.nvim_create_autocmd("BufWipeout", {
		group = augroup,
		callback = function(ev)
			started[ev.buf] = nil
		end,
	})
end

return M
